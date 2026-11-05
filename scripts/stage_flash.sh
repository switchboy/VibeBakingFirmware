#!/usr/bin/env bash
# Collect the first-flash images into one folder with checksums, ready for `adb push`.
#
#   scripts/stage_flash.sh <lineage-tree-or-image-dir> <outdir>
#
# Run it on the machine that talks to the unit in Boot-ADB mode. Size limits are checked against the
# unit's real partitions (analysis/hu_partition_offsets.txt) so an oversized image is caught here
# instead of as a half-written partition on the eMMC.
set -eu
SRC=${1:?usage: stage_flash.sh <tree or image dir> <outdir>}
OUT=${2:?usage: stage_flash.sh <tree or image dir> <outdir>}
REPO=$(cd "$(dirname "$0")/.." && pwd)

if [ -d "$SRC/out/target/product/rk3399" ]; then SRC="$SRC/out/target/product/rk3399"; fi
[ -d "$SRC" ] || { echo "no such directory: $SRC"; exit 1; }

mkdir -p "$OUT"
for f in super.img boot.img recovery.img; do
  [ -s "$SRC/$f" ] || { echo "  ! missing or empty: $SRC/$f"; exit 1; }
  cp -a "$SRC/$f" "$OUT/"
done

# super.img comes out of the build in Android's sparse format (magic 0xED26FF3A, stored little-endian
# so the first four bytes read 3a ff 26 ed). Boot-ADB's `dd` does not understand that - it would
# write the sparse header onto the eMMC - so convert it to a raw image here. boot.img/recovery.img
# are already raw (they start with "ANDROID!").
if [ "$(head -c 4 "$OUT/super.img" | od -An -tx1 | tr -d ' \n')" = "3aff26ed" ]; then
  if ! command -v simg2img >/dev/null 2>&1; then
    echo "  ! super.img is sparse but simg2img is not installed here (apt install android-simg2img,"
    echo "    or run the conversion on the NAS: out/host/linux-x86/bin/simg2img)"
    exit 1
  fi
  simg2img "$OUT/super.img" "$OUT/super_raw.img"
  rm -f "$OUT/super.img"
  mv "$OUT/super_raw.img" "$OUT/super.img"
  echo "  converted super.img to raw format ($(stat -c %s "$OUT/super.img") bytes)"
fi

# Limits from the probe (512-byte LBAs). The by-name partition is looked up by its current device
# node: boot=p7 32 MiB, recovery=p8 96 MiB, super=p14 3,263,168,512 B. Those numbers change after a
# repartition, which is why this reads the offsets file rather than trusting the defaults.
OFF="$REPO/analysis/hu_partition_offsets.txt"
limit() {  # $1 = partition name, $2 = fallback bytes
  local dev
  case "$1" in
    boot) dev=mmcblk2p7 ;;
    recovery) dev=mmcblk2p8 ;;
    super) dev=mmcblk2p14 ;;
    *) echo "$2"; return ;;
  esac
  local v=""
  if [ -f "$OFF" ]; then v=$(awk -v d="$dev" '$1==d { print ($3-$2+1)*512 }' "$OFF" | head -1); fi
  [ -n "$v" ] && echo "$v" || echo "$2"
}
boot_max=$(limit boot 33554432); rec_max=$(limit recovery 100663296); super_max=$(limit super 3263168512)
for pair in "boot.img $boot_max" "recovery.img $rec_max" "super.img $super_max"; do
  set -- $pair
  size=$(stat -c %s "$OUT/$1")
  if [ "$size" -gt "$2" ]; then
    echo "  ! $1 is $size bytes, partition limit $2 - do not flash it"
    exit 1
  fi
  echo "  ok $1 $size <= $2"
done

(cd "$OUT" && sha256sum super.img boot.img recovery.img > sha256sums.txt)
echo "staged in $OUT:"
ls -l "$OUT"
echo
echo "push these from the Boot-ADB session (docs/flash.md):"
echo "  adb push $OUT/super.img $OUT/boot.img $OUT/recovery.img /tmp/"
