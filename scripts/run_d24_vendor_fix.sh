#!/usr/bin/env bash
# Prove the device.mk newline fix restores the four HU vendor copy rules (docs/decisions.md D24 gates addendum).
#   nohup bash .../scripts/run_d24_vendor_fix.sh > /tmp/d24-vfix.log 2>&1 &
set -o pipefail
export HOME=/tmp
export GOCACHE=/srv/dev-disk-by-label-SSData/aospbuild/.gocache
export TMPDIR=/srv/dev-disk-by-label-SSData/aospbuild/tmp
REPO=/srv/dev-disk-by-label-SSData/aospbuild/VibeBakingFirmware
TREE=/srv/dev-disk-by-label-SSData/aospbuild/lineage21s

cd "$REPO"
echo "== deploy_device.sh =="
bash scripts/deploy_device.sh "$TREE" > /tmp/d24-vdeploy.log 2>&1
echo "deploy rc=$? ; $(tail -3 /tmp/d24-vdeploy.log)"
grep -c PRODUCT_COPY_FILES "$TREE/device/rockchip/rk3399/device.mk" | sed 's/^/PRODUCT_COPY_FILES lines in deployed device.mk: /'

echo "== build vendorimage systemimage productimage =="
cd "$TREE"
source build/envsetup.sh > /dev/null 2>&1
lunch lineage_rk3399-ap2a-userdebug > /dev/null 2>&1
m -j4 vendorimage systemimage productimage > /tmp/d24-vbuild.log 2>&1
echo "build rc=$? ; $(tail -6 /tmp/d24-vbuild.log)"

echo "== vendor tree contents (the four HU files) =="
P="$TREE/out/target/product/rk3399"
for f in vendor/etc/fstab.rk30board vendor/etc/ueventd.rc vendor/etc/init/hu.rc vendor/etc/hu_insmod.sh; do
  printf '%-34s %s\n' "$f" "$([ -e "$P/$f" ] && stat -c %s "$P/$f" || echo MISSING)"
done

echo "== vendor.img contents =="
python3 "$REPO/tools/ext4_ls.py" "$P/vendor.img" / --sizes 2>/dev/null | grep -E "fstab.rk30board|ueventd.rc|init/hu.rc|hu_insmod.sh" || echo "none of the four found in vendor.img"

echo "== sizes =="
ls -l "$P"/system.img "$P"/product.img "$P"/vendor.img | awk '{print $3, $NF}'
python3 - "$P" <<'PY'
import os, sys
p = sys.argv[1]
sizes = {part: os.path.getsize(os.path.join(p, part + ".img")) for part in ["system", "vendor", "product", "system_ext", "odm"]}
info = open(os.path.join(p, "misc_info.txt")).read()
def find(key):
    for line in info.splitlines():
        if line.startswith(key + "="):
            return int(line.split("=", 1)[1])
    return None
group = find("super_hct_dynamic_partitions_group_size")
total = sum(sizes.values())
print("vendor:", f"{sizes['vendor']:,} B", "total:", f"{total:,} B", "group:", f"{group:,} B", "spare:", f"{group - total:,} B", "fits:", total <= group)
PY
echo "== vendor_abi_check =="
python3 "$REPO/tools/vendor_abi_check.py" "$TREE" "$REPO/device/rk3399-px6-hct4" 2>&1 | tail -8
echo "== done =="
