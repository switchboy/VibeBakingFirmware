# First flash: fastboot (the PX6 HU has no loader/Boot-ADB)

The very first `boot`, `recovery` and `super` write cannot come from an OTA (there is no LineageOS
recovery yet), so it goes through **fastboot** in the Android 10 ABL. Owner confirmation (Nov 6):
this board has *no* Rockchip loader/Boot-ADB entry - only fastboot and the stock recovery. So
fastboot is the only first-write path, and the backup below is not optional: without it there is no
way back. Everything else in this repo (OTA zip, `docs/ota.md`) applies later and never touches the
partition table again (**D11**: the GPT stays as it is).

## Pre-flight, in the running Android 10 (no loader needed)

The stock firmware is `userdebug` with test-keys, so plain adb works and `adb root` is allowed.

```
adb devices                      # the HU over USB or over LAN (adb connect <ip>:5555)
adb root                         # needed for the partition dumps
adb shell id                     # must say uid=0
adb shell 'ls -l /dev/block/by-name/'   # names must include super/boot/recovery/misc/metadata
adb shell 'cat /proc/partitions'         # mmcblk2 = 122683392 sectors
adb reboot bootloader            # ABL fastboot mode
fastboot devices
fastboot getvar all              # record this; needs partition-size:super, :boot, :recovery
```

If `getvar` lists no `partition-size:super`, fastboot cannot write the 3.26 GB super block: then use
the logical-partition fallback further down instead, and do not try to force it.

## Backup first - the only rollback path on this single unit

Do this **before** entering fastboot, from the running Android 10 with root. Pull everything back to
the workstation and re-check the sizes; keep the folder out of git (it is device data).

```
adb shell 'dd if=/dev/block/mmcblk2 of=/tmp/backup_head.bin bs=1 count=17408 conv=notrunc'
adb shell 'dd if=/dev/block/mmcblk2 of=/tmp/backup_tail.bin bs=1 skip=<disk_bytes-16896> count=16896'
adb shell 'for p in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do dd if=/dev/block/mmcblk2p$p of=/tmp/p$p.bin bs=1M; done'
adb pull /tmp/
adb shell 'sha256sum /tmp/backup_*.bin /tmp/p*.bin'   # compare with the workstation copy
```

Also build the stock Android 10 super so restoring super is a single write:
`scripts/build_rollback_super.sh "extracted update.zip" <outdir>` → `super_stock.img` +
`sha256sums-rollback.txt`. Use the unit's own dumps for `boot`/`recovery` (the installed firmware is
not guaranteed byte-identical to the package).

## Staging the images

`scripts/verify_artifacts.sh <tree>` must pass first (VENDOR/ + vendor.map, every stock blob,
super layout, VINTF COMPATIBLE, boot header, recovery installer, OTA zip). Then
`scripts/stage_flash.sh <tree> <outdir>` converts `super.img` out of Android's sparse format, checks
every size against the unit's real partitions (`analysis/hu_partition_offsets.txt`) and refuses a
folder whose three images come from different packaging passes. fastboot wants the raw files:

```
<outdir>/super.img     raw, 3,263,168,512 B
<outdir>/boot.img      33,554,432 B partition (p7)
<outdir>/recovery.img  100,663,296 B partition (p8)
<outdir>/sha256sums.txt
```

`boot.img` carries the vendor kernel, our Android 14 ramdisk, the vendor DTB and the Rockchip RSCE
boot logo (`docs/build-host.md`); there is nothing else to write: `dtbo` (p5) and `vbmeta` (p6) keep
their content - we build neither, and the board boots `verifiedbootstate=orange` anyway. No `logo`
partition exists on this unit.

## Flashing

Use `scripts/fastboot_flash.sh <staged-dir> <backup-dir>` - it refuses to run without the backup
dumps, re-checks the staged set for freshness, compares each image with the partition size the ABL
reports, and stops if `partition-size:super` is missing (then use the fallback below). Manual order,
for reference:

Order matters only in one respect: write `super` before `boot`/`recovery`, so the OS you boot into
always matches the recovery next to it. Sizes come from `getvar`, not from guesses.

```
fastboot flash super    <outdir>/super.img      # 3.26 GB, takes a few minutes over USB
fastboot flash boot     <outdir>/boot.img
fastboot flash recovery <outdir>/recovery.img
fastboot reboot
```

Nothing else: no `--wipe` of `userdata`, no GPT write, no `dtbo`, no `vbmeta`, no `misc` (update_engine
reads it and we do not need to reset it; recovery wipes data itself).

**Fallback if fastboot rejects `super`** (no `partition-size:super`, or the write errors): flash the
logical partitions instead, which ABL supports. Write all five, then boot:

```
fastboot flash system      out/target/product/rk3399/system.img
fastboot flash vendor      out/target/product/rk3399/vendor.img
fastboot flash product     out/target/product/rk3399/product.img
fastboot flash system_ext  out/target/product/rk3399/system_ext.img
fastboot flash odm         out/target/product/rk3399/odm.img
fastboot flash boot        <outdir>/boot.img
fastboot flash recovery    <outdir>/recovery.img
```

This leaves super's metadata (group size, extents) untouched, so it only works while the logical
partitions keep their current sizes - check `lpdump -d` against the extents in
`docs/repartition.md` before choosing it. Repartitioning (**D8/D11**) is a separate step with its own
GPT blobs and must not be mixed into the first flash.

## First boot

1. Boot Android 14, confirm the partition sizes with the SD-card probe (`sh allinone.sh` - no adb, no
   root) and compare them with `misc_info.txt`.
2. Boot into **our** recovery (`adb reboot recovery`, or the recovery key if the unit has one) and
   wipe data so `userdata` is formatted for Android 14 (**D10**: factory settings, apps and data are
   expected to be lost).
3. Only then judge the features: audio/AMP, tuner, CAN/MTC, AV-in, GPS, Bluetooth, wired CarPlay/AA.
   The install path for later updates is recovery "Local update" from SD/USB (`docs/ota.md`).

## Rollback

`scripts/fastboot_rollback.sh <backup-dir>` (add `--super <super_stock.img>` to restore the rebuilt
Android 10 super instead of the unit's own dump). Two independent restore paths, both mechanical,
both through fastboot:

1. **What the unit had** - `backup_head.bin` / `backup_tail.bin` (GPT) and `p1.bin`..`p15.bin` from
   the dump above, plus boot/recovery byte-for-byte:
   ```
   fastboot flash super    <work>/p14.bin     # or the stock super below
   fastboot flash boot     <work>/p7.bin
   fastboot flash recovery <work>/p8.bin
   ```
   For the GPT dumps there is no fastboot partition; write them back with dd only if you actually
   changed the table (you should not have: **D11**).
2. **A rebuilt Android 10 super** - `super_stock.img` from `scripts/build_rollback_super.sh`
   (group `rockchip_dynamic_partitions`, 3,258,974,208 B, content 3,125,321,728 B):
   ```
   fastboot flash super <rollback-dir>/super_stock.img
   ```

The unit ends up at factory settings either way (D10) - nothing but a brick would be unrecoverable.

## What we do not use

Rockchip's `upgrade_tool` / Boot-ADB loader: this board has no loader entry (owner confirmation), and
the payload's `RKLoader.bin` is the stock update tool's own loader image, not something we can reach.
`update_engine` cannot create partitions, only logical ones inside `super`. TWRP is not needed and
there is no working recovery to install it into until our own recovery exists.
