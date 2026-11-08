#!/usr/bin/env bash
# One-shot D24 verification pass on the build host (docs/decisions.md D24 "Gates").
#   systemd-run --unit=los-d24 --collect /bin/bash /srv/dev-disk-by-label-SSData/aospbuild/VibeBakingFirmware/scripts/run_d24_gates.sh
# Read-only except the build itself; nothing partition-shaped, no packaging pass.
# NOTE: no `set -u` here - build/envsetup.sh reads $TOP unconditionally (line 21).
set -o pipefail

export HOME=/tmp
export GOCACHE=/srv/dev-disk-by-label-SSData/aospbuild/.gocache
export TMPDIR=/srv/dev-disk-by-label-SSData/aospbuild/tmp
REPO=/srv/dev-disk-by-label-SSData/aospbuild/VibeBakingFirmware
TREE=/srv/dev-disk-by-label-SSData/aospbuild/lineage21s

cd "$REPO"

echo "== repo integrity (apps + hu_system + mk + tools) =="
find device/rk3399-px6-hct4/apps device/rk3399-px6-hct4/hu_system device/rk3399-px6-hct4/hu_apps.mk \
  device/rk3399-px6-hct4/device.mk scripts/verify_hu_apps.sh tools/hct_apk_inventory.py \
  tools/hu_apk_cert.py tools/hu_apk_native_libs.py tools/hu_system_abi_check.py -type f | sort | xargs sha256sum | sha256sum

echo "== deploy_device.sh =="
bash scripts/deploy_device.sh "$TREE" > /tmp/d24-deploy.log 2>&1
echo "deploy rc=$? ; $(tail -6 /tmp/d24-deploy.log)"

echo "== vendor_conflicts.py =="
python3 tools/vendor_conflicts.py "$TREE" "$REPO/device/rk3399-px6-hct4" > /tmp/d24-conflicts.log 2>&1
echo "conflicts rc=$? ; $(tail -3 /tmp/d24-conflicts.log)"

echo "== build systemimage productimage =="
cd "$TREE"
source build/envsetup.sh > /tmp/d24-envsetup.log 2>&1
lunch lineage_rk3399-ap2a-userdebug > /tmp/d24-lunch.log 2>&1
echo "envsetup rc=$? lunch rc=$? ; m defined: $(type m 2>&1 | head -1) ; lunch tail: $(tail -3 /tmp/d24-lunch.log)"
m -j4 systemimage productimage > /tmp/d24-build.log 2>&1
echo "build rc=$? ; $(tail -20 /tmp/d24-build.log)"

echo "== verify_hu_apps.sh =="
bash "$REPO/scripts/verify_hu_apps.sh" "$TREE" 2>&1

echo "== done =="
