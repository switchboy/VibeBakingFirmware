#!/usr/bin/env bash
# smoke_recovery_netmodule.sh - offline gate for the Step-3 recovery net module (D84/D85).
# Runs the six module scripts against a fake /sys, /proc, /cache, /dev and a busybox shim faithful
# to the measured applet set. SAFETY: ifconfig/route/udhcpc/telnetd/insmod are RECORDED, never
# executed, so a dry-run cannot touch this workstation's interfaces, routes, DHCP or sockets.
# The udhcpc shim actually invokes the shipped lease script, so the lease path is exercised.
#
#   TMPDIR=<scratch> bash scripts/smoke_recovery_netmodule.sh
set -u
REPO=/run/media/Daan/Opslagmonster/VibeBakingFirmware
S=${SCRATCH:-${TMPDIR:-/tmp}/hu-net-smoke}
rm -rf "$S"; mkdir -p "$S/cache" "$S/fakesbin" "$S/sysbin" "$S/fakenet" "$S/fakepstore" \
                 "$S/by-name" "$S/mntext" "$S/devblk"

fails=0
ok()  { printf '  ok   %s\n' "$1"; }
no()  { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }
# `--` matters: patterns like "p rejected" are searched literally, and grep must not read a leading
# dash as an option (the same trap that bit the adb readbacks).
expect() { if grep -q -- "$1" "$S/cache/hu-mark.log" 2>/dev/null; then ok "says: $1"; else no "missing: $1"; fi; }

# --- busybox shim -----------------------------------------------------------------------------
# Mirrors the applet list measured Nov 21 by running the ramdisk's own busybox --help on the unit:
# everything the module needs is present, and the two applets busybox 1.11.1 does NOT have are
# sha256sum and timeout - the shim refuses those, so a script reaching for them fails loudly.
# Net applets (ifconfig/route/udhcpc/telnetd) are RECORDED, never executed, so a dry-run cannot
# touch this workstation's interfaces, routes, DHCP or sockets.
# sleep is shortened to 0.3 s (the unit sleeps 5/10/12 s); that is long enough for a guarded child
# to finish, so the parent's follow-up stat sees the file, exactly as it does on the unit.
cat > "$S/busybox" <<EOF
#!/usr/bin/env bash
app="\$1"; shift
case "\$app" in
  sleep) sleep 0.3; exit 0 ;;
  reboot) echo "REBOOT REQUESTED" >> "$S/state.reboot"; exit 0 ;;
  ifconfig)
    printf 'ifconfig %s\n' "\$*" >> "$S/state.net"
    # an applied address (iface then a dotted quad) is remembered as the interface's address
    if [ "\$#" -ge 2 ]; then
      case "\$2" in
        [0-9]*.[0-9]*.[0-9]*.[0-9]*) printf '%s\n' "\$2" > "$S/lease" ;;
      esac
    fi
    # query form: report the applied address if there is one, otherwise only the link line
    if [ "\$1" = "-a" ] || [ "\$#" = 1 ]; then
      printf 'eth0      Link encap:Ethernet  HWaddr 00:0a:cd:27:a5:b2  Driver ax88179_178a\n'
      if [ -f "$S/lease" ]; then
        printf '          inet addr:%s  Bcast:192.168.77.255  Mask:255.255.255.0 \n' "\$(cat "$S/lease")"
        printf '          UP BROADCAST RUNNING MULTICAST  MTU:1500  Metric:1\n'
      fi
      exit 0
    fi
    exit 0 ;;
  route) printf 'route %s\n' "\$*" >> "$S/state.net"; exit 0 ;;
  telnetd)
    printf 'telnetd %s\n' "\$*" >> "$S/state.net"
    if [ -f "$S/no-pport" ]; then
      for a in "\$@"; do [ "\$a" = "-p" ] && exit 1; done
    fi
    : > "$S/telnetd"; exit 0 ;;
  udhcpc)
    printf 'udhcpc %s\n' "\$*" >> "$S/state.net"
    script=""
    while [ "\$#" -gt 0 ]; do
      case "\$1" in -s) script="\$2"; shift 2 ;; *) shift ;; esac
    done
    if [ -f "$S/dhcp-ok" ] && [ -n "\$script" ]; then
      INTERFACE=eth0 IP=\$(cat "$S/dhcp-ip") NETMASK=255.255.255.0 GATEWAY=192.168.1.1 DNS=192.168.1.1 \\
        /usr/bin/bash "\$script" lease
      exit 0
    fi
    exit 1 ;;
  netstat) cat "$S/fake-tcp" 2>/dev/null; exit 0 ;;
  dmesg) exec "$S/sysbin/dmesg" "\$@" ;;
  mount)
    if [ "\$#" = 0 ]; then cat "$S/fake-mounts" 2>/dev/null; exit 0; fi
    for a in "\$@"; do
      case "\$a" in
        */cache|cache) printf 'fake %s/cache fake rw 0 0\n' "$S" >> "$S/fake-mounts"; exit 0 ;;
        */pstore) exit 0 ;;
        */mntext|*/hucard) : ;;
      esac
    done
    exit 1 ;;
  umount) exit 0 ;;
  kill) exit 0 ;;
  sync) exit 0 ;;
  sha256sum|timeout|iw|insmod|rmmod)
    echo "busybox: applet not found: \$app" >&2; exit 1 ;;
  *) exec "\$app" "\$@" ;;
esac
EOF
chmod 755 "$S/busybox"

# --- /system/bin shim ---------------------------------------------------------------------------
# toybox's measured set includes cat ls tail grep cut head sed stat cp mkdir rm touch basename tr
# umount setprop getprop dmesg - and NOT awk. awk is deliberately absent, so a script that uses it
# fails loudly.
for app in cat ls tail grep cut head sed stat cp mkdir rm touch basename tr sync date umount dmesg; do
  printf '#!/usr/bin/env bash\nexec %s "$@"\n' "$(command -v "$app" || echo /bin/$app)" > "$S/sysbin/$app"
  chmod 755 "$S/sysbin/$app"
done
cat > "$S/sysbin/dmesg" <<EOF
#!/usr/bin/env bash
printf '[    0.518899] ehci-platform fe3c0000.usb: irq 32, io mem 0xfe3c0000\n'
printf '[    1.358644] --mtc ann 1-1.2 0b95\n'
printf '[    1.698310] ax88179_178a 1-1.2:1.0 eth0: register ax88179_178a\n'
exit 0
EOF
chmod 755 "$S/sysbin/dmesg"
cat > "$S/sysbin/setprop" <<EOF
#!/usr/bin/env bash
printf '%s=%s\n' "\$1" "\$2" >> "$S/fake-props"
# emulates adbd coming up and listening when init starts it / a tcp port is set
if [ "\$1" = "ctl.start" ] && [ "\$2" = "adbd" ]; then
  printf '  0: 00000000:15B3 00000000:0000 0A 0000000000000000 0000000000000000 00000001 0 0 1 3 0\n' >> "$S/fake-tcp"
  printf 'adbd=running\n' >> "$S/fake-props"
fi
if [ "\$1" = "service.adb.tcp.port" ]; then printf '  0: 00000000:15B3 00000000:0000 0A 0 0 0 1 0 0 1 3 0\n' >> "$S/fake-tcp"; fi
exit 0
EOF
cat > "$S/sysbin/getprop" <<EOF
#!/usr/bin/env bash
if [ -f "$S/fake-props" ]; then grep -m1 "^\$1=" "$S/fake-props" 2>/dev/null | cut -d= -f2; fi
exit 0
EOF
chmod 755 "$S/sysbin/setprop" "$S/sysbin/getprop"

# --- fake device files --------------------------------------------------------------------------
printf '%s\n' "fake /dev/block/by-name/cache fake rw 0 0" > "$S/fake-mounts"
printf '1.23 4.56\n' > "$S/fake-uptime"
: > "$S/fake-kmsg"
printf 'Iface\tDestination\tGateway\neth0\t0001A8C0\t00000000\n' > "$S/fake-route"
: > "$S/fake-tcp"
dd if=/dev/zero of="$S/by-name/misc" bs=1 count=4096 conv=fsync >/dev/null 2>&1
printf 'boot-recovery\x00' > "$S/by-name/misc.head"
cat "$S/by-name/misc.head" > "$S/by-name/misc"
dd if=/dev/zero of="$S/by-name/misc" bs=1 count=4096 conv=fsync >/dev/null 2>&1
printf 'console-ramoops-0 text\n' > "$S/fakepstore/console-ramoops-0"
printf 'pmsg-ramoops-0 text\n' > "$S/fakepstore/pmsg-ramoops-0"

# --- generate runnable copies of the module scripts ---------------------------------------------
# Names inside the sandbox mirror the ramdisk names (dashes), so the sed-mapped source paths and
# the service invocations line up.
OUTNAME() {
  case "$1" in
    hu_udhcpc_script.sh) printf 'hu-udhcpc.script' ;;
    *) printf '%s' "$1" | tr '_' '-' ;;
  esac
}
gen() {
  src="$1"
  out="$S/fakesbin/$(OUTNAME "$(basename "$src")")"
  sed -e "s|/sbin/hu-h-common.sh|$S/fakesbin/hu-h-common.sh|g" \
      -e "s|/sbin/hu-udhcpc.script|$S/fakesbin/hu-udhcpc.script|g" \
      -e "s|/sbin/hu-early.sh|$S/fakesbin/hu-early.sh|g" \
      -e "s|/sbin/hu-hb.sh|$S/fakesbin/hu-hb.sh|g" \
      -e "s|/sbin/hu-state.sh|$S/fakesbin/hu-state.sh|g" \
      -e "s|/sbin/hu-net.sh|$S/fakesbin/hu-net.sh|g" \
      -e "s|/sbin/hu-card.sh|$S/fakesbin/hu-card.sh|g" \
      -e "s|/sbin/sh|/usr/bin/bash|g" \
      -e "s|/sbin/busybox|$S/busybox|g" \
      -e "s|/system/bin|$S/sysbin|g" \
      -e "s|/cache|$S/cache|g" \
      -e "s|/sys/class/net|$S/fakenet|g" \
      -e "s|/sys/fs/pstore|$S/fakepstore|g" \
      -e "s|/proc/mounts|$S/fake-mounts|g" \
      -e "s|/proc/uptime|$S/fake-uptime|g" \
      -e "s|/proc/net/tcp|$S/fake-tcp|g" \
      -e "s|/proc/net/route|$S/fake-route|g" \
      -e "s|/dev/kmsg|$S/fake-kmsg|g" \
      -e "s|/dev/block/by-name|$S/by-name|g" \
      -e "s|/dev/block/mmcblk|$S/devblk/mmcblk|g" \
      -e "s|/mnt/external_sd|$S/mntext|g" \
      -e "s|/mnt/hucard|$S/hucard|g" \
      "$src" > "$out"
}
for f in hu_h_common hu_early hu_hb hu_state hu_net hu_card hu_udhcpc_script; do
  gen "$REPO/scripts/$f.sh"
done

run() {
  set -- $1
  cmd="$1"; shift
  HB_TICKS=${HB:-3} HOLD_ITERS=${HOLD:-2} POLL_LIMIT=${POLL:-60} \
    /usr/bin/bash "$S/fakesbin/$cmd" "$@" >/dev/null 2>&1
  echo $? > "$S/rc"
}
reset_state() {
  rm -f "$S/state.net" "$S/state.reboot" "$S/telnetd" "$S/lease" "$S/dhcp-ok" "$S/no-pport" \
        "$S/fake-props" "$S/fake-tcp" "$S/cache/hu-mark.log" "$S/cache/net-done-"*.txt \
        "$S/cache/hu-net.stop" "$S/cache/hu-net.request" "$S/cache/misc-head.bin" \
        "$S/cache/state-recovery-"*.txt "$S/cache/pstore-"*/ 2>/dev/null
  rm -rf "$S/cache"; mkdir -p "$S/cache"
  rm -rf "$S/fakenet"; mkdir -p "$S/fakenet"
  printf 'fake /dev/block/by-name/cache fake rw 0 0\n' > "$S/fake-mounts"
  : > "$S/fake-tcp"
}
stage_net() { printf "${1:-nonce-1}\n" > "$S/cache/hu-net.request"; }
iface_up() { mkdir -p "$S/fakenet/eth0"; printf '1\n' > "$S/fakenet/eth0/carrier"; }

printf '=== 1. early service: pstore saved first, misc head read-only ===\n'
reset_state
run hu-early.sh
[ "$(cat "$S/rc")" = 0 ] && ok "rc=0" || { no "rc=$(cat "$S/rc")"; cat "$S/cache/hu-mark.log"; }
expect "early begin"
expect "early pstore copied files=2"
expect "early misc head size=2048"
ls "$S"/cache/pstore-*/console-ramoops-0 >/dev/null 2>&1 && ok "pstore file kept" || no "pstore copy missing"
[ "$(stat -c %s "$S/cache/misc-head.bin")" = 2048 ] && ok "misc head is exactly 2048 B" || no "misc head wrong size"
[ -f "$S/state.reboot" ] && no "rebooted" || ok "no reboot requested"

printf '=== 2. heartbeat: alive lines, then window complete ===\n'
reset_state; HB=3
run hu-hb.sh
[ "$(cat "$S/rc")" = 0 ] && ok "rc=0" || no "rc=$(cat "$S/rc")"
[ "$(grep -c 'alive up=' "$S/cache/hu-mark.log" 2>/dev/null)" = 3 ] \
  && ok "three alive lines (ticks honoured)" || no "alive lines: $(grep -c 'alive up=' "$S/cache/hu-mark.log" 2>/dev/null)"
expect "heartbeat: window complete"

printf '=== 3. heartbeat honours the stop flag ===\n'
reset_state; HB=5; touch "$S/cache/hu-net.stop"
run hu-hb.sh
expect "stop flag seen"
[ "$(grep -c 'alive up=' "$S/cache/hu-mark.log" 2>/dev/null)" = 1 ] && ok "stopped after first tick" || no "did not stop early"

printf '=== 4. state snapshot: every section present, guarded ===\n'
reset_state; iface_up
run "hu-state.sh 1 $S/cache/state-recovery-5.txt"
[ "$(cat "$S/rc")" = 0 ] && ok "rc=0" || no "rc=$(cat "$S/rc")"
f="$S/cache/state-recovery-5.txt"
[ -s "$f" ] && ok "state file written ($(stat -c %s "$f") B)" || no "state file empty"
grep -q 'ax88179_178a' "$f" && ok "ifconfig section present" || no "ifconfig missing"
grep -q 'eth0' "$f" && ok "route section present" || no "route missing"
grep -q 'eth0: register' "$f" && ok "dmesg tail present" || no "dmesg missing"
expect "state begin delay=1"
expect "state end"

printf '=== 5. net armed + iface present + DHCP success: lease, adbd, telnetd, marker ===\n'
reset_state; stage_net nonce-5; iface_up; printf '192.168.77.30\n' > "$S/dhcp-ip"; : > "$S/dhcp-ok"
HOLD=1
run hu-net.sh
[ "$(cat "$S/rc")" = 0 ] && ok "rc=0" || { no "rc=$(cat "$S/rc")"; cat "$S/cache/hu-mark.log"; }
expect "net begin nonce=nonce-5"
expect "iface eth0 present"
expect "dhcp lease applied iface=eth0 ip=192.168.77.30"
expect "route rc=0 gw=192.168.1.1"
expect "net: address=192.168.77.30"
expect "adbd svc="
expect "net: adbd listen line="
expect "telnetd on"
expect "workstation reaches 192.168.77.30"
grep -q 'udhcpc -i eth0 -n -q -t 5 -s' "$S/state.net" && ok "udhcpc called with the shipped script" || no "udhcpc line wrong"
grep -q 'route add default gw 192.168.1.1' "$S/state.net" && ok "default route issued" || no "no route line"
[ -f "$S/cache/net-done-nonce-5.txt" ] && ok "done marker named after the nonce" || no "done marker missing"
[ -f "$S/state.reboot" ] && no "rebooted while armed" || ok "stayed in recovery"

printf '=== 6. DHCP fails: static fallback, still listening ===\n'
reset_state; stage_net nonce-6; iface_up
HOLD=1
run hu-net.sh
expect "no DHCP address - falling back to static 192.168.77.2"
expect "net: address=192.168.77.2"
grep -q 'ifconfig eth0 192.168.77.2 netmask 255.255.255.0 up' "$S/state.net" && ok "static ifconfig issued" || no "static ifconfig missing"
expect "workstation reaches 192.168.77.2"
[ -f "$S/cache/net-done-nonce-6.txt" ] && ok "marker only on success path" || no "marker missing"

printf '=== 7. telnetd without -p support: falls back to the default port ===\n'
reset_state; stage_net nonce-7; iface_up; : > "$S/no-pport"; printf '192.168.77.40\n' > "$S/dhcp-ip"; : > "$S/dhcp-ok"
HOLD=1
run hu-net.sh
expect "telnetd on default 23"
expect "p rejected by this busybox"
[ -f "$S/telnetd" ] && ok "telnetd marker" || no "no telnetd"

printf '=== 8. no interface after the poll limit: stops, no reboot, no marker ===\n'
reset_state; stage_net nonce-8; HOLD=1; POLL=10
run hu-net.sh
expect "never appeared after"
expect "no reboot"
[ -f "$S/cache/net-done-nonce-8.txt" ] && no "marker written although nothing came up" || ok "marker only on success"
[ -f "$S/telnetd" ] && no "telnetd started without an interface" || ok "no telnetd"
[ -f "$S/state.reboot" ] && no "rebooted" || ok "old reboot-out path not reintroduced"

printf '=== 9. consumed nonce: not armed again ===\n'
reset_state; stage_net nonce-9; mkdir -p "$S/cache"; touch "$S/cache/net-done-nonce-9.txt"; iface_up
run hu-net.sh
expect "already consumed"
grep -q 'udhcpc' "$S/state.net" 2>/dev/null && no "dhcp attempted" || ok "no dhcp attempt"

printf '=== 10. no request at all: inert ===\n'
reset_state
run hu-net.sh
expect "no request in"
expect "not arming"

printf '=== 11. nonce refresh extends the window ===\n'
reset_state; stage_net nonce-a; iface_up; printf '192.168.77.50\n' > "$S/dhcp-ip"; : > "$S/dhcp-ok"
HOLD=2
( sleep 0.1; printf 'nonce-b\n' > "$S/cache/hu-net.request" ) &
run hu-net.sh
expect "nonce refreshed (nonce-a -> nonce-b)"
[ -f "$S/cache/net-done-nonce-b.txt" ] && ok "new nonce marked consumed" || no "new nonce marker missing"

printf '=== 12. card channel: UI-mounted card gets copies, own mount is not attempted ===\n'
reset_state
printf 'fake %s fake rw 0 0\n' "$S/mntext" >> "$S/fake-mounts"   # the grep pattern is sed-mapped too
HB=1; run hu-early.sh; run hu-hb.sh; run "hu-state.sh 1 $S/cache/state-recovery-5.txt"
run hu-card.sh
expect "card copied to"
expect "UI-mounted channel"
expect "state end"
[ -f "$S/mntext/hu-mark.log" ] && ok "log copied to card" || no "log not copied"
[ -f "$S/mntext/state-recovery-5.txt" ] && ok "state file copied to card" || no "state file not copied"
[ -f "$S/mntext/misc-head.bin" ] && ok "misc head copied to card" || no "misc head not copied"

printf '=== 13. card channel: no card present -> channel unused ===\n'
reset_state
run hu-card.sh
expect "no mountable FAT32 card"

printf '=== 14. tool-side audit of the sources: no applet this busybox lacks is reached through busybox ===\n'
# Comments are stripped first: the header comments NAME the missing applets on purpose, and the
# unrelated first-stage harness must not be counted as part of this module.
MODS="$REPO/scripts/hu_h_common.sh $REPO/scripts/hu_early.sh $REPO/scripts/hu_hb.sh $REPO/scripts/hu_state.sh $REPO/scripts/hu_net.sh $REPO/scripts/hu_card.sh $REPO/scripts/hu_udhcpc_script.sh"
bad=0
sed '/^[[:space:]]*#/d' $MODS > "$S/audit.body" 2>/dev/null
# The only applets this busybox genuinely lacks are sha256sum and timeout; toybox's gap is awk.
for a in sha256sum timeout; do
  if grep -q "\$BB $a" "$S/audit.body"; then no "module asks busybox for $a"; bad=$((bad + 1)); fi
done
grep -q "\$SB/awk" "$S/audit.body" && { no "module asks toybox for awk"; bad=$((bad + 1)); }
# The call-shape trap: a toybox call must be $SB/applet, never "$SB applet" (that execs the directory).
if grep -q "\$SB [^/]" "$S/audit.body"; then no "toybox call written as \$SB <applet>, which execs the directory"; bad=$((bad + 1)); fi
[ "$bad" = 0 ] && ok "every tool call is on the side that actually has it"
# safety invariants over the module bodies: no digest, no dd, no reboot command
grep -q 'sha256sum\|md5sum' "$S/audit.body" && no "on-device digest present" || ok "no on-device digest"
grep -q 'dd if=/dev/block' "$S/audit.body" && no "dd of a block device present" || ok "no dd of a block device"
grep -q '\$BB reboot\|/sbin/reboot\|ctl.start reboot' "$S/audit.body" && no "reboot command in the module" || ok "no reboot path in the module"
grep -q 'hu_evidence' "$REPO/scripts/hu_net_module_append.rc" && no "retired evidence service referenced" || ok "retired evidence script not referenced"

printf '=== result ===\n'
if [ "$fails" = 0 ]; then echo "all scenarios pass"; exit 0; fi
echo "$fails assertion(s) failed"; exit 1
