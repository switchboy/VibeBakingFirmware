#!/usr/bin/env bash
# stage_hu_card.sh - puts the Android 14 payload plus the recovery installer's inputs on a card,
# all in the card root, in the layout scripts/hu_recovery_install.sh expects.
#
#   hu-install.flag     - makes the patched recovery run the installer at all
#   hu-checksums.txt    - one `size <bytes> <blocks> <name>` line per payload (the installer's busybox
#                         cannot do arithmetic above 2 GiB, so it reads the block count here), plus a
#                         digest line per algorithm: `<applet> <hex> <name>` named exactly as the
#                         busybox applet (sha256sum/sha1sum/md5sum) because the installer matches the
#                         manifest against whichever applet it actually has
#   super-a14.img       - raw-super.img, the logical super container
#   boot-a14.img        - a14-boot-fixed.img, A10 kernel + Android 14 first-stage ramdisk
#   update.zip          - the signed fallback package (recovery can install it by hand)
#   hu-install.sh       - a readable copy of what the patched recovery runs
#
# The card needs ~3.3 GiB of free space. The second, small card is only used to force recovery;
# this script writes the roomy one. Usage: stage_hu_card.sh <mounted-card-dir>
set -u

CARD="${1:?usage: stage_hu_card.sh <mounted-card-dir>}"
CHK=/run/media/Daan/Opslagmonster/a14-work/a14chk
ZIP=/run/media/Daan/Opslagmonster/a14-work/huzip-card/update.zip
REPO=/run/media/Daan/Opslagmonster/VibeBakingFirmware
LOG=/run/media/Daan/Opslagmonster/a14-work/card-stage.log

: > "$LOG"
say() { printf '%s\n' "$1" >> "$LOG"; }

[ -d "$CARD" ] || { say "no such card dir: $CARD"; echo "see $LOG"; exit 1; }

say "=== free space on the card ==="
df -h "$CARD" >> "$LOG" 2>&1

say "=== copy the payload ==="
cp "$CHK/raw-super.img" "$CARD/super-a14.img" >> "$LOG" 2>&1
cp "$CHK/a14-boot-fixed.img" "$CARD/boot-a14.img" >> "$LOG" 2>&1
cp "$REPO/scripts/hu_recovery_install.sh" "$CARD/hu-install.sh" >> "$LOG" 2>&1
[ -s "$ZIP" ] && cp "$ZIP" "$CARD/update.zip" >> "$LOG" 2>&1
touch "$CARD/hu-install.flag"

say "=== manifest: sizes first, then every digest we can compute ==="
: > "$CARD/hu-checksums.txt"
rc=0
for name in super-a14.img boot-a14.img; do
  f="$CARD/$name"
  [ -s "$f" ] || { say "FAIL $name not copied"; rc=1; continue; }
  b=$(stat -c %s "$f")
  # dd in the installer works in 4096-byte blocks, so a payload that is not block-aligned would
  # leave its tail unwritten; refuse it here rather than on the unit.
  if (( b % 4096 )); then say "FAIL $name is $b B, not a multiple of 4096"; rc=1; continue; fi
  printf 'size %d %d %s\n' "$b" "$((b / 4096))" "$name" >> "$CARD/hu-checksums.txt"
  for applet in sha256sum sha1sum md5sum; do
    h=$(LC_ALL=C "$applet" "$f" 2>/dev/null | cut -d' ' -f1)
    [ -n "$h" ] && printf '%s %s %s\n' "$applet" "$h" "$name" >> "$CARD/hu-checksums.txt"
  done
done
cat "$CARD/hu-checksums.txt" >> "$LOG"

say "=== read the card back ==="
sync
ls -l "$CARD" >> "$LOG" 2>&1
while read -r tag f1 f2 f3; do
  if [ "$tag" = size ]; then
    got=$(stat -c %s "$CARD/$f3" 2>/dev/null)
    if [ "$got" = "$f1" ]; then say "  ok   $f3 size $f1 ($f2 blocks)"; else say "  FAIL $f3 size: got=$got manifest=$f1"; rc=1; fi
    continue
  fi
  got=$(LC_ALL=C "$tag" "$CARD/$f2" 2>/dev/null | cut -d' ' -f1)
  if [ "$got" = "$f1" ]; then say "  ok   $f2 $tag"; else say "  FAIL $f2 $tag got=$got"; rc=1; fi
done < "$CARD/hu-checksums.txt"
[ -f "$CARD/hu-install.flag" ] && say "  ok   hu-install.flag present" || { say "  FAIL hu-install.flag missing"; rc=1; }
say "=== card staging rc=$rc ==="
echo "see $LOG"
exit "$rc"
