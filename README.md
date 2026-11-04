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
│   └── decisions.md           design decisions + questions for the owner
├── tools/               analysis + packaging tooling (Python, no root needed)
│   ├── reassemble.py    transfer.list + *.new.dat  -> raw ext4 partition images
│   ├── ext4_ls.py       recursive listing / file dump from ext4 images via debugfs
│   └── hal_gap.py       vendor manifest vs framework matrix gap report
├── analysis/            generated artefacts (gitignored: images, dumps, listings)
├── device/            → AOSP/Lineage device tree for this unit (to be created)
├── hal/               → HAL wrappers / shims for the legacy vendor blobs
├── rom/               → ROM-level config, sepolicy overlays, packaging recipes
└── scripts/           → build / flash / device-inspection helper scripts
```

The payload itself (`update.zip`, 1.2 GB, and its extracted copy) is the **unaltered reference
firmware** — never edit it; everything derived goes into `analysis/`. Both are gitignored.

## Tooling used in this environment

`brotli`, `simg2img`, `debugfs`/`dumpe2fs` (read ext4 images without mounting/root),
`readelf`, `unpack_bootimg`, `strings`, `python3`.

## Status

- Phase 0 (firmware inventory): **done** — `docs/firmware-analysis.md`.
- Phase 1 (feasibility): **done** — `docs/feasibility.md`; Android 14 is the ceiling, framework-only upgrade path chosen.
- Design decisions D1–D7: **answered** — `docs/decisions.md`.
- Next: M1 (collect data from the live unit), M2 (Lineage 21 tree + build environment), M3 (framework-only boot test) — see `docs/plan.md`.
