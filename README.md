# VibeBaking Firmware — PX6 (RK3399) head-unit upgrade project

Goal: take a **Rockchip PX6 Android head unit** (HCT4 platform, currently Android 10/11 with a 2020
security patch level) and bring it to **Android 14 / LineageOS 21** while keeping the head-unit hardware
(CAN bus / MCU "MTC", radio tuner, AMP, AV-in, GPS, Bluetooth-on-UART, CarPlay bridges) working, and
without bricking the single unit we have.

## Hardware / firmware as found

| Item | Value |
|---|---|
| SoC | Rockchip PX6 = RK3399 (2×A72 + 4×A53), Mali-T620 MP4 (Midgard) GPU |
| Vendor HAL hardware name | `rk30board` (`ro.hardware`), board `rk30sdk`, platform `rk3399` |
| Device / customer | `ro.product.vendor.model=PX6`, `ro.product.customer=HCT4`, `ro.product.manufacturer9=HengChangTong`, `ro.product.model9=H660000` |
| Current OS | Android 10 (`QQ2A.200305.004.A1`), SDK 29, userdebug **test-keys**, security patch **2020-05-05** |
| Custom ROM base | **Hal9k Mod v5** (build fingerprint `eng.hct2…`, `ro.product.ota.host=ota.hal9k.ru:2300`, Magisk present in `/vendor/magisk`) |
| Kernel | Linux **4.19.111+**, Rockchip BSP, built Mar 2021, boot image header v2, `androidboot.selinux=permissive` |
| Partitions | dynamic partitions in `super` (group max 3258974208 = 3.1 GB): system 1.44 GB, product 0.93 GB, vendor 0.33 GB, odm 0.56 GB |
| Data | `/data` = F2FS with `quota`, `checkpoint=fs` |
| Flashing | Rockchip `update.zip` on FAT32 USB/SD → unit's built-in upgrade flow (`RKLoader.bin` loader + custom `update-binary` with `do_rk_firmware_upgrade()`), plus `uboot.img` / `trust.img` / `dtbo.img` written directly |

The current firmware's concrete security problems are listed in `docs/firmware-analysis.md`
(permissive SELinux, Magisk in the vendor image, world-writable `/dev/mtc-*`/`ttyS*`/`ttyV*`, adb over
TCP, 2020-05 vendor patch level, third-party OTA server).

What runs **today** is not the Hal9k build: the owner restored the unit's own firmware through the bootSD
recovery card (**D39**), and the Nov 13 probe reports
`rockchip/rk3399/rk3399:10/QQ2A.200305.004.A1/eng.hct2.20250401.152740:userdebug/release-keys` - the April
2025 OEM rebuild (`diatsia fw/update(1).zip`, `31bb492a…`) - with SELinux still Permissive and root
available through `su`. Its hashed vendor/system/product/odm surface is 126/126 identical to the Android 10
reference image (`tools/vendor_blob_check.py`), which is what makes **D44** a live question.

## Where things live

| path | what it is |
|---|---|
| `device/rk3399-px6-hct4/` | the device tree, copied into the synced Lineage tree by `scripts/deploy_device.sh` |
| `patches/` | tree patches, applied by `scripts/apply_tree_patches.sh` |
| `scripts/`, `tools/` | build / verify / flash plumbing; usage is in each file's own header |
| `scripts/archive/`, `tools/archive/` | historical one-shots whose results are recorded in `docs/decisions.md` / `docs/findings.md` - do not run blindly |
| `docs/` | see `docs/index.md` for which file is canonical |
| `analysis/` | generated dumps + tracked evidence (`*.txt`, kernel configs, partition offsets, app-layer inventory, `gpt/gpt_head.bin` + `gpt_tail.bin`) |
| `incoming/` | owner's probe reports from the live unit (tracked `*.md`) |
| `out-hu/` | workstation copies of the payload artefacts (ignored, reproducible): `update.zip` (signed payload), `super.img`, `boot.img` |
| `update.zip`, `extracted update.zip/`, `diatsia fw/` | the OEM reference packages on disk (ignored; originals also live on the NAS). Identify by sha, not name: repo-root `update.zip` = Android 10 2021 test-keys (`dd3e2ac0…`), `diatsia fw/update.zip` = Android 11 (`50775dba…`) - the OS running today - `diatsia fw/update(1).zip` = Android 10 2025 release-keys (`31bb492a…`) - the preferred rollback. All three are signed by HCT's cert `cf2ab3…`. Never confuse them with `out-hu/update.zip`, which is OUR payload (`b81c50cc…`) |
| `hal/`, `rom/` | parked shim/hardening stubs, superseded in practice by D21/D22/D23 |

Build host paths (NAS): build tree `/srv/dev-disk-by-label-SSData/aospbuild/lineage21s`, scratch
`/srv/dev-disk-by-label-SSData/aospbuild/tmp`, OEM archive
`/srv/50911774-19fb-46b6-bc9e-8cf81623d044/aospbuild-archive`.

## Workflow today

1. `scripts/package.sh <tree>` — vendor closure, deploy, dist, superimage, bootimage (`docs/build-host.md`).
2. `scripts/verify_artifacts.sh <tree>` + `scripts/verify_hu_apps.sh <tree>` — offline gates.
3. `scripts/build_hu_package.sh <tree> "extracted update.zip" <out>` — payload zip; then
   `scripts/sign_hu_package.sh <in> <out>` adds the SignApk comment signature the OEM packages use, and
   `tools/zip_comment_sig.py <zip>` reads back whatever signature a package carries.
4. Stick: route 1 = signed `update.zip` at the root (recovery install); route 2 =
   `scripts/make_flash_stick.sh <mountpoint>` for the raw-image install (`docs/flash.md`).
5. First boot: the ROM's own `/system/bin/hu_probe.sh` writes the report to the stick - no terminal needed.

## Status (Nov 13/14)

* The Android 14 build is in the tree and verified offline: apps, WiFi HAL, patched libdrm, drmservice
  and the vendor module set (D21-D24). Packaging pass and payload audit: `docs/findings.md`.
* Nov 13 probe (`incoming/probe-20261113-2016.md`, root via `su`): the firmware running today is the April
  2025 OEM rebuild, and its hashed vendor/system/product/odm surface is **byte-for-byte the Android 10
  reference** (`tools/vendor_blob_check.py`, 126/126 identical, `analysis/vendor_blob_live_vs_oem_a10.tsv`).
  The tree we stage, however, comes from the Android 11 dump and differs from the live unit in **75** paths
  (audio/composer/sensors/gps/power/vibrator/mtc/bluetooth/wifi/rild/hostapd and the vendor manifest). Which
  vendor base to ship is now **D44** and is the owner's call, because it trades proven hardware against the
  cleaner Android 14 HAL interface D9 chose.
* Route 1 (signed zip through recovery) was **rejected** on Nov 9: recovery trusts only HCT's own cert
  (`cf2ab3…`), which we do not hold (**D25**). Route 2 ran the same day and the write itself succeeded
  over TCP adb (`adbon` in the factory-settings dialog -> port 5555 -> `adb root`, **D28**), but the unit
  came up black-screen with no WiFi and no adb. The cause is measured (**D34**): the payload had **no
  first-stage fstab anywhere**, so Android 14 init never mounted `/system`. Nothing in the boot chain was
  touched, so the unit is not bricked (**D30**). Flash-attempt log, and the two `flash_from_android.sh`
  bugs that were found in it, are in `docs/findings.md`.
* Nov 11: the unit is back on **stock Android 10** through the owner's bootSD recovery card (**D39**) and
  the OEM `diatsia fw/update(1).zip`, and the working stock eMMC was pulled partition-by-partition into a
  byte-exact backup with a verified manifest (**D40**). That backup - not the factory card - is the
  rollback for the next Android 14 attempt, which writes only `boot` + `super`.
* Recovery is becoming the install tool instead of a menu nobody can drive (**D42**/**D43**): partition 8
  is patched (it is not boot chain, and `vbmeta` carries zero descriptors, so AVB cannot reject the patch)
  to run a card-driven installer that writes only `super`, `boot` and `userdata` and is inert without
  `hu-install.flag` on a card. `scripts/patch_recovery_autorun.sh` builds the image,
  `scripts/stage_hu_card.sh` stages the card, `scripts/hu_recovery_install.sh` is the installer.
* Nov 13: the installer was logic-tested offline (`scripts/smoke_recovery_installer.sh`) and **two bugs
  were fixed** - the payload-size check divided by 1000 where it meant 1024 and therefore refused every
  write, and the digest check compared manifest spellings (`sha1`) against the applet name it probed
  (`sha1sum`), so it verified nothing while reporting success. Payload sizes and digests now come from the
  card manifest. The patched recovery image on record (`a0cd9de3…`) still holds the buggy script, so
  `scripts/patch_recovery_autorun.sh` must run again before partition 8 is flashed - that splice runs on
  the build host, whose access wrapper lives outside the repo and is currently not present (`/tmp` was
  cleared). Nothing was flashed today.
* Two fixed boot images are **built and verified but not flashed** (**D33**/**D34**): `a14-fixed.img`
  (our payload + `/first_stage_ramdisk/fstab.rk30board`) and the generation-coherent
  `boot-a10k-a14rd.img` (OEM A10 kernel + OEM A10 `second` with the A10 DTB + our A14 ramdisk + fstab).
  Flashing the OEM `boot-a10.img` unchanged would **not** work - its ramdisk fstab lists only
  `system/vendor/odm/product`, no `system_ext`.
* Other measured differences (**D32**) are cleanup, not the cause: `mali_kbase.ko` reports
  `vermagic=4.4.167` (the OEM vendor ships the same bad module and Mali is built into both kernels), and
  the DTB panel-timing changes are a *vendor* A10->A11 difference, not our edit. AVB/vbmeta, uboot/trust
  mismatch, partition layout and ext4-vs-fstab are ruled out.
* The bench route is written up standalone in `docs/reanimation.md` (harness yellow+red to a **12 V /
  10 A** supply fused at 10 A, black to supply GND, a 3.3 V serial fob on `console=ttyFIQ0` at
  115200 8N1, partition sector map, serial reading order, decision tree, write routes); capture with
  `scripts/serial_console.sh log <name>`.
* Rollback payload rebuilt from `diatsia fw/update(1).zip` (**D31**) and checked with `lpdump` +
  `debugfs`. Restore by `dd` from the recovery environment or from the stock backup. Nothing has been
  burned to a physical rescue card; the bootSD archive in the NAS cold storage turns out to be Rockchip's
  SD-boot tooling only, with no Android or recovery image in it, so the patched partition 8 is what runs
  on that route (**D39**, findings Nov 12).
* The Nov 5 "62.8 GB full-eMMC snapshot" is **not** insurance: measured Nov 10 `analysis/gpt/disk.img`
  is zero except a protective-MBR remnant and the backup GPT, and `gpt_head.bin` is all zeros. The layout
  reference is `gpt_tail.bin` + the Nov 4 probe's LBA table; the content reference is the OEM packages.
* `docs/upstream.md` is the candidate register for upstream contributions - **nothing submitted yet**, and
  the verified Lineage/AOSP review and licensing rules are recorded there.
* Bluetooth is a deliberate second pass after first boot (`docs/decisions.md`, "Bluetooth route").
* No partition is ever resized or rewritten, and uboot/trust/dtb/dtbo/vbmeta/RKLoader/security are never
  written by our tooling; recovery is written only as the D42 patch (**D11**/**D18**/**D19**). Restoring
  the unit's own firmware means the OEM package or the stock backup (**D39**/**D40**).
