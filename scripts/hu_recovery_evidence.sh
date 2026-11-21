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
NETREQ=/cache/hu-net.request
NETCONF=/cache/hu-net.conf
PSTORE=/sys/fs/pstore
RAMOOPS_BASE=1114112      # 0x110000
RAMOOPS_BYTES=1048576
# Ethernet defaults, overridable through $NETCONF (line per key: iface ip gw adbtelnet). The workstation on
# this bench LAN is 192.168.1.161; the unit has been 192.168.1.120 throughout (measured Nov 21).
IFACE=eth0
NETIP=192.168.1.120
NETMASK=255.255.255.0
NETGW=192.168.1.1
ADBPORT=5555

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
STRINGS=$(tool strings)
DD=$(tool dd)
LS=$(tool ls)
SETPROP=$(tool setprop)
GETPROP=$(tool getprop)
NETSTAT=$(tool netstat)

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

# 3b. The bootloader control block. misc holds the reboot-mode request that decides which boot happens next,
# so its first 4 KiB is kept on every recovery boot: whether a plain `reboot` clears it (booting partition 7)
# or leaves it parked in recovery is measured by comparing this file across boots, not guessed.
if $BB head -c 4096 /dev/block/by-name/misc > "$OUT/misc-bcb.bin" 2>>"$LOG"; then
  say "misc BCB kept: $(sz "$OUT/misc-bcb.bin") bytes, digest $(dig "$OUT/misc-bcb.bin")"
  if $STRINGS "$OUT/misc-bcb.bin" > "$OUT/misc-bcb.txt" 2>>"$LOG"; then
    say "BCB text view kept through strings"
  elif $BB grep -a "boot-recovery" "$OUT/misc-bcb.bin" > "$OUT/misc-bcb.txt" 2>>"$LOG"; then
    say "busybox grep found boot-recovery in the BCB"
  fi
else
  say "misc BCB read failed"
fi

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

# 5. The network phase (D84). A boot that dies leaves no shell; recovery does, and the USB host port takes a
# USB-Ethernet dongle. Measured Nov 21: the dongle (ASIX AX88179_178A) binds on fe3c0000.usb as eth0 while
# Android runs, the driver is BUILT INTO the kernel blob (ax88179_178a, plus asix/cdc_ether/cdc_ncm/r8152
# strings in the same kernel that recovery boots), and SELinux is permissive (androidboot.selinux=permissive),
# so binding sockets and writing partitions need no policy work. busybox here has ifconfig/route/telnetd,
# and the ramdisk's /system/bin has setprop/getprop/netstat/dd/strings - no WiFi, no wpa_supplicant, no modules.
net_nonce=$($BB awk '{print $1}' "$NETREQ" 2>/dev/null)
net_done="$OUT/net-done.txt"
if [ -n "$net_nonce" ]; then net_done="$OUT/net-done-$net_nonce.txt"; fi
netup=0
if [ -f "$NETREQ" ] && [ ! -f "$net_done" ]; then
  # Optional overrides; a missing conf means the defaults above.
  if [ -f "$NETCONF" ]; then
    v=$($BB awk -F= '/^iface=/ {print $2}' "$NETCONF" 2>/dev/null); [ -n "$v" ] && IFACE="$v"
    v=$($BB awk -F= '/^ip=/ {print $2}' "$NETCONF" 2>/dev/null); [ -n "$v" ] && NETIP="$v"
    v=$($BB awk -F= '/^gw=/ {print $2}' "$NETCONF" 2>/dev/null); [ -n "$v" ] && NETGW="$v"
    ssid=$($BB awk -F= '/^ssid=/ {print $2}' "$NETCONF" 2>/dev/null)
  fi
  say "net requested (nonce=${net_nonce:-none}): iface=$IFACE ip=$NETIP gw=$NETGW adbport=$ADBPORT"

  # The dongle binds asynchronously; wait for the interface rather than assuming it.
  i=0
  while [ "$i" -lt 12 ]; do
    if [ -d "/sys/class/net/$IFACE" ]; then break; fi
    $BB sleep 1
    i=$((i+1))
  done
  $LS -l /sys/class/net > "$OUT/list-ifaces.txt" 2>>"$LOG"

  if [ -d "/sys/class/net/$IFACE" ]; then
    say "interface $IFACE present after $i s (carrier=$($BB cat /sys/class/net/$IFACE/carrier 2>/dev/null || echo '?'))"
    # busybox's ifconfig takes the classic keyword form; toybox's would not, so this goes through busybox.
    if $BB ifconfig "$IFACE" "$NETIP" netmask "$NETMASK" up 2>>"$LOG"; then
      netup=1
      say "ip set: $IFACE=$NETIP/$NETMASK"
      $BB route add default gw "$NETGW" 2>>"$LOG"
      say "route: default via $NETGW rc=$?"
    else
      say "ifconfig failed for $IFACE"
    fi

    if [ "$netup" = 1 ]; then
      # TCP adb. adbd is a disabled service in recovery's init.rc; ro.debuggable=1 and the permissive policy
      # make an unauthenticated TCP adbd possible. If init has no adbd domain the property shows it.
      $SETPROP service.adb.tcp.port "$ADBPORT" 2>>"$LOG"
      $SETPROP ctl.start adbd 2>>"$LOG"
      $BB sleep 2
      say "adbd: service.adb.tcp.port=$($GETPROP service.adb.tcp.port) init.svc.adbd=$($GETPROP init.svc.adbd)"

      # An interactive shell on telnet: /sbin/sh is mksh R40 on the unit (measured Nov 21), root in recovery.
      if $BB telnetd -l /sbin/sh 2>>"$LOG"; then say "telnetd started (port 23, login /sbin/sh)"; else say "telnetd failed"; fi

      # What the workstation can actually reach, recorded rather than assumed.
      $NETSTAT -tn > "$OUT/list-net.txt" 2>>"$LOG"
      # Can this environment write a partition? Probed with a zero-length write (conv=notrunc opens O_WRONLY
      # and writes nothing), so the answer is measured without changing any bytes.
      if $DD conv=notrunc bs=1 count=0 of=/dev/block/by-name/boot 2>>"$LOG"; then
        say "p7 write probe: open-for-write OK (0 bytes written)"
      else
        say "p7 write probe FAILED - partition writes must happen from Android instead"
      fi
      say "net up: workstation reaches $NETIP via adb:$ADBPORT and telnet:23; staying in recovery, no reboot"
      $BB touch "$net_done" 2>>"$LOG"
      $BB sync 2>/dev/null
    fi
  else
    # No Ethernet: the WiFi fallback, only live if the ramdisk carries the module and the conf names an AP.
    # The recovery kernel has cfg80211/mac80211 built in and its vermagic matches Android's 8188eu.ko
    # (4.19.111+ SMP preempt mod_unload modversions aarch64), so insmod is the intended route; this unit's
    # WiFi chip is an RTL8188EU USB module. busybox has no wpa_supplicant, so only an OPEN AP works via iw.
    ko=""
    for k in /sbin/modules/8188eu.ko /lib/modules/8188eu.ko; do
      [ -f "$k" ] && ko="$k" && break
    done
    if [ -n "$ko" ]; then
      say "no $IFACE - trying WiFi fallback: insmod $ko"
      $BB insmod "$ko" 2>>"$LOG"
      say "insmod rc=$?, modules now: $($BB lsmod 2>/dev/null | $TR '\n' ' ')"
      if [ -n "${ssid:-}" ] && [ -x "$SB/iw" ]; then
        $(tool iw) dev wlan0 connect "$ssid" 2>>"$LOG"
        say "iw connect rc=$?"
        $BB ifconfig wlan0 "$NETIP" netmask "$NETMASK" up 2>>"$LOG" && netup=1
        if [ "$netup" = 1 ]; then
          $SETPROP service.adb.tcp.port "$ADBPORT" 2>>"$LOG"; $SETPROP ctl.start adbd 2>>"$LOG"
          $BB telnetd -l /sbin/sh 2>>"$LOG"
          say "wifi net up on wlan0 ($ssid)"
          $BB touch "$net_done" 2>>"$LOG"
        fi
      else
        say "no open-AP ssid in $NETCONF, or iw absent - WiFi fallback stopped"
      fi
    else
      say "no $IFACE and no WiFi module in the ramdisk - network stopped, rebooting out as before"
    fi
  fi
elif [ -f "$NETREQ" ]; then
  say "net request already consumed ($net_done present) - network not brought up again"
fi

if [ "$netup" = 1 ]; then
  say "network armed: recovery stays up for the workstation; partition 7 is left alone until it writes one"
elif [ "$got" = 1 ] || [ "$restored" = 1 ] || [ -f "$OUT/restore-skipped.txt" ]; then
  say "rebooting out of recovery; if this lands back in the recovery menu (reboot-mode), a cold power cycle boots partition 7"
  $BB reboot
fi
exit 0
