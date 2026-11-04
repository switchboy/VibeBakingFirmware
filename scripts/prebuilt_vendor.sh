#!/usr/bin/env bash
# Build the prebuilt vendor image for the PX6 HU from the Daisaita Android 11 package.
#
#   scripts/prebuilt_vendor.sh "../diatsia fw/update.zip" /srv/.../lineage21
#
# Needs root on the build host (loop-mount). Run it on the build host, not on the unit.
# The blobs stay byte-identical; only our HU files are overlaid, and Rockchip's patched-init
# `insmod` lines are stripped so LineageOS init can parse the rc files.
set -eu

ZIP=${1:?usage: prebuilt_vendor.sh <update.zip> <lineage-tree>}
TREE=${2:?usage: prebuilt_vendor.sh <update.zip> <lineage-tree>}
REPO=$(cd "$(dirname "$0")/.." && pwd)
DEV="$REPO/device/rk3399-px6-hct4"
OUT="$TREE/vendor/hct4"
# Work inside the build volume: the vendor payload is ~260 MB and the host's /tmp may be
# a size-limited tmpfs.
WORK=$(mktemp -d "$TREE/.vendor-work.XXXXXX")
trap 'umount "$WORK/mnt" 2>/dev/null || true; rm -rf "$WORK"' EXIT

unzip -qo "$ZIP" -d "$WORK"
if [ -f "$WORK/vendor.new.dat.br" ]; then
    brotli -d -f "$WORK/vendor.new.dat.br" -o "$WORK/vendor.new.dat"
fi
python3 "$REPO/tools/reassemble.py" --dir "$WORK" --out "$WORK/images" --partition vendor

mkdir -p "$OUT/prebuilt" "$OUT/tree"
cp "$WORK/images/vendor.img" "$OUT/prebuilt/vendor_a11.img"

# The kernel that matches this vendor tree's module vermagic (4.19.193 #24).
python3 - "$WORK/boot.img" "$OUT/prebuilt/kernel_a11" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
page = struct.unpack_from("<I", d, 56)[0] or 2048
ksize = struct.unpack_from("<I", d, 8)[0]
open(sys.argv[2], "wb").write(d[page:page + ksize])
PY

python3 "$REPO/tools/extract_vendor.py" "$WORK/images/vendor.img" "$OUT/tree" >/dev/null

# Overlay onto a working copy of the image so the vendor blobs are untouched.
IMG="$OUT/vendor.img"
cp "$WORK/images/vendor.img" "$IMG"
# The vendor image is 99.7% full: extend the file and grow the filesystem offline, otherwise
# copying our own fstab/init files into it fails with ENOSPC. 32 MiB headroom, block-aligned.
ORIG=$(stat -c %s "$IMG")
truncate -s $(( ORIG + 32 * 1024 * 1024 )) "$IMG"
resize2fs "$IMG"
mkdir -p "$WORK/mnt"
mount -o rw "$IMG" "$WORK/mnt"
cp "$DEV/fstab.rk30board"            "$WORK/mnt/etc/fstab.rk30board"
cp "$DEV/configs/ueventd.rk30board.rc" "$WORK/mnt/etc/ueventd.rc"
cp "$DEV/configs/init.hu.rc"         "$WORK/mnt/etc/init/hu.rc"
cp "$DEV/configs/hu_insmod.sh"       "$WORK/mnt/etc/hu_insmod.sh"
chmod 0755 "$WORK/mnt/etc/hu_insmod.sh"
sed -i '/^[[:space:]]*insmod /d' "$WORK/mnt/etc/init/hw/init.rockchip.rc"
umount "$WORK/mnt"

echo "vendor image: $IMG"
echo "kernel:       $OUT/prebuilt/kernel_a11"
