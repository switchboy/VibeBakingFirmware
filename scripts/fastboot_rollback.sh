#!/usr/bin/env bash
# Undo the first flash: put the unit's own Android 10 boot/recovery/super back over fastboot.
#
#   scripts/fastboot_rollback.sh <backup-dir> [--super <super_stock.img>] [--dry-run]
#
# <backup-dir> holds what docs/flash.md pulled over adb root: p7.bin (boot), p8.bin (recovery),
# p14.bin (super) - or boot.bin/recovery.bin/super.bin. --super restores the Android 10 super
# rebuilt by scripts/build_rollback_super.sh instead of the unit's own dump, which is the cleaner
# path when the unit's dump is incomplete; the boot/recovery restore still uses the unit's dumps,
# because the installed firmware is not guaranteed byte-identical to the stock package.
#
# Nothing else is touched: no GPT write (**D11** means we never changed the table), no userdata.
set -eu
BACKUP=${1:?usage: fastboot_rollback.sh <backup-dir> [--super <img>] [--dry-run]}
SUPER=${2:-}
DRY=${3:-}
FB=$(command -v fastboot || true)
[ -n "$FB" ] || { echo "fastboot not installed (apt install android-tools-fastboot)"; exit 1; }
[ -d "$BACKUP" ] || { echo "no such backup dir: $BACKUP"; exit 1; }

boot=$(ls "$BACKUP"/p7.bin "$BACKUP"/boot.bin 2>/dev/null | head -1)
rec=$(ls "$BACKUP"/p8.bin "$BACKUP"/recovery.bin 2>/dev/null | head -1)
sup=$(ls "$BACKUP"/p14.bin "$BACKUP"/super.bin 2>/dev/null | head -1)
[ -n "$SUPER" ] && sup="$SUPER"
for pair in "boot=$boot" "recovery=$rec" "super=$sup"; do
  f=${pair#*=}
  [ -n "$f" ] || { echo "  ! missing ${pair%%=*} dump in $BACKUP${SUPER:+ (--super given but super dump absent)}"; exit 1; }
  echo "  ${pair%%=*} <- $f ($(stat -c %s "$f") B)"
done

size() {
  hex=$("$FB" getvar "partition-size:$1" 2>&1 | grep -oE "0x[0-9a-f]+" | head -1)
  [ -n "$hex" ] && echo "$((hex))"
}

echo "=== fastboot pre-flight ==="
"$FB" devices
"$FB" reboot bootloader >/dev/null 2>&1 || true
sleep 3
"$FB" devices | head -2
for pair in "super=$sup" "boot=$boot" "recovery=$rec"; do
  p=${pair%%=*}; f=${pair#*=}
  n=$(size "$p" || true)
  [ -n "$n" ] || { echo "  ! fastboot reports no partition-size:$p - cannot restore it here"; exit 1; }
  want=$(stat -c %s "$f")
  echo "  $p: partition $n B, dump $want B $([ "$want" -le "$n" ] && echo fits || echo TOO BIG)"
  [ "$want" -le "$n" ] || { echo "  ! $f is larger than the partition - wrong dump?"; exit 1; }
done

if [ "$DRY" = "--dry-run" ]; then echo "  dry run: would restore super, boot, recovery, then reboot"; exit 0; fi

echo "=== restoring (super first) ==="
"$FB" flash super    "$sup"
"$FB" flash boot     "$boot"
"$FB" flash recovery "$rec"
"$FB" reboot
echo "Android 10 restored. Data is untouched; the stock upgrade flow will re-flash from SD/USB if needed."
