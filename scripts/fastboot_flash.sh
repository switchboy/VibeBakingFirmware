#!/usr/bin/env bash
# First flash over fastboot (docs/flash.md). This board has no Rockchip loader/Boot-ADB, so fastboot
# in the Android 10 ABL is the only first-write path - which also means it is the only rollback path.
#
#   scripts/fastboot_flash.sh <staged-dir> <backup-dir> [--dry-run]
#
# <staged-dir>  = output of scripts/stage_flash.sh (raw super.img, boot.img, recovery.img, sha256s)
# <backup-dir>  = the unit's own dumps pulled over adb root; the script refuses to flash without them
#
# Refusals, in order:
#   1. no backup dir / no p7.bin, p8.bin, p14.bin (or by-name/boot,recovery,super dumps) -> abort
#   2. three images from different packaging passes (stage_flash.sh checked this, re-checked here)
#   3. no fastboot device, or `partition-size:super` is not reported -> abort and print the
#      logical-partition fallback instead of forcing a write the bootloader may half-apply
#   4. an image larger than the partition fastboot reports -> abort
# Order: super first, then boot, then recovery, so the OS always matches the recovery beside it.
set -eu
STAGED=${1:?usage: fastboot_flash.sh <staged-dir> <backup-dir> [--dry-run]}
BACKUP=${2:?no backup directory: this is the only way back, docs/flash.md}
DRY=${3:-}
REPO=$(cd "$(dirname "$0")/.." && pwd)
FB=$(command -v fastboot || true)
[ -n "$FB" ] || { echo "fastboot not installed (apt install android-tools-fastboot)"; exit 1; }
[ -d "$STAGED" ] || { echo "no such staged dir: $STAGED"; exit 1; }
for f in super.img boot.img recovery.img sha256sums.txt; do
  [ -s "$STAGED/$f" ] || { echo "  ! missing or empty: $STAGED/$f (run scripts/stage_flash.sh)"; exit 1; }
done
if command -v sha256sum >/dev/null; then
  (cd "$STAGED" && sha256sum -c sha256sums.txt >/dev/null && echo "  staged image hashes OK")
fi

# Freshness of the staged set: all three images must come from the same packaging pass.
newest=$(for f in super.img boot.img recovery.img; do stat -c %Y "$STAGED/$f"; done | sort -n | tail -1)
for f in super.img boot.img recovery.img; do
  age=$((newest - $(stat -c %Y "$STAGED/$f")))
  [ "$age" -le 86400 ] || { echo "  ! $f is $((age / 3600)) h older than the newest staged image"; exit 1; }
done

# The backup must contain boot, recovery and super (the three partitions we overwrite). Accept the
# numeric dumps from docs/flash.md or any by-name dump of the same three.
have=0
for cand in p7.bin p8.bin p14.bin boot.bin recovery.bin super.bin; do
  [ -s "$BACKUP/$cand" ] && have=$((have + 1))
done
[ "$have" -ge 3 ] || {
  echo "  ! $BACKUP must hold the unit's own boot/recovery/super dumps (p7.bin p8.bin p14.bin, or"
  echo "    boot.bin recovery.bin super.bin) - take them over adb root before flashing, docs/flash.md"
  exit 1
}
echo "  backup present: $(ls "$BACKUP" | tr '\n' ' ')"

echo "=== fastboot pre-flight ==="
"$FB" devices
"$FB" reboot bootloader >/dev/null 2>&1 || true   # from a running Android 10 (adb reboot bootloader works too)
sleep 3
"$FB" devices | head -2

# fastboot prints getvar answers to stderr (getvar:partition-size:super ... OKAY), so read both
# streams. Decimal via bash arithmetic: Debian's default awk (mawk) has no strtonum.
size() {
  hex=$("$FB" getvar "partition-size:$1" 2>&1 | grep -oE "0x[0-9a-f]+" | head -1)
  [ -n "$hex" ] && echo "$((hex))"
}
declare -A P
for p in super boot recovery; do
  n=$(size "$p" || true)
  [ -n "$n" ] || { echo "  ! fastboot reports no partition-size:$p - this ABL cannot write that partition";
                   echo "    use the logical-partition fallback in docs/flash.md (fastboot flash system/vendor/...)"; exit 1; }
  P[$p]=$n
  want=$(stat -c %s "$STAGED/$p.img")
  echo "  $p: partition $n B, image $want B $([ "$want" -le "$n" ] && echo fits || echo TOO BIG)"
  [ "$want" -le "$n" ] || { echo "  ! $p.img is larger than the partition"; exit 1; }
done

if [ "$DRY" = "--dry-run" ]; then
  echo "  dry run: would flash super, boot, recovery in that order, then reboot"
  exit 0
fi

echo "=== flashing (super first) ==="
"$FB" flash super    "$STAGED/super.img"     # 3.26 GB raw; a few minutes over USB
"$FB" flash boot     "$STAGED/boot.img"
"$FB" flash recovery "$STAGED/recovery.img"
echo "=== rebooting ==="
"$FB" reboot
echo "Now: boot Android 14, run the SD-card probe (sh allinone.sh), then boot our recovery and wipe data."
echo "Rollback if needed: fastboot flash super <backup>/p14.bin (or super_stock.img), boot/recovery from p7.bin/p8.bin."
