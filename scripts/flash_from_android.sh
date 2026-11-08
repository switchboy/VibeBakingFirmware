#!/bin/sh
# flash_from_android.sh - install the Android 14 images using the head unit's *own* root shell, from
# the Android 11 ROM that is still booting (docs/flash.md, **D25**).
#
# Why this exists: the unit's recovery verifies a package before running anything in it, and the two
# OEM packages we hold are signed with a certificate we cannot sign with. Both stock zips carry a
# SignApk PKCS#7 blob in the zip comment signed by cert sha256 cf2ab3818595c4ed..., and
# /system/etc/security/otacerts.zip inside both stock system images contains exactly that one cert
# (HCT replaced the tree's testkey with their own key - subject CN=Android, different key). So our
# payload cannot pass recovery verification, and AOSP testkey (a40da80a...) would be rejected too.
# This script is the alternative transport: raw images read from the USB stick and written with dd.
#
# Run it inside a root shell on the unit. Two ways to get that root (**the ROM's own su is blocked**:
# `/system/xbin/su` exists but returns "Permission denied", and there is no Magisk - Nov 5 probe):
#   * from a workstation over adb - this ROM is userdebug with ro.debuggable=1, so `adb root` gives a
#     uid-0 shell: `adb root && adb shell sh /mnt/udisk/hu14/flash.sh` (the HU must be the USB *device*,
#     i.e. the CarPlay/OTG port; ro.adb.secure=1 means an authorization prompt on the unit's screen);
#   * in Termux if root ever comes back: `/system/xbin/su 0 sh /mnt/udisk/hu14/flash.sh`.
# POSIX sh only - Android's /system/bin/sh is mksh - and no toybox dependency beyond dd/sha256sum/stat.
#
# It writes exactly two partitions: super (Android 14's system/vendor/product/system_ext/odm plus its
# dynamic-partition metadata, which is inside super) and boot (Android 14 kernel+ramdisk+vendor DTB).
# It does NOT touch recovery, uboot, trust, dtbo, RKLoader.bin, logo, security or the GPT, and it does
# not resize anything - the super partition keeps its 3,263,168,512 B size (**D11**), only the logical
# partitions inside it are recreated by the metadata we write. Because recovery stays intact, the stock
# Android 10 package remains the rollback (**D18**), flashed the normal way.
#
# /data is deliberately NOT wiped here: it is mounted read-write by the running Android 11, so the
# clean way is to wipe it from recovery afterwards ("wipe data/factory reset") - same effect as the
# wipe_block_device() the OTA script would have done, without touching a mounted filesystem (**D10**).
set -u

STICK=${STICK:-/mnt/udisk}
SRC="$STICK/hu14"
BACKUP="$STICK/hu14-backup"
LOG="$SRC/hu14-flash.log"

SUPER=/dev/block/by-name/super
BOOT=/dev/block/by-name/boot

say() { printf '%s\n' "$1" | tee -a "$LOG"; }

# Partition size without depending on toybox's blockdev (not present in every Android 11 build): ask
# blockdev first, else read the block device's KiB column out of /proc/partitions via the by-name link.
part_size() {
  name=$(basename "$(readlink "$1" 2>/dev/null || printf '%s' "$1")")
  size=$(blockdev --getsize64 "$1" 2>/dev/null)
  [ -n "${size:-}" ] || size=$(awk -v d="$name" '$4 == d { print $3 * 1024 }' /proc/partitions 2>/dev/null)
  printf '%s' "${size:-0}"
}

[ -d "$SRC" ] || { echo "no $SRC on the stick (copy the hu14 dir to /mnt/udisk)"; exit 1; }
: > "$LOG" 2>/dev/null || { echo "stick not writable ($LOG)"; exit 1; }
say "hu14 flash - $(date 2>/dev/null)"
say "running rom: $(getprop ro.build.version.release) $(getprop ro.build.display.id)"

# Must be a root shell: dd of an eMMC partition is not permitted any other way.
if [ "$(id -u)" != 0 ]; then
  say "ABORT: needs a root shell (uid 0). This ROM's own su is blocked, so use adb root (userdebug,"
  say "       ro.debuggable=1): adb root && adb shell sh /mnt/udisk/hu14/flash.sh"
  exit 1
fi

# Guard: this must run from Android 10/11. Running it from Android 14 would overwrite the ROM it is
# booted from, which is a self-destruct, not an install.
rel=$(getprop ro.build.version.release 2>/dev/null)
case "$rel" in
  10|11) say "target device confirmed running Android $rel" ;;
  *) say "ABORT: this runs from Android 10/11, not from $rel"; exit 1 ;;
esac

[ -e "$SUPER" ] || { say "ABORT: no $SUPER"; exit 1; }
[ -e "$BOOT" ] || { say "ABORT: no $BOOT"; exit 1; }
[ -s "$SRC/sha256.txt" ] || { say "ABORT: no sha256.txt next to the images"; exit 1; }

mkdir -p "$BACKUP" 2>/dev/null

say "== verify the images on the stick =="
ok=1
while read -r want name _rest; do
  [ -n "${want:-}" ] || continue
  got=$(sha256sum "$SRC/$name" 2>/dev/null | cut -d' ' -f1)
  if [ "$got" = "$want" ]; then
    say "  ok   $name  $got"
  else
    say "  FAIL $name  expected $want got ${got:-unreadable}"
    ok=0
  fi
done < "$SRC/sha256.txt"
[ "$ok" = 1 ] || { say "ABORT: stick images do not match sha256.txt - copy them again"; exit 1; }

super_size=$(part_size "$SUPER")
super_img=$(stat -c %s "$SRC/super.img" 2>/dev/null || echo 0)
boot_img=$(stat -c %s "$SRC/boot.img" 2>/dev/null || echo 0)
say "super partition $super_size B ; super.img $super_img B ; boot.img $boot_img B"
if [ "$super_img" -gt "$super_size" ] || [ "$super_img" -lt 1000000000 ]; then
  say "ABORT: super.img size $super_img B is not plausible for a $super_size B partition"
  exit 1
fi

# Insurance before writing: copy the head and tail of super and the whole boot partition, so a
# half-written flash can still be put back with the stock Android 10 package or these blocks.
# Read-only, ~64 MB, nothing written to the partitions.
say "== backup of what we are about to overwrite =="
dd if="$SUPER" of="$BACKUP/super-head.bin" bs=4096 count=4096 2>&1 | tail -1 | tee -a "$LOG"
tail_off=$((super_size - 16777216))
dd if="$SUPER" of="$BACKUP/super-tail.bin" bs=4096 skip="$tail_off" count=4096 2>&1 | tail -1 | tee -a "$LOG"
dd if="$BOOT" of="$BACKUP/boot-current.bin" bs=4096 count=8192 2>&1 | tail -1 | tee -a "$LOG"
say "  backups in $BACKUP ($(ls "$BACKUP" 2>/dev/null | tr '\n' ' '))"

say "== writing super (Android 14 system/vendor/product/system_ext/odm + metadata) =="
dd if="$SRC/super.img" of="$SUPER" bs=4096 conv=fsync 2>&1 | tail -1 | tee -a "$LOG"
say "== writing boot (Android 14 kernel + ramdisk + vendor DTB) =="
dd if="$SRC/boot.img" of="$BOOT" bs=4096 conv=fsync 2>&1 | tail -1 | tee -a "$LOG"
sync

say "== done: super and boot now hold Android 14; recovery/uboot/trust/dtbo/security/GPT untouched =="
say "next steps:"
say "  1. reboot into recovery (hold the reset button, or the recovery entry in the menu)"
say "  2. in recovery: wipe data/factory reset  (Android 10's /data is not readable by Android 14 - D10)"
say "  3. reboot. Keep this stick plugged in: the ROM's auto-probe writes hu-probe-<ts>.md to $STICK"
say "  4. if it does not boot, reboot into recovery and install the stock Android 10 package"
say "     (copy backup/a10-update.zip to the stick root as update.zip, then install)"
