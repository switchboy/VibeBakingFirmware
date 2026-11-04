# Design decisions

Status: **awaiting owner answers** (asked interactively; recorded here once answered).

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

## D8 — partition layout

Needed info from the unit before deciding: real `super` size, per-partition sizes, whether
`/data` can stay untouched. Then either keep the current layout (trim Android 14 modules to fit
3.1 GB) or re-layout the dynamic group with a larger system/product.

## Questions for the owner (data we need from the unit)

1. Exact unit identification: is it really the Hal9k Mod (base HCT4) as shipped here, and which
   version (`ro.product.version`, serial in Settings → System → About)?
2. Can you give us adb access (`adb shell` over USB or TCP) so we can collect `scripts/device_inspect.sh` output?
3. Do you have a second unit / spare for testing, so we can experiment without bricking your car unit?
4. Is the MCU firmware (MTCD/MTCE) separate from this update.zip? Which MCU version is installed?
5. Do you want OTA-style updates (server) or offline packages only?
6. Which head-unit features must keep working (CAN steering-wheel keys, reverse camera, AV-in, FM/DAB
   radio, DSP/EQ, CarPlay/Android Auto, GPS, iPod/USB mirror)?
