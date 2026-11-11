#!/usr/bin/env bash
# Read-only inspection of a Rockchip SD card: what layout does BootROM + miniloader + vendor u-boot accept?
# Use this on a card that is KNOWN to boot a Rockchip device, then mirror it. Writes nothing.
set -euo pipefail
DEV="${1:-/dev/sda}"
[ -b "$DEV" ] || { echo "abort: $DEV is not a block device"; exit 1; }
RM="$(cat /sys/block/$(basename "$DEV")/removable 2>/dev/null || echo 0)"
[ "$RM" = "1" ] || { echo "abort: $DEV is not removable (RM=$RM) - this tool is for cards only"; exit 1; }

echo "=== identity ==="
lsblk -o NAME,SIZE,RM,VENDOR,MODEL,TRAN,FSTYPE,MOUNTPOINTS "$DEV" | cut -c1-90
SECTORS="$(cat /sys/block/$(basename "$DEV")/size)"
echo "sectors=$SECTORS bytes=$((SECTORS * 512))"

sync
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true   # read media, not cache

echo "=== LBA 0..7 (MBR / GPT / parameter area) ==="
dd if="$DEV" bs=512 skip=0 count=8 status=none | od -Ad -tx1 -Ax | head -40

echo "=== sector 64 (ID block loader) ==="
dd if="$DEV" bs=512 skip=64 count=2 status=none | od -Ad -tx1 | head -6

echo "=== magic scan over first 256 MiB ==="
dd if="$DEV" bs=1M count=256 status=none 2>/dev/null \
  | grep -abo "RKFW\|RKAF\|RSAK\|RK33HH\|LOADER  \|ANDROID!\|AVB0\|SUPER\|PARI" \
  | head -25 | awk -F: '{printf "  byte %s (%s) magic %s\n", $1, $1/512, $2}'

echo "=== partition-name strings near the parameter block ==="
dd if="$DEV" bs=1M count=64 status=none 2>/dev/null \
  | tr -c '[:alnum:]_\n-' '\n' | grep -E "^(uboot|trust|misc|dtb|dtbo|vbmeta|boot|recovery|backup|security|cache|metadata|frp|super|userdata|baseparameter|parameter|bootloader)(_[ab])?$" \
  | sort | uniq -c | sort -rn | head -20 | sed 's/^/  /'

echo "=== partition table, as Windows/Linux see it ==="
fdisk -l "$DEV" 2>&1 | head -20
sgdisk -v "$DEV" 2>&1 | tail -8 || true
