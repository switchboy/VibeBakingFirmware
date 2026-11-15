#!/usr/bin/env bash
# Rebuild the two candidate boot images that carry a first-stage fstab (D34).
#
# Measured on Nov 10: Android 14's first-stage init reads its fstab from the devicetree
# (/proc/device-tree/firmware/android/fstab, compatible "android,fstab") or from the ramdisk at
# /first_stage_ramdisk/fstab.<hardware>. Our payload had neither - our DTB (the vendor A11 one) has no
# fstab node, the unit's untouched A10-era dtbo marks the overlay's vbmeta/fstab children
# status="disabled", and our ramdisk has no first_stage_ramdisk/ and no fstab file at all - so init
# never mounted /system. androidboot.hardware=rk30board means the file must be fstab.rk30board.
#
# Two outputs, neither one flashed (D30 keeps the serial gate):
#   a14-fixed.img        our current boot.img + /first_stage_ramdisk/fstab.rk30board, still the vendor
#                        Android 11 kernel/DTB, so the generation mix (D33) stays.
#   boot-a10k-a14rd.img  the coherent shape: OEM Android 10 kernel + OEM Android 10 `second` (which
#                        carries the A10 DTB, header dtb_size = 0) + our Android 14 ramdisk with the
#                        fstab + our own cmdline. No boot-chain partition is touched (D18).
#                        CAVEAT measured Nov 15: this image pairs with the STOCK 4.19.111+ module set
#                        (a14-work/hu-stock-backup/vendor-modules/), not with the 4.19.193 modules in
#                        our super. Its vendor manifest keeps target-level="4" and adds **no** <kernel>
#                        tag: libvintf only checks kernel compatibility when the manifest declares one
#                        (HalManifest.cpp:576, used at 554), and the stock Android 10 manifest has none.
#                        See docs/findings.md and docs/feasibility.md before flashing it.
# Flashing the OEM boot-a10.img unchanged is NOT a path: its ramdisk fstab lists only
# system/vendor/odm/product, no system_ext, which Android 14 needs.
#
#   SRC_BOOT=<our boot.img> OEM_A10_BOOT=<OEM Android 10 boot.img> \
#   FSTAB=<fstab.rk30board with 5 logical ext4 entries> OUT=<dir> [HOST_BIN=<aosp host bin>] \
#   scripts/rebuild_boot_with_fstab.sh
#
# mkbootimg --header_version 2 refuses a DTB-less build ("DTB image must not be empty") and no longer
# takes --os-version/--os-patch-level, so the coherent image is assembled byte-wise instead. The layout
# measured Nov 15 from the stock backup's `boot.bin` and from our own `boot.img` is: a header block
# padded to `page_size` (2048; the header struct itself is 1660 B, dtb_size/dtb_addr at 1648/1652), then
# each component **aligned to page_size**: kernel at 2048, ramdisk at 2048+roundup(kernel_size,2048),
# `second` at ramdisk_offset+roundup(ramdisk_size,2048). Slicing or writing components contiguously
# shifts `second` and u-boot/init then read padding instead of the blob that carries the DTB (D38).
set -u

SRC_BOOT=${SRC_BOOT:?set SRC_BOOT to our Android 14 boot.img}
OEM_A10_BOOT=${OEM_A10_BOOT:?set OEM_A10_BOOT to the OEM Android 10 boot.img}
FSTAB=${FSTAB:?set FSTAB to a fstab.rk30board file}
# Scratch lives on the repo volume, not /var/tmp: the workstation's root filesystem is full and the NAS
# SSData volume is at 100% too, which is what made lpmake fail with "Disk quota exceeded".
OUT=${OUT:-/run/media/Daan/Opslagmonster/a14-work/a14repack}
HOST_BIN=${HOST_BIN:-/srv/dev-disk-by-label-SSData/aospbuild/lineage21s/out/host/linux-x86/bin}
HDR=1660

say() { printf '%s\n' "$1"; }

export PATH="$HOST_BIN:$PATH"
command -v repack_bootimg >/dev/null || { say "ABORT: repack_bootimg not in $HOST_BIN"; exit 1; }
command -v unpack_bootimg >/dev/null || { say "ABORT: unpack_bootimg not in $HOST_BIN"; exit 1; }
# repack_bootimg shells out to `toybox cpio`, not to the distro cpio. The workstation has the script in
# /usr/bin but no toybox, so step 1 dies in the traceback *after* copying the source image, and step 2
# would then ship a coherent image whose ramdisk has no fstab at all (D34). Require toybox up front.
command -v toybox >/dev/null || { say "ABORT: repack_bootimg needs 'toybox' on PATH - run this on the build host (out/host/linux-x86/bin)"; exit 1; }
[ -f "$SRC_BOOT" ] || { say "ABORT: no $SRC_BOOT"; exit 1; }
[ -f "$OEM_A10_BOOT" ] || { say "ABORT: no $OEM_A10_BOOT"; exit 1; }
[ -f "$FSTAB" ] || { say "ABORT: no $FSTAB"; exit 1; }
grep -c 'first_stage_mount' "$FSTAB" | grep -qv '^0$' || { say "ABORT: $FSTAB has no first_stage_mount entries"; exit 1; }
grep -q 'system_ext' "$FSTAB" || { say "ABORT: $FSTAB has no system_ext entry; Android 14 needs it"; exit 1; }

mkdir -p "$OUT"
FIXED="$OUT/a14-fixed.img"
COHERENT="$OUT/boot-a10k-a14rd.img"

say "== 1. minimal fix: add /first_stage_ramdisk/fstab.rk30board to our own boot image =="
cp -a "$SRC_BOOT" "$FIXED"
repack_bootimg --local --dst_bootimg "$FIXED" \
  --ramdisk_add "$FSTAB:first_stage_ramdisk/fstab.rk30board" 2>&1 | tail -4

say "== 2. coherent fix: OEM A10 kernel + OEM A10 second + the ramdisk from step 1 =="
python3 - "$FIXED" "$OEM_A10_BOOT" "$COHERENT" "$HDR" <<'PY'
import re, struct, sys

src, oem, out, hdr_size = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
d = open(src, 'rb').read()          # step 1 output: A14 init + first_stage_ramdisk/fstab.rk30board
a = open(oem, 'rb').read()

def page_of(b):
    # pagesize sits in the header's reserved area (offset 56 in a v2 header); 0 means the 2048 default.
    # Anything that is not a real page size is treated as the default, and the content self-check below
    # catches a wrong guess, because a mis-read offset lands on padding instead of the payload.
    p = struct.unpack('<I', b[56:60])[0]
    return p if p in (2048, 4096, 8192, 16384, 32768) else 2048

def offsets(b):
    """Header block padded to page_size, then every component aligned to page_size."""
    ks, rs, ss = (struct.unpack('<I', b[8:12])[0], struct.unpack('<I', b[16:20])[0],
                  struct.unpack('<I', b[24:28])[0])
    pg = page_of(b)
    ko = pg
    ro = ko + ((ks + pg - 1) // pg) * pg
    so = ro + ((rs + pg - 1) // pg) * pg
    if ks == 0 or ro + rs > len(b) or (ss and so + ss > len(b)):
        raise SystemExit("boot image layout does not match its header sizes")
    return pg, ks, rs, ss, ko, ro, so

def looks_like_payload(b):
    return b[:2] == b'\x1f\x8b' or b[:4] in (b'0707', b'\x04\x22\x50\x44') or b[:8] != b'\x00' * 8

pg, ks, rs, ss, ko, ro, so = offsets(d)
ramdisk = d[ro:ro + rs]                       # our A14 first-stage init + the fstab
if not looks_like_payload(ramdisk):
    raise SystemExit("first-stage ramdisk at %d is padding - wrong ramdisk offset" % ro)

_, aks, ars, ass, ako, aro, aso = offsets(a)
kernel = a[ako:ako + aks]                     # OEM Android 10 kernel payload (#190)
second = a[aso:aso + ass] if ass else b''     # OEM blob that carries the A10 DTB (D38)
if kernel[:8] == b'\x00' * 8:
    raise SystemExit("kernel payload at %d is padding - wrong kernel offset" % ako)
if ass and second[:8] == b'\x00' * 8:
    raise SystemExit("second stage at %d is padding; the DTB lives inside it (D38)" % aso)

hdr = bytearray(d[:hdr_size])                 # keep our cmdline, addresses, page size, header v2
struct.pack_into('<I', hdr, 8, len(kernel))
struct.pack_into('<I', hdr, 16, len(ramdisk))
struct.pack_into('<I', hdr, 24, len(second))
struct.pack_into('<I', hdr, 1648, 0)          # dtb_size -> 0, like the OEM A10 image (the DTB lives in second)
struct.pack_into('<I', hdr, 1652, 0)          # dtb_addr likewise

po = page_of(d)
pad = lambda n: b'\x00' * ((-n) % po)
image = bytes(hdr) + b'\x00' * (po - len(hdr))
image += kernel + pad(len(kernel)) + ramdisk + pad(len(ramdisk)) + second + pad(len(second))
open(out, 'wb').write(image)

# Read the finished image back exactly the way a boot loader computes its offsets, so a misplaced
# component cannot be shipped: sizes are re-parsed from the image we just wrote, not from the inputs.
chk = open(out, 'rb').read()
p2, k2, r2, s2, k2o, r2o, s2o = offsets(chk)
ok = (chk[k2o:k2o + k2] == kernel and chk[r2o:r2o + r2] == ramdisk
      and (chk[s2o:s2o + s2] == second if s2 else True))
if not ok:
    raise SystemExit("self-check failed: kernel/ramdisk/second not readable at their computed offsets")

dtbs = [m.start() for m in re.finditer(re.escape(b'\xd0\x0d\xfe\xed'), chk)
        if 200 < struct.unpack('>I', chk[m.start() + 4:m.start() + 8])[0] < 4_000_000]
print(f"kernel {len(kernel):,}B @{k2o}  ramdisk {len(ramdisk):,}B @{r2o}  "
      f"second {len(second):,}B @{s2o}  page {po}  DTB blobs {len(dtbs)} "
      f"at {[f'{p:,}' for p in dtbs]}  -> {out}")
print("self-check OK: kernel, ramdisk and second are readable at the offsets a boot loader computes")
PY

say "== 3. verify both images =="
for img in "$FIXED" "$COHERENT"; do
  say "--- $img"
  unpack_bootimg --boot_img "$img" 2>&1 | grep -E 'boot magic|kernel_size|kernel load|ramdisk size|second bootloader size|second bootloader load|kernel tags|page size|header version|dtb size|command line args' | cut -c1-160
  tmp=$(mktemp -d)
  unpack_bootimg --boot_img "$img" --out "$tmp" >/dev/null 2>&1
  mkdir -p "$tmp/rd"
  (gzip -dc "$tmp/ramdisk" 2>/dev/null || cat "$tmp/ramdisk") | (cd "$tmp/rd" && cpio -id --quiet 2>/dev/null)
  if [ -f "$tmp/rd/first_stage_ramdisk/fstab.rk30board" ]; then
    say "  ramdisk carries first_stage_ramdisk/fstab.rk30board ($(wc -c < "$tmp/rd/first_stage_ramdisk/fstab.rk30board") bytes)"
    grep -E 'logical.*first_stage_mount' "$tmp/rd/first_stage_ramdisk/fstab.rk30board" | cut -c1-110 | sed 's/^/    /'
  else
    say "  ABORT: ramdisk has no first_stage_ramdisk/fstab.rk30board"
    exit 1
  fi
  rm -rf "$tmp"
done

say "== shas (record these before any flash) =="
(cd "$OUT" && sha256sum a14-fixed.img boot-a10k-a14rd.img fstab.rk30board 2>/dev/null | cut -c1-80)
say "Nothing was written to the unit. a14-fixed.img is shape B (kernel #24, modules vermagic=4.19.193, target"
say "level 5); boot-a10k-a14rd.img is shape A (kernel #190, stock 4.19.111+ modules, target level 4). Neither"
say "goes to eMMC until the offline gate set passes (D47), and a kernel we build ourselves is card-booted first."
say "Neither image touches uboot/trust/dtb/dtbo/vbmeta/security or the GPT (D18/D19)."
