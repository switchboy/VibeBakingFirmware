#!/usr/bin/env bash
# Assemble the USB stick for scripts/flash_from_android.sh (**D25**, docs/flash.md).
#
#   scripts/make_flash_stick.sh <stick-mountpoint> [stock-a10-zip] [stock-a11-zip]
#
# The stick must be FAT32 (the unit's recovery and its Android 11 storage stack only read FAT32/exFAT
# sticks, and FAT32 takes single files up to 4 GB - our super.img is ~2.3 GB). Layout:
#
#   /hu14/super.img boot.img flash.sh sha256.txt     the Android 14 payload, flashed from Android 11
#   /backup/a10-update.zip a11-update.zip            the stock packages (rollback, optional)
#
# Deliberately no `update.zip` at the stick root: some Dasaita/HCT firmware offers an automatic
# "firmware update" when it finds update.zip, so the rollback package is only renamed to update.zip
# when a rollback is actually wanted.
set -eu
MNT=${1:?usage: make_flash_stick.sh <stick-mountpoint> [stock-a10-zip] [stock-a11-zip]}
REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT=$REPO/out-hu

for f in super.img boot.img; do
  [ -s "$OUT/$f" ] || { echo "missing $OUT/$f (copy it from the build host: out/target/product/rk3399/)"; exit 1; }
done
[ -d "$MNT" ] || { echo "not a directory: $MNT"; exit 1; }

mkdir -p "$MNT/hu14"
cp -a "$OUT/super.img" "$OUT/boot.img" "$MNT/hu14/"
cp -a "$REPO/scripts/flash_from_android.sh" "$MNT/hu14/flash.sh"

# Manifest with plain file names: flash_from_android.sh resolves each name against /mnt/udisk/hu14.
( cd "$MNT/hu14" && sha256sum super.img boot.img flash.sh > sha256.txt )

if [ "${2:-}" ] && [ -s "$2" ]; then
  mkdir -p "$MNT/backup"
  cp -a "$2" "$MNT/backup/a10-update.zip"
  [ "${3:-}" ] && [ -s "$3" ] && cp -a "$3" "$MNT/backup/a11-update.zip"
fi

echo "stick layout in $MNT:"
ls -l "$MNT/hu14"
[ -d "$MNT/backup" ] && ls -l "$MNT/backup"
echo "manifest:"
cat "$MNT/hu14/sha256.txt"
echo "free space: $(df -h "$MNT" | tail -1 | awk '{print $4}')"
echo "on the unit: /system/xbin/su 0 sh /mnt/udisk/hu14/flash.sh   (then recovery -> wipe data/factory reset)"
