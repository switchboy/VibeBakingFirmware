#!/usr/bin/env bash
# smoke_hu_card_arm.sh - offline scenarios for tools/hu_card_arm.c (D103, D107). Nothing touches the unit.
#
# The binary is the aarch64 static wrapper that runs as PID 1 from the Android 14 ramdisk, arms the
# SD-boot card's BCB, forks a reporting watchdog child and execs /init.real. Here it runs under
# qemu-aarch64 with HU_TEST set, so the device lookup reads a fake /proc/partitions, the misc and the raw
# card are loopback files, sysfs is a fixture directory, sysrq is a file, and the exec target is a script
# that exits 7 - so a correct run is proved by the exit code, not by a log line. Test mode never calls
# reboot(2) or sync(2), so the workstation is never at risk.
#
# What each scenario pins down:
#   1 happy path        - the card and its p3 are found by block count, the BCB is written and verified
#   2 no card           - no device of the card's size: refuses to arm, still execs init.real, misc untouched
#   3 two cards         - two devices with the card's block count: refuses rather than guessing
#   4 wrong misc size   - the p3 line has the wrong block count: refuses
#   5 passthrough       - argv[0] is not "init": no arm at all
#   6 unwritable misc   - the misc file cannot be opened: refuses to arm, still execs init.real
#   7 BCB bytes         - the 2048 B written equal the registered blob ceaae1a6314a…
#   8 watchdog reports  - task dump first, then the pstore copy, then the crash; order and content checked
#   9 stand-down        - a cleared BCB inside the window: nothing is written to sysrq or to the card
#  10 no watchdog       - an arm that failed starts no child and writes nothing
#  11 sink bounds       - the copy touches only the unpartitioned head; a record bigger than the region is
#                        capped, so nothing reaches the partition table or p1
#  12 unopenable card   - the raw card node cannot be opened: sink disabled, crash still fires
#  13 no sysrq          - sysrq-trigger unavailable: the dump still happens, then the reboot fallback
#  14 p1 too close      - sysfs says the first partition starts inside the log region: sink disabled
#  15 boot alive        - the mount table shows /data mounted: the watchdog stands down, boot not crashed
#  16 fds not leaked    - init.real sees no fd to the raw card or sysrq after execve
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
# run an aarch64 ELF without binfmt_misc, but a shebang script runs the host shell fine. It also records
# which fds it inherited, for scenario 16.
printf '#!/bin/sh\nls -l /proc/self/fd > "%s/fd-after-exec.txt" 2>/dev/null\nexit 7\n' "$WORK" > "$WORK/init.real"
chmod +x "$WORK/init.real"

mkparts() { printf 'major minor  #blocks  name\n%s\n' "$1" > "$WORK/partitions"; }
CARD_LINES=$' 179        0   30533632 mmcblk0\n 179        1   30529536 mmcblk0p1\n 179       32    7761920 mmcblk1\n 179       35       4096 mmcblk1p3\n 179       39      32768 mmcblk1p7\n 179       64   61341696 mmcblk2\n 179       67       4096 mmcblk2p3'
newmisc() { head -c 4194304 /dev/zero > "$WORK/misc.bin"; }

# The log sink is the raw card's unpartitioned head: a sparse 7,948,206,080 B file standing in for
# mmcblk1. The wrapper writes only inside [HU_LOG_RAW, HU_LOG_RAW+HU_LOG_LEN), so the rest must stay zero.
# Each scenario gets its own sink file, because a watchdog child from an earlier scenario is alive for a
# second or two and would otherwise write into a later scenario's file.
LOG_BASE=1048576
LOG_LEN=1048576
FIRST_PART=8388608
newcard() { dd if=/dev/null of="$WORK/$1" bs=1 seek=7948206080 count=0 status=none; }
nonzero() { head -c "$2" "$WORK/$1" | tr -d '\0' | wc -c; }
firstnz() { head -c "$2" "$WORK/$1" | tr -d '\0' | head -c 24 | od -An -tx1 | tr -s ' ' | head -1; }
mkpstore() {
  mkdir -p "$WORK/pstore"
  printf 'Booting Android 14\ninit: mount /data failed\n' > "$WORK/pstore/console-ramoops-0"
  printf 'oops backtrace here\n' > "$WORK/pstore/last-kmsg-0"
}
mkbigpstore() {
  mkdir -p "$WORK/pstorebig"
  # one record larger than the whole log region, to prove the cap
  head -c 1200000 /dev/zero | tr '\0' 'x' > "$WORK/pstorebig/console-ramoops-0"
}
# The fixture stands in for sysfs: it needs the device directory, because the wrapper reads
# <sys_dir>/<parent>p1/start the way the kernel exposes it.
mksysfs() { mkdir -p "$WORK/$1/mmcblk1p1"; printf '%s\n' "$2" > "$WORK/$1/mmcblk1p1/start"; }
mkmounts() { printf 'proc /proc proc rw 0 0\ntmpfs /dev tmpfs rw 0 0\n' > "$WORK/$1"; }
mklive()  { printf 'proc /proc proc rw 0 0\n/dev/block/mmcblk1p15 /data ext4 rw 0 0\n' > "$WORK/$1"; }

reap() { pkill -f "$WORK/init" >/dev/null 2>&1; sleep 1; }

run() { # run <argv0> [extra env...]
  local a0=$1; shift
  reap
  cp "$BIN" "$WORK/$a0"
  : > "$WORK/log.txt"
  env HU_TEST=1 HU_TEST_LOG="$WORK/log.txt" HU_TEST_INIT="$WORK/init.real" \
      HU_TEST_REBOOT_MARK="$WORK/rebooted" \
      HU_TEST_PARTS="$WORK/partitions" HU_TEST_MISC="$WORK/misc.bin" \
      HU_TEST_MOUNTS="$WORK/mounts" "$@" \
      qemu-aarch64 "$WORK/$a0"
  echo $? > "$WORK/rc"
}

echo "== 1 happy path =="
mkparts "$CARD_LINES"; newmisc; newcard card1.bin; mkpstore; mkmounts mounts; mksysfs sysdir 16384
rm -f "$WORK/rebooted"
run init HU_TEST_FORCE_ARM=1 HU_TEST_WATCHDOG=1 HU_TEST_SYS="$WORK/sysdir" \
    HU_TEST_CARD="$WORK/card1.bin" HU_TEST_PSTORE="$WORK/pstore"
[ "$(cat "$WORK/rc")" = 7 ] && ok "exec reached init.real (rc 7)" || bad "rc $(cat "$WORK/rc"), expected 7"
grep -q "card device mmcblk1" "$WORK/log.txt" && ok "card resolved as mmcblk1 by block count" || bad "card not resolved: $(tr '\n' '|' < "$WORK/log.txt")"
grep -q "misc node mmcblk1p3" "$WORK/log.txt" && ok "misc resolved as mmcblk1p3" || bad "misc not resolved"
grep -q "pwrite=2048" "$WORK/log.txt" && ok "2048 B written" || bad "no 2048 B write"
grep -q "BCB verified" "$WORK/log.txt" && ok "readback verified" || bad "readback not verified"
grep -q "p1 starts at 8388608" "$WORK/log.txt" && ok "p1 start measured from sysfs" || bad "p1 start not measured"

echo "== 7 the BCB bytes are the registered blob =="
want=ceaae1a6314a19927ab431d55b46d08a6aaf73e9bcceb578244783c06bffd00e
got=$(head -c 2048 "$WORK/misc.bin" | sha256sum | cut -d' ' -f1)
[ "$got" = "$want" ] && ok "BCB sha256 $want" || bad "BCB sha256 $got"
rest=$(tail -c +2049 "$WORK/misc.bin" | tr -d '\0' | wc -c)
[ "$rest" = 0 ] && ok "nothing written past byte 2048" || bad "$rest non-zero bytes past 2048"

echo "== 2 no device of the card's size =="
mkparts $' 179        0   30533632 mmcblk0\n 179       64   61341696 mmcblk2\n 179       67       4096 mmcblk2p3'; newmisc
run init HU_TEST_FORCE_ARM=1 HU_TEST_WATCHDOG=1
[ "$(cat "$WORK/rc")" = 7 ] && ok "still execs init.real when it cannot arm" || bad "rc $(cat "$WORK/rc"), expected 7"
head -c 2048 "$WORK/misc.bin" | tr -d '\0' | wc -c | grep -qx 0 && ok "misc untouched" || bad "misc was written"

echo "== 3 two devices with the card's block count =="
mkparts "$CARD_LINES"$'\n 179       96    7761920 mmcblk3\n 179       99       4096 mmcblk3p3'; newmisc; rm -f "$WORK/rebooted"
run init HU_TEST_FORCE_ARM=1 HU_TEST_WATCHDOG=1
grep -q "two devices match" "$WORK/log.txt" && ok "refuses to guess between two matching devices" \
  || bad "did not refuse: $(tr '\n' '|' < "$WORK/log.txt")"
head -c 2048 "$WORK/misc.bin" | tr -d '\0' | wc -c | grep -qx 0 && ok "misc untouched by the refusal" || bad "misc written by the refusal"
[ -f "$WORK/rebooted" ] && bad "a refused lookup still crashed" || ok "no watchdog child started by the refusal"

echo "== 4 misc partition with the wrong block count =="
mkparts $' 179       32    7761920 mmcblk1\n 179       35       8192 mmcblk1p3'; newmisc; rm -f "$WORK/rebooted"
run init HU_TEST_FORCE_ARM=1 HU_TEST_WATCHDOG=1
grep -q "wrong block count" "$WORK/log.txt" && ok "refuses a misc of the wrong size" \
  || bad "did not refuse the wrong size: $(tr '\n' '|' < "$WORK/log.txt")"
head -c 2048 "$WORK/misc.bin" | tr -d '\0' | wc -c | grep -qx 0 && ok "misc untouched by the refusal" || bad "misc written by the refusal"

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

echo "== 8 the watchdog reports the dead boot and crashes it =="
mkparts "$CARD_LINES"; newmisc; newcard card8.bin; mkpstore; mkmounts mounts; mksysfs sysdir 16384
rm -f "$WORK/rebooted" "$WORK/sysrq.txt"
run init HU_TEST_FORCE_ARM=1 HU_TEST_WATCHDOG=1 HU_TEST_REBOOT_MARK="$WORK/rebooted" \
    HU_TEST_SYSRQ="$WORK/sysrq.txt" HU_TEST_SYS="$WORK/sysdir" \
    HU_TEST_CARD="$WORK/card8.bin" HU_TEST_PSTORE="$WORK/pstore"
[ "$(cat "$WORK/rc")" = 7 ] && ok "the parent still execs init.real immediately" || bad "rc $(cat "$WORK/rc"), expected 7"
grep -q "watchdog child pid=" "$WORK/log.txt" && ok "watchdog child forked" || bad "no watchdog child"
sleep 4
[ -f "$WORK/rebooted" ] && ok "watchdog reached the crash step after its delay" || bad "watchdog never reached the crash step"
grep -q "no working boot" "$WORK/log.txt" && ok "logged why it crashed" || bad "no reason logged"
[ "$(cat "$WORK/sysrq.txt" 2>/dev/null)" = "tc" ] && ok "sysrq order: task dump before crash" \
  || bad "sysrq file is '$(cat "$WORK/sysrq.txt" 2>/dev/null)', expected tc"
grep -q "pstore records copied=2" "$WORK/log.txt" && ok "both pstore records copied" || bad "records not copied: $(tr '\n' '|' < "$WORK/log.txt")"

echo "== 9 the watchdog stands down if the BCB is cleared inside the window =="
mkparts "$CARD_LINES"; newmisc; newcard card9.bin; mkpstore; mkmounts mounts; mksysfs sysdir 16384
rm -f "$WORK/rebooted" "$WORK/sysrq.txt"
reap
cp "$BIN" "$WORK/init"; : > "$WORK/log.txt"
env HU_TEST=1 HU_TEST_FORCE_ARM=1 HU_TEST_LOG="$WORK/log.txt" HU_TEST_INIT="$WORK/init.real" \
    HU_TEST_PARTS="$WORK/partitions" HU_TEST_MISC="$WORK/misc.bin" HU_TEST_WATCHDOG=3 \
    HU_TEST_REBOOT_MARK="$WORK/rebooted" HU_TEST_SYSRQ="$WORK/sysrq.txt" \
    HU_TEST_SYS="$WORK/sysdir" HU_TEST_CARD="$WORK/card9.bin" HU_TEST_PSTORE="$WORK/pstore" \
    HU_TEST_MOUNTS="$WORK/mounts" qemu-aarch64 "$WORK/init" >/dev/null 2>&1
sleep 1; head -c 2048 /dev/zero > "$WORK/zero"; dd if="$WORK/zero" of="$WORK/misc.bin" bs=2048 count=1 conv=notrunc status=none
sleep 5
[ -f "$WORK/rebooted" ] && bad "crashed even though the BCB was cleared" || ok "stood down after the BCB was cleared"
grep -q "standing down" "$WORK/log.txt" && ok "logged standing down" || bad "no stand-down line"
[ -s "$WORK/sysrq.txt" ] && bad "sysrq written after standing down" || ok "nothing written to sysrq"
[ "$(nonzero card9.bin 8388608)" = 0 ] && ok "the card's head is still all zero - nothing written" || bad "card written after standing down: $(firstnz card9.bin 8388608)"

echo "== 10 no watchdog when the arm failed =="
mkparts $' 179        0   30533632 mmcblk0\n 179       64   61341696 mmcblk2'; newmisc; newcard card10.bin; mkpstore; mkmounts mounts
rm -f "$WORK/rebooted" "$WORK/sysrq.txt"
run init HU_TEST_FORCE_ARM=1 HU_TEST_WATCHDOG=1 HU_TEST_SYSRQ="$WORK/sysrq.txt" \
    HU_TEST_CARD="$WORK/card10.bin" HU_TEST_PSTORE="$WORK/pstore"
sleep 3
[ -f "$WORK/rebooted" ] && bad "started a watchdog without an armed BCB" || ok "no watchdog when nothing was armed"
[ "$(nonzero card10.bin 8388608)" = 0 ] && ok "the card's head is untouched" || bad "card written without an armed BCB: $(firstnz card10.bin 8388608)"

echo "== 11 the log copy lands only in the unpartitioned head, and a record bigger than the region is capped =="
mkparts "$CARD_LINES"; newmisc; newcard card11.bin; mkbigpstore; mkmounts mounts; mksysfs sysdir 16384
rm -f "$WORK/rebooted" "$WORK/sysrq.txt"
run init HU_TEST_FORCE_ARM=1 HU_TEST_WATCHDOG=1 HU_TEST_REBOOT_MARK="$WORK/rebooted" \
    HU_TEST_SYSRQ="$WORK/sysrq.txt" HU_TEST_SYS="$WORK/sysdir" \
    HU_TEST_CARD="$WORK/card11.bin" HU_TEST_PSTORE="$WORK/pstorebig"
sleep 4
[ "$(nonzero card11.bin "$LOG_BASE")" = 0 ] && ok "no bytes before the log region (the partition table area is safe)" \
  || bad "bytes before the log region were changed: $(firstnz card11.bin "$LOG_BASE")"
dd if="$WORK/card11.bin" bs=1 skip="$LOG_BASE" count=64 2>/dev/null | grep -a -q "HULOG1" \
  && ok "the header names the copy" || bad "no HULOG1 header at offset $LOG_BASE"
dd if="$WORK/card11.bin" bs=1 skip="$LOG_BASE" count="$LOG_LEN" 2>/dev/null | grep -a -q "=== console-ramoops-0" \
  && ok "the record name is in the copy" || bad "record name missing"
dd if="$WORK/card11.bin" bs=1 skip="$((LOG_BASE + LOG_LEN))" count="$((FIRST_PART - LOG_BASE - LOG_LEN))" 2>/dev/null \
  | tr -d '\0' | wc -c | grep -qx 0 && ok "a 1,200,000 B record was capped: nothing written between the region and p1 ($((FIRST_PART/1024)) KiB)" \
  || bad "wrote between the log region and the first partition"

echo "== 12 a card node that cannot be opened disables the sink, the crash still happens =="
mkparts "$CARD_LINES"; newmisc; newcard card12.bin; mkpstore; mkmounts mounts; mksysfs sysdir 16384
chmod 000 "$WORK/card12.bin"
rm -f "$WORK/rebooted" "$WORK/sysrq.txt"
run init HU_TEST_FORCE_ARM=1 HU_TEST_WATCHDOG=1 HU_TEST_REBOOT_MARK="$WORK/rebooted" \
    HU_TEST_SYSRQ="$WORK/sysrq.txt" HU_TEST_SYS="$WORK/sysdir" \
    HU_TEST_CARD="$WORK/card12.bin" HU_TEST_PSTORE="$WORK/pstore"
chmod 600 "$WORK/card12.bin"
sleep 4
grep -q "log sink fd=-1" "$WORK/log.txt" && ok "sink disabled, no fd opened" || bad "sink not disabled"
[ "$(nonzero card12.bin 8388608)" = 0 ] && ok "the unreadable card was not written" || bad "wrote a device it could not open: $(firstnz card12.bin 8388608)"
[ -f "$WORK/rebooted" ] && ok "the crash still fires with no log sink" || bad "no crash without a sink"

echo "== 13 sysrq missing falls back to the reboot syscall, still after dumping =="
mkparts "$CARD_LINES"; newmisc; newcard card13.bin; mkpstore; mkmounts mounts; mksysfs sysdir 16384
rm -f "$WORK/rebooted"
run init HU_TEST_FORCE_ARM=1 HU_TEST_WATCHDOG=1 HU_TEST_REBOOT_MARK="$WORK/rebooted" \
    HU_TEST_SYS="$WORK/sysdir" HU_TEST_CARD="$WORK/card13.bin" HU_TEST_PSTORE="$WORK/pstore"
sleep 4
grep -q "sysrq unavailable" "$WORK/log.txt" && ok "logged that sysrq is unavailable" || bad "no sysrq-unavailable line"
grep -q "pstore records copied=2" "$WORK/log.txt" && ok "the dump happened anyway" || bad "the dump was skipped"
grep -q "falling back to the reboot syscall" "$WORK/log.txt" && ok "logged the reboot fallback" || bad "no fallback line"
[ -f "$WORK/rebooted" ] && ok "reached the fallback step (the syscall itself is never called in test mode)" || bad "no reboot fallback"

echo "== 14 sysfs says p1 starts inside the log region - the sink is disabled =="
mkparts "$CARD_LINES"; newmisc; newcard card14.bin; mkpstore; mkmounts mounts; mksysfs sysdir 3000
rm -f "$WORK/rebooted" "$WORK/sysrq.txt"
run init HU_TEST_FORCE_ARM=1 HU_TEST_WATCHDOG=1 HU_TEST_REBOOT_MARK="$WORK/rebooted" \
    HU_TEST_SYSRQ="$WORK/sysrq.txt" HU_TEST_SYS="$WORK/sysdir" \
    HU_TEST_CARD="$WORK/card14.bin" HU_TEST_PSTORE="$WORK/pstore"
sleep 4
grep -q "log region would reach the first partition" "$WORK/log.txt" && ok "refused a region that overlaps p1" \
  || bad "did not refuse: $(tr '\n' '|' < "$WORK/log.txt")"
grep -q "log sink fd=-1" "$WORK/log.txt" && ok "sink disabled" || bad "sink still open"
[ "$(nonzero card14.bin 8388608)" = 0 ] && ok "the card was not written" || bad "wrote into a region overlapping a partition: $(firstnz card14.bin 8388608)"
[ -f "$WORK/rebooted" ] && ok "the crash still fires with no log sink" || bad "no crash without a sink"

echo "== 15 a boot that reached /data is not crashed =="
mkparts "$CARD_LINES"; newmisc; newcard card15.bin; mkpstore; mklive mounts15; mksysfs sysdir 16384
rm -f "$WORK/rebooted" "$WORK/sysrq.txt"
run init HU_TEST_FORCE_ARM=1 HU_TEST_WATCHDOG=1 HU_TEST_REBOOT_MARK="$WORK/rebooted" \
    HU_TEST_SYSRQ="$WORK/sysrq.txt" HU_TEST_SYS="$WORK/sysdir" HU_TEST_MOUNTS="$WORK/mounts15" \
    HU_TEST_CARD="$WORK/card15.bin" HU_TEST_PSTORE="$WORK/pstore"
sleep 4
grep -q "the boot reached /data" "$WORK/log.txt" && ok "stood down on a live boot" || bad "did not notice the live boot: $(tr '\n' '|' < "$WORK/log.txt")"
[ -f "$WORK/rebooted" ] && bad "crashed a working boot" || ok "no crash on a working boot"
[ -s "$WORK/sysrq.txt" ] && bad "sysrq written on a working boot" || ok "nothing written to sysrq"
[ "$(nonzero card15.bin 8388608)" = 0 ] && ok "the card was not written on a working boot" || bad "card written on a working boot"

echo "== 16 init.real inherits no fd to the card, sysrq or the misc =="
mkparts "$CARD_LINES"; newmisc; newcard card16.bin; mkpstore; mkmounts mounts; mksysfs sysdir 16384
rm -f "$WORK/rebooted" "$WORK/sysrq.txt" "$WORK/fd-after-exec.txt"
run init HU_TEST_FORCE_ARM=1 HU_TEST_WATCHDOG=1 HU_TEST_REBOOT_MARK="$WORK/rebooted" \
    HU_TEST_SYSRQ="$WORK/sysrq.txt" HU_TEST_SYS="$WORK/sysdir" \
    HU_TEST_CARD="$WORK/card16.bin" HU_TEST_PSTORE="$WORK/pstore"
sleep 4
if [ -s "$WORK/fd-after-exec.txt" ]; then
  leaked=$(grep -c -E "card16\.bin|sysrq\.txt|misc\.bin|log\.txt" "$WORK/fd-after-exec.txt" || true)
  [ "$leaked" = 0 ] && ok "no wrapper fd visible to init.real" || bad "$leaked wrapper fds inherited by init.real: $(grep -E "card16\.bin|sysrq\.txt|misc\.bin|log\.txt" "$WORK/fd-after-exec.txt" | tr '\n' '|')"
else
  bad "init.real did not record its fds"
fi

printf 'summary: failures=%d\n' "$fail"
[ "$fail" = 0 ]
