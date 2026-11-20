#!/usr/bin/env bash
# patch_recovery_evidence.sh - builds recovery-evidence.img from the CURRENT recovery capture (D80).
#
# Partition 8 became writable on Nov 20 under one condition (D80): the MTC/mainboard flashing path must stay
# intact. That is honoured by shipping the stock recovery bytes verbatim and adding only two files to the
# ramdisk:
#   /sbin/hu-evidence.sh              - the evidence reader + boot restorer (hu_recovery_evidence.sh)
#   /init.recovery.rk30board.rc       - stock content byte-for-byte + one appended service block
#
# scripts/repack_recovery_python.py splices the new ramdisk and keeps kernel/second/recovery_dtbo and every
# header field verbatim, changing only ramdisk_size and the stored dtbo offset. This script proves that by
# comparing the two images and the two unpacked trees, and it refuses to call the image buildable if any
# byte outside the ramdisk span moves. Everything runs locally - no NAS, no unit.
#
#   scripts/patch_recovery_evidence.sh            # default capture + default out dir
#   scripts/patch_recovery_evidence.sh <capture> <outdir>
set -u
REPO=/run/media/Daan/Opslagmonster/VibeBakingFirmware
WORK=/run/media/Daan/Opslagmonster/a14-work
CAPTURE="${1:-$WORK/hu-stock-backup-refresh/recovery.bin}"
OUTDIR="${2:-$WORK/recovery-evidence}"
LOG="$OUTDIR/patch.log"
PART_BYTES=100663296
DTBO_SIZE=803          # measured Nov 12 by unpack_bootimg on the stock recovery.bin (patch.log line 30)

mkdir -p "$OUTDIR/inject"
: > "$LOG"
say() { printf '%s\n' "$1" >> "$LOG"; }
fail() { say "REFUSE: $1"; echo "REFUSE: $1"; exit 1; }

[ -f "$CAPTURE" ] || fail "capture missing: $CAPTURE"
[ "$(stat -c %s "$CAPTURE")" = "$PART_BYTES" ] || fail "capture is not partition-sized"
sha256sum "$CAPTURE" >> "$LOG"

say "=== 1. extract the capture's ramdisk ==="
RD="$OUTDIR/rd-src"
rm -rf "$RD"; mkdir -p "$RD"
python3 - "$CAPTURE" "$RD" >> "$LOG" 2>&1 <<'PY'
import gzip, sys, os
sys.path.insert(0, "/run/media/Daan/Opslagmonster/VibeBakingFirmware/tools")
import rebuild_boot_faithful as R
src, rd = sys.argv[1], sys.argv[2]
d = open(src, "rb").read()
ks, rs, ss, ro, so = R.offsets(d)
open(os.path.join(rd, "ramdisk.cpio"), "wb").write(gzip.decompress(d[ro:ro+rs]))
print(f"kernel {ks} ramdisk gz {rs} @{ro} second {ss} @{so}")
PY
cd "$RD" && cpio -idmf --quiet < ramdisk.cpio 2>>"$LOG" && rm -f ramdisk.cpio
[ -f "$RD/init.rc" ] || fail "ramdisk did not extract"
[ -f "$RD/sbin/busybox" ] && [ -f "$RD/sbin/sh" ] || fail "ramdisk lost its static busybox/sh"
say "extracted: $(ls "$RD" | tr '\n' ' ')"

say "=== 2. overlay exactly two files ==="
cp "$REPO/scripts/hu_recovery_evidence.sh" "$RD/sbin/hu-evidence.sh" && chmod 755 "$RD/sbin/hu-evidence.sh"
cp "$REPO/scripts/hu_recovery_evidence_append.rc" "$RD/init.recovery.rk30board.rc" && chmod 755 "$RD/init.recovery.rk30board.rc"
cp "$REPO/scripts/hu_recovery_evidence.sh" "$OUTDIR/inject/hu-evidence.sh"
cp "$REPO/scripts/hu_recovery_evidence_append.rc" "$OUTDIR/inject/init.recovery.rk30board.rc"
sha256sum "$RD/sbin/hu-evidence.sh" "$RD/init.recovery.rk30board.rc" >> "$LOG"

say "=== 3. the appended rc keeps the stock file verbatim ==="
STOCK_RC_LEN=$(stat -c %s "$REPO/scripts/hu_recovery_evidence_append.rc")
head -c "$STOCK_RC_LEN" "$RD/init.recovery.rk30board.rc" > "$OUTDIR/rc-prefix.bin"
# The appended block starts with a blank line, so compare the stock bytes up to the marker.
python3 - "$CAPTURE" "$RD/init.recovery.rk30board.rc" >> "$LOG" 2>&1 <<'PY'
import sys, gzip
sys.path.insert(0, "/run/media/Daan/Opslagmonster/VibeBakingFirmware/tools")
import rebuild_boot_faithful as R
cap, new = sys.argv[1], sys.argv[2]
d = open(cap, "rb").read()
ks, rs, ss, ro, so = R.offsets(d)
import subprocess, os, tempfile
tmp = tempfile.mkdtemp()
open(os.path.join(tmp, "r.cpio"), "wb").write(gzip.decompress(d[ro:ro+rs]))
subprocess.run(["cpio", "-idmf", "--quiet"], cwd=tmp, stdin=open(os.path.join(tmp, "r.cpio"), "rb"),
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
old = open(os.path.join(tmp, "init.recovery.rk30board.rc"), "rb").read()
nb = open(new, "rb").read()
if not nb.startswith(old):
    print("REFUSE: appended rc does not start with the stock file verbatim"); sys.exit(1)
tail = nb[len(old):]
print(f"stock rc {len(old)} B kept verbatim; appended {len(tail)} B")
print("appended service lines:", tail.count(b"service hu_evidence"), "start lines:", tail.count(b"start hu_evidence"))
print("stock markers still present:", b"service console" in old, b"sys.usb.controller" in old)
PY
grep -q "REFUSE: appended rc" "$LOG" && fail "rc splice refused"
grep "appended service lines: 1 start lines: 1" "$LOG" > /dev/null || fail "appended block not exactly once"

say "=== 4. splice the image ==="
python3 "$REPO/scripts/repack_recovery_python.py" "$CAPTURE" "$RD" "$OUTDIR/recovery-evidence.img" \
  "$PART_BYTES" "$DTBO_SIZE" >> "$LOG" 2>&1 | tail -14
OUT="$OUTDIR/recovery-evidence.img"
[ -f "$OUT" ] || fail "no output image written"

say "=== 5. only the ramdisk span may differ ==="
python3 - "$CAPTURE" "$OUT" >> "$LOG" 2>&1 <<'PY'
import struct, sys, hashlib
sys.path.insert(0, "/run/media/Daan/Opslagmonster/VibeBakingFirmware/tools")
import rebuild_boot_faithful as R
a = open(sys.argv[1], "rb").read(); b = open(sys.argv[2], "rb").read()
ka, ra, sa, ao, so = R.offsets(a)
kb, rb, sb, bo, sbo = R.offsets(b)
ca, cb = R.roundup(so + sa), R.roundup(sbo + sb)
print(f"capture: kernel {ka} ramdisk {ra}@{ao} second {sa}@{so} content end {ca}")
print(f"patched: kernel {kb} ramdisk {rb}@{bo} second {sb}@{sbo} content end {cb}  file {len(b)}")
if ka != kb or sa != sb: print("REFUSE: kernel or second size changed")
if a[2048:2048+ka] != b[2048:2048+ka]: print("REFUSE: kernel bytes changed")
if a[so:so+sa] != b[sbo:sbo+sa]: print("REFUSE: second bytes changed")
da = struct.unpack_from("<Q", a, 1636)[0]; db = struct.unpack_from("<Q", b, 1636)[0]
if a[da:da+803] != b[db:db+803]: print("REFUSE: recovery_dtbo bytes changed")
# Everything the patched image holds, up to its own content end, must match the capture except the
# ramdisk span and the two header fields that describe it.
allowed = set(range(16, 20)) | set(range(1636, 1644))
bad = [i for i in range(min(len(b), 2048)) if a[i] != b[i] and i not in allowed]
if bad: print(f"REFUSE: header bytes changed outside ramdisk_size/dtbo offset: {bad[:12]}")
for i in range(2048, cb):
    if a[i] != b[i] and not (ao <= i < R.roundup(ra + ao) or sbo <= i < cb):
        print(f"REFUSE: byte {i} changed outside the ramdisk/second span"); break
print(f"kernel blob digest  {hashlib.sha256(a[2048:2048+ka]).hexdigest()[:12]} vs {hashlib.sha256(b[2048:2048+kb]).hexdigest()[:12]}")
print(f"second blob digest  {hashlib.sha256(a[so:so+sa]).hexdigest()[:12]} vs {hashlib.sha256(b[sbo:sbo+sa]).hexdigest()[:12]}")
print(f"dtbo digest         {hashlib.sha256(a[da:da+803]).hexdigest()[:12]} vs {hashlib.sha256(b[db:db+803]).hexdigest()[:12]}")
# What sits in the partition after the capture's own content end is what our write leaves untouched.
tail = a[cb:]
nz = sum(1 for x in tail if x)
print(f"partition tail beyond patched content end: {len(tail):,} B, non-zero {nz:,} (left untouched by the write)")
print(f"write span: 0..{len(b):,} B of partition {len(a):,} B")
PY
grep "REFUSE" "$LOG" > /dev/null && fail "byte-level check refused the image (see $LOG)"

say "=== 6. ramdisk archive: no duplicate entries, injected files intact ==="
rm -rf "$OUTDIR/rd-patched"; mkdir -p "$OUTDIR/rd-patched"
python3 - "$OUT" "$OUTDIR/rd-patched" >> "$LOG" 2>&1 <<'PY'
import gzip, os, subprocess, sys
sys.path.insert(0, "/run/media/Daan/Opslagmonster/VibeBakingFirmware/tools")
import rebuild_boot_faithful as R
img, rd = sys.argv[1], sys.argv[2]
d = open(img, "rb").read()
ks, rs, ss, ro, so = R.offsets(d)
open(os.path.join(rd, "r.cpio"), "wb").write(gzip.decompress(d[ro:ro+rs]))
subprocess.run(["cpio", "-idmf", "--quiet"], cwd=rd, stdin=open(os.path.join(rd, "r.cpio"), "rb"),
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
os.remove(os.path.join(rd, "r.cpio"))
print("injected:", os.path.exists(os.path.join(rd, "sbin/hu-evidence.sh")),
      os.path.exists(os.path.join(rd, "init.recovery.rk30board.rc")))
PY
cp "$RD/sbin/hu-evidence.sh" "$OUTDIR/rd-patched/hu-evidence.sh.chk"
cp "$RD/init.recovery.rk30board.rc" "$OUTDIR/rd-patched/rc.chk"
sha256sum "$OUTDIR/rd-patched/sbin/hu-evidence.sh" "$OUTDIR/rd-patched/init.recovery.rk30board.rc" \
  "$OUTDIR/rd-patched/hu-evidence.sh.chk" "$OUTDIR/rd-patched/rc.chk" >> "$LOG" 2>&1
grep -c "service hu_evidence" "$OUTDIR/rd-patched/init.recovery.rk30board.rc" >> "$LOG" 2>&1
printf 'stock console service lines: %s\n' "$(grep -c 'service console' "$OUTDIR/rd-patched/init.recovery.rk30board.rc")" >> "$LOG"
printf 'stock usb controller lines: %s\n' "$(grep -c 'sys.usb.controller' "$OUTDIR/rd-patched/init.recovery.rk30board.rc")" >> "$LOG"
rm -f "$OUTDIR/rd-patched/hu-evidence.sh.chk" "$OUTDIR/rd-patched/rc.chk"

say "=== 7. digests ==="
stat -c '%n %s' "$OUT" >> "$LOG"
sha256sum "$OUT" >> "$LOG"
sha256sum "$CAPTURE" "$OUT" > "$OUTDIR/MANIFEST.sha256"
echo "see $LOG and $OUTDIR/MANIFEST.sha256"
