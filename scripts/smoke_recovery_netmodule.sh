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
    # The unit's driver only negotiates the PHY when the interface is OPENED (measured Nov 21: UP ->
    # ADDRCONF(NETDEV_UP) -> \"Link status is: 1\"). So the fake state follows that shape: carrier reads
    # 0 while the iface is closed and only becomes 1 after a SUCCESSFUL up, and flags carry IFF_UP
    # (bit 0) once up succeeds. A query form (one argument) never changes state.
    iface="\$1"
    isup=0
    for a in "\$@"; do [ "\$a" = "up" ] && isup=1; done
    # Paths are expanded when the shim is GENERATED (the shim itself has no $S), runtime values are
    # escaped - that is the shape every other applet branch in this shim uses.
    case "\$iface" in
      eth0|eth0:*)
        # only a node that actually exists can change state; a missing node is the module's own
        # "node never appeared" path, not a shim failure
        if [ "\$isup" = 1 ] && [ -d "$S/fakenet/eth0" ]; then
          if [ -f "$S/up-fail" ]; then
            c=\$(cat "$S/up-calls" 2>/dev/null || echo 0); c=\$((c + 1))
            printf '%s\n' "\$c" > "$S/up-calls"
            [ "\$c" -le 2 ] && exit 1
          fi
          if [ -f "$S/no-carrier" ]; then
            printf '0x103\n' > "$S/fakenet/eth0/flags"
          else
            printf '0x113\n' > "$S/fakenet/eth0/flags"
            printf '1\n' > "$S/fakenet/eth0/carrier"
          fi
        fi
        ;;
    esac
    # an applied address (iface then a dotted quad) is remembered: eth0 keeps the primary address and
    # an eth0:N alias is recorded separately, so a diagnostic script must never move eth0.
    if [ "\$#" -ge 2 ]; then
      case "\$2" in
        [0-9]*.[0-9]*.[0-9]*.[0-9]*)
          case "\$1" in
            *:* ) printf '%s\n' "\$2" > "$S/alias" ;;
            * )   printf '%s\n' "\$2" > "$S/lease" ;;
          esac ;;
      esac
    fi
    # query form: report the applied address (and alias) if there is one, otherwise only the link line
    if [ "\$1" = "-a" ] || [ "\$#" = 1 ]; then
      case "\$1" in
        *:* )
          printf 'eth0:1    Link encap:Ethernet  HWaddr 00:0a:cd:27:a5:b2\n'
          if [ -f "$S/alias" ]; then
            printf '          inet addr:%s  Mask:255.255.255.0 \n' "\$(cat "$S/alias")"
          fi
          exit 0 ;;
      esac
      printf 'eth0      Link encap:Ethernet  HWaddr 00:0a:cd:27:a5:b2  Driver ax88179_178a\n'
      if [ -f "$S/lease" ]; then
        printf '          inet addr:%s  Bcast:192.168.1.255  Mask:255.255.255.0 \n' "\$(cat "$S/lease")"
        printf '          UP BROADCAST RUNNING MULTICAST  MTU:1500  Metric:1\n'
      fi
      if [ -f "$S/alias" ]; then
        printf 'eth0:1    Link encap:Ethernet  HWaddr 00:0a:cd:27:a5:b2\n'
        printf '          inet addr:%s  Mask:255.255.255.0 \n' "\$(cat "$S/alias")"
      fi
      exit 0
    fi
    printf 'eth0      Link encap:Ethernet  HWaddr 00:0a:cd:27:a5:b2  Driver ax88179_178a\n'
    if [ -f "$S/lease" ]; then
      printf '          inet addr:%s  Mask:255.255.255.0 \n' "\$(cat "$S/lease")"
      printf '          UP BROADCAST RUNNING MULTICAST  MTU:1500  Metric:1\n'
    fi
    printf '          RX packets:12 errors:0 dropped:0 overruns:0 frame:0\n'
    printf '          TX packets:9 errors:0 dropped:0 overruns:0 carrier:0\n'
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
# Emulates init's service handling AND adbd's own startup behaviour, measured Nov 21: stock recovery
# init.rc has no trigger on service.adb.tcp.port, so setting the port on a RUNNING adbd binds nothing.
# A TCP listener (0x15B3 = 5555, state 0A) only appears when adbd starts with the port already set.
if [ "\$1" = "ctl.stop" ] && [ "\$2" = "adbd" ]; then
  : > "$S/fake-tcp"; : > "$S/fake-tcp6"
  printf 'init.svc.adbd=stopped\n' >> "$S/fake-props"
fi
if [ "\$1" = "ctl.start" ] && [ "\$2" = "adbd" ]; then
  printf 'init.svc.adbd=running\n' >> "$S/fake-props"
  if grep -q '^service.adb.tcp.port=' "$S/fake-props" 2>/dev/null && [ ! -f "$S/no-listener" ]; then
    printf '   0: 00000000000000000000000000000000:15B3 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 25296 1 0000000000000000 100 0 0 10 0\n' >> "$S/fake-tcp6"
  fi
fi
exit 0
EOF
cat > "$S/sysbin/getprop" <<EOF
#!/usr/bin/env bash
# last write wins, like Android's property service: ctl.stop then ctl.start must read 'running'
if [ -f "$S/fake-props" ]; then grep "^\$1=" "$S/fake-props" 2>/dev/null | tail -1 | cut -d= -f2; fi
exit 0
EOF
chmod 755 "$S/sysbin/setprop" "$S/sysbin/getprop"

# --- fake device files --------------------------------------------------------------------------
printf '%s\n' "fake /dev/block/by-name/cache fake rw 0 0" > "$S/fake-mounts"
printf '1.23 4.56\n' > "$S/fake-uptime"
: > "$S/fake-kmsg"
printf 'Iface\tDestination\tGateway\neth0\t0001A8C0\t00000000\n' > "$S/fake-route"
printf 'IP address       HW type     Flags       HW address            Mask     Device\n192.168.1.1    0x1         0x2         aa:bb:cc:dd:ee:ff     *        eth0\n' > "$S/fake-arp"
: > "$S/fake-tcp"; : > "$S/fake-tcp6"
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
      -e "s|/proc/net/tcp6|$S/fake-tcp6|g" \
      -e "s|/proc/net/tcp|$S/fake-tcp|g" \
      -e "s|/proc/net/arp|$S/fake-arp|g" \
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
  HB_TICKS=${HB:-3} HOLD_ITERS=${HOLD:-2} NODE_LIMIT=${NODE:-12} \
  UP_LIMIT=${UP:-8} CARRIER_WATCH=${CW:-10} \
  DHCP_LIMIT=${DHCP:-8} CARD_ITERS=${CARD:-3} \
    /usr/bin/bash "$S/fakesbin/$cmd" "$@" >/dev/null 2>&1
  echo $? > "$S/rc"
}
reset_state() {
  rm -f "$S/state.net" "$S/state.reboot" "$S/telnetd" "$S/lease" "$S/alias" "$S/dhcp-ok" "$S/no-pport" \
        "$S/no-listener" "$S/no-carrier" "$S/up-fail" "$S/up-calls" "$S/fake-props" "$S/fake-tcp" \
        "$S/fake-tcp6" \
        "$S/cache/hu-mark.log" "$S/cache/net-done-"*.txt \
        "$S/cache/hu-net.stop" "$S/cache/hu-net.request" "$S/cache/misc-head.bin" \
        "$S/cache/state-recovery-"*.txt "$S/cache/pstore-"*/ 2>/dev/null
  rm -rf "$S/cache"; mkdir -p "$S/cache"
  rm -rf "$S/fakenet" "$S/hucard"; mkdir -p "$S/fakenet" "$S/hucard"
  printf 'fake /dev/block/by-name/cache fake rw 0 0\n' > "$S/fake-mounts"
  printf 'IP address       HW type     Flags       HW address            Mask     Device\n192.168.1.1    0x1         0x2         aa:bb:cc:dd:ee:ff     *        eth0\n' > "$S/fake-arp"
  : > "$S/fake-tcp"; : > "$S/fake-tcp6"
}
stage_net() { printf "${1:-nonce-1}\n" > "$S/cache/hu-net.request"; }
# The node exists but the interface is CLOSED, exactly as the unit reports eth0 before the module
# opens it: flags 0x102 (BROADCAST|MULTICAST, no IFF_UP), carrier 0, plus the five L2 counters the
# module samples around the DHCP attempt. Carrier only flips to 1 through the ifconfig shim, which
# models the measured shape: the driver negotiates the PHY only when the interface is opened.
iface_present() {
  mkdir -p "$S/fakenet/eth0/statistics"
  printf '0\n' > "$S/fakenet/eth0/carrier"
  printf '0x102\n' > "$S/fakenet/eth0/flags"
  v=12
  for f in rx_packets tx_packets rx_errors tx_errors rx_dropped; do
    printf '%s\n' "$v" > "$S/fakenet/eth0/statistics/$f"
    v=$((v + 1))
  done
}

printf '=== 1. early service: pstore saved first, misc head read-only ===\n'
reset_state
run hu-early.sh
[ "$(cat "$S/rc")" = 0 ] && ok "rc=0" || { no "rc=$(cat "$S/rc")"; cat "$S/cache/hu-mark.log"; }
expect "early begin"
expect "early pstore copied files=2"
expect "early misc node=$S/by-name/misc"
expect "head size=2048"
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

printf '=== 4. state snapshot: every section present, guarded, copied to the card ===\n'
reset_state; iface_present
run "hu-state.sh 1 $S/cache/state-recovery-5.txt"
[ "$(cat "$S/rc")" = 0 ] && ok "rc=0" || no "rc=$(cat "$S/rc")"
f="$S/cache/state-recovery-5.txt"
[ -s "$f" ] && ok "state file written ($(stat -c %s "$f") B)" || no "state file empty"
grep -q 'ax88179_178a' "$f" && ok "ifconfig section present" || no "ifconfig missing"
grep -q 'eth0' "$f" && ok "route section present" || no "route missing"
grep -q '192.168.1.1' "$f" && ok "arp section present" || no "arp missing"
grep -q 'rx_packets=12' "$f" && ok "l2 counters present" || no "counters missing"
grep -q 'eth0: register' "$f" && ok "dmesg tail present" || no "dmesg missing"
expect "state begin delay=1"
expect "state end out=$f size=$(stat -c %s "$f")"
[ -f "$S/hucard/state-recovery-5.txt" ] && ok "snapshot copied to the card mount" || no "snapshot not copied to card"
expect "state copied to card rc=0"

printf '=== 5. net armed: node wait, OPEN, static LAN address, alias, then the adbd RESTART order ===\n'
reset_state; stage_net nonce-5; iface_present; printf '192.168.77.30\n' > "$S/dhcp-ip"; : > "$S/dhcp-ok"
HOLD=1; DHCP=4
run hu-net.sh
[ "$(cat "$S/rc")" = 0 ] && ok "rc=0" || { no "rc=$(cat "$S/rc")"; cat "$S/cache/hu-mark.log"; }
expect "net begin nonce=nonce-5"
expect "iface eth0 node present"
expect "nap: poll interval"
expect "net: ifconfig eth0 up rc=0"
expect "ifconfig eth0 up issued, flags=1 (UP)"
# The ordering is the whole point of build v5 (class (B) diagnosis): wait for the node, OPEN the
# interface, address, restart adbd. Carrier must never be reported before the interface was opened,
# and it must not gate anything on the critical path.
n_node=$(grep -n -- 'iface eth0 node present' "$S/cache/hu-mark.log" | head -1 | cut -d: -f1)
n_open=$(grep -n -- 'ifconfig eth0 up issued' "$S/cache/hu-mark.log" | head -1 | cut -d: -f1)
n_addr=$(grep -n -- 'net: address=' "$S/cache/hu-mark.log" | head -1 | cut -d: -f1)
n_stop=$(grep -n -- 'ctl.stop adbd issued' "$S/cache/hu-mark.log" | head -1 | cut -d: -f1)
n_car=$(grep -n -- 'carrier=1' "$S/cache/hu-mark.log" | head -1 | cut -d: -f1)
[ -n "$n_node" ] && [ -n "$n_open" ] && [ "$n_node" -lt "$n_open" ] \
  && ok "node wait precedes the open ($n_node < $n_open)" || no "open logged before the node: $n_node/$n_open"
[ -n "$n_open" ] && [ -n "$n_addr" ] && [ "$n_open" -lt "$n_addr" ] \
  && ok "the open precedes addressing ($n_open < $n_addr)" || no "addressed before opening: $n_open/$n_addr"
[ -n "$n_addr" ] && [ -n "$n_stop" ] && [ "$n_addr" -lt "$n_stop" ] \
  && ok "addressing precedes the adbd restart ($n_addr < $n_stop)" || no "adbd restarted before addressing: $n_addr/$n_stop"
[ -n "$n_car" ] && [ -n "$n_open" ] && [ "$n_car" -gt "$n_open" ] \
  && ok "carrier=1 only after the open ($n_open < $n_car)" || no "carrier reported at/before the open: $n_open/$n_car"
expect "carrier up on eth0"
expect "net: static rc=0"
expect "net: alias rc=0"
expect "net: route rc=0"
expect "net: address=192.168.1.127 alias_addr=192.168.77.2"
grep -q 'ifconfig eth0 192.168.1.127 netmask 255.255.255.0 up' "$S/state.net" && ok "static LAN ifconfig issued" || no "static ifconfig missing"
grep -q 'ifconfig eth0:1 192.168.77.2 netmask 255.255.255.0 up' "$S/state.net" && ok "alias ifconfig issued" || no "alias ifconfig missing"
grep -q 'route add default gw 192.168.1.1' "$S/state.net" && ok "default route issued" || no "no route line"
expect "ctl.stop adbd issued"
expect "service.adb.tcp.port=5555"
expect "ctl.start adbd issued"
# the order is the whole point of D87: stop, then the port, then start
st=$(grep -n '^ctl.stop=adbd' "$S/fake-props" | cut -d: -f1)
pt=$(grep -n '^service.adb.tcp.port=5555' "$S/fake-props" | cut -d: -f1)
sa=$(grep -n '^ctl.start=adbd' "$S/fake-props" | cut -d: -f1)
[ -n "$st" ] && [ -n "$pt" ] && [ -n "$sa" ] && [ "$st" -lt "$pt" ] && [ "$pt" -lt "$sa" ] \
  && ok "adbd order is stop -> port -> start (lines $st/$pt/$sa)" || no "adbd order wrong: $st/$pt/$sa"
expect "adbd svc=running"
expect "fake-tcp6:   0: 00000000000000000000000000000000:15B3"
expect "elapsed from carrier"
expect "workstation reaches 192.168.1.127"
expect "telnetd on 2323"
expect "dhcp script present"
expect "l2 before dhcp: rx_packets=12"
expect "dhcp offer observed iface=eth0 ip=192.168.77.30"
expect "l2 after dhcp"
expect "address after dhcp=192.168.1.127"
# the dhcp script must never move eth0: the offered address must not appear in any ifconfig call
grep -q '192.168.77.30' "$S/state.net" && no "dhcp script configured eth0" || ok "dhcp diagnostic left eth0 alone"
[ "$(grep -c 'udhcpc' "$S/state.net" 2>/dev/null)" = 1 ] && ok "dhcp attempted once, in the background" || no "dhcp attempted $(grep -c 'udhcpc' "$S/state.net" 2>/dev/null) times"
grep -q 'udhcpc -i eth0 -t 5 -r 6 -s' "$S/state.net" && ok "udhcpc called with the diagnostic script" || no "udhcpc line wrong"
[ -f "$S/cache/net-done-nonce-5.txt" ] && ok "done marker named after the nonce" || no "done marker missing"
[ -f "$S/state.reboot" ] && no "rebooted while armed" || ok "stayed in recovery"

printf '=== 6. DHCP offers nothing: the static LAN address is already up and still listening ===\n'
reset_state; stage_net nonce-6; iface_present
HOLD=1; DHCP=4
run hu-net.sh
expect "net: address=192.168.1.127 alias_addr=192.168.77.2"
expect "fake-tcp6:   0: 00000000000000000000000000000000:15B3"
expect "l2 after dhcp"
expect "workstation reaches 192.168.1.127"
grep -q 'dhcp offer observed' "$S/cache/hu-mark.log" && no "a lease was claimed with no offer" || ok "no lease claimed"
[ -f "$S/cache/net-done-nonce-6.txt" ] && ok "marker written on the listener path" || no "marker missing"

printf '=== 6b. listener never appears (adbd ignores the port property): says NO TCP LISTENER ===\n'
reset_state; stage_net nonce-6b; iface_present; : > "$S/no-listener"
HOLD=1; DHCP=1
run hu-net.sh
expect "net: adbd listen line=none"
expect "NO TCP LISTENER"
grep -q 'workstation reaches' "$S/cache/hu-mark.log" && no "claimed success without a listener" || ok "success not claimed"
expect "l2 before dhcp"
[ -f "$S/cache/net-done-nonce-6b.txt" ] && ok "nonce consumed once, diagnostics continue" || no "marker missing"
[ -f "$S/state.reboot" ] && no "rebooted after a failed listener" || ok "no reboot, no retry"

printf '=== 7. telnetd without -p support: falls back to the default port ===\n'
reset_state; stage_net nonce-7; iface_present; : > "$S/no-pport"; printf '192.168.77.40\n' > "$S/dhcp-ip"; : > "$S/dhcp-ok"
HOLD=1; DHCP=4
run hu-net.sh
expect "telnetd on default 23"
expect "p rejected by this busybox"
expect "fake-tcp6:   0: 00000000000000000000000000000000:15B3"
[ -f "$S/telnetd" ] && ok "telnetd marker" || no "no telnetd"

printf '=== 8. UP succeeded but carrier never arrives: the critical path still runs ===\n'
reset_state; stage_net nonce-8; iface_present; : > "$S/no-carrier"; HOLD=1; NODE=6; UP=6; CW=10; DHCP=1
run hu-net.sh
[ "$(cat "$S/rc")" = 0 ] && ok "rc=0" || { no "rc=$(cat "$S/rc")"; cat "$S/cache/hu-mark.log"; }
expect "ifconfig eth0 up issued, flags=1 (UP)"
expect "net: static rc=0"
expect "net: route rc=0"
expect "ctl.stop adbd issued"
expect "ctl.start adbd issued"
expect "fake-tcp6:   0: 00000000000000000000000000000000:15B3"
expect "workstation reaches 192.168.1.127"
expect "carrier=0"
expect "no carrier on eth0 after"
expect "NOT stopping, window stays open"
grep -q -- 'carrier up on eth0' "$S/cache/hu-mark.log" && no "claimed a carrier that never came" || ok "no carrier claim"
[ -f "$S/cache/net-done-nonce-8.txt" ] && ok "nonce consumed even with a dark link" || no "marker missing"
[ -f "$S/telnetd" ] && ok "telnetd started despite the dark link" || no "no telnetd"
grep -c -- 'carrier=0' "$S/cache/hu-mark.log" | grep -q '^0$' && no "carrier not sampled" || ok "carrier sampled every tick with the counters"
grep -q -- 'counters=rx_packets' "$S/cache/hu-mark.log" && ok "carrier lines carry the L2 counters" || no "carrier lines lack counters"
[ -f "$S/state.reboot" ] && no "rebooted" || ok "no reboot, no early stop"

printf '=== 8b. the iface node appears late (measured: begin 1.661s, register 1.699s) ===\n'
reset_state; stage_net nonce-8b; HOLD=1; NODE=12; UP=8; CW=10; DHCP=1
( sleep 1.2; mkdir -p "$S/fakenet/eth0/statistics"; printf '0\n' > "$S/fakenet/eth0/carrier" \
    ; printf '0x102\n' > "$S/fakenet/eth0/flags"; printf '12\n' > "$S/fakenet/eth0/statistics/rx_packets" ) &
run hu-net.sh
[ "$(cat "$S/rc")" = 0 ] && ok "rc=0" || { no "rc=$(cat "$S/rc")"; cat "$S/cache/hu-mark.log"; }
expect "waiting for the iface node eth0"
expect "iface eth0 node present"
expect "ifconfig eth0 up issued, flags=1 (UP)"
expect "net: static rc=0"
expect "fake-tcp6:   0: 00000000000000000000000000000000:15B3"
expect "workstation reaches 192.168.1.127"
n_wait=$(grep -n -- 'waiting for the iface node eth0' "$S/cache/hu-mark.log" | head -1 | cut -d: -f1)
n_present=$(grep -n -- 'iface eth0 node present' "$S/cache/hu-mark.log" | head -1 | cut -d: -f1)
[ -n "$n_wait" ] && [ -n "$n_present" ] && [ "$n_wait" -lt "$n_present" ] \
  && ok "the wait logged before the node showed up ($n_wait < $n_present)" || no "no node-wait line: $n_wait/$n_present"
[ -f "$S/cache/net-done-nonce-8b.txt" ] && ok "nonce consumed after the late node" || no "marker missing"
[ -f "$S/state.reboot" ] && no "rebooted" || ok "no reboot"

printf '=== 8c. ifconfig eth0 up fails twice, then succeeds: real exit status logged ===\n'
reset_state; stage_net nonce-8c; iface_present; : > "$S/up-fail"; HOLD=1; NODE=6; UP=8; CW=10; DHCP=1
run hu-net.sh
[ "$(cat "$S/rc")" = 0 ] && ok "rc=0" || { no "rc=$(cat "$S/rc")"; cat "$S/cache/hu-mark.log"; }
[ "$(grep -c -- 'ifconfig eth0 up rc=1' "$S/cache/hu-mark.log")" = 2 ] \
  && ok "two failed opens logged with rc=1" || no "failed-open lines: $(grep -c -- 'ifconfig eth0 up rc=1' "$S/cache/hu-mark.log")"
expect "net: ifconfig eth0 up rc=0"
expect "ifconfig eth0 up issued, flags=1 (UP)"
expect "not UP yet"
expect "retrying in 2 s"
expect "net: static rc=0"
expect "fake-tcp6:   0: 00000000000000000000000000000000:15B3"
expect "workstation reaches 192.168.1.127"
[ -f "$S/cache/net-done-nonce-8c.txt" ] && ok "nonce consumed after the retried open" || no "marker missing"
[ -f "$S/state.reboot" ] && no "rebooted" || ok "no reboot"

printf '=== 8d. the node never appears within the bound: reported, not fatal ===\n'
reset_state; stage_net nonce-8d; HOLD=1; NODE=4; UP=4; CW=5; DHCP=1
run hu-net.sh
[ "$(cat "$S/rc")" = 0 ] && ok "rc=0" || { no "rc=$(cat "$S/rc")"; cat "$S/cache/hu-mark.log"; }
expect "no iface eth0 node after"
expect "continuing anyway"
expect "never reported UP"
expect "ctl.stop adbd issued"
expect "ctl.start adbd issued"
expect "fake-tcp6:   0: 00000000000000000000000000000000:15B3"
expect "NOT stopping, window stays open"
[ -f "$S/state.reboot" ] && no "rebooted" || ok "no reboot, no early stop"

printf '=== 9. consumed nonce: not armed again ===\n'
reset_state; stage_net nonce-9; mkdir -p "$S/cache"; touch "$S/cache/net-done-nonce-9.txt"; iface_present
run hu-net.sh
expect "already consumed"
grep -q 'udhcpc' "$S/state.net" 2>/dev/null && no "dhcp attempted" || ok "no dhcp attempt"

printf '=== 10. no request at all: inert ===\n'
reset_state
run hu-net.sh
expect "no request in"
expect "not arming"

printf '=== 11. nonce refresh extends the window ===\n'
reset_state; stage_net nonce-a; iface_present; printf '192.168.77.50\n' > "$S/dhcp-ip"; : > "$S/dhcp-ok"
HOLD=2
( sleep 0.1; printf 'nonce-b\n' > "$S/cache/hu-net.request" ) &
run hu-net.sh
expect "nonce refreshed (nonce-a -> nonce-b)"
[ -f "$S/cache/net-done-nonce-b.txt" ] && ok "new nonce marked consumed" || no "new nonce marker missing"

printf '=== 12. card channel: UI-mounted card gets repeated copies, own mount not attempted ===\n'
reset_state
printf 'fake %s fake rw 0 0\n' "$S/mntext" >> "$S/fake-mounts"   # the grep pattern is sed-mapped too
HB=1; CARD=2; stage_net nonce-card; run hu-early.sh; run hu-hb.sh; run "hu-state.sh 1 $S/cache/state-recovery-5.txt"
run hu-card.sh
expect "card copied to"
expect "UI-mounted channel"
expect "state end"
[ "$(grep -c 'card copied to' "$S/cache/hu-mark.log" 2>/dev/null)" -ge 2 ] \
  && ok "copied more than once (the card is kept mounted)" || no "copied only once"
[ -f "$S/mntext/hu-mark.log" ] && ok "log copied to card" || no "log not copied"
[ -f "$S/mntext/state-recovery-5.txt" ] && ok "state file copied to card" || no "state file not copied"
[ -f "$S/mntext/misc-head.bin" ] && ok "misc head copied to card" || no "misc head not copied"
[ -f "$S/mntext/hu-net.request" ] && ok "nonce request copied to card" || no "nonce request not copied"
[ -f "$S/mntext/update.zip" ] && no "an install package was created on the card" || ok "no install package written"

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
# D87 invariants in the sources: the adbd restart order, and a DHCP script that never configures.
sed '/^[[:space:]]*#/d' "$REPO/scripts/hu_net.sh" > "$S/net.body" 2>/dev/null
n_stop=$(grep -n 'setprop ctl.stop adbd' "$S/net.body" | head -1 | cut -d: -f1)
n_port=$(grep -n 'setprop service.adb.tcp.port' "$S/net.body" | head -1 | cut -d: -f1)
n_start=$(grep -n 'setprop ctl.start adbd' "$S/net.body" | head -1 | cut -d: -f1)
[ -n "$n_stop" ] && [ -n "$n_port" ] && [ -n "$n_start" ] && [ "$n_stop" -lt "$n_port" ] && [ "$n_port" -lt "$n_start" ] \
  && ok "source restart order is stop -> port -> start ($n_stop/$n_port/$n_start)" || no "source restart order wrong: $n_stop/$n_port/$n_start"
# D89 order in the sources: wait for the node, OPEN it, address, then restart adbd; carrier is
# watched only afterwards and must not be able to stop the module early.
n_wait=$(grep -n -- '-e "/sys/class/net/$IFACE"' "$S/net.body" | head -1 | cut -d: -f1)
n_open=$(grep -n -- '$BB ifconfig $IFACE up;' "$S/net.body" | head -1 | cut -d: -f1)
n_static=$(grep -n -- '$BB ifconfig $IFACE $STATICIP' "$S/net.body" | head -1 | cut -d: -f1)
n_watch=$(grep -n -- 'CARRIER_WATCH' "$S/net.body" | head -1 | cut -d: -f1)
n_hold=$(grep -n -- 'hold=${HOLD_ITERS:-120}' "$S/net.body" | head -1 | cut -d: -f1)
[ -n "$n_wait" ] && [ -n "$n_open" ] && [ -n "$n_static" ] && [ -n "$n_stop" ] \
  && [ "$n_wait" -lt "$n_open" ] && [ "$n_open" -lt "$n_static" ] && [ "$n_static" -lt "$n_stop" ] \
  && ok "source bring-up order is node -> open -> address -> adbd ($n_wait/$n_open/$n_static/$n_stop)" \
  || no "source bring-up order wrong: $n_wait/$n_open/$n_static/$n_stop"
[ -n "$n_stop" ] && [ -n "$n_watch" ] && [ "$n_watch" -gt "$n_start" ] \
  && ok "carrier is watched only after the listener check ($n_start < $n_watch)" \
  || no "carrier watch sits on the critical path: $n_start/$n_watch"
sed -n "$((n_watch + 1)),$((n_hold - 1))p" "$S/net.body" | grep -q 'exit' \
  && no "the carrier watch can stop the module" || ok "carrier watch is diagnostics only - no exit path"
grep -q 'iface_up_state' "$S/net.body" && ok "the open is verified by sysfs flags" || no "no flags check in the net body"
# The v5 boot printed NO TCP LISTENER although adb was already connected: adbd binds 5555 on IPv6.
# The listener check must read both tables, or the module's own success verdict is a false negative.
grep -q '/proc/net/tcp /proc/net/tcp6' "$S/net.body" \
  && ok "the listener check reads ipv4 AND ipv6 tables" || no "listener check reads only /proc/net/tcp"
sed '/^[[:space:]]*#/d' "$REPO/scripts/hu_udhcpc_script.sh" > "$S/dhcp.body" 2>/dev/null
grep -q 'ifconfig\|route add' "$S/dhcp.body" && no "the dhcp script configures an interface" || ok "dhcp script is diagnostic only"
sed '/^[[:space:]]*#/d' "$REPO/scripts/hu_state.sh" > "$S/state.body" 2>/dev/null
grep -q '\$SB/awk\|\$BB timeout' "$S/state.body" "$S/net.body" && no "state/net ask for an applet that does not exist" || ok "state/net use only applets that exist"

printf '=== result ===\n'
if [ "$fails" = 0 ]; then echo "all scenarios pass"; exit 0; fi
echo "$fails assertion(s) failed"; exit 1
