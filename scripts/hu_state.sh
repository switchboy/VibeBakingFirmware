#!/sbin/sh
# hu-state.sh <delay-seconds> <outfile> - snapshot of the network/USB state <delay> s after this
# service starts. Every section is guarded separately, so a hanging applet cannot stall the others.
# Read-only sources; writes only to the given /cache file, then a copy to the card if one is mounted.
# Absolute tool paths only: init gives no PATH. ifconfig comes from busybox (the shape the recovery
# kernel reports); ls/cat/tail/dmesg/stat come from toybox, because busybox 1.11.1 here has no awk.
# Nov 21 evening: the owner asked for the L2 counters and the ARP table in here; the size is now taken
# with an unquoted stat argument (the old \\"$out\\" form passed literal quote characters to toybox and
# printed an empty size), and the snapshot is copied to the card because /cache written inside
# recovery does not survive the reboot.
. /sbin/hu-h-common.sh
delay=$1
out=$2
cache_ready || { say "state($out): cache not mounted, giving up"; exit 1; }
say "state begin delay=$delay out=$out"
$BB sleep "$delay"
up=$(uptime_s)
echo "=== hu state up=$up date=$($SB/date +%s)" > "$out" 2>/dev/null
$BB sync 2>/dev/null
echo "=== l2 counters ($(eth_stats | $SB/tr '\n' ' '))" >> "$out" 2>/dev/null
$BB sync 2>/dev/null
guarded 12 "$BB ifconfig -a >> \"$out\""
guarded 6  "$BB ifconfig $IFACE >> \"$out\""
guarded 8  "$SB/cat /proc/net/route >> \"$out\""
guarded 8  "$SB/cat /proc/net/arp >> \"$out\""
guarded 8  "$SB/ls /sys/bus/usb/devices >> \"$out\""
guarded 8  "$SB/ls /sys/class/net >> \"$out\""
guarded 12 "$SB/dmesg 2>/dev/null | $SB/tail -30 >> \"$out\""
$BB sync 2>/dev/null
size=$($SB/stat -c %s "$out" 2>/dev/null)
say "state end out=$out size=${size:-none} up=$up"

# The card is the durable channel. hu-card.sh keeps its own mount alive until the 120 s snapshot
# exists, so either mount point is a valid destination; copies are additive and never touch an
# install package. In card-boot mode (**D98**) the boot card IS this device, so copying there would be
# a module writing a block device - refused, and the snapshot stays in RAM.
dst=none
if [ -f "$CARD_FLAG" ]; then
  say "state card copy: card-boot mode - refusing to write to a block device, snapshot stays in RAM ($out)"
else
if [ -d /mnt/hucard ]; then dst=/mnt/hucard
elif $SB/grep -q " /mnt/external_sd " /proc/mounts 2>/dev/null; then dst=/mnt/external_sd
fi
if [ "$dst" != none ]; then
  b=${out##*/}
  guarded 15 "$SB/cp \"$out\" \"$dst/$b\"; echo \"$($SB/date +%s) state copied to card rc=\$?\" >> \"$LOG\""
  $BB sync 2>/dev/null
  say "state card copy out=$b dst=$dst"
else
  say "state card copy: no card mounted - snapshot only in /cache (best effort)"
fi
fi
exit 0
