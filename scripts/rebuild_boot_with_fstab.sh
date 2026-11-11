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
# Flashing the OEM boot-a10.img unchanged is NOT a path: its ramdisk fstab lists only
# system/vendor/odm/product, no system_ext, which Android 14 needs.
#
#   SRC_BOOT=<our boot.img> OEM_A10_BOOT=<OEM Android 10 boot.img> \
#   FSTAB=<fstab.rk30board with 5 logical ext4 entries> OUT=<dir> [HOST_BIN=<aosp host bin>] \
#   scripts/rebuild_boot_with_fstab.sh
#
# mkbootimg --header_version 2 refuses a DTB-less build ("DTB image must not be empty") and no longer
# takes --os-version/--os-patch-level, so the coherent image is assembled byte-wise instead. The boot
# image layout measured here is: 1660-byte header, then kernel, ramdisk and `second` laid out
# contiguously, tail padded to page_size (2048); dtb_size/dtb_addr sit at header offsets 1648/1652.
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

def sizes(b):
    return (struct.unpack('<I', b[8:12])[0], struct.unpack('<I', b[16:20])[0],
            struct.unpack('<I', b[24:28])[0])

ks, rs, ss = sizes(d)
ramdisk = d[hdr_size + ks:hdr_size + ks + rs]           # our A14 first-stage init + the fstab
aks, ars, ass = sizes(a)
kernel = a[hdr_size:hdr_size + aks]                     # OEM Android 10 kernel payload
second = a[hdr_size + aks + ars:hdr_size + aks + ars + ass]  # OEM blob that carries the A10 DTB

hdr = bytearray(d[:hdr_size])                           # keep our cmdline, addresses, page size, header v2
struct.pack_into('<I', hdr, 8, len(kernel))
struct.pack_into('<I', hdr, 16, len(ramdisk))
struct.pack_into('<I', hdr, 24, len(second))
struct.pack_into('<I', hdr, 1648, 0)                    # dtb_size -> 0, like the OEM A10 image (DTB lives in second)
page = struct.unpack('<I', hdr[36:40])[0]
body = kernel + ramdisk + second
image = bytes(hdr) + body + b'\x00' * ((-len(body)) % page)
open(out, 'wb').write(image)

dtbs = [m.start() for m in re.finditer(re.escape(b'\xd0\x0d\xfe\xed'), image)
        if 200 < struct.unpack('>I', image[m.start() + 4:m.start() + 8])[0] < 4_000_000]
print(f"kernel {len(kernel):,}B  ramdisk {len(ramdisk):,}B  second {len(second):,}B  DTB blobs {len(dtbs)} "
      f"at {[f'{p:,}' for p in dtbs]}  -> {out}")
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
say "Nothing was written to the unit. Flashing either image pairs with the A14 super already on it and"
say "touches no boot-chain partition (D18); D30 still requires a serial console reading first."
