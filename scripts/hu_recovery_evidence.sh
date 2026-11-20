#!/sbin/sh
# hu_recovery_evidence.sh - runs automatically inside the patched recovery (partition 8, D80).
#
# Purpose. A boot that dies leaves no shell and no network: TCP adb only exists while Android 10 runs
# (D78), and none of the unit's USB ports drive adb in recovery. But the dead boot's kernel console text is
# still in RAM - pstore/ramoops keeps the *previous* boot's text (D77). Recovery boots after it, so recovery
# is the one environment that can read that record. This script reads it and leaves it where a later
# Android 10 boot can pick it up over adb, and it puts partition 7 back on the known-good image if a risky
# write was staged with a restore request.
#
# It uses only what the recovery ramdisk already carries (/sbin/sh and /sbin/busybox, both static 32-bit
# ARM, measured Nov 20), so it works before /system is mounted - the same constraint D43 sets for the card
# installer. It never touches a boot-chain partition other than the boot partition it restores, and it
# never resizes anything (D18/D19).
#
# Destination is /cache: recovery's init.rc mkdirs /cache, recovery.fstab names /dev/block/by-name/cache,
# and Android 10 mounts /cache, so the files are readable over adb after the unit comes back. No SD card
# and no UART are involved.
#
# Inert without the marker: with no /cache/hu-restore.request this only copies records, so a patched
# recovery with no marker behaves exactly like the stock one (D42's rule).

BB=/sbin/busybox
OUT=/cache/hu-evidence
LOG=/cache/hu-evidence.log
REQ=/cache/hu-restore.request
ROLLBACK=/cache/hu-rollback-boot.bin
PSTORE=/sys/fs/pstore
RAMOOPS_BASE=0x110000
RAMOOPS_BYTES=1048576

say() {
  $BB echo "$(date -u +%s 2>/dev/null) $1" >> "$LOG" 2>/dev/null
  $BB echo "$1" >> /dev/console 2>/dev/null
}

sz() { $BB wc -c < "$1" 2>/dev/null; }

# busybox here has no sha256sum (D43 measured that), so probe a digest applet and use what exists.
dig() {
  if $BB sha256sum "$1" 2>/dev/null | $BB cut -c1-12; then return; fi
  $BB md5sum "$1" 2>/dev/null | $BB cut -c1-12
}

mkdir -p "$OUT" 2>/dev/null

# 1. Get /cache writable. ext4, and the OTA flow may hold it, so retry.
i=0
while [ "$i" -lt 5 ]; do
  $BB mount -t ext4 /dev/block/by-name/cache "$OUT" 2>/dev/null
  if $BB mount 2>/dev/null | $BB grep -q " $OUT "; then break; fi
  i=$((i+1)); $BB sleep 1
done
if ! $BB mount 2>/dev/null | $BB grep -q " $OUT "; then
  say "cache not mounted after $i attempts - evidence cannot be persisted, stopping"
  exit 1
fi
say "cache mounted (attempt $i)"

# 2. Read the dead boot's console record. Prefer pstore; fall back to raw RAM if pstore is not a filesystem here.
mkdir -p "$PSTORE" 2>/dev/null
$BB mount -t pstore nodev "$PSTORE" 2>/dev/null
if [ -f "$PSTORE/console-ramoops-0" ]; then
  say "source=pstore"
  for r in console-ramoops-0 pmsg-ramoops-0; do
    if [ -f "$PSTORE/$r" ]; then
      $BB dd if="$PSTORE/$r" of="$OUT/$r" bs=4096 conv=noerror 2>>"$LOG"
      say "copied $r: $(sz "$OUT/$r") bytes, digest $(dig "$OUT/$r")"
    fi
  done
else
  # The ramoops region at RAMOOPS_BASE still holds the previous zones. Dump it raw and keep the printable
  # runs, so the record is readable even if this kernel ships no pstore filesystem.
  say "pstore not mounted - dumping $RAMOOPS_BYTES raw from $RAMOOPS_BASE"
  $BB dd if=/dev/mem of="$OUT/ramoops-raw.bin" bs=4096 count=$((RAMOOPS_BYTES/4096)) \
      skip=$((RAMOOPS_BASE/4096)) conv=noerror 2>>"$LOG"
  if [ -s "$OUT/ramoops-raw.bin" ]; then
    $BB tr -c "[:print:]\n" "." < "$OUT/ramoops-raw.bin" > "$OUT/ramoops-text.txt" 2>>"$LOG"
    say "raw dump kept: $(sz "$OUT/ramoops-raw.bin") bytes, printable text $(sz "$OUT/ramoops-text.txt") bytes"
  else
    say "raw dump failed - no /dev/mem or read refused"
  fi
fi

# 3. Say which boot this record belongs to, so the log stays interpretable (D77).
$BB cat /proc/cmdline > "$OUT/recovery-cmdline.txt" 2>>"$LOG"
$BB cat /proc/sys/kernel/random/boot_id > "$OUT/recovery-boot-id.txt" 2>>"$LOG"
$BB echo "read by recovery: uptime=$(cut -d' ' -f1 /proc/uptime 2>/dev/null) epoch=$(date -u +%s)" > "$OUT/when.txt" 2>>"$LOG"
say "p8 digest $(dig /dev/block/by-name/recovery)"

# 4. Restore partition 7 only when a risky write asked for it.
if [ -f "$REQ" ]; then
  if [ -s "$ROLLBACK" ]; then
    before=$(dig /dev/block/by-name/boot)
    want=$(dig "$ROLLBACK")
    say "restore requested: p7=$before want=$want"
    if [ "$before" != "$want" ]; then
      $BB dd if="$ROLLBACK" of=/dev/block/by-name/boot bs=1M count=32 conv=fsync 2>>"$LOG"
      after=$(dig /dev/block/by-name/boot)
      say "restored p7=$after (wanted $want)"
      if [ "$after" = "$want" ]; then $BB echo ok > "$OUT/restore-ok.txt"; else $BB echo FAILED > "$OUT/restore-failed.txt"; fi
    else
      $BB echo "already on the rollback image" > "$OUT/restore-skipped.txt"
    fi
    $BB rm -f "$REQ" 2>>"$LOG"
  else
    say "restore requested but $ROLLBACK missing - partition 7 untouched"
    $BB echo "no rollback file" > "$OUT/restore-skipped.txt"
  fi
else
  say "no restore request - recovery behaves as stock"
fi

$BB sync 2>/dev/null
say "done"

# Hand the unit back: with a restore (or a no-op restore) the next boot is the known-good Android 10, which
# reads /cache over adb. Without a request we leave the recovery UI alone.
if [ -f "$OUT/restore-ok.txt" ] || [ -f "$OUT/restore-skipped.txt" ]; then
  say "rebooting to the restored image"
  reboot 2>/dev/null || $BB reboot 2>/dev/null
fi
exit 0
