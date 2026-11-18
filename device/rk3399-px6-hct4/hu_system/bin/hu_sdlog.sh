#!/system/bin/sh
# Bring-up log capture onto the SD card, started by init BEFORE vold so a framework that
# restart-loops still writes something we can read on the bench.
#
# What the card is, measured Nov 18 on the rolled-back unit: eMMC is mmcblk2, the inserted card is
# mmcblk0 with one FAT32 partition (mmcblk0p1); stock's vold mounts that volume at
# /mnt/media_rw/363A-7751. We mount it ourselves at /mnt/hu_sd instead of waiting for vold.
#
# Safety: this mounts only mmcblk0* and writes only onto that card. It never touches mmcblk2 (the
# eMMC) or any partition by name. Nothing here reboots, wipes or formats.
#
#   hu_sdlog.sh            run by init as root (seclabel u:r:shell:s0, permissive bring-up)
#   output on the card:    hu-boot.log    snapshot + appended logcat stream
#                          hu-pstore.txt  previous boot's kernel console (RAMoops)
#                          hu-attempts.txt one line per boot, so a loop is visible as a count
set -u

CARD=${CARD:-/dev/block/mmcblk0p1}
MNT=/mnt/hu_sd
LOG=$MNT/hu-boot.log
ATT=$MNT/hu-attempts.txt

say() { printf '%s\n' "$1"; }

mkdir -p "$MNT" 2>/dev/null
if mount -t vfat -o noatime,rw "$CARD" "$MNT" 2>&1; then
  say "card mounted: $CARD -> $MNT"
else
  # Whole-disk fallback: a card formatted without a partition table is still FAT.
  if mount -t vfat -o noatime,rw /dev/block/mmcblk0 "$MNT" 2>&1; then
    say "card mounted whole-disk: mmcblk0 -> $MNT"
  else
    say "NO CARD MOUNTED - falling back to /cache/hu-boot.log (survives a reboot, needs adb to read)"
    LOG=/cache/hu-boot.log
    ATT=/cache/hu-attempts.txt
  fi
fi

# One line per boot attempt: a boot loop shows up as a growing count on the card.
echo "$(date '+%s.%N') boot attempt, uptime=$(cut -d' ' -f1 /proc/uptime), selinux=$(getenforce 2>/dev/null)" >> "$ATT" 2>/dev/null

# ---- snapshot of the stage we reached ----------------------------------------------------------
{
  echo "=== hu-boot snapshot ==="
  date '+%Y-%m-%d %H:%M:%S'
  echo "--- cmdline ---";  cat /proc/cmdline
  echo "--- version ---";  getprop ro.build.display.id; getprop ro.build.version.release; getprop ro.debuggable
  echo "--- adb ---";      getprop service.adb.tcp.port; getprop ro.adb.secure
  echo "--- mounts ---";   mount
  echo "--- mounts of interest ---"; ls -l /mnt/hu_sd 2>/dev/null
  echo "--- services ---"; getprop | grep -E 'init\.svc|\.status' | sort
  echo "--- restart counters ---"; getprop | grep -E 'init\.svc\.(surfaceflinger|zygote|adbd|vold|logd|netd)' | sort
  echo "--- modules loaded ---"; lsmod 2>/dev/null | head -20
  echo "--- wifi ---"; getprop ro.boot.wificountrycode; ls /sys/class/net 2>/dev/null
  echo "--- pstore list ---"; ls -l /sys/fs/pstore 2>/dev/null
  echo "--- df ---"; df 2>/dev/null | head -12
} > "$LOG.snapshot" 2>&1

# Previous boot's kernel console survives a WARM reboot in RAMoops. That is the only way to read a
# panic or an init failure from a boot that died before writing anything (no UART, no adb).
for f in /sys/fs/pstore/*; do
  [ -f "$f" ] || continue
  echo "=== $(basename "$f") ===" >> "$MNT/hu-pstore.txt" 2>/dev/null
  cat "$f" >> "$MNT/hu-pstore.txt" 2>/dev/null
done

# ---- the live stream ----------------------------------------------------------------------
# Foreground, so init owns the process and restarts it if it dies; every restart attempt is itself
# a log line. -T 0 starts from the oldest buffered entry, so the whole boot is captured.
sync 2>/dev/null
exec logcat -b all -T 0 -v threadtime >> "$LOG" 2>&1
