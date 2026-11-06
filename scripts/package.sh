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

# PRODUCT_COPY_FILES destinations that collide with a *legacy Make* module's install rule never
# show up in out/soong/installs-*.mk - only Soong writes that file - so ckati is the only thing
# that reveals them (rild is such a module: "previously defined at build/make/core/base_rules.mk:
# 497"). A parse takes ~1.5 min with Soong's cache warm, so reveal-and-retry converges fast:
# append the revealed destination to vendor_build_wins.txt, regenerate the copy list, deploy, retry.
DEVMK=$REPO/device/rk3399-px6-hct4
regen_staging() {
  # cwd is $TREE here (m runs from the build tree), so use absolute paths for the repo scripts.
  python3 "$REPO/tools/gen_vendor_staging.py" "$TREE/vendor/hct4/tree/vendor" "$DEVMK" \
    --src-prefix vendor/hct4/tree/vendor \
    --build-prop "$TREE/vendor/hct4/prebuilt/vendor_build.prop.a11" \
    --compat-matrix "$TREE/vendor/hct4/prebuilt/vendor_compat_matrix.a11.xml" \
    --skip-file "$DEVMK/vendor_props_skip.txt" \
    --dest-skip "$DEVMK/vendor_build_wins.txt" >> "$LOG" 2>&1 || return 1
  "$REPO/scripts/deploy_device.sh" "$TREE" >> "$LOG" 2>&1 || return 1
}

m_retry() {
  target=$1 ; tries=0
  while :; do
    # Only the output this attempt produced may be interpreted as a collision. Grepping the whole
    # log would re-read an earlier attempt's "overriding commands" line after an unrelated failure
    # (pack18 hit that: the ninja fstab error was treated as a collision, burned 12 regenerations
    # and ~75 min), so remember where the log ended before `m`.
    start=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
    if run "$target"; then return 0; fi
    # `overriding commands for target \`out/target/product/rk3399/vendor/<rel>'` -> <rel>
    bad=$(tail -c +"$((start + 1))" "$LOG" |
          grep -o "overriding commands for target \`out/target/product/rk3399/vendor/[^']*" |
          tail -1 | sed 's|.*rk3399/vendor/||')
    [ -n "$bad" ] || { echo "attempt of '$target' failed for a non-collision reason at $(date)" >> "$LOG"; return 1; }
    tries=$((tries + 1))
    if [ "$tries" -gt 12 ]; then echo "too many install collisions at $(date)" >> "$LOG"; return 1; fi
    grep -qxF "$bad" "$DEVMK/vendor_build_wins.txt" || \
      printf '# revealed by ckati: a legacy Make module installs this path, so it is not in\n# out/soong/installs-*.mk. Android 14 builds it; the staged blob must not be copied.\n%s\n' "$bad" \
        >> "$DEVMK/vendor_build_wins.txt"
    # durable: survives a fresh sync, so the next host converges without re-discovering it
    grep -qxF "$bad" "$DEVMK/vendor_dest_skip_extra.txt" || printf '%s\n' "$bad" >> "$DEVMK/vendor_dest_skip_extra.txt"
    echo "=== install collision #$tries: vendor/$bad -> dropped, staging regenerated at $(date) ===" >> "$LOG"
    regen_staging || { echo "regen_staging failed at $(date)" >> "$LOG"; return 1; }
  done
}

m_retry bootimage   || { echo "PACKAGING STOPPED on bootimage" >> "$LOG"; exit 1; }
m_retry recoveryimage || { echo "PACKAGING STOPPED on recoveryimage" >> "$LOG"; exit 1; }

# dist builds the target_files package (including IMAGES/) and tries the OTA package. With vendor
# staged from blobs (D15) the dist pass should now produce a VENDOR/ directory; if it does not, the
# OTA step will assert on the missing BlockDifference, so check it here rather than deep in ninja.
if ! m_retry dist; then
  echo "dist failed - continuing; IMAGES/ is usually complete by the time the OTA step runs" >> "$LOG"
fi
STAGE=$TREE/out/target/product/rk3399/obj/PACKAGING/target_files_intermediates/lineage_rk3399-target_files
{
  echo "--- vendor staging check ---"
  grep -n "building_vendor_image\|building_odm_image\|building_system_ext_image" \
    "$TREE/out/target/product/rk3399/misc_info.txt" 2>/dev/null
  if [ -d "$STAGE/VENDOR" ]; then
    echo "  VENDOR/ staged: $(find "$STAGE/VENDOR" -type f | wc -l) files, $(du -sh "$STAGE/VENDOR" | cut -f1)"
    echo "  vendor.map: $([ -f "$STAGE/IMAGES/vendor.map" ] && stat -c %s "$STAGE/IMAGES/vendor.map" || echo "missing")"
  else
    echo "  ! no VENDOR/ directory in the target_files staging tree - otapackage will assert"
  fi
} >> "$LOG" 2>&1

# Stage super from the IMAGES that dist just wrote, then check they really are fresh.
if ! m_retry superimage; then echo "PACKAGING STOPPED on superimage" >> "$LOG"; exit 1; fi
IMAGES=$TREE/out/target/product/rk3399/obj/PACKAGING/target_files_intermediates/lineage_rk3399-target_files/IMAGES
if [ -f "$IMAGES/system.img" ] && [ "$(stat -c %Y "$IMAGES/system.img")" -lt "$START" ]; then
  echo "  ! WARNING: $IMAGES/system.img predates this pass - super would embed stale images" >> "$LOG"
fi

m_retry otapackage

# LineageOS's dist flow also emits debug/symbol and proguard packages we never use. They are the
# largest files in out/dist and the SSD is tight, so drop them (they are regenerated on demand).
if [ -d "$TREE/out/dist" ]; then
  echo "--- pruning unused dist packages ---" >> "$LOG"
  for z in "*-symbols.zip" "*-symbols-root.zip" "*-img.zip" "*-img-root.zip" \
           "*-proguard-dict*.zip" "*-proguard-usage*.zip" \
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
