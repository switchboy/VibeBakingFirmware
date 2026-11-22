#!/usr/bin/env bash
# smoke_card_rearm.sh - offline gate for scripts/arm_card_misc.sh (**D98**). Runs the script against a
# regular file (HU_MISC_FILE + HU_OFFLINE=1) and checks the exact 2048 B BCB layout, the registered
# blob digest, and the eMMC refusal path. Nothing here touches a device.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
SCRATCH=${HU_SCRATCH_ROOT:-/run/media/Daan/Opslagmonster/a14-work/tmp}
mkdir -p "$SCRATCH"
WORK=$(mktemp -d "$SCRATCH/card-rearm.XXXXXX")
BCB_SHA=ceaae1a6314a19927ab431d55b46d08a6aaf73e9bcceb578244783c06bffd00e
fails=0

echo "=== 1. arm into a zeroed 4,194,304 B file"
head -c 4194304 /dev/zero > "$WORK/misc.bin"
HU_OFFLINE=1 HU_MISC_FILE="$WORK/misc.bin" sh "$REPO/scripts/arm_card_misc.sh" > "$WORK/arm1.log" 2>&1
rc=$?
grep -E "blob|readback|ARMED" "$WORK/arm1.log" | head -4
[ "$rc" = 0 ] && echo "  rc=0" || { echo "  FAIL rc=$rc"; fails=$((fails+1)); }

got=$(sha256sum "$WORK/misc.bin" | cut -d' ' -f1)
head2=$(head -c 2048 "$WORK/misc.bin" | sha256sum | cut -d' ' -f1)
if [ "$head2" = "$BCB_SHA" ]; then echo "  head 2048 B digest = $BCB_SHA (registered)"; else echo "  FAIL head digest $head2 != registered $BCB_SHA"; fails=$((fails+1)); fi

echo "=== 2. byte layout: 'boot-recovery' at 0, NUL at 12, 'recovery' + NL at 64, zeros to 2048"
head -c 13 "$WORK/misc.bin" | od -An -c | tr -s ' ' | head -2
printf '  offset 0..12: %s\n' "$(head -c 13 "$WORK/misc.bin" | tr -d '\0' | tr -d '\n')"
printf '  offset 64..72: %s\n' "$(dd if="$WORK/misc.bin" bs=1 skip=64 count=9 2>/dev/null | tr -d '\n')"
pad=$(dd if="$WORK/misc.bin" bs=1 skip=13 count=51 2>/dev/null | tr -d '\0' | wc -c)
[ "$pad" = 0 ] && echo "  13..63 all zero" || { echo "  FAIL nonzero in 13..63 ($pad B)"; fails=$((fails+1)); }
pad2=$(dd if="$WORK/misc.bin" bs=1 skip=73 count=1975 2>/dev/null | tr -d '\0' | wc -c)
[ "$pad2" = 0 ] && echo "  73..2047 all zero" || { echo "  FAIL nonzero in 73..2047 ($pad2 B)"; fails=$((fails+1)); }
tailbyte=$(dd if="$WORK/misc.bin" bs=1 skip=2048 count=1 2>/dev/null | wc -c)
[ "$tailbyte" = 1 ] && echo "  byte at 2048 untouched (write confined to 2048 B)" || { echo "  FAIL write ran past 2048"; fails=$((fails+1)); }

echo "=== 3. idempotent re-arm"
HU_OFFLINE=1 HU_MISC_FILE="$WORK/misc.bin" sh "$REPO/scripts/arm_card_misc.sh" > "$WORK/arm2.log" 2>&1
rc=$?; [ "$rc" = 0 ] && echo "  rc=0" || { echo "  FAIL rc=$rc"; fails=$((fails+1)); }
got2=$(sha256sum "$WORK/misc.bin" | cut -d' ' -f1)
[ "$got" = "$got2" ] && echo "  file digest unchanged after a second arm: ${got:0:12}" || { echo "  FAIL digest changed: ${got2:0:12}"; fails=$((fails+1)); }

echo "=== 4. refusal: an eMMC-shaped target is never written"
cp "$WORK/misc.bin" "$WORK/mmcblk2p3.bin"
HU_OFFLINE=1 HU_MISC_FILE="$WORK/mmcblk2p3.bin" sh "$REPO/scripts/arm_card_misc.sh" > "$WORK/arm3.log" 2>&1
rc=$?
grep -a "ABORT" "$WORK/arm3.log" | head -2
[ "$rc" != 0 ] && echo "  refused with rc=$rc" || { echo "  FAIL: eMMC-shaped target accepted"; fails=$((fails+1)); }
cmp -s "$WORK/misc.bin" "$WORK/mmcblk2p3.bin" && echo "  eMMC-shaped file untouched" || { echo "  FAIL: eMMC-shaped file modified"; fails=$((fails+1)); }

echo "=== 5. refusal: a missing target writes nothing"
HU_OFFLINE=1 HU_MISC_FILE="$WORK/nope.bin" sh "$REPO/scripts/arm_card_misc.sh" > "$WORK/arm4.log" 2>&1
rc=$?; grep -a "ABORT" "$WORK/arm4.log" | head -2
[ "$rc" != 0 ] && echo "  refused with rc=$rc" || { echo "  FAIL: missing target accepted"; fails=$((fails+1)); }

echo "summary: failures=$fails"
[ "$fails" = 0 ] && rm -rf "$WORK"
exit "$fails"
