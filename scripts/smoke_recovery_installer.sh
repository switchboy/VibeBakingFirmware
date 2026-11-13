#!/usr/bin/env bash
# smoke_recovery_installer.sh - runs scripts/hu_recovery_install.sh against a fake card and fake
# eMMC partitions, so its logic can be tested without the head unit being powered on.
#
# The installer is written for the recovery ramdisk's static 32-bit busybox and touches paths that
# only exist there (/proc/partitions, /dev/block/by-name/*, /dev/console, /dev/block/mmcblk2p*,
# /mnt/external_sd, /sbin/make_f2fs.oem). This harness copies the script into a scratch dir and
# rewrites those absolute paths to files it creates, and points $BB at a shim that maps the applets
# the installer calls onto the host's coreutils. The fake card files are sparse files of exactly the
# real payload sizes, so the size checks, the dd writes and the readback hashes behave the same.
#
# Rewriting /dev/console to a file changes one behaviour: a real console appends, a file opened with
# `>` would only keep the last line. The sed chain therefore turns say()'s `>` into `>>`, so the
# harness sees the whole transcript the way the serial console does.
#
# What it proves is the logic: inert without the flag, the manifest's size lines, the digest match
# against whichever applet busybox has, the partition-size refusal, and the readback. It does NOT
# prove the shell dialect - busybox ash is not available here - so POSIX syntax is checked on the
# build host with `dash -n` and `busybox ash -n` before the image is flashed.
#
#   scripts/smoke_recovery_installer.sh            (scratch under ${TMPDIR:-/tmp/opencode})
set -eu

REPO=$(cd "$(dirname "$0")/.." && pwd)
SRC="$REPO/scripts/hu_recovery_install.sh"
S="${TMPDIR:-/tmp/opencode}/hu-installer-smoke"
rm -rf "$S"
mkdir -p "$S/by-name" "$S/card" "$S/hucard"

# Payload sizes measured in docs/findings.md: raw-super.img 3,263,168,512 B, a14-boot-fixed.img
# 32,796,672 B; partitions: super 3,263,168,512 B (3,186,688 KiB), boot 33,554,432 B (32,768 KiB),
# userdata 56,687,104 KiB.
SUPER_BYTES=3263168512
BOOT_BYTES=32796672
SUPER_KIB=$((SUPER_BYTES / 1024))
BOOT_KIB=$((BOOT_BYTES / 1024))
USER_KIB=56687104

truncate -s "$SUPER_BYTES" "$S/card/super-a14.img"
truncate -s "$BOOT_BYTES" "$S/card/boot-a14.img"
truncate -s "$SUPER_BYTES" "$S/mmcblk2p14"
truncate -s 33554432 "$S/mmcblk2p7"
truncate -s $((USER_KIB * 1024)) "$S/mmcblk2p15"
ln -sf "$S/mmcblk2p14" "$S/by-name/super"
ln -sf "$S/mmcblk2p7" "$S/by-name/boot"
ln -sf "$S/mmcblk2p15" "$S/by-name/userdata"

# The fake partitions start empty: "nothing was written" is then measurable as size 0.
reset_devs() {
  truncate -s 0 "$S/mmcblk2p14" "$S/mmcblk2p7"
}
reset_devs

cat > "$S/fake-partitions" <<EOF
maj min    blocks name
 254 0      $USER_KIB mmcblk2
 254 7      $BOOT_KIB mmcblk2p7
 254 14     $SUPER_KIB mmcblk2p14
 254 15     $USER_KIB mmcblk2p15
EOF

cat > "$S/busybox" <<EOF
#!/usr/bin/env bash
# Maps the applets hu-install.sh calls onto host coreutils. Anything the installer should never run
# is refused loudly, which is the point of the shim.
app="\$1"; shift
case "\$app" in
  reboot) echo "smoke: reboot requested"; exit 0 ;;
  sync|umount|sleep) exit 0 ;;
  mount) echo "smoke: mount \$* (never expected: the flag card is already in the list)" >&2; exit 1 ;;
  mkdir|dd|stat|wc|cut|cmp|tail|sha256sum|sha1sum|md5sum) exec "\$app" "\$@" ;;
  *) echo "smoke: installer asked for applet '\$app', not mapped" >&2; exit 1 ;;
esac
EOF
chmod 755 "$S/busybox"

cat > "$S/make_f2fs.oem" <<EOF
#!/usr/bin/env bash
echo "smoke: make_f2fs.oem -f \$1"
exit 0
EOF
chmod 755 "$S/make_f2fs.oem"
touch "$S/linker64"

# Rewrite the on-device paths to the scratch dir. `-b` (block device) becomes `-e` because the fake
# partitions are regular files; busybox, the console and the shell at the end are swapped too.
sed \
  -e "s|/sbin/busybox|$S/busybox|" \
  -e "s|/sbin/make_f2fs.oem|$S/make_f2fs.oem|" \
  -e "s|/sbin/sh|/bin/true|" \
  -e "s|/dev/console|$S/console.log|" \
  -e "s|> $S/console.log|>> $S/console.log|" \
  -e "s|/proc/partitions|$S/fake-partitions|" \
  -e "s|/dev/block/by-name/|$S/by-name/|" \
  -e "s|/dev/block/mmcblk2p14|$S/mmcblk2p14|" \
  -e "s|/dev/block/mmcblk2p7|$S/mmcblk2p7|" \
  -e "s|/dev/block/mmcblk2p15|$S/mmcblk2p15|" \
  -e "s|/dev/block/mmcblk0p1|$S/no-card-p1|" \
  -e "s|/dev/block/mmcblk0|$S/no-card-0|" \
  -e "s|/dev/block/mmcblk1p1|$S/no-card-p2|" \
  -e "s|/dev/block/mmcblk1|$S/no-card-1|" \
  -e "s|/mnt/external_sd|$S/card|" \
  -e "s|/mnt/internal_sd|$S/no-internal|" \
  -e "s|/mnt/sdcard|$S/no-sdcard|" \
  -e "s|/mnt/hucard|$S/hucard|" \
  -e "s|/system/bin/linker64|$S/linker64|" \
  -e 's|\[ -b "\$d" \]|[ -e "\$d" ]|' \
  -e 's|\[ -b "\$c" \]|[ -e "\$c" ]|' \
  "$SRC" > "$S/installer.sh"

manifest_good() {
  local tag="$1"
  : > "$S/card/hu-checksums.txt"
  printf 'size %d %d super-a14.img\n' "$SUPER_BYTES" "$((SUPER_BYTES / 4096))" >> "$S/card/hu-checksums.txt"
  printf 'size %d %d boot-a14.img\n' "$BOOT_BYTES" "$((BOOT_BYTES / 4096))" >> "$S/card/hu-checksums.txt"
  for name in super-a14.img boot-a14.img; do
    printf '%s %s %s\n' "$tag" "$(sha256sum "$S/card/$name" | cut -d' ' -f1)" "$name" >> "$S/card/hu-checksums.txt"
  done
}

# ---------- scenarios ----------
# Every scenario prints what it expects and dies on the first mismatch, so this script is a gate,
# not a demo: rc 0 means the installer's logic matches the contract in docs/decisions.md (D43).
fail=0
ok() { printf '  ok   %s\n' "$1"; }
no() { printf '  FAIL %s\n' "$1"; fail=1; }

run() {
  : > "$S/console.log"
  rm -f "$S/hu-install.log"
  reset_devs          # so "nothing was written" is measurable as size 0 in every scenario
  rc_run=0            # the installer is *supposed* to fail in several scenarios; set -e must not
  bash "$S/installer.sh" > "$S/stdout.log" 2>&1 || rc_run=$?
  printf '%s' "$rc_run" > "$S/rc"
}
expect() {
  local want="$1"
  if grep -qF -- "$want" "$S/console.log"; then ok "says: $want"; else no "missing: $want"; tail -8 "$S/console.log"; fi
}

printf '=== 1. no flag on the card: inert, nothing written ===\n'
rm -f "$S/card/hu-install.flag" "$S/card/hu-checksums.txt"
run
[ "$(cat "$S/rc")" = 0 ] && ok "rc=0" || no "rc=$(cat "$S/rc")"
expect "no hu-install.flag found"
[ -s "$S/mmcblk2p14" ] && no "super was written" || ok "super untouched"

printf '=== 2. good manifest (digest named as the busybox applet) ===\n'
manifest_good sha256sum
touch "$S/card/hu-install.flag"
run
[ "$(cat "$S/rc")" = 0 ] && ok "rc=0" || { no "rc=$(cat "$S/rc")"; cat "$S/console.log"; }
expect "super partition $SUPER_KIB KiB, payload $SUPER_KIB KiB"
expect "ok   super-a14.img"
expect "make_f2fs.oem rc=0"
expect "ok   super readback"
expect "done: boot + super written"

printf '=== 3. the old manifest spelling (sha1, no "sum") is matched to the applet ===\n'
manifest_good sha256
run
[ "$(cat "$S/rc")" = 0 ] && ok "rc=0" || { no "rc=$(cat "$S/rc")"; cat "$S/console.log"; }
expect "ok   super readback"

printf '=== 4. a manifest with no line for the digest we can compute must refuse ===\n'
: > "$S/card/hu-checksums.txt"
printf 'size %d %d super-a14.img\n' "$SUPER_BYTES" "$((SUPER_BYTES / 4096))" >> "$S/card/hu-checksums.txt"
printf 'size %d %d boot-a14.img\n' "$BOOT_BYTES" "$((BOOT_BYTES / 4096))" >> "$S/card/hu-checksums.txt"
printf 'md5sum deadbeef super-a14.img\n' >> "$S/card/hu-checksums.txt"
run
[ "$(cat "$S/rc")" = 1 ] && ok "rc=1" || no "rc=$(cat "$S/rc")"
expect "no sha256sum line in"

printf '=== 5. no size lines: refuse before writing anything ===\n'
: > "$S/card/hu-checksums.txt"
printf 'sha256sum %s super-a14.img\n' "$(sha256sum "$S/card/super-a14.img" | cut -d' ' -f1)" >> "$S/card/hu-checksums.txt"
run
[ "$(cat "$S/rc")" = 1 ] && ok "rc=1" || no "rc=$(cat "$S/rc")"
expect "no size line for super-a14.img"
[ "$(stat -c %s "$S/mmcblk2p14")" = 0 ] && ok "super untouched" || no "super was written"

printf '=== 6. the file on the card does not match the declared size ===\n'
manifest_good sha256sum
# Declare a byte count that is not the real one, keeping the boot size line and the digests.
{ printf 'size %d %d super-a14.img\n' "$((SUPER_BYTES - 4096))" "$((SUPER_BYTES / 4096))"
  grep '^size .* boot-a14.img$' "$S/card/hu-checksums.txt"
  grep -v '^size' "$S/card/hu-checksums.txt"; } > "$S/new-man"
mv "$S/new-man" "$S/card/hu-checksums.txt"
run
[ "$(cat "$S/rc")" = 1 ] && ok "rc=1" || no "rc=$(cat "$S/rc")"
expect "is $SUPER_BYTES B, manifest says"

printf '=== 7. a payload larger than the partition is refused ===\n'
manifest_good sha256sum
cat > "$S/fake-partitions" <<EOF
maj min    blocks name
 254 0      $USER_KIB mmcblk2
 254 7      $BOOT_KIB mmcblk2p7
 254 14     $((SUPER_KIB - 4)) mmcblk2p14
 254 15     $USER_KIB mmcblk2p15
EOF
run
[ "$(cat "$S/rc")" = 1 ] && ok "rc=1" || no "rc=$(cat "$S/rc")"
expect "super payload exceeds partition"

printf '=== 8. a corrupted payload on the card is caught before the write ===\n'
cat > "$S/fake-partitions" <<EOF
maj min    blocks name
 254 0      $USER_KIB mmcblk2
 254 7      $BOOT_KIB mmcblk2p7
 254 14     $SUPER_KIB mmcblk2p14
 254 15     $USER_KIB mmcblk2p15
EOF
manifest_good sha256sum
# Change one byte inside the payload without changing its size, so the digest check is what catches
# it (the size check cannot see it).
printf '\xff' | dd of="$S/card/boot-a14.img" bs=1 count=1 seek=1048576 conv=notrunc 2>/dev/null
run
[ "$(cat "$S/rc")" = 1 ] && ok "rc=1" || no "rc=$(cat "$S/rc")"
expect "FAIL boot-a14.img"

printf '=== result ===\n'
if [ "$fail" = 0 ]; then echo "all scenarios pass: $(wc -l < "$S/console.log") console lines exercised"; fi
exit "$fail"
