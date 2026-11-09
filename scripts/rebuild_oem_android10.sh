#!/usr/bin/env bash
# Rebuild the OEM Android 10 restore payload from the vendor's April 2025 package (D31).
#
# This is the rollback payload: super-a10.img (Android 10 logical partitions inside super, OEM layout,
# nothing resized beyond the package's own dynamic_partitions_op_list) + boot-a10.img (the package's boot
# image). Verified afterwards with lpdump + debugfs, which is what makes it trustworthy without a device.
#
# Run on any machine with brotli, python3, img2simg and lpmake (the NAS build host has all of them; the
# workstation's NTFS mount corrupts sparse writes, so build on ext4 or on the NAS archive).
#
#   scripts/rebuild_oem_android10.sh <package.zip> <outdir>
#
# The stock partition layout is deliberately untouched (D19): the group name and the four partition sizes
# come straight out of dynamic_partitions_op_list, and only super + boot are ever written by a restore.
set -eu

PKG=${1:?usage: rebuild_oem_android10.sh <package.zip> <outdir>}
OUT=${2:?usage: rebuild_oem_android10.sh <package.zip> <outdir>}
HERE=$(cd "$(dirname "$0")/.." && pwd)

mkdir -p "$OUT/pkg" "$OUT/images" "$OUT/sparse"

echo "== extracting the package =="
unzip -o -q "$PKG" '*.new.dat.br' '*.transfer.list' 'boot.img' 'dynamic_partitions_op_list' -d "$OUT/pkg"

echo "== decoding the .br payloads =="
for f in "$OUT/pkg"/*.new.dat.br; do
  brotli -d -f "$f"
done

echo "== reassembling the partition images from the transfer lists =="
python3 "$HERE/tools/reassemble.py" --dir "$OUT/pkg" --out "$OUT/images"

echo "== making sparse inputs (lpmake reads sparse images) =="
for p in system vendor product odm; do
  img2simg "$OUT/images/$p.img" "$OUT/sparse/$p.sparse"
done

# Sizes come from the package itself, so a rebuild cannot drift away from the OEM layout.
group=$(awk '/add_group/ {print $2 "=" $3}' "$OUT/pkg/dynamic_partitions_op_list")
super_size=$(awk -v g="$group" 'BEGIN{ split(g, a, "="); print a[2] }')
meta=65536
slots=2

echo "== group $group ; super device size $super_size =="
opts=()
for p in system vendor product odm; do
  sz=$(awk -v part="$p" '/^resize/ { if ($2 == part) print $3 }' "$OUT/pkg/dynamic_partitions_op_list")
  opts+=(-p "$p:readonly:$sz:${group%%=*}" -i "$p=$OUT/sparse/$p.sparse")
done

lpmake -d "$super_size" -m "$meta" -s "$slots" -g "$group" -F "${opts[@]}" -o "$OUT/super-a10.img"
cp "$OUT/pkg/boot.img" "$OUT/boot-a10.img"

echo "== verifying =="
sha256sum "$OUT/super-a10.img" "$OUT/boot-a10.img" | tee "$OUT/rescue.sha256"
lpdump "$OUT/super-a10.img" | grep -E 'Name:|linear super|Maximum size|Metadata size|Size:'
# The real proof is reading a filesystem inside super: carve system and let debugfs open it.
sys_sec=$(lpdump "$OUT/super-a10.img" | awk '/Name: system/{f=1} f && /linear super/{print $4; exit}')
dd if="$OUT/super-a10.img" of="$OUT/system-slice.img" bs=512 "skip=$sys_sec" count=2490880 status=none
debugfs -R 'ls /' "$OUT/system-slice.img" 2>&1 | head -6
debugfs -R 'stat /system/build.prop' "$OUT/system-slice.img" 2>&1 | head -4
rm -f "$OUT/system-slice.img"

echo "== done: $OUT/super-a10.img + $OUT/boot-a10.img ; restore writes ONLY super + boot =="
