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
* Logical content is 2,299,031,552 B inside a 3,258,974,208 B group, so there is ~915 MiB of spare
  (Nov 8 rebuilt pass: system 1,012,834,304 / vendor 444,424,192 / product 456,159,232 / system_ext
  384,802,816 / odm 811,008 B, block-multiple resizes, no partition resize - **D19**/**D11**).
 * **The payload to try first is the signed zip**: store zip 945,046,226 B, sha256
   `b81c50cc3eb07b8b0ba5a3ab7f518d8ba2a0339801608c892bbd640e52d04407`, with
   SignApk's PKCS#7 signature in the EOCD comment (prefix `signed by SignApk\0`, cert `a40da80a…` = the
   AOSP testkey) added by `scripts/sign_hu_package.sh` using the tree's own `signapk.jar -w` and its
   prebuilt JDK. Recovery verifies that comment *before* running anything in the package, so a rejected
   zip writes no partition at all - the attempt is free. The caveat we measured (**D25**): both OEM
   packages are signed with HCT's own cert `cf2ab3…`, and `/system/etc/security/otacerts.zip` in both
   stock system images contains only that cert. If this recovery bundle is only that cert, our testkey
   signature is rejected again and the fallback below is the route.
 * **Fallback images**, for `scripts/flash_from_android.sh` from the Android 11 root shell (rebuilt Nov 8
   20:32 so they carry the same probe + adb key): `super.img` 2,275,747,780 B, sha256
   `2045af9c2d730aa5cb76df48e8a081b677ccf74a3272dbd1d2419aaf8162ff69`, and `boot.img` 32,796,672 B,
   sha256 `83fd2a15c74424e8a6c9663dfa89339a77de8ea53b9659e7e3e58819609104f8` (NAS
   `lineage21s/out/target/product/rk3399/`, workstation copies in `out-hu/`). Recovery stays untouched in
   both routes, which is what keeps the stock package installable as the rollback.

## Pre-flight

1. `scripts/verify_artifacts.sh <tree>` must pass: `VENDOR/` + `vendor.map`, the injected vendor
   libraries, super layout, VINTF `COMPATIBLE`, boot header, OTA zip. The Nov 8 pass flagged
   `flashable = NO` only on the parity flags (`vendor_diff.py` / `vendor_dropped_check.py` exit
   non-zero) - `docs/findings.md`, packaging pass Nov 8, records why those are intentional
   Android 14 drops plus one real gap (`libstagefright_softomx_plugin.so`, legacy OMX soft codecs
   only). Read that section before flashing.
2. Check the payload, then re-verify the same sha on the stick copy - a corrupt stick copy is the one
   thing a pre-flash check catches: `unzip -tqq out-hu/update.zip` is clean, `unzip -l` shows the payload
   entries plus SignApk's `META-INF/com/android/otacert`, and
   `python3 tools/zip_comment_sig.py out-hu/update.zip` reports a comment signed by cert `a40da80a…`.
   The updater-script still has zero uboot/trust/dtbo/RKLoader/loader/security/recovery writes.
3. Format the stick FAT32 and put our signed zip at the root as `update.zip`. Keep the stock packages in
   `backup/`, named by Android version so they cannot be mislabelled: `backup/a10-update.zip` (Android 10,
   1,203,718,969 B, sha256 `dd3e2ac0…`, Android 10 test-keys 2021) and `backup/a11-update.zip`
   (Android 11, 1,477,122,869 B, sha256 `50775dba…`, build.prop `RQ3A.210705.001`). Rollback = copy
   `backup/a10-update.zip` to the root as `update.zip` and install it; recovery still accepts it because
   it is signed with the cert recovery trusts.

## Install, route 1: the signed zip through recovery

1. Stick in before boot (or the power-button sequence - see "Getting into the recovery"), enter recovery,
   read the version line it prints, then install `update.zip`.
2. Watch the verification line: `E:footer is wrong` / `E:Signature verification failed` / `E:error: 21`
   means the signature check rejected the package - nothing is written, and route 2 applies. `E3004` is
   the device assert, `E2001` is a partition write failure.
3. If it installs, reboot and read the probe report off the stick (see "First boot"). The script recreates
   the logical partitions, writes system / vendor / product / system_ext / odm and `boot.img`, and wipes the
   first 8 MiB of `userdata` and `cache` so Android 14 formats `/data` fresh (**D10**).

## Install, route 2: raw images from Android 11 (**D25**)

Use this if recovery rejects the signed zip. The unit still runs its own firmware with a root shell over
TCP adb (**D28**; measured Nov 9: Android 10 `QQ2A.200305.004.A1`, not Android 11 as earlier docs assumed),
and recovery is deliberately left untouched so it keeps working as the rollback. `/data` is mounted
read-write by the running firmware, so it is not wiped here - recovery's own wipe data/factory reset does
that cleanly afterwards (**D10**).

1. Put `hu14/super.img`, `hu14/boot.img`, `hu14/flash.sh` (a copy of `scripts/flash_from_android.sh`) and
   `hu14/sha256.txt` (plain file names) on the stick; re-verify the manifest on the stick. On this unit
   `/mnt/udisk` is not mounted at all, so the equivalent is to stage the same four files on the
   workstation (`/tmp/hu/stage/hu14/`) and `adb push` them into `/data/local/tmp/hu14/`, then re-verify
   `sha256sum -c` **on the unit** before writing.
2. Get a root shell. The ROM's own su is blocked (`/system/xbin/su` exists but returns "Permission
   denied", no Magisk), so use adb - and on this unit adb only comes over the LAN (**D28**), not over a
   cable: every HU socket is host-mode, nothing enumerates, and the firmware has no developer options.
   Enter **`adbon`** in the HU's factory-settings dialog (instead of `126`) - that sets
   `persist.internet_adb_enable=1`, and the OEM init then opens TCP adb on port 5555. From the workstation:

   ```
   adb connect 192.168.1.120:5555
   adb root                                   # uid 0, context u:r:su:s0, no auth prompt
   adb -s 192.168.1.120:5555 shell id
   adb -s 192.168.1.120:5555 push hu14 /data/local/tmp/   # or push the four files individually
   adb -s 192.168.1.120:5555 shell "sync; STICK=/data/local/tmp sh /data/local/tmp/hu14/flash.sh"
   ```

   With no stick mounted, `STICK=/data/local/tmp` is what the script expects (`SRC=$STICK/hu14`,
   `BACKUP=$STICK/hu14-backup`) - backups then land in userdata, which survives a `super` rewrite. Pull
   them back to the workstation with `adb pull` **before** writing anything; `super.img` is 2.27 GB and
   pushes at ~3.2 MB/s over TCP, so budget ~11 minutes each way. The script verifies the images against
   `sha256.txt`, backs up the head and tail of `super` plus the current `boot` partition, then `dd`s
   `super.img` to `/dev/block/by-name/super` (Android 14's system/vendor/product/system_ext/odm plus its
   dynamic-partition metadata, all inside super) and `boot.img` to `/dev/block/by-name/boot`. Two
   partitions only: no recovery, uboot, trust, dtbo, RKLoader, logo, security or GPT write, no resize
   (**D11**/**D19**). Log: `$SRC/hu14-flash.log`.
   Two script bugs were found by running it on Nov 9 and both are fixed in
   `scripts/flash_from_android.sh`: Android's mksh does 32-bit arithmetic, so a partition size above
   2 GiB wraps negative and the size guard aborted a valid image (now compared in awk); and the tail
   backup used a byte value as `dd skip=` with `bs=4096`, which is a *block* count (`Can't skip`) - the
   correct skip is `792576` blocks. Read `docs/findings.md`, "Flash attempt Nov 9/10", before flashing.
3. Reboot into recovery, run **wipe data/factory reset**, reboot with the stick still in; the auto-probe
   writes `hu-probe-<ts>.md` to the stick (`/data/local/tmp/hu-probe-<ts>.md` and `/dev/kmsg` fallbacks).
4. If it does not boot, and the recovery menu cannot be reached (Nov 9: no button combo the owner tried
   reaches it), the rollback must be **blind** (**D29**): either a serial console (`console=ttyFIQ0`,
   115200 8N1, 3.3 V) with a root shell that `dd`s the OEM `super`/`boot` back, or a bootable SD card that
   the untouched u-boot flashes (`rkimg_bootdev=if mmc dev 1 && rkimgtest mmc 1`, `sdfwupdate`) - which
   touches the loader/IDB, so it stays gated on verifying that `fw_update=2` skips that write. The card
   goes in the **sdmmc** slot: `dwmmc@fe320000` = Android `sdcard1` = u-boot `mmc 1`, not the recovery
   slot `dwmmc@fe310000` = `sdcard2`.

## Nov 9 attempt: route 2 ran, the write succeeded, Android 14 did not bring up the panel

The full log with timestamps and every captured command is in `docs/findings.md`, "Flash attempt Nov 9/10".
The operator-relevant consequences:

* `adbon` in the factory-settings dialog opened TCP adb and `adb root` gave uid 0 - route 2 works exactly
  as written above, and the images were verified on the unit before writing.
* The write itself completed: `super` 2,275,747,780 B at 64 MB/s, `boot` 32,796,672 B at 33 MB/s. Only
  those two partitions.
* After it: **black screen, no boot animation, no OEM logo**, WiFi gone (`No route to host`), TCP adb dead,
  no recovery menu. So the transport died with the old OS - Android 14 cannot recover Android 10's Wi-Fi
  credentials and `persist.internet_adb_enable=1` lives in `/data`, which Android 14 formats fresh (**D10**).
  A shell on first boot therefore cannot be assumed; if one appears it comes from the stick copy or
  `/dev/kmsg`, not from TCP adb.
* Nothing that could brick the unit was written (`uboot`, `trust`, `dtb`, `dtbo`, `recovery`, `vbmeta`,
  loader, GPT all untouched), so the boot chain is intact and the unit is recoverable by a blind path.
* Do not flash a second payload without a serial console reading first (**D30**; defect list **D32**,
  generation mismatch **D33**, missing first-stage fstab **D34**). Primary cause, measured: our payload has
  **no fstab source** for first-stage mount - Android 14 init wants `/proc/device-tree/firmware/android/fstab`
  or `/first_stage_ramdisk/fstab.rk30board` (it matches `androidboot.hardware=rk30board`), our DTB has no
  `fstab` node, the untouched A10 `dtbo` overlay (803 B, `28a07d49…`) adds `vbmeta`/`fstab` children marked
  `status = "disabled"`, and our ramdisk contains no `first_stage_ramdisk/` and no `fstab*` file. So
  `failed to read default fstab for first stage mount` -> `/system` never mounted -> no display, no WiFi, no
  adbd. Second-order: our kernel/DTB are the vendor **A11** pair (`ec3b6631…` / `530b8412…`) on the unit's
  **A10**-era chain (the vendor's A11 script also writes `boot`, `trust`, `uboot`, `logo`, `dtbo` and the
  loader; the A11 overlay `607 B` `ec0ae97c…` lacks the disable-`vbmeta`/`fstab` fragment). `mali_kbase.ko`
  (`vermagic=4.4.167`) is cleanup, not the cause; AVB/vbmeta, uboot/trust mismatch, partition layout and
  ext4-vs-fstab are ruled out. Console reading order: init's fstab messages first
  (`First stage mount skipped (missing/incompatible/empty fstab in device tree)`,
  `failed to read default fstab for first stage mount`), then which DTB u-boot used (`Found DTB in <part>` vs
  `dtb size`/`dtb addr`), whether the `dtbo` overlay applied, then kernel panel/timing messages, then init
  stage 2 and SurfaceFlinger. Which boot image the card/recovery flow actually writes is measured Nov 15:
  `scripts/stage_hu_card.sh:36`, `scripts/stage_a14_payload.sh:21`,
  `scripts/build_recovery_fallback_zip.sh:72` and the recovery installer all take
  **`a14chk/a14-boot-fixed.img`** (kernel payload 30,455,816 B = the vendor **Android 11** kernel
  `4.19.193 #24`, sha `933e2ecc…`), and our A14 super ships `.ko` files at `vermagic=4.19.193` - a coherent
  pair. That is **shape B**, the fallback (**D46**).

  **Shape A** (the primary, Nov 15) ships `a14-work/a14chk-shapeA/boot-a10k-a14rd.img`: 28,233,728 B,
  sha `3cf4012980d0a824c37ed3f24982a9c7e50d2c8c8497030be139e1184a647375`, kernel payload 25,671,688 B = the
  OEM **Android 10** kernel `4.19.111+ #190`, our Android 14 first-stage ramdisk with
  `first_stage_ramdisk/fstab.rk30board` (4,190 B), the OEM `second` stage 924,672 B carrying the HCT DTB
  (`d0 0d fe ed` at 27,310,080, size 152,425), header v2 with `dtb_size 0`. It pairs with the stock
  `4.19.111+` module set (the 19 `.ko` in `a14-work/hu-stock-backup/vendor-modules/`) and with a vendor
  manifest at `target-level="4"` - and **no `<kernel>` tag** is added, because libvintf only checks kernel
  compatibility when the manifest declares one (**D46**).

  The earlier `a14chk/boot-a10k-a14rd.img` (sha head `455a9ac8…`, 28,231,292 B) is **malformed and unusable**:
  `rebuild_boot_with_fstab.sh` sliced the components at the 1660-byte header size instead of at the page
  boundary, so its `second` stage landed at 27,309,144 while a boot loader computes 27,308,032 and would read
  padding instead of the DTB (**D38**). It is kept as `a14chk/boot-a10k-a14rd.img.stale-misplaced-second` for
  the record; regenerate with the fixed script rather than reusing it. Do **not** flash the OEM `boot-a10.img`
  unchanged: its ramdisk fstab has no `system_ext`, which Android 14 needs. Writing either chain is gated on
  the offline gate set (**D47**), with the stock backup and rescue card staged first.

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

**Measured on our unit (Nov 9):** none of these reached the menu. With the payload already written, the
owner power-cycled the unit and tried button combos including the reset pinhole - no recovery menu, no
logo, no animation, screen fully black. So treat recovery as **unreachable** here and plan the blind
rollback (**D29**) instead of counting on it; the SD-card-before-boot trick could not be evaluated because
there was no display to read an offer on.

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

1. Boot Android 14. The build ships **no terminal and no su**, so the report comes to you without a
   shell: `/system/etc/init/hu_probe.rc` runs `/system/bin/hu_probe.sh` as root when boot completes and
   waits ~2 min for the stick to mount. The dump then lands in three places - `/mnt/udisk/hu-probe-<ts>.md`
   (the stick that carried `update.zip`, read it on the workstation), `/data/local/tmp/hu-probe-<ts>.md`
   (pullable with `adb pull`, no root needed), and stdout into `/dev/kmsg` (`dmesg` over adb or the FIQ
   serial console, `console=ttyFIQ0`). USB adb needs no auth prompt once our key is in `/data/adb/adb_keys`
   (the probe injects `/system/etc/hu_adb_key.pub` at boot; `ro.adb.secure` stays 1), and `adb root` works
   because `ro.debuggable=1`. If you get a shell and WiFi is up, run
   `sh /system/bin/hu_probe.sh http://<workstation>:9000` (workstation side `nc -l 9000 > report.md`) or
   `setprop persist.hu.probe.url http://<workstation>:9000/` before a reboot. The report covers boot, WiFi
   (`wlan0` under `fe3c0000.usb`, `iw reg`), Bluetooth (expected empty in v1 - D24), touch/buttons
   (`getevent -L`, `/dev/mtc-*`), CANBUS (`/dev/mtc-car`, `HCTCanBus`), audio (`audio.primary.rk30board.so`,
   `/proc/asound/cards`) and the error/warning logcat lines per subsystem, plus `CANNOT LINK` lines from
   `dmesg` (the gocsdk/sdsdk ABI gap, D24).
2. Judge the hardware before anything else: display, audio/AMP, tuner, CAN/MTC, AV-in, GPS, Bluetooth,
   wired CarPlay/AA. If the unit boots, the recovery/bootloader were never touched and everything
   below is reversible.
3. Only after that: consider writing our own recovery (a separate decision, needing proof the board
   can drive it), and later updates go through `docs/ota.md`.

## Rollback

Rollback package choice (Nov 9): the vendor's 2025 Android 10 rebuild -
`diatsia fw/update(1).zip`, 1,285,817,036 B, sha256 `31bb492ab6036dd10a9dc9c33be900af23499eef049a260bf267b166f239db4c`,
release-keys, signed by the same cert the recovery trusts - is newer than the 2021 package and installs
through the untouched stock recovery. Prefer it if a rollback is ever needed; put it on the stick as
`backup/a10-2025-update.zip`. Identity of every package on disk: `docs/findings.md`, "OEM reference
packages on disk".

Owner's decision (Nov 6): no rollback tooling. Flash the **stock Android 10 `update.zip`** the same
way - root of the stick, stock recovery - and it recreates the stock logical partitions
(`rockchip_dynamic_partitions`, no `system_ext`), writes the stock boot/trust/uboot/dtbo and re-runs its
own loader step. The unit returns to Android 10 at factory settings. Nothing in this repo rebuilds an
Android 10 super or dumps partitions; `tools/reassemble.py` stays only because it is how the stock
payload was decoded in `docs/firmware-analysis.md`.

**Nov 10 revision.** That plan needs the recovery menu, and the menu is unreachable on this unit, so the
rollback is now blind (**D29**). The payload to write is rebuilt from the vendor's April 2025 Android 10
package (**D31**), not from a dump: `super-a10.img` 3,263,168,512 B sha `30da961c…` and `boot-a10.img`
27,406,336 B sha `04a43ea9…`, both in the NAS archive
`/srv/50911774-19fb-46b6-bc9e-8cf81623d044/aospbuild-archive/vibe-rescue/`. Serial-console `dd` of those
two files restores Android 10; the bootable SD card (**D31**) carries the same two files plus a rescue
initramfs that `dd`s them, so the restore also works with no shell at all. The stock packages stay on the
stick in `backup/` for the day a menu does appear. **The 62.8 GB "full-eMMC snapshot" is not insurance** -
measured Nov 10 it is zero except the backup GPT (`docs/findings.md`), which is why the payload had to be
rebuilt; `analysis/gpt/gpt_tail.bin` plus the Nov 4 probe's LBA table remain the layout reference. The
extraction work is done: `brotli` on the `.new.dat.br` payloads, `tools/reassemble.py` for the transfer
lists, `lpmake` for the super, verified with `lpdump` + `debugfs`.

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
