#!/sbin/sh
# hu-install.sh - the Android 14 bring-up installer for the Rockchip PX6 head unit, started by the
# patched recovery (see scripts/hu_recovery_init_append.rc).
#
# It is INERT: without hu-install.flag on a card it prints one line and exits 0, so the patched
# recovery behaves exactly like the stock one. With the flag it writes ONLY boot + super (D18/D19:
# never uboot, trust, dtb, dtbo, vbmeta, security, never the GPT) and wipes /data (D10, Android 10
# encrypted it and Android 14 expects plain f2fs here).
#
# Everything it uses comes from the recovery ramdisk: /sbin/sh and /sbin/busybox are statically
# linked 32-bit ARM binaries, so they work before /system is mounted. The one dynamic binary is
# /sbin/make_f2fs.oem - the stock Android 10 mkfs (49,544 B, "for Android 29"), the only make_f2fs
# measured to mount on this 4.19 kernel. Android 14's own make_f2fs (201,496 B, "for Android 34")
# may write f2fs features this kernel cannot mount, so it is deliberately not used. Because
# make_f2fs.oem needs /system/bin/linker64 and /system/lib64, the script waits for /system to be
# mounted (the recovery service mounts it from recovery.fstab) and falls back to a zero-wipe of the
# first MiB of userdata if /system never appears - Android 14's fs_mgr then formats /data itself.
#
# Card layout, all in the card root:
#   hu-install.flag     - makes this script run at all
#   hu-checksums.txt    - digest lines plus the payload sizes, see the manifest block below
#   super-a14.img       - our logical super container (system/vendor/odm/product slices)
#   boot-a14.img        - A10 kernel + Android 14 first-stage ramdisk
#
# Deliberately no awk and no grep: this busybox was measured to carry dd/stat/mount/umount/reboot/
# sleep/wc/cut/sed/ls, but sha256sum and blockdev are absent and awk/grep are not certain applets.
# Arithmetic wraps above 2 GiB in this shell (busybox ash uses a 32-bit long), so a byte count of
# 3,263,168,512 can never be divided here - hence the manifest carries the block count rather than
# the script computing it. Earlier versions derived KiB by dropping the last three decimal digits,
# which divides by 1000, not 1024: raw-super.img would have read as 3,263,168 KiB against a
# partition of 3,186,688 KiB and refused every write.
BB=/sbin/busybox
LOG=/tmp/hu-install.log

say() {
  printf '%s\n' "$1" > /dev/console 2>/dev/null
  printf '%s\n' "$1" >> "$LOG" 2>/dev/null
}
die() { say "hu-install: ABORT - $1"; exit 1; }

# ---------- capability probe ----------
# Which hash applets exist is only knowable at runtime, so probe instead of assuming.
HASH=""
for a in sha256sum sha1sum md5sum; do
  if $BB "$a" /dev/null >/dev/null 2>&1; then HASH="$a"; break; fi
done
CMP=""
if $BB cmp /dev/null /dev/null >/dev/null 2>&1; then CMP=cmp; fi
say "hu-install: hash tool = ${HASH:-none}, cmp = ${CMP:-none}"

# ---------- find the payload card ----------
# Recovery mounts the cards itself (recovery.fstab: mmcblk0p1 -> /mnt/external_sd, the user card
# -> /mnt/internal_sd), so prefer whatever it already mounted and mount our own only if nothing
# carries the flag. The eMMC (mmcblk2) is never a card and is never mounted here.
CARD=""
mkdir -p /mnt/hucard 2>/dev/null
tries=0
while [ "$tries" -lt 30 ]; do
  tries=$((tries + 1))
  for p in /mnt/external_sd /mnt/internal_sd /mnt/sdcard /mnt/hucard; do
    if [ -f "$p/hu-install.flag" ]; then
      CARD="$p"
      break
    fi
  done
  [ -n "$CARD" ] && break
  for c in /dev/block/mmcblk0p1 /dev/block/mmcblk0 /dev/block/mmcblk1p1 /dev/block/mmcblk1; do
    [ -b "$c" ] || continue
    if $BB mount -t vfat -o rw,sync "$c" /mnt/hucard 2>>"$LOG"; then
      if [ -f /mnt/hucard/hu-install.flag ]; then CARD=/mnt/hucard; break; fi
      $BB umount /mnt/hucard 2>/dev/null
    fi
  done
  [ -n "$CARD" ] && break
  $BB sleep 2
done
if [ -z "$CARD" ]; then
  say "hu-install: no hu-install.flag found on any card after ${tries} tries - nothing written"
  exit 0
fi
say "hu-install: flag found in $CARD"

MAN="$CARD/hu-checksums.txt"
SUPER="$CARD/super-a14.img"
BOOTIMG="$CARD/boot-a14.img"
[ -s "$MAN" ] || die "no hu-checksums.txt on the card"
[ -s "$SUPER" ] || die "no super-a14.img on the card"
[ -s "$BOOTIMG" ] || die "no boot-a14.img on the card"

# ---------- the manifest ----------
# Two line types, written by scripts/stage_hu_card.sh:
#   <algo> <hex> <name>          a digest of the payload file; <algo> may be spelled with or
#                                without the trailing "sum" - it is matched to whichever applet
#                                this busybox actually has
#   size <bytes> <blocks> <name> the byte count and the 4096-byte block count of that file
# The block count is what dd and the readback use, and the byte count is checked against `stat`
# as a decimal string, so no arithmetic ever touches a number above 2 GiB.
is_digits() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}
super_bytes=""; super_blocks=""; boot_bytes=""; boot_blocks=""
while read -r tag f1 f2 f3 _rest; do
  [ "$tag" = size ] || continue
  case "$f3" in
    super-a14.img) super_bytes="$f1"; super_blocks="$f2" ;;
    boot-a14.img)  boot_bytes="$f1";  boot_blocks="$f2" ;;
  esac
done < "$MAN"
[ -n "$super_bytes" ] && [ -n "$super_blocks" ] || die "no size line for super-a14.img in $MAN"
[ -n "$boot_bytes" ] && [ -n "$boot_blocks" ] || die "no size line for boot-a14.img in $MAN"
is_digits "$super_blocks" || die "super-a14.img size line has a non-numeric block count"
is_digits "$boot_blocks" || die "boot-a14.img size line has a non-numeric block count"

file_bytes() {
  b=$($BB stat -c %s "$1" 2>/dev/null)
  [ -n "$b" ] || b=$($BB wc -c < "$1" 2>/dev/null)
  printf '%s\n' "${b%% *}"
}
got_super_bytes=$(file_bytes "$SUPER")
got_boot_bytes=$(file_bytes "$BOOTIMG")
[ "$got_super_bytes" = "$super_bytes" ] || die "super-a14.img is $got_super_bytes B, manifest says $super_bytes B - nothing written"
[ "$got_boot_bytes" = "$boot_bytes" ] || die "boot-a14.img is $got_boot_bytes B, manifest says $boot_bytes B - nothing written"

# ---------- targets ----------
# Hard-coded from the measured partition map of this unit (eMMC mmcblk2): boot is partition 7,
# super is partition 14 (3,263,168,512 B), userdata is partition 15. Nothing else is ever written.
# The by-name symlinks must exist, which is the check that the map still matches this unit.
SUPERDEV=/dev/block/mmcblk2p14
BOOTDEV=/dev/block/mmcblk2p7
USERDEV=/dev/block/mmcblk2p15
for n in super boot userdata; do
  [ -L "/dev/block/by-name/$n" ] || die "no by-name/$n - ueventd has not finished, refusing"
done
for d in "$SUPERDEV" "$BOOTDEV" "$USERDEV"; do
  [ -b "$d" ] || die "no $d"
done

# Partition sizes in KiB straight out of /proc/partitions (no blockdev in this busybox).
part_kib() {
  while read -r maj min kib nm; do
    if [ "$nm" = "$1" ]; then printf '%s\n' "$kib"; return; fi
  done < /proc/partitions
}
part_super_kib=$(part_kib mmcblk2p14)
part_boot_kib=$(part_kib mmcblk2p7)
part_user_kib=$(part_kib mmcblk2p15)
[ -n "$part_super_kib" ] || die "mmcblk2p14 not in /proc/partitions"
[ -n "$part_boot_kib" ] || die "mmcblk2p7 not in /proc/partitions"
[ -n "$part_user_kib" ] || die "mmcblk2p15 not in /proc/partitions"

# Payload size in KiB = blocks * 4 KiB. The largest block count here is 796,672 (raw-super.img),
# so 796,672 * 4 = 3,186,688 KiB stays far below the 2 GiB wrap.
super_kib=$((super_blocks * 4))
boot_kib=$((boot_blocks * 4))
say "  super partition $part_super_kib KiB, payload $super_kib KiB ($super_blocks blocks)"
say "  boot  partition $part_boot_kib KiB, payload $boot_kib KiB ($boot_blocks blocks)"
say "  userdata partition $part_user_kib KiB"
[ "$super_kib" -le "$part_super_kib" ] || die "super payload exceeds partition - nothing written"
[ "$boot_kib" -le "$part_boot_kib" ] || die "boot payload exceeds partition - nothing written"
# The 4096-byte alignment is not checkable here without arithmetic above 2 GiB: stage_hu_card.sh
# refuses a payload whose byte count is not a multiple of 4096, and the readback compares the hash
# of exactly $super_blocks / $boot_blocks blocks against the hash of the whole file, so a manifest
# whose block count does not match the file is caught there.

# ---------- verify the payload before touching the unit ----------
if [ -n "$HASH" ]; then
  ok=1
  checked=0
  while read -r algo want name _rest; do
    [ -n "${algo:-}" ] || continue
    [ -n "${want:-}" ] || continue
    # The manifest may name the algo either way; match it to the applet we actually have.
    case "$algo" in
      sha256|sha256sum) a=sha256sum ;;
      sha1|sha1sum) a=sha1sum ;;
      md5|md5sum) a=md5sum ;;
      *) a="$algo" ;;
    esac
    [ "$a" = "$HASH" ] || continue
    case "$name" in
      super-a14.img|boot-a14.img) ;;
      *) continue ;;
    esac
    got=$($BB "$HASH" "$CARD/$name" 2>/dev/null | $BB cut -d' ' -f1)
    checked=$((checked + 1))
    if [ "$got" = "$want" ]; then
      say "  ok   $name  $got"
    else
      say "  FAIL $name  expected $want got ${got:-unreadable}"
      ok=0
    fi
  done < "$MAN"
  # A manifest with no line for the algorithm we can compute would verify nothing, so treat the
  # absence as a failure rather than a silent pass.
  [ "$checked" -gt 0 ] || die "no $HASH line in $MAN - cannot verify the payload, nothing written"
  [ "$ok" = 1 ] || die "card images do not match $HASH in hu-checksums.txt - nothing written"
else
  say "  no hash applet in busybox - payload integrity checked by size + readback only"
fi

# ---------- wipe /data (D10) ----------
# Before the super write: /system is still the stock Android 10 system, so make_f2fs.oem can load
# its linker and libraries. userdata is not part of super, so this cannot corrupt the payload.
say "== wiping /data =="
$BB umount /data/sync 2>/dev/null
$BB umount /data 2>/dev/null
sys_ready=""
tries=0
while [ "$tries" -lt 20 ]; do
  tries=$((tries + 1))
  # /system/bin/linker64 exists only once recovery has mounted the system slice - no grep needed.
  if [ -f /system/bin/linker64 ]; then sys_ready=1; break; fi
  $BB sleep 3
done
if [ -n "$sys_ready" ] && [ -x /sbin/make_f2fs.oem ]; then
  /sbin/make_f2fs.oem -f "$USERDEV" >/tmp/mkfs.out 2>&1
  rc=$?
  $BB tail -6 /tmp/mkfs.out >>"$LOG"
  say "  make_f2fs.oem rc=$rc"
  [ "$rc" = 0 ] || die "make_f2fs.oem failed - /data not formatted"
else
  # No /system to serve the linker: destroy the filesystem header so Android 14's fs_mgr formats
  # /data on first boot (the shipped fstab entry carries formattable). userdata is wiped either way.
  say "  /system not mounted after ${tries} tries - zero-wiping the first MiB of userdata instead"
  $BB dd if=/dev/zero of="$USERDEV" bs=1024 count=1024 conv=fsync 2>>"$LOG" \
    || die "zero-wipe of userdata failed"
fi

# ---------- write ----------
# super first: it is the big write, and a boot write landing on a half-written super is the worse
# failure. A partial super is rolled back with hu-stock-backup/super.bin or the OEM restore zip.
# Recovery still has /system and /vendor mounted (read-only) from the slices inside super, so
# flush anything pending before overwriting the container underneath them.
$BB sync
say "== writing super =="
$BB dd if="$SUPER" of="$SUPERDEV" bs=4096 conv=fsync 2>>"$LOG" || die "dd super failed"
say "== writing boot =="
$BB dd if="$BOOTIMG" of="$BOOTDEV" bs=4096 conv=fsync 2>>"$LOG" || die "dd boot failed"

# ---------- verify the partitions, not just the card files ----------
say "== readback =="
if [ -n "$HASH" ]; then
  want_super=$($BB "$HASH" "$SUPER" | $BB cut -d' ' -f1)
  rb_super=$($BB dd if="$SUPERDEV" bs=4096 count="$super_blocks" 2>/dev/null | $BB "$HASH" | $BB cut -d' ' -f1)
  if [ "$rb_super" = "$want_super" ]; then
    say "  ok   super readback $rb_super"
  else
    die "super readback $rb_super != payload $want_super"
  fi
  want_boot=$($BB "$HASH" "$BOOTIMG" | $BB cut -d' ' -f1)
  rb_boot=$($BB dd if="$BOOTDEV" bs=4096 count="$boot_blocks" 2>/dev/null | $BB "$HASH" | $BB cut -d' ' -f1)
  if [ "$rb_boot" = "$want_boot" ]; then
    say "  ok   boot readback $rb_boot"
  else
    die "boot readback $rb_boot != payload $want_boot"
  fi
elif [ -n "$CMP" ]; then
  # No hash applet: sample the first and last 64 KiB of each write against the payload.
  for pair in "super:$SUPER:$SUPERDEV:$super_blocks" "boot:$BOOTIMG:$BOOTDEV:$boot_blocks"; do
    label=$(printf '%s' "$pair" | $BB cut -d: -f1)
    src=$(printf '%s' "$pair" | $BB cut -d: -f2)
    dst=$(printf '%s' "$pair" | $BB cut -d: -f3)
    blocks=$(printf '%s' "$pair" | $BB cut -d: -f4)
    tail=$((blocks - 16))
    $BB dd if="$dst" bs=4096 count=16 2>/dev/null > /tmp/hu-head
    $BB dd if="$src" bs=4096 count=16 2>/dev/null > /tmp/hu-src-head
    $BB cmp /tmp/hu-head /tmp/hu-src-head >/dev/null 2>&1; hrc=$?
    $BB dd if="$dst" bs=4096 count=16 skip="$tail" 2>/dev/null > /tmp/hu-tail
    $BB dd if="$src" bs=4096 count=16 skip="$tail" 2>/dev/null > /tmp/hu-src-tail
    $BB cmp /tmp/hu-tail /tmp/hu-src-tail >/dev/null 2>&1; trc=$?
    say "  $label head rc=$hrc tail rc=$trc"
    [ "$hrc" = 0 ] && [ "$trc" = 0 ] || die "$label readback mismatch"
  done
else
  say "  no hash tool and no cmp - readback not verified (read /tmp/hu-install.log on the serial console)"
fi

say "== done: boot + super written, /data wiped. Rebooting. =="
$BB sync
$BB reboot
# If reboot somehow returns, keep the console alive so the failure is readable.
say "hu-install: reboot did not take effect - leaving the serial console open"
exec /sbin/sh
