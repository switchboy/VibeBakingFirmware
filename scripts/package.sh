#!/bin/bash
# Packaging pass on the NAS: device tree + vendor, boot/recovery images, dist, super, OTA zip.
# No big compiles here, so the docker fleet stays up and we use -j4 (owner's daytime policy).
#
#   systemd-run --unit=los-packN --working-directory=/srv/.../lineage21s \
#     /srv/.../aospbuild/VibeBakingFirmware/scripts/package.sh
#
# Order matters: `m dist` runs add_img_to_target_files, which (re)builds IMAGES/ inside the
# target_files staging dir; `m superimage` then stages super from those fresh images. Running
# superimage first embeds the previous pass's images, which is why the offline content check
# reported embedded_matches=False. `m dist` failing on the OTA step is not fatal: the images it
# builds are what we need, and otapackage gets its own attempt afterwards.
set -o pipefail
export HOME=/tmp          # Soong's sbox mounts / read-only; repo's `manifest -r` writes $HOME/.repo_.gitconfig.json
export GOCACHE=/srv/dev-disk-by-label-SSData/aospbuild/.gocache
export TMPDIR=/srv/dev-disk-by-label-SSData/aospbuild/tmp   # the OTA flow needs several GB of temp space
mkdir -p "$GOCACHE" "$TMPDIR"
A=/srv/dev-disk-by-label-SSData/aospbuild
TREE=$A/lineage21s
REPO=$A/VibeBakingFirmware
LOG=$TREE/package.log

cd "$TREE"
: > "$LOG"

{
  echo "=== envsetup+lunch at $(date) ==="
  source build/envsetup.sh
  lunch lineage_rk3399-ap2a-userdebug
  echo "TARGET_PRODUCT=$TARGET_PRODUCT TARGET_RELEASE=$TARGET_RELEASE TARGET_VARIANT=$TARGET_BUILD_VARIANT"
  df -h "$A" | tail -1
  free -m | sed -n 2p
} >> "$LOG" 2>&1
if [ "$TARGET_PRODUCT" != "lineage_rk3399" ]; then echo "lunch failed at $(date)" >> "$LOG"; exit 1; fi

# Order: tree patches, then the vendor staging, then the device deploy. prebuilt_vendor.sh runs
# tools/gen_vendor_staging.py, which writes vendor_staging.mk / vendor_props.mk into the repo's
# device folder, and deploy_device.sh is what copies those into the build tree.
cd "$REPO"
./scripts/apply_tree_patches.sh ../lineage21s >> "$LOG" 2>&1 || { echo "apply_tree_patches failed at $(date)" >> "$LOG"; exit 1; }

# The firmware zip is only needed the first time; afterwards the extracted reference image and
# kernel in vendor/hct4/prebuilt/ are reused (it is ~1 GB, so re-unpacking every pass is waste).
ZIPARG=""
for z in "$A/daisaita_a11.zip" "$REPO/../diatsia fw/update.zip"; do
  if [ -s "$z" ]; then ZIPARG="$z"; break; fi
done
./scripts/prebuilt_vendor.sh "$ZIPARG" ../lineage21s >> "$LOG" 2>&1 || { echo "prebuilt_vendor failed at $(date)" >> "$LOG"; exit 1; }
./scripts/deploy_device.sh ../lineage21s >> "$LOG" 2>&1 || { echo "deploy_device failed at $(date)" >> "$LOG"; exit 1; }

cd "$TREE"
START=$(date +%s)

run() {
  echo "=== m $1 -j4 at $(date) ===" >> "$LOG"
  m "$1" -j4 >> "$LOG" 2>&1
  rc=$?
  echo "=== m $1 rc=$rc at $(date) ===" >> "$LOG"
  return $rc
}

run bootimage   || { echo "PACKAGING STOPPED on bootimage" >> "$LOG"; exit 1; }
run recoveryimage || { echo "PACKAGING STOPPED on recoveryimage" >> "$LOG"; exit 1; }

# dist builds the target_files package (including IMAGES/) and tries the OTA package. Its OTA step
# currently fails because a prebuilt vendor image produces no VENDOR/ staging directory.
if ! run dist; then
  echo "dist failed - continuing; IMAGES/ is usually complete by the time the OTA step runs" >> "$LOG"
fi

# Stage super from the IMAGES that dist just wrote, then check they really are fresh.
if ! run superimage; then echo "PACKAGING STOPPED on superimage" >> "$LOG"; exit 1; fi
IMAGES=$TREE/out/target/product/rk3399/obj/PACKAGING/target_files_intermediates/lineage_rk3399-target_files/IMAGES
if [ -f "$IMAGES/system.img" ] && [ "$(stat -c %Y "$IMAGES/system.img")" -lt "$START" ]; then
  echo "  ! WARNING: $IMAGES/system.img predates this pass - super would embed stale images" >> "$LOG"
fi

run otapackage

# LineageOS's dist flow also emits debug/symbol and proguard packages we never use. They are the
# largest files in out/dist and the SSD is tight, so drop them (they are regenerated on demand).
if [ -d "$TREE/out/dist" ]; then
  echo "--- pruning unused dist packages ---" >> "$LOG"
  for z in "*-symbols.zip" "*-img.zip" "*-proguard-dict*.zip" "*-proguard-usage*.zip" \
           art_release.zip dexpreopt_tools.zip dexpreopt_config.zip system_server.zip appcompat.zip; do
    find "$TREE/out/dist" -maxdepth 1 -name "$z" -print -delete >> "$LOG" 2>&1
  done
fi

echo "--- produced ---" >> "$LOG"
{
  ls -l "$TREE"/out/target/product/rk3399/*.img 2>/dev/null
  ls -l "$TREE"/out/dist 2>/dev/null | head -20
  ls -l "$TREE"/out/target/product/rk3399/*.zip 2>/dev/null
  echo "--- misc_info boot/recovery lines ---"
  grep -n "boot_size\|boot_images\|recovery_size\|blocksize\|no_boot\|ab_update\|super_partition\|dynamic_partitions" \
    "$TREE"/out/target/product/rk3399/misc_info.txt 2>/dev/null
  echo "--- OTA sha256 ---"
  sha256sum "$TREE"/out/target/product/rk3399/lineage_rk3399-ota.zip 2>/dev/null
  df -h "$A" | tail -1
} >> "$LOG" 2>&1
echo "=== done at $(date) ===" >> "$LOG"
