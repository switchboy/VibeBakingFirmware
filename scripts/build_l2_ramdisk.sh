#!/usr/bin/env sh
# build_l2_ramdisk.sh - assemble the L2 ramdisk (D62): the stock Android 10 ramdisk with Android 14's
# static first-stage init in place of the stock /init, plus /first_stage_ramdisk/fstab.rk30board.
#
#   sh scripts/build_l2_ramdisk.sh            # builds into $OUT (default a14-work/ladder/L2-ramdisk.gz)
#   CAPTURE=<boot.bin> PAYLOAD_INIT=<init> LADDER_DIR=<dir> sh scripts/build_l2_ramdisk.sh
#
# Why these two files and nothing else:
# * Android 14's init reads the first-stage fstab only from `/first_stage_ramdisk/fstab.<hardware>`
#   (Android 10 reads it at the ramdisk root), so that directory must exist and hold the fstab.
# * The fstab placed there is the STOCK one, not our payload's: our payload fstab lists `system_ext`,
#   which the Android 10 `super` does not contain, and a logical partition that does not exist makes
#   first-stage mount fail. L2 tests Android 14's init against Android 10's super (D62), so the
#   partition set must be Android 10's.
# * Everything else in the ramdisk stays the OEM's, so a failure can be attributed to init's own code.
#
# It refuses to run unless the capture hashes the Nov 17 image and the payload init hashes the digest
# measured Nov 19 from the payload's own ramdisk, and it verifies the result by decompressing it and
# reading `/init` back out of the archive. It never touches the unit, the NAS or the stick.
set -u

CAPTURE=${CAPTURE:-/run/media/Daan/Opslagmonster/a14-work/hu-stock-backup-refresh/boot.bin}
EXPECTED_SHA=${EXPECTED_SHA:-4121b58f77598d73b1b7958c36d1c5a81c8b82ba176cce9f6863b67992ce5b3d}
PAYLOAD_INIT=${PAYLOAD_INIT:-/run/media/Daan/Opslagmonster/a14-work/tmp/ramdisks/a14/init}
PAYLOAD_INIT_SHA=${PAYLOAD_INIT_SHA:-631f960cbb96149069228b04287739129e40ac83c8c0b82ddd6c65f05d4a4c56}
LADDER_DIR=${LADDER_DIR:-/run/media/Daan/Opslagmonster/a14-work/ladder}
REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$LADDER_DIR/L2-ramdisk.gz}
SCRATCH=${HU_SCRATCH_ROOT:-/run/media/Daan/Opslagmonster/a14-work/tmp}

got=$(sha256sum "$CAPTURE" | cut -d' ' -f1)
[ "$got" = "$EXPECTED_SHA" ] || { echo "capture digest $got is not $EXPECTED_SHA - refusing to build from an image we cannot trace" >&2; exit 1; }
[ -f "$PAYLOAD_INIT" ] || { echo "no payload init at $PAYLOAD_INIT" >&2; exit 1; }
pay_sha=$(sha256sum "$PAYLOAD_INIT" | cut -d' ' -f1)
if [ "$pay_sha" != "$PAYLOAD_INIT_SHA" ]; then
  echo "payload init $pay_sha is not the measured $PAYLOAD_INIT_SHA - refusing" >&2; exit 1
fi

WORK="$SCRATCH/l2-ramdisk-$$"
rm -rf "$WORK"; mkdir -p "$WORK/unpack" || exit 1

REPO="$REPO" python3 - "$CAPTURE" "$WORK/ramdisk.gz" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(os.environ["REPO"], "tools"))
import rebuild_boot_faithful as R
d = open(sys.argv[1], "rb").read()
ks, rs, ss, ro, so = R.offsets(d)
blob = d[ro:ro + rs]
if blob[:2] != b"\x1f\x8b":
    sys.exit(f"the stock ramdisk at {ro:,} is not gzip ({blob[:2]!r})")
open(sys.argv[2], "wb").write(blob)
print(f"stock ramdisk: declared {rs:,} B at {ro:,}, gzip {len(blob):,} B")
PY

python3 - "$WORK/ramdisk.gz" "$WORK/ramdisk.cpio" <<'PY'
import gzip, sys
data = gzip.decompress(open(sys.argv[1], "rb").read())
open(sys.argv[2], "wb").write(data)
print(f"decompressed cpio {len(data):,} B")
PY

( cd "$WORK/unpack" && cpio -idmf --quiet < ../ramdisk.cpio ) || { echo "cpio unpack failed" >&2; exit 1; }
cp "$PAYLOAD_INIT" "$WORK/unpack/init" && chmod 755 "$WORK/unpack/init"
mkdir -p "$WORK/unpack/first_stage_ramdisk"
cp "$WORK/unpack/fstab.rk30board" "$WORK/unpack/first_stage_ramdisk/fstab.rk30board" || { echo "stock fstab missing from the ramdisk" >&2; exit 1; }
grep -q "system_ext" "$WORK/unpack/first_stage_ramdisk/fstab.rk30board" && { echo "the stock fstab must not list system_ext (Android 10 super has none)" >&2; exit 1; }
sed -n '1,12p' "$WORK/unpack/first_stage_ramdisk/fstab.rk30board" | grep -n "first_stage_mount" | sed 's/^/  fstab entry: /'

( cd "$WORK/unpack" && find . ! -name 'ramdisk.cpio' | cpio -oH newc --owner=root:root 2>/dev/null | gzip -9n > "$OUT" ) || { echo "repack failed" >&2; exit 1; }

mkdir -p "$WORK/verify" && ( cd "$WORK/verify" && cp "$OUT" ./L2-ramdisk.gz && gunzip -c L2-ramdisk.gz | cpio -idmf --quiet ) || { echo "verification unpack failed" >&2; exit 1; }
got_init=$(sha256sum "$WORK/verify/init" | cut -d' ' -f1)
[ "$got_init" = "$pay_sha" ] || { echo "FAIL: /init in the repacked archive is $got_init, not the payload init $pay_sha" >&2; exit 1; }
[ -f "$WORK/verify/first_stage_ramdisk/fstab.rk30board" ] || { echo "FAIL: first_stage_ramdisk/fstab.rk30board missing from the archive" >&2; exit 1; }
cmp -s "$WORK/verify/first_stage_ramdisk/fstab.rk30board" "$WORK/unpack/fstab.rk30board" || { echo "FAIL: the fstab under first_stage_ramdisk is not the stock fstab" >&2; exit 1; }
echo "verified: /init is the payload init ($got_init), fstab under first_stage_ramdisk equals the stock fstab"
ls "$WORK/verify" | head -12 | sed 's/^/  archive entry: /'
gzip -l "$OUT" | awk 'NR==2 {print "  gzip " $2 " B -> cpio " $3 " B"}'
sha256sum "$OUT"
echo "built $OUT - nothing is flashed; each write needs the owner's go (D38/D40)"
