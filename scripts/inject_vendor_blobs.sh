#!/usr/bin/env bash
# Put back the vendor libraries Android 14 does not install into /vendor.
#
#   scripts/inject_vendor_blobs.sh <lineage-tree> <device-dir> [--dry-run]
#
# Android 14 dropped the VNDK, so libchrome/libdrm/libvpx/libopus/libstagefright_*/libvorbisidec/
# libhwbinder/libkeymaster4support are built for /system only. Their Soong *vendor variant* install
# rule still exists, which means:
#   * PRODUCT_COPY_FILES cannot copy the stock blob to that path - ckati aborts with
#     "overriding commands for target .../vendor/lib/libchrome.so" even though nothing installs it
#     (pack24 burned 6 attempts on exactly this);
#   * the file never materialises in /vendor, and a vendor process cannot read /system, so the
#     Rockchip HAL blobs that link those sonames would not load.
#
# So the blob is dropped from the copy list (vendor_build_wins.txt) and written into the staging
# directory after the install rules have run, which is what build_image.py packs into vendor.img and
# what add_img_to_target_files copies into VENDOR/ + IMAGES/vendor.map. The stale vendor.img is
# removed so ninja rebuilds it from the staging directory instead of reusing the old image.
#
# vendor_dest_keep.txt is written by tools/vendor_dropped_check.py --write-keep-list from a real
# build; scripts/verify_artifacts.sh fails if an injected path is missing from the image.
set -eu
TREE=${1:?usage: inject_vendor_blobs.sh <lineage-tree> <device-dir> [--dry-run]}
DEV=${2:?no device dir}
DRY=${3:-}
KEEP=$DEV/vendor_dest_keep.txt
SRC=$TREE/vendor/hct4/tree/vendor
STAGE=$TREE/out/target/product/rk3399/vendor
[ -s "$KEEP" ] || { echo "  no $KEEP (run: tools/vendor_dropped_check.py --write-keep-list)"; exit 0; }
[ -d "$SRC" ] || { echo "  ! no staged vendor tree: $SRC"; exit 1; }
[ -d "$STAGE" ] || { echo "  ! vendor staging dir does not exist yet: $STAGE"; exit 1; }

copied=0 skipped=0
while read -r rel; do
  case "$rel" in ''|'#'*) continue ;; esac
  # The staging dir must not hold a copy that a module also installs: that would be the same file
  # twice with different provenance. Only the paths nothing installs are injected.
  if [ -e "$STAGE/$rel" ]; then
    skipped=$((skipped + 1))
    continue
  fi
  if [ ! -f "$SRC/$rel" ]; then
    echo "  ! listed in vendor_dest_keep.txt but not staged: $rel"
    exit 1
  fi
  mkdir -p "$STAGE/$(dirname "$rel")"
  if [ "$DRY" != "--dry-run" ]; then
    cp -a "$SRC/$rel" "$STAGE/$rel"
  fi
  copied=$((copied + 1))
done < "$KEEP"

echo "  injected $copied vendor library(ies) from vendor_dest_keep.txt (skipped $skipped already installed)"
if [ "$DRY" = "--dry-run" ]; then exit 0; fi

# ninja only rebuilds an image whose declared inputs changed; extra files in the staging dir are not
# inputs, so delete the built image and the copy inside target_files to force a fresh one.
PROD=$TREE/out/target/product/rk3399
STAGES=$(ls -d "$PROD"/obj/PACKAGING/target_files_intermediates/*/IMAGES 2>/dev/null | head -1)
for f in "$PROD/vendor.img" "$STAGES/vendor.img"; do
  [ -n "$f" ] && [ -f "$f" ] && { rm -f "$f"; echo "  removed stale $f (ninja rebuilds it from the staging dir)"; }
done
