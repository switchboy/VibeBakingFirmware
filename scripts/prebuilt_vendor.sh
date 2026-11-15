#!/usr/bin/env bash
# Stage a stock vendor partition into the build tree, so vendor.img is *built*.
#
#   scripts/prebuilt_vendor.sh <update.zip> <lineage-tree>     # first run: unpack + extract
#   scripts/prebuilt_vendor.sh "" <lineage-tree>               # later runs: reuse the reference
#
# Which firmware is staged is chosen with SHAPE (**D44** flipped to the Android 10 reference on Nov 15):
#   SHAPE=a10 (default, shape A, the proven kernel)  vendor_a10.img + kernel_a10 -> vendor/hct4/tree_a10/vendor
#   SHAPE=a11 (shape B, fallback)                    vendor_a11.img + kernel_a11 -> vendor/hct4/tree/vendor
# `REF_IMG` / `BOOT_IMG` point at an already-extracted reference image and stock boot image instead of
# unpacking an update.zip; on the build host the Android 10 pair lives in the archive:
#   SHAPE=a10 REF_IMG=/srv/50911774-.../aospbuild-archive/ref-a10/vendor.img \
#   BOOT_IMG=/srv/50911774-.../aospbuild-archive/hu-stock-backup/boot.bin \
#   scripts/prebuilt_vendor.sh "" /srv/dev-disk-by-label-SSData/aospbuild/lineage21s
#
# Why: Android 14's OTA packer needs a real VENDOR/ staging directory, vendor.map and a vendor
# build.prop. BOARD_PREBUILT_VENDORIMAGE produces none of those, so `m otapackage` asserts
# ("vendor is in super_hct_dynamic_partitions_partition_list but no BlockDifference object is
# provided"). The blobs are staged through PRODUCT_COPY_FILES instead, byte-for-byte;
# tools/vendor_diff.py checks the built image against the stock reference afterwards.
#
# Kernel and modules come from the same firmware as the tree, which is the point of the shape switch:
# each stock vendor partition carries its own /vendor/lib/modules, so staging the A10 tree ships the
# 4.19.111+ `.ko` set that kernel #190 loads, and staging the A11 tree ships the 4.19.193 set
# (docs/findings.md, "Which kernel Android 14's VINTF actually accepts").
#
# Run on the build host as root (loop mount). Idempotent, and it re-runs the generator, so
# deploy_device.sh must run *after* this script.
set -eu

ZIP=${1:-}
TREE=${2:?usage: prebuilt_vendor.sh <update.zip|empty> <lineage-tree>}
REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT="$TREE/vendor/hct4"
SHAPE=${SHAPE:-a10}
REF_IMG=${REF_IMG:-}
BOOT_IMG=${BOOT_IMG:-}
case "$SHAPE" in
    a10) REF="$OUT/prebuilt/vendor_a10.img"; KERNEL="$OUT/prebuilt/kernel_a10"
         TREEV="$OUT/tree_a10/vendor"; SRC="vendor/hct4/tree_a10/vendor"; LABEL="Android 10" ;;
    a11) REF="$OUT/prebuilt/vendor_a11.img"; KERNEL="$OUT/prebuilt/kernel_a11"
         TREEV="$OUT/tree/vendor";         SRC="vendor/hct4/tree/vendor";  LABEL="Android 11" ;;
    *) echo "SHAPE must be a10 or a11 (shape A is the primary, shape B the fallback - D44/D46)"; exit 1 ;;
esac
GEN="$REPO/device/rk3399-px6-hct4"
WORK=$(mktemp -d "$OUT/.work.XXXXXX")
trap 'umount "$WORK/mnt" 2>/dev/null || true; rm -rf "$WORK"' EXIT

# ---- 1. reference image, and the kernel whose module vermagic matches it --------
# REF_IMG / BOOT_IMG are *authoritative*, not merely "used when something is missing": a prebuilt copy
# that already exists but hashes differently is a stale reference and gets replaced. That happened on
# Nov 15 - the NAS archive's aospbuild-archive/ref-a10/vendor.img (333,447,168 B, sha b4e50b55…) is a
# different Android 10 build than the one the unit actually runs (analysis/daisaita_a10/vendor.img,
# 323,530,752 B, sha 3fe2f53a…): its /lib/modules lacks sd_user_hid.ko, usb_f_iap.ko, usb_f_iap2.ko,
# virtual_tp.ko and the aic8800 pair, i.e. the WiFi / USB-HID / iAP modules the owner's criteria depend
# on. Reusing a stale copy silently because the file was "not missing" is exactly the trap this gate
# exists to catch (docs/findings.md, "the archive ref-a10 is not the live Android 10 firmware").
sha_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

cut_kernel() {   # boot image header v2: the kernel payload sits at page_size, kernel_size bytes
    python3 - "$1" "$2" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
page = struct.unpack_from("<I", d, 56)[0] or 2048
ksize = struct.unpack_from("<I", d, 8)[0]
open(sys.argv[2], "wb").write(d[page:page + ksize])
PY
}

mkdir -p "$OUT/prebuilt"
if [ -n "$REF_IMG" ]; then
    [ -s "$REF_IMG" ] || { echo "REF_IMG $REF_IMG missing"; exit 1; }
    if [ ! -s "$REF" ] || [ "$(sha_of "$REF")" != "$(sha_of "$REF_IMG")" ]; then
        cp "$REF_IMG" "$REF"
        echo "  reference vendor: $(stat -c %s "$REF") B sha $(sha_of "$REF" | cut -c1-12) <- $REF_IMG"
    else
        echo "  reference vendor already matches $REF_IMG ($(stat -c %s "$REF") B, sha $(sha_of "$REF" | cut -c1-12))"
    fi
fi
if [ -n "$BOOT_IMG" ]; then
    [ -s "$BOOT_IMG" ] || { echo "BOOT_IMG $BOOT_IMG missing"; exit 1; }
    cut_kernel "$BOOT_IMG" "$WORK/kernel.cut"
    [ -s "$WORK/kernel.cut" ] || { echo "no kernel payload in $BOOT_IMG"; exit 1; }
    if [ ! -s "$KERNEL" ] || [ "$(sha_of "$KERNEL")" != "$(sha_of "$WORK/kernel.cut")" ]; then
        cp "$WORK/kernel.cut" "$KERNEL"
        echo "  kernel payload: $(stat -c %s "$KERNEL") B sha $(sha_of "$KERNEL" | cut -c1-12) <- $BOOT_IMG"
    else
        echo "  kernel already matches $BOOT_IMG ($(stat -c %s "$KERNEL") B, sha $(sha_of "$KERNEL" | cut -c1-12))"
    fi
fi

# The zip (~1 GB) is unpacked only when the reference or kernel is still missing after that.
if [ ! -s "$REF" ] || [ ! -s "$KERNEL" ]; then
    [ -n "$ZIP" ] || { echo "missing $REF / $KERNEL and no update.zip given"; exit 1; }
    unzip -qo "$ZIP" -d "$WORK/pkg"
    if [ ! -s "$REF" ]; then
        if [ -f "$WORK/pkg/vendor.new.dat.br" ]; then
            brotli -d -f "$WORK/pkg/vendor.new.dat.br" -o "$WORK/pkg/vendor.new.dat"
        fi
        python3 "$REPO/tools/reassemble.py" --dir "$WORK/pkg" --out "$WORK/images" --partition vendor
        cp "$WORK/images/vendor.img" "$REF"
    fi
    if [ ! -s "$KERNEL" ]; then
        cut_kernel "$WORK/pkg/boot.img" "$KERNEL"
        echo "  kernel payload cut from the update.zip's boot.img: $(stat -c %s "$KERNEL") B sha $(sha_of "$KERNEL" | cut -c1-12)"
    fi
fi
[ -s "$REF" ] && [ -s "$KERNEL" ] || { echo "reference image or kernel missing"; exit 1; }

# ---- 2. extract the partition tree ----------------------------------------------
# A read-only loop mount gives real symlinks (debugfs dumps them as 0-byte sidecars, which
# loses the target), so the tree is a faithful mirror of the partition.
rm -rf "$(dirname "$TREEV")"
mkdir -p "$TREEV" "$WORK/mnt"
mount -o ro,loop "$REF" "$WORK/mnt"
# The stock build.prop is not staged (Android 14 generates its own), but its properties are what
# the Rockchip HALs read, so a copy is kept for tools/gen_vendor_staging.py. Same for the device
# compatibility matrix: its <vendor-ndk> block must be removed before Android 14 will accept it.
cp "$WORK/mnt/build.prop" "$OUT/prebuilt/vendor_build.prop.$SHAPE"
cp "$WORK/mnt/etc/vintf/compatibility_matrix.xml" "$OUT/prebuilt/vendor_compat_matrix.$SHAPE.xml"
# Deliberately not staged:
#   build.prop / default.prop      Android 14 generates its own (props come from vendor_props.mk)
#   recovery-from-boot.p           the stock recovery payload (A11: this file; A10 keeps it too),
#                                  we ship our own recovery.img
#   odm                            a symlink to the odm partition, which we build from source
#   etc/vintf/manifest/            manifest fragments -> VINTF metadata in PRODUCT_COPY_FILES is
#                                  a build error (build/make/core/Makefile:131); the assembled
#                                  manifest.xml goes through DEVICE_MANIFEST_FILE instead
#   etc/vintf/compatibility_matrix.xml  it declares <vendor-ndk> (Android 10: 29, Android 11: 30),
#                                  and Android 14 has no VNDK, so checkvintf rejects it
#                                  (see docs/build-host.md)
rsync -a --exclude='lost+found/' --exclude='build.prop' --exclude='default.prop' \
      --exclude='recovery-from-boot.p' --exclude='odm' \
      --exclude='etc/vintf/compatibility_matrix.xml' --exclude='etc/vintf/manifest/' \
      "$WORK/mnt/" "$TREEV/"
umount "$WORK/mnt"

# ---- 3. symlinks ---------------------------------------------------------------
# PRODUCT_COPY_FILES copies with acp/cp, which *dereferences* symlinks: the 178 /vendor/bin
# toybox aliases would each become a 489 KB copy of toybox_vendor. Those tools resolve through
# /system/bin on Android 14 anyway, so the aliases are dropped. /vendor/bin/sh is a real file in
# the stock vendor (314 KB), so our init service and the stock shell scripts keep working.
# The GPU aliases are the exception: Android 14's EGL/OpenCL loader looks for the library named
# by ro.hardware.egl (libGLES_mali.so) and for libOpenCL.so, in /vendor/lib(64)/ and its egl/
# subdir, so they become real copies of the blob that lives in egl/ (Loader.cpp:284-315).
# Materialise first, while the whole alias chain still exists, then drop every remaining link.
find "$TREEV" -type l \( -name libGLES_mali.so -o -name libOpenCL.so \) -print | while read -r link; do
    real=$(readlink -f "$link")
    if [ -s "$real" ]; then
        cp "$real" "$link.materialised"
        mv -f "$link.materialised" "$link"
        echo "  materialised $(realpath --relative-to="$TREEV" "$link") ($(stat -c %s "$link") B, from $(realpath --relative-to="$TREEV" "$real"))"
    else
        rm -f "$link"
    fi
done
n=$(find "$TREEV" -type l | wc -l)
find "$TREEV" -type l -delete
echo "  dropped $n remaining symlink(s) (toybox aliases, OpenCL .1/.1.1 aliases)"

# ---- 4. vendor APKs ---------------------------------------------------------
# PRODUCT_COPY_FILES rejects .apk destinations ("Prebuilt apk found in PRODUCT_COPY_FILES",
# build/make/core/Makefile:118), so the stock vendor resource-overlay package is installed as a
# BUILD_PREBUILT module. Its Android.mk is generated by the tool below, with LOCAL_SRC_FILES
# relative to the device folder, so the blob is mirrored here first.
rm -rf "$GEN/prebuilt_apps"
find "$TREEV" -name '*.apk' -printf '%P\n' | while read -r rel; do
    mkdir -p "$GEN/prebuilt_apps/$(dirname "$rel")"
    cp "$TREEV/$rel" "$GEN/prebuilt_apps/$rel"
    echo "  staged vendor apk for BUILD_PREBUILT: $rel ($(stat -c %s "$GEN/prebuilt_apps/$rel") B)"
done

# ---- 5. the generated staging config -------------------------------------------
python3 "$REPO/tools/gen_vendor_staging.py" "$TREEV" "$GEN" \
    --src-prefix "$SRC" \
    --reference-label "$LABEL" \
    --build-prop "$OUT/prebuilt/vendor_build.prop.$SHAPE" \
    --compat-matrix "$OUT/prebuilt/vendor_compat_matrix.$SHAPE.xml" \
    --skip-file "$GEN/vendor_props_skip.txt"

# ---- 6. destinations the build installs itself --------------------------------
# PRODUCT_COPY_FILES creates an install rule per destination. If a module installs the same path,
# ckati aborts ("overriding commands for target out/.../vendor/bin/applypatch, previously defined
# at out/soong/installs-lineage_rk3399.mk"). This partition has 162 such paths, all compiled from
# upstream AOSP source (toybox/sh/awk, libchrome, libdrm, the AOSP default HAL services and their
# default impls, generated sepolicy) - Android 14's own build is the right file, and every Rockchip
# HAL keeps its own name, so no blob that matters is dropped. The install list comes from the
# previous build's out/soong; without it (first sync) this step is skipped and the collisions show
# up in the build instead.
INSTALLS=$(ls "$TREE"/out/soong/installs-*.mk 2>/dev/null | head -1)
if [ -n "$INSTALLS" ]; then
    python3 "$REPO/tools/vendor_conflicts.py" "$TREE" "$GEN" \
      --write-drop-list "$GEN/vendor_build_wins.txt" 2>&1 | tail -6
    # Destinations discovered by ckati in earlier passes: legacy Make modules install paths, and no
    # generated file lists them, so vendor_conflicts.py cannot find them statically.
    if [ -s "$GEN/vendor_dest_skip_extra.txt" ]; then
        while read -r p; do
            case "$p" in ''|'#'*) continue ;; esac
            grep -qxF "$p" "$GEN/vendor_build_wins.txt" || printf '%s\n' "$p" >> "$GEN/vendor_build_wins.txt"
        done < "$GEN/vendor_dest_skip_extra.txt"
    fi
    # Declared gaps (vendor_dest_deviations.txt): neither the blob nor an Android 14 module. Without
    # this merge the stock blob would land back in /vendor and init would start a daemon nothing
    # asked for (rild against a modem that does not exist).
    if [ -s "$GEN/vendor_dest_deviations.txt" ]; then
        while read -r p; do
            case "$p" in ''|'#'*) continue ;; esac
            grep -qxF "$p" "$GEN/vendor_build_wins.txt" || printf '%s\n' "$p" >> "$GEN/vendor_build_wins.txt"
        done < "$GEN/vendor_dest_deviations.txt"
    fi
    python3 "$REPO/tools/gen_vendor_staging.py" "$TREEV" "$GEN" \
        --src-prefix "$SRC" \
        --reference-label "$LABEL" \
        --build-prop "$OUT/prebuilt/vendor_build.prop.$SHAPE" \
        --compat-matrix "$OUT/prebuilt/vendor_compat_matrix.$SHAPE.xml" \
        --skip-file "$GEN/vendor_props_skip.txt" \
        --dest-skip "$GEN/vendor_build_wins.txt"
fi

echo "shape:        $SHAPE ($LABEL reference)"
echo "vendor blobs: $TREEV ($(find "$TREEV" -type f | wc -l) files, $(du -sh "$TREEV" | cut -f1))"
echo "reference:    $REF"
echo "kernel:       $KERNEL (its vermagic must match the .ko files in $TREEV/lib/modules)"
# Distinct vermagics, not the first one found: stock trees carry leftovers from other kernels
# (mali_kbase.ko at 4.4.167), so a single-match echo is misleading. Per-module checking with the
# kernel banner is scripts/deploy_device.sh's job.
vm=$(find "$TREEV/lib/modules" -name '*.ko' -exec LC_ALL=C strings {} \; 2>/dev/null | sed -n 's/.*vermagic=\([^ ]*\).*/\1/p' | sort -u | tr '\n' ' ')
echo "modules:      $(find "$TREEV/lib/modules" -name '*.ko' 2>/dev/null | wc -l) .ko, vermagics: ${vm:-none}"
echo "run scripts/deploy_device.sh after this (it copies the generated .mk files)"
