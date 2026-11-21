#!/sbin/sh
# hu-state.sh <delay-seconds> <outfile> - snapshot of the network/USB state <delay> s after this
# service starts. Every section is guarded separately, so a hanging applet cannot stall the others.
# Read-only sources; writes only to the given /cache file. Absolute tool paths only: init gives no
# PATH. ifconfig comes from busybox (the shape the recovery kernel reports); ls/cat/tail/dmesg come
# from toybox, because busybox 1.11.1 here has no cat/ls.
. /sbin/hu-h-common.sh
delay=$1
out=$2
cache_ready || { say "state($out): cache not mounted, giving up"; exit 1; }
say "state begin delay=$delay out=$out"
$BB sleep "$delay"
up=$(uptime_s)
echo "=== hu state up=$up date=$($SB/date +%s)" > "$out" 2>/dev/null
guarded 12 "$BB ifconfig -a >> \"$out\""
guarded 8  "$SB/cat /proc/net/route >> \"$out\""
guarded 8  "$SB/ls /sys/bus/usb/devices >> \"$out\""
guarded 8  "$SB/ls /sys/class/net >> \"$out\""
guarded 12 "$SB/dmesg 2>/dev/null | $SB/tail -30 >> \"$out\""
$BB sync 2>/dev/null
say "state end out=$out size=$($SB/stat -c %s \"$out\" 2>/dev/null) up=$up"
exit 0
