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
| `update.zip`, `extracted update.zip/`, `diatsia fw/` | the OEM reference packages on disk (ignored; originals also live on the NAS). `update.zip` here is the **Android 10** package (`dd3e2ac0…`), `diatsia fw/update.zip` is the Android 11 package (`50775dba…`) - do not confuse them with `out-hu/update.zip`, which is OUR payload |
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

## Status (Nov 9)

* Apps, WiFi HAL, libdrm, drmservice and the vendor module set are in the tree and verified offline
  (D21-D24). Packaging pass and payload audit: `docs/findings.md`.
* First flash attempt was **rejected by the unit's recovery**: `E:footer is wrong`,
  `E:Signature verification failed`, `E:error: 21` - recovery trusts only HCT's own cert
  (`cf2ab3…`), which we do not hold (**D25**).
* A testkey-signed payload now exists (route 1) and the raw-image route 2 is ready
  (`scripts/flash_from_android.sh`, over `adb root` on the still-booting Android 11).
* Bluetooth is a deliberate second pass after first boot (`docs/decisions.md`, "Bluetooth route").
* No partition is ever resized or rewritten, and recovery/uboot/trust/dtbo/RKLoader/security are never
  written; rollback stays the stock Android 10 package (**D11**/**D18**/**D19**).
