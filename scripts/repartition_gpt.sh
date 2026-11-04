#!/usr/bin/env bash
# Build the D8 replacement partition table (super 8 GiB, userdata 49.84 GiB) as dd-able blobs.
#
#   scripts/repartition_gpt.sh <offsets.txt> analysis/gpt [super_bytes] [userdata_bytes]
#
# offsets.txt comes from the on-device probe section "Partition offsets for repartitioning":
#   disk sectors: <n>
#   name first_lba last_lba          (mmcblk2pN, 512-byte LBAs)
#
# p1-p13 keep their exact LBAs, so their contents stay valid. Super grows and userdata shrinks by
# the same amount, so the disk's last LBA and the backup-GPT reserve do not move. userdata's first
# LBA moves later (it is reformatted anyway, so that is fine).
#
# sgdisk computes the header/entry CRCs; we never hand-write GPT bytes.
set -eu

OFF=${1:?usage: repartition_gpt.sh <offsets.txt> <outdir> [super_bytes] [userdata_bytes]}
OUT=${2:?usage: repartition_gpt.sh <offsets.txt> <outdir> [super_bytes] [userdata_bytes]}
SUPER=${3:-8589934592}
USERDATA=${4:-53517729280}

declare -A NAMES=(
  [mmcblk2p1]=uboot [mmcblk2p2]=trust [mmcblk2p3]=misc [mmcblk2p4]=dtb [mmcblk2p5]=dtbo
  [mmcblk2p6]=vbmeta [mmcblk2p7]=boot [mmcblk2p8]=recovery [mmcblk2p9]=backup
  [mmcblk2p10]=security [mmcblk2p11]=cache [mmcblk2p12]=metadata [mmcblk2p13]=frp
  [mmcblk2p14]=super [mmcblk2p15]=userdata
)

disk_sectors=$(grep '^disk sectors:' "$OFF" | awk '{print $3}')
[ -n "$disk_sectors" ] || { echo "offsets file has no 'disk sectors:' line"; exit 1; }
disk_bytes=$(( disk_sectors * 512 ))

mkdir -p "$OUT"
IMG="$OUT/disk.img"
truncate -s "$disk_bytes" "$IMG"

args=(--clear)
super_first=$(grep '^mmcblk2p14 ' "$OFF" | awk '{print $2}')
super_last=$(grep '^mmcblk2p14 ' "$OFF" | awk '{print $3}')
user_first=$(grep '^mmcblk2p15 ' "$OFF" | awk '{print $2}')
user_last=$(grep '^mmcblk2p15 ' "$OFF" | awk '{print $3}')
old_super=$(( (super_last - super_first + 1) * 512 ))
delta=$(( SUPER - old_super ))
[ "$delta" -gt 0 ] || { echo "super is not growing (old=$old_super new=$SUPER)"; exit 1; }
new_user_first=$(( user_first + delta / 512 ))
new_super_last=$(( super_first + SUPER / 512 - 1 ))
[ "$new_user_first" -eq $(( new_super_last + 1 )) ] || { echo "super and userdata would overlap"; exit 1; }
new_user_size=$(( (user_last - new_user_first + 1) * 512 ))
[ "$new_user_size" -ge $(( USERDATA )) ] || { echo "userdata would end up smaller than requested"; exit 1; }
[ "$user_last" -le "$disk_sectors" ] || { echo "userdata last LBA beyond disk"; exit 1; }

idx=1
while read -r name first last; do
  [ -n "${NAMES[$name]:-}" ] || continue
  n="${NAMES[$name]}"
  if [ "$name" = mmcblk2p14 ]; then
    args+=(-n "$idx:$super_first:$new_super_last" -c "$idx:super")
  elif [ "$name" = mmcblk2p15 ]; then
    args+=(-n "$idx:$new_user_first:$user_last" -c "$idx:userdata")
  else
    args+=(-n "$idx:$first:$last" -c "$idx:$n")
  fi
  idx=$(( idx + 1 ))
done < <(grep '^mmcblk2p' "$OFF")

sgdisk "${args[@]}" "$IMG" >/dev/null
sgdisk -v "$IMG" | tail -6
echo "=== new table ==="
gdisk -l "$IMG" | sed -n '/Partition table/,$p'
echo "=== sizes ==="
printf '  super    %s -> %s bytes\n' "$old_super" "$SUPER"
printf '  userdata %s -> %s bytes\n' "$(( (user_last - user_first + 1) * 512 ))" "$(( (user_last - new_user_first + 1) * 512 ))"
printf '  tail reserve unchanged: %s bytes\n' "$(( disk_bytes - (user_last + 1) * 512 ))"

# The two blobs to write: primary GPT (MBR+header+128 entries = 34 LBAs) and backup GPT (33 LBAs).
dd if="$IMG" of="$OUT/gpt_head.bin" bs=1 count=17408 status=none
dd if="$IMG" of="$OUT/gpt_tail.bin" bs=1 skip=$(( disk_bytes - 16896 )) count=16896 status=none

echo "=== apply from a root shell on the unit (Boot-ADB) ==="
echo "dd if=gpt_head.bin of=/dev/block/mmcblk2 bs=1 count=17408 conv=notrunc"
echo "dd if=gpt_tail.bin of=/dev/block/mmcblk2 bs=1 seek=$(( disk_bytes - 16896 )) conv=notrunc"
echo "partprobe /dev/block/mmcblk2      # or reboot so the kernel re-reads the table"
echo "mkfs.f2fs /dev/block/by-name/userdata"
