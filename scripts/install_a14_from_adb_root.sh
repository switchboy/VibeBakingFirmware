#!/system/bin/sh
# install_a14_from_adb_root.sh - put the Android 14 payload on the PX6 head unit using the unit's own
# root shell while stock Android 10 is still booting.
#
# Why this route (Nov 11): the recovery environment is reachable only through the SD-boot card and it
# is MENU-ONLY and signature-checked, so our payload cannot travel as an update.zip - the OEM recovery
# rejects anything not signed with HCT's key ("carfull complained about signatures"). Raw dd from a
# uid-0 shell is the transport that attempt 1 already proved did not damage the hardware.
#
# It writes exactly two partitions (D18/D19): super and boot. recovery/uboot/trust/dtb/dtbo/vbmeta/
# security/misc/GPT are never touched, and nothing is resized - super keeps its 3,263,168,512 B.
#
# /data IS wiped here (D10). Android 10 formatted it with software encryption; Android 14's fstab
# (D34 + Nov 11 kernel-config fix) mounts plain f2fs, so the old fs must not survive. Recovery cannot
# do the wipe for us (menu only, and its own fstab is the Android 10 one), so we stop the framework,
# unmount, and re-create the filesystem with the unit's own make_f2fs.
#
# Run:  adb root && adb shell sh /data/local/tmp/a14/install_a14_from_adb_root.sh
# POSIX-ish mksh: dd/sha256sum/stat/getprop/awk only. Sizes above 2 GiB wrap in mksh arithmetic,
# so every size comparison is done in awk (double precision).
set -u

SRC=${SRC:-/data/local/tmp/a14}
BACKUP=${BACKUP:-/data/local/tmp/a14-backup}
BOOT_IMG=${BOOT_IMG:-boot-a14.img}
SUPER_IMG=${SUPER_IMG:-super-a14.img}
BOOT=/dev/block/by-name/boot
SUPER=/dev/block/by-name/super
USERDATA=/dev/block/by-name/userdata

say() { printf '%s\n' "$1"; }

part_size() {
  name=$(basename "$(readlink "$1" 2>/dev/null || printf '%s' "$1")")
  size=$(blockdev --getsize64 "$1" 2>/dev/null)
  [ -n "${size:-}" ] || size=$(awk -v d="$name" '$4 == d { printf "%.0f", $3 * 1024 }' /proc/partitions 2>/dev/null)
  printf '%s' "${size:-0}"
}

if [ "$(id -u)" != 0 ]; then
  say "ABORT: needs uid 0 - run `adb root` first"
  exit 1
fi

rel=$(getprop ro.build.version.release 2>/dev/null)
case "$rel" in
  10|11) say "running Android $rel - install target confirmed" ;;
  *) say "ABORT: this installs onto a running Android 10/11, not onto $rel"; exit 1 ;;
esac

[ -s "$SRC/$BOOT_IMG" ] || { say "ABORT: no $SRC/$BOOT_IMG"; exit 1; }
[ -s "$SRC/$SUPER_IMG" ] || { say "ABORT: no $SRC/$SUPER_IMG"; exit 1; }
[ -s "$SRC/sha256.txt" ] || { say "ABORT: no $SRC/sha256.txt - record the shas before writing"; exit 1; }
[ -e "$BOOT" ] || { say "ABORT: no $BOOT"; exit 1; }
[ -e "$SUPER" ] || { say "ABORT: no $SUPER"; exit 1; }

say "== images as staged on the unit =="
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
[ "$ok" = 1 ] || { say "ABORT: staged images do not match sha256.txt - push them again"; exit 1; }

boot_size=$(part_size "$BOOT")
super_size=$(part_size "$SUPER")
boot_img=$(stat -c %s "$SRC/$BOOT_IMG")
super_img=$(stat -c %s "$SRC/$SUPER_IMG")
say "boot partition $boot_size B ; image $boot_img B"
say "super partition $super_size B ; image $super_img B"
awk -v i="$boot_img" -v p="$boot_size" 'BEGIN{ exit (i+0 > p+0 || i+0 < 10000000) ? 1 : 0 }' \
  || { say "ABORT: boot image $boot_img B not plausible for $boot_size B"; exit 1; }
awk -v i="$super_img" -v p="$super_size" 'BEGIN{ exit (i+0 > p+0 || i+0 < 1000000000) ? 1 : 0 }' \
  || { say "ABORT: super image $super_img B not plausible for $super_size B"; exit 1; }

# Insurance, read-only: the pieces a half-written flash would need to be put back.
mkdir -p "$BACKUP" 2>/dev/null
say "== backup of what we overwrite =="
dd if="$BOOT" of="$BACKUP/boot-before.bin" bs=4096 count="$((boot_img / 4096 + 1))" 2>/dev/null | tail -1
dd if="$SUPER" of="$BACKUP/super-head.bin" bs=4096 count=4096 2>/dev/null | tail -1
tail_skip=$(awk -v s="$super_size" 'BEGIN{ printf "%.0f", (s - 16777216) / 4096 }')
dd if="$SUPER" of="$BACKUP/super-tail.bin" bs=4096 skip="$tail_skip" count=4096 2>/dev/null | tail -1
say "  backups in $BACKUP: $(ls "$BACKUP" 2>/dev/null | tr '\n' ' ')"

say "== writing boot ($BOOT_IMG) =="
dd if="$SRC/$BOOT_IMG" of="$BOOT" bs=4096 conv=fsync 2>&1 | tail -1
say "== writing super ($SUPER_IMG) =="
dd if="$SRC/$SUPER_IMG" of="$SUPER" bs=4096 conv=fsync 2>&1 | tail -1
sync

say "== read back what is on the partitions =="
got_boot=$(dd if="$BOOT" bs=4096 count=$((boot_img / 4096)) 2>/dev/null | sha256sum | cut -d' ' -f1)
say "  boot   partition prefix $got_boot"
got_super=$(dd if="$SUPER" bs=1M count=256 2>/dev/null | sha256sum | cut -d' ' -f1)
say "  super  first 256 MiB $got_super"
# The payload's own first 256 MiB and whole-file hash, from the staged copy.
want_super_head=$(dd if="$SRC/$SUPER_IMG" bs=1M count=256 2>/dev/null | sha256sum | cut -d' ' -f1)
[ "$got_super" = "$want_super_head" ] && say "  super  head matches the staged image" || say "  super  head DOES NOT MATCH - do not reboot, push and write again"
tail_nonzero=$(dd if="$SUPER" bs=1M skip=$((super_img / 1048576 - 8)) 2>/dev/null | tr -d '\000' | wc -c)
say "  super  tail beyond $((super_img / 1048576 - 8)) MiB: $tail_nonzero non-zero bytes"

# The wipe is the part that kills adbd: `stop` stops class main and adbd is a class main service, so
# the adb session dies the moment it runs. Either let the script run detached (setsid) so an orphaned
# shell survives adbd's death, or set WIPE=0 and issue the detached command separately.
if [ "${WIPE:-1}" != 1 ]; then
  say "== stopping here: WIPE=0. Next phase, detached so adbd's death cannot abort it: =="
  say "  setsid -f sh -c 'sync; stop; sleep 5; umount /data/sync; umount -l /data; \\
      grep -q \" /data \" /proc/mounts || make_f2fs -f /dev/block/by-name/userdata; \\
      sync; reboot' > /cache/wipe.log 2>&1"
  exit 0
fi

say "== wiping /data (Android 10 encryption must not survive into Android 14) =="
stop
sleep 4
umount /data/sync 2>/dev/null
umount /data 2>/dev/null || umount -l /data 2>/dev/null
if grep -q ' /data ' /proc/mounts; then
  say "ABORT: /data still mounted - do not format a mounted filesystem"
  exit 1
fi
make_f2fs -f "$USERDATA" 2>&1 | tail -6
say "  userdata now: $(blkid "$USERDATA" 2>/dev/null || echo 'blkid unavailable')"
sync
reboot

say "== done: super+boot hold Android 14, /data is a fresh plain f2fs =="
say "reboot now, then deep-power-cycle the unit (the PMIC/capacitors hold state for minutes)."
say "Rollback if it does not boot: bootSD card + diatsia fw/update(1).zip in the card root."
