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

## Getting into the recovery

Three routes are reported for PX6/RK3399 head units; they are not guesses, they are what owners did:

* **Stick in before boot.** `update.zip` at the root of a FAT32 USB stick or SD card, inserted before
  powering on: the unit offers the update, and on units that no longer show the menu the recovery menu
  comes back with the card inserted. Iker Gomez (Dasaita forum, 7 Jul 2022) lists it as the recovery
  recovery method: "on a FAT32 formatted SDcard just copy the A10 OTA file (update.zip) and reboot with
  the Sdcard inserted... Some guys reported that after inserting the SDCARD and booting... the recovery
  menu was again accessible". This is the owner's route and the one our payload is built for.
* **Power-button sequence.** Long press the power key, wait for the unit to flash about five times,
  release and press again - that reached a recovery with an "install update" entry on a PX6 Android 10
  unit (alfondehesa, XDA, 22 Jul 2020). Units with no hardware buttons only have the reset key: holding
  it ~10 s did *not* bring the menu back on the unit that went black-screen in the Dasaita thread.
* **The menu tells its own version.** The third line of the recovery menu prints the build, so before
  flashing anything, read that line and check the package is something that recovery can apply.

The stock `update-binary` is not a plain AOSP updater: it carries Rockchip's USB OTA module
(`CRKUsbComm`, `emmc_point`, `/mnt/scratch`, `drmboot.ko`) and the loader step ("Start to update loader
from update.zip"), which is why a stick at the root of a card is picked up at all. That is also the
reason it must stay byte-for-byte the stock binary (**D18**).

**The known hazard on this platform.** Dasaita's own rule is that an OTA file must match the Android
major version already installed - "you can NEVER upgrade the Android 10 to Android 11 by means of OTA
files.... you can corrupt your boot system". In that thread a unit that was flashed with an Android 11
package ended stuck at the logo, and a further package left it black-screen with no recovery. Those
packages write `uboot.img`, `trust.img`, `dtbo.img` and the loader (`write_raw_loader_image()`), i.e. a
boot chain from a different variant. Our payload deliberately never writes those (see above), so the
observed brick is not our path - but we are still crossing a major version through a recovery built for
Android 10, which no offline check can prove. Before the first flash: read the recovery menu's version
line, and confirm the route on XDA/Dasaita for this exact unit.

Then: select the update package, let it run, and reboot. The script asserts
`ro.product.device == "rk3399"`, recreates the logical partitions, writes system / vendor / product /
system_ext / odm, writes `boot.img`, and wipes the first 8 MiB of `userdata` and `cache` so Android 14
formats `/data` fresh (Android 10's data, vold metadata and app data are not readable by Android 14 -
factory settings, accepted for v1 per **D10**).

Watch for `E2001`/`E3004` in the recovery output: `E3004` means the device assert failed, `E2001`
means a partition write failed. `dynamic_partitions_op_list` does not rename anything: it is the stock
vocabulary - `remove scratch`, `remove_all_groups`, then `add_group hct_dynamic_partitions 3258974208`,
`add` and `resize` per partition, with `system_ext` as a fifth partition. If `update_dynamic_partitions`
refuses that op list, the updater aborts before any image is written - a safe failure that tells us the
stock updater cannot carry Android 14's layout, which is then a decision point, not a brick.

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

## If the unit ever stops booting

The last resort on this SoC is MASKROM, and it does exist on the PX6 - it is just not reachable through
the unit's own ports, which is what the owner checked (**D14**). The community route is: open the case,
get at the PX6 board, connect it over USB with a made cable (XDA's PX3/PX5 thread, and the PX6 pinout on
page 2 of the PX6 MASKROM thread, t3989407), short two pins to enter MASKROM, then flash a full
`update.img` with AndroidTool. Shorting pins on some boards instead enters the *recovery* menu
(skipraider, XDA, 22 Jul 2020). Dasaita's support answer for a unit that will not boot is the same
escalation: card-with-`update.zip` first, then a full image, then "a complete flashing (you will need a
USBA to USBA cable)".

A MASKROM flash writes the whole boot chain (uboot, trust, dtbo, loader) from whatever `update.img` is
chosen, so it is outside **D18** and outside this repo's tooling: it is a rescue operation for a
bricked unit, not an install transport, and it needs the board opened and soldering. Nothing here
shorts pins or writes loader images.
