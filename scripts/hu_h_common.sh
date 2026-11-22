#!/sbin/sh
# hu-h-common.sh - shared lines for the recovery net module (D84/D85/D87). Sourced, never run.
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
#
# Nov 21 evening measurement changed two things here:
#  - The static fallback is the address the router binds to this dongle's MAC (measured: Android gets
#    192.168.1.127 for 00:0a:cd:27:a5:b2, and the owner MAC-bound it in the DHCP server so it is always
#    the same). Static 192.168.1.127/24 with gw 192.168.1.1 is therefore reachable from the workstation
#    with no privileged workstation-side change; 192.168.77.2 stays as an ALIAS on eth0:1 as a second
#    address in case the LAN one is taken by another client.
#  - /cache writes made inside recovery do not survive the reboot (the partitions are detached lazily
#    at reboot), so every write is followed by sync, and the evidence of record is kmsg read back
#    through pstore after the reboot plus the copies on the FAT32 card.
BB=/sbin/busybox
SB=/system/bin
CACHE=/cache
LOG=/cache/hu-mark.log
NETREQ=/cache/hu-net.request
IFACE=eth0
STATICIP=192.168.1.127
NETMASK=255.255.255.0
NETGW=192.168.1.1
ALIASIF=eth0:1
ALIASIP=192.168.77.2
ADBPORT=5555
TELNETPORT=2323

# Card-boot mode (**D98**). The flag file is baked into the SD-boot card's own recovery ramdisk. When it
# is present the module never mounts a partition and never opens a block device: markers and logs live in
# RAM (/tmp), and the misc head is read from the card's own misc node resolved by SIZE and TYPE from
# /proc/partitions plus /sys/block/<n>/device/type - never through by-name, which is measured to point at
# the eMMC while Android runs and is unmeasured inside a card boot.
CARD_FLAG=/sbin/hu-card-boot.flag
CARD_BLOCKS=7761920    # 7,948,206,080 B / 1024 - the SD-boot card, as /proc/partitions reports blocks
MISC_BLOCKS=4096       # 4,194,304 B / 1024 - the card's misc partition
if [ -f "$CARD_FLAG" ]; then
  CACHE=/tmp
  LOG=/tmp/hu-mark.log
  NETREQ=/tmp/hu-net.request
fi

# The misc node for the misc head read. Off the card flag this is the by-name link, exactly as before.
# On the card flag it resolves the SD device whose whole-device block count equals CARD_BLOCKS, then the
# partition of that device whose block count equals MISC_BLOCKS. Anything else - including the eMMC, whose
# type is MMC and whose size differs - is refused.
misc_node() {
  if [ ! -f "$CARD_FLAG" ]; then
    printf '%s\n' /dev/block/by-name/misc
    return 0
  fi
  card=""
  for d in /sys/block/mmcblk*; do
    [ -d "$d" ] || continue
    n=${d##*/}
    t=$($SB/cat "$d/device/type" 2>/dev/null)
    b=$($BB awk -v n="$n" '$4==n {print $3}' /proc/partitions 2>/dev/null)
    [ "$t" = SD ] || continue
    [ "$b" = "$CARD_BLOCKS" ] || continue
    card=$n
  done
  [ -n "$card" ] || { say "misc: no SD device of $CARD_BLOCKS blocks found - nothing read"; return 1; }
  pb=$($BB awk -v n="${card}p3" '$4==n {print $3}' /proc/partitions 2>/dev/null)
  [ "$pb" = "$MISC_BLOCKS" ] || { say "misc: ${card}p3 blocks=${pb:-none}, not $MISC_BLOCKS - nothing read"; return 1; }
  printf '%s\n' "/dev/block/${card}p3"
  return 0
}

say() {
  # marker first, then the action; both channels, both non-blocking, then sync so anything that can
  # reach the device actually reaches it (recovery detaches partitions lazily at reboot).
  echo "$($SB/date +%s) $*" >> "$LOG" 2>/dev/null
  echo "hu: $*" > /dev/kmsg 2>/dev/null
  $BB sync 2>/dev/null
}

uptime_s() { $SB/cut -d' ' -f1 /proc/uptime 2>/dev/null; }

# Poll nap: ~0.5 s if the ramdisk's toybox accepts a fractional sleep, otherwise the integer busybox
# sleep 1 (busybox 1.11.1 rejects fractions and exits 1). nap_probe measures which one works and says
# so once per boot, so the record states what the polls actually cost instead of assuming it; nap()
# then uses that answer. Default is the safe integer busybox sleep.
nap_probe() {
  NAPF=${NAPF:-}
  if [ -z "$NAPF" ]; then
    if $SB/sleep 0.5 2>/dev/null; then NAPF=1; else NAPF=0; fi
    if [ "$NAPF" = 1 ]; then say "nap: poll interval 0.5s via toybox fractional=1"; else say "nap: poll interval 1s via busybox fractional=0"; fi
  fi
}

nap() {
  NAPF=${NAPF:-0}
  if [ "$NAPF" = 1 ]; then $SB/sleep 0.5; else $BB sleep 1; fi
}

# Is the interface administratively OPEN? /sys/class/net/<iface>/flags holds IFF_UP in bit 0 (down
# ethernet reads 0x102 = BROADCAST|MULTICAST, open adds 0x1 and the driver adds 0x10 = RUNNING).
# busybox ifconfig is the fallback because the sysfs attribute could be missing on this kernel; the
# value is 1/0, and empty means "could not tell".
iface_up_state() {
  f=$($SB/cat "/sys/class/net/$1/flags" 2>/dev/null)
  if [ -n "$f" ]; then
    # the sysfs value is already hex ("0x113"), so it goes straight into the arithmetic - prefixing
    # another 0x here would make it 0x0x113, which neither mksh nor bash can evaluate.
    v=$(( $f ))
    if [ $((v & 1)) -eq 1 ]; then echo 1; else echo 0; fi
    return 0
  fi
  if $BB ifconfig "$1" 2>/dev/null | $SB/grep -a -q 'UP '; then echo 1; else echo 0; fi
}

# busybox ifconfig prints "inet addr:<ip>  Bcast:...". The address is field 2 of that line, and
# the inet6 line ("inet6 addr: fe80::...") is skipped because its value starts with a space, not a
# digit. grep/head/cut come from toybox; busybox has no cut.
iface_addr() {
  $BB ifconfig "$1" 2>/dev/null | $SB/grep -a -o 'addr:[0-9.]*' | $SB/head -1 | $SB/cut -d: -f2
}

# The driver only reports carrier after it logs "ax88179 - Link status is: 1" (measured at 5.13 s of
# a recovery boot); before that the file reads empty, so an empty value means "not ready", not "down".
carrier_of() { $SB/cat "/sys/class/net/$1/carrier" 2>/dev/null; }

# The five RX/TX counters the L2 diagnosis needs. Read-only sysfs reads, tiny, so no guarded wrapper.
eth_stats() {
  d="/sys/class/net/$IFACE/statistics"
  for f in rx_packets tx_packets rx_errors tx_errors rx_dropped; do
    echo "$f=$($SB/cat "$d/$f" 2>/dev/null)"
  done
}

cache_ready() {
  if [ -f "$CARD_FLAG" ]; then
    # Card boot (**D98**): no partition is mounted by this module. /tmp already exists in the ramdisk, so
    # the marker directory is ready without opening any ext4 partition read-write.
    $SB/mkdir -p "$CACHE" 2>/dev/null
    return 0
  fi
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
  $BB sync 2>/dev/null
}
