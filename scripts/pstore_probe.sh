#!/usr/bin/env sh
# pstore_probe.sh - rung L0 of the boot-only ladder (D62): does a failed boot's console log survive to be read?
#
# Run on the workstation, not on the unit:
#   HU_CONSENT=1 sh scripts/pstore_probe.sh              # owner-approved warm reboot
#   sh scripts/pstore_probe.sh                            # dry run: prints the plan, touches nothing
#
# Why it exists. Both Nov 18 payload writes died before init started a service and the panel told us nothing.
# The OEM kernel registers RAMoops (`dmesg`: `ramoops: attached 0xf0000@0x110000`, `console [pstore-1] enabled`,
# D65), so a dying boot should leave its console bytes in DRAM for the next boot to read - but only across a
# WARM reset. A cold power cycle loses DRAM, which is why the Nov 18 read came back empty after the owner's
# restore, and reading a pstore file deletes it, so this script is the reader.
#
# Costs: one boot cycle of the healthy stock unit. Writes: nothing on the unit (no partition, no file outside
# /sys/fs/pstore's own deletion), and the captured files land in the scratch dir on the workstation. It is a
# read-only probe plus a reboot; the reboot is the part the owner must approve, so it is gated on HU_CONSENT=1.
#
# Device is TCP adb (D28). Binary reads go through `toybox base64` because a plain `adb exec-out dd/cat` inserts
# CR bytes into binary output and corrupts the digest (measured Nov 18); the CRs are stripped before decoding.
set -u

DEV=${DEV:-192.168.1.120:5555}
SCRATCH=${HU_SCRATCH_ROOT:-/run/media/Daan/Opslagmonster/a14-work/tmp}
if ! { mkdir -p "$SCRATCH" && : > "$SCRATCH/.pstore_probe"; } 2>/dev/null; then
  SCRATCH=/run/media/Daan/Opslagmonster/a14-work/scratch
  mkdir -p "$SCRATCH" 2>/dev/null || true
fi
rm -f "$SCRATCH/.pstore_probe"
OUT="$SCRATCH/pstore-$(date -u +%Y%m%d-%H%M%S)"

# The scratch root is only real if a file can be written there: mkdir alone succeeds on a quota-limited tmpfs,
# which is what burned scripts/repo_update.sh on Nov 18.
if ! mkdir -p "$OUT" 2>/dev/null || ! : > "$OUT/.probe" 2>/dev/null; then
  echo "scratch root $SCRATCH cannot hold files (set HU_SCRATCH_ROOT to a writable directory)" >&2
  exit 1
fi
rm -f "$OUT/.probe"

pull() {  # $1 = device path, $2 = local name; binary-safe, then hashed on the workstation
  p="$OUT/$2"
  adb -s "$DEV" exec-out "toybox cat $1 2>/dev/null | toybox base64" 2>/dev/null \
    | tr -d '\r' | base64 -d > "$p" 2>/dev/null
  if [ -s "$p" ]; then
    echo "  $2: $(wc -c < "$p") bytes, sha256 $(sha256sum "$p" | cut -c1-12)"
  else
    echo "  $2: empty or absent"
    rm -f "$p"
  fi
}

echo "== pstore probe (L0) on $DEV -> $OUT =="
adb kill-server >/dev/null 2>&1
adb start-server >/dev/null 2>&1
adb connect "$DEV" >/dev/null 2>&1
if ! adb -s "$DEV" get-state >/dev/null 2>&1; then
  echo "not reachable: $DEV did not answer (this is the workstation's adb daemon or the unit's adbon state)" >&2
  exit 1
fi
adb -s "$DEV" root >/dev/null 2>&1 || echo "  warning: adb root failed; pstore needs uid 0"

echo "-- before (nothing is read from pstore yet, so no record is consumed) --"
adb -s "$DEV" shell 'toybox cat /proc/sys/kernel/random/boot_id; toybox uptime; toybox ls -l /sys/fs/pstore 2>/dev/null; toybox grep -m1 -i "linux version" /proc/version 2>/dev/null' 2>/dev/null | sed 's/^/  /'
# Android's shell cannot reliably grep its own dmesg through a pipe (measured Nov 18: the device-side
# `dmesg | grep pstore` printed nothing while a host-side grep found the ramoops lines), so the log is pulled
# and filtered here. dmesg carries colour codes on this kernel, so they are stripped before the file lands.
pull_dmesg() {  # $1 = local file name
  adb -s "$DEV" exec-out 'toybox dmesg 2>/dev/null' | tr -d '\r' \
    | sed 's/\x1b\[[0-9;]*m//g' > "$OUT/$1" 2>/dev/null
  echo "  dmesg: $(wc -l < "$OUT/$1") lines; pstore/ramoops/bootconsole lines:"
  grep -i -m4 "pstore\|ramoops\|bootconsole" "$OUT/$1" | sed 's/^/    /'
}
pull_dmesg dmesg-before.txt
echo "  dmesg: $(wc -l < "$OUT/dmesg-before.txt") lines; pstore/ramoops/bootconsole lines:"
grep -i -m4 "pstore\|ramoops\|bootconsole" "$OUT/dmesg-before.txt" | sed 's/^/    /'

if [ "${HU_CONSENT:-}" != "1" ]; then
  echo "-- dry run: NOT rebooting. Re-run with HU_CONSENT=1 after the owner approves one warm reboot. --"
  echo "   plan: adb reboot -> reconnect -> read /sys/fs/pstore/* on the next boot (reading deletes them)."
  exit 1
fi

echo "-- warm reboot (RAM records survive this; a cold power cycle would erase them) --"
adb -s "$DEV" reboot 2>/dev/null
sleep 20
for i in 1 2 3 4 5 6; do
  adb connect "$DEV" >/dev/null 2>&1
  if adb -s "$DEV" get-state >/dev/null 2>&1; then break; fi
  sleep 15
done
if ! adb -s "$DEV" get-state >/dev/null 2>&1; then
  echo "the unit did not answer after reboot - read the panel, and do not power-cycle it (that erases RAMoops)" >&2
  exit 1
fi
adb -s "$DEV" root >/dev/null 2>&1

echo "-- after (the console record from the boot we just left) --"
adb -s "$DEV" shell 'toybox cat /proc/sys/kernel/random/boot_id; toybox ls -l /sys/fs/pstore 2>/dev/null' 2>/dev/null | sed 's/^/  /'
pull_dmesg dmesg-after.txt
pull /sys/fs/pstore/console-ramoops-0 console-ramoops-0
pull /sys/fs/pstore/dmesg-ramoops-0 dmesg-ramoops-0
pull /sys/fs/pstore/pmsg-ramoops-0 pmsg-ramoops-0

echo "-- verdict --"
if [ -s "$OUT/console-ramoops-0" ]; then
  echo "PASS: the console record survived the warm reset. A dying init boot can be read this way; the"
  echo "      first_stage/second_stage lines are the thing to look for in console-ramoops-0."
else
  echo "FAIL: no console record. Either the boot before this one produced no console output, or the record"
  echo "      was consumed earlier. Do not conclude RAMoops is broken - dmesg above is the evidence."
fi
echo "captured files in $OUT"
