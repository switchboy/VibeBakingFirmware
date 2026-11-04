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
echo "device tree -> $DEST"
