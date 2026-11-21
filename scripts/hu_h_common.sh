#!/sbin/sh
# hu-h-common.sh - shared lines for the recovery net module (D84, Nov 21). Sourced, never run.
# Kept deliberately tiny. mksh R40 is /sbin/sh; init gives no PATH, so every tool is an absolute
# path. Measured Nov 21 by pushing the ramdisk's own busybox to the unit and running `busybox --help`:
# the applet list carries ifconfig route netstat dmesg udhcpc telnetd mount umount head tail grep
# stat sync kill sleep date cat ls awk sed cut tr cp rm mkdir touch basename dd md5sum sort wc - and
# NOT sha256sum and NOT timeout. The ramdisk's /system/bin is toybox, 196 applets (cat ls tail grep
# cut head sed stat cp mkdir rm touch basename tr umount setprop getprop dmesg dd sha256sum
# timeout), and toybox has NO awk.
# The trap is the call shape, not availability: busybox is multi-call, so `$BB cat` is right, while
# `$SB cat` would exec the DIRECTORY /system/bin with "cat" as an argument - toybox needs `$SB/cat`.
# Digests stay off-device for two reasons: busybox cannot sha256 at all, and toybox has no awk.
# Rules honoured: marker before action; nothing on the critical path may block (guarded() runs a
# kill watchdog); no on-device digest of a block device; no $(...) over a pipeline that reads one.
BB=/sbin/busybox
SB=/system/bin
CACHE=/cache
LOG=/cache/hu-mark.log
NETREQ=/cache/hu-net.request
IFACE=eth0
STATICIP=192.168.77.2
NETMASK=255.255.255.0
NETGW=192.168.1.1
ADBPORT=5555

say() {
  # marker first, then the action; both channels, both non-blocking.
  echo "$($SB/date +%s) $*" >> "$LOG" 2>/dev/null
  echo "hu: $*" > /dev/kmsg 2>/dev/null
}

uptime_s() { $SB/cut -d' ' -f1 /proc/uptime 2>/dev/null; }

# busybox ifconfig prints "inet addr:<ip>  Bcast:...". The address is field 2 of that line, and
# the inet6 line ("inet6 addr: fe80::...") is skipped because its value starts with a space, not a
# digit. grep/head/cut come from toybox; busybox has no cut.
iface_addr() {
  $BB ifconfig "$1" 2>/dev/null | $SB/grep -a -o 'addr:[0-9.]*' | $SB/head -1 | $SB/cut -d: -f2
}

cache_ready() {
  i=0
  while [ "$i" -lt 5 ]; do
    $SB/grep -q " /cache " /proc/mounts 2>/dev/null && return 0
    $BB mount -t ext4 /dev/block/by-name/cache "$CACHE" 2>/dev/null
    $BB sync 2>/dev/null
    i=$((i + 1))
  done
  $SB/grep -q " /cache " /proc/mounts 2>/dev/null
}

# guarded <secs> <command-string>: run the string through the ramdisk's own shell in a background
# subshell, kill it after <secs>. busybox 1.11.1 has no timeout applet (toybox has one, but it is
# not on the critical path's busybox side), so the watchdog is a plain sleep+kill pair. The caller
# never blocks beyond <secs>, and redirections work because the string is interpreted by sh.
guarded() {
  t=$1; shift
  /sbin/sh -c "$*" >/dev/null 2>&1 &
  p=$!
  ( $BB sleep "$t"; $BB kill -9 "$p" 2>/dev/null ) >/dev/null 2>&1 &
  w=$!
  $BB sleep "$t"
  $BB kill -9 "$p" 2>/dev/null
  $BB kill -9 "$w" 2>/dev/null
}
