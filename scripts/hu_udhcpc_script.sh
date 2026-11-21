#!/sbin/sh
# hu-udhcpc.script - busybox 1.11.1 udhcpc -s script. The recovery ramdisk ships no
# /usr/share/udhcpc/default.script, so udhcpc needs this one passed explicitly with -s.
# udhcpc hands the lease as environment variables: INTERFACE, IP, NETMASK, GATEWAY, DNS.
BB=/sbin/busybox
SB=/system/bin
LOG=/cache/hu-mark.log
say() {
  echo "$($SB/date +%s) dhcp $*" >> "$LOG" 2>/dev/null
  echo "hu-dhcp: $*" > /dev/kmsg 2>/dev/null
}
case "$1" in
  lease|bound)
    if [ -n "$IP" ]; then
      $BB ifconfig "$INTERFACE" "$IP" netmask "${NETMASK:-255.255.255.0}" up 2>>"$LOG"
      rc=$?
      say "lease applied iface=$INTERFACE ip=$IP mask=${NETMASK:-255.255.255.0} dns=${DNS:-none} rc=$rc"
      if [ -n "$GATEWAY" ]; then
        $BB route add default gw "$GATEWAY" 2>>"$LOG"
        say "route rc=$? gw=$GATEWAY"
      fi
    else
      say "lease without IP"
    fi
    ;;
  renew)
    say "renew iface=${INTERFACE:-eth0} ip=$IP"
    ;;
  deconfig)
    say "deconfig iface=${INTERFACE:-eth0}"
    ;;
  *)
    say "unknown action '$1'"
    ;;
esac
exit 0
