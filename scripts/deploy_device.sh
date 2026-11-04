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
missing=0
while read -r ref; do
  [ -n "$ref" ] || continue
  if [ ! -e "$TREE/$ref" ]; then
    echo "  ! referenced file not in tree: $ref"
    missing=1
  fi
done < <(sed -n 's|^[[:space:]]*\(\(frameworks\|packages\|vendor\|device\)/[^:]*\):.*|\1|p' "$DEST/device.mk")
if [ "$missing" = 1 ]; then
  echo "fix those paths before building (ninja fails on missing PRODUCT_COPY_FILES sources)"
  exit 1
fi

echo "device tree -> $DEST"
