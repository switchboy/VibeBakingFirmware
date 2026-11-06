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

say "=== super layout ==="
TREE="$TREE" WORK="$WORK" python3 "$REPO/scripts/check_super.py" 2>&1 | tail -14

say "=== VINTF compatibility ==="
CV=$(find "$TREE/out/host" -name checkvintf -type f 2>/dev/null | head -1)
# The framework side is the system manifest plus every framework compatibility matrix the image
# carries (compatibility_matrix.<n>.xml, highest n = this release) and our own device-side
# framework matrix, which is what declares android.hardware.mtc.mfi and the rockchip HALs.
if [ -n "$CV" ]; then
  fw="$STAGE/SYSTEM/etc/vintf/manifest.xml"
  fwmat=$(ls "$STAGE/SYSTEM/etc/vintf/compatibility_matrix."*.xml 2>/dev/null | sort -V | tail -1)
  dev="$STAGE/VENDOR/etc/vintf/manifest.xml"
  devmat="$STAGE/VENDOR/etc/vintf/compatibility_matrix.xml"
  mats=()
  for m in "$STAGE/SYSTEM/etc/vintf/device_framework_matrix.xml" "$STAGE/SYSTEM/etc/vintf/compatibility_matrix.device.xml"; do
    if [ -s "$m" ]; then mats+=("$m"); fi
  done
  extra=""; names=""
  for m in "${mats[@]}"; do names+=" + $(basename "$m")"; extra+=" --framework-mat=$m"; done
  if [ -s "$fw" ] && [ -s "$fwmat" ] && [ -s "$dev" ] && [ -s "$devmat" ]; then
    say "  framework: $(basename "$fw") + $(basename "$fwmat")$names"
    say "  device:    $(basename "$dev") + $(basename "$devmat")"
    "$CV" --no_local --check-compat --framework="$fw" --framework-mat="$fwmat" \
      --device="$dev" --device-mat="$devmat" $extra 2>&1 | tail -4 | sed 's/^/  /'
    "$CV" --no_local --check-compat --framework="$fw" --framework-mat="$fwmat" \
      --device="$dev" --device-mat="$devmat" $extra >/dev/null 2>&1 || \
      bad "checkvintf reports incompatibility"
  else
    bad "missing VINTF files in target_files: fw=$fw fwmat=${fwmat:-none} dev=$dev devmat=$devmat"
  fi
else
  bad "no checkvintf in out/host"
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
say "  recovery.fstab rows for the flash targets:"
grep -E "^(/boot|/recovery|/misc|/super|/data)" "$RD/system/etc/recovery.fstab" 2>/dev/null | sed 's/^/    /' || bad "no boot/recovery/misc rows"

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
