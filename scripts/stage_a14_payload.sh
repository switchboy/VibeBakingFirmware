#!/usr/bin/env bash
# Stage the Android 14 payload for a boot+super-only write (D18/D19: never the boot chain).
# This script only PUSHES files and verifies hashes. It writes nothing to the unit's partitions.
#
#   scripts/stage_a14_payload.sh [bootimg] [superimg]
#     default bootimg  /run/media/Daan/Opslagmonster/a14-work/a14chk/a14-boot-fixed.img
#                      (vendor A11 kernel 4.19.193 #24 + A14 first-stage ramdisk, sha 933e2ecc4237...,
#                       32,796,672 B; pairs with the vermagic 4.19.193 modules inside super-a14.img)
#     default superimg /run/media/Daan/Opslagmonster/a14-work/a14chk/raw-super.img
#                      (our A14 logical super container, sha d4b4990931cc..., 3,263,168,512 B)
#
# The payload lands in /data/local/tmp/a14 on the running stock Android 10, under the names the installer
# expects (boot-a14.img, super-a14.img), with a sha256.txt manifest built from those names. Partition
# writes happen either from that staged copy under adb root (scripts/install_a14_from_adb_root.sh, the
# primary route) or from the card in the recovery environment (bootSD + update.zip built by
# scripts/build_recovery_fallback_zip.sh) - recovery is where super is not mounted by Android.
# The files live under $WORK (the repo volume, 442 GiB free) because the workstation's root filesystem
# is full; scripts/cold_storage_move.sh STAGE=payload moved them there and re-verified both hashes.
set -euo pipefail

WORK=${WORK:-/run/media/Daan/Opslagmonster/a14-work}
# Which payload is staged depends on the shape (D46/D47). Shape A is the default - the proven OEM
# kernel with the current layout - and it pairs with the super built from the Android 10 restaged
# vendor (the stock 4.19.111+ modules live in that partition's /vendor/lib/modules). Shape B is the
# Android 11 kernel fallback and pairs with the A11-vendor super whose modules are vermagic 4.19.193.
SHAPE=${SHAPE:-a10}
case "$SHAPE" in
  a10) BOOTIMG="${1:-$WORK/a14chk-shapeA/boot-a10k-a14rd.img}"; SUPERIMG="${2:-$WORK/a14chk-shapeA/raw-super.img}" ;;
  a11) BOOTIMG="${1:-$WORK/a14chk/a14-boot-fixed.img}";        SUPERIMG="${2:-$WORK/a14chk/raw-super.img}" ;;
  *) echo "SHAPE must be a10 or a11"; exit 1 ;;
esac
echo "shape $SHAPE: boot $(basename "$BOOTIMG") ($(stat -c %s "$BOOTIMG" 2>/dev/null || echo missing) B), super $(basename "$SUPERIMG") ($(stat -c %s "$SUPERIMG" 2>/dev/null || echo missing) B)"
[ -s "$BOOTIMG" ] && [ -s "$SUPERIMG" ] || { echo "abort: payload files missing for shape $SHAPE"; exit 1; }

adb get-state >/dev/null || { echo "abort: no adb device"; exit 1; }
adb shell id 2>/dev/null | grep -q 'uid=0' || { echo "abort: adb shell is not root - run adb root first"; exit 1; }

SUPER_SIZE=$(stat -c %s "$SUPERIMG")
PART_SIZE=$(adb shell blockdev --getsize64 /dev/block/by-name/super 2>/dev/null | tr -d '\r')
[ "$SUPER_SIZE" -le "$PART_SIZE" ] || { echo "abort: super payload $SUPER_SIZE B exceeds partition $PART_SIZE B"; exit 1; }

# The installer (scripts/install_a14_from_adb_root.sh) looks for boot-a14.img / super-a14.img and a
# sha256.txt manifest of "<hash> <name>". So the files are pushed under those names, and the manifest it
# verifies is built here from the pushed names - the local filenames would make it abort.
BOOT_NAME=${BOOT_NAME:-boot-a14.img}
SUPER_NAME=${SUPER_NAME:-super-a14.img}
adb shell "mkdir -p /data/local/tmp/a14"
MANIFEST="$WORK/staged-sha256.txt"
: > "$MANIFEST"
for pair in "$BOOTIMG:$BOOT_NAME" "$SUPERIMG:$SUPER_NAME"; do
  f=${pair%%:*}; name=${pair##*:}
  echo "pushing $name from $(basename "$f") ($(stat -c %s "$f") B)"
  adb push "$f" "/data/local/tmp/a14/$name" >/dev/null
  want=$(sha256sum "$f" | cut -d' ' -f1)
  got=$(adb shell "sha256sum /data/local/tmp/a14/$name" 2>/dev/null | tr -d '\r' | cut -d' ' -f1)
  [ "$want" = "$got" ] || { echo "abort: $name on unit hashes $got, local is $want"; exit 1; }
  echo "  ok $name $want"
  printf '%s  %s\n' "$want" "$name" >> "$MANIFEST"
done
adb push "$MANIFEST" /data/local/tmp/a14/sha256.txt >/dev/null
# The manifest is read back on the unit: the installer's check is only as good as this file. Both reads
# are informational - stock A10's sha256sum may not support -c, so never let them abort a good staging.
adb shell "sha256sum -c /data/local/tmp/a14/sha256.txt" 2>&1 | tr -d '\r' | head -4 || true
adb shell "cat /data/local/tmp/a14/sha256.txt" 2>&1 | tr -d '\r' | head -4 || true

echo "staged in /data/local/tmp/a14: boot-a14.img, super-a14.img, sha256.txt."
echo "Install (primary route, detached so adbd's death cannot abort the wipe):"
echo "  adb shell sh /data/local/tmp/a14/install_a14_from_adb_root.sh   # WIPE=0 first pass, then:"
echo "  adb shell setsid -f sh -c '...see the WIPE=0 output the script prints...'"
echo "Fallback (recovery, bootSD card): update.zip built by scripts/build_recovery_fallback_zip.sh, with"
echo "super-a14.img and boot-a14.img next to it in the card root."
echo "And nothing else - no uboot/trust/dtb/dtbo/vbmeta/security/GPT writes (D18, D19)."
echo "Rollback if it does not boot: the stock backup pulled by scripts/pull_stock_backup.sh, or re-run the"
echo "bootSD recovery with diatsia fw/update(1).zip."
