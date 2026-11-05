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
- `userdata` is **reformatted**, so the unit goes to factory settings: accounts, apps and their
  settings are lost. **Owner confirmed that is acceptable** - only a brick is unacceptable, so the
  backup requirement is about bootable firmware (GPT + bootloader/boot/recovery/super images), not
  personal data. Re-setup is documented as a routine step in `docs/plan.md` M2b.
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


## D9 - vendor base: Daisaita Android 11 vendor tree (decided)

Use `analysis/daisaita_a11/vendor_tree` (manifest 2.0 / target-level 5) as the vendor base for the
Android 14 ROM instead of shimming the Android 10 vendor:

- allocator/mapper **4.0 midgard** = dmabuf buffers, so the Android 14 framework needs no `libion`
  shim at all (Android 12+ removed libion from system).
- audio 6.0, health 2.1, drm 1.3, cas 1.2, gatekeeper/keymaster 4.0 via **optee**, wifi@1.0 +
  hostapd, lights HIDL + power AIDL - all closer to what Android 14 expects.
- `rockchip.hardware.rockit.hw@1.0` and `rockchip.hardware.outputmanager@1.0` survive, and
  `android.hardware.mtc.mfi@1.0` (the HU control plane) is still declared.
- Android 14 still accepts keymaster@4.0 HIDL; if KeyMint turns out to be mandatory, wrap it on top
  of the optee keymaster 4.0 service rather than rewriting the TA (same reasoning as D4).
- Keep the Daisaita A10 zip as the known-good rollback (D8/M2b). The unit's own kernel (#277) and the
  A11 kernel (#24, 4.19.193, IKCONFIG recovered to `analysis/daisaita_a11_kernel_config.txt`) are both
  usable; the A11 kernel is the better starting point because it ships binderfs, ION CMA heap and
  POSIX ACL, which Android 14 wants.


## D10 - install medium: SD card, applied by an updater app (decided)

Owner wants SD-card installs ("cleanest route"). Consequences:

- AOSP/LineageOS recovery has no "apply update from SD card" menu; it runs update_engine and takes
  a package over **ADB sideload**, or a package handed over by an app through
  `RecoverySystem.installPackage()`. Our ROM ships LineageOS's own **Updater** app, whose menu entry
  **"Local update"** imports a zip from external storage, verifies it, and installs it - so the SD
  route needs no extra app and no TWRP.
- Recovery itself has to exist first: we flash our own `boot`+`recovery` images (built with
  `BOARD_USES_RECOVERY_AS_BOOT := false`, the HU keeps its recovery partition p8). That first flash
  needs Rockchip's flash path (`rkflash` from the NAS in Loader/Boot-ADB mode) - not the SD card.
- After that, every upgrade is: copy zip to the stick -> updater app -> reboot to recovery ->
  update_engine applies the logical partitions. The GPT itself is never touched by an upgrade.


## D11 - first flash: repartition first, or flash the current layout? **(open, needs the owner)**

Both fit on paper, but only one order is safe without a proven rollback:

- **Option A - flash the current layout first** (recommended): our images total 2,056 MB and the
  existing 3,263,168,512 B `super` group holds them, so the first flash writes only
  `super.img`/`boot.img`/`recovery.img` and never touches the GPT. `userdata` keeps its partition and
  is factory-reset from recovery. If Android 14 misbehaves, the stock Android 10 zip reinstalls into
  the same table (its group size is exactly 3,258,974,208). Repartitioning to 8 GiB happens later, once
  the ROM boots and the rollback is verified on this unit.
- **Option B - repartition in the same session** (D8 as decided): one root session does GPT + images,
  so there is only one flash procedure to run - but the first attempt combines the risky GPT write with
  an untested ROM, and the restore path then depends on the saved GPT blobs working.

The build supports both: `BoardConfig.mk` holds the 8 GiB numbers plus the commented fallback for the
untouched table, and `m superimage` re-stages super without a full rebuild (`docs/repartition.md`).
