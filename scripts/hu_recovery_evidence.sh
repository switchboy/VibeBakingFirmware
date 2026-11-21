#!/sbin/sh
# hu_recovery_evidence.sh - runs automatically inside the patched recovery (partition 8, D80).
#
# Purpose. A boot that dies leaves no shell and no network: TCP adb only exists while Android 10 runs
# (D78), and none of the unit's USB ports drive adb in recovery. But the dead boot's kernel console text is
# still in RAM - pstore/ramoops keeps the *previous* boot's text (D77). Recovery boots after it, so recovery
# is the one environment that can read that record. Measured Nov 20: recovery's kernel does register pstore,
# and `mount -t pstore nodev /sys/fs/pstore` succeeds there, so this script reads the record and leaves it
# where a later Android 10 boot can pick it up over adb (/cache), and it puts partition 7 back on the
# known-good image when a risky write staged a restore request.
#
# Applet limits are measured, not assumed. The recovery ramdisk's busybox (strings over sbin/busybox, Nov 20)
# offers: awk cat cut date echo expr grep head md5sum mkdir mount reboot sed sha1sum sleep stat sync tail
# touch umount. It has NO dd, NO wc, NO cp, NO rm, NO ls, NO tr and NO sha256sum - so reading a partition
# uses cat, sizes use stat -c %s, digests use the hash applets, and nothing is deleted: the restore request
# is retired by writing a done-marker named after its nonce (D43's lesson: the installer may only use what
# the ramdisk already holds). Where busybox cannot do something, the script prefers the same ramdisk's
# /system/bin copy, which ships `sha256sum`/`dd`/`tr`/`rm`/`wc` as toybox plus linker64 and lib64, so it
# runs before recovery mounts the system slice; that is resolved by tool() rather than assumed.
#
# Device guard. Run outside the unit's recovery ramdisk it must do nothing at all. An earlier version ended
# with a bare `reboot`, which reached the workstation's own /usr/sbin/reboot during an offline dry-run and
# rebooted the workstation (Nov 20 evening) - hence the guard and the busybox-only reboot.

BB=/sbin/busybox
SB=/system/bin
OUT=/cache/hu-evidence
LOG=/cache/hu-evidence.log
REQ=/cache/hu-restore.request
ROLLBACK=/cache/hu-rollback-boot.bin
PSTORE=/sys/fs/pstore
RAMOOPS_BASE=1114112      # 0x110000
RAMOOPS_BYTES=1048576

if [ ! -e /dev/block/by-name/misc ] || [ ! -e /sbin/busybox ] || [ ! -e /sbin/sh ]; then
  echo "hu-evidence: no /dev/block/by-name/misc, /sbin/busybox or /sbin/sh - not the unit's recovery; doing nothing" >&2
  exit 1
fi

# Resolve a tool: the ramdisk's /system/bin copy when it exists, otherwise the busybox applet. Echoing two
# words ("/sbin/busybox sha1sum") is deliberate - it word-splits into command plus applet.
tool() {
  if [ -x "$SB/$1" ]; then printf '%s\n' "$SB/$1"; else printf '%s\n' "$BB $1"; fi
}
SHA=$(tool sha256sum)
SHA1=$(tool sha1sum)
MD5=$(tool md5sum)
TR=$(tool tr)

say() {
  $BB echo "$($BB date -u +%s 2>/dev/null) $1" >> "$LOG" 2>/dev/null
  $BB echo "$1" >> /dev/console 2>/dev/null
}

sz() { $BB stat -c %s "$1" 2>/dev/null; }

# A digest, full length, from a bounded read. The Nov 20 run stalled forever inside a full 96 MiB hash of the
# recovery partition and never reached the restore step, so every read is capped and piped: a hash of a pipe
# cannot wait on a device that someone else is writing.
hash() { $BB head -c "$2" "$1" 2>/dev/null | $SHA 2>/dev/null; }

# A digest, full length. The pipeline's exit status belongs to the last command, so the check is on the
# output being non-empty; empty means "no digest", and a caller must never treat two empties as a match.
dig() {
  d=$(hash "$1" 67108864 2>/dev/null)
  [ -n "$d" ] || d=$(hash "$1" 67108864 2>/dev/null | $SHA1 2>/dev/null)
  [ -n "$d" ] || d=$(hash "$1" 67108864 2>/dev/null | $MD5 2>/dev/null)
  set -- $d
  printf '%s\n' "${1:-}"
}

# What this environment really offers. busybox's own applet list came back 0 bytes on the unit (measured
# Nov 20 22:06), so the listing is made from the directories themselves with toybox ls.
record_tools() {
  # File names deliberately avoid a `/sbin`, `/system/bin` or `/dev/block/by-name` substring after $OUT: the
  # offline dry-run maps those absolute paths onto sandbox directories with sed, and an output name like
  # sbin-list.txt gets rewritten into a broken one by that same mapping.
  $(tool ls) -l /sbin > "$OUT/list-sbin.txt" 2>>"$LOG"
  $(tool ls) /system/bin > "$OUT/list-systembin.txt" 2>>"$LOG"
  $(tool ls) -l /dev/block/by-name > "$OUT/list-by-name.txt" 2>>"$LOG"
  $BB cat /proc/mounts > "$OUT/mounts.txt" 2>>"$LOG"
  say "tool listing: sbin=$(sz "$OUT/list-sbin.txt") systembin=$(sz "$OUT/list-systembin.txt") by-name=$(sz "$OUT/list-by-name.txt")"
}

# 1. Mount /cache first, then create the evidence directory INSIDE the mounted partition. The Nov 20 evening
# run mounted cache but had mkdir'd /cache/hu-evidence before the mount, so the directory vanished under the
# mount point and every copy failed with "No such file or directory".
i=0
while [ "$i" -lt 5 ]; do
  if $BB grep -q " /cache " /proc/mounts 2>/dev/null; then break; fi
  $BB mount -t ext4 /dev/block/by-name/cache /cache 2>/dev/null
  i=$((i+1))
  if $BB grep -q " /cache " /proc/mounts 2>/dev/null; then break; fi
  $BB sleep 1
done
if ! $BB grep -q " /cache " /proc/mounts 2>/dev/null; then
  say "cache not mounted after $i attempts - evidence cannot be persisted, stopping"
  exit 1
fi
$BB mkdir -p "$OUT" 2>/dev/null
say "cache mounted (attempt $i), evidence dir $OUT $(sz "$OUT")"

# 1b. Record what this environment can actually do, so the next rung is written against measurement rather
# than strings over the binary. busybox's own --list-applets came back empty on the unit (Nov 20 22:06), so
# the lists are taken from the directories. Everything lands in /cache and is readable over adb afterwards.
$BB --list-applets > "$OUT/busybox-applets.txt" 2>/dev/null
if [ -z "$(sz "$OUT/busybox-applets.txt")" ]; then $BB --list > "$OUT/busybox-applets.txt" 2>/dev/null; fi
$BB echo "busybox version: $($BB --version 2>/dev/null | $BB head -1)" > "$OUT/busybox-version.txt" 2>>"$LOG"
record_tools

# 2. Read the dead boot's console record.
$BB mkdir -p "$PSTORE" 2>/dev/null
$BB mount -t pstore nodev "$PSTORE" 2>/dev/null
got=0
if [ -f "$PSTORE/console-ramoops-0" ]; then
  say "source=pstore"
  for r in console-ramoops-0 pmsg-ramoops-0 dmesg-ramoops-0; do
    if [ -f "$PSTORE/$r" ]; then
      if $BB cat "$PSTORE/$r" > "$OUT/$r" 2>>"$LOG"; then
        say "copied $r: $(sz "$OUT/$r") bytes, digest $(dig "$OUT/$r")"
        got=1
      else
        say "copy of $r failed"
      fi
    fi
  done
else
  # pstore is not mounted: the ramoops RAM region still holds the previous zones. tail/head reach it
  # without dd - skip to the base, then cap the read.
  say "pstore not mounted - reading raw RAM from $RAMOOPS_BASE for $RAMOOPS_BYTES bytes"
  if $BB tail -c +"$((RAMOOPS_BASE + 1))" /dev/mem 2>/dev/null | $BB head -c "$RAMOOPS_BYTES" > "$OUT/ramoops-raw.bin" 2>>"$LOG"; then
    say "raw dump kept: $(sz "$OUT/ramoops-raw.bin") bytes"
    got=1
    # Keep a printable view too, so the file is readable without a binary editor. tr is not a busybox
    # applet here, so this goes through the resolved tool; if nothing is available the raw dump stays.
    if [ -x "$TR" ] || printf '%s' "$TR" | $BB grep -q 'busybox tr'; then
      $TR -c "[:print:]\n" "." < "$OUT/ramoops-raw.bin" > "$OUT/ramoops-text.txt" 2>>"$LOG"
      say "printable text kept: $(sz "$OUT/ramoops-text.txt") bytes"
    fi
  else
    say "raw dump failed"
  fi
fi

# 3. Say which boot this record belongs to (D77), and what recovery itself sees.
$BB cat /proc/cmdline > "$OUT/recovery-cmdline.txt" 2>>"$LOG"
$BB cat /proc/sys/kernel/random/boot_id > "$OUT/recovery-boot-id.txt" 2>>"$LOG"
$BB echo "read by recovery: uptime=$($BB cut -d' ' -f1 /proc/uptime 2>/dev/null) epoch=$($BB date -u +%s)" > "$OUT/when.txt" 2>>"$LOG"
say "p8 digest $(dig /dev/block/by-name/recovery)"

# 4. Restore partition 7 only when a risky write asked for it. The request carries a nonce, so a consumed
# request cannot re-arm the restore even though this busybox has no rm applet: the done-marker is named after
# the nonce, and a fresh request with a new nonce runs again.
nonce=$($BB awk '{print $1}' "$REQ" 2>/dev/null)
done_f="$OUT/restore-done.txt"
if [ -n "$nonce" ]; then done_f="$OUT/restore-done-$nonce.txt"; fi
restored=0
if [ -f "$REQ" ] && [ ! -f "$done_f" ]; then
  if [ -s "$ROLLBACK" ]; then
    before=$(dig /dev/block/by-name/boot)
    want=$(dig "$ROLLBACK")
    say "restore requested (nonce=${nonce:-none}): p7=${before:-unreadable} want=${want:-unreadable} rollback=$(sz "$ROLLBACK") bytes"
    # An unreadable digest must never look like a match: two empty strings compare equal, which would leave
    # the risky image in partition 7. Writing the rollback is the safe direction, so it happens anyway and
    # the result is recorded as unverified.
    if [ "$before" = "$want" ] && [ -n "$before" ]; then
      say "p7 already matches the rollback - not writing"
      $BB echo "skipped" > "$OUT/restore-skipped.txt" 2>>"$LOG"
    else
      if $BB cat "$ROLLBACK" > /dev/block/by-name/boot 2>>"$LOG"; then
        $BB sync 2>/dev/null
        restored=1
        after=$(dig /dev/block/by-name/boot)
        say "restored p7=${after:-unreadable} (wanted ${want:-unreadable})"
        if [ -z "$after" ] || [ -z "$want" ]; then
          $BB echo "unverified" > "$OUT/restore-unverified.txt" 2>>"$LOG"
        elif [ "$after" = "$want" ]; then
          $BB echo ok > "$OUT/restore-ok.txt" 2>>"$LOG"
        else
          $BB echo FAILED > "$OUT/restore-failed.txt" 2>>"$LOG"
        fi
      else
        say "restore write failed"
        $BB echo FAILED > "$OUT/restore-failed.txt" 2>>"$LOG"
      fi
    fi
    $BB touch "$done_f" 2>>"$LOG"
    $BB echo "nonce=${nonce:-none}" > "$OUT/restore-nonce.txt" 2>>"$LOG"
  else
    say "restore requested but $ROLLBACK missing - partition 7 untouched"
    $BB echo "no rollback file" > "$OUT/restore-skipped.txt" 2>>"$LOG"
  fi
elif [ -f "$REQ" ]; then
  say "restore request already consumed ($done_f present) - not restoring again"
else
  say "no restore request - recovery behaves as stock"
fi

$BB sync 2>/dev/null
say "done (evidence=$got, restored=$restored)"

# Hand the unit back. Two things bound this step:
#  - The owner's own install flow must survive (D80: MTC/mainboard flashing stays intact), so recovery is
#    left alone whenever an install package is on a card. The search reads whatever recovery already
#    mounted and only mounts a card itself when nothing carries a package - read-only, so the OEM card is
#    never modified.
#  - This unit enters recovery through the kernel's reboot-mode, so a reboot from inside recovery can land
#    back in the recovery menu (the Nov 20 evening run ended parked there). The reboot is therefore only
#    attempted when this boot actually did something, and the log says what to do if it lands back.
keep=0
for p in /mnt/external_sd /mnt/internal_sd /mnt/sdcard; do
  for z in update.zip "update(1).zip"; do
    if [ -f "$p/$z" ]; then
      keep=1
      say "install package present: $p/$z - leaving the recovery UI alone"
    fi
  done
done
if [ "$keep" != 1 ]; then
  $BB mkdir -p /mnt/hucard 2>/dev/null
  for c in /dev/block/mmcblk0p1 /dev/block/mmcblk0 /dev/block/mmcblk1p1 /dev/block/mmcblk1; do
    [ -b "$c" ] || continue
    if $BB mount -t vfat -o ro,sync "$c" /mnt/hucard 2>>"$LOG"; then
      for z in update.zip "update(1).zip"; do
        if [ -f "/mnt/hucard/$z" ]; then
          keep=1
          say "install package present: /mnt/hucard/$z - leaving the recovery UI alone"
        fi
      done
      [ "$keep" = 1 ] || $BB umount /mnt/hucard 2>/dev/null
    fi
    [ "$keep" = 1 ] && break
  done
fi
if [ "$keep" = 1 ]; then exit 0; fi

if [ "$got" = 1 ] || [ "$restored" = 1 ] || [ -f "$OUT/restore-skipped.txt" ]; then
  say "rebooting out of recovery; if this lands back in the recovery menu (reboot-mode), a cold power cycle boots partition 7"
  $BB reboot
fi
exit 0
