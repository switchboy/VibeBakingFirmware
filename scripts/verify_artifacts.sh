#!/usr/bin/env bash
# Offline verification of a finished packaging pass, before anything is flashed.
#
#   scripts/verify_artifacts.sh <lineage-tree>
#
# Run on the build host. Nothing here touches the head unit: every check reads files in out/ and
# compares them against the stock Android 11 reference in vendor/hct4/. It answers the four
# questions that decide whether a build is flashable:
#
#   1. did the vendor partition get built from the staged blobs (VENDOR/ + vendor.map in target_files)?
#   2. does the built vendor.img still carry every stock blob (tools/vendor_diff.py)?
#   3. is super internally consistent - logical partitions byte-identical to their images (check_super.py)?
#   4. can recovery actually install an update (update_engine_sideload + our recovery.fstab)?
# Plus VINTF compatibility, and the boot image header that u-boot reads.
set -eu
TREE=${1:?usage: verify_artifacts.sh <lineage-tree>}
REPO=$(cd "$(dirname "$0")/.." && pwd)
PROD=$TREE/out/target/product/rk3399
STAGE=$PROD/obj/PACKAGING/target_files_intermediates/lineage_rk3399-target_files
WORK=${WORK:-/srv/dev-disk-by-label-SSData/aospbuild/tmp}
fail=0
say() { printf '%s\n' "$*"; }
bad() { say "  ! $*"; fail=1; }

[ -d "$PROD" ] || { echo "no built product dir: $PROD"; exit 1; }

say "=== images (mtime shows which pass produced them) ==="
for f in boot.img recovery.img super.img system.img vendor.img product.img system_ext.img odm.img; do
  if [ -s "$PROD/$f" ]; then stat -c '%y %s %n' "$PROD/$f" | sed 's/\.[0-9]*//' | sed 's|^|  |'
  else bad "missing or empty: $f"; fi
done

say "=== vendor staged from blobs (D15) ==="
grep -n "building_vendor_image\|building_odm_image\|building_system_ext_image\|super_partition_size\|dynamic_partitions" \
  "$PROD/misc_info.txt" 2>/dev/null | sed 's/^/  /' || bad "no misc_info.txt"
if [ -d "$STAGE/VENDOR" ]; then
  say "  VENDOR/: $(find "$STAGE/VENDOR" -type f | wc -l) files, $(du -sh "$STAGE/VENDOR" | cut -f1)"
else
  bad "no VENDOR/ in target_files - otapackage cannot build a BlockDifference for vendor"
fi
if [ -s "$STAGE/IMAGES/vendor.map" ]; then
  say "  vendor.map: $(stat -c %s "$STAGE/IMAGES/vendor.map") bytes, $(wc -l < "$STAGE/IMAGES/vendor.map") entries"
else
  bad "no IMAGES/vendor.map"
fi

say "=== built vendor.img vs the stock Android 11 partition ==="
python3 "$REPO/tools/vendor_diff.py" "$TREE/vendor/hct4/prebuilt/vendor_a11.img" "$PROD/vendor.img" \
  "$REPO/device/rk3399-px6-hct4" 2>&1 | tail -14

say "=== every dropped vendor destination really replaced (tools/vendor_dropped_check.py) ==="
python3 "$REPO/tools/vendor_dropped_check.py" "$TREE" "$TREE/device/rockchip/rk3399" "$PROD/vendor.img" 2>&1 | tail -18
[ "${PIPESTATUS[0]}" = 0 ] || bad "dropped vendor destinations are missing from vendor.img (see PRODUCT_PACKAGES in device.mk)"

say "=== kept vendor blobs resolve their DT_NEEDED in the built image ==="
python3 "$REPO/tools/blob_deps.py" "$TREE/vendor/hct4/tree/vendor" \
  "$TREE/device/rockchip/rk3399/vendor_build_wins.txt" "$PROD/vendor.img" \
  "$TREE/device/rockchip/rk3399/vendor_dest_keep.txt" 2>&1 | tail -14
[ "${PIPESTATUS[0]}" = 0 ] || bad "a staged vendor blob needs a library that /vendor does not provide"

say "=== vendor link closure (Android 14 vendor variants / injections / gaps) ==="
# Writes vendor_modules_extra.mk + vendor_dest_keep.txt from this build. Unresolved sonames mean a blob
# would not load and no Android 14 module or reference copy exists for it.
python3 "$REPO/tools/vendor_link_closure.py" "$TREE" "$REPO/device/rk3399-px6-hct4" 2>&1 | tail -22
[ "${PIPESTATUS[0]}" = 0 ] || bad "a vendor blob links a soname Android 14 does not build and no reference image provides"

say "=== kept Android 11 blobs resolve their symbols against Android 14's libraries ==="
# DT_NEEDED is only half the story: a library can be present and still not export the symbol the blob
# calls (Android 14 turned libstagefright_foundation's AString into std::string). A missing symbol is a
# boot-time `dlopen failed: cannot locate symbol`, so this is the real gate.
python3 "$REPO/tools/vendor_abi_check.py" "$TREE" "$REPO/device/rk3399-px6-hct4" 2>&1 | tail -22
[ "${PIPESTATUS[0]}" = 0 ] || bad "a kept blob needs symbols Android 14 does not export - it would not dlopen"

say "=== super layout ==="
TREE="$TREE" WORK="$WORK" python3 "$REPO/scripts/check_super.py" 2>&1 | tail -14

say "=== VINTF compatibility (the build ran checkvintf during dist) ==="
# dist runs checkvintf --check-one per partition and --check-compat over the whole target_files set,
# and fails the build if anything is incompatible, so the logs are the authoritative result. Running
# it ourselves offline is not equivalent: --check-compat needs /apex/apex-info-list.xml, which only
# exists on a running device (the build passes the apex info file it generated).
logs=$(find "$PROD/obj/PACKAGING" -name "check_vintf*.log" 2>/dev/null | sort)
if [ -n "$logs" ]; then
  for lg in $logs; do
    name=$(basename "$lg")
    # These logs contain warnings too (e.g. --check-one on /system cannot read /vendor/manifest.xml,
    # and the kernel version line is retried through three parsers). Only ERROR lines and the
    # verdict matter: the recipe fails dist when checkvintf exits non-zero.
    if grep -q "^ERROR" "$lg"; then
      bad "$name: $(grep -m3 "^ERROR" "$lg" | tr "\n" " ")"
    elif [ "$name" = check_vintf_compatible.log ] && ! grep -q "^COMPATIBLE$" "$lg"; then
      bad "$name has no COMPATIBLE verdict"
    elif grep -q "VINTF parse error" "$lg" && ! grep -q "Successfully processed" "$lg"; then
      bad "$name: VINTF parse error without a successful parse"
    else
      say "  $name: $(grep -c . "$lg") lines; $(grep -m1 "^COMPATIBLE\|Successfully processed" "$lg")"
    fi
  done
else
  bad "no check_vintf logs - dist did not run the VINTF check"
fi

say "=== boot image header (what u-boot loads) ==="
UB=$(find "$TREE/out/host" -name unpack_bootimg -type f 2>/dev/null | head -1)
if [ -n "$UB" ]; then
  "$UB" --boot_img "$PROD/boot.img" --format mkbootimg 2>&1 | sed 's/^/  /' | head -12
else
  bad "no unpack_bootimg in out/host"
fi

say "=== recovery carries an installer ==="
RD="$WORK/recovery-ramdisk-check"
rm -rf "$RD"; mkdir -p "$RD"
python3 - "$PROD/ramdisk-recovery.img" "$RD" <<'PY'
import gzip, sys, pathlib
src, dst = sys.argv[1], sys.argv[2]
d = pathlib.Path(src).read_bytes()
if d[:2] == b"\x1f\x8b":
    d = gzip.decompress(d)
pathlib.Path(dst + "/rd.cpio").write_bytes(d)
print("  ramdisk-recovery.img: %d bytes, decompressed %d" % (len(pathlib.Path(src).read_bytes()), len(d)))
PY
(cd "$RD" && cpio -id < rd.cpio 2>/dev/null || true)
if [ -x "$RD/system/bin/update_engine_sideload" ]; then
  say "  update_engine_sideload: $(stat -c %s "$RD/system/bin/update_engine_sideload") bytes"
else
  bad "update_engine_sideload not in the recovery ramdisk - no SD/USB or ADB sideload install"
fi
for f in system/lib64/libfusesideload.so system/etc/recovery.fstab; do
  if [ -s "$RD/$f" ]; then say "  $f: $(stat -c %s "$RD/$f") bytes"
  else bad "$f missing from the recovery ramdisk"; fi
done
say "  recovery.fstab rows for the flash targets (recovery mounts by block device):"
grep -E "by-name/(boot|recovery|misc|userdata|metadata|cache)" "$RD/system/etc/recovery.fstab" 2>/dev/null | sed 's/^/    /' || bad "no boot/recovery/misc/userdata rows"

say "=== OTA package ==="
if [ -s "$PROD/lineage_rk3399-ota.zip" ]; then
  say "  $(stat -c %y "$PROD/lineage_rk3399-ota.zip" | cut -c1-19) $(stat -c %s "$PROD/lineage_rk3399-ota.zip") bytes"
  sha256sum "$PROD/lineage_rk3399-ota.zip" | sed 's/^/  sha256 /'
  if unzip -tqq "$PROD/lineage_rk3399-ota.zip" >/dev/null 2>&1; then say "  unzips cleanly ($(unzip -l "$PROD/lineage_rk3399-ota.zip" | tail -1 | awk '{print $2}') entries)"
  else bad "OTA zip does not unzip cleanly"; fi
else
  bad "no OTA zip yet - m otapackage did not run"
fi

say "VERDICT: flashable build = $([ "$fail" = 0 ] && echo yes || echo NO)"
exit "$fail"
