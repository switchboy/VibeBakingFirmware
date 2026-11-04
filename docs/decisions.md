# Design decisions

Status: **answered** — target Android 14, base LineageOS 21, kernel = shipped 4.19 binary first then
BSP-source rebuild, vendor = blobs untouched + wrappers, apps = keep HCT4 apps for v1, security =
pragmatic during bring-up / strict at release, delivery = Update.zip on USB/SD. Milestone breakdown
in `docs/plan.md`. Options below are kept for the record.

## D1 — target Android version

| Option | Support window | Notes |
|---|---|---|
| **Android 14 (API 34) — recommended** | LTS, security patches ~2029 | last version that keeps VNDK v29 snapshots + HIDL HALs → vendor blobs can stay untouched |
| Android 13 (API 33) | LTS ~2027 | slightly less work (composer/audio migration less aggressive) |
| Android 12 (API 31) | LTS ~2026 | needs KeyMint + legacy-lib shims; still good |
| Android 11 (API 30) | patches ended | community-proven on PX6 (Hal9k/Malaysk), but not "safe" long term |
| Android 15+ | — | **not feasible** with this vendor: VNDK snapshots and HIDL support are removed |

## D2 — base project

| Option | Trade-off |
|---|---|
| **LineageOS 21 (Android 14) — recommended** | upstream security maintenance, mature old-device plumbing (non-GKI kernels, legacy HAL wrappers), rich UI; needs a Lineage device tree |
| Vanilla AOSP 14 | closest to "clean base" for a head unit; HCT apps must be re-added manually; no upstream ROM plumbing |
| crDroid / DerpFest fork of Lineage | extra features, more fork-specific churn |
| Minimal AOSP fork of the HCT Android 10 tree | least structural change, but you inherit a 2021 codebase and its bugs |

## D3 — kernel strategy

| Option | Notes |
|---|---|
| **Keep shipped 4.19.111 binary first (recommended as step 1)** | guarantees MTC/CAN/tuner/AMP/ADV7181/RGA/Mali blobs work; kernel CVEs unpatched; needs a VINTF kernel-config workaround (no `/proc/config.gz`) |
| Rebuild BSP 4.19 from source + stable/LTS backports, `CONFIG_IKCONFIG_PROC=y` (step 2) | the security win; requires kernel source incl. the out-of-tree `mtc-*` driver (GPL-published by the HU vendor → ask vendor/Hal9k for it) |
| Port to 5.10+ GKI | would need `mtc-*`, Mali kbase, gralloc_drm/ion, camera ISP ports; high risk of breaking hardware |

## D4 — vendor / blob strategy

| Option | Notes |
|---|---|
| **Keep vendor as shipped + wrappers (recommended)** | ship vendor-local copies of `libhardware_legacy`, `libhwc2on1/2onfbadapter`, `libchrome`, `libion` shim, etc.; add KeyMint service; blobs untouched |
| Wrap individual blobs into AIDL/newer HIDL HALs | nicer long term, more engineering per HAL |
| Reimplement HALs from scratch (AOSP audio/gralloc/composer) | cleanest, highest risk of losing head-unit behaviour (DSP/EQ/AMP routing, tuner) |

## D5 — security posture vs app compatibility

Current firmware is deliberately sloppy: SELinux permissive, Magisk in `/vendor/magisk`, ~12 init
services running as root under `u:r:shell:s0`, world-writable UART/MTC device nodes, ADB-over-TCP on
boot, NAT tethering, third-party OTA host.

| Option | Effect |
|---|---|
| **Strict (recommended for the final release)** | enforcing SELinux, no Magisk, HCT services given dedicated SELinux domains with least privilege, device nodes 0600/0660, ADB disabled by default, own signed update package | risk: HCT apps break until policies are written |
| Pragmatic (dev milestone) | keep permissive + Magisk during bring-up, tighten at the end | faster iteration, less safe intermediate builds |

## D6 — head-unit app layer

| Option | Notes |
|---|---|
| **Keep the HCT4 apps as shipped (recommended for v1)** | radio/AMP/EQ/AV-in/back-view/CarPlay keep working immediately |
| Replace with open-source equivalents | needs CAN/tuner/AMP protocols documented; long tail of work |
| Move to Android Automotive OS (`IVehicle`/`IAudioControl`/EVS) | the "right" car architecture, but a big reimplementation; needs new HALs we do not have |

## D7 — update/flash delivery

| Option | Notes |
|---|---|
| **Keep the existing `Update.zip` + built-in upgrade flow (recommended)** | owner experience unchanged (USB/SD), reuse the custom update-binary; sign our own payload |
| Rockchip USB loader / rkflash full-image flash | more reliable for bricking recovery, needs the loader + OTG cable + PC |
| Ship a custom recovery (TWRP-like) + zip | flexible (nvdiv backups, per-partition flashing), extra work |

## D8 - partition layout

Measured on the unit (no root needed): `super` = 3,263,168,512 B with ~730 MB free,
`userdata` = 58,844,495,360 B with 5.4 GiB used, whole eMMC 58.5 GiB. `/data` can stay F2FS and
untouched in either option.

| Option | Notes |
|---|---|
| **A. Keep the current layout, trim Android 14 images** | no repartitioning risk, but ~3.0-3.2 GiB of Android 14 images must fit in 3.04 GiB: no Google apps, few preinstalls, flash via recovery (direct writes, no OTA snapshot). Every feature we add costs space we may not have |
| **B. Repartition: super 5-6 GiB, userdata ~50 GiB (recommended if a full backup is possible)** | comfortable, allows OTA-style headroom and the HCT app set; requires rewriting the eMMC GPT and reflashing every partition, so it is only safe with a byte-exact backup of uboot/trust/dtb/dtbo/vbmeta/boot/recovery/super plus the userdata content (5.4 GiB, uploadable over LAN) |
| C. Keep super, move nothing out | Android 14 requires system/system_ext/product/odm in the dynamic group, so there is no third escape |

Waiting on the owner: which of A/B, and whether a saved copy of the currently installed firmware
zip exists (B needs a verified rollback).

## Questions for the owner (what we still need)

1. Do you have a saved copy of the zip currently installed on the unit (Daisaita/Daitsun)? If not,
   and `su` works, the probe can `dd` the partitions over LAN as a rollback backup.
2. Does `/system/xbin/su 0 id` give a root shell (no password), or does it refuse? That decides how
   much we can learn without adb.
3. Accept swapping the unit's USB WiFi module for a dual-band one (RTL8821CU/RTL8822BU, drivers
   already shipped in vendor) to get wireless CarPlay/AA working, or stick to wired CarPlay/AA?
4. Which features must survive verbatim in v1: CAN steering-wheel controls, radio/DAB tuner,
   AV-in cameras, GPS navigation, BT phone, DSP/EQ, HCT launcher? (drives P7 acceptance list)

Answered by the unit itself: identity is a `userdebug/test-keys` Android 10 eng build dated
2022-04-12 (not the Hal9k Mod), security patch 2020-05-05, and the vendor HAL surface matches the
reference payload. adb is not needed: Termux + `allinone.sh` over the LAN endpoint collects
everything the probe asks for.
