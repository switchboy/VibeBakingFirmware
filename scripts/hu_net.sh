#!/sbin/sh
# hu-net.sh - Ethernet bring-up inside recovery (D84, order revised Nov 21 evening per the owner).
# Gated on /cache/hu-net.request (a nonce, consumed once via a nonce-named done marker), because
# always-on networking would change behaviour on every boot. Never reboots: the recovery window must
# stay open for the workstation.
#
# Measured Nov 21 evening, and the order follows those measurements:
#  - the interface NODE exists at 1.70 s but carrier only arrives when the driver logs
#    "ax88179 - Link status is: 1" at 5.13 s, so this polls carrier, not the node;
#  - addressing is applied immediately after carrier: static 192.168.1.250/24 on the LAN subnet plus
#    an eth0:1 alias on 192.168.77.2, gateway 192.168.1.1 - the LAN address is reachable from the
#    workstation without any privileged workstation-side change;
#  - adbd is RESTARTED, not started: stock recovery init.rc has no trigger on service.adb.tcp.port,
#    so a property set plus ctl.start on a running adbd binds nothing (measured: svc=running,
#    tcpport=5555, listen line=none). ctl.stop, sleep 2, set the port, ctl.start, then verify the
#    listener in /proc/net/tcp (5555 = 0x15B3, state 0A) before claiming success;
#  - telnetd starts in the same block, and all of this happens within ~15 s of carrier;
#  - DHCP is DIAGNOSTIC ONLY. hu-udhcpc.script logs the offered IP/router and never touches eth0, and
#    the attempt runs in a background subshell for ~60 s so it cannot hold the window or steal the
#    static address. RX/TX counters are sampled before and after it.
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
say "net begin nonce=$nonce iface=$IFACE static=$STATICIP/$NETMASK alias=$ALIASIF=$ALIASIP gw=$NETGW adbport=$ADBPORT telnetport=$TELNETPORT dhcp=diagnostic"

# 1. Wait for CARRIER, logging every 5 s so a silent failure is distinguishable from a slow one.
poll=${POLL_LIMIT:-60}
i=0
carrier_at=""
while [ "$i" -lt "$poll" ]; do
  c=$(carrier_of "$IFACE")
  if [ "$c" = 1 ]; then
    carrier_at=$(uptime_s)
    say "net: carrier up on $IFACE at up=$carrier_at (t=${i}s)"
    break
  fi
  guarded 4 "$SB/ls -l /sys/class/net >> \"$LOG\""
  say "net: waiting for carrier on $IFACE (t=${i}s) carrier=${c:-none}"
  $BB sleep 5
  i=$((i + 5))
done
if [ -z "$carrier_at" ]; then
  say "net: no carrier on $IFACE after ${poll} s - stopping, no reboot"
  exit 0
fi

# 2. Addressing immediately, before anything else. Each command is guarded so a stuck applet cannot
#    hold the critical path; the inner shell reports the real rc into the log.
guarded 2 "$BB ifconfig $IFACE $STATICIP netmask $NETMASK up; echo \"$($SB/date +%s) net: static rc=\$?\" >> \"$LOG\""
guarded 2 "$BB ifconfig $ALIASIF $ALIASIP netmask $NETMASK up; echo \"$($SB/date +%s) net: alias rc=\$?\" >> \"$LOG\""
guarded 2 "$BB route add default gw $NETGW; echo \"$($SB/date +%s) net: route rc=\$?\" >> \"$LOG\""
addr=$(iface_addr "$IFACE")
say "net: address=$addr alias_addr=$(iface_addr "$ALIASIF")"

# 3. TCP adb: restart, not start. Order exactly as measured to be the only shape that binds.
$SB/setprop ctl.stop adbd
say "net: ctl.stop adbd issued"
$BB sleep 2
$SB/setprop service.adb.tcp.port "$ADBPORT"
say "net: service.adb.tcp.port=$($SB/getprop service.adb.tcp.port) ro.adb.secure=$($SB/getprop ro.adb.secure)"

# 4. Redundant shell in the same block: busybox telnetd. 1.11.1 may or may not take -p, so try the
#    port, then the default, and say which one was used.
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
listen_line=none
j=0
while [ "$j" -lt 6 ]; do
  line=$($SB/grep -a -i '15B3' /proc/net/tcp 2>/dev/null | $SB/grep -a -i ' 0A ' | $SB/head -1)
  if [ -n "$line" ]; then listen_line="$line"; break; fi
  $BB sleep 1
  j=$((j + 1))
done
elapsed=$(uptime_s)
elapsed=${elapsed%%.*}
carrier_sec=${carrier_at%%.*}
say "net: adbd svc=$($SB/getprop init.svc.adbd) tcpport=$($SB/getprop service.adb.tcp.port) secure=$($SB/getprop ro.adb.secure)"
say "net: adbd listen line=$listen_line (elapsed from carrier: $((elapsed - carrier_sec)) s)"
if [ "$listen_line" = none ]; then
  say "net: NO TCP LISTENER - not claiming success; diagnostics follow, no reboot, no retry"
else
  say "net: workstation reaches ${addr:-none}:$ADBPORT (adb) and :$telnetport (telnet); staying in recovery, no reboot"
fi
# the nonce is consumed exactly once, whatever the outcome: this boot already acted on it, and the
# diagnostics below are what decide L2 vs addressing vs adbd.
$SB/touch "$done_marker" 2>/dev/null
$BB sync 2>/dev/null

# 6. Diagnostics on the net log: interface state, ARP table, and the L2 counters.
guarded 4 "$BB ifconfig $IFACE >> \"$LOG\""
guarded 3 "$SB/cat /proc/net/arp >> \"$LOG\""
say "net: l2 before dhcp: $(eth_stats | $SB/tr '\n' ' ')"

# 7. DHCP, diagnostic only: the script logs the offer and never configures eth0. Runs in a
#    background subshell so a stuck udhcpc cannot hold the window; the kill watchdog bounds it.
if [ -f /sbin/hu-udhcpc.script ]; then
  say "net: dhcp script present at /sbin/hu-udhcpc.script"
else
  say "net: dhcp script MISSING at /sbin/hu-udhcpc.script - not attempting"
fi
dhcp=${DHCP_LIMIT:-60}
if [ -f /sbin/hu-udhcpc.script ]; then
  ( guarded "$dhcp" "$BB udhcpc -i $IFACE -t 5 -r 6 -s /sbin/hu-udhcpc.script 2>>\"$LOG\"" ) >/dev/null 2>&1 &
  say "net: dhcp diagnostic attempt started (background, ${dhcp}s)"
  $BB sleep "$dhcp"
fi
say "net: l2 after dhcp: $(eth_stats | $SB/tr '\n' ' ')"
guarded 3 "$SB/cat /proc/net/arp >> \"$LOG\""
say "net: address after dhcp=$addr / alias=$(iface_addr "$ALIASIF") (eth0 untouched by the dhcp script)"

# 8. Hold the window for 20 min (120 ticks of 10 s). A NEW nonce in the request file extends it again,
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
