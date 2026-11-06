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
    The unit exposes `/proc/config.gz` (config recovered to `analysis/hu_kernel_config.txt`), and it
    has no `CONFIG_MTC*`/`ADV7181` symbol at all - confirming that driver stack is out-of-tree
    and built into this kernel. Rebuilding needs the Rockchip BSP source plus that driver.
3. **VNDK ceiling**: vendor is built for VNDK 29 (Android 10). Android keeps VNDK APEXes for
   vendor images built for Android ≤14, and drops them in Android 15.
   → **Android 14 (API 34, LTS) is the ceiling for a framework-only upgrade with this vendor.**
   Android 15 would require reimplementing the vendor HAL surface.
4. **KeyMint**: Android ≥11 requires `IKeyMintDevice`; vendor ships keymaster 3.0 → must add a
   KeyMint service (software implementation, or a wrapper over `keystore.rk30board.so`).
5. **Partition layout (D8 superseded by D19, Nov 6)**: no change at all. Super stays 3,263,168,512 B
    and the group stays 3,258,974,208 B. Android 14's logical images total 2,183,183,264 B block-aligned
    (system 929 MB / vendor 412 MB / product 456 MB / system_ext 385 MB / odm 0.8 MB), so they fit with
    ~1.07 GiB spare without touching the GPT; only the logical partitions inside super are recreated by
    the payload's `dynamic_partitions_op_list`. Android 10's stock layout needed 3,125,321,728 B, so our
    build is *smaller* than what the unit already holds.
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
| P1 | Device data collection from the real unit | **mostly done**: partition sizes, full kernel config, vendor HAL surface, control-plane props, SELinux behaviour, WiFi chip (see `docs/head-unit-findings.md`); still missing: MCU/MTCD firmware version, DTB dump, feature checklist, vendor blob hash comparison | done via Termux + `allinone.sh` over LAN, no adb needed |
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
| D8 | Partition layout change | **superseded by D19** | no layout change | Android 14's logical images (2.18 GB) fit in the existing 3.26 GB super with 1.07 GB spare, so growing it buys nothing and a GPT rewrite is a brick risk |
| D16 | Dropped vendor destinations | **decided** | restore Android 14's own HAL modules via PRODUCT_PACKAGES; declare rild + vendor_flash_recovery.rc as the only gaps | Soong defines rules for HIDL services the product never pulls in, so dropping the blob deleted real features; blobs cannot be re-added without a Make collision |
| D17 | First-flash transport | **superseded by D18** | fastboot kept as last resort only | owner rejected it: it bypasses the stock recovery's loader step, which may be the only path to the mainboard MCU firmware |
| D18 | Install transport + untouchable partitions | **decided** | stock `update.zip` flow (stock recovery + stock `update-binary`); never write recovery/uboot/trust/dtbo/RKLoader/`security`; no partition resize | owner: keep it as simple as flashing another Android 10 build; an unverified custom recovery could brick the unit; rollback = the stock Android 10 update.zip |
| D19 | Partition-size change for the test | **decided** | none - recreate logical partitions inside the existing super | owner: don't complicate it; Android 14's 2.18 GB fits in the 3.26 GB group, so no GPT write and no resize (**D18** forbids writing partition-table bytes) |
| D20 | Libraries Android 14 does not install into /vendor | **decided** | request Android 14's own `<name>.vendor`/`<name>.vendor_32` modules through PRODUCT_PACKAGES (generated `vendor_modules_extra.mk`); public libraries load from /system through the linker config; inject only the leftovers | Android 14 dropped the VNDK, so the Android 10 route (/system/lib/vndk-29) is gone; a requested module is an install dep of vendor.img, which is what build_image.py's file filter is built from - an injected file is not (docs/decisions.md D20) |



Detailed milestone breakdown: `docs/plan.md`.

## Risk register

| Risk | Impact | Mitigation |
|---|---|---|
| MTC driver source unavailable → kernel frozen | kernel CVEs unpatched | keep kernel; mitigate by hardening userspace/SELinux, network-facing services disabled; later rebuild kernel from Rockchip BSP + vendor's driver source if obtainable |
| VNDK/legacy lib drift in Android 14 build | blobs fail to link | ship vendor-local copies of Android-10 era libs; test each HAL with VTS-ish smoke tests |
| Ion vs dmabuf allocator path | graphics breakage | keep HIDL allocator/mapper 2.0 + vendor `libion` shim talking to `/dev/ion` (kernel 4.19 has Rockchip ion) |
| Super partition too small for Android 14 | install fails | no longer a risk: Android 14 needs 2.18 GB of logical content and the group is 3.26 GB (1.07 GB spare). If it ever stops fitting, that is a fresh layout decision (**D19**), not a scripted GPT rewrite |
| HCT apps depend on framework internals | features break | keep app layer from current firmware initially; test early on real car |
| Bricking the unit | hardware loss | **only one unit**: backup GPT head/tail, p1-p13, boot/recovery and the current logical images before any flash; never flash without a verified restore path. Losing accounts/apps/settings is acceptable per the owner, so backup only needs to be firmware-level |
| Installed firmware is a Daisaita build, not the reference ROM | vendor assumptions could be wrong | largely resolved: the live HAL set matches the reference manifest except `cas`/`weaver`/`rockit.hw` (declared but binaries still present); the next report hashes every vendor blob so we can prove byte-for-byte equality |
| No root on the unit | boot cmdline, lsmod, dmesg, `/init.hct.rc` unavailable | probe degraded fine (sysfs sizes + `/proc/config.gz` worked); **`/system/xbin/su` exists on this ROM** - the probe now calls it directly, so root may be available without Magisk |
| Wireless CarPlay/AA needs 5 GHz, unit's WiFi is a USB **Realtek RTL8188E** dongle (2.4 GHz hardware) | feature cannot be used wirelessly | hardware fix: swap that USB module for a dual-band RTL8821CU/8822BU - the shipped vendor already carries `8821cu.ko`/`8822bu.ko`, so no kernel rebuild; needs module loading in `init.connectivity.rc` and a correct `iw reg` country code. Wired CarPlay/AA unaffected |
| Payload signing / upgrade app rejects our zip | cannot install | keep the same custom update-binary mechanism; verify signature handling before release |

## Next action

1. Run pack26 with the vendor variants requested (**D20**). `scripts/package.sh` now runs
   `tools/vendor_link_closure.py` before the deploy (it writes `vendor_modules_extra.mk`, which
   `device.mk` `-include`s), injects whatever has no vendor variant module, runs dist, re-runs the
   closure and `tools/vendor_abi_check.py` after dist, syncs `vendor.img` if anything was injected,
   then `m superimage` and `m otapackage`.
2. Verify the pass offline with `scripts/verify_artifacts.sh`: VENDOR/ + vendor.map, `vendor_diff.py`,
   `vendor_dropped_check.py`, `blob_deps.py` DT_NEEDED, the closure (0 unresolved sonames), the ABI
   check (0 unresolved symbols), `check_super.py`, the VINTF verdict, the boot header, the recovery
   installer and the OTA zip.
3. Build the flashable payload - `scripts/build_hu_package.sh ../lineage21s "extracted update.zip"
   ../tmp/hu-package/update.zip` - it has never been run. Check `unzip -l`, each transfer list's size and
   the sha256. The op list is stock vocabulary (`remove_all_groups`, `add_group
   hct_dynamic_partitions 3258974208`, `add`, `resize`) with `system_ext` as a fifth partition, so the
   question is whether the Android 10 recovery's `update_engine` accepts that op list and the
   `.new.dat.br` payloads (docs/flash.md records the risk).
4. Owner answered **D14**/**D17**/**D18** (Nov 6): no reachable loader/Boot-ADB, fastboot is not used,
   and rollback is the stock Android 10 update.zip - flash it the same way if Android 14 turns out
   wrong. Nothing in this repo restores partitions. The recovery-entry routes are now sourced, not
   guessed (docs/flash.md "Getting into the recovery"): stick with `update.zip` at the root inserted
   before boot brings the menu back or prompts the install (Dasaita forum, Iker Gomez, 7 Jul 2022);
   long-press power until it flashes ~5 times, release and press again reaches the recovery menu on a
   PX6 Android 10 unit (XDA, alfondehesa, 22 Jul 2020); the menu's third line prints its version, so
   read it before flashing. Dasaita's rule - never cross Android major versions with an OTA file - is
   why the payload skips uboot/trust/dtbo/loader, and why the first flash still needs the unit's own
   menu confirmed.
5. M2b repartition is dropped (**D19**): the install recreates the logical partitions inside the
   existing super and never writes the GPT (**D11**, **D18**).
6. Closeout when the ROM ships: remove the extra packages installed on the build host
   (`git-lfs repo unzip device-tree-compiler brotli gdisk zip`) and delete the temporary
   firewall rule.
