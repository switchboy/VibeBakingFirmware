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
echo "=== actual table values (sgdisk may shift starts to its alignment) ==="
# Match by partition NAME, not by row number: sgdisk re-sorts the entries by start sector, so the
# row indices (and therefore the kernel's mmcblk2pN numbers) change even though the names do not.
# gdisk's Size column is two fields ("8.0 GiB"), so the name is always the last field.
s_row=$(gdisk -l "$IMG" | awk '$NF=="super" {print $2, $3}')
u_row=$(gdisk -l "$IMG" | awk '$NF=="userdata" {print $2, $3}')
[ -n "$s_row" ] && [ -n "$u_row" ] || { echo "could not read super/userdata rows"; exit 1; }
set -- $s_row; s_first=$1; s_last=$2; super_bytes=$(( (s_last - s_first + 1) * 512 ))
set -- $u_row; u_first=$1; u_last=$2; user_bytes=$(( (u_last - u_first + 1) * 512 ))
old_user=$(( (user_last - user_first + 1) * 512 ))
# awk, not bc: bc prints a locale decimal comma here, which printf rejects as "invalid number".
awk -v a="$old_super" -v b="$super_bytes" -v c="$old_user" -v d="$user_bytes" \
  'BEGIN { printf "  super    %d -> %d bytes (%.2f GiB)\n", a, b, b/1073741824;
           printf "  userdata %d -> %d bytes (%.2f GiB)\n", c, d, d/1073741824 }'
printf '  disk tail reserve: %s bytes\n' "$(( disk_bytes - (u_last + 1) * 512 ))"
if [ "$super_bytes" -lt "$SUPER" ]; then
  echo "  note: alignment shrank super by $(( SUPER - super_bytes )) bytes - BoardConfig must use the actual value."
fi
echo
echo "paste into device/rk3399-px6-hct4/BoardConfig.mk:"
echo "  BOARD_SUPER_PARTITION_SIZE := $super_bytes"
echo "  BOARD_HCT_DYNAMIC_PARTITIONS_SIZE := $(( super_bytes - 4 * 1024 * 1024 ))"
echo
echo "The entry order is re-sorted by start sector, so mmcblk2pN numbers change (super is no longer"
echo "p14, boot is no longer p7). Everything on the unit must address partitions by"
echo "/dev/block/by-name/<name>, which init builds from the GPT names."

# The two blobs to write: primary GPT (MBR+header+128 entries = 34 LBAs) and backup GPT (33 LBAs).
dd if="$IMG" of="$OUT/gpt_head.bin" bs=1 count=17408 status=none
dd if="$IMG" of="$OUT/gpt_tail.bin" bs=1 skip=$(( disk_bytes - 16896 )) count=16896 status=none

echo "=== apply from a root shell on the unit (Boot-ADB) ==="
echo "dd if=gpt_head.bin of=/dev/block/mmcblk2 bs=1 count=17408 conv=notrunc"
echo "dd if=gpt_tail.bin of=/dev/block/mmcblk2 bs=1 seek=$(( disk_bytes - 16896 )) conv=notrunc"
echo "partprobe /dev/block/mmcblk2      # or reboot so the kernel re-reads the table"
echo "mkfs.f2fs /dev/block/by-name/userdata"
