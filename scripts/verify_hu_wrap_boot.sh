#!/usr/bin/env bash
# verify_hu_wrap_boot.sh - offline gate for an injected boot image (D92). Reads and builds only; nothing is flashed.
#
#   bash scripts/verify_hu_wrap_boot.sh <base_boot> <wrapper_bin> <candidate_img> [--cmdline-append " tokens"]
#
# Checks, in order:
#   1. the injector runs, and a second run produces the identical digest (deterministic packing)
#   2. header bytes outside ramdisk_size (16..19) and the cmdline field (64..575) are unchanged
#   3. an independent reader (7z) extracts the candidate's ramdisk: /init is byte-identical to the
#      wrapper binary, /init.real is byte-identical to the base image's original /init, fstab unchanged
#   4. the wrapper extracted from the candidate passes HU_TEST against a loopback file (healthy arm,
#      passthrough), so the binary that ships inside the image is the binary we tested
#   5. device nodes present in the base's ramdisk survive in the candidate with their devmajor/devminor
#   6. every tail resource entry in the image matches its declared SHA1
set -uo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
S=${SCRATCH:-/run/media/Daan/Opslagmonster/a14-work/tmp/hu-wrap-boot-verify}
fails=0
ok() { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; fails=$((fails+1)); }

BASE=$1; WRAP=$2; CAND=$3; shift 3
CMDLINE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --cmdline-append) CMDLINE=$2; shift 2 ;;
    *) bad "unknown argument $1"; shift ;;
  esac
done
rm -rf "$S"; mkdir -p "$S"
inject() {  # inject <out> <work>
  if [ -n "$CMDLINE" ]; then
    python3 "$REPO/scripts/inject_hu_wrap_boot.py" "$BASE" "$WRAP" "$1" --cmdline-append "$CMDLINE" --work "$2"
  else
    python3 "$REPO/scripts/inject_hu_wrap_boot.py" "$BASE" "$WRAP" "$1" --work "$2"
  fi
}

echo "=== inputs ==="
echo "  base      $(stat -c '%s' "$BASE") B  sha256 $(sha256sum "$BASE" | cut -d' ' -f1)"
echo "  wrapper   $(stat -c '%s' "$WRAP") B  sha256 $(sha256sum "$WRAP" | cut -d' ' -f1)"
echo "  candidate $(stat -c '%s' "$CAND") B  sha256 $(sha256sum "$CAND" | cut -d' ' -f1)"

echo "=== 1. deterministic repack ==="
inject "$S/rebuild-1.img" "$S/repack1" > "$S/inject-1.txt" 2>&1 || bad "first build failed"
inject "$S/rebuild-2.img" "$S/repack2" > "$S/inject-2.txt" 2>&1 || bad "second build failed"
cmp -s "$S/rebuild-1.img" "$S/rebuild-2.img" && ok "two runs give the same image" || bad "repack is not deterministic"
cmp -s "$S/rebuild-1.img" "$CAND" && ok "the candidate on disk matches a fresh build" || bad "candidate differs from a fresh build"

echo "=== 2. header diff ranges ==="
python3 - "$BASE" "$CAND" "$CMDLINE" <<'PY'
import sys
b = open(sys.argv[1], 'rb').read(); c = open(sys.argv[2], 'rb').read()
allowed = [(16, 19)] + ([(64, 575)] if sys.argv[3] else [])
runs, start = [], None
for i in range(2048):
    if b[i] != c[i]:
        start = i if start is None else start
        last = i
    elif start is not None:
        runs.append((start, last)); start = None
if start is not None: runs.append((start, last))
outside = [r for r in runs if not any(a <= r[0] and r[1] <= bb for a, bb in allowed)]
print(f"  header diff ranges: {runs}")
if outside:
    print(f"  FAIL header changed outside the allowed fields: {outside}")
    sys.exit(1)
print(f"  ok header changes confined to {'bytes 16..19 and 64..575' if sys.argv[3] else 'ramdisk_size bytes 16..19'}")
PY
[ $? -eq 0 ] || bad "header diff outside allowed fields"

echo "=== 3. independent extraction (7z reads the ramdisk) ==="
python3 - "$BASE" "$CAND" "$S" <<'PY'
import gzip, struct, sys
def rd(p):
    d = open(p, 'rb').read()
    ks = struct.unpack_from('<I', d, 8)[0]; rs = struct.unpack_from('<I', d, 16)[0]
    ro = ((2048 + ks + 2047) // 2048) * 2048
    return gzip.decompress(d[ro:ro + rs])
open(f"{sys.argv[3]}/base.cpio", "wb").write(rd(sys.argv[1]))
open(f"{sys.argv[3]}/cand.cpio", "wb").write(rd(sys.argv[2]))
PY
rm -rf "$S/base-ex" "$S/cand-ex"
7z x -y -o"$S/base-ex" "$S/base.cpio" >/dev/null 2>&1 || bad "7z could not read the base ramdisk"
7z x -y -o"$S/cand-ex" "$S/cand.cpio" >/dev/null 2>&1 || bad "7z could not read the candidate ramdisk"
cmp -s "$WRAP" "$S/cand-ex/init" && ok "candidate /init == wrapper binary ($(stat -c '%s' "$S/cand-ex/init") B)" || bad "candidate /init is not the wrapper binary"
if cmp -s "$S/base-ex/init" "$S/cand-ex/init.real"; then
  ok "candidate /init.real == the base's original /init ($(stat -c '%s' "$S/cand-ex/init.real") B, sha256 $(sha256sum "$S/cand-ex/init.real" | cut -c1-12))"
else bad "candidate /init.real is not the base's original /init"; fi
if cmp -s "$S/base-ex/fstab.rk30board" "$S/cand-ex/fstab.rk30board" 2>/dev/null \
   || cmp -s "$S/base-ex/first_stage_ramdisk/fstab.rk30board" "$S/cand-ex/first_stage_ramdisk/fstab.rk30board" 2>/dev/null; then
  ok "fstab unchanged"; else bad "fstab changed or not found"; fi

echo "=== 4. HU_TEST on the wrapper extracted from the candidate ==="
# the extracted /init is the aarch64 build; run it under qemu-aarch64, natively only if it is x86_64
case "$(file -b "$S/cand-ex/init")" in
  *ARM\ aarch64*) RUN=(qemu-aarch64 -L / -0 /init "$S/cand-ex/init") ;;
  *x86-64*)       RUN=(bash -c 'exec -a "$1" "$2"' x /init "$S/cand-ex/init") ;;
  *) bad "extracted /init is not a recognizable ELF binary: $(file -b "$S/cand-ex/init")"; RUN=() ;;
esac
dd if=/dev/zero of="$S/misc.bin" bs=2048 count=1 conv=notrunc status=none
printf '#!/bin/sh\necho REAL-INIT-RAN > "%s/run.marker"\n' "$S" > "$S/fake-init.sh"
chmod 755 "$S/fake-init.sh"
: > "$S/arm.log"; rm -f "$S/run.marker"
HU_TEST=1 HU_TEST_MISC="$S/misc.bin" HU_TEST_INIT="$S/fake-init.sh" HU_TEST_LOG="$S/arm.log" \
  HU_TEST_WATCHDOG=300 HU_TEST_FORCE_ARM=1 "${RUN[@]}" >/dev/null 2>&1
grep -qaF "HU-WRAP bcb verified" "$S/arm.log" && ok "extracted wrapper arms the BCB" || bad "extracted wrapper did not arm the BCB"
[ -f "$S/run.marker" ] && ok "extracted wrapper hands off to init.real" || bad "extracted wrapper did not exec init.real"
python3 - "$S/misc.bin" <<'PY'
import sys
b = open(sys.argv[1], 'rb').read()
zeros = sum(1 for x in b if x == 0)
ok = len(b) == 2048 and b[:13] == b'boot-recovery' and b[64:73] == b'recovery\n' and zeros == 2048 - 22
print("  ok BCB blob matches boot-recovery/recovery with the rest zero" if ok else "  FAIL BCB blob wrong")
sys.exit(0 if ok else 1)
PY
[ $? -eq 0 ] || bad "BCB blob mismatch after the extraction test"
: > "$S/pass.log"; rm -f "$S/run.marker"
case "$(file -b "$S/cand-ex/init")" in
  *ARM\ aarch64*) PASS=(qemu-aarch64 -L / -0 /system/bin/adbd "$S/cand-ex/init") ;;
  *x86-64*)       PASS=(bash -c 'exec -a "$1" "$2"' x /system/bin/adbd "$S/cand-ex/init") ;;
  *) PASS=(); bad "cannot run passthrough test: no runnable extracted /init" ;;
esac
HU_TEST=1 HU_TEST_MISC="$S/misc.bin" HU_TEST_INIT="$S/fake-init.sh" HU_TEST_LOG="$S/pass.log" \
  HU_TEST_WATCHDOG=300 "${PASS[@]}" >/dev/null 2>&1
grep -qaF "passthrough: not PID-1-as-init" "$S/pass.log" && ok "extracted wrapper passes through for another argv0" || bad "extracted wrapper did not pass through"
grep -qaF "bcb pwrite" "$S/pass.log" && bad "passthrough armed the BCB" || ok "passthrough wrote no BCB"

echo "=== 5. device nodes ==="
# 7z cannot create device nodes as a non-root user, so the nodes are compared in the cpio streams themselves
python3 - "$S/base.cpio" "$S/cand.cpio" "$REPO" <<'PY'
import importlib.util, sys
inj_path = f"{sys.argv[3]}/scripts/inject_hu_wrap_boot.py"
spec = importlib.util.spec_from_file_location("inj", inj_path)
inj = importlib.util.module_from_spec(spec); spec.loader.exec_module(inj)
base_e, _ = inj.parse_cpio(open(sys.argv[1], "rb").read())
cand_e, _ = inj.parse_cpio(open(sys.argv[2], "rb").read())
base_nodes = {e["name"]: (e["mode"], e["devmj"], e["devmn"], e["data"]) for e in base_e if e["devmj"] or e["devmn"]}
cand_nodes = {e["name"]: (e["mode"], e["devmj"], e["devmn"], e["data"]) for e in cand_e if e["devmj"] or e["devmn"]}
print(f"  base device nodes: {[(n, d[1], d[2]) for n, d in base_nodes.items()] or '(none)'}")
lost = [n for n, v in base_nodes.items() if cand_nodes.get(n) != v]
if lost:
    print(f"  FAIL device nodes lost or altered: {lost}")
    sys.exit(1)
print("  ok device nodes carried into the candidate with the same mode and devmajor:devminor")
PY
[ $? -eq 0 ] || bad "device nodes lost"

echo "=== 6. tail resource entries ==="
python3 - "$CAND" <<'PY'
import hashlib, struct, sys
d = open(sys.argv[1], 'rb').read()
pos = d.find(b'RSCE')
if pos < 0:
    print("  note: image carries no RSCE resource header"); sys.exit(0)
n = struct.unpack_from('<I', d, pos + 12)[0]
bad = []
for i in range(n):
    e = pos + 512 * (i + 1)
    if d[e:e + 4] != b'ENTR': continue
    name = d[e + 4:e + 224].split(b'\x00')[0].decode(errors='replace')
    declared = d[e + 224:e + 244].hex()
    blocks = struct.unpack_from('<I', d, e + 260)[0]
    size = struct.unpack_from('<I', d, e + 264)[0]
    h = hashlib.sha1(d[pos + blocks * 512:pos + blocks * 512 + size]).hexdigest()
    print(f"  entry {name} @{pos + blocks * 512:,} {size:,} B sha1 {h[:12]} {'matches declared' if h == declared else 'MISMATCH'}")
    if h != declared: bad.append(name)
if bad:
    print(f"  FAIL resource entries: {bad}"); sys.exit(1)
print("  ok every tail resource entry matches its declared SHA1")
PY
[ $? -eq 0 ] || bad "tail resource entries failed"

echo "=== summary: $fails failure(s)"
[ "$fails" -eq 0 ] && echo "gate ok"
exit "$fails"
