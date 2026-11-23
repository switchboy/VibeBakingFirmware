#!/usr/bin/env bash
# smoke_hu_card_arm.sh - offline scenarios for tools/hu_card_arm.c (D103). Nothing touches the unit.
#
# The binary is the aarch64 static wrapper that runs as PID 1 from the Android 14 ramdisk, arms the
# SD-boot card's BCB and execs /init.real. Here it runs under qemu-aarch64 with HU_TEST set, so the
# device lookup reads a fake /proc/partitions, the misc node is a loopback file, and the exec target is
# a tiny aarch64 program that exits 7 - so a correct run is proved by the exit code, not by a log line.
#
# What each scenario pins down:
#   1 happy path        - the card and its p3 are found by block count, the BCB is written and verified
#   2 no card           - no device of the card's size: refuses to arm, still execs init.real
#   3 two cards         - two devices with the card's block count: refuses rather than guessing
#   4 wrong misc size   - the p3 line has the wrong block count: refuses
#   5 passthrough       - argv[0] is not "init": no arm at all
#   6 unwritable misc   - the misc file cannot be opened: refuses to arm, still execs init.real
#   7 BCB bytes         - the 2048 B written equal the registered blob ceaae1a6314a…
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-/run/media/Daan/Opslagmonster/a14-work/hu-card-arm}
BIN=$OUT/hu-card-arm
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
fail=0
ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

command -v qemu-aarch64 >/dev/null || { echo "qemu-aarch64 missing"; exit 1; }
[ -x "$BIN" ] || { echo "build it first: zig cc -target aarch64-linux-musl -static -Os -o $BIN $REPO/tools/hu_card_arm.c"; exit 1; }

# A stand-in 'init.real' that exits 7, so a real execve is observable by the exit code. It must be a
# script, not an aarch64 binary: execve from inside qemu-aarch64 goes to the host kernel, which cannot
# run an aarch64 ELF without binfmt_misc, but a shebang script runs the host shell fine.
printf '#!/bin/sh\nexit 7\n' > "$WORK/init.real"
chmod +x "$WORK/init.real"

mkparts() { printf 'major minor  #blocks  name\n%s\n' "$1" > "$WORK/partitions"; }
CARD_LINES=$' 179        0   30533632 mmcblk0\n 179        1   30529536 mmcblk0p1\n 179       32    7761920 mmcblk1\n 179       35       4096 mmcblk1p3\n 179       39      32768 mmcblk1p7\n 179       64   61341696 mmcblk2\n 179       67       4096 mmcblk2p3'
newmisc() { head -c 4194304 /dev/zero > "$WORK/misc.bin"; }
run() { # run <argv0> [extra env...]
  local a0=$1; shift
  cp "$BIN" "$WORK/$a0"
  : > "$WORK/log.txt"
  env HU_TEST=1 HU_TEST_LOG="$WORK/log.txt" HU_TEST_INIT="$WORK/init.real" \
      HU_TEST_PARTS="$WORK/partitions" HU_TEST_MISC="$WORK/misc.bin" "$@" \
      qemu-aarch64 "$WORK/$a0"
  echo $? > "$WORK/rc"
}

echo "== 1 happy path =="
mkparts "$CARD_LINES"; newmisc
run init HU_TEST_FORCE_ARM=1
[ "$(cat "$WORK/rc")" = 7 ] && ok "exec reached init.real (rc 7)" || bad "rc $(cat "$WORK/rc"), expected 7"
grep -q "card device mmcblk1" "$WORK/log.txt" && ok "card resolved as mmcblk1 by block count" || bad "card not resolved: $(tr '\n' '|' < "$WORK/log.txt")"
grep -q "misc node mmcblk1p3" "$WORK/log.txt" && ok "misc resolved as mmcblk1p3" || bad "misc not resolved"
grep -q "pwrite=2048" "$WORK/log.txt" && ok "2048 B written" || bad "no 2048 B write"
grep -q "BCB verified" "$WORK/log.txt" && ok "readback verified" || bad "readback not verified"

echo "== 7 the BCB bytes are the registered blob =="
want=ceaae1a6314a19927ab431d55b46d08a6aaf73e9bcceb578244783c06bffd00e
got=$(head -c 2048 "$WORK/misc.bin" | sha256sum | cut -d' ' -f1)
[ "$got" = "$want" ] && ok "BCB sha256 $want" || bad "BCB sha256 $got"
rest=$(tail -c +2049 "$WORK/misc.bin" | tr -d '\0' | wc -c)
[ "$rest" = 0 ] && ok "nothing written past byte 2048" || bad "$rest non-zero bytes past 2048"

echo "== 2 no device of the card's size =="
mkparts $' 179        0   30533632 mmcblk0\n 179       64   61341696 mmcblk2\n 179       67       4096 mmcblk2p3'; newmisc
run init HU_TEST_FORCE_ARM=1 HU_TEST_MISC="$WORK/missing-on-purpose"
[ "$(cat "$WORK/rc")" = 7 ] && ok "still execs init.real when it cannot arm" || bad "rc $(cat "$WORK/rc"), expected 7"
head -c 2048 "$WORK/misc.bin" | tr -d '\0' | wc -c | grep -qx 0 && ok "misc untouched" || bad "misc was written"

echo "== 3 two devices with the card's block count =="
mkparts "$CARD_LINES"$'\n 179       96    7761920 mmcblk3\n 179       99       4096 mmcblk3p3'; newmisc
: > "$WORK/log.txt"
env HU_TEST=1 HU_TEST_FORCE_ARM=1 HU_TEST_LOG="$WORK/log.txt" HU_TEST_INIT="$WORK/init.real" \
    HU_TEST_PARTS="$WORK/partitions" HU_TEST_MISC="$WORK/misc.bin" HU_TEST_REAL=1 \
    qemu-aarch64 "$WORK/init" >/dev/null 2>&1
grep -q "two devices match" "$WORK/log.txt" && ok "refuses to guess between two matching devices" \
  || bad "did not refuse: $(tr '\n' '|' < "$WORK/log.txt")"

echo "== 4 misc partition with the wrong block count =="
mkparts $' 179       32    7761920 mmcblk1\n 179       35       8192 mmcblk1p3'; newmisc
: > "$WORK/log.txt"
env HU_TEST=1 HU_TEST_FORCE_ARM=1 HU_TEST_LOG="$WORK/log.txt" HU_TEST_INIT="$WORK/init.real" \
    HU_TEST_PARTS="$WORK/partitions" HU_TEST_MISC="$WORK/misc.bin" \
    qemu-aarch64 "$WORK/init" >/dev/null 2>&1
grep -q "wrong block count" "$WORK/log.txt" && ok "refuses a misc of the wrong size" \
  || bad "did not refuse the wrong size: $(tr '\n' '|' < "$WORK/log.txt")"

echo "== 5 passthrough when argv[0] is not init =="
mkparts "$CARD_LINES"; newmisc
run something-else
[ "$(cat "$WORK/rc")" = 7 ] && ok "execs init.real" || bad "rc $(cat "$WORK/rc"), expected 7"
grep -q "passthrough" "$WORK/log.txt" && ok "logged passthrough" || bad "no passthrough line"
head -c 2048 "$WORK/misc.bin" | tr -d '\0' | wc -c | grep -qx 0 && ok "misc untouched in passthrough" || bad "misc written in passthrough"

echo "== 6 misc that cannot be opened =="
mkparts "$CARD_LINES"; newmisc
run init HU_TEST_FORCE_ARM=1 HU_TEST_MISC="$WORK/nope.bin"
[ "$(cat "$WORK/rc")" = 7 ] && ok "fails open: still execs init.real" || bad "rc $(cat "$WORK/rc"), expected 7"
grep -q "ARM FAILED" "$WORK/log.txt" && ok "logged ARM FAILED" || bad "no ARM FAILED line"

echo "== 8 the watchdog fires in software after its delay =="
mkparts "$CARD_LINES"; newmisc
rm -f "$WORK/rebooted"
run init HU_TEST_FORCE_ARM=1 HU_TEST_WATCHDOG=1 HU_TEST_REBOOT_MARK="$WORK/rebooted"
[ "$(cat "$WORK/rc")" = 7 ] && ok "the parent still execs init.real immediately" || bad "rc $(cat "$WORK/rc"), expected 7"
grep -q "watchdog child pid=" "$WORK/log.txt" && ok "watchdog child forked" || bad "no watchdog child"
sleep 4
[ -f "$WORK/rebooted" ] && ok "watchdog reached the reboot step after its delay" || bad "watchdog never reached the reboot step"
grep -q "watchdog expired with the BCB still armed" "$WORK/log.txt" && ok "logged the reason" || bad "no reason logged"

echo "== 9 the watchdog stands down if the BCB is cleared inside the window =="
mkparts "$CARD_LINES"; newmisc
rm -f "$WORK/rebooted"
cp "$BIN" "$WORK/init"; : > "$WORK/log.txt"
env HU_TEST=1 HU_TEST_FORCE_ARM=1 HU_TEST_LOG="$WORK/log.txt" HU_TEST_INIT="$WORK/init.real" \
    HU_TEST_PARTS="$WORK/partitions" HU_TEST_MISC="$WORK/misc.bin" HU_TEST_WATCHDOG=3 \
    HU_TEST_REBOOT_MARK="$WORK/rebooted" qemu-aarch64 "$WORK/init" >/dev/null 2>&1
sleep 1; head -c 2048 /dev/zero > "$WORK/zero"; dd if="$WORK/zero" of="$WORK/misc.bin" bs=2048 count=1 conv=notrunc status=none
sleep 5
[ -f "$WORK/rebooted" ] && bad "rebooted even though the BCB was cleared" || ok "stood down after the BCB was cleared"
grep -q "standing down" "$WORK/log.txt" && ok "logged standing down" || bad "no stand-down line"

echo "== 10 no watchdog when the arm failed =="
mkparts $' 179        0   30533632 mmcblk0\n 179       64   61341696 mmcblk2'; newmisc
rm -f "$WORK/rebooted"
run init HU_TEST_FORCE_ARM=1 HU_TEST_WATCHDOG=1 HU_TEST_REBOOT_MARK="$WORK/rebooted"
sleep 3
[ -f "$WORK/rebooted" ] && bad "started a watchdog without an armed BCB" || ok "no watchdog when nothing was armed"

printf 'summary: failures=%d\n' "$fail"
[ "$fail" = 0 ]
