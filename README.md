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

## Status (Nov 9/10)

* Apps, WiFi HAL, libdrm, drmservice and the vendor module set are in the tree and verified offline
  (D21-D24). Packaging pass and payload audit: `docs/findings.md`.
* Route 1 (signed zip through recovery) was **rejected** on Nov 9: `E:footer is wrong`,
  `E:Signature verification failed`, `E:error: 21` - recovery trusts only HCT's own cert
  (`cf2ab3…`), which we do not hold (**D25**).
* Route 2 ran on Nov 9 and **the write succeeded**: `super` (2,275,747,780 B) and `boot` (32,796,672 B)
  were flashed with verified shas over TCP adb (`adbon` in the factory-settings dialog -> port 5555 ->
  `adb root`, **D28**). Access details, timestamps and the two `flash_from_android.sh` bugs (mksh 32-bit
  arithmetic, `dd skip=` in block units) are in `docs/findings.md`, "Flash attempt Nov 9/10".
* Result: **black screen, no boot animation, no OEM logo**, WiFi gone, TCP adb dead, no recovery menu
  reachable by any button combo. The unit is *not* bricked - `uboot`, `trust`, `dtb`, `dtbo`, `recovery`,
  `vbmeta`, the loader and the GPT were never touched, so the OEM boot chain is intact (**D30**).
* The cause is measured (**D34**): our payload has **no first-stage fstab anywhere**, so Android 14 init
  cannot mount `/system` at all and nothing ever starts. Android 12+ reads the first-stage fstab from the
  devicetree (`/proc/device-tree/firmware/android/fstab`) or from the ramdisk at
  `/first_stage_ramdisk/fstab.<hardware>`; our DTB (the vendor A11 DTB) has no `fstab` node, the unit's
  untouched A10-era `dtbo` adds `vbmeta`/`fstab` children with `status = "disabled"`, and our ramdisk has
  neither that directory nor any `fstab*` file. That alone explains black screen + no WiFi + dead adb.
* Second-order risk (**D33**), still real: our `boot.img` kernel and DTB are byte-identical to the vendor
  **Android 11** package (`ec3b6631…` / `530b8412…`) while the untouched `uboot`/`trust`/`dtbo` are the
  **Android 10** generation the unit last installed - the vendor's own A11 upgrade rewrites `boot`, `trust`,
  `uboot`, `logo`, `dtbo` and the loader, so it never mixes them (what XDA warns about for A10->A11). The A10
  overlay disables `vbmeta`/`fstab` under `firmware/android`; the A11 overlay drops that fragment.
* Other measured differences (**D32**) are cleanup, not the cause: `mali_kbase.ko` reports
  `vermagic=4.4.167` (the OEM vendor ships the same bad module and Mali is built into both kernels), and the
  DTB panel-timing changes we found are a *vendor* A10->A11 difference, not our edit. AVB/vbmeta,
  uboot/trust mismatch, partition layout and ext4-vs-fstab are ruled out.
* Two fixed boot images are **built and verified but not flashed**: `a14-fixed.img` (32,796,672 B,
  `f378d4fd…`, our payload + `/first_stage_ramdisk/fstab.rk30board`) and the generation-coherent
  `boot-a10k-a14rd.img` (28,231,292 B, `455a9ac8…`: OEM A10 kernel + OEM A10 `second` with the A10 DTB + our
  A14 ramdisk + fstab). Flashing the OEM `boot-a10.img` unchanged would **not** work - its ramdisk fstab
  lists only `system/vendor/odm/product`, no `system_ext`. **No second flash without a serial console
  reading first.**
* The unit goes on the desk bench next: harness yellow+red to a **12 V / 10 A supply** fused at 10 A (the
  unit's nameplate and rear fuse are both 10 A - a 1 A brick does not power it on), black to supply GND,
  a 3.3 V serial fob on `console=ttyFIQ0` at 115200 8N1. The standalone bench guide (materials, wiring,
  partition sector map, serial reading order, decision tree, write routes via `upgrade_tool` maskrom or
  TCP adb, troubleshooting) is `docs/reanimation.md`; capture with `scripts/serial_console.sh log <name>`.
* Rollback is now **blind** (**D29**, revises D26) and the payload for it is **built and verified**
  (**D31**): `super-a10.img` 3,263,168,512 B sha `30da961c…` + `boot-a10.img` 27,406,336 B sha
  `04a43ea9…`, rebuilt from `diatsia fw/update(1).zip` with `brotli` + `tools/reassemble.py` + `lpmake`
  and checked with `lpdump` + `debugfs`. Restore by serial-console `dd`, or by a **bootable SD card**
  (u-boot scans `mmc1` first: `rkimg_bootdev=if mmc dev 1 && rkimgtest mmc 1`, strings `Found IDB in
  SDcard`, `Forbid to flash mmc 1(sdcard)`) that carries the same two images plus a rescue initramfs.
  The card goes in the sdmmc slot (`dwmmc@fe320000` = Android `sdcard1` = u-boot `mmc 1`). Nothing has
  been burned to a physical card yet - four facts must be measured on the desk first
  (`docs/findings.md`, "Unbrick SD route - Nov 9/10").
* The Nov 5 "62.8 GB full-eMMC snapshot" is **not** insurance: measured Nov 10 `analysis/gpt/disk.img`
  is zero except a protective-MBR remnant and the backup GPT, and `gpt_head.bin` is all zeros. The layout
  reference is `gpt_tail.bin` + the Nov 4 probe's LBA table; the content reference is the OEM packages.
* `docs/upstream.md` is the candidate register for upstream contributions - **nothing submitted yet**, and
  the verified Lineage/AOSP review and licensing rules are recorded there.
* Bluetooth is a deliberate second pass after first boot (`docs/decisions.md`, "Bluetooth route").
* No partition is ever resized or rewritten, and recovery/uboot/trust/dtbo/RKLoader/security are never
  written by our payload; rollback via the untouched recovery (prefer the vendor's April 2025 rebuild
  `diatsia fw/update(1).zip`, sha `31bb492a…`) only works if the menu ever appears (**D11**/**D18**/**D19**).
