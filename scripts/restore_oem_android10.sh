#!/usr/bin/env bash
# Blind restore of the OEM Android 10 payload (D29/D31): writes ONLY super + boot.
#
# Where it runs: anywhere with a root shell and the rescue dir mounted - TCP adb root on the old
# firmware, a serial console shell, or the rescue initramfs booted from the SD card. Nothing here
# touches recovery/uboot/trust/dtbo/vbmeta/security/loader/GPT, so the vendor boot chain stays as-is.
#
#   RESCUE=/path/with/super-a10.img+boot-a10.img+rescue.sha256 scripts/restore_oem_android10.sh
#
# Sizes are compared in awk: Android's mksh does 32-bit arithmetic, so anything above 2 GiB wraps
# negative and a plain [ -gt ] test rejects a valid image (measured Nov 9: echo $((2147483648+1))
# prints -2147483647). dd's skip/count are in units of bs=, not bytes.
set -u

RESCUE=${RESCUE:-/mnt/udisk/rescue}
SUPER=/dev/block/by-name/super
BOOT=/dev/block/by-name/boot

say() { printf '%s\n' "$1"; }

[ -d "$RESCUE" ] || { say "no $RESCUE"; exit 1; }
[ -f "$RESCUE/super-a10.img" ] || { say "no super-a10.img in $RESCUE"; exit 1; }
[ -f "$RESCUE/boot-a10.img" ] || { say "no boot-a10.img in $RESCUE"; exit 1; }

if [ "$(id -u)" != 0 ]; then
  say "ABORT: needs uid 0 (dd of a partition is not permitted any other way)"
  exit 1
fi

# The unit must be running something that mounted userdata, or booted from the card; either way the
# partition names must exist before we start.
[ -e "$SUPER" ] && [ -e "$BOOT" ] || { say "ABORT: /dev/block/by-name/super or boot missing"; exit 1; }

if [ -f "$RESCUE/rescue.sha256" ]; then
  say "== verifying the rescue payload =="
  (cd "$RESCUE" && sha256sum -c rescue.sha256 2>&1 | tail -4) || { say "ABORT: sha mismatch"; exit 1; }
fi

part_size() {
  name=$(basename "$(readlink "$1" 2>/dev/null || printf '%s' "$1")")
  size=$(blockdev --getsize64 "$1" 2>/dev/null)
  [ -n "${size:-}" ] || size=$(awk -v d="$name" '$4 == d { printf "%.0f", $3 * 1024 }' /proc/partitions 2>/dev/null)
  printf '%s' "${size:-0}"
}

super_size=$(part_size "$SUPER")
super_img=$(stat -c %s "$RESCUE/super-a10.img" 2>/dev/null || echo 0)
boot_img=$(stat -c %s "$RESCUE/boot-a10.img" 2>/dev/null || echo 0)
say "super partition $super_size B ; super-a10.img $super_img B ; boot-a10.img $boot_img B"
if awk -v img="$super_img" -v part="$super_size" \
     'BEGIN{ exit (img+0 > part+0 || img+0 < 1000000000) ? 1 : 0 }'; then
  :
else
  say "ABORT: super-a10.img $super_img B is not plausible for a $super_size B partition"
  exit 1
fi

say "== writing super (Android 10 system/vendor/product/odm + its dynamic-partition metadata) =="
dd if="$RESCUE/super-a10.img" of="$SUPER" bs=4096 conv=fsync 2>&1 | tail -1
say "== writing boot (vendor April 2025 Android 10 boot image) =="
dd if="$RESCUE/boot-a10.img" of="$BOOT" bs=4096 conv=fsync 2>&1 | tail -1
sync
say "== done: Android 10 restored; recovery/uboot/trust/dtbo/security/GPT untouched =="
say "next: power-cycle the unit. Android 10 formats /data fresh, so its settings/accounts are gone (D10)."
