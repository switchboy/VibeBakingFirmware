#!/usr/bin/env bash
# stage_hu_card.sh - puts the Android 14 payload plus the recovery installer's inputs on a card,
# all in the card root, in the layout scripts/hu_recovery_install.sh expects.
#
#   hu-install.flag     - makes the patched recovery run the installer at all
#   hu-checksums.txt    - "<algo> <hex> <name>" lines; the installer picks whichever algo its
#                         busybox has (sha256sum is absent there, so sha1/md5 matter)
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

say "=== manifest: every algo the recovery busybox might offer ==="
: > "$CARD/hu-checksums.txt"
for name in super-a14.img boot-a14.img; do
  for algo in sha256 sha1 md5; do
    h=$(LC_ALL=C ${algo}sum "$CARD/$name" 2>/dev/null | cut -d' ' -f1)
    [ -n "$h" ] && printf '%s %s %s\n' "$algo" "$h" "$name" >> "$CARD/hu-checksums.txt"
  done
done
cat "$CARD/hu-checksums.txt" >> "$LOG"

say "=== read the card back ==="
sync
ls -l "$CARD" >> "$LOG" 2>&1
rc=0
while read -r algo h name; do
  got=$(LC_ALL=C ${algo}sum "$CARD/$name" 2>/dev/null | cut -d' ' -f1)
  if [ "$got" = "$h" ]; then say "  ok   $name $algo"; else say "  FAIL $name $algo got=$got"; rc=1; fi
done < "$CARD/hu-checksums.txt"
[ -f "$CARD/hu-install.flag" ] && say "  ok   hu-install.flag present" || { say "  FAIL hu-install.flag missing"; rc=1; }
say "=== card staging rc=$rc ==="
echo "see $LOG"
exit "$rc"
