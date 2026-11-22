#!/sbin/sh
# hu-net.sh - Ethernet bring-up inside recovery (D84; bring-up order revised Nov 21 night per the owner).
# Gated on /cache/hu-net.request (a nonce, consumed once via a nonce-named done marker), because
# always-on networking would change behaviour on every boot. Never reboots: the recovery window must
# stay open for the workstation.
#
# The bring-up ORDER is what this build changes. The Nov 21 measurements behind it (docs/findings.md):
#  1. the iface node may appear AFTER this service starts - measured begin 1.661 s vs driver register
#     1.699 s - so the node itself is waited for (poll ~0.5 s, log every 10 s, bound = nonce window);
#     issuing ifconfig before the node exists fails with "No such device" and negotiates nothing;
#  2. ax88179 negotiates the PHY only when the interface is OPENED: build v2's boot brought eth0 UP at
#     ~1.71 s and the kernel logged ADDRCONF(NETDEV_UP) at 2.081 s and "ax88179 - Link status is: 1" at
#     5.128 s; build v4 polled carrier before opening anything, got no ADDRCONF at all, counters stayed
#     0/0 and carrier never arrived (class (B)). So the interface is brought UP here, retried every 2 s
#     on failure, with the real exit status logged;
#  3. addressing happens immediately, WITHOUT waiting for carrier: static 192.168.1.127/24 (the address
#     the router MAC-binds to this dongle, D88) plus an eth0:1 alias on 192.168.77.2 and gateway
#     192.168.1.1. Each command is guarded so a stuck applet cannot hold the critical path;
#  4. adbd is RESTARTED, not started, and is likewise not gated on carrier: a TCP listener binds without
#     a link. Stock recovery init.rc has no trigger on service.adb.tcp.port, so a property set plus
#     ctl.start on a running adbd binds nothing (measured: svc=running, tcpport=5555, listen=none).
#     ctl.stop, sleep 2, set the port, ctl.start, then verify /proc/net/tcp (5555 = 0x15B3, state 0A)
#     before claiming success; telnetd starts in the same block;
#  5. carrier is watched AFTERWARDS as diagnostics - ~120 s, logging carrier together with the L2
#     counters every 5 s, so a hot-plugged cable is visible in the log; DHCP stays DIAGNOSTIC ONLY
#     (hu-udhcpc.script logs the offer, never touches eth0) in a background subshell with a watchdog;
#  6. nothing stops early because carrier is missing: the window closes only at its end, and the nonce
#     is consumed exactly once whatever the outcome.
# The log file is best effort (recovery detaches partitions lazily at reboot): kmsg read back through
# pstore after the reboot and the copies on the FAT32 card are the evidence of record.
. /sbin/hu-h-common.sh
cache_ready || { say "net: cache not mounted, giving up"; exit 1; }

nonce=$($SB/cut -d' ' -f1 "$NETREQ" 2>/dev/null)
if [ -z "$nonce" ]; then
  say "net: no request in $NETREQ - not arming"
  exit 0
fi
done_marker="$CACHE/net-done-$nonce.txt"
if [ -f "$done_marker" ]; then
  say "net: nonce $nonce already consumed ($done_marker) - not arming again"
  exit 0
fi
say "net begin nonce=$nonce iface=$IFACE static=$STATICIP/$NETMASK alias=$ALIASIF=$ALIASIP gw=$NETGW adbport=$ADBPORT telnetport=$TELNETPORT order=wait-node-up-address-adbd-carrier dhcp=diagnostic"
nap_probe

# 1. Wait for the interface NODE. Bound to the nonce window so a hot-plugged dongle is caught; the
#    stop flag is honoured here too, and a missing node is reported rather than treated as fatal.
#    The first wait line is logged immediately (lastlog is pre-dated), so "waiting" is always visible.
win=${HOLD_ITERS:-120}
node_limit=${NODE_LIMIT:-$((win * 10))}
start=$($SB/date +%s 2>/dev/null); start=${start:-0}
lastlog=$((start - 10))
node_at=""
while :; do
  now=$($SB/date +%s 2>/dev/null); now=${now:-$start}
  el=$((now - start))
  if [ -e "/sys/class/net/$IFACE" ]; then
    node_at=$(uptime_s)
    say "net: iface $IFACE node present at up=$node_at (t=${el}s)"
    break
  fi
  if [ "$el" -ge "$node_limit" ]; then
    say "net: no iface $IFACE node after ${el}s - continuing anyway (never appeared), no reboot"
    break
  fi
  if [ $((now - lastlog)) -ge 10 ]; then
    say "net: waiting for the iface node $IFACE (t=${el}s) - not present yet"
    lastlog=$now
  fi
  if [ -f "$CACHE/hu-net.stop" ]; then
    say "net: stop flag seen during node wait, tearing down"
    exit 0
  fi
  nap
done

# 2. Open the interface. guarded runs it in a background subshell with a kill watchdog, so a stuck
#    ifconfig cannot hold the critical path; the inner shell writes the REAL exit status into the log.
up_limit=${UP_LIMIT:-30}
up_at=""
u=0
while [ "$u" -lt "$up_limit" ]; do
  guarded 2 "$BB ifconfig $IFACE up; echo \"$($SB/date +%s) net: ifconfig $IFACE up rc=\$?\" >> \"$LOG\""
  st=$(iface_up_state "$IFACE")
  if [ "$st" = 1 ]; then
    up_at=$(uptime_s)
    say "net: ifconfig $IFACE up issued, flags=$st (UP) at up=$up_at (t=${u}s)"
    break
  fi
  say "net: $IFACE not UP yet (flags=${st:-unknown}), retrying in 2 s (t=${u}s)"
  $BB sleep 2
  u=$((u + 2))
done
if [ -z "$up_at" ]; then
  say "net: $IFACE never reported UP within ${up_limit} s - addressing anyway, no reboot"
fi

# 3. Addressing immediately: no carrier needed. Static, alias and route, each guarded and each logged
#    with its exit status.
guarded 2 "$BB ifconfig $IFACE $STATICIP netmask $NETMASK up; echo \"$($SB/date +%s) net: static rc=\$?\" >> \"$LOG\""
guarded 2 "$BB ifconfig $ALIASIF $ALIASIP netmask $NETMASK up; echo \"$($SB/date +%s) net: alias rc=\$?\" >> \"$LOG\""
guarded 2 "$BB route add default gw $NETGW; echo \"$($SB/date +%s) net: route rc=\$?\" >> \"$LOG\""
addr=$(iface_addr "$IFACE")
say "net: address=$addr alias_addr=$(iface_addr "$ALIASIF") carrier=$(carrier_of "$IFACE") flags=$(iface_up_state "$IFACE")"

# 4. TCP adb: restart, not start. Order exactly as measured to be the only shape that binds.
$SB/setprop ctl.stop adbd
say "net: ctl.stop adbd issued"
$BB sleep 2
$SB/setprop service.adb.tcp.port "$ADBPORT"
say "net: service.adb.tcp.port=$($SB/getprop service.adb.tcp.port) ro.adb.secure=$($SB/getprop ro.adb.secure)"

# 4b. Redundant shell in the same block: busybox telnetd. 1.11.1 may or may not take -p, so try the
#     port, then the default, and say which one was used.
telnetport=none
if $BB telnetd -l /sbin/sh -p "$TELNETPORT" 2>>"$LOG"; then
  say "net: telnetd on $TELNETPORT (login /sbin/sh)"
  telnetport=$TELNETPORT
elif $BB telnetd -l /sbin/sh 2>>"$LOG"; then
  say "net: telnetd on default 23 (login /sbin/sh); p rejected by this busybox"
  telnetport=23
else
  say "net: telnetd failed"
fi
$BB sync 2>/dev/null

$SB/setprop ctl.start adbd
say "net: ctl.start adbd issued"

# 5. Verify the listener before claiming success. 5555 decimal is 0x15B3; LISTEN is state 0A.
#    This binds whether or not the cable is carrying traffic, so it is not gated on carrier.
#    Measured Nov 22: adbd binds the TCP port on IPv6, so the entry is in /proc/net/tcp6 (the v5 boot
#    printed NO TCP LISTENER while the workstation was already connected through 5555). Both tables
#    are read now, and the filename is kept in the recorded line so the log says which table answered.
listen_line=none
j=0
while [ "$j" -lt 6 ]; do
  line=$($SB/grep -a -i '15B3' /proc/net/tcp /proc/net/tcp6 2>/dev/null | $SB/grep -a -i ' 0A ' | $SB/head -1)
  if [ -n "$line" ]; then listen_line="$line"; break; fi
  $BB sleep 1
  j=$((j + 1))
done
elapsed=$(uptime_s)
elapsed=${elapsed%%.*}
node_sec=${node_at%%.*}
[ -n "$node_sec" ] || node_sec=0
say "net: adbd svc=$($SB/getprop init.svc.adbd) tcpport=$($SB/getprop service.adb.tcp.port) secure=$($SB/getprop ro.adb.secure)"
say "net: adbd listen line=$listen_line (elapsed from carrier: $((elapsed - node_sec)) s)"
if [ "$listen_line" = none ]; then
  say "net: NO TCP LISTENER - not claiming success; diagnostics follow, no reboot, no retry"
else
  say "net: workstation reaches ${addr:-none}:$ADBPORT (adb) and :$telnetport (telnet); staying in recovery, no reboot"
fi
# the nonce is consumed exactly once, whatever the outcome: this boot already acted on it, and the
# diagnostics below are what decide L2 vs addressing vs adbd.
$SB/touch "$done_marker" 2>/dev/null
$BB sync 2>/dev/null

# 6. Carrier is watched AFTER the critical path, as diagnostics only - never a reason to stop.
#    Every 5 s: carrier together with the five L2 counters, the address and the flags, so a cable
#    plugged in later is visible, and a silent link partner is distinguishable from a slow one.
guarded 4 "$BB ifconfig $IFACE >> \"$LOG\""
guarded 3 "$SB/cat /proc/net/arp >> \"$LOG\""
say "net: l2 before dhcp: $(eth_stats | $SB/tr '\n' ' ')"
if [ -f /sbin/hu-udhcpc.script ]; then
  say "net: dhcp script present at /sbin/hu-udhcpc.script"
else
  say "net: dhcp script MISSING at /sbin/hu-udhcpc.script - not attempting"
fi
dhcp=${DHCP_LIMIT:-60}
if [ -f /sbin/hu-udhcpc.script ]; then
  ( guarded "$dhcp" "$BB udhcpc -i $IFACE -t 5 -r 6 -s /sbin/hu-udhcpc.script 2>>\"$LOG\"" ) >/dev/null 2>&1 &
  say "net: dhcp diagnostic attempt started (background, ${dhcp}s)"
fi

cw=${CARRIER_WATCH:-120}
carrier_at=""
k=0
while [ "$k" -lt "$cw" ]; do
  c=$(carrier_of "$IFACE")
  if [ "$c" = 1 ] && [ -z "$carrier_at" ]; then
    carrier_at=$(uptime_s)
    say "net: carrier up on $IFACE at up=$carrier_at (t=${k}s, $((k - ${u:-0})) s after UP)"
  fi
  say "net: carrier=${c:-none} flags=$(iface_up_state "$IFACE") addr=$(iface_addr "$IFACE") t=${k}s counters=$(eth_stats | $SB/tr '\n' ' ')"
  $BB sleep 5
  k=$((k + 5))
done
if [ -z "$carrier_at" ]; then
  say "net: no carrier on $IFACE after ${cw}s of watching - NOT stopping, window stays open, no reboot"
fi
say "net: l2 after dhcp: $(eth_stats | $SB/tr '\n' ' ')"
guarded 3 "$SB/cat /proc/net/arp >> \"$LOG\""
say "net: address after dhcp=$addr / alias=$(iface_addr "$ALIASIF") (eth0 untouched by the dhcp script)"

# 7. Hold the window for 20 min (120 ticks of 10 s). A NEW nonce in the request file extends it again,
#    so the owner can keep the session open without flashing anything. Tick counts are overridable for
#    offline tests only; the unit always uses the defaults.
hold=${HOLD_ITERS:-120}
cur=$nonce
h=0
while [ "$h" -lt "$hold" ]; do
  fresh=$($SB/cut -d' ' -f1 "$NETREQ" 2>/dev/null)
  if [ -n "$fresh" ] && [ "$fresh" != "$cur" ]; then
    say "net: nonce refreshed ($cur -> $fresh), extending window 20 min"
    $SB/touch "$CACHE/net-done-$fresh.txt" 2>/dev/null
    cur=$fresh
    h=0
  fi
  [ -f "$CACHE/hu-net.stop" ] && { say "net: stop flag seen, tearing down"; break; }
  $BB sleep 10
  h=$((h + 1))
done
say "net: window closed; adbd/telnetd left running (init owns them), iface untouched"
exit 0
