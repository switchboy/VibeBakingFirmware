# Agent plan — PX6 firmware modernisation

Mission: ship a flashable firmware image for a PX6 (RK3399 / HCT4) head unit that runs a
modern Android build (current security patches) while keeping the head-unit-specific hardware
working. Owner accepts an old kernel if that is what the vendor blobs need; wrappers around the
legacy blobs are preferred over reimplementing them.

## Hard constraints discovered in phase 0

1. **Legacy vendor blobs** (`audio.primary.rk30board.so`, `hwcomposer.rk30board.so`,
   `gralloc.rk30board.so` + `libgralloc_drm.so`, `camera.rk30board.so`, `vulkan.rk30board.so`,
   `gps.default.so`, `sensors.rk30board.so`, wifi/BT daemons) link against Android-10 era libs:
   `libhardware_legacy.so`, `libhwc2on1adapter.so`, `libhwc2onfbadapter.so`, `libchrome.so`,
   `librkisp/libvpu/librga/libjpeghwenc.so`, `libtinyalsa`, `libaudioroute`, `libsync_vendor`.
   They must keep working unchanged, or be wrapped.
2. **Kernel 4.19 Rockchip BSP carries head-unit drivers** that are out-of-tree:
   `mtc-*` nodes (`mtc-car` = CAN, `mtc-radio`, `mtc-dab`, `mtc-av`, `mtc-cvbs(2)`, `mtc-key`,
   `mtc-io`, `mtc-vs`, `mtc-dvd`), ADV7181 AV-in decoder, RGA/IEP, Mali kbase (`mali_kbase.ko`
   shipped in `/vendor/lib/modules`). No source for the MTC driver is in the payload.
   → kernel changes must not break these; safest is to keep the 4.19 kernel.
3. **VNDK ceiling**: vendor is built for VNDK 29 (Android 10). Android keeps VNDK APEXes for
   vendor images built for Android ≤14, and drops them in Android 15.
   → **Android 14 (API 34, LTS) is the ceiling for a framework-only upgrade with this vendor.**
   Android 15 would require reimplementing the vendor HAL surface.
4. **KeyMint**: Android ≥11 requires `IKeyMintDevice`; vendor ships keymaster 3.0 → must add a
   KeyMint service (software implementation, or a wrapper over `keystore.rk30board.so`).
5. **super group is 3.1 GB** (`add_group rockchip_dynamic_partitions 3258974208`). Android 14
   system+product+odm+vendor is ~2.8–3.1 GB, so partition sizing must be planned (and possibly
   re-laid-out) before the build is finalised.
6. **Boot image format**: existing U-Boot reads Android boot header v2 (`boot.img` in payload).
   Keep header v2/v3; do not emit header v4 unless U-Boot is updated.
7. **Flashing path**: unit's built-in upgrade flow expects a Rockchip `update.zip` (FAT32 media),
   with the custom `update-binary` (supports `write_raw_loader_image()` / `do_rk_firmware_upgrade`)
   and `RKLoader.bin`. Any new ROM must be delivered in that format (or via the Rockchip USB
   loader / a recovery we ship ourselves).

## Phases

| # | Phase | Exit criteria | Notes |
|---|---|---|---|
| P0 | Firmware inventory | ✅ done | Images reassembled (`tools/reassemble.py`), kernel/boot/HAL/props/driver inventory in `docs/firmware-analysis.md` |
| P1 | Device data collection from the real unit | partition table sizes, `/proc/config.gz` or `/proc/mounts`, MCU firmware version, DTB dump, SELinux mode, working-feature checklist | needs owner cooperation via adb |
| P2 | Version ceiling + HAL gap analysis | generated `system_matrix.xml` of the chosen Android base diffed against `vendor_manifest.xml`; gap list per HAL with strategy (keep / wrap / replace / software) | `tools/hal_gap.py` |
| P3 | Baseline boot test | chosen Android build boots on the unit as a **system-only** image (vendor untouched) — proof that framework-only upgrade works on this vendor/kernel | cheapest proof: flash new system/product/odm onto current firmware |
| P4 | Vendor shim layer | `libhardware_legacy`, hwc2 adapters, libchrome, ion/gralloc shims shipped in vendor; KeyMint service; SELinux labels for new services | `hal/` |
| P5 | Device tree + full build | AOSP/Lineage `device/` + `vendor/` tree builds a bootable `update.zip` | `device/`, `rom/` |
| P6 | Security harden | enforcing SELinux (no `androidboot.selinux=permissive`), no Magisk, no root init services, tight device-node permissions, signed payload, own OTA/offline update path | `rom/sepolicy`, `scripts/` |
| P7 | Head-unit feature parity | CAN/MCU, radio, AMP/EQ, AV-in, GPS, BT phone, CarPlay/AA verified; regression list vs current firmware | owner testing on the car |
| P8 | Packaging + docs | reproducible build, flashable zip + SD/USB image, recovery/rollback procedure, release notes | `scripts/`, `docs/` |

## Work already done in this session

- Reassembled `system/vendor/product/odm` ext4 images from `*.transfer.list` + `*.new.dat.br`
  (`tools/reassemble.py`); verified sizes match `dynamic_partitions_op_list` resize values.
- Unpacked `boot.img`: kernel 4.19.111+, header v2, cmdline with `androidboot.hardware=rk30board`,
  `androidboot.selinux=permissive`, `dwc_otg.speed=0`, `loop.max_part=7`.
- Enumerated vendor HAL surface + blob library dependencies (`readelf -d`).
- Found the head-unit control plane: `/dev/mtc-*`, `/dev/ttyS0-4`, `/dev/ttyV0-5`, `/dev/goc_serial`,
  services `hctcanbusservice`, `gocsdk*`, `sdsdk*`, `blueletd`, `brlinktd`, `usbmuxd`, `adbec`, `hctnat`.

## Decision log (answered by owner)

| ID | Topic | Status | Decision | Rationale |
|---|---|---|---|---|
| D1 | Target Android version | **decided** | Android 14 (API 34) | LTS patches ~2029; ceiling for a VNDK-29 vendor (Android 15 drops VNDK snapshots + HIDL) |
| D2 | Base project | **decided** | LineageOS 21 | upstream security maintenance + mature old-device plumbing |
| D3 | Kernel strategy | **decided** | shipped 4.19 binary first, BSP-source rebuild later | boots immediately; security upgrade in M6 |
| D4 | Vendor strategy | **decided** | blobs untouched + wrappers/shims | owner preference; keeps DSP/EQ/tuner/AMP behaviour |
| D5 | Security posture | **decided** | pragmatic during bring-up, strict at release | fast iteration, hardened final build |
| D6 | Head-unit apps | **decided** | keep HCT4 apps for v1 | feature parity first, replace incrementally |
| D7 | Update/flash delivery | **decided** | keep Update.zip on USB/SD | unchanged owner workflow, payload signed by us |
| D8 | Partition layout change | pending | — | needs real super/partition sizes from the unit (M1) |

Detailed milestone breakdown: `docs/plan.md`.

## Risk register

| Risk | Impact | Mitigation |
|---|---|---|
| MTC driver source unavailable → kernel frozen | kernel CVEs unpatched | keep kernel; mitigate by hardening userspace/SELinux, network-facing services disabled; later rebuild kernel from Rockchip BSP + vendor's driver source if obtainable |
| VNDK/legacy lib drift in Android 14 build | blobs fail to link | ship vendor-local copies of Android-10 era libs; test each HAL with VTS-ish smoke tests |
| Ion vs dmabuf allocator path | graphics breakage | keep HIDL allocator/mapper 2.0 + vendor `libion` shim talking to `/dev/ion` (kernel 4.19 has Rockchip ion) |
| Super partition too small for Android 14 | install fails | measure real partition sizes on unit; shrink modules (remove unused APEX/apps) or re-layout groups |
| HCT apps depend on framework internals | features break | keep app layer from current firmware initially; test early on real car |
| Bricking the unit | hardware loss | **only one unit**: keep the currently-installed Daisaita firmware zip (get it from the vendor) + the reference `update.zip`; never flash without a known-good recovery path |
| Installed firmware ≠ reference firmware (unit runs Daisaita, not this Hal9k/HCT4 ROM) | our vendor assumptions (HAL set, `mtc-*` nodes, DSP/tuner mapping) may be wrong | M1 probe compares installed vendor with `analysis/vintf/vendor_manifest.xml`; if it differs, flash the reference Android 10 firmware first, or re-target our shims to the installed vendor |
| No root on the unit | partition sizes, kernel config, SELinux contexts unavailable | `scripts/probe.sh` degrades gracefully; ask owner to run it with a root terminal if their firmware ships one |
| Wireless CarPlay/AA needs 5 GHz, chip exposes 2.4 GHz only | feature cannot be validated | M9: driver/HAL band exposure; wireless-AA→USB stick as fallback (owner has none) |
| Payload signing / upgrade app rejects our zip | cannot install | keep the same custom update-binary mechanism; verify signature handling before release |

## Next action

1. Owner runs `scripts/probe.sh` from the SD card and places the resulting `probe.md` in the repo root.
2. Compare the installed vendor against the reference vendor; confirm partition sizes (D8).
3. Build the device-tree skeleton, then sync LineageOS 21 into the prepared tree (space-lean order).
