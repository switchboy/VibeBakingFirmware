#!/usr/bin/env bash
# Copy the PX6 device tree into a LineageOS checkout.
#
#   scripts/deploy_device.sh /srv/.../lineage21
#
# The folder in the build tree is named after PRODUCT_DEVICE (rk3399), not the repo folder.
set -eu

TREE=${1:?usage: deploy_device.sh <lineage-tree>}
REPO=$(cd "$(dirname "$0")/.." && pwd)
DEST="$TREE/device/rockchip/rk3399"

mkdir -p "$DEST"
cp -a "$REPO/device/rk3399-px6-hct4/." "$DEST/"

# Every source path in PRODUCT_COPY_FILES must exist in the checkout, otherwise ninja aborts with
# "missing and no known rule to make it". Check them here instead of 20 minutes into a build.
# The generated staging file holds ~1400 blob paths, so scan every .mk in the device dir.
missing=0
while read -r ref; do
  [ -n "$ref" ] || continue
  if [ ! -e "$TREE/$ref" ]; then
    echo "  ! referenced file not in tree: $ref"
    missing=1
  fi
done < <(sed -n 's|^[[:space:]]*\(\(frameworks\|packages\|vendor\|device\)/[^:]*\):.*|\1|p' "$DEST"/*.mk)
if [ "$missing" = 1 ]; then
  echo "fix those paths before building (ninja fails on missing PRODUCT_COPY_FILES sources)"
  exit 1
fi

# BoardConfig.mk points at files that are not in device.mk. mkbootimg/lpmake fail late, so check:
#   dtb dir must hold exactly one .dtb (the rule copies the wildcard), boot/recovery need `second`,
#   and the vendor staging comes from scripts/prebuilt_vendor.sh + tools/gen_vendor_staging.py.
dtb_count=$(find "$DEST/prebuilt/dtb" -name '*.dtb' 2>/dev/null | wc -l)
[ "$dtb_count" = 1 ] || { echo "  ! need exactly 1 .dtb in $DEST/prebuilt/dtb (found $dtb_count)"; exit 1; }
for f in "$DEST/prebuilt/boot_second_logo.bin" \
         "$TREE/vendor/hct4/prebuilt/kernel_a11" \
         "$TREE/vendor/hct4/prebuilt/vendor_a11.img" \
         "$TREE/vendor/hct4/tree/vendor/etc/vintf/manifest.xml" \
         "$DEST/vendor_staging.mk" "$DEST/vendor_props.mk"; do
  [ -s "$f" ] || { echo "  ! missing or empty: $f (run scripts/prebuilt_vendor.sh first)"; exit 1; }
done

# Flags the Makefile guards with `ifdef` must not be set to `false`: definedness is enough to emit
# the flag, and mkbootimg then gets an empty argument (see docs/build-host.md).
# `|| true` matters: grep exits 1 when nothing matches, and the script runs under `set -eu`, so
# without it a clean BoardConfig.mk aborts the deploy silently.
bad=$(grep -nE '^[[:space:]]*(BOARD_INCLUDE_RECOVERY_DTBO|BOARD_INCLUDE_DTB_IN_BOOTIMG|BOARD_INCLUDE_RECOVERY_ACPIO)[[:space:]]*:=?[[:space:]]*false' "$DEST/BoardConfig.mk" 2>/dev/null || true)
if [ -n "$bad" ]; then
  echo "  ! these ifdef-tested flags must be left undeclared, not '=false':"
  printf '%s\n' "$bad"
  exit 1
fi

# The vendor APKs (the stock resource-overlay package) are installed by the generated
# prebuilt_apps/Android.mk, because PRODUCT_COPY_FILES rejects .apk destinations. Its
# LOCAL_SRC_FILES are relative to that folder, so make sure the blob came along.
if [ -f "$DEST/prebuilt_apps/Android.mk" ]; then
  while read -r src; do
    [ -s "$DEST/prebuilt_apps/$src" ] || { echo "  ! apk referenced by prebuilt_apps/Android.mk missing: $src"; exit 1; }
  done < <(sed -n 's/^LOCAL_SRC_FILES := //p' "$DEST/prebuilt_apps/Android.mk")
fi

echo "device tree -> $DEST"
