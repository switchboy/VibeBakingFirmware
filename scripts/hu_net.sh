#!/sbin/sh
# hu-net.sh - Ethernet bring-up inside recovery (D84). Gated on /cache/hu-net.request (a nonce,
# consumed once via a nonce-named done marker), because always-on networking would change behaviour
# on every boot. Never reboots: the recovery window must stay open for the workstation.
# Measured Nov 21: eth0 registers through the built-in ax88179_178a at ~1.7 s of a recovery boot,
# so only userspace bring-up is needed here - no driver load, no USB enabler.
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
say "net begin nonce=$nonce iface=$IFACE static=$STATICIP/$NETMASK gw=$NETGW adbport=$ADBPORT"

# 1. Wait for the interface, logging every 5 s so a silent failure is distinguishable from a slow one.
poll=${POLL_LIMIT:-60}   # 60 s of polling on the unit; overridable for offline tests only
i=0
while [ "$i" -lt "$poll" ]; do
  if [ -d "/sys/class/net/$IFACE" ]; then
    say "net: iface $IFACE present at up=$(uptime_s) carrier=$($SB/cat /sys/class/net/$IFACE/carrier 2>/dev/null)"
    break
  fi
  guarded 6 "$SB/ls /sys/class/net >> \"$LOG\""
  say "net: waiting for $IFACE (t=${i}s)"
  $BB sleep 5
  i=$((i + 5))
done
if [ ! -d "/sys/class/net/$IFACE" ]; then
  say "net: $IFACE never appeared after ${poll} s - stopping, no reboot"
  exit 0
fi

# 2. Bring the link up, then try DHCP with the shipped script (the ramdisk has no
#    /usr/share/udhcpc/default.script, so -s points at the injected one). Guarded so a stuck
#    udhcpc cannot hold the window.
guarded 10 "$BB ifconfig $IFACE up"
say "net: ifconfig $IFACE up issued"
guarded 30 "$BB udhcpc -i $IFACE -n -q -t 5 -s /sbin/hu-udhcpc.script"
say "net: udhcpc finished"

addr=$(iface_addr "$IFACE")
if [ -z "$addr" ]; then
  say "net: no DHCP address - falling back to static $STATICIP/$NETMASK"
  guarded 10 "$BB ifconfig $IFACE $STATICIP netmask $NETMASK up"
  guarded 8 "$BB route add default gw $NETGW"
  addr=$(iface_addr "$IFACE")
fi
say "net: address=$addr"
guarded 8 "$BB ifconfig $IFACE >> \"$LOG\""
guarded 8 "$BB route >> \"$LOG\""

# 3. TCP adb. The recovery ramdisk ships no adb keys, so the patched prop.default sets
#    ro.adb.secure=0; without that adbd defaults to secure and refuses an unauthenticated TCP link.
$SB/setprop service.adb.tcp.port "$ADBPORT"
$SB/setprop ctl.start adbd
$BB sleep 2
say "net: adbd svc=$($SB/getprop init.svc.adbd) tcpport=$($SB/getprop service.adb.tcp.port) secure=$($SB/getprop ro.adb.secure)"
# 5555 decimal = 0x15B3 in /proc/net/tcp; state 0A = LISTEN.
listening=$($SB/grep -a -i '15B3' /proc/net/tcp 2>/dev/null | $SB/head -1)
say "net: adbd listen line=${listening:-none}"

# 4. Redundant shell: busybox telnetd. 1.11.1 may or may not take -p, so try the port, then the
#    default, and say which one was used.
telnetport=none
if $BB telnetd -l /sbin/sh -p 2323 2>>"$LOG"; then
  say "net: telnetd on 2323 (login /sbin/sh)"
  telnetport=2323
elif $BB telnetd -l /sbin/sh 2>>"$LOG"; then
  say "net: telnetd on default 23 (login /sbin/sh); p rejected by this busybox"
  telnetport=23
else
  say "net: telnetd failed"
fi
say "net: workstation reaches ${addr:-none}:$ADBPORT (adb) and :$telnetport (telnet); staying in recovery, no reboot"
$SB/touch "$done_marker" 2>/dev/null
$BB sync 2>/dev/null

# 5. Hold the window for 20 min (120 ticks of 10 s). A NEW nonce in the request file extends it
#    again, so the owner can keep the session open without flashing anything. Tick counts are
#    overridable for offline tests only; the unit always uses the defaults.
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
