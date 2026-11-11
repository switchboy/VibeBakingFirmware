#!/usr/bin/env bash
# Stage the Android 14 payload for a boot+super-only write (D18/D19: never the boot chain).
# This script only PUSHES files and verifies hashes. It writes nothing to the unit's partitions.
#
#   scripts/stage_a14_payload.sh [bootimg] [superimg]
#     default bootimg  /run/media/Daan/Opslagmonster/a14-work/a14chk/a14-boot-fixed.img
#                      (A10 kernel + A14 first-stage ramdisk, sha 933e2ecc4237..., 32,796,672 B)
#     default superimg /run/media/Daan/Opslagmonster/a14-work/a14chk/raw-super.img
#                      (our A14 logical super container, sha d4b4990931cc..., 3,263,168,512 B)
#
# The payload lands in /data/local/tmp/a14 on the running stock Android 10, sha-verified against the local
# files. The actual partitions are written later from the recovery environment (bootSD), where super is not
# mounted by Android - that is the safe moment to dd (D30: read the console output of the session first).
# The files live under $WORK (the repo volume, 472 GiB free) because the workstation's root filesystem is
# full; scripts/cold_storage_move.sh STAGE=payload moved them there and re-verified both hashes.
set -euo pipefail

WORK=${WORK:-/run/media/Daan/Opslagmonster/a14-work}
BOOTIMG="${1:-$WORK/a14chk/a14-boot-fixed.img}"
SUPERIMG="${2:-$WORK/a14chk/raw-super.img}"

adb get-state >/dev/null || { echo "abort: no adb device"; exit 1; }
adb shell id 2>/dev/null | grep -q 'uid=0' || { echo "abort: adb shell is not root - run adb root first"; exit 1; }

SUPER_SIZE=$(stat -c %s "$SUPERIMG")
PART_SIZE=$(adb shell blockdev --getsize64 /dev/block/by-name/super 2>/dev/null | tr -d '\r')
[ "$SUPER_SIZE" -le "$PART_SIZE" ] || { echo "abort: super payload $SUPER_SIZE B exceeds partition $PART_SIZE B"; exit 1; }

adb shell "mkdir -p /data/local/tmp/a14"
for f in "$BOOTIMG" "$SUPERIMG"; do
  base=$(basename "$f")
  echo "pushing $base ($(stat -c %s "$f") B)"
  adb push "$f" "/data/local/tmp/a14/$base" >/dev/null
  want=$(sha256sum "$f" | cut -c1-12)
  got=$(adb shell "sha256sum /data/local/tmp/a14/$base" 2>/dev/null | cut -c1-12)
  [ "$want" = "$got" ] || { echo "abort: $base on unit hashes $got, local is $want"; exit 1; }
  echo "  ok $base $want"
done

echo "staged in /data/local/tmp/a14. Partition writes, from the recovery environment (bootSD), are:"
echo "  dd if=/data/local/tmp/a14/boot-a10k-a14rd.img of=/dev/block/by-name/boot bs=4096"
echo "  dd if=/data/local/tmp/a14/raw-super.img       of=/dev/block/by-name/super bs=4096 conv=fsync"
echo "and nothing else - no uboot/trust/dtb/dtbo/vbmeta/security/GPT writes (D18, D19)."
echo "Rollback if it does not boot: the stock backup pulled by scripts/pull_stock_backup.sh, or re-run the"
echo "bootSD recovery with diatsia fw/update(1).zip."
