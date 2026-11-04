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

## D8 - partition layout - **DECIDED: option B (shrink userdata, grow super)**

Owner's reasoning: userdata is oversized; apart from installed apps it holds little real storage.

New eMMC layout (`mmcblk2`, 62,813,896,704 B). Partitions p1-p13 keep their exact size and order,
so U-Boot, trust, dtb, dtbo, vbmeta, boot, recovery, backup, security, cache, metadata and frp
keep their byte offsets and their current contents stay valid. Only `super` grows and `userdata`
moves later and shrinks:

| partition | old bytes | new bytes | note |
|---|---|---|---|
| uboot/trust/dtb/dtbo/misc/security (p1-p5, p10) | 4,194,304 each | unchanged | bootloader, DT, OPTEE |
| vbmeta (p6) | 1,048,576 | unchanged | AVB metadata |
| boot (p7) | 33,554,432 | unchanged | kernel + ramdisk |
| recovery (p8) | 100,663,296 | unchanged | recovery image |
| backup (p9) | 117,440,512 | unchanged | spare |
| cache (p11) | 402,653,184 | unchanged | the unit's upgrade flow uses /cache |
| metadata (p12) | 16,777,216 | unchanged | |
| frp (p13) | 524,288 | unchanged | factory-reset protection |
| **super (p14)** | 3,263,168,512 (3.04 GiB) | **8,589,934,592 (8 GiB)** | dynamic group |
| **userdata (p15)** | 58,844,495,360 (54.78 GiB) | **53,517,729,280 (49.84 GiB)** | reformatted as F2FS |
| GPT / alignment padding | 8,405,504 (8 MiB) | unchanged | |

Small partitions p1-p13 total 697,827,328 B, so 697,827,328 + 8,589,934,592 + 53,517,729,280 +
8,405,504 = 62,813,896,704 exactly.

Consequences:
- Android 14 images (system ~1.5 GiB, system_ext ~0.6 GiB, product ~1.2 GiB, vendor ~0.4 GiB with
  our shims, odm ~0.2 GiB = ~3.9 GiB) fit with ~4 GiB to spare - enough for a snapshot/rollback copy,
  so future updates can run without repartitioning again.
- No Google apps needed for sizing anymore; the HCT app set and our own apps can stay.
- `userdata` is **reformatted**: everything in /data and /sdcard is gone unless backed up first
  (5.4 GiB currently used). Mandatory backup before touching the GPT - see `docs/plan.md` M2b.
- `/data` stays F2FS, `metadata`/`frp` untouched.

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
