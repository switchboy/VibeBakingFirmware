#!/system/bin/sh
# scripts/write_card_gpt.sh - put the prepared GPT head/tail blobs onto the boot SD card.
#
# Written for Android's toybox /system/bin/sh (mksh) and for recovery's sh. POSIX only:
# no bash-isms, no awk (recovery's sh has no awk), no /dev/block/by-name lookups.
#
#   SRC=/tmp sh write_card_gpt.sh          write + verify
#   SRC=/tmp DRY=1 sh write_card_gpt.sh    every check, the two dd writes are skipped
#
# $SRC must contain:
#   new-head34.bin   sectors 0..33   (protective MBR, primary GPT header, primary entries)
#   new-tail33.bin   sectors 15523807..15523839 (backup entries, backup header)
#   before.sha256    two lines: "<sha> head" and "<sha> tail"  = what is on the card NOW
#   after.sha256     two lines: "<sha> head" and "<sha> tail"  = the staged blobs
#
# The boot card is found by scanning $SYSROOT/block/mmcblk*/size (the block device's own size) and
# requiring size == 15523840 sectors, exactly one match. Zero or more than one match is a
# refusal; by-name symlinks are never used. The eMMC is the device whose size is
# 122683392 - it is never written, only its first 4 KiB is hashed for the log.
#
# Paths are overridable so the logic can be exercised offline against a fake card:
#   SYSROOT (default /sys), DEVDIR (default /dev/block), DROPCACHES
#   (default /proc/sys/vm/drop_caches), SCRATCH (default $TMPDIR or /tmp).
#
# Exit status: 0 = written and VERIFIED, or "already written", or DRY run; 1 = refused or
# read-back MISMATCH.

SECTOR=512
CARD_SECTORS=15523840
EMMC_SECTORS=122683392
HEAD_SECTORS=34
TAIL_SECTORS=33
TAIL_SKIP=15523807

SRC=${SRC:-/tmp}
SYSROOT=${SYSROOT:-/sys}
DEVDIR=${DEVDIR:-/dev/block}
DROPCACHES=${DROPCACHES:-/proc/sys/vm/drop_caches}
SCRATCH=${SCRATCH:-${TMPDIR:-/tmp}}
DRY=${DRY:-0}

CR=$(printf '\r')

die() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

note() {
    printf '%s\n' "$*"
}

# sha256sum/sha256 (toybox has both; Android's core utility set has sha256sum).
SHA_CMD=''
for c in sha256sum sha256; do
    if command -v "$c" >/dev/null 2>&1; then
        SHA_CMD=$c
        break
    fi
done
if [ -z "$SHA_CMD" ]; then
    die "no sha256sum or sha256 in PATH - cannot verify digests"
fi
if ! command -v dd >/dev/null 2>&1; then
    die "dd not in PATH"
fi

# digest FILE -> prints the hex digest (first field of the hashing tool's output).
digest() {
    out=$($SHA_CMD "$1") || die "digest failed for $1"
    set -- $out
    printf '%s\n' "$1"
}

# sysfs_read FILE -> prints the first non-empty line of a sysfs attribute file.
sysfs_read() {
    line=''
    if [ -f "$1" ]; then
        while IFS= read -r attr; do
            attr=${attr%"$CR"}
            if [ -n "$attr" ]; then
                line=$attr
                break
            fi
        done < "$1"
    fi
    printf '%s\n' "$line"
}

# read_pair FILE -> sets PAIR_HEAD/PAIR_TAIL from "<sha> head" and "<sha> tail" lines.
# Tokens are split on whitespace, so LF-separated lines (or a missing final newline) work;
# a stray CR makes the label token invalid and is refused with a clear message.
read_pair() {
    file=$1
    if [ ! -f "$file" ]; then
        die "missing $file"
    fi
    pair_head=''
    pair_tail=''
    set -- $(cat "$file")
    while [ $# -ge 2 ]; do
        sha=$1
        label=$2
        shift 2
        case "$label" in
            head) pair_head=$sha ;;
            tail) pair_tail=$sha ;;
            *) die "$file: token '$label' is not 'head' or 'tail' (need '<sha> head' and '<sha> tail', LF-separated)" ;;
        esac
        if [ ${#sha} -ne 64 ]; then
            die "$file: digest '$sha' is ${#sha} chars, expected 64"
        fi
    done
    if [ -z "$pair_head" ] || [ -z "$pair_tail" ]; then
        die "$file: need one '<sha> head' and one '<sha> tail' line"
    fi
    PAIR_HEAD=$pair_head
    PAIR_TAIL=$pair_tail
}

# resolve_boot_device -> sets CARD_NAME and EMMC_NAME; prints what it scanned.
# Called directly (not inside a command substitution) so the variables survive.
resolve_boot_device() {
    found=''
    found_count=0
    emmc=''
    for d in "$SYSROOT"/block/mmcblk*; do
        if [ ! -d "$d" ]; then
            continue
        fi
        name=${d##*/}
        # The block device's own size only. $d/device/size is NOT used: on the unit it made
        # mmcblk2boot0/1 report the whole eMMC's size (seen in the Nov 23 dry run).
        size=$(sysfs_read "$d/size")
        if [ -z "$size" ]; then
            note "note: $name has no readable size file, skipped"
            continue
        fi
        note "scanned $name: size=$size sectors"
        if [ "$size" = "$EMMC_SECTORS" ]; then
            emmc=$name
        fi
        if [ "$size" = "$CARD_SECTORS" ]; then
            found_count=$((found_count + 1))
            found=$name
        fi
    done
    if [ "$found_count" -eq 0 ]; then
        die "no mmcblk device of exactly $CARD_SECTORS sectors found under $SYSROOT/block"
    fi
    if [ "$found_count" -gt 1 ]; then
        die "$found_count mmcblk devices of $CARD_SECTORS sectors found - refusing to guess"
    fi
    if [ -n "$emmc" ] && [ "$found" = "$emmc" ]; then
        die "matched device $found is also the $EMMC_SECTORS-sector eMMC - refusing"
    fi
    CARD_NAME=$found
    EMMC_NAME=$emmc
}

# emmc_head_digest -> prints the sha256 of the first 4 KiB of the eMMC (read only).
emmc_head_digest() {
    label=$1
    if [ -z "$EMMC_NAME" ]; then
        note "eMMC $label digest: no device with size $EMMC_SECTORS found, skipped"
        return 0
    fi
    node="$DEVDIR/$EMMC_NAME"
    if [ ! -b "$node" ] && [ ! -f "$node" ]; then
        note "eMMC $label digest: $node does not exist, skipped"
        return 0
    fi
    dd if="$node" bs=$SECTOR count=8 of="$SCRATCH/emmc_head.$$" 2>/dev/null || {
        note "eMMC $label digest: could not read $node, skipped"
        return 0
    }
    note "eMMC $label head 4 KiB ($node) sha256: $(digest "$SCRATCH/emmc_head.$$")"
}

# print_partnames -> reads sysfs partition attributes for p12 and p14 (read only).
print_partnames() {
    for p in 12 14; do
        pdir="$SYSROOT/block/$CARD_NAME/${CARD_NAME}p$p"
        if [ -d "$pdir" ]; then
            pname=''
            if [ -f "$pdir/uevent" ]; then
                while IFS= read -r ue; do
                    case "$ue" in PARTNAME=*) pname=${ue#PARTNAME=} ;; esac
                done < "$pdir/uevent"
            fi
            if [ -n "$pname" ]; then
                note "PARTNAME p$p: $pname"
            else
                note "PARTNAME p$p: sysfs dir exists but has no name/partname attribute"
            fi
        else
            note "PARTNAME p$p: not present in $SYSROOT/block/$CARD_NAME (partition table not re-read)"
        fi
    done
}

# ---- what is staged ---------------------------------------------------------------

HEAD_BLOB="$SRC/new-head34.bin"
TAIL_BLOB="$SRC/new-tail33.bin"
for f in "$HEAD_BLOB" "$TAIL_BLOB" "$SRC/before.sha256" "$SRC/after.sha256"; do
    if [ ! -f "$f" ]; then
        die "missing staged file $f"
    fi
done

read_pair "$SRC/after.sha256"
after_head=$PAIR_HEAD
after_tail=$PAIR_TAIL
read_pair "$SRC/before.sha256"
before_head=$PAIR_HEAD
before_tail=$PAIR_TAIL

staged_head=$(digest "$HEAD_BLOB")
staged_tail=$(digest "$TAIL_BLOB")
note "staged $HEAD_BLOB sha256: $staged_head"
note "staged $TAIL_BLOB sha256: $staged_tail"
note "after.sha256:  head $after_head tail $after_tail"
note "before.sha256: head $before_head tail $before_tail"
if [ "$staged_head" != "$after_head" ]; then
    die "staged head blob does not match after.sha256"
fi
if [ "$staged_tail" != "$after_tail" ]; then
    die "staged tail blob does not match after.sha256"
fi

# ---- which card -------------------------------------------------------------------

resolve_boot_device
DEV="$DEVDIR/$CARD_NAME"
if [ ! -b "$DEV" ] && [ ! -f "$DEV" ]; then
    die "device node $DEV for sysfs device $CARD_NAME does not exist (by-name is deliberately not used)"
fi
note "boot card: sysfs $CARD_NAME -> $DEV ($CARD_SECTORS sectors)"

mkdir -p "$SCRATCH" 2>/dev/null
if [ ! -d "$SCRATCH" ]; then
    die "scratch dir $SCRATCH does not exist and cannot be created"
fi
emmc_head_digest before

cur_head="$SCRATCH/card_head.$$"
cur_tail="$SCRATCH/card_tail.$$"

# ---- what is on the card right now --------------------------------------------------

if ! dd if="$DEV" bs=$SECTOR skip=0 count=$HEAD_SECTORS of="$cur_head" 2>/dev/null; then
    die "could not read sectors 0..$((HEAD_SECTORS - 1)) from $DEV"
fi
if ! dd if="$DEV" bs=$SECTOR skip=$TAIL_SKIP count=$TAIL_SECTORS of="$cur_tail" 2>/dev/null; then
    die "could not read sectors $TAIL_SKIP..$((TAIL_SKIP + TAIL_SECTORS - 1)) from $DEV"
fi
cur_head_sha=$(digest "$cur_head")
cur_tail_sha=$(digest "$cur_tail")
note "card head sectors 0..$((HEAD_SECTORS - 1)) sha256: $cur_head_sha"
note "card tail sectors $TAIL_SKIP..$((TAIL_SKIP + TAIL_SECTORS - 1)) sha256: $cur_tail_sha"

if [ "$cur_head_sha" = "$after_head" ] && [ "$cur_tail_sha" = "$after_tail" ]; then
    note "already written"
    rm -f "$cur_head" "$cur_tail" "$SCRATCH/emmc_head.$$"
    exit 0
fi
if [ "$cur_head_sha" != "$before_head" ] || [ "$cur_tail_sha" != "$before_tail" ]; then
    rm -f "$cur_head" "$cur_tail" "$SCRATCH/emmc_head.$$"
    die "card digests match neither before.sha256 nor after.sha256 - the card is not the expected pre-state"
fi
note "card matches before.sha256 - safe to write"

if [ "$DRY" = "1" ]; then
    note "DRY=1: checks all passed, the two dd writes are skipped, nothing written"
    print_partnames
    rm -f "$cur_head" "$cur_tail" "$SCRATCH/emmc_head.$$"
    exit 0
fi

# ---- write ------------------------------------------------------------------------

if ! dd if="$HEAD_BLOB" of="$DEV" bs=$SECTOR seek=0 count=$HEAD_SECTORS conv=notrunc,fsync 2>/dev/null; then
    rm -f "$cur_head" "$cur_tail" "$SCRATCH/emmc_head.$$"
    die "writing sectors 0..$((HEAD_SECTORS - 1)) failed"
fi
note "wrote head blob (sectors 0..$((HEAD_SECTORS - 1)))"
if ! dd if="$TAIL_BLOB" of="$DEV" bs=$SECTOR seek=$TAIL_SKIP count=$TAIL_SECTORS conv=notrunc,fsync 2>/dev/null; then
    rm -f "$cur_head" "$cur_tail" "$SCRATCH/emmc_head.$$"
    die "writing sectors $TAIL_SKIP..$((TAIL_SKIP + TAIL_SECTORS - 1)) failed"
fi
note "wrote tail blob (sectors $TAIL_SKIP..$((TAIL_SKIP + TAIL_SECTORS - 1)))"
sync
echo 3 > "$DROPCACHES" 2>/dev/null || note "note: could not write $DROPCACHES (page cache drop skipped)"

# ---- read back --------------------------------------------------------------------

if ! dd if="$DEV" bs=$SECTOR skip=0 count=$HEAD_SECTORS of="$cur_head" 2>/dev/null; then
    rm -f "$cur_head" "$cur_tail" "$SCRATCH/emmc_head.$$"
    die "read-back of sectors 0..$((HEAD_SECTORS - 1)) failed"
fi
if ! dd if="$DEV" bs=$SECTOR skip=$TAIL_SKIP count=$TAIL_SECTORS of="$cur_tail" 2>/dev/null; then
    rm -f "$cur_head" "$cur_tail" "$SCRATCH/emmc_head.$$"
    die "read-back of sectors $TAIL_SKIP..$((TAIL_SKIP + TAIL_SECTORS - 1)) failed"
fi
rb_head_sha=$(digest "$cur_head")
rb_tail_sha=$(digest "$cur_tail")
note "read-back head sha256: $rb_head_sha (expected $after_head)"
note "read-back tail sha256: $rb_tail_sha (expected $after_tail)"
emmc_head_digest after

if command -v blockdev >/dev/null 2>&1; then
    if blockdev --rereadpt "$DEV" 2>/dev/null; then
        note "blockdev --rereadpt $DEV ok"
    else
        note "blockdev --rereadpt $DEV failed (ignored)"
    fi
else
    note "blockdev not available (ignored)"
fi

print_partnames

rm -f "$cur_head" "$cur_tail" "$SCRATCH/emmc_head.$$"

if [ "$rb_head_sha" = "$after_head" ] && [ "$rb_tail_sha" = "$after_tail" ]; then
    note "VERIFIED"
    exit 0
fi
note "MISMATCH"
exit 1
