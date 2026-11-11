#!/bin/bash
# NAS-side half of scripts/cold_storage_move.sh (STAGE=nas). Transferred to the NAS as base64 and run
# there, because nested ssh quoting eats operands. Tidies old build passes into cold storage on the
# ZFS DataPool (908 GiB free) and moves tonight's offline extraction scratch out of /var/tmp.
#
# Inputs that must stay put: hu-stock-backup (rollback mirror), ref-a10 (vendor staging blobs),
# daisaita_a11.zip (the firmware the vendor slice was staged from), and lineage21s (the build tree).
set -u
A=/srv/50911774-19fb-46b6-bc9e-8cf81623d044/aospbuild-archive
C=/srv/50911774-19fb-46b6-bc9e-8cf81623d044/cold/vibe-baking

mkdir -p "$C/nas-archive" "$C/nas-var-tmp"

cd "$A"
for d in "extracted update.zip" vibe-rescue vibe-fix out a11boot update.zip; do
  if [ -e "$d" ]; then
    mv "$d" "$C/nas-archive/" && printf 'moved archive: %s\n' "$d"
  fi
done
echo "--- archive left in place (inputs, not scratch) ---"
ls "$A"

echo "--- NAS /var/tmp scratch ---"
for f in /var/tmp/a10-system.img /var/tmp/rec-full.bin /var/tmp/recrd /var/tmp/rec-boot.bin \
         /var/tmp/mkfs /var/tmp/otac /var/tmp/otac-dual /var/tmp/otac-dual.zip \
         /var/tmp/huzip /var/tmp/out /var/tmp/a14repack /var/tmp/a14repack2 /var/tmp/recprobe.sh; do
  if [ -e "$f" ]; then
    mv "$f" "$C/nas-var-tmp/" && printf 'moved scratch: %s\n' "$f"
  fi
done

echo "--- cold contents ---"
du -sh "$C/nas-archive" "$C/nas-var-tmp" 2>/dev/null | sort -rh
echo "--- free space after ---"
df -h / /srv/dev-disk-by-label-SSData /srv/50911774-19fb-46b6-bc9e-8cf81623d044 | tail -4
