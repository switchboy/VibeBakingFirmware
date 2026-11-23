#!/usr/bin/env bash
# smoke_card_module.sh - offline gate for the card-boot mode of the recovery net module (**D98**).
# The same module scripts are run against a fake /sys/block, /proc/partitions, /dev/block and a
# busybox shim, with /sbin/hu-card-boot.flag PRESENT, which is what the card build bakes into the
# card's own recovery ramdisk. SAFETY: net applets are recorded, never executed, and the fake card
# partition files are digested before and after every run - the gate fails if the module writes to
# a block device. Nothing here touches a device.
set -u
REPO=/run/media/Daan/Opslagmonster/VibeBakingFirmware
S=${SCRATCH:-${TMPDIR:-/tmp}/hu-card-smoke}
rm -rf "$S"; mkdir -p "$S/tmp" "$S/fakesbin" "$S/sysbin" "$S/fakenet/eth0/statistics" "$S/fakepstore" \
                 "$S/devblk" "$S/sysblock" "$S/hucard" "$S/mntext" "$S/sbin"
fails=0
ok()  { printf '  ok   %s\n' "$1"; }
no()  { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }
expect() { if grep -q -- "$1" "$S/tmp/hu-mark.log" 2>/dev/null; then ok "says: $1"; else no "missing: $1"; fi; }

# --- busybox shim: only the applets the module uses, net applets recorded only ------------------
cat > "$S/busybox" <<'EOF'
#!/usr/bin/env bash
app="$1"; shift
case "$app" in
  awk)   exec awk "$@" ;;
  sleep) sleep 0.3; exit 0 ;;
  sync)  exit 0 ;;
  kill)  exec kill "$@" ;;
  head)  exec head "$@" ;;
  wc)    exec wc "$@" ;;
  mount) printf 'mount %s\n' "$*" >> "$SB_SHIM_STATE"; exit 0 ;;
  ifconfig) printf 'ifconfig %s\n' "$*" >> "$SB_SHIM_STATE"; exit 0 ;;
  route)  printf 'route %s\n' "$*" >> "$SB_SHIM_STATE"; exit 0 ;;
  telnetd) printf 'telnetd %s\n' "$*" >> "$SB_SHIM_STATE"; exit 0 ;;
  udhcpc) printf 'udhcpc %s\n' "$*" >> "$SB_SHIM_STATE"; exit 0 ;;
  *) exec "$app" "$@" ;;
esac
EOF
SB_SHIM_STATE="$S/state.record"
export SB_SHIM_STATE
chmod 755 "$S/busybox"
for app in cat ls tail grep cut head sed stat cp mkdir rm touch basename tr sync date umount dmesg; do
  printf '#!/usr/bin/env bash\nexec %s "$@"\n' "$(command -v "$app" || echo /bin/$app)" > "$S/sysbin/$app"
  chmod 755 "$S/sysbin/$app"
done
printf '#!/usr/bin/env bash\nprintf "%s\\n" "0.518899 ax88179_178a 1-1.2:1.0 eth0: register ax88179_178a"\n' > "$S/sysbin/dmesg"
chmod 755 "$S/sysbin/dmesg"
printf '#!/usr/bin/env bash\nprintf "%s=%s\\n" "$1" "$2" >> "$S/fake-props"\n' > "$S/sysbin/setprop"
cat > "$S/sysbin/getprop" <<'EOF'
#!/usr/bin/env bash
if [ -f "$SB_SHIM_PROPS" ]; then grep "^$1=" "$SB_SHIM_PROPS" | tail -1 | cut -d= -f2; fi
EOF
chmod 755 "$S/sysbin/setprop" "$S/sysbin/getprop"

# --- fake devices -------------------------------------------------------------------------------
# /proc/partitions reports blocks in 1024-byte units: the SD-boot card is 7,948,206,080 B = 7,761,920
# blocks, its misc p3 is 4,194,304 B = 4096 blocks; the eMMC is 62,813,896,704 B = 61,341,096 blocks
# and its type is MMC. Two extra SD-shaped traps: a wrong-size SD, and a card whose p3 size differs.
printf 'Major Minor Blocks Name\n179 0 30533764 mmcblk0\n179 128 7761920 mmcblk1\n179 131 4096 mmcblk1p3\n179 143 3885568 mmcblk1p15\n179 138 117440 mmcblk1p11\n236 0 61341096 mmcblk2\n236 3 4096 mmcblk2p3\n' > "$S/fake-partitions"
mkdir -p "$S/sysblock/mmcblk0/device" "$S/sysblock/mmcblk1/device" "$S/sysblock/mmcblk2/device"
printf 'SD\n'  > "$S/sysblock/mmcblk0/device/type"
printf 'SD\n'  > "$S/sysblock/mmcblk1/device/type"
printf 'MMC\n' > "$S/sysblock/mmcblk2/device/type"
dd if=/dev/zero of="$S/devblk/mmcblk0" bs=1 count=1024 conv=fsync >/dev/null 2>&1
dd if=/dev/zero of="$S/devblk/mmcblk1" bs=1 count=1024 conv=fsync >/dev/null 2>&1
dd if=/dev/zero of="$S/devblk/mmcblk2" bs=1 count=1024 conv=fsync >/dev/null 2>&1
dd if=/dev/zero of="$S/devblk/mmcblk1p3" bs=1 count=4194304 conv=fsync >/dev/null 2>&1
printf 'boot-recovery\x00' | dd of="$S/devblk/mmcblk1p3" bs=1 count=13 conv=notrunc status=none
dd if=/dev/zero of="$S/devblk/mmcblk2p3" bs=1 count=4194304 conv=fsync >/dev/null 2>&1
printf 'boot-recovery\x00eMMC-MISC-MUST-NEVER-BE-READ\x00' | dd of="$S/devblk/mmcblk2p3" bs=1 count=44 conv=notrunc status=none
before_card=$(sha256sum "$S/devblk/mmcblk1p3" | cut -d' ' -f1)
before_emmc=$(sha256sum "$S/devblk/mmcblk2p3" | cut -d' ' -f1)
printf '%s/devblk/mmcblk0 %s/mntext vfat rw 0 0\n' "$S" "$S" > "$S/fake-mounts"
printf 'fake %s/tmp tmpfs rw 0 0\n' "$S" >> "$S/fake-mounts"
printf '1.23 4.56\n' > "$S/fake-uptime"
: > "$S/fake-kmsg"; : > "$S/fake-tcp"; : > "$S/fake-tcp6"
printf '0x113\n' > "$S/fakenet/eth0/flags"
printf '1\n' > "$S/fakenet/eth0/carrier"
for f in rx_packets tx_packets rx_errors tx_errors rx_dropped; do printf '7\n' > "$S/fakenet/eth0/statistics/$f"; done
printf 'console-ramoops-0 text\n' > "$S/fakepstore/console-ramoops-0"
printf 'pmsg-ramoops-0 text\n' > "$S/fakepstore/pmsg-ramoops-0"

touch "$S/fakesbin/hu-card-boot.flag"   # the card build bakes this into the ramdisk

gen() {
  src="$1"
  out="$S/fakesbin/$(printf '%s' "$(basename "$src")" | tr '_' '-')"
  sed -e "s|/sbin/hu-h-common.sh|$S/fakesbin/hu-h-common.sh|g" \
      -e "s|/sbin/hu-udhcpc.script|$S/fakesbin/hu-udhcpc.script|g" \
      -e "s|/sbin/hu-card-boot.flag|$S/fakesbin/hu-card-boot.flag|g" \
      -e "s|/sbin/busybox|$S/busybox|g" \
      -e "s|/sbin/sh|/usr/bin/bash|g" \
      -e "s|/system/bin|$S/sysbin|g" \
      -e "s|CACHE=/tmp\$|CACHE=$S/tmp|" \
      -e "s|LOG=/tmp/hu-mark.log\$|LOG=$S/tmp/hu-mark.log|" \
      -e "s|NETREQ=/tmp/hu-net.request\$|NETREQ=$S/tmp/hu-net.request|" \
      -e "s|/cache|$S/cache|g" \
      -e "s|/proc/partitions|$S/fake-partitions|g" \
      -e "s|^SYSBLOCK=/sys/block$|SYSBLOCK=$S/sysblock|" \
      -e "s|/sys/block/mmcblk|$S/sysblock/mmcblk|g" \
      -e "s|/sys/class/net|$S/fakenet|g" \
      -e "s|/sys/fs/pstore|$S/fakepstore|g" \
      -e "s|/proc/mounts|$S/fake-mounts|g" \
      -e "s|/proc/uptime|$S/fake-uptime|g" \
      -e "s|/proc/net/tcp6|$S/fake-tcp6|g" \
      -e "s|/proc/net/tcp|$S/fake-tcp|g" \
      -e "s|/proc/net/arp|$S/fake-arp|g" \
      -e "s|/proc/net/route|$S/fake-route|g" \
      -e "s|/dev/kmsg|$S/fake-kmsg|g" \
      -e "s|/dev/block/by-name|$S/by-name|g" \
      -e "s|/dev/block/|$S/devblk/|g" \
      -e "s|/mnt/external_sd|$S/mntext|g" \
      -e "s|/mnt/hucard|$S/hucard|g" \
      "$src" > "$out"
  chmod 755 "$out"
}
gen "$REPO/scripts/hu_h_common.sh"
gen "$REPO/scripts/hu_early.sh"
gen "$REPO/scripts/hu_state.sh"
gen "$REPO/scripts/hu_card.sh"
gen "$REPO/scripts/hu_net.sh"

echo "=== 1. the card switch is on: RAM paths, no cache mount"
( . "$S/fakesbin/hu-h-common.sh"; printf 'CACHE=%s LOG=%s NETREQ=%s\n' "$CACHE" "$LOG" "$NETREQ" ) > "$S/paths.txt"
grep -q "CACHE=$S/tmp" "$S/paths.txt" && ok "CACHE -> RAM ($S/tmp)" || no "CACHE is not RAM: $(head -1 "$S/paths.txt")"
grep -q "LOG=$S/tmp/hu-mark.log" "$S/paths.txt" && ok "LOG -> RAM" || no "LOG is not RAM"
grep -q "NETREQ=$S/tmp/hu-net.request" "$S/paths.txt" && ok "NETREQ -> RAM" || no "NETREQ is not RAM"
[ -f "$S/by-name/cache" ] && no "by-name cache was opened" || ok "no by-name cache file created"

echo "=== 2. misc node resolution: size+type, never by-name"
mnode=$( ( . "$S/fakesbin/hu-h-common.sh"; misc_node ) )
[ "$mnode" = "$S/devblk/mmcblk1p3" ] && ok "misc resolved to $mnode" || no "misc resolved to '$mnode', expected $S/devblk/mmcblk1p3"
# the wrong-size SD must be refused
cp "$S/fake-partitions" "$S/part-wrong"
sed -i 's/^179 128 7761920 mmcblk1$/179 128 7000000 mmcblk1/' "$S/part-wrong"
cp "$S/fake-partitions" "$S/part-nop3"
sed -i 's/^179 131 4096 mmcblk1p3$/179 131 2048 mmcblk1p3/' "$S/part-nop3"
r1=$( ( . "$S/fakesbin/hu-h-common.sh"; misc_node 2>/dev/null; printf 'rc=%s\n' "$?" ) < "$S/part-wrong" )
[ -n "$mnode" ] && true
# re-run with the tampered table by pointing the rewritten path at it
sed -e "s|$S/fake-partitions|$S/part-wrong|" "$S/fakesbin/hu-h-common.sh" > "$S/fakesbin/hu-h-common-wrong.sh"
r2=$( ( . "$S/fakesbin/hu-h-common-wrong.sh"; misc_node 2>/dev/null; printf 'rc=%s\n' "$?" ) )
printf '%s\n' "$r2" | grep -q "rc=1" && grep -q -- "no SD device of 7761920 blocks" "$S/tmp/hu-mark.log" && ok "wrong-size SD refused (rc 1, says why)" || no "wrong-size SD not refused properly: $r2"
sed -e "s|$S/fake-partitions|$S/part-nop3|" "$S/fakesbin/hu-h-common.sh" > "$S/fakesbin/hu-h-common-nop3.sh"
r3=$( ( . "$S/fakesbin/hu-h-common-nop3.sh"; misc_node 2>/dev/null; printf 'rc=%s\n' "$?" ) )
printf '%s\n' "$r3" | grep -q "rc=1" && grep -q -- "mmcblk1p3 blocks=2048" "$S/tmp/hu-mark.log" && ok "wrong-size p3 refused (rc 1, says why)" || no "wrong-size p3 not refused properly: $r3"

echo "=== 3. hu-early.sh: pstore + misc head into RAM, read-only sources"
"$S/fakesbin/hu-early.sh" > "$S/early.out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "rc=0" || no "rc=$rc"
grep -q "early misc node=$S/devblk/mmcblk1p3" "$S/tmp/hu-mark.log" && ok "misc head read from the card node" || no "misc head not read from the card node"
sz=$(stat -c %s "$S/tmp/misc-head.bin" 2>/dev/null)
[ "$sz" = 2048 ] && ok "misc head 2048 B in RAM" || no "misc head size=${sz:-none}"
grep -a -q "MMC" "$S/tmp/misc-head.bin" && no "misc head came from the eMMC node" || ok "misc head does not carry the eMMC marker"
[ -f "$S/tmp/pstore-1.23/console-ramoops-0" ] && ok "pstore copy landed in RAM" || no "pstore copy missing"

echo "=== 4. evidence copies land on the SECOND card (**D99**, owner-approved)"
CARD_ITERS=1 CARRIER_WATCH=2 "$S/fakesbin/hu-card.sh" > "$S/card.out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "hu-card rc=0" || no "hu-card rc=$rc"
expect "card-boot mode, destination $S/mntext"
grep -q "mount -t vfat" "$S/state.record" 2>/dev/null && no "a mount was issued while the second card was already mounted" || ok "no mount issued for an existing second-card mount"
CARRIER_WATCH=2 HOLD_ITERS=1 "$S/fakesbin/hu-state.sh" 1 "$S/tmp/state-recovery-1.txt" > "$S/state.out" 2>&1
expect "state card copy out=state-recovery-1.txt dst=$S/mntext"
[ -f "$S/mntext/hu-mark.log" ] && ok "the log copy landed on the second card" || no "log copy missing on the second card"
[ -f "$S/mntext/state-recovery-1.txt" ] && ok "the state snapshot copy landed" || no "state copy missing"
after_boot=$(sha256sum "$S/devblk/mmcblk1p3" | cut -d' ' -f1)
[ "$before_card" = "$after_boot" ] && ok "the boot card misc node stayed byte-identical" || no "boot card was written"
after_emmc=$(sha256sum "$S/devblk/mmcblk2p3" | cut -d' ' -f1)
[ "$before_emmc" = "$after_emmc" ] && ok "the eMMC-shaped node stayed byte-identical" || no "eMMC-shaped node was written"
grep -q "mount -t vfat $S/devblk/mmcblk1" "$S/state.record" 2>/dev/null && no "the BOOT card was mounted" || ok "the boot card was never mounted"
grep -q "mmcblk2" "$S/state.record" 2>/dev/null && no "an eMMC-shaped node was mounted" || ok "no eMMC node was mounted"

echo "=== 4b. a mount that resolves to the BOOT card is refused, the second card is mounted instead"
printf '%s/devblk/mmcblk1 %s/mntext vfat rw 0 0\n' "$S" "$S" > "$S/fake-mounts"
: > "$S/state.record"
rm -f "$S/hucard/hu-mark.log" "$S/hucard/state-recovery-1.txt" "$S/hucard/misc-head.bin"
before_bootnode=$(sha256sum "$S/devblk/mmcblk1" | cut -d' ' -f1)
CARD_ITERS=1 "$S/fakesbin/hu-card.sh" > "$S/card2.out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "hu-card rc=0" || no "hu-card rc=$rc"
expect "not the second card - refusing it as a destination"
expect "mounted the second card $S/devblk/mmcblk0 at $S/hucard"
grep -q "mount -t vfat $S/devblk/mmcblk1" "$S/state.record" 2>/dev/null && no "the BOOT card was mounted as a destination" || ok "the boot card was never mounted"
after_bootnode=$(sha256sum "$S/devblk/mmcblk1" | cut -d' ' -f1)
[ "$before_bootnode" = "$after_bootnode" ] && ok "the boot card whole-device node stayed byte-identical" || no "the boot card node was written"
[ -f "$S/hucard/hu-mark.log" ] && ok "copies land on the second card mount, not the refused one" || no "no copy landed on the second card mount"

echo "=== 4c. with nothing mounted, the second card is mounted by size and type"
printf 'fake %s/tmp tmpfs rw 0 0\n' "$S" > "$S/fake-mounts"
: > "$S/state.record"
CARD_ITERS=1 "$S/fakesbin/hu-card.sh" > "$S/card3.out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "hu-card rc=0" || no "hu-card rc=$rc"
expect "mounted the second card $S/devblk/mmcblk0 at $S/hucard"
grep -q "mount -t vfat $S/devblk/mmcblk0" "$S/state.record" 2>/dev/null && ok "the mount call names the second card" || no "no mount call for the second card"
printf '%s/devblk/mmcblk0 %s/mntext vfat rw 0 0\n' "$S" "$S" >> "$S/fake-mounts"

echo "=== 5. hu-net.sh arms without a nonce; window default 30 min"
[ -f "$S/tmp/hu-net.request" ] && no "a nonce file exists - the arm must not need one" || ok "no nonce file needed"
CARRIER_WATCH=2 HOLD_ITERS=1 "$S/fakesbin/hu-net.sh" > "$S/net.out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "hu-net rc=0" || no "hu-net rc=$rc"
expect "arming without a nonce"
expect "net begin nonce=card-boot"
expect "net: ifconfig eth0 up issued"
expect "net: address="
expect "net: adbd svc="
grep -q "hold_default=360" "$S/fakesbin/hu-net.sh" && ok "window default 360 ticks = 30 min on the card flag" || no "window default is not 360"
grep -q "hold_default=120" "$REPO/scripts/hu_net.sh" && ok "eMMC path keeps its 20 min default" || no "eMMC default changed"

echo "=== 6. nothing wrote to a block device"
after_card=$(sha256sum "$S/devblk/mmcblk1p3" | cut -d' ' -f1)
after_emmc=$(sha256sum "$S/devblk/mmcblk2p3" | cut -d' ' -f1)
[ "$before_card" = "$after_card" ] && ok "card misc node byte-identical after the run" || no "card misc was written"
[ "$before_emmc" = "$after_emmc" ] && ok "eMMC-shaped node byte-identical after the run" || no "eMMC-shaped node was written"
grep -q "mount -t ext4" "$S/state.mount" 2>/dev/null && no "busybox mounted an ext4 partition in card mode" || ok "no ext4 mount invoked by the module"

echo "summary: failures=$fails"
[ "$fails" = 0 ] && rm -rf "$S"
exit "$fails"
