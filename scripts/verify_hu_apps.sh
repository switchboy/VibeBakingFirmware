#!/usr/bin/env bash
# Check the staged head-unit app layer in a built tree (docs/decisions.md D24).
#
#   scripts/verify_hu_apps.sh <lineage-tree>
#
# Read-only: it never builds, never writes into out/, and never touches anything partition-shaped.
# It answers the four questions the staging has to survive:
#   1. are the apps and the control binaries actually installed, and is the init fragment in the
#      directory Android 14's init reads (/system/etc/init/*.rc)?
#   2. did any `oat/` directory get copied? (Android 14 dexopts at boot; Android 10's odex/vdex is dead
#      weight and Android 14's runtime cannot use it)
#   3. does the re-signing hold? the installed apk must still carry its package + sharedUserId and be
#      signed with this build's platform certificate, not the payload's own key.
#   4. do the images still fit inside the existing super group (misc_info.txt numbers), with no resize?
set -eu

TREE=${1:?usage: verify_hu_apps.sh <lineage-tree>}
REPO=$(cd "$(dirname "$0")/.." && pwd)
P="$TREE/out/target/product/rk3399"
AAPT2="$TREE/out/host/linux-x86/bin/aapt2"

[ -d "$P" ] || { echo "no built product dir: $P"; exit 1; }

echo "== installed apps =="
sys=$(ls "$P/system/app" 2>/dev/null | grep -c '^HCT')
priv=$(ls "$P/system/priv-app" 2>/dev/null | grep -c '^HCT')
echo "system/app HCT dirs: $sys ; system/priv-app HCT dirs: $priv"
echo "CANBUS/manager/touch present: $(ls -d "$P/system/priv-app/HCTCanBus" "$P/system/priv-app/HCTManagerService" "$P/system/app/HCTCarTouch" 2>&1 | head -3)"

echo "== binaries, libraries, init, permissions =="
for f in system/bin/gocsdk system/bin/gocsdk6 system/bin/gocsdk8 system/bin/gocsdkrf210 \
         system/bin/sdsdk6 system/bin/sdsdk816 system/bin/blueletd system/bin/brlinktd \
         system/bin/sd_carplay system/bin/dhcpcd system/bin/ec_usb_filter \
         system/lib/libbluelet.so system/lib/libbt_platform.so system/lib/libGbtsTask.so \
         system/lib/libgocdfu.so system/lib/librockchip_update_jni.so \
         system/lib64/librockchip_update_jni.so system/etc/init/hct.rc \
         system/etc/init/hu_probe.rc system/bin/hu_probe.sh \
         system/etc/permissions/privapp-permissions-hct.xml system/etc/bluesoleil/TL.INI; do
  printf '%-52s %s\n' "$f" "$([ -e "$P/$f" ] && stat -c %s "$P/$f" || echo MISSING)"
done
echo "auto-probe service defined: $(grep -c '^service hu_probe /system/bin/hu_probe.sh' "$P/system/etc/init/hu_probe.rc" 2>/dev/null || echo 0) ; started on boot_completed: $(grep -c 'start hu_probe' "$P/system/etc/init/hu_probe.rc" 2>/dev/null || echo 0)"
echo "adb key staged for /data/adb/adb_keys injection: $(stat -c %s "$P/system/etc/hu_adb_key.pub" 2>/dev/null || echo MISSING) ; ro.adb.secure kept: $(grep -c 'ro.adb.secure=1' "$P/system/build.prop" 2>/dev/null || echo 0)"
echo "init fragment import lines still pointing at a missing file: $(grep -n 'import' "$P/system/etc/init/hct.rc" || echo none)"
echo "init fragment fidelity: $(diff <(tail -n +2 "$REPO/analysis/system_init.hct.rc") "$P/system/etc/init/hct.rc" > /dev/null 2>&1 && echo 'identical apart from the dropped import line' || echo 'DIFFERS from the payload copy')"

echo "== oat =="
# Lineage's own apps are dexpreopted by the build (their oat/ dirs are legitimate build output).
# What must be zero is oat/ under an *HCT* app dir: Android 10's odex/vdex is dead weight on Android 14.
found=$(find "$P/system/app" "$P/system/priv-app" -name oat -type d 2>/dev/null | grep -c HCT || true)
all=$(find "$P/system/app" "$P/system/priv-app" -name oat -type d 2>/dev/null | wc -l)
echo "oat directories under HCT app dirs: $found (want 0) ; total oat dirs under app dirs: $all (Lineage's own dexpreopt)"

echo "== signing + manifest survival =="
python3 "$REPO/tools/hu_apk_cert.py" \
  "$P/system/framework/framework-res.apk" \
  "$P/system/app/HCT4Radio/HCT4Radio.apk" \
  "$P/system/priv-app/HCTCanBus/HCTCanBus.apk"
python3 "$REPO/tools/hct_apk_inventory.py" --aapt2 "$AAPT2" \
  "$P/system/app/HCT4Radio" "$P/system/priv-app/HCTCanBus" "$P/system/priv-app/HCTManagerService"
echo "apk sha256 after signing:"
sha256sum "$P/system/app/HCT4Radio/HCT4Radio.apk" "$P/system/priv-app/HCTCanBus/HCTCanBus.apk" | cut -c1-64

echo "== sizes and super budget =="
python3 - "$P" <<'PY'
import os, sys
p = sys.argv[1]
parts = ["system", "vendor", "product", "system_ext", "odm"]
sizes = {}
for part in parts:
    img = os.path.join(p, part + ".img")
    if os.path.isfile(img):
        sizes[part] = os.path.getsize(img)
total = sum(sizes.values())
info = open(os.path.join(p, "misc_info.txt")).read()
def find(key):
    for line in info.splitlines():
        if line.startswith(key + "="):
            return int(line.split("=", 1)[1])
    return None
group = find("super_hct_dynamic_partitions_group_size")
super_dev = find("super_partition_size")
print("images:", {k: f"{v:,} B" for k, v in sizes.items()})
print("total logical content:", f"{total:,} B")
print("group size:", f"{group:,} B", "spare:", f"{group - total:,} B")
print("super device size:", f"{super_dev:,} B")
print("fits without a resize:", total <= group)
PY

echo "== collisions =="
python3 "$REPO/tools/vendor_conflicts.py" "$TREE" "$TREE/device/rockchip/rk3399" | tail -3
# vendor_conflicts.py only compares the /vendor destinations, which is what the vendor staging needs.
# The app layer copies into /system, where a colliding module install rule makes ckati abort with
# "overriding commands for target", so check those destinations here against Soong's install list.
python3 - "$TREE" "$REPO/device/rk3399-px6-hct4/hu_apps.mk" <<'PY'
import glob, os, re, sys
tree, mk = sys.argv[1], sys.argv[2]
installs = "\n".join(open(p).read() for p in glob.glob(os.path.join(tree, "out", "soong", "installs-*.mk")))
dests = [m.group(2).replace("$(TARGET_COPY_OUT_SYSTEM)", "system")
         for m in re.finditer(r"^\s*(\S+):(\$\([^)]*\)/[^ ]+)", open(mk).read(), re.M)]
hits = [d for d in dests if "out/target/product/rk3399/" + d in installs]
print(f"system destinations copied: {len(dests)} ; colliding with a module install rule: {len(hits)}")
for d in hits:
    print(f"    COLLISION {d}")
PY
# vendor_dropped_check.py is about the vendor staging (tree, device dir, vendor image), not the app
# layer; run it when the staging changed, and skip it here if there is no vendor.img yet.
if [ -s "$P/vendor.img" ]; then
  python3 "$REPO/tools/vendor_dropped_check.py" "$TREE" "$TREE/device/rockchip/rk3399" "$P/vendor.img" | tail -3
else
  echo "no vendor.img yet - vendor_dropped_check.py skipped"
fi
