#!/usr/bin/env bash
# smoke_hu_wrap.sh - HU_TEST scenarios for tools/hu_wrap.c (D92).
#
# Runs the same source twice: the x86_64 build natively, and the aarch64 build under qemu-aarch64.
# HU_TEST makes every path env-driven, so nothing here touches a real partition: `misc` is a plain
# file, the reboot syscall is suppressed in test mode, and init.real is a script we control.
# Scenarios: healthy arm, misc missing, write fails (open fails), passthrough for other argv,
# watchdog fires, disarmed before the watchdog.
set -uo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-/run/media/Daan/Opslagmonster/a14-work/hu-wrap}
S=${SCRATCH:-/run/media/Daan/Opslagmonster/a14-work/tmp/hu-wrap-smoke}
BIN=${BIN:-$OUT/hu-wrap-x86_64}
QBIN=${QBIN:-$OUT/hu-wrap-aarch64}
QEMU=${QEMU:-qemu-aarch64}
rm -rf "$S"; mkdir -p "$S"
fails=0

python3 - "$S/bcb-expected.bin" <<'PY'
import sys
b = bytearray(2048)
cmd = b"boot-recovery"; rec = b"recovery\x0a"
b[0:len(cmd)] = cmd
b[64:64+len(rec)] = rec
open(sys.argv[1], "wb").write(bytes(b))
PY

mk_init() {  # $1=script name, $2=shebang, $3=body (already expanded by the caller)
  printf '%s\n%s\n' "$2" "$3" > "$S/$1"; chmod 755 "$S/$1"
}
mk_init init-noop.sh '#!/bin/sh' "echo PASSTHROUGH-RAN > \"$S/run.marker\""
mk_init init-sleep.sh '#!/bin/sh' "sleep 4; echo PASSTHROUGH-RAN > \"$S/run.marker\""
mk_init init-disarm.sh '#!/bin/sh' "sleep 1; : > \"$S/misc6.bin\"; echo DISARMED > \"$S/disarm.marker\"; sleep 3; echo PASSTHROUGH-RAN > \"$S/run.marker\""

run() {  # run <label> <binary> <argv0> <misc-file> <init-script> <watchdog> <force-arm(1 or empty)>
  local label=$1 bin=$2 argv0=$3 misc=$4 init=$5 wd=$6 force=$7
  local log="$S/$label.log"
  : > "$log"; rm -f "$S/run.marker" "$S/disarm.marker"
  local args=(HU_TEST=1 "HU_TEST_MISC=$misc" "HU_TEST_INIT=$S/$init" "HU_TEST_LOG=$log" "HU_TEST_WATCHDOG=$wd")
  if [ -n "$force" ]; then args+=(HU_TEST_FORCE_ARM=1); fi
  if [ "$bin" = "$QBIN" ]; then
    env "${args[@]}" "$QEMU" -L / -0 "$argv0" "$bin" >/dev/null 2>&1
  else
    env "${args[@]}" bash -c 'exec -a "$1" "$2"' x "$argv0" "$bin" >/dev/null 2>&1
  fi
  echo "$label rc=$?"
}

expect() {  # expect <label> <substring> [present|absent]
  local label=$1 s=$2 mode=${3:-present}
  if grep -qaF -- "$s" "$S/$label.log"; then got=present; else got=absent; fi
  if [ "$got" = "$mode" ]; then echo "  ok   $label: '$s' $mode"; else echo "  FAIL $label: wanted '$s' $mode, got $got"; fails=$((fails+1)); fi
}

zero_misc() { dd if=/dev/zero of="$1" bs=2048 count=1 conv=notrunc status=none; }

echo "=== scenario 1: healthy arm (x86_64) ==="
zero_misc "$S/misc1.bin"
run s1 "$BIN" /init "$S/misc1.bin" init-noop.sh 300 1
expect s1 "HU-WRAP test begin"
expect s1 "HU-WRAP pid="
expect s1 "HU-WRAP bcb pwrite=2048"
expect s1 "HU-WRAP bcb verified"
expect s1 "HU-WRAP execing init.real with argv[0]=/init"
[ -f "$S/run.marker" ] && echo "  ok   s1: init.real ran" || { echo "  FAIL s1: init.real did not run"; fails=$((fails+1)); }
cmp "$S/misc1.bin" "$S/bcb-expected.bin" && echo "  ok   s1: misc file == BCB blob" || { echo "  FAIL s1: misc differs from the blob"; fails=$((fails+1)); }

echo "=== scenario 2: misc missing ==="
run s2 "$BIN" /init "$S/no-such-misc.bin" init-noop.sh 300 1
expect s2 "ARM FAILED: misc open failed"
expect s2 "HU-WRAP execing init.real"
[ -f "$S/run.marker" ] && echo "  ok   s2: boot continues after ARM FAILED" || { echo "  FAIL s2: boot did not continue"; fails=$((fails+1)); }

echo "=== scenario 3: write fails (node not writable) ==="
zero_misc "$S/misc3.bin"; chmod 444 "$S/misc3.bin"
run s3 "$BIN" /init "$S/misc3.bin" init-noop.sh 300 1
expect s3 "ARM FAILED"
[ -f "$S/run.marker" ] && echo "  ok   s3: boot continues after a failed write" || { echo "  FAIL s3: boot did not continue"; fails=$((fails+1)); }
cmp "$S/misc3.bin" "$S/bcb-expected.bin" >/dev/null 2>&1 && { echo "  FAIL s3: read-only misc was modified"; fails=$((fails+1)); } || echo "  ok   s3: read-only misc untouched"
chmod 644 "$S/misc3.bin"

echo "=== scenario 4: passthrough for other argv ==="
zero_misc "$S/misc4.bin"
run s4 "$BIN" /sbin/adbd "$S/misc4.bin" init-noop.sh 300 ""
expect s4 "passthrough: not PID-1-as-init"
expect s4 "HU-WRAP bcb pwrite" absent
expect s4 "argv0=/sbin/adbd"
[ -f "$S/run.marker" ] && echo "  ok   s4: init.real ran with the original argv" || { echo "  FAIL s4: passthrough did not exec"; fails=$((fails+1)); }
cmp "$S/misc4.bin" "$S/bcb-expected.bin" >/dev/null 2>&1 && { echo "  FAIL s4: passthrough armed misc"; fails=$((fails+1)); } || echo "  ok   s4: misc untouched by passthrough"

echo "=== scenario 5: watchdog fires (BCB still armed) ==="
zero_misc "$S/misc5.bin"
run s5 "$BIN" /init "$S/misc5.bin" init-sleep.sh 2 1
sleep 5
expect s5 "HU-WRAP watchdog delay=2"
expect s5 "BCB still armed, rebooting into recovery"
expect s5 "reboot suppressed"
cmp "$S/misc5.bin" "$S/bcb-expected.bin" && echo "  ok   s5: misc still armed at the watchdog tick" || { echo "  FAIL s5: misc changed before the tick"; fails=$((fails+1)); }

echo "=== scenario 6: disarmed before the watchdog ==="
zero_misc "$S/misc6.bin"
run s6 "$BIN" /init "$S/misc6.bin" init-disarm.sh 3 1
sleep 6
expect s6 "HU-WRAP watchdog: BCB disarmed, no reboot"
expect s6 "BCB still armed, rebooting" absent
cmp "$S/misc6.bin" "$S/bcb-expected.bin" >/dev/null 2>&1 && { echo "  FAIL s6: misc still armed after the disarm"; fails=$((fails+1)); } || echo "  ok   s6: misc zeroed by the disarm"

if [ -x "$QBIN" ] && command -v "$QEMU" >/dev/null 2>&1; then
  echo "=== scenario 1 under qemu-aarch64 ==="
  zero_misc "$S/qmisc1.bin"
  run q1 "$QBIN" /init "$S/qmisc1.bin" init-noop.sh 300 1
  expect q1 "HU-WRAP bcb pwrite=2048"
  expect q1 "HU-WRAP bcb verified"
  cmp "$S/qmisc1.bin" "$S/bcb-expected.bin" && echo "  ok   q1: aarch64 build wrote the same blob" || { echo "  FAIL q1: blob differs"; fails=$((fails+1)); }
  echo "=== scenario 4 under qemu-aarch64 ==="
  zero_misc "$S/qmisc4.bin"
  run q4 "$QBIN" /sbin/ueventd "$S/qmisc4.bin" init-noop.sh 300 ""
  expect q4 "passthrough: not PID-1-as-init"
  cmp "$S/qmisc4.bin" "$S/bcb-expected.bin" >/dev/null 2>&1 && { echo "  FAIL q4: armed misc"; fails=$((fails+1)); } || echo "  ok   q4: misc untouched"
else
  echo "  note: qemu-aarch64 or the aarch64 build unavailable; host-only scenarios ran"
fi

echo "=== source-level assertions on tools/hu_wrap.c ==="
src=$REPO/tools/hu_wrap.c
chk() { grep -qF -- "$1" "$src" && echo "  ok   source: $1" || { echo "  FAIL source: $1 missing"; fails=$((fails+1)); }; }
chk 'hu_streq(hu_basename(argv[0]), "init")'
chk 'syscall(SYS_getpid) == 1 && argc == 1'
chk 'SYS_reboot, HU_MAGIC1, HU_MAGIC2, HU_RESTART2, "recovery"'
chk 'PARTNAME=misc'
chk 'HU_EMMC_SECTORS'
chk 'SYS_mknodat'
chk 'SYS_pwrite64'
chk 'MNT_DETACH'
chk 'ARM FAILED'
chk 'argv[0] = (char *)"/init"'
chk 'HU_TEST_MISC'
chk 'HU_TEST_FORCE_ARM'

echo "=== summary: $fails failure(s)"
[ "$fails" -eq 0 ] && echo "all scenarios pass"
exit "$fails"
