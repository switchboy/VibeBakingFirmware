#!/sbin/sh
# hu-card.sh - the no-network channel: copies the log and the state snapshots onto a FAT32 card
# (<=32 GB; this kernel cannot mount exFAT). Nov 21 evening revision: the card stays mounted until the
# 120 s snapshot has landed, and the copy is re-run every tick, because /cache written inside recovery
# does not survive the reboot (partitions are detached lazily at reboot) - the card copy is taken from
# the live page cache, so it captures what /cache would otherwise lose. Copies are additive and never
# touch an install package.
. /sbin/hu-h-common.sh
cache_ready || { say "card: cache not mounted, giving up"; exit 1; }
say "card begin"

copy_all() {
  dst=$1
  guarded 20 "$SB/cp /cache/hu-mark.log \"$dst/hu-mark.log\""
  for f in /cache/state-recovery-*.txt; do
    [ -f "$f" ] || continue
    b=${f##*/}
    guarded 15 "$SB/cp \"$f\" \"$dst/$b\""
  done
  guarded 10 "$SB/cp /cache/misc-head.bin \"$dst/misc-head.bin\""
  # the nonce request is copied only when it exists, so an unarmed boot copies nothing extra
  [ -f /cache/hu-net.request ] && guarded 10 "$SB/cp /cache/hu-net.request \"$dst/hu-net.request\""
  $BB sync 2>/dev/null
  say "card copied to $dst: $($SB/ls $dst 2>/dev/null | $SB/tr '\n' ' ')"
}

# If the recovery UI already mounted the card, copy into that mount without touching the mount table.
if $SB/grep -q " /mnt/external_sd " /proc/mounts 2>/dev/null; then
  if $SB/cp /cache/hu-mark.log /mnt/external_sd/hu-mark.log 2>/dev/null; then
    ticks=${CARD_ITERS:-24}
    i=0
    while [ "$i" -lt "$ticks" ]; do
      copy_all /mnt/external_sd
      [ -f /cache/state-recovery-120.txt ] && { say "card: 120 s snapshot captured, done"; break; }
      $BB sleep 10
      i=$((i + 1))
    done
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
ticks=${CARD_ITERS:-24}
i=0
while [ "$i" -lt "$ticks" ]; do
  copy_all /mnt/hucard
  [ -f /cache/state-recovery-120.txt ] && { say "card: 120 s snapshot captured, done"; break; }
  $BB sleep 10
  i=$((i + 1))
done
$SB/umount /mnt/hucard 2>/dev/null
$BB sync 2>/dev/null
say "card end"
exit 0
