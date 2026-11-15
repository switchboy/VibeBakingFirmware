#!/usr/bin/env bash
# Build the signed package for the recovery fallback route ("apply update from external storage").
#
# It is deliberately TINY: the payload images stay as files in the card root, and the updater-script dd's
# them straight from the card. Embedding 3.2 GiB in the zip would need room on the unit to unpack it, and
# recovery has none. Card layout the script assumes (and prints):
#   /external_sd/update.zip        <- this zip, in the card root, where recovery looks for it
#   /external_sd/super-a14.img     <- the shape's raw-super.img
#   /external_sd/boot-a14.img      <- the shape's boot image (SHAPE=a10: boot-a10k-a14rd.img,
#                                    SHAPE=a11: a14-boot-fixed.img)
#
#   scripts/build_recovery_fallback_zip.sh [outdir]      default /run/media/Daan/Opslagmonster/a14-work/huzip-card
#
# Signing goes through scripts/sign_update_zip.py with the AOSP testkey (cert der-sha a40da80a59d170ca),
# which our own system slice puts in /system/etc/security/otacerts.zip next to HCT's cert. Recovery
# verifies the package BEFORE running the updater-script, so if the hashed byte range (the --scope guess)
# is wrong the install is refused with nothing written - it cannot brick anything.
# The adb-root installer (scripts/install_a14_from_adb_root.sh) stays the primary route.
set -euo pipefail

WORK=${WORK:-/run/media/Daan/Opslagmonster/a14-work}
OUT=${1:-$WORK/huzip-card}
REPO=${REPO:-/run/media/Daan/Opslagmonster/VibeBakingFirmware}
SCOPE=${SCOPE:-content-plus-EOCD-clen0}
# Which shape the card carries (D46): shape A is the default, shape B the Android 11 fallback. The zip
# itself holds no payload - it only names the files the installer dd's from the card root.
SHAPE=${SHAPE:-a10}
case "$SHAPE" in
  a10) CHK=$WORK/a14chk-shapeA; BOOTNAME=boot-a10k-a14rd.img ;;
  a11) CHK=$WORK/a14chk;        BOOTNAME=a14-boot-fixed.img ;;
  *) echo "SHAPE must be a10 or a11"; exit 1 ;;
esac
mkdir -p "$OUT"

say() { printf '%s\n' "$1"; }

python3 - "$OUT" "$REPO/scripts/recovery_updater.script" <<'PY'
import pathlib, zipfile, sys
out, script = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
body = script.read_bytes()
notes = (
    b'Android 14 bring-up for the PX6 (RK3399 / HCT4 MTCE).\n'
    b'The images live next to this zip in the card root; recovery dd\'s them, it does not unpack them.\n'
    b'Files expected: super-a14.img (logical super container), boot-a14.img (the shape\'s kernel plus\n'
    b'the Android 14 first-stage ramdisk). Shape A: kernel 4.19.111+ #190 with 4.19.111+ modules in\n'
    b'super; shape B: kernel 4.19.193 #24 with 4.19.193 modules. boot-a14.img and super-a14.img must\n'
    b'always move together, or every .ko refuses at insmod (docs/flash.md).\n'
    b'Nothing here touches uboot/trust/dtb/dtbo/vbmeta/security (D18) and no partition table is\n'
    b'written (D19).\n'
)
p = out / 'update-unsigned.zip'
# ZIP_STORED, not DEFLATED: the payload is not in this zip and an updater-script must be read verbatim.
with zipfile.ZipFile(p, 'w', zipfile.ZIP_STORED) as z:
    z.writestr('updater-script', body)
    z.writestr('a14-notes.txt', notes)
print('unsigned zip', p.stat().st_size, 'bytes, entries:', z.namelist())
PY

python3 "$REPO/scripts/sign_update_zip.py" "$OUT/update-unsigned.zip" "$OUT/update.zip" --scope "$SCOPE"

python3 - "$OUT/update.zip" <<'PY'
import hashlib, pathlib, struct, zipfile, sys
p = pathlib.Path(sys.argv[1])
raw = p.read_bytes()
c = zipfile.ZipFile(p).comment
msg = b'signed by SignApk'
pk = c[len(msg) + 1:-6]
total = struct.unpack('<H', c[-2:])[0]
sig_start = struct.unpack('<H', c[-6:-4])[0]
print('signed zip', len(raw), 'bytes; comment', len(c), 'B')
print('  message+NUL:', c.startswith(msg + b'\x00'), ' trailer ffff:', c[-4:-2] == b'\xff\xff')
print('  total_size == len(comment):', total == len(c))
print('  signature_start == len(pkcs7) + 6:', sig_start == len(pk) + 6)
print('  sha256 of signed zip:', hashlib.sha256(raw).hexdigest())
PY

say "== card layout =="
say "  $OUT/update.zip            <- copy to the card root as /external_sd/update.zip"
say "  super-a14.img    <- cp $CHK/raw-super.img"
say "  boot-a14.img     <- cp $CHK/$BOOTNAME"
say "== how to stage the payload card =="
say "  cp $OUT/update.zip <card>/update.zip"
say "  cp $CHK/raw-super.img <card>/super-a14.img"
say "  cp $CHK/$BOOTNAME <card>/boot-a14.img"
say "  sha256sum super-a14.img boot-a14.img   # compare against $CHK/sha256.txt before burning"
