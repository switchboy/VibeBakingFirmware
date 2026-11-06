# VibeBaking Firmware — PX6 (RK3399) head-unit upgrade project

Goal: take a **Rockchip PX6 Android head unit** (HCT4 platform, currently Android 10 with a
May 2020 security patch level) and bring it to a **modern, patched Android** so the unit is
safe to use again, while keeping the head-unit hardware (CAN bus / MCU "MTC", radio tuner,
AMP, AV-in, GPS, Bluetooth-on-UART, CarPlay bridges) working.

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

## Why the current firmware is unsafe

Concrete problems found in the payload (see `docs/firmware-analysis.md`):

- `androidboot.selinux=permissive` — SELinux is not enforcing.
- Vendor SELinux policy is from Android 10, security patch level **2020-05-05** (≈6 years of CVEs missing).
- Root framework shipped inside the ROM: `/vendor/magisk`, plus init services running as **root** with
  `u:r:shell:s0` (`hctcanbusservice`, `adbec`, `usbmuxd`, `vendingpatch.sh`, `hctlog.sh`, `sd-reverse.sh`).
- Device nodes made world-writable/world-readable: `/dev/ttyS0…ttyS4`, `/dev/ttyV0…ttyV5`,
  `/dev/goc_serial`, `/dev/mtc-car`, `/dev/mtc-av`, `/dev/mtc-dab`, `/dev/mtc-cvbs(2)` at `0666/0777`.
- ADB over TCP (`service.adb.tcp.port=5555`) and an "adb-ec-server" started on `sys.boot_completed`.
- `userdebug` + `test-keys` build, world-writable `/mnt/oem` and `/etc/bluesoleil`.
- OTA is fetched from a third-party server (`ota.hal9k.ru:2300`) and the payload itself is unsigned by us.

## Repo layout

```
VibeBakingFirmware/
├── README.md            this file
├── agentPlan.md         phased plan, decision log, risks (agent-facing)
├── docs/
│   ├── firmware-analysis.md   what the shipped firmware actually contains
│   ├── feasibility.md         can modern Android run on this vendor/kernel? version ceiling
│   ├── decisions.md           design decisions + questions for the owner (D1-D10)
│   ├── plan.md                milestones M1..M9, order and rollback
│   ├── head-unit-findings.md  live-unit data + Daisaita A10/A11 comparison
│   ├── build-host.md          the NAS build box, space plan, sync/build units
│   ├── repartition.md         new GPT (super 8 GiB / userdata 49.84 GiB) + dd sequence
│   ├── flash.md               Rockchip Loader/Boot-ADB first flash + backup path
│   ├── ota.md                 packaging the install zip and how it reaches recovery
│   └── termux.md              how the probe runs on the unit and uploads over LAN
├── tools/               analysis + packaging tooling (Python, no root needed)
│   ├── reassemble.py    transfer.list + *.new.dat  -> raw ext4 partition images
│   ├── ext4_ls.py       recursive listing / file dump from ext4 images via debugfs
│   ├── hal_gap.py       vendor manifest vs framework matrix gap report
│   ├── gen_vendor_staging.py  turns vendor/hct4/tree/vendor into vendor_staging.mk + vendor_props.mk
│   │                          + prebuilt_apps/Android.mk (vendor APKs the copy list cannot carry)
│   ├── namecheck.py     lists vendor file names Make cannot stage (# : = whitespace wildcards)
│   ├── vendor_conflicts.py  copy list vs out/soong/installs-*.mk: which destinations the build
│   │                        installs itself (drop the blob) and which need a module removed
│   ├── extract_vendor.py  debugfs-based extraction of a vendor partition into a tree
│   └── vendor_diff.py   built vendor.img vs the stock reference, differences classified
├── analysis/            generated artefacts (gitignored: images, dumps, listings)
├── device/rk3399-px6-hct4/  → device tree for this unit (deployed as device/rockchip/rk3399)
├── hal/               → HAL wrappers / shims for the legacy vendor blobs
├── rom/               → ROM-level config, sepolicy overlays, packaging recipes
├── scripts/           → build / flash / device-inspection helper scripts
│   ├── probe.sh          run it on the SD card; writes probe.md next to itself (no adb/root)
│   ├── deploy_device.sh  copies the device tree into a LineageOS checkout
│   ├── prebuilt_vendor.sh stages the stock Android 11 vendor partition into the build tree
│   │                  (read-only loop mount -> vendor/hct4/tree/vendor, GPU aliases materialised,
│   │                  vendor APKs mirrored for the module build, then runs tools/gen_vendor_staging.py)
│   ├── repartition_gpt.sh builds the new GPT blobs with sgdisk
│   ├── apply_tree_patches.sh applies patches/ to the LineageOS checkout (idempotent, git apply)
│   ├── package.sh      the packaging pass on the NAS: patches -> vendor staging -> deploy ->
│   │                  bootimage/recoveryimage/dist/superimage/otapackage, reveal-and-retry on
│   │                  install collisions, prune unused dist packages
│   ├── verify_artifacts.sh checks a finished pass offline (VENDOR/ + vendor.map, vendor_diff,
│   │                  super layout, VINTF compat, boot header, recovery installer, OTA zip)
│   ├── stage_flash.sh  stages super/boot/recovery (+ sha256) for the Boot-ADB flash, sparse->raw
│   ├── build_rollback_super.sh rebuilds a flashable Android 10 super from the stock package
│   ├── check_super.py  verifies the staged super offline (lpdump layout + dumpe2fs per partition)
│   └── upload_server.py / upload_client.sh  LAN endpoint the unit reports to
```

The payload itself (`update.zip`, 1.2 GB, and its extracted copy) is the **unaltered reference
firmware** — never edit it; everything derived goes into `analysis/`. Both are gitignored.

## Tooling used in this environment

`brotli`, `simg2img`/`img2simg`, `debugfs`/`dumpe2fs` (read ext4 images without mounting/root),
`readelf`, `unpack_bootimg`, `sgdisk`/`gdisk`, `strings`, `python3`.

## Status

- Phase 0 (firmware inventory): **done** — `docs/firmware-analysis.md`.
- Phase 1 (feasibility): **done** — `docs/feasibility.md`; Android 14 is the ceiling, framework-only upgrade path chosen.
- Design decisions D1-D10: **answered** - `docs/decisions.md`. D8/D10: shrink `userdata` to 49.84 GiB,
  grow `super` to 8 GiB, install via SD/USB stick handed to recovery. Factory reset / losing apps
  during upgrade is fine; only bricking is unacceptable.
- M1 (live-unit data): **mostly done** via Termux + `allinone.sh` over LAN - see
  `docs/head-unit-findings.md`. The unit reports a `userdebug/test-keys` Android 10 build (patch
  level 2020-05-05), `super` = 3.04 GiB with ~730 MB free, kernel 4.19.111 with `/proc/config.gz`,
  SELinux Permissive (`getenforce` in the latest probe), and a **USB Realtek RTL8188E WiFi adapter**
  (2.4 GHz silicon). Its vendor HAL
  surface matches the reference payload except three undeclared HALs; blob hashes land in the next report.
- M2 (LineageOS 21 tree): **building cleanly** - shallow source sync on the NAS (`docs/build-host.md`),
  device tree in `device/rk3399-px6-hct4/` deployed as `device/rockchip/rk3399`. Per **D15** the vendor
  is now *built from staged blobs* instead of being prebuilt: `scripts/prebuilt_vendor.sh` mirrors the
  stock Android 11 vendor partition into `vendor/hct4/tree/vendor` and `tools/gen_vendor_staging.py`
  turns it into `vendor_staging.mk` (1034 copy entries — 1233 staged files minus the 173 the build
  installs itself — + the VINTF manifest/matrix),
  `vendor_props.mk` (100 stock properties) and `prebuilt_apps/Android.mk` (the stock vendor RRO,
  which `PRODUCT_COPY_FILES` refuses as an `.apk` destination); the kernel comes from
  `prebuilt/kernel_a11`. `m -j4`
  finished with rc=0 in 45 min (`los-build11`): `super.img` 2.01 GB, `system.img` 922 MB,
  `product.img` 456 MB, `system_ext.img` 385 MB, `odm.img` 811 KB. `boot.img` (32,796,672 B in a
  33,554,432 B partition: vendor kernel + Android 14 ramdisk + vendor DTB + RSCE logo) and
  `recovery.img` (44,689,408 B in 100,663,296 B, with `update_engine_sideload` in it) build too, and
  `super.img` is staged for the unit's real 3,263,168,512 B partition. Packaging (`los-pack`: patches
  -> vendor staging -> deploy -> bootimage/recoveryimage/dist/superimage/otapackage) reruns until the
  OTA zip lands; what the lunch attempts, the missing boot image, the zip-symlink failure and the four
  OTA failures exposed is written up in `docs/build-host.md`.
- M2b (repartition): deferred by **D11** - the first flash writes `super`/`boot`/`recovery` into the
  current table, no GPT rewrite. The real LBAs are captured (`analysis/hu_partition_offsets.txt`) and
  `scripts/repartition_gpt.sh` validated against them (super 8,589,410,304 / userdata 53,517,204,992).
  Next is M3: the Boot-ADB first flash per `docs/flash.md`, then the framework-only boot test.
