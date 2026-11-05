# First flash: Rockchip Loader / Boot-ADB

The very first `boot`, `recovery`, `super` and GPT write cannot come from an OTA (there is no
LineageOS recovery yet), so it goes through Rockchip's Loader mode. Everything else in this repo
(OTA zip, `docs/ota.md`) applies later and never touches the partition table again.

## Entering Loader mode on the PX6 HU

1. Put the unit on 12 V/battery power with the eMMC attached, and connect the USB OTG port (the
   same micro-USB port CarPlay/AA uses) to the workstation with a data cable.
2. Hold the RESET button (or the maskrom/reset pad, if the board has one) while plugging the cable
   in, keep holding a few seconds. The board enumerates as a Rockchip device instead of booting.
3. Check from the workstation:
   ```
   adb devices            # Boot-ADB loader shows up as an adb device
   lsusb -v | grep -i -A4 'rockchip\|2e8a'   # loader VID if adb shows nothing
   ```
   **Unknown and needs your confirmation**: whether this board has a maskrom pad/jumper and which
   button is RESET. If adb shows nothing in loader mode, we need Rockchip's `upgrade_tool`
   ("Device Tool") instead, which is proprietary and not in Debian - tell me and I'll ask for it.

## Flashing through Boot-ADB

Boot-ADB is a tiny shell in the loader that can reach the eMMC as block devices, so plain `dd`
works. Stage the images first (`scripts/stage_flash.sh <tree> <outdir>` converts `super.img` out of
Android's sparse format and checks every size against the real partitions), then push:

```
adb push <outdir>/super.img    /tmp/     # raw, 3,263,168,512 B - the push takes a while
adb push <outdir>/boot.img     /tmp/
adb push <outdir>/recovery.img /tmp/
adb push <outdir>/sha256sums.txt /tmp/   # verify with sha256sum in the loader shell before dd
# Only when repartitioning (D11 option B): also copy analysis/gpt/gpt_head.bin and gpt_tail.bin.
```

`boot.img` carries the vendor kernel, our Android 14 ramdisk, the vendor DTB and the Rockchip RSCE
boot logo (see `docs/build-host.md`), so there is nothing else to flash: `dtbo` (p5) and `vbmeta`
(p6) keep their current content - we do not build either, and the board boots with
`verifiedbootstate=orange` anyway. There is no `logo` partition on this unit.

Then, in order, on-device (`adb shell`):

1. **Backup first** (this is the only rollback path on one unit):
   ```
   dd if=/dev/block/mmcblk2 of=/tmp/backup_head.bin bs=1 count=17408 conv=notrunc
   dd if=/dev/block/mmcblk2 of=/tmp/backup_tail.bin bs=1 skip=<disk_bytes-16896> count=16896
   for p in 1 2 3 4 5 6 7 8 9 10 11 12 13; do dd if=/dev/block/mmcblk2p$p of=/tmp/p$p.bin bs=1M; done
   adb pull /tmp/            # copy everything back to the workstation and verify the sizes
   ```
2. Partition table - **only if you repartition now (D11 option B)**. Keeping the current layout
   (option A, recommended for the first flash) means skipping this step: build super for
   3,263,168,512 B (`docs/repartition.md`) and step 3 writes into the existing p14.
   ```
   dd if=/tmp/gpt_head.bin of=/dev/block/mmcblk2 bs=1 count=17408 conv=notrunc
   dd if=/tmp/gpt_tail.bin of=/dev/block/mmcblk2 bs=1 seek=<disk_bytes-16896> conv=notrunc
   ```
3. Images. Before the repartition these numbers are what the unit has (super=p14, boot=p7,
   recovery=p8); after a new GPT they change, so prefer the names if Boot-ADB exposes
   `/dev/block/by-name/` (check with `ls /dev/block/by-name/` first):
   ```
   dd if=/tmp/super.img    of=/dev/block/mmcblk2p14 bs=1M    # or by-name/super
   dd if=/tmp/boot.img     of=/dev/block/mmcblk2p7  bs=1M    # or by-name/boot
   dd if=/tmp/recovery.img of=/dev/block/mmcblk2p8  bs=1M    # or by-name/recovery
   ```
4. Power off, reboot, confirm the sizes from sysfs without root (`sh allinone.sh` on the SD
   card does that), then boot into our recovery and wipe data so `userdata` is formatted as f2fs. If
   the table was resized, `mkfs.f2fs /dev/block/by-name/userdata` before that wipe.

## Rollback

Two independent restore paths, both mechanical:

1. **What the unit had** - the `backup_head.bin` / `backup_tail.bin` (GPT) and `p1.bin`..`p13.bin`
   dumps taken in step 1 above. Pull them back to the workstation and check the sizes before you
   flash anything new. This restores boot/recovery/misc exactly as they were, byte for byte.
2. **A rebuilt Android 10 super** - `scripts/build_rollback_super.sh <extracted-package-dir> <out-dir>`
   re-assembles the stock package's logical images into one raw `super_stock.img` (group
   `rockchip_dynamic_partitions` 3,258,974,208 B, content 3,125,321,728 B) plus
   `sha256sums-rollback.txt`, so restoring super is a single `dd`:
   ```
   dd if=/tmp/super_stock.img of=/dev/block/mmcblk2p14 bs=1M    # or by-name/super
   ```
   Use the unit's own dumps for `boot`/`recovery`; the package's `boot.img` is only a convenience,
   because the installed firmware is not guaranteed to be byte-identical to the package.

The unit ends up at factory settings either way (D10) - nothing but a brick would be unrecoverable.

## What we do not use

`update_engine` cannot create partitions, only logical ones inside `super`; `fastboot` is not
present in this loader. TWRP is not needed (and there is no working recovery to install it into
until our own recovery exists).
