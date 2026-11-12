#!/system/bin/sh
# flash_recovery_from_adb_root.sh - write the patched recovery image to partition 8 while stock
# Android 10 boots, over `adb root` on TCP (factory password `adbon`).
#
# Why partition 8 is safe to write (D42): recovery is not part of the boot chain. u-boot loads
# uboot/trust/dtb/dtbo/vbmeta/security and then boots `boot`; a broken recovery only removes the
# recovery environment, it cannot stop a normal boot. AVB cannot reject the image either: the vbmeta
# partition holds zero descriptors and neither the stock nor the patched recovery has an AVB footer.
# The rollback is byte-exact: hu-stock-backup/recovery.bin (sha256 1fdf5ea77fc6…) is pushed back and
# dd'd to the same partition.
#
# Nothing else is touched - boot, super, uboot, trust, dtb, dtbo, vbmeta, security, misc, GPT are
# all left alone (D18/D19).
#
# Run:  adb root
#       adb push recovery-patched.img recovery-sha256.txt /data/local/tmp/rec/
#       adb shell sh /data/local/tmp/rec/flash_recovery_from_adb_root.sh
# mksh: dd/sha256sum/stat/blockdev/awk only. Sizes here are well under the 2 GiB wrap limit, but the
# partition/image comparison still goes through awk.
set -u

SRC=${SRC:-/data/local/tmp/rec}
IMG=${IMG:-recovery-patched.img}
SHA=${SHA:-recovery-sha256.txt}
REC=/dev/block/by-name/recovery

say() { printf '%s\n' "$1"; }

if [ "$(id -u)" != 0 ]; then
  say "ABORT: needs uid 0 - run `adb root` first"
  exit 1
fi
[ -s "$SRC/$IMG" ] || { say "ABORT: no $SRC/$IMG"; exit 1; }
[ -s "$SRC/$SHA" ] || { say "ABORT: no $SRC/$SHA - record the hash before writing"; exit 1; }
[ -b "$REC" ] || { say "ABORT: no $REC"; exit 1; }

want=$(cut -d' ' -f1 "$SRC/$SHA")
got=$(sha256sum "$SRC/$IMG" | cut -d' ' -f1)
say "staged image $got"
[ "$got" = "$want" ] || { say "ABORT: staged image does not match $SHA - push it again"; exit 1; }

part=$(blockdev --getsize64 "$REC" 2>/dev/null)
[ -n "${part:-}" ] || part=$(awk -v d=$(basename "$(readlink "$REC")") '$4 == d { printf "%.0f", $3 * 1024 }' /proc/partitions 2>/dev/null)
img=$(stat -c %s "$SRC/$IMG")
say "recovery partition $part B ; image $img B"
awk -v i="$img" -v p="$part" 'BEGIN { exit (i+0 > p+0 || i+0 < 1000000) ? 1 : 0 }' \
  || { say "ABORT: image $img B not plausible for partition $part B - nothing written"; exit 1; }

# What is on the partition right now, so the rollback can be checked against it afterwards.
head_now=$(dd if="$REC" bs=4096 count=16 2>/dev/null | sha256sum | cut -d' ' -f1)
say "current partition head $head_now (stock recovery.bin head is 41 4e 44 52 4f 49 44 21 = ANDROID!)"

say "== writing recovery =="
dd if="$SRC/$IMG" of="$REC" bs=4096 conv=fsync 2>&1 | tail -1
sync

say "== read back =="
blocks=$((img / 4096))
rb=$(dd if="$REC" bs=4096 count="$blocks" 2>/dev/null | sha256sum | cut -d' ' -f1)
if [ "$rb" = "$want" ]; then
  say "  ok   recovery readback $rb"
else
  say "  FAIL recovery readback $rb != image $want"
  say "  Rollback: adb push hu-stock-backup/recovery.bin /data/local/tmp/rec/stock.bin"
  say "            adb shell dd if=/data/local/tmp/rec/stock.bin of=$REC bs=4096 conv=fsync"
  exit 1
fi

say "== done: partition 8 now carries the patched recovery =="
say "boot it with the bootSD card and a card that holds hu-install.flag in its root"
say "(scripts/stage_hu_card.sh writes the flag, the payload images and hu-checksums.txt)."
