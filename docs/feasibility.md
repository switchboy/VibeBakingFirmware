# Phase 1 — feasibility: how far can this vendor be dragged forward?

## Headline

**Android 14 (API 34) is the realistic ceiling, and it is achievable without touching the
hardware blobs.** Android 15 is not achievable without reimplementing the vendor HAL surface.

Why:

1. **Treble is designed for exactly this.** A device launched with Android 10 (`target-level 4`,
   VNDK 29) can receive a framework-only update: only `system`/`product`/`odm` (+ APEXes) are
   replaced, `vendor`/`boot` stay as shipped. Verified: `tools/hal_gap.py` shows **0 hard
   requirement gaps** between the shipped `vendor_manifest.xml` and the shipped framework matrix
   (FCM level 4), and `libvintf` at runtime always evaluates the framework matrix *at the vendor's
   shipping FCM level* (plus optional HALs from higher levels), so an Android 14 framework running
   against this vendor is a supported configuration.
2. **VNDK ceiling.** Android deprecates VNDK starting with **Android 15**; VNDK APEXes up to
   version 14 (Android 14) are kept precisely "to support existing vendor images". Our vendor needs
   `ro.vndk.version=29` libs (`libcutils`, `libutils`, `libhardware`, `libhardware_legacy`,
   `libhwc2on1adapter`, `libchrome`, …) to keep the blobs linkable. On Android 15 those snapshots are
   gone → every Rockchip blob breaks. So: **Android 14 = last version where the vendor can stay untouched.**
3. **HIDL ceiling.** HIDL is deprecated since Android 10 but still functional; graphics composer
   HIDL 2.1–2.4 are "deprecated" from Android 13 (still served), and HIDL support ends in
   Android 15/16. Android 14 keeps our composer 2.1 / audio 5.0 / camera 2.5 / mapper 2.0 chain.
4. **Kernel.** Android 14 does not require GKI for an *upgrade* device; GKI applies to devices
   launching with Android 12+. VINTF kernel matching for our 4.19 kernel resolves to branch
   `4.19-q` (FCM 4) — which exists (`kernel/configs/q/android-4.19`) and requires kernel ≥ 4.19.42;
   we have 4.19.111 ✓. **Caveat:** kernel config requirements are matched against `/proc/config.gz`,
   and the shipped kernel has **no IKCONFIG embedded** (`strings` finds no `IKCONFIG_CONFIG_START`).
   Options: rebuild the kernel with `CONFIG_IKCONFIG_PROC=y` (needs kernel source, see below), or
   patch `libvintf`/`assemble_vintf` in our fork to skip kernel-config checks (acceptable for a
   hobby ROM, breaks VTS).
5. **Boot image.** The shipped U-Boot reads Android boot header v2 with no DTB in `boot.img`.
   Android's `mkbootimg` can still emit header v2/v3 → keep the existing bootloader untouched.

## The Android-14 gap list (vendor surface we must add or wrap)

| HAL in vendor today | Android 14 need | Strategy |
|---|---|---|
| `keymaster@3.0` (`keystore.rk30board.so`) | KeyMint (`IKeyMintDevice`) required by keystore2 since Android 11 | **A** software KeyMint (AOSP `keymint-service`, test-only attestation) — simplest; **B** wrapper exposing KeyMint 4.x over the legacy blob (keeps HW-backed keys, more work) |
| `gatekeeper@1.0`, `weaver@1.0` | accepted as-is (HIDL still supported) | keep; software gatekeeper if blob misbehaves |
| `audio@5.0` + `audio.effect@5.0`, loaded through `libhardware_legacy.so` + `audio.primary.rk30board.so` | HIDL audio 5.0 still served in 14, but `libhardware_legacy` is not in the platform anymore | ship a vendor-local `libhardware_legacy.so` + `libtinyalsa`/`libaudioroute`/`libspeexresampler`/`libaudioutils` built from Android-10 sources (the "wrapper" approach) |
| `composer@2.1` needing `libhwc2on1adapter` + `libhwc2onfbadapter` | deprecated but functional in 14 | ship vendor-local copies of both adapters |
| `allocator@2.0`/`mapper@2.0` + `gralloc.rk30board.so`/`libgralloc_drm.so` | Android 12+ prefers dmabuf heaps (kernel ≥5.6); kernel 4.19 has Rockchip **ion** | keep HIDL 2.0 allocator/mapper; ship a vendor `libion.so` shim that talks to `/dev/ion` via ioctls (Android 12 removed `libion` from the platform) |
| `camera.provider@2.4/2.5` needing `libchrome`, `libui`, `libnativewindow`, `librkisp/libvpu/librga/libjpeghwenc`, `libsync_vendor` | HIDL camera 2.5 supported in 14 | ship vendor-local `libchrome` (Android-10 copy) + vendor variants of `libui`/`libnativewindow`; Rockchip libs already live in vendor |
| `sensors@1.0`, `gnss@1.0`, `power@1.0`, `light@2.0`, `memtrack@1.0`, `health@2.0`, `drm@1.0/1.2`, `cas@1.1`, `wifi@1.0`, `bluetooth@1.0`, `usb@1.1`, `rild`/`radio@1.0` | HIDL versions accepted by the FCM-4 matrix | keep; verify runtime behaviour (Android 14 may only request the declared version) |
| none | `android.hardware.broadcastradio` (FM/DAB tuner) — **the HU radio app currently uses `/dev/mtc-radio` / `/dev/mtc-dab` directly**, not the HAL | optional: wrap MTC tuner into `broadcastradio@2.0` later to get standard Android radio integration |
| none | `android.hardware.automotive.vehicle` / `audiocontrol` / `evs` | optional: needed only if we move to Android Automotive instead of the HCT app layer |

## Kernel strategy options

| Option | Effort | Security | Risk |
|---|---|---|---|
| **K1 keep the shipped 4.19.111 binary** | none | kernel CVEs unpatched (4.19 LTS is dead since 2022) | lowest — guaranteed blob/driver compatibility; no IKCONFIG → needs VINTF patch |
| **K2 rebuild Rockchip BSP 4.19 from source + LTS backports** | days–weeks (needs BSP source + the out-of-tree `mtc-*` driver, which is GPL and *should* be published by the HU vendor; GPL compliance is our leverage to obtain it) | much better: 4.19 stable fixes, plus config for IKCONFIG/dm-verity | medium — must reproduce vendor driver behaviour exactly |
| **K3 port to 5.10/6.x GKI** | weeks–months; port `mtc-*`, ADV7181, RGA/IEP, Mali kbase to newer DRM/KMI | best | high — blobs (gralloc_drm/ion, composer, vulkan, camera ISP) talk to kernel interfaces that changed; likely breaks the hardware |

Owner preference on record: willing to stay on an old kernel for blob compatibility, prefers wrappers
over reimplementations → **K1 to get a first boot, then K2 as the security upgrade**. K3 is out of scope.

## Storage constraint

`dynamic_partitions_op_list` creates group `rockchip_dynamic_partitions` with max size
**3 258 974 208 B (3.1 GB)** holding system 1.44 GB + product 0.93 GB + vendor 0.33 GB + odm 0.56 GB
= 3.1 GB (already at the limit). An Android 14 system+product (with APEX modules) is bigger than
Android 10's. Before building we must measure the *real* `super` partition size on the unit
(`blockdev --size /dev/block/by-name/super`) and either re-layout the groups (our zip can rewrite
the op-list) or trim modules (drop unused APEX/apps/fonts). `/data` stays F2FS; userdata is untouched.

## Delivery/flash constraint

The unit installs firmware via `Update.zip` on FAT32 USB/SD using its built-in upgrade path, driven
by a custom 3 MB `update-binary` that implements Rockchip-specific edify functions
(`write_raw_loader_image()`, `do_rk_firmware_upgrade()`) and writes `uboot/trust/dtbo/boot` plus the
dynamic partitions. Alternatives: Rockchip USB "loader" mode (`RKLoader.bin` + rkflash tools), or a
custom recovery/TWRP we ship. Whatever we choose, a **rollback path** (keep the current zip + a
full partition dump) is mandatory.

## Candidate strategies (cost/risk)

| # | Strategy | Effort | Outcome |
|---|---|---|---|
| S1 | **Minimal security refresh**: keep Android 10 base, replace only kernel/boot + updatable APEXes (WebView, etc.) + harden SELinux/props | days | still Android 10 (EOL), but browser/TLS much better; low risk |
| S2 | **Framework-only Android 11/12** (vendor untouched, shims minimal) | weeks | Android 11 is community-proven on PX6 (Hal9k/Malaysk); Android 12 needs KeyMint + legacy-lib shims |
| S3 | **Framework-only Android 13/14** (recommended) | weeks–months | modern patched Android (14 = LTS), same vendor/kernel, shims for legacy libs, KeyMint service, sepolicy rewrite |
| S4 | **Full rebuild: AOSP/LineageOS device + vendor with open-source HALs** | months | cleanest, but reimplements audio/gralloc/composer/camera → head-unit features at risk |

## Bottom line

Feasible: **S3 (Android 14, framework-only, vendor + kernel as shipped, legacy-lib wrappers)**.
Hard prerequisites: KeyMint service, vendor-local legacy lib copies, sepolicy rebuild, super-partition
re-layout, and a VINTF/kernel-config workaround (or a rebuilt kernel). Unknowns that need the real unit:
partition sizes, kernel config, MCU firmware version, whether `/proc/config.gz` exists, DTB, and the
feature checklist (CAN/radio/AMP/AV-in/GPS/BT/CarPlay).
