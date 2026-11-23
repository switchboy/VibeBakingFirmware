#!/system/bin/sh
# flash_card_a14.sh - write ONE Android 14 span onto the SD-boot card, from the unit, over adb.
#
# Why this script exists (D101): the SD-boot card carries the same partition layout as the eMMC -
# measured in the card recovery boot of Nov 23, /proc/partitions reports mmcblk1 with p7 32,768 blocks
# (boot) and p14 3,186,688 blocks (super), and p14 holds a real liblp super (geometry magic `gDla` at
# byte 4096 of the card capture). The card's own dtbo (p5) carries the FDT property `bootargs_ext` =
# "androidboot.boot_devices=fe330000.sdhci" at byte 213, and /dev/block/by-name is built from that
# value, which is why by-name points at the eMMC even in a card boot. Changing those 14 bytes to
# "fe320000.dwmmc" - the controller the boot card itself sits on, measured from
# /sys/block/mmcblk1/device -> fe320000.dwmmc/mmc_host/mmc1 - points by-name at the card, so an
# Android 14 payload written to the card's p7 + p14 runs entirely from the card and the eMMC is never
# read or written. The rollback for a failed attempt is physical: the owner removes the card and the
# unit boots the untouched stock Android 10 from the eMMC.
#
# Hard rules this script enforces:
#   * the destination device is resolved by WHOLE-DEVICE block count plus sysfs type SD (never
#     by-name, never a partition number alone) - D76;
#   * the eMMC (61,341,696 blocks, type MMC) and the second/evidence card (30,533,632 blocks) can
#     never be a destination: both are refused by block count before anything is opened;
#   * one span per invocation - D62's one-variable rule;
#   * the current content of the target partition must hash to one of the digests listed in
#     <name>.before, otherwise nothing is written;
#   * every write is followed by a whole-partition sha256 read back on the device and compared with
#     the image digest. Measured Nov 23 in the card recovery boot: `toybox sha256sum` on a block node
#     returns, and it is fast - 33,554,432 B in 2.5 s at 14 MB/s, and it reproduced the registered
#     card p7 carve digest 1b47dbc48aee…, so whole-partition verification is cheap here.
#
# Run (from the workstation):
#   adb push card-p7-a14.img card-p7-a14.img.sha256 card-p7-a14.img.before flash_card_a14.sh <SRC>
#   adb shell sh <SRC>/flash_card_a14.sh boot
# Targets: dtbo | boot | super | bcb-clear | verify
set -u

SRC=${SRC:-}
TARGET=${1:-}

say() { printf '%s\n' "$*"; }
die() { say "ABORT: $*"; exit 1; }

# ---- tools -------------------------------------------------------------------------------------
# Recovery has busybox 1.11.1 (no sha256sum) plus toybox 0.8.0 under /system/bin; Android 10 has
# toybox too. Resolve each tool once, absolute, because init gives no PATH.
tool() {
  for c in "/system/bin/$1" "/sbin/$1" "/bin/$1" "/system/xbin/$1"; do
    [ -x "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  if [ -x /system/bin/toybox ]; then
    if /system/bin/toybox 2>/dev/null | tr ' ' '\n' | grep -qx "$1"; then
      printf '%s\n' "/system/bin/toybox $1"; return 0
    fi
  fi
  return 1
}
DD=$(tool dd) || die "no dd"
SHA=$(tool sha256sum) || die "no sha256sum - this script will not write without verification"
CAT=$(tool cat) || die "no cat"
STAT=$(tool stat) || die "no stat"
GREP=$(tool grep) || die "no grep"

[ "$(id -u)" = 0 ] || die "needs uid 0 - run 'adb root' first"

# ---- device identities, as blocks in /proc/partitions ------------------------------------------
BOOT_CARD_BLOCKS=7761920      # 7,948,206,080 B - the SD-boot card (whole device)
EVID_CARD_BLOCKS=30533632     # 31,266,439,168 B - the second card, never a destination
EMMC_BLOCKS=61341696          # 62,813,896,704 B - the eMMC, never a destination

blocks_of() { $GREP -E "[ ]$1\$" /proc/partitions | while read -r _ _ b _; do printf '%s\n' "$b"; done; }

# ---- resolve the boot card --------------------------------------------------------------------
dev=
for d in /sys/block/mmcblk*; do
  [ -d "$d" ] || continue
  n=${d##*/}
  b=$(blocks_of "$n")
  [ "$b" = "$BOOT_CARD_BLOCKS" ] || continue
  t=$($CAT "$d/device/type" 2>/dev/null)
  [ "$t" = SD ] || { say "note: $n has the boot-card size but sysfs type '$t', not SD - skipped"; continue; }
  [ -n "$dev" ] && die "two devices match the boot card ($dev and $n) - refusing to guess"
  dev=$n
done
[ -n "$dev" ] || die "no SD device of $BOOT_CARD_BLOCKS blocks present - insert the boot card"
db=$(blocks_of "$dev")
[ "$db" = "$EVID_CARD_BLOCKS" ] && die "$dev is the second card - never a destination"
[ "$db" = "$EMMC_BLOCKS" ] && die "$dev is the eMMC - never a destination"
say "boot card resolved: /dev/block/$dev ($db blocks, type SD)"

# ---- target -> partition ----------------------------------------------------------------------
case "$TARGET" in
  dtbo)      idx=5;  want_blocks=4096;    img=card-p5-a14.bin ;;
  boot)      idx=7;  want_blocks=32768;   img=card-p7-a14.img ;;
  super)     idx=14; want_blocks=3186688; img=card-p14-a14.img ;;
  bcb-clear) idx=3;  want_blocks=4096;    img= ;;
  verify)    idx=;   want_blocks=;        img= ;;
  *) die "usage: $0 dtbo|boot|super|bcb-clear|verify   (one span per run)" ;;
esac
# IMG overrides the file name only; the size and the partition it may go to are still checked below.
[ -n "${IMG:-}" ] && [ -n "$img" ] && img=$IMG

emmc_heads() {
  for p in 3 7 8; do
    n=
    for d in /sys/block/mmcblk*; do
      [ "$(blocks_of "${d##*/}")" = "$EMMC_BLOCKS" ] && n=${d##*/}
    done
    [ -n "$n" ] || { say "  eMMC not found - cannot show its heads"; return 0; }
    h=$($DD if="/dev/block/${n}p${p}" bs=4096 count=1 2>/dev/null | $SHA | cut -d' ' -f1)
    say "  eMMC ${n}p${p} head4k $h"
  done
}

if [ "$TARGET" = verify ]; then
  say "== card partitions =="
  for p in 3 5 7 8 14; do
    node="/dev/block/${dev}p${p}"
    [ -b "$node" ] || { say "  p$p MISSING"; continue; }
    say "  p$p blocks $(blocks_of "${dev}p${p}") sha256 $($SHA "$node" | cut -d' ' -f1)"
  done
  say "== eMMC heads (never written by this script) =="
  emmc_heads
  exit 0
fi

node="/dev/block/${dev}p${idx}"
[ -b "$node" ] || die "no $node"
pb=$(blocks_of "${dev}p${idx}")
[ "$pb" = "$want_blocks" ] || die "$node is $pb blocks, expected $want_blocks - layout mismatch"
say "target $node ($pb blocks)"

say "== eMMC heads before =="
emmc_heads

if [ "$TARGET" = bcb-clear ]; then
  before=$($DD if="$node" bs=4096 count=1 2>/dev/null | $SHA | cut -d' ' -f1)
  say "misc head4k before $before"
  # Pre-write gate, same rule as the image writes: the 2048 B BCB must be one we recognise - our own
  # armed blob or an already-clear one. Anything else means this is not the misc we think it is.
  bcb_before=$($DD if="$node" bs=2048 count=1 2>/dev/null | $SHA | cut -d' ' -f1)
  say "BCB 2048 B before $bcb_before"
  case "$bcb_before" in
    ceaae1a6314a19927ab431d55b46d08a6aaf73e9bcceb578244783c06bffd00e) say "  (our armed BCB)" ;;
    e5a00aa9991ac8a5ee3109844d84a55583bd20572ad3ffcd42792f3c36b183ad) say "  (already clear - nothing to do)"; exit 0 ;;
    *) die "BCB $bcb_before is neither our armed blob nor all zeros - nothing written" ;;
  esac
  # 2048 B of zeros over the BCB only. Nothing past byte 2048 is touched: count=2048 bs=1 with
  # conv=notrunc, so the rest of the partition keeps its bytes (measured: the card's misc holds
  # vendor bytes past 2048 that must survive).
  $DD if=/dev/zero of="$node" bs=1 count=2048 conv=notrunc 2>&1 | tail -1
  sync
  after=$($DD if="$node" bs=4096 count=1 2>/dev/null | $SHA | cut -d' ' -f1)
  bcb=$($DD if="$node" bs=2048 count=1 2>/dev/null | $SHA | cut -d' ' -f1)
  say "misc head4k after  $after"
  say "BCB 2048 B sha256  $bcb"
  say "  (all-zero 2048 B is e5a00aa9991ac8a5ee3109844d84a55583bd20572ad3ffcd42792f3c36b183ad)"
  say "== eMMC heads after =="
  emmc_heads
  exit 0
fi

[ -n "$SRC" ] || die "set SRC to the directory holding $img"
[ -s "$SRC/$img" ] || die "no $SRC/$img"
[ -s "$SRC/$img.sha256" ] || die "no $SRC/$img.sha256 - refusing to write an unverified image"
[ -s "$SRC/$img.before" ] || die "no $SRC/$img.before - refusing to write without a pre-write check"

want=$($CAT "$SRC/$img.sha256" | cut -d' ' -f1)
got=$($SHA "$SRC/$img" | cut -d' ' -f1)
say "staged image $got"
[ "$got" = "$want" ] || die "staged image does not match its sidecar digest - push it again"

isz=$($STAT -c %s "$SRC/$img")
say "image $isz B"
# The three A14 spans are whole-partition images, so the byte count must equal the partition exactly.
case "$TARGET" in
  dtbo)  [ "$isz" = 4194304 ]    || die "dtbo image must be 4,194,304 B" ;;
  boot)  [ "$isz" = 33554432 ]   || die "boot image must be 33,554,432 B" ;;
  super) [ "$isz" = 3263168512 ] || die "super image must be 3,263,168,512 B" ;;
esac

say "== pre-write check =="
cur=$($SHA "$node" | cut -d' ' -f1)
say "partition now $cur"
# An unreadable partition must never compare equal to anything: a failed hash leaves cur empty, and
# an empty pattern would match a blank line in the .before file.
case "$cur" in
  ????????????????????????????????????????????????????????????????) : ;;
  *) die "could not hash $node (got '$cur') - nothing written" ;;
esac
if [ "$cur" = "$want" ]; then
  say "already equal to the image - nothing to write"
  say "== eMMC heads after =="
  emmc_heads
  exit 0
fi
$GREP -q "^$cur\$" "$SRC/$img.before" \
  || die "partition content $cur is not listed in $img.before - nothing written"

say "== writing $TARGET =="
$DD if="$SRC/$img" of="$node" bs=1048576 conv=fsync 2>&1 | tail -1
sync

say "== read back (whole partition) =="
rb=$($SHA "$node" | cut -d' ' -f1)
say "partition now $rb"
if [ "$rb" = "$want" ]; then
  say "VERIFIED: $node equals $img"
else
  say "MISMATCH: $node is $rb, image is $want - do NOT boot; restore from the card capture"
fi

say "== eMMC heads after =="
emmc_heads
