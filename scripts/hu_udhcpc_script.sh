#!/sbin/sh
# hu-udhcpc.script - busybox 1.11.1 udhcpc -s script. The recovery ramdisk ships no
# /usr/share/udhcpc/default.script, so udhcpc needs this one passed explicitly with -s.
# udhcpc hands the offer/lease as environment variables: INTERFACE, IP, NETMASK, GATEWAY, DNS.
#
# Nov 21 evening: this script is DIAGNOSTIC ONLY. It records what the DHCP server offers and NEVER
# configures the interface - the static LAN address must not be replaced mid-session, and the Nov 21
# boot showed udhcpc coming up with no lease after 30 s anyway. hu-net.sh runs it in a background
# subshell with stderr into the log, so the counters around the attempt tell L2 success from failure.
BB=/sbin/busybox
SB=/system/bin
LOG=/cache/hu-mark.log
say() {
  echo "$($SB/date +%s) dhcp $*" >> "$LOG" 2>/dev/null
  echo "hu-dhcp: $*" > /dev/kmsg 2>/dev/null
  $BB sync 2>/dev/null
}
case "$1" in
  lease|bound|renew)
    # Recording only: no ifconfig, no route, nothing that would move eth0's address.
    say "offer observed iface=${INTERFACE:-eth0} ip=${IP:-none} mask=${NETMASK:-none} gw=${GATEWAY:-none} dns=${DNS:-none} (eth0 untouched)"
    ;;
  deconfig|nobind|release)
    say "dhcp action '$1' iface=${INTERFACE:-eth0} (no interface change made)"
    ;;
  *)
    say "unknown action '$1' (no interface change made)"
    ;;
esac
exit 0
