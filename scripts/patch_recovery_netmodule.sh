#!/usr/bin/env bash
# patch_recovery_netmodule.sh - builds the Step-3 recovery net module image (D84/D85) from the
# CURRENT stock recovery capture. Ramdisk-only, exactly like patch_recovery_evidence.sh: kernel,
# the RSCE second, recovery_dtbo, cmdline and header fields stay byte-for-byte, and the builder
# refuses the image if any byte outside the ramdisk span moves.
#
# Injected/changed inside the ramdisk only:
#   /sbin/hu-h-common.sh      shared lines (say/cache_ready/guarded watchdog)
#   /sbin/hu-early.sh         pstore copy + misc head 2048 B, first action
#   /sbin/hu-hb.sh            heartbeat "alive up=<uptime>" every 5 s for 20 min
#   /sbin/hu-state.sh         guarded state snapshot at a given delay
#   /sbin/hu-net.sh           Ethernet bring-up, gated on /cache/hu-net.request nonce: carrier poll,
#                             static 192.168.1.250/24 + eth0:1 alias 192.168.77.2, adbd RESTART
#                             (stop -> port -> start, verified in /proc/net/tcp), telnetd in the same
#                             block, then a background DIAGNOSTIC-only udhcpc (~60 s)
#   /sbin/hu-card.sh          FAT32 card copy as the no-network channel; stays mounted until the
#                             120 s snapshot has landed and re-copies every tick
#   /sbin/hu-udhcpc.script    busybox udhcpc lease script (ramdisk ships no default.script); records
#                             the offer and never configures an interface
#   /init.recovery.rk30board.rc   stock bytes verbatim + appended independent service block
#   /prop.default             -HUPATCH suffix on fingerprint/display id, + ro.adb.secure=0
#                             (default.prop is a symlink to it, so one patch covers both)
#
#   scripts/patch_recovery_netmodule.sh            # default capture + default out dir
#   scripts/patch_recovery_netmodule.sh <capture> <outdir>
set -u
REPO=/run/media/Daan/Opslagmonster/VibeBakingFirmware
WORK=/run/media/Daan/Opslagmonster/a14-work
CAPTURE="${1:-$WORK/hu-stock-backup-refresh/recovery.bin}"
OUTDIR="${2:-$WORK/recovery-netmodule}"
LOG="$OUTDIR/patch.log"
PART_BYTES=100663296
DTBO_SIZE=803          # measured Nov 12 by unpack_bootimg on the stock recovery.bin

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
[ -L "$RD/default.prop" ] || fail "default.prop is no longer a symlink to prop.default"
say "extracted: $(ls "$RD" | tr '\n' ' ')"

say "=== 2. overlay the module files ==="
for f in hu_h_common hu_early hu_hb hu_state hu_net hu_card hu_udhcpc_script; do
  [ -f "$REPO/scripts/${f}.sh" ] || fail "module source missing: scripts/${f}.sh"
done
# names inside the ramdisk keep the hu- prefix with dashes
cp "$REPO/scripts/hu_h_common.sh"       "$RD/sbin/hu-h-common.sh"   && chmod 755 "$RD/sbin/hu-h-common.sh"
cp "$REPO/scripts/hu_early.sh"          "$RD/sbin/hu-early.sh"      && chmod 755 "$RD/sbin/hu-early.sh"
cp "$REPO/scripts/hu_hb.sh"             "$RD/sbin/hu-hb.sh"         && chmod 755 "$RD/sbin/hu-hb.sh"
cp "$REPO/scripts/hu_state.sh"          "$RD/sbin/hu-state.sh"      && chmod 755 "$RD/sbin/hu-state.sh"
cp "$REPO/scripts/hu_net.sh"            "$RD/sbin/hu-net.sh"        && chmod 755 "$RD/sbin/hu-net.sh"
cp "$REPO/scripts/hu_card.sh"           "$RD/sbin/hu-card.sh"       && chmod 755 "$RD/sbin/hu-card.sh"
cp "$REPO/scripts/hu_udhcpc_script.sh"  "$RD/sbin/hu-udhcpc.script" && chmod 755 "$RD/sbin/hu-udhcpc.script"
rm -f "$RD/sbin/hu-evidence.sh"   # the 18 KB evidence script is retired; its dig() path is not reused
cp "$REPO/scripts/hu_net_module_append.rc" "$RD/init.recovery.rk30board.rc" && chmod 755 "$RD/init.recovery.rk30board.rc"

# prop.default patch: marker on the three build strings, and an unauthenticated TCP adbd (the
# recovery ramdisk ships no adb keys, so ro.adb.secure default 1 would refuse our connection).
# Nov 21 evening measurement: the OEM recovery UI prints ro.build.fingerprint /
# ro.bootimage.build.fingerprint - prop.default carries NO ro.build.fingerprint line, so the
# visible header string comes from ro.bootimage.build.fingerprint. All three markers are appended.
python3 - "$RD/prop.default" >> "$LOG" 2>&1 <<'PY'
import sys
p = sys.argv[1]
MARKED = ("ro.system.build.fingerprint=", "ro.build.display.id=", "ro.bootimage.build.fingerprint=")
lines = open(p, "r").read().split("\n")
out, changed = [], 0
for ln in lines:
    if any(ln.startswith(k) for k in MARKED) and not ln.endswith("-HUPATCH"):
        ln = ln + "-HUPATCH"; changed += 1
    out.append(ln)
if not any(l.startswith("ro.adb.secure=") for l in out):
    out.append("ro.adb.secure=0"); changed += 1
open(p, "w").write("\n".join(out))
print(f"prop.default changed lines: {changed}")
if changed != 4:
    print("REFUSE: prop.default changed more or fewer than the 4 intended lines"); sys.exit(1)
PY
grep -q "REFUSE: prop.default" "$LOG" && fail "prop patch refused"

mkdir -p "$OUTDIR/inject"
cp "$RD/sbin/hu-h-common.sh" "$RD/sbin/hu-early.sh" "$RD/sbin/hu-hb.sh" "$RD/sbin/hu-state.sh" \
   "$RD/sbin/hu-net.sh" "$RD/sbin/hu-card.sh" "$RD/sbin/hu-udhcpc.script" "$RD/init.recovery.rk30board.rc" \
   "$RD/prop.default" "$OUTDIR/inject/" 2>/dev/null
sha256sum "$OUTDIR/inject/"* >> "$LOG"

say "=== 3. the appended rc keeps the stock file verbatim ==="
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
for svc in ("hu_early", "hu_hb", "hu_state5", "hu_state30", "hu_state120", "hu_net", "hu_card"):
    n = tail.count(b"service " + svc.encode())
    s = tail.count(b"start " + svc.encode())
    print(f"service {svc}: defined {n}, started {s}")
    if n != 1 or s != 1:
        print("REFUSE: service not defined exactly once or not started exactly once"); sys.exit(1)
print("retired hu_evidence absent from tail:", b"hu_evidence" not in tail)
print("stock markers still present:", b"service console" in old, b"sys.usb.controller" in old)
PY
grep -q "REFUSE: appended rc\|REFUSE: service" "$LOG" && fail "rc splice refused"

say "=== 4. splice the image ==="
python3 "$REPO/scripts/repack_recovery_python.py" "$CAPTURE" "$RD" "$OUTDIR/recovery-netmodule.img" \
  "$PART_BYTES" "$DTBO_SIZE" >> "$LOG" 2>&1 | tail -14
OUT="$OUTDIR/recovery-netmodule.img"
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
allowed = set(range(16, 20)) | set(range(1636, 1644))
bad = [i for i in range(min(len(b), 2048)) if a[i] != b[i] and i not in allowed]
if bad: print(f"REFUSE: header bytes changed outside ramdisk_size/dtbo offset: {bad[:12]}")
for i in range(2048, cb):
    if a[i] != b[i] and not (ao <= i < R.roundup(ra + ao) or sbo <= i < cb):
        print(f"REFUSE: byte {i} changed outside the ramdisk/second span"); break
print(f"kernel blob digest  {hashlib.sha256(a[2048:2048+ka]).hexdigest()[:12]} vs {hashlib.sha256(b[2048:2048+kb]).hexdigest()[:12]}")
print(f"second blob digest  {hashlib.sha256(a[so:so+sa]).hexdigest()[:12]} vs {hashlib.sha256(b[sbo:sbo+sa]).hexdigest()[:12]}")
print(f"dtbo digest         {hashlib.sha256(a[da:da+803]).hexdigest()[:12]} vs {hashlib.sha256(b[db:db+803]).hexdigest()[:12]}")
tail = a[cb:]
nz = sum(1 for x in tail if x)
print(f"partition tail beyond patched content end: {len(tail):,} B, non-zero {nz:,} (left untouched by the write)")
print(f"write span: 0..{len(b):,} B of partition {len(a):,} B")
PY
grep "REFUSE" "$LOG" > /dev/null && fail "byte-level check refused the image (see $LOG)"

say "=== 6. ramdisk archive: injected files intact, prop marker present ==="
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
want = ["sbin/hu-h-common.sh", "sbin/hu-early.sh", "sbin/hu-hb.sh", "sbin/hu-state.sh",
        "sbin/hu-net.sh", "sbin/hu-card.sh", "sbin/hu-udhcpc.script"]
print("present:", all(os.path.exists(os.path.join(rd, w)) for w in want))
print("retired evidence script gone:", not os.path.exists(os.path.join(rd, "sbin/hu-evidence.sh")))
props = open(os.path.join(rd, "prop.default")).read()
print("marker on fingerprint:", "ro.system.build.fingerprint=" in props and
      props.split("ro.system.build.fingerprint=")[1].splitlines()[0].endswith("-HUPATCH"))
print("marker on display id:", props.split("ro.build.display.id=")[1].splitlines()[0].endswith("-HUPATCH"))
print("marker on bootimage fingerprint:", "ro.bootimage.build.fingerprint=" in props and
      props.split("ro.bootimage.build.fingerprint=")[1].splitlines()[0].endswith("-HUPATCH"))
print("ro.adb.secure=0 present:", "ro.adb.secure=0" in props)
print("default.prop is symlink:", os.path.islink(os.path.join(rd, "default.prop")))
PY
grep -q "present: True" "$LOG" || fail "module files missing from the spliced ramdisk"
grep -q "retired evidence script gone: True" "$LOG" || fail "retired evidence script still present"
grep -q "marker on fingerprint: True" "$LOG" || fail "fingerprint marker missing"
grep -q "marker on display id: True" "$LOG" || fail "display id marker missing"
grep -q "marker on bootimage fingerprint: True" "$LOG" || fail "bootimage fingerprint marker missing"
grep -q "ro.adb.secure=0 present: True" "$LOG" || fail "ro.adb.secure=0 missing"
grep -q "default.prop is symlink: True" "$LOG" || fail "default.prop symlink lost"
sha256sum "$OUTDIR/rd-patched/sbin/"* >> "$LOG"

say "=== 7. digests ==="
stat -c '%n %s' "$OUT" >> "$LOG"
sha256sum "$OUT" >> "$LOG"
sha256sum "$CAPTURE" "$OUT" > "$OUTDIR/MANIFEST.sha256"
echo "see $LOG and $OUTDIR/MANIFEST.sha256"
