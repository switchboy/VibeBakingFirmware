# Installing Android 14 with the unit's own `update.zip` flow

The install path is the one the head unit already has: an `update.zip` at the root of a USB/SD stick,
installed by the **stock** recovery using the **stock** `update-binary`. We build the payload files
that binary understands and reuse its own script vocabulary - nothing is invented, no partition is
resized, and the recovery, bootloader and mainboard firmware are never written (**D18**).

## Why we do not touch recovery or the bootloader

The PX6 sits as a card on a mainboard with its own MCU firmware. The community reports that this unit
has no custom recovery, and the most likely reason is that the stock recovery is the only thing able
to flash that mainboard firmware: the stock package's own `write_raw_loader_image()` step runs in it,
with `/tmp/RKLoader.bin` as the loader image. We cannot verify that a *custom* recovery would boot,
show a prompt, and read touch or button input on this board - and if it does not, the unit is a brick.
So our recovery image is built and verified but **not flashed**; it is for later, once Android 14
boots and we know the unit is alive.

Consequently the payload's updater-script omits everything the stock script does to the boot chain:
no `uboot.img`, no `trust.img`, no `dtbo.img`, no `RKLoader.bin`, no `write_raw_loader_image()`, and
no wipe of `/dev/block/by-name/security`. Those files are copied into the zip byte-identical from the
stock package so a diff of the package stays honest, but the script never writes them.

## What the payload is

`scripts/build_hu_package.sh <lineage-tree> "extracted update.zip" <out-zip>` produces a zip with
the stock layout:

```
META-INF/com/google/android/updater-script   ours, stock vocabulary only
META-INF/com/google/android/update-binary    the stock binary, unmodified
dynamic_partitions_op_list                   our Android 14 layout, same super size and group size
<part>.transfer.list / <part>.new.dat.br / <part>.patch.dat   system vendor product system_ext odm
boot.img                                     Android 14 kernel + ramdisk + vendor DTB + RSCE logo
uboot.img trust.img dtbo.img RKLoader.bin    stock bytes, present but never written
```

* `dynamic_partitions_op_list` recreates the logical partitions inside `/dev/block/by-name/super`.
  The GPT is untouched (**D11**): p14 stays 3,263,168,512 B, the group stays 3,258,974,208 B. Only
  the partition list and sizes change, and Android 14 adds `system_ext`, which stock did not have.
* `.patch.dat` is empty and each transfer list is one `flash` command: an unconditional full write,
  exactly like the stock package.
* Logical content is 2,182,987,776 B inside a 3,258,974,208 B group, so there is ~1.07 GiB of spare.

## Pre-flight

1. `scripts/verify_artifacts.sh <tree>` must pass: `VENDOR/` + `vendor.map`, the injected vendor
   libraries, super layout, VINTF `COMPATIBLE`, boot header, OTA zip.
2. Build the package and check it: `scripts/build_hu_package.sh ../lineage21s "extracted update.zip"
   ../tmp/hu-package/update.zip`, then `unzip -l` and the sha256 it prints. Record the sha256.
3. Format the stick FAT32 and put `update.zip` in its **root**.
4. Keep the stock Android 10 `update.zip` file (the one in `incoming/`, or whatever the vendor ships).
   That is the whole rollback story: owner's decision on Nov 6 - if Android 14 turns out wrong, flash
   the official update.zip the same way. No partition dumps, no rebuilt Android 10 super, no rollback
   scripts - keeping the zip is enough because the stock package recreates the stock layout and runs its
   own loader step.

## Installing

Owner's route (needs confirming against XDA before the first attempt): a `update.zip` in the root of a
flash drive prompts the unit to install, and the unit boots into recovery for you; there is also a
"reboot recovery" app and a key combination. Confirm which one works on this unit before relying on
it - if neither reaches the stock recovery, stop and do not attempt the fastboot fallback yet.

Then: select the update package, let it run, and reboot. The script asserts
`ro.product.device == "rk3399"`, recreates the logical partitions, writes system / vendor / product /
system_ext / odm, writes `boot.img`, and wipes the first 8 MiB of `userdata` and `cache` so Android 14
formats `/data` fresh (Android 10's data, vold metadata and app data are not readable by Android 14 -
factory settings, accepted for v1 per **D10**).

Watch for `E2001`/`E3004` in the recovery output: `E3004` means the device assert failed, `E2001`
means a partition write failed. If `update_dynamic_partitions` refuses the group rename or the new
`system_ext` partition, the updater aborts before any image is written - that is a safe failure and
tells us the stock updater cannot carry Android 14's layout, which is then a decision point, not a
brick.

## First boot

1. Boot Android 14 and run the SD-card probe (`sh allinone.sh` - no adb, no root) to read partition
   sizes and the HAL list; compare with `misc_info.txt`.
2. Judge the hardware before anything else: display, audio/AMP, tuner, CAN/MTC, AV-in, GPS, Bluetooth,
   wired CarPlay/AA. If the unit boots, the recovery/bootloader were never touched and everything
   below is reversible.
3. Only after that: consider writing our own recovery (a separate decision, needing proof the board
   can drive it), and later updates go through `docs/ota.md`.

## Rollback

Owner's decision (Nov 6): no rollback tooling. Flash the **stock Android 10 `update.zip`** the same
way - root of the stick, stock recovery - and it recreates the stock logical partitions
(`rockchip_dynamic_partitions`, no `system_ext`), writes the stock boot/trust/uboot/dtbo and re-runs its
own loader step. The unit returns to Android 10 at factory settings. Nothing in this repo rebuilds an
Android 10 super or dumps partitions; `tools/reassemble.py` stays only because it is how the stock
payload was decoded in `docs/firmware-analysis.md`.

## Fastboot is not used

Owner confirmed there is no Rockchip loader/Boot-ADB entry, so fastboot in the ABL was the only other
transport. It is not used (**D18**): it writes `recovery` and `boot` while bypassing the stock
recovery's loader step, which may be the sole route to the mainboard MCU firmware. Its scripts were
removed on Nov 6 - if the update.zip route ever proves impossible that is a fresh decision, not a
fallback to reach for.
