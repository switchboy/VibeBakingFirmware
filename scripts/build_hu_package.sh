#!/usr/bin/env bash
# Assemble the update.zip the head unit's own upgrade flow installs (docs/flash.md).
#
#   scripts/build_hu_package.sh <lineage-tree> <stock-package-dir> <out-zip>
#
# The transport is deliberately the stock mechanism: an `update.zip` at the root of a FAT32 USB/SD
# stick, installed by the unit's existing recovery through its own update-binary. Nothing else is
# touched - no custom recovery (the mainboard's MCU firmware path may only be reachable from the
# stock recovery, and a recovery that cannot show a prompt or read a touch input would brick the
# unit), no uboot/trust/dtbo/RKLoader write, no GPT change, no partition-size change (**D11**: p14
# stays 3,263,168,512 B; only the *logical* partitions inside it are recreated).
#
# The updater-script speaks only the functions this update-binary implements - the same calls the
# stock package makes (update_dynamic_partitions, map_partition, block_image_update,
# package_extract_file, wipe_block_device) - and drops the stock script's bootloader writes and its
# `security` wipe.
set -eu
TREE=${1:?usage: build_hu_package.sh <lineage-tree> <stock-package-dir> <out-zip>}
STOCK=${2:?no stock package dir (use the extracted update.zip reference)}
OUT=${3:?usage: build_hu_package.sh <lineage-tree> <stock-package-dir> <out-zip>}
REPO=$(cd "$(dirname "$0")/.." && pwd)
PROD=$TREE/out/target/product/rk3399
[ -d "$PROD" ] || { echo "no built product dir: $PROD"; exit 1; }
[ -s "$STOCK/META-INF/com/google/android/update-binary" ] || { echo "no stock update-binary in $STOCK"; exit 1; }

# The payload needs ~2 GB of uncompressed .new.dat plus the compressed copies, so keep the scratch
# on the build host's data disk, not in the repo folder or sshd's small PrivateTmp /tmp.
SCRATCH=${SCRATCH:-/srv/dev-disk-by-label-SSData/aospbuild/tmp}
[ -d "$SCRATCH" ] || SCRATCH="${TMPDIR:-/tmp}"
WORK=$(mktemp -d "$SCRATCH/hupkg.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

echo "=== payload files ==="
python3 "$REPO/tools/gen_hu_payload.py" "$PROD" "$STOCK" "$WORK"

# The stock package ships `<part>.new.dat.br` (brotli) and the binary decompresses it. Same here:
# the images are ext4, so deflate gains nothing while brotli level 9 halves the zip size.
echo "=== compressing ==="
for p in system vendor product system_ext odm; do
  brotli -q 9 -f "$WORK/$p.new.dat" -o "$WORK/$p.new.dat.br"
  rm -f "$WORK/$p.new.dat"
  echo "  $p.new.dat.br $(stat -c %s "$WORK/$p.new.dat.br") B (was $(stat -c %s "$WORK/$p.transfer.list") B list)"
done

echo "=== updater-script ==="
{
  echo 'getprop("ro.product.device") == "rk3399" || abort("E3004: This package is for \"rk3399\" devices; this is a \"" + getprop("ro.product.device") + "\".");'
  echo 'ui_print("LineageOS 21 / Android 14 for the PX6 HU; layout unchanged, bootloader untouched");'
  echo 'show_progress(0.650000, 0);'
  echo ''
  echo '# Recreate the logical partitions inside super: same super partition, same group size, new'
  echo '# partition list (Android 14 adds system_ext) and new sizes. The GPT is never written.'
  echo 'assert(update_dynamic_partitions(package_extract_file("dynamic_partitions_op_list")));'
  echo ''
  for p in system vendor product system_ext odm; do
    echo "# Write $p"
    echo "ui_print(\"Writing $p image...\");"
    echo "show_progress(0.120000, 0);"
    echo "block_image_update(map_partition(\"$p\"), package_extract_file(\"$p.transfer.list\"), \"$p.new.dat.br\", \"$p.patch.dat\") ||"
    echo "  abort(\"E2001: Failed to write the $p image.\");"
    echo ''
  done
  echo 'show_progress(0.050000, 5);'
  echo 'ui_print("Writing boot image (Android 14 kernel + ramdisk + vendor DTB)...");'
  echo 'package_extract_file("boot.img", "/dev/block/by-name/boot");'
  echo ''
  # Android 14 cannot use Android 10's /data: the framework, vold metadata and the app data are all
  # incompatible. Zeroing the start of userdata makes the fs unrecognisable, so init/vold format it
  # on first boot (factory settings, accepted for v1 - D10). The partition itself is not resized.
  echo 'ui_print("Wiping userdata so Android 14 formats it fresh...");'
  echo 'wipe_block_device("/dev/block/by-name/userdata", 8388608);'
  echo 'wipe_block_device("/dev/block/by-name/cache", 8388608);'
  echo ''
  echo '# NOT done, on purpose: no recovery write (stock recovery stays able to flash the mainboard'
  echo '# MCU firmware and to show its own install prompt), no uboot/trust/dtbo/RKLoader write, no'
  echo '# write_raw_loader_image(), no wipe of /dev/block/by-name/security, no GPT write.'
  echo 'set_progress(1.000000);'
} > "$WORK/META-INF_dummy"
mkdir -p "$WORK/META-INF/com/google/android"
mv "$WORK/META-INF_dummy" "$WORK/META-INF/com/google/android/updater-script"

cp -a "$STOCK/META-INF/com/google/android/update-binary" "$WORK/META-INF/com/google/android/update-binary"
chmod 0755 "$WORK/META-INF/com/google/android/update-binary"

# The stock script stays *next to* the payload, not inside it: the zip is what the unit reads, and a
# stray file in it is only noise. Keeping the stock script beside the output is how a diff of the two
# packages is read later (what we removed: uboot/trust/dtbo writes, write_raw_loader_image(), the
# `security` wipe).
cp -a "$STOCK/META-INF/com/google/android/updater-script" "$OUT.stock-updater-script" 2>/dev/null || true

echo "=== zipping ==="
rm -f "$OUT"
# Store, not deflate: the payload files are already brotli-compressed, and this zip is read by the
# unit's updater from a USB stick, where re-compressing only costs time.
( cd "$WORK" && zip -r -X -0 -q "$OUT" . )
echo "  $OUT $(stat -c %s "$OUT") B"
sha256sum "$OUT" | sed 's/^/  sha256 /'
echo "=== contents ==="
unzip -l "$OUT" | tail -20
