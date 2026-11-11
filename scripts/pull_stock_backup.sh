#!/usr/bin/env bash
# Pull a byte-exact backup of the working stock eMMC over TCP adb (D40). READ-ONLY on the unit: it only
# reads partitions. The backup is what makes the next Android 14 attempt reversible.
#
#   scripts/pull_stock_backup.sh [outdir]        default /var/tmp/hu-stock-backup
#
# Requires adb connected (adb connect <hu-ip>:5555, then adb root). Refuses if adb is not root or if the
# build is not the stock OEM A10 build, so it cannot silently "back up" a bricked state.
set -euo pipefail

OUT="${1:-/var/tmp/hu-stock-backup}"
DISK=/dev/block/mmcblk2
mkdir -p "$OUT"

adb get-state >/dev/null || { echo "abort: no adb device"; exit 1; }
adb shell id 2>/dev/null | grep -q 'uid=0' || { echo "abort: adb shell is not root - run adb root first"; exit 1; }
FP="$(adb shell getprop ro.build.fingerprint 2>/dev/null | tr -d '\r')"
case "$FP" in
  *QQ2A.200305.004.A1*) : ;;
  *) echo "abort: build is not stock OEM A10 ($FP) - this backup must be taken on the known-good firmware"; exit 1 ;;
esac

pull() {  # pull <block-device-path> <outfile>
  local src="$1" dst="$2"
  local size
  size="$(adb shell blockdev --getsize64 "$src" 2>/dev/null | tr -d '\r')"
  [ -n "$size" ] || { echo "abort: cannot size $src"; exit 1; }
  adb exec-out dd if="$src" bs=4096 count="$(( (size + 4095) / 4096 ))" status=none > "$dst"
  printf "  %-16s %12s B  %s\n" "$(basename "$dst")" "$size" "$(sha256sum "$dst" | cut -c1-12)"
}

echo "stock backup of $DISK -> $OUT"
# head: ID block loader area + partition table (first 8 MB), tail: backup GPT (last 34 sectors)
adb exec-out dd if="$DISK" bs=4096 count=2048 status=none  > "$OUT/disk-head-8mb.bin"
adb exec-out dd if="$DISK" bs=512 skip="$(( $(adb shell blockdev --getsize64 "$DISK" | tr -d '\r') / 512 - 34 ))" count=34 status=none > "$OUT/disk-tail-gpt.bin"
printf "  %-16s %12s B  %s\n" "disk-head-8mb.bin" "$(stat -c %s "$OUT/disk-head-8mb.bin")" "$(sha256sum "$OUT/disk-head-8mb.bin" | cut -c1-12)"
printf "  %-16s %12s B  %s\n" "disk-tail-gpt.bin" "$(stat -c %s "$OUT/disk-tail-gpt.bin")" "$(sha256sum "$OUT/disk-tail-gpt.bin" | cut -c1-12)"

for p in uboot trust misc dtb dtbo vbmeta boot recovery security metadata frp super; do
  pull "/dev/block/by-name/$p" "$OUT/$p.bin"
done

adb shell "blkid; cat /proc/cmdline" > "$OUT/blkid-and-boot-cmdline.txt" 2>/dev/null || true
adb shell "getprop | grep -E 'internet_adb|avb|vbmeta|boot_devices'" > "$OUT/props.txt" 2>/dev/null || true
adb shell ls -l /dev/block/by-name > "$OUT/by-name.txt" 2>/dev/null || true

sha256sum "$OUT"/*.bin > "$OUT/MANIFEST.sha256"
echo "manifest: $OUT/MANIFEST.sha256 ($(wc -l < "$OUT/MANIFEST.sha256") files)"
echo "total: $(du -sh "$OUT" | cut -f1)"
