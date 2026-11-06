#!/bin/bash
# Packaging pass on the NAS: device tree + vendor, boot/recovery images, dist, super, OTA zip.
# The job count follows the owner's policy (see the block below): -j4 with the whole docker fleet up
# during the day, -j12 at night with the containers stopped except Pi-hole/Home Assistant. Requesting
# Android 14's vendor variants (D20) makes this a real compile too - libchrome is built for both
# arches - so the hour decides how much of the fleet stays running.
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
DEVMK=$REPO/device/rk3399-px6-hct4      # generated files (vendor_staging.mk, vendor_modules_extra.mk)
LOG=$TREE/package.log

# The owner's build policy (docs/build-host.md "Memory ceiling"): the NAS has 24 GB RAM and docker holds
# ~12 GB, so the job count depends on the hour.
#   daytime   07:00-22:00: leave the whole fleet running, build -j4 (slow, services stay up)
#   night     22:00-07:00: stop every container except Pi-hole and Home Assistant, build -j12
# Stopped containers are recorded and restarted on exit, failure included. Pi-hole stays up because it
# is this workstation's DNS.
JOBS=4
H=$(date +%H)
if [ "$H" -lt 7 ] || [ "$H" -ge 22 ]; then
  JOBS=12
  KEEP='pi-hole|pihole|homeassistant|home-assistant'
  STOPPED=$A/docker_stopped.txt
  : > "$STOPPED"
  restore_docker() {
    while read -r c; do
      [ -n "$c" ] && docker start "$c" >> "$LOG" 2>&1
    done < "$STOPPED"
    echo "=== docker restarted: $(wc -l < "$STOPPED") container(s) at $(date) ===" >> "$LOG"
  }
  trap restore_docker EXIT
  echo "=== night policy: -j$JOBS, stopping docker except Pi-hole/Home Assistant at $(date) ===" >> "$LOG"
  for c in $(docker ps --format '{{.Names}}'); do
    if printf '%s' "$c" | grep -qiE "$KEEP"; then continue; fi
    if docker stop "$c" >> "$LOG" 2>&1; then echo "$c" >> "$STOPPED"; fi
  done
  echo "  docker still running: $(docker ps -q | wc -l)" >> "$LOG"
fi

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

# ---- what /vendor has to contain -----------------------------------------------
# tools/vendor_link_closure.py walks the DT_NEEDED graph of the kept vendor blobs and writes two
# generated files into the repo's device folder (deploy_device.sh copies them into the tree):
#   vendor_modules_extra.mk  Android 14's *vendor variant* modules to request. device.mk -includes it,
#                            so Soong installs e.g. /vendor/lib64/android.hardware.wifi@1.4.so. That
#                            is the preferred route: Android 14's own ABI, and an install dep, which is
#                            what build_image.py's file filter is generated from.
#   vendor_dest_keep.txt     the leftovers with no vendor variant module and no public-liberty -
#                            injected into the staging dir by scripts/inject_vendor_blobs.sh.
# It reads the previous pass's vendor.img and out/soong/module-info-*.json, so on a cold tree it has
# nothing to say; the pass after a build is the one that converges.
echo "=== vendor link closure ===" >> "$LOG"
"$REPO/tools/vendor_link_closure.py" "$TREE" "$DEVMK" >> "$LOG" 2>&1 \
  || echo "  ! closure left unresolved sonames (see the report above)" >> "$LOG"

./scripts/deploy_device.sh ../lineage21s >> "$LOG" 2>&1 || { echo "deploy_device failed at $(date)" >> "$LOG"; exit 1; }

cd "$TREE"
START=$(date +%s)

run() {
  echo "=== m $1 -j$JOBS at $(date) ===" >> "$LOG"
  m "$1" -j"$JOBS" >> "$LOG" 2>&1
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

# LineageOS's dist flow also emits debug/symbol and proguard packages we never use. They are the
# largest files in out/dist (symbols-root and img-root are ~2 GB each) and the SSD is tight, so drop
# them - they are regenerated on demand. Called right after the dist attempt as well as at the end:
# a failing dist still writes those zips, and the disk has ~20 GB free while super/OTA need room.
prune_dist() {
  # LineageOS's dist flow writes these both into out/dist/ and into the product dir.
  for d in "$TREE/out/dist" "$TREE/out/target/product/rk3399"; do
    [ -d "$d" ] || continue
    echo "--- pruning unused dist packages from $d ---" >> "$LOG"
    for z in "*-symbols.zip" "*-symbols-root.zip" "*-img.zip" "*-img-root.zip" \
             "*-proguard-dict*.zip" "*-proguard-usage*.zip" \
             art_release.zip dexpreopt_tools.zip dexpreopt_config.zip system_server.zip appcompat.zip; do
      find "$d" -maxdepth 1 -name "$z" -print -delete >> "$LOG" 2>&1
    done
  done
  df -h "$A" | tail -1 >> "$LOG"
}

m_retry bootimage   || { echo "PACKAGING STOPPED on bootimage" >> "$LOG"; exit 1; }
m_retry recoveryimage || { echo "PACKAGING STOPPED on recoveryimage" >> "$LOG"; exit 1; }

# The leftovers: libraries Android 14 has no vendor variant for and that are not public libraries. On
# a converged tree vendor_dest_keep.txt is absent, and this says so and exits 0.
echo "=== injecting the vendor libraries no module installs ===" >> "$LOG"
"$REPO/scripts/inject_vendor_blobs.sh" "$TREE" "$DEVMK" >> "$LOG" 2>&1 \
  || { echo "PACKAGING STOPPED on inject_vendor_blobs" >> "$LOG"; exit 1; }

# dist builds the target_files package (including IMAGES/) and tries the OTA package. With vendor
# staged from blobs (D15) the dist pass should now produce a VENDOR/ directory; if it does not, the
# OTA step will assert on the missing BlockDifference, so check it here rather than deep in ninja.
if ! m_retry dist; then
  echo "dist failed - continuing; IMAGES/ is usually complete by the time the OTA step runs" >> "$LOG"
fi
prune_dist
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

# Re-run the closure now that dist has installed whatever device.mk asked for, and check the ABI of
# the blobs that stay byte-for-byte copies: an Android 11 HAL whose symbols Android 14's libraries no
# longer export would fail to dlopen at boot (`dlopen failed: cannot locate symbol ...`), which no
# amount of partition checking would reveal. Both are reported, not fatal - a gap is a decision, not a
# build error.
echo "=== closure after dist ===" >> "$LOG"
"$REPO/tools/vendor_link_closure.py" "$TREE" "$DEVMK" >> "$LOG" 2>&1 \
  || echo "  ! closure left unresolved sonames (see the report above)" >> "$LOG"
echo "=== vendor ABI check (kept blobs vs Android 14's symbols) ===" >> "$LOG"
python3 "$REPO/tools/vendor_abi_check.py" "$TREE" "$DEVMK" >> "$LOG" 2>&1 \
  || echo "  ! at least one kept blob has unresolved symbols (see the report above)" >> "$LOG"

# Injected files are not install dependencies, so Make's file filter excludes them and the *product*
# vendor.img omits them (pack25: product vendor.img 412,073,984 B without libchrome.so, dist's
# IMAGES/vendor.img 460,693,504 B with it). dist's image is built from VENDOR/, a copy of the staging
# directory, so when the keep list is non-empty we take it; when nothing is injected, ninja's own
# vendor.img is authoritative.
sync_vendor_image() {
  local prod="$TREE/out/target/product/rk3399/vendor.img" imv="$STAGE/IMAGES/vendor.img"
  local keep="$DEVMK/vendor_dest_keep.txt" need=""
  if [ -s "$keep" ]; then
    need=$(sed 's|#.*||' "$keep" | awk -F'\t' '$1 != "" { print $1 }')
  fi
  if [ -z "$need" ]; then
    echo "  nothing injected -> ninja's own vendor.img is authoritative ($(stat -c %s "$prod") B)" >> "$LOG"
    return 0
  fi
  [ -s "$imv" ] || { echo "  ! no dist IMAGES/vendor.img to sync from" >> "$LOG"; return 1; }
  # Android sparse magic 0xED26FF3A is stored little-endian, so it reads 3a ff 26 ed; debugfs cannot
  # read a sparse image at all, so convert both before comparing.
  local prod_raw="$TMPDIR/vendor_prod_raw.img" dist_raw="$TMPDIR/vendor_dist_raw.img"
  for pair in "$prod:$prod_raw" "$imv:$dist_raw"; do
    local src=${pair%%:*} dst=${pair##*:}
    if head -c 4 "$src" | od -An -tx1 | tr -d ' \n' | grep -q "3aff26ed"; then
      "$TREE/out/host/linux-x86/bin/simg2img" "$src" "$dst" >> "$LOG" 2>&1 || return 1
    else
      cp -a "$src" "$dst"
    fi
  done
  local missing=0
  for rel in $need; do
    local dir=$(dirname "$rel") base=$(basename "$rel")
    local in_prod=$(debugfs -R "ls -l -r /$dir" "$prod_raw" 2>/dev/null | awk '{print $NF}' | grep -cx "$base")
    local in_dist=$(debugfs -R "ls -l -r /$dir" "$dist_raw" 2>/dev/null | awk '{print $NF}' | grep -cx "$base")
    if [ "$in_prod" -ge 1 ]; then continue; fi
    missing=$((missing + 1))
    echo "  $rel: missing from the product image ($(stat -c %s "$prod") B), present in dist's ($(stat -c %s "$imv") B)" >> "$LOG"
  done
  rm -f "$prod_raw" "$dist_raw"
  if [ "$missing" -gt 0 ]; then
    echo "  vendor.img lacks $missing injected file(s) -> taking dist's IMAGES/vendor.img" >> "$LOG"
    local sync_raw="$TMPDIR/vendor_sync.img"
    if head -c 4 "$imv" | od -An -tx1 | tr -d ' \n' | grep -q "3aff26ed"; then
      "$TREE/out/host/linux-x86/bin/simg2img" "$imv" "$sync_raw" >> "$LOG" 2>&1 || return 1
    else
      cp -a "$imv" "$sync_raw"
    fi
    cp -a "$sync_raw" "$prod"
    rm -f "$sync_raw"
    echo "  product vendor.img <- dist's ($(stat -c %s "$prod") B)" >> "$LOG"
  else
    echo "  every injected file is already in ninja's vendor.img ($(stat -c %s "$prod") B)" >> "$LOG"
  fi
}
if ! sync_vendor_image; then echo "PACKAGING STOPPED on sync_vendor_image" >> "$LOG"; exit 1; fi

# Stage super from the IMAGES that dist just wrote, then check they really are fresh.
if ! m_retry superimage; then echo "PACKAGING STOPPED on superimage" >> "$LOG"; exit 1; fi
IMAGES=$TREE/out/target/product/rk3399/obj/PACKAGING/target_files_intermediates/lineage_rk3399-target_files/IMAGES
if [ -f "$IMAGES/system.img" ] && [ "$(stat -c %Y "$IMAGES/system.img")" -lt "$START" ]; then
  echo "  ! WARNING: $IMAGES/system.img predates this pass - super would embed stale images" >> "$LOG"
fi

m_retry otapackage

prune_dist

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
