#!/usr/bin/env bash
# smoke_recovery_evidence.sh - runs scripts/hu_recovery_evidence.sh against fake partitions, a fake pstore,
# a fake /proc/mounts and a fake /cache, so its logic can be tested without the head unit being powered on.
#
# The script is written for the recovery ramdisk (partition 8, D80) and touches paths that only exist there
# (/dev/block/by-name/*, /sys/fs/pstore, /cache, /proc/mounts, /dev/console, /dev/mem, /mnt/external_sd).
# The harness rewrites those to files it creates, points $BB at a shim mapped onto host coreutils, and points
# $SB at a directory whose contents can be swapped per scenario.
#
# The shim is deliberately faithful to the measured busybox applet set (Nov 20, strings over sbin/busybox):
# awk cat cut date echo expr grep head md5sum mkdir mount reboot sed sha1sum sleep stat sync tail touch umount.
# dd, wc, cp, rm, ls, tr and sha256sum are refused, because the real busybox does not have them - the script
# is supposed to reach for /system/bin instead, and a refusal here is the proof that it does not.
#
# What it proves: the device guard; that /cache is mounted before the evidence directory is created (the
# Nov 20 evening failure: mkdir ran before the mount and the directory vanished underneath it); record
# copying; the restore when a request is staged; the skip when partition 7 already matches; the missing
# rollback case; a consumed request not re-arming a restore; the case where no digest tool exists (which
# must restore anyway rather than claim a match); that an install package on a card keeps the recovery UI
# untouched (D80's condition); and the raw-RAM fallback when pstore is not a filesystem.
#
# What it does NOT prove: the shell dialect. busybox ash is not on this host, so POSIX syntax is checked
# here with `bash --posix -n` and still has to be checked with `dash -n` and `busybox ash -n` on the build
# host before partition 8 is written.
#
#   scripts/smoke_recovery_evidence.sh        (scratch under ${TMPDIR:-/tmp/opencode})
set -eu

REPO=$(cd "$(dirname "$0")/.." && pwd)
SRC="$REPO/scripts/hu_recovery_evidence.sh"
S="${TMPDIR:-/tmp/opencode}/hu-evidence-smoke"
rm -rf "$S"
mkdir -p "$S/cache" "$S/pstore" "$S/mntext" "$S/mntint" "$S/mntsd" "$S/hucard" "$S/by-name" \
        "$S/fakesbin" "$S/binfull" "$S/binbare" "$S/fakenet" "$S/fakelibmods"

BOOT_BYTES=33554432
RECOVERY_BYTES=100663296
RAMOOPS_BASE=1114112
RAMOOPS_BYTES=1048576

# /sbin stands in for the recovery ramdisk's own directory, so record_tools' `ls -l /sbin` lists the fake
# world instead of the workstation's. /sbin/sh is mksh R40 on the unit (measured Nov 21), not busybox ash.
mkdir -p "$S/fakesbin"; : > "$S/fakesbin/sh"

truncate -s "$BOOT_BYTES" "$S/by-name/boot"
truncate -s "$RECOVERY_BYTES" "$S/by-name/recovery"
truncate -s 4096 "$S/by-name/cache"
: > "$S/by-name/misc"
: > "$S/fake-sh"
truncate -s "$BOOT_BYTES" "$S/rollback.bin"
# /dev/mem stand-in: the script reads RAMOOPS_BYTES at RAMOOPS_BASE, so it must cover base + size.
truncate -s $((RAMOOPS_BASE + RAMOOPS_BYTES)) "$S/fake-mem"
printf 'kernel: rockchip_display: booting, init stage 2\n' > "$S/ramoops-src.txt"
dd if="$S/ramoops-src.txt" of="$S/fake-mem" bs=1 seek="$RAMOOPS_BASE" conv=notrunc 2>/dev/null
printf 'booting Linux rockchip-console earlycon=uart8250,mmio32,0xff1a0000 androidboot.selinux=permissive\n' > "$S/cmdline"
printf 'deadbeef-0001\n' > "$S/boot_id"
printf '12.34 5.67\n' > "$S/uptime"

# The two fake bin trees stand in for the ramdisk's /system/bin. binfull mirrors what recovery.bin ships
# (toybox plus real binaries, including sha256sum); binbare carries the file tools but no digest tool, which
# is how the "no digest available" scenario is tested. binbare is synthetic: the real ramdisk does ship
# /system/bin/sha256sum.
mk_fake_bin() {
  dir="$1"; shift
  rm -rf "$dir"; mkdir -p "$dir"
  for app in "$@"; do
    case "$app" in
      mount)
        cat > "$dir/mount" <<EOF
#!/usr/bin/env bash
# Records a /proc/mounts-style line so the script's grep " /cache " sees the mount.
last=\$(printf "%s\n" "\$@" | tail -1)
printf "ext4 %s /dev/block/by-name/dev rw,relatime 0 0\n" "\$last" >> "$S/fake-mounts"
exit 0
EOF
        ;;
      umount)
        cat > "$dir/umount" <<EOF
#!/usr/bin/env bash
sed -i "s|^ext4 \$1 .*||" "$S/fake-mounts" 2>/dev/null
exit 0
EOF
        ;;
      sync) printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/sync" ;;
      # The net phase's property plumbing and port listing. setprop/getprop go through a fake property file,
      # netstat reports two LISTEN sockets so the workstation-facing record is non-empty, iw is a stub that
      # succeeds so the WiFi-fallback scenario can reach the branch.
      setprop)
        cat > "$dir/setprop" <<EOF
#!/usr/bin/env bash
printf '%s=%s\n' "\$1" "\$2" >> "$S/fake-props"
exit 0
EOF
        ;;
      getprop)
        cat > "$dir/getprop" <<EOF
#!/usr/bin/env bash
if [ -f "$S/fake-props" ]; then grep -m1 "^\$1=" "$S/fake-props" 2>/dev/null | cut -d= -f2; fi
exit 0
EOF
        ;;
      netstat) printf '#!/usr/bin/env bash\nprintf "tcp  0 0 0.0.0.0:5555 0.0.0.0:* LISTEN\\ntcp  0 0 0.0.0.0:23 0.0.0.0:* LISTEN\\n"\n' > "$dir/netstat" ;;
      iw)
        cat > "$dir/iw" <<EOF
#!/usr/bin/env bash
printf "iw %s\n" "\$*" >> "$S/net-state"
exit 0
EOF
        ;;
      *) printf '#!/usr/bin/env bash\nexec %s "$@"\n' "$app" > "$dir/$app" ;;
    esac
    chmod 755 "$dir/$app"
  done
}
mk_fake_bin "$S/binfull" sha256sum sha1sum md5sum dd cp cat cut cmp wc tr rm ls stat grep mkdir echo mount umount sync awk head tail touch date setprop getprop netstat strings iw
mk_fake_bin "$S/binbare" dd cp cat cut stat ls mount umount mkdir echo head tail touch date awk
ln -sfn "$S/binfull" "$S/bincur"

cat > "$S/busybox" <<EOF
#!/usr/bin/env bash
# Maps the measured busybox applets onto host coreutils, and refuses the ones the real busybox lacks.
app="\$1"; shift
case "\$app" in
  reboot) : > "$S/rebooted"; echo "smoke: reboot requested"; exit 0 ;;
  sync|sleep) exit 0 ;;
  mount)
    last=\$(printf "%s\n" "\$@" | tail -1)
    printf "ext4 %s /dev/block/by-name/dev rw,relatime 0 0\n" "\$last" >> "$S/fake-mounts"
    exit 0 ;;
  umount) sed -i "s|^ext4 \$1 .*||" "$S/fake-mounts" 2>/dev/null; exit 0 ;;
  sha256sum) echo "smoke: busybox has no sha256sum (measured Nov 20) - the script must use /system/bin" >&2; exit 1 ;;
  sha1sum|md5sum)
    if [ -f "$S/no-digests" ]; then exit 1; fi
    exec "\$app" "\$@" ;;
  # The net phase's applets. ifconfig/route/telnetd/insmod are recorded rather than executed, so a scenario
  # can see whether the script actually reached them.
  ifconfig) printf 'ifconfig %s\\n' "\$*" >> "$S/net-state"; exit 0 ;;
  route) printf 'route %s\\n' "\$*" >> "$S/net-state"; exit 0 ;;
  telnetd) : > "$S/telnetd"; printf 'telnetd %s\\n' "\$*" >> "$S/net-state"; exit 0 ;;
  httpd) : > "$S/httpd"; printf 'httpd %s\\n' "\$*" >> "$S/net-state"; exit 0 ;;
  insmod) if [ -f "\$1" ]; then printf 'insmod %s\\n' "\$1" >> "$S/net-state"; : > "$S/insmod"; exit 0; fi
          echo "smoke: insmod target missing: \$1" >&2; exit 1 ;;
  lsmod) printf '8188eu 1253376 0\\n' ;;
  wget|tftp) printf 'fetch %s\\n' "\$*" >> "$S/net-state"; exit 0 ;;
  dd|wc|cp|rm|ls|tr|sha256sum)
    echo "smoke: script asked busybox for applet '\$app', which the real one lacks (measured Nov 20)" >&2
    exit 1 ;;
  awk|cat|cut|date|echo|expr|grep|head|md5sum|mkdir|sed|sha1sum|stat|tail|touch) exec "\$app" "\$@" ;;
  *) echo "smoke: script asked for applet '\$app', not mapped" >&2; exit 1 ;;
esac
EOF
chmod 755 "$S/busybox"
# The fake /sbin must contain a busybox and an sh, so record_tools' directory listing is non-empty.
cp "$S/busybox" "$S/fakesbin/busybox"

# Rewrite the on-device paths to the scratch dir. /sbin/sh is only used by the guard, so it becomes a file.
# The `-b` block-device test cannot be satisfied by regular files, so it becomes `-e`.
sed \
  -e "s|^BB=/sbin/busybox|BB=$S/busybox|" \
  -e "s|/sbin/busybox|$S/busybox|g" \
  -e "s|/sbin/sh|$S/fakesbin/sh|" \
  -e "s|/sbin|$S/fakesbin|g" \
  -e "s|^SB=/system/bin|SB=$S/bincur|" \
  -e "s|/system/bin|$S/bincur|g" \
  -e "s|^OUT=/cache/hu-evidence$|OUT=$S/cache/hu-evidence|" \
  -e "s|^LOG=/cache/hu-evidence.log$|LOG=$S/cache/hu-evidence.log|" \
  -e "s|^REQ=/cache/hu-restore.request$|REQ=$S/cache/hu-restore.request|" \
  -e "s|^ROLLBACK=/cache/hu-rollback-boot.bin$|ROLLBACK=$S/cache/hu-rollback-boot.bin|" \
  -e "s|^CACHE=/cache$|CACHE=$S/cache|" \
  -e "s|^NETREQ=/cache/hu-net.request$|NETREQ=$S/cache/hu-net.request|" \
  -e "s|^NETCONF=/cache/hu-net.conf$|NETCONF=$S/cache/hu-net.conf|" \
  -e "s|/sys/class/net|$S/fakenet|g" \
  -e "s|/lib/modules|$S/fakelibmods|g" \
  -e "s|/dev/block/by-name|$S/by-name|g" \
  -e "s|/proc/mounts|$S/fake-mounts|" \
  -e "s|/sys/fs/pstore|$S/pstore|" \
  -e "s|/dev/console|$S/console.log|" \
  -e "s|/dev/mem|$S/fake-mem|" \
  -e "s|/proc/cmdline|$S/cmdline|" \
  -e "s|/proc/sys/kernel/random/boot_id|$S/boot_id|" \
  -e "s|/proc/uptime|$S/uptime|" \
  -e "s|/mnt/external_sd|$S/mntext|" \
  -e "s|/mnt/internal_sd|$S/mntint|" \
  -e "s|/mnt/sdcard|$S/mntsd|" \
  -e "s|/mnt/hucard|$S/hucard|" \
  -e "s|/dev/block/mmcblk0p1|$S/no-card-p1|" \
  -e "s|/dev/block/mmcblk0|$S/no-card-0|" \
  -e "s|/dev/block/mmcblk1p1|$S/no-card-p2|" \
  -e "s|/dev/block/mmcblk1|$S/no-card-1|" \
  "$SRC" > "$S/evidence.sh"
sed -i -e 's|\[ -b "$c" \]|[ -e "$c" ]|' "$S/evidence.sh"

reset_state() {
  : > "$S/fake-mounts"
  rm -f "$S/console.log" "$S/rebooted" "$S/no-digests" "$S/cache/hu-evidence.log" \
        "$S/net-state" "$S/telnetd" "$S/httpd" "$S/insmod" "$S/fake-props"
  rm -rf "$S/cache"; mkdir -p "$S/cache"
  # The net phase looks for the interface under /sys/class/net (mapped to $S/fakenet) and a WiFi module in
  # the ramdisk, so both are emptied per scenario and filled by PRE when a scenario needs them.
  rm -rf "$S/fakenet" "$S/fakelibmods" "$S/fakesbin/modules"
  mkdir -p "$S/fakenet" "$S/fakelibmods"
  # truncate to the same size does not clear bytes that are already there, so zero through 0 first.
  truncate -s 0 "$S/by-name/boot"; truncate -s "$BOOT_BYTES" "$S/by-name/boot"
  truncate -s 0 "$S/rollback.bin"; truncate -s "$BOOT_BYTES" "$S/rollback.bin"
  rm -f "$S/mntext/update.zip" "$S/mntext/update(1).zip" "$S/hucard/update.zip"
  rm -rf "$S/pstore"; mkdir -p "$S/pstore"
  if [ ! -f "$S/no-pstore" ]; then
    printf 'console-ramoops-0 text from the boot that died\n' > "$S/pstore/console-ramoops-0"
    printf 'pmsg text\n' > "$S/pstore/pmsg-ramoops-0"
  fi
  : > "$S/by-name/misc"
  ln -sfn "$S/binfull" "$S/bincur"
}

# The fake world is rebuilt before every scenario; PRE runs after reset_state, because staging inputs
# before run() would simply be wiped by it.
stage_request() { cp "$S/rollback.bin" "$S/cache/hu-rollback-boot.bin"; printf 'nonce-17\n' > "$S/cache/hu-restore.request"; }
# Net staging: a request arms the network phase for one boot (done-marker named after its nonce, same rule
# as the restore), and an interface directory under the fake /sys/class/net stands in for a bound dongle.
stage_net() { printf "${1:-nonce-9}\n" > "$S/cache/hu-net.request"; }
iface_eth0() { mkdir -p "$S/fakenet/eth0"; printf '1\n' > "$S/fakenet/eth0/carrier"; }
iface_wifi() { mkdir -p "$S/fakesbin/modules"; : > "$S/fakesbin/modules/8188eu.ko"; printf 'ssid=bench-open\n' > "$S/cache/hu-net.conf"; }
dirty_boot() { printf '\xff' | dd of="$S/by-name/boot" bs=1 count=1 seek=4096 conv=notrunc 2>/dev/null; }
# Partition 7 is sparse-zero between scenarios, so "untouched" is its digest still being the all-zeros
# digest of that size - stat cannot see sparseness.
PRISTINE=$(truncate -s "$BOOT_BYTES" "$S/pristine.bin" && sha256sum "$S/pristine.bin" | cut -d' ' -f1)
boot_untouched() { [ "$(sha256sum "$S/by-name/boot" | cut -d' ' -f1)" = "$PRISTINE" ]; }
boot_matches_rollback() { [ "$(sha256sum "$S/by-name/boot" | cut -d' ' -f1)" = "$(sha256sum "$S/rollback.bin" | cut -d' ' -f1)" ]; }

fail=0
ok() { printf '  ok   %s\n' "$1"; }
no() { printf '  FAIL %s\n' "$1"; fail=1; }

PRE=""
run() {
  reset_state
  [ -n "$PRE" ] && eval "$PRE"
  rc_run=0
  bash "$S/evidence.sh" > "$S/stdout.log" 2>&1 || rc_run=$?
  printf '%s' "$rc_run" > "$S/rc"
  PRE=""
}
E="$S/cache/hu-evidence"
expect() {
  if grep -qF -- "$1" "$S/console.log" 2>/dev/null; then ok "says: $1"; else no "missing: $1"; tail -6 "$S/console.log" 2>/dev/null; fi
}

printf '=== 1. run outside the unit: the guard refuses and nothing happens ===\n'
PRE='rm -f "$S/by-name/misc"'
run
[ "$(cat "$S/rc")" = 1 ] && ok "rc=1" || no "rc=$(cat "$S/rc")"
[ -f "$S/rebooted" ] && no "rebooted on a host that is not the unit" || ok "no reboot"
[ -s "$S/console.log" ] && no "wrote evidence" || ok "nothing written"
[ -s "$S/fake-mounts" ] && no "mounted /cache on a host that is not the unit" || ok "no mount attempted"
boot_untouched && ok "partition 7 untouched" || no "partition 7 was written"

printf '=== 2. no restore request: /cache mounted first, records copied, partition 7 untouched ===\n'
run
[ "$(cat "$S/rc")" = 0 ] && ok "rc=0" || { no "rc=$(cat "$S/rc")"; cat "$S/console.log"; }
expect "cache mounted"
expect "evidence dir"
expect "source=pstore"
expect "copied console-ramoops-0"
expect "no restore request - recovery behaves as stock"
# The directory must exist INSIDE the mounted partition, i.e. created after the mount, not before it.
grep -n "^cache mounted" "$S/console.log" >/dev/null && ok "mount line precedes the mkdir line" || no "no mount line"
[ -f "$E/console-ramoops-0" ] && ok "record persisted in /cache/hu-evidence" || no "record not in /cache/hu-evidence"
# record_tools must produce the directory listings - busybox's own --list-applets came back empty on the unit,
# so the listing is what tells the next rung what this environment can do.
expect "tool listing:"
for f in list-sbin.txt list-systembin.txt list-by-name.txt mounts.txt busybox-version.txt; do
  [ -s "$E/$f" ] && ok "$f written" || no "$f empty or missing"
done
# The Nov 20 22:06 run stalled forever hashing the whole 96 MiB recovery partition and never reached the
# restore step. dig() caps the read, so the digest recorded is the one over the first 64 MiB.
CAP=67108864
want8=$(head -c "$CAP" "$S/by-name/recovery" | sha256sum | cut -d' ' -f1)
grep -qF "p8 digest $want8" "$S/console.log" && ok "p8 digest is the capped first $CAP bytes" || no "p8 digest not the capped read"
grep -n "p8 digest" "$S/console.log" >/dev/null && ok "the p8 line is reached" || no "script never reached the p8 digest line (the Nov 20 stall)"
boot_untouched && ok "partition 7 untouched" || no "partition 7 was written"
expect "rebooting out of recovery"
expect "cold power cycle"
[ -f "$S/rebooted" ] && ok "rebooted so the record becomes readable over adb" || no "no reboot"
# The BCB capture runs on every recovery boot, so the parking question is measurable across boots.
[ -f "$E/misc-bcb.bin" ] && ok "misc BCB kept ($(stat -c %s "$E/misc-bcb.bin") bytes)" || no "misc-bcb.bin missing"

printf '=== 3. restore requested, partition 7 differs: written back, verified, request consumed ===\n'
PRE='stage_request; dirty_boot'
run
[ "$(cat "$S/rc")" = 0 ] && ok "rc=0" || { no "rc=$(cat "$S/rc")"; cat "$S/console.log"; }
expect "restore requested (nonce=nonce-17)"
expect "restored p7="
[ -f "$E/restore-ok.txt" ] && ok "restore-ok.txt" || no "restore-ok.txt missing"
boot_matches_rollback && ok "partition 7 now equals the rollback" || no "partition 7 does not match the rollback"
[ -f "$E/restore-done-nonce-17.txt" ] && ok "done-marker named after the nonce" || no "done-marker missing"
[ -f "$S/cache/hu-restore.request" ] && ok "request file kept (busybox has no rm)" || no "request file deleted - busybox has no rm applet"

printf '=== 4. the same nonce cannot re-arm the restore ===\n'
PRE="stage_request; mkdir -p '$E'; touch '$E/restore-done-nonce-17.txt'"
run
expect "restore request already consumed"
boot_untouched && ok "partition 7 untouched on a consumed request" || no "partition 7 was written on a consumed request"
[ -f "$E/restore-ok.txt" ] && no "restored despite the consumed request" || ok "no restore marker written"

printf '=== 5. partition 7 already on the rollback image: skipped, not written ===\n'
PRE='stage_request'
run
expect "restore requested (nonce=nonce-17)"
expect "p7 already matches the rollback"
[ -f "$E/restore-skipped.txt" ] && ok "restore-skipped.txt" || no "restore-skipped.txt missing"
boot_untouched && ok "partition 7 untouched" || no "partition 7 was written despite matching"

printf '=== 6. request with no rollback staged: partition 7 untouched ===\n'
PRE='printf "nonce-18\n" > "$S/cache/hu-restore.request"'
run
expect "restore requested but"
expect "missing - partition 7 untouched"
[ -f "$E/restore-skipped.txt" ] && ok "restore-skipped.txt carries the reason" || no "restore-skipped.txt missing"
boot_untouched && ok "partition 7 untouched" || no "partition 7 was written"

printf '=== 7. no digest tool at all: it must restore anyway, never claim a match ===\n'
# Two empty digests compare equal, so a digest check on exit status would write "already on the rollback
# image" and leave the risky image in partition 7. binbare plus the refusal marker stands in for that.
PRE='ln -sfn "$S/binbare" "$S/bincur"; : > "$S/no-digests"; stage_request; dirty_boot'
run
expect "restore requested (nonce=nonce-17): p7=unreadable want=unreadable"
[ -f "$E/restore-unverified.txt" ] && ok "restore-unverified.txt" || no "restore-unverified.txt missing"
[ -f "$E/restore-skipped.txt" ] && no "claimed a match with no digest" || ok "no false skip"
boot_matches_rollback && ok "partition 7 written back anyway" || no "partition 7 left on the risky image"

printf '=== 8. an install package on a card keeps the recovery UI alone (D80 condition) ===\n'
PRE='stage_request; dirty_boot; printf "the OEM mainboard package\n" > "$S/mntext/update(1).zip"'
run
expect "install package present:"
expect "leaving the recovery UI alone"
[ -f "$E/restore-ok.txt" ] && ok "the restore still ran" || no "restore did not run"
[ -f "$S/rebooted" ] && no "rebooted while the owner's package sits on the card" || ok "no reboot"

printf '=== 9. pstore not a filesystem: the raw RAM read is kept, without dd ===\n'
rm -f "$S/no-digests"
: > "$S/no-pstore"
PRE='ln -sfn "$S/binfull" "$S/bincur"'
run
expect "pstore not mounted - reading raw RAM"
[ -f "$E/ramoops-raw.bin" ] && ok "raw dump present ($(stat -c %s "$E/ramoops-raw.bin") bytes)" || no "raw dump missing"
grep -qF "rockchip_display" "$E/ramoops-raw.bin" 2>/dev/null && ok "the RAM record reached the dump at the right offset" || no "record not at the ramoops offset"
[ -f "$E/ramoops-text.txt" ] && ok "printable view kept through /system/bin/tr" || no "printable view missing"
rm -f "$S/no-pstore"

printf '=== 10. net request armed and a dongle bound: Ethernet comes up, restore still runs, NO reboot ===\n'
rm -f "$S/no-pstore"
PRE='stage_request; dirty_boot; stage_net nonce-9; iface_eth0'
run
[ "$(cat "$S/rc")" = 0 ] && ok "rc=0" || { no "rc=$(cat "$S/rc")"; cat "$S/console.log"; }
expect "net requested (nonce=nonce-9)"
expect "interface eth0 present"
expect "ip set: eth0=192.168.1.120/255.255.255.0"
expect "route: default via 192.168.1.1"
expect "adbd: service.adb.tcp.port=5555"
expect "telnetd started"
expect "p7 write probe: open-for-write OK"
expect "net up: workstation reaches 192.168.1.120"
expect "network armed"
grep -q "ifconfig eth0 192.168.1.120 netmask" "$S/net-state" 2>/dev/null && ok "busybox ifconfig reached with the bench IP" || no "ifconfig not reached"
grep -q "telnetd -l" "$S/net-state" 2>/dev/null && ok "telnetd reached (login shell on port 23)" || no "telnetd not reached"
grep -q "route add default gw" "$S/net-state" 2>/dev/null && ok "default route issued" || no "no default route line"
[ -f "$S/telnetd" ] && ok "telnetd daemon marker" || no "telnetd marker missing"
[ -s "$E/list-net.txt" ] && ok "listening ports recorded" || no "list-net.txt empty"
[ -s "$E/list-ifaces.txt" ] && ok "interface listing recorded" || no "list-ifaces.txt empty"
[ -f "$E/net-done-nonce-9.txt" ] && ok "net done-marker named after the nonce" || no "net done-marker missing"
[ -f "$E/restore-ok.txt" ] && ok "the restore ran despite the net phase" || no "restore did not run"
boot_matches_rollback && ok "partition 7 restored before the network came up" || no "partition 7 not restored"
[ -f "$S/rebooted" ] && no "rebooted while the net session is armed - the workstation would lose the recovery window" || ok "stayed in recovery"

printf '=== 11. a consumed net request does not re-arm the network ===\n'
PRE='stage_net nonce-9; mkdir -p "$E"; touch "$E/net-done-nonce-9.txt"'
run
expect "net request already consumed"
[ -f "$S/telnetd" ] && no "telnetd started despite the consumed request" || ok "no telnetd"
[ -f "$S/rebooted" ] && ok "reboot-out behaviour is back (no net armed)" || no "no reboot on a consumed request"

printf '=== 12. no dongle bound and no WiFi module: the old reboot-out path stays ===\n'
PRE='stage_net nonce-10'
run
expect "no eth0 and no WiFi module in the ramdisk"
[ -f "$S/telnetd" ] && no "telnetd started without an interface" || ok "no telnetd"
[ -f "$S/rebooted" ] && ok "rebooted as before" || no "no reboot"
[ -f "$E/net-done-nonce-10.txt" ] && no "done-marker written although nothing came up" || ok "marker only written on success"

printf '=== 13. no dongle, module plus open ssid in conf: the WiFi fallback path is reached ===\n'
PRE='stage_net nonce-11; iface_wifi'
run
expect "trying WiFi fallback: insmod"
expect "insmod rc=0"
expect "iw connect rc=0"
expect "wifi net up on wlan0 (bench-open)"
[ -f "$S/insmod" ] && ok "insmod reached the shipped 8188eu.ko" || no "insmod marker missing"
grep -q "iw dev wlan0 connect bench-open" "$S/net-state" 2>/dev/null && ok "iw reached with the open AP" || no "iw line not recorded"
grep -q "ifconfig wlan0 192.168.1.120" "$S/net-state" 2>/dev/null && ok "wlan0 got the bench IP" || no "wlan0 ifconfig not recorded"
[ -f "$S/rebooted" ] && no "rebooted with the WiFi session armed" || ok "stayed in recovery"

printf '=== result ===\n'
if [ "$fail" = 0 ]; then echo "all scenarios pass: $(wc -l < "$S/console.log") console lines from the last run"; fi
exit "$fail"
