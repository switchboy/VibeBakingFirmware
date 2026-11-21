#!/sbin/sh
# hu-early.sh - the FIRST recovery action: save pstore, then the misc head. Read-only sources,
# /cache-only writes. Runs as its own oneshot service so nothing else can block it.
. /sbin/hu-h-common.sh
cache_ready || { say "early: cache not mounted, giving up"; exit 1; }
up=$(uptime_s)
say "early begin up=$up"

# 1. pstore first, before this boot's own console text overwrites the ramoops buffer (the buffer
#    mixes boots, so it is copied raw rather than interpreted). No nested quoting: the basename is
#    expanded before the guarded string is built.
PDIR=/cache/pstore-$up
$SB/mkdir -p "$PDIR" 2>/dev/null
$BB mount -t pstore nodev /sys/fs/pstore 2>/dev/null
n=0
for f in /sys/fs/pstore/*; do
  [ -f "$f" ] || continue
  b=${f##*/}
  guarded 10 "$SB/cat $f > $PDIR/$b"
  [ -s "$PDIR/$b" ] && n=$((n + 1))
done
$BB sync 2>/dev/null
say "early pstore copied files=$n dir=$PDIR"

# 2. misc head, read-only, 2048 B. No digest of the block device (rule: no on-device sha of
#    anything large; head -c on a block device is measured to work).
guarded 15 "$BB head -c 2048 /dev/block/by-name/misc > /cache/misc-head.bin"
say "early misc head size=$($SB/stat -c %s /cache/misc-head.bin 2>/dev/null)"
$BB sync 2>/dev/null
say "early end"
exit 0
