#!/system/bin/sh
# arm_card_misc.sh - the re-arm step the owner runs before each SD-boot card use (**D98**).
#
# Why it exists: entering recovery clears the BCB (measured Nov 22: the misc head read inside a recovery
# boot that carried b.mode=recovery was all zeros), so a card boot needs its own misc re-armed every time.
# The blob is the exact 2048 B Android BCB: `boot-recovery\0` at offset 0, `recovery\n` at offset 64, zero
# padding to 2048, NO arguments and no `--wipe_all` (the digest of that exact blob is registered).
#
# The target is resolved by SIZE and TYPE, never by partition number alone: the SD card whose whole-device
# size is 7,948,206,080 B (type SD), partition 3 sized 4,194,304 B. The eMMC (type MMC, whole-device size
# 62,813,896,704 B) is refused by construction - this script must never arm eMMC misc.
#
# Offline gate: HU_MISC_FILE=<regular file> writes the blob into that file instead, which is how
# scripts/smoke_card_rearm.sh proves the byte layout without a device.
set -u

CARD_SIZE=7948206080
MISC_SIZE=4194304
BB=/sbin/busybox
SB=/system/bin
TOY=/system/bin/toybox

tool() {
  if [ "${HU_OFFLINE:-0}" = 1 ]; then
    p=$(command -v "$1" 2>/dev/null)
    [ -n "$p" ] && { printf '%s\n' "$p"; return; }
    printf '%s\n' "$BB $1"
    return
  fi
  if [ -x "$SB/$1" ]; then printf '%s\n' "$SB/$1"
  elif [ -x "$TOY" ]; then printf '%s\n' "$TOY $1"
  else printf '%s\n' "$BB $1"
  fi
}
DD=$(tool dd)
SHA=$(tool sha256sum)
# `stat` is only a toybox applet on the HU, so it goes through tool() like dd and sha256sum. Measured
# Nov 23: a bare `stat -c %s` returned nothing on the unit and the script aborted with an empty size,
# which is the safe outcome - nothing was written.
ST=$(tool stat)
# The blob needs a writable directory. Android's normal boot has no /tmp (measured Nov 23: /tmp does not
# exist in Android, recovery does), so probe the candidates and take the first writable one. A dd error
# is not enough to notice on its own, which is why the size check below still gates the write.
RM=$(tool rm)
BCB_DIR=""
for d in /tmp /data/local/tmp; do
  if $DD if=/dev/zero of="$d/hu-bcb-probe.bin" bs=1 count=1 2>/dev/null; then
    $RM "$d/hu-bcb-probe.bin" 2>/dev/null
    BCB_DIR="$d"
    break
  fi
done
[ -n "$BCB_DIR" ] || { printf 'ABORT: no writable directory for the blob - nothing written\n'; exit 1; }
printf 'blob directory %s\n' "$BCB_DIR"

node=${HU_MISC_NODE:-}
if [ -n "${HU_MISC_FILE:-}" ]; then
  node=$HU_MISC_FILE
else
  for d in /sys/block/mmcblk*; do
    [ -d "$d" ] || continue
    n=$(basename "$d")
    t=$(cat "$d/device/type" 2>/dev/null)
    s=$(blockdev --getsize64 "/dev/block/$n" 2>/dev/null)
    [ "$t" = SD ] || continue
    [ "$s" = "$CARD_SIZE" ] || continue
    cand="/dev/block/${n}p3"
    [ -b "$cand" ] || continue
    ms=$(blockdev --getsize64 "$cand" 2>/dev/null)
    [ "$ms" = "$MISC_SIZE" ] || continue
    node=$cand
    printf 'target %s (whole device %s type %s size %s; partition size %s)\n' "$cand" "$n" "$t" "$s" "$ms"
    break
  done
fi
[ -n "$node" ] || { printf 'ABORT: no SD card misc of size %s found - nothing written\n' "$MISC_SIZE"; exit 1; }
case "$node" in
  *mmcblk2*) printf 'ABORT: %s is the eMMC - this script never arms eMMC misc\n' "$node"; exit 1 ;;
esac
if [ -n "${HU_MISC_FILE:-}" ]; then
  # A regular file target must exist and be partition-sized; dd would otherwise create a new file.
  [ -f "$node" ] || { printf 'ABORT: %s does not exist - nothing written\n' "$node"; exit 1; }
  fsz=$($ST -c %s "$node" 2>/dev/null)
  [ "$fsz" = "$MISC_SIZE" ] || { printf 'ABORT: %s is %s B, not %s B - nothing written\n' "$node" "$fsz" "$MISC_SIZE"; exit 1; }
fi

blob="$BCB_DIR/hu-bcb.bin"
$DD if=/dev/zero of="$blob" bs=1 count=2048 2>/dev/null
printf 'boot-recovery\0' | $DD of="$blob" bs=1 conv=notrunc 2>/dev/null
printf 'recovery\n' | $DD of="$blob" bs=1 seek=64 conv=notrunc 2>/dev/null
sz=$($ST -c %s "$blob" 2>/dev/null)
[ "$sz" = 2048 ] || { printf 'ABORT: blob is %s B, not 2048 B - nothing written\n' "$sz"; exit 1; }
bdig=$($SHA "$blob" 2>/dev/null | cut -d' ' -f1)
printf 'blob %s B sha256=%s\n' "$sz" "$bdig"

printf '== writing 2048 B to %s ==\n' "$node"
$DD if="$blob" of="$node" bs=2048 count=1 conv=notrunc 2>&1 | tail -2
sync 2>/dev/null

printf '== readback ==\n'
$DD if="$node" bs=2048 count=1 2>/dev/null > "$BCB_DIR/hu-bcb-read.bin"
rdig=$($SHA "$BCB_DIR/hu-bcb-read.bin" 2>/dev/null | cut -d' ' -f1)
printf 'readback sha256=%s (blob was %s)\n' "$rdig" "$bdig"
if [ "$rdig" = "$bdig" ]; then printf 'ARMED and verified\n'; else printf 'READBACK MISMATCH - stop here\n'; exit 1; fi
od -An -c "$BCB_DIR/hu-bcb-read.bin" 2>/dev/null | head -4
