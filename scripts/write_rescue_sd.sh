#!/usr/bin/env bash
# Build the rescue/boot MicroSD card for the Rockchip PX6 (RK3399 / HCT4 MTCE) head unit.
#
# Run this on the LAPPER's bench machine, NOT the workstation. The workstation's /dev/sda is a
# 7.3 T RAID array holding the payload archive - it must never be written.
#
# The layout mirrors the unit's eMMC partition map sector-for-sector (measured from the unit's own
# by-name symlinks and /proc/partitions, and confirmed against the owner's known-good factory PX6
# SD firmware, which carries the same partition offsets and byte-identical trust.img/dtbo.img).
# Rockchip BootROM reads the ID block loader at sector 64; vendor u-boot then reads uboot at 16384
# and finds boot/dtbo/vbmeta/super by GPT partition name (boot_targets=mmc1 mmc0 ..., mmc1 = SD).
#
# Nothing here touches the unit. Only the card is written.
set -euo pipefail

DEV="${1:-/dev/sda}"
DIR="${2:-$HOME/sdrescue}"

# ---- identity gate: refuse anything that is not the removable SD card -------------------------
[ -b "$DEV" ] || { echo "abort: $DEV is not a block device"; exit 1; }
RM="$(cat /sys/block/$(basename "$DEV")/removable 2>/dev/null || echo 0)"
VENDOR="$(cat /sys/block/$(basename "$DEV")/device/vendor 2>/dev/null || true)"
MODEL="$(cat /sys/block/$(basename "$DEV")/device/model 2>/dev/null || true)"
TRAN="$(cat /sys/block/$(basename "$DEV")/device/transport 2>/dev/null || true)"
SECTORS="$(cat /sys/block/$(basename "$DEV")/size)"
BYTES=$((SECTORS * 512))

echo "target: $DEV removable=$RM vendor=$VENDOR model=$MODEL transport=$TRAN size=$((BYTES / 1024 / 1024)) MiB"

[ "$RM" = "1" ] || { echo "abort: $DEV is not removable (RM=$RM)"; exit 1; }
case "$VENDOR" in *"SD/MMC"*|*Generic*) ;; *) echo "abort: vendor '$VENDOR' is not a card reader"; exit 1;; esac
[ "$BYTES" -ge 7000000000 ] && [ "$BYTES" -le 8000000000 ] || { echo "abort: size $BYTES outside 7-8 GB"; exit 1; }
if mount | grep -q "^${DEV}[0-9]* "; then echo "abort: a partition of $DEV is mounted"; exit 1; fi
if lsblk -M "$DEV" 2>/dev/null | grep -qE "${DEV}[0-9]+ .*(rom|rwm)"; then echo "abort: mounted"; exit 1; fi
# never a disk holding / or /home
if lsblk -o MOUNTPOINTS -l "$DEV" 2>/dev/null | grep -qE "^/( |/home|/srv|/run/media)"; then
  echo "abort: $DEV carries a system mountpoint"; exit 1; fi

# ---- payload ------------------------------------------------------------------
# whole-disk 512-byte LBAs, matching the unit's map
declare -A OFF=(
  [idbloader.bin]=64
  [uboot.img]=16384
  [trust.img]=24576
  [dtb.dtb]=40960
  [dtbo.img]=49152
  [vbmeta.img]=57344
  [boot-a10.img]=59392
  [super-a10.img]=1378328
)
declare -A WANT=(
  [idbloader.bin]=a6e6502dff43d7d2f54d9b14603b82a7b1e13dd7a190a6f61ccfc0dba0604f80
  [uboot.img]=a28fd6a0e6c63ef88b65522dbde6c885a299440e3d60ded16beaff8de85b838e
  [trust.img]=7f2c4e52e595b7922b2f0139bebcfffbb231235040df75423a9939fa1e483cd0
  [dtb.dtb]=cd4eeb3daeceb0e972f84905d9bf4f7ff1b9dd7560ebed2b0a698ff717675275
  [dtbo.img]=28a07d4946e9f27884c69eab91437f0a1499344035b1d808d3a2a31303d06dcb
  [vbmeta.img]=ad7facb2586fc6e966c004d7d1d16b024f5805ff7cb47c7a85dabd8b48892ca7
  [boot-a10.img]=04a43ea931de08734d8a25afe9920cba69a099095ab4b4490dbbe4368d0b89c6
  [super-a10.img]=30da961c94ba064d1edce80d5dc3b96ad5ec7480a4971b8ca38d1bdb2cefc11c
)

for f in "${!OFF[@]}"; do
  [ -f "$DIR/$f" ] || { echo "abort: missing $DIR/$f"; exit 1; }
  got="$(sha256sum "$DIR/$f" | cut -d' ' -f1)"
  if [ "$got" != "${WANT[$f]}" ]; then
    echo "abort: $f sha $got != manifest ${WANT[$f]}"; exit 1
  fi
  echo "payload ok: $f $(stat -c %s "$DIR/$f") B sha ${got:0:12}"
done

# ---- partition map (card-local GPT, same names and offsets as the unit's eMMC) ---------------
LAST=$((SECTORS - 34))   # backup GPT occupies the last 33 LBAs; last usable LBA = SECTORS-34
if [ "$LAST" -le 1378328 ]; then echo "abort: card too small for super"; exit 1; fi

echo "wiping $DEV"
dd if=/dev/zero of="$DEV" bs=1M count=8 conv=notrunc status=none        # kill old MBR/GPT/first data
dd if=/dev/zero of="$DEV" bs=1M seek=$((BYTES / 1024 / 1024 - 8)) count=8 conv=notrunc status=none   # kill old backup GPT
sgdisk --zap-all "$DEV"                                                 # clear MBR + main + backup GPT
sgdisk -o "$DEV"                                                        # fresh, consistent GPT
sgdisk -a 8 \
  -n 1:16384:24575    -c 1:uboot     \
  -n 2:24576:32767    -c 2:trust     \
  -n 3:32768:40959    -c 3:misc      \
  -n 4:40960:49151    -c 4:dtb       \
  -n 5:49152:57343    -c 5:dtbo      \
  -n 6:57344:59391    -c 6:vbmeta    \
  -n 7:59392:124927   -c 7:boot      \
  -n 8:124928:321535  -c 8:recovery  \
  -n 9:321536:550911  -c 9:backup    \
  -n 10:550912:559103 -c 10:security \
  -n 11:559104:1345535 -c 11:cache   \
  -n 12:1345536:1378303 -c 12:metadata \
  -n 13:1378304:1378327 -c 13:frp    \
  -n 14:1378328:7752703  -c 14:super  \
  -n 15:7752704:$LAST    -c 15:userdata \
  "$DEV"
echo "GPT written; verifying with fdisk (kernel parser):"
fdisk -l "$DEV" 2>/dev/null | sed -n '1,25p'
NPARTS=$(fdisk -l "$DEV" 2>/dev/null | grep -c "^${DEV}[0-9]")
[ "$NPARTS" = "15" ] || { echo "abort: fdisk sees $NPARTS partitions, expected 15"; exit 1; }
sgdisk -v "$DEV" 2>&1 | tail -6

# ---- write the pieces ------------------------------------------------------------------------
# bs=4096, not 512: every partition start is a multiple of 8 sectors, so its byte offset is a multiple
# of 4096 and the placement stays sector-exact (boot -> sector 59392, super -> 1378328). bs=512 measured
# ~270 KB/s on this reader (queue nr_requests=2), which would take hours for super.
BS=4096
for f in "${!OFF[@]}"; do
  size=$(stat -c %s "$DIR/$f")
  count=$(( (size + BS - 1) / BS ))
  seek=$(( OFF[$f] * 512 / BS ))
  echo "dd $f -> sector ${OFF[$f]} (byte $(( OFF[$f] * 512 )), $count blocks of $BS)"
  dd if="$DIR/$f" of="$DEV" bs="$BS" seek="$seek" count="$count" conv=notrunc,fsync status=none
done
sync

# ---- read-back verification -------------------------------------------------------------------
# Drop the page cache first: after writing 3.26 GB, a plain dd read of the device is satisfied from the
# write's own cached pages, so it proves nothing about what is actually on the card.
echo "dropping page cache before verification"
sync
echo 3 > /proc/sys/vm/drop_caches
fail=0
for f in "${!OFF[@]}"; do
  size=$(stat -c %s "$DIR/$f")
  count=$(( (size + BS - 1) / BS ))
  seek=$(( OFF[$f] * 512 / BS ))
  got=$(dd if="$DEV" bs="$BS" skip="$seek" count="$count" status=none 2>/dev/null | head -c "$size" | sha256sum | cut -d' ' -f1)
  want=$(sha256sum "$DIR/$f" | cut -d' ' -f1)
  if [ "$got" = "$want" ]; then echo "  ok   $f @${OFF[$f]}"; else echo "  FAIL $f @${OFF[$f]} got ${got:0:12} want ${want:0:12}"; fail=1; fi
done
[ "$fail" = 0 ] || { echo "card verification FAILED - do not use this card"; exit 1; }

echo "card layout:"
fdisk -l "$DEV" 2>/dev/null | head -30
echo "card is ready: BootROM reads idbloader at sector 64, u-boot reads uboot at 16384, then boot/super by GPT name."
