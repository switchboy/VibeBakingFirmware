#!/sbin/sh
# hu-card.sh - the no-network channel: copy the log and the state files onto a FAT32 card
# (<=32 GB; this kernel cannot mount exFAT). Runs late, after the state snapshots exist.
# If the recovery UI already mounted the card, copies are additive (never touches an install
# package); otherwise the card is mounted read-write at /mnt/hucard, copied, synced, unmounted.
. /sbin/hu-h-common.sh
cache_ready || { say "card: cache not mounted, giving up"; exit 1; }
say "card begin"

copy_to() {
  dst=$1
  guarded 20 "$SB/cp /cache/hu-mark.log $dst/hu-mark.log"
  for f in /cache/state-recovery-*.txt; do
    [ -f "$f" ] || continue
    b=${f##*/}
    guarded 15 "$SB/cp $f $dst/$b"
  done
  guarded 10 "$SB/cp /cache/misc-head.bin $dst/misc-head.bin"
  $BB sync 2>/dev/null
  say "card copied to $dst: $($SB/ls $dst 2>/dev/null | $SB/tr '\n' ' ')"
}

if $SB/grep -q " /mnt/external_sd " /proc/mounts 2>/dev/null; then
  if $SB/cp /cache/hu-mark.log /mnt/external_sd/hu-mark.log 2>/dev/null; then
    copy_to /mnt/external_sd
    say "card end (UI-mounted channel)"
    exit 0
  fi
  say "card: /mnt/external_sd mounted but not writable - channel unused"
  exit 0
fi

$SB/mkdir -p /mnt/hucard 2>/dev/null
mounted=0
for c in /dev/block/mmcblk0p1 /dev/block/mmcblk0 /dev/block/mmcblk1p1 /dev/block/mmcblk1; do
  [ -b "$c" ] || continue
  if $BB mount -t vfat -o rw,sync "$c" /mnt/hucard 2>/dev/null; then mounted=1; say "card mounted $c"; break; fi
done
if [ "$mounted" != 1 ]; then
  say "card: no mountable FAT32 card found - channel unused"
  exit 0
fi
copy_to /mnt/hucard
$SB/umount /mnt/hucard 2>/dev/null
say "card end"
exit 0
