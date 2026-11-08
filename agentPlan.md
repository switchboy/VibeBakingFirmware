# Agent plan — PX6 firmware modernisation

Mission: ship a flashable firmware image for a PX6 (RK3399 / HCT4) head unit that runs a
modern Android build (current security patches) while keeping the head-unit-specific hardware
working. Owner accepts an old kernel if that is what the vendor blobs need; wrappers around the


Canonical detail lives elsewhere: decisions in `docs/decisions.md`, measurements in `docs/findings.md`,
operator procedure in `docs/flash.md`, build-host ops in `docs/build-host.md`, doc map in `docs/index.md`.
This file is the index plus the risk register, and it must not restate numbers - if this file and
`docs/findings.md` disagree, findings.md is right.

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

## D-status (one line each; reasoning in `docs/decisions.md`)

| ID | Status | One line |
|---|---|---|
| D1-D7 | decided | Android 14 / LineageOS 21 / keep shipped 4.19 kernel / blobs untouched + wrappers / permissive during bring-up / keep HCT apps in the first flash / keep the update.zip-on-USB transport |
| D8 | superseded by D19 | no layout change; the 8 GiB proposal is recorded in `docs/decisions.md` only |
| D9-D12 | decided | Android 11 vendor tree as base; `/data` wiped on flash; flash current layout first; keep the built-in RTL8188E (2.4 GHz only) |
| D13-D14 | decided | staging-first vendor build; no reachable loader/Boot-ADB, fastboot unused |
| D15-D16 | decided | vendor built from staged Android 11 blobs; dropped HAL services come back as Android 14 modules |
| D18-D19 | decided | stock-package transport (now superseded by D25 for the transport itself); never resize, never write the GPT |
| D20-D23 | decided | vendor libs via Android 14's own `<name>.vendor` modules; WiFi HAL rebuilt in-tree (`libwifi-hal-rtk`); libdrm patched to export `drmModeAddFB2_ext`; `usb_dongle` rebuilt from published source, `libomxvpu` stays a declared gap |
| D24 | implemented | HCT app layer staged from the reference payload, re-signed with our platform key |
| D25 | decided | recovery cannot install our package (trusted cert `cf2ab3…` is HCT's own); route 1 = testkey-signed zip attempt, route 2 = raw images via `adb root` dd, recovery untouched |
| Bluetooth | pending | second pass after first boot: Lineage's `packages/services/Bluetooth` + HAL transport |

## Current state (Nov 9)

1. Payload rebuilt and signed: route 1 zip in `out-hu/update.zip`, route 2 images `super.img` +
   `boot.img` - shas and sizes in `docs/flash.md` pre-flight.
2. Next move: flash route 1 (recovery), read the menu's version line; if verification is rejected again,
   route 2 over `adb root` from the laptop (`ssh daan@<laptop>` -> `adb root` -> `adb shell sh
   /mnt/udisk/hu14/flash.sh`), then recovery wipe data/factory reset, reboot, read `hu-probe-<ts>.md`
   off the stick.
3. AVB lock state still unmeasured - read it without root: `getprop ro.boot.vbmeta.device_state`
   (`docs/findings.md`, "SD-card flashing"). If it is locked, a replaced `boot.img` cannot boot at all.
4. Judge boot -> screen -> WiFi -> touch/buttons -> CANBUS -> sound input from the probe report, then
   the Bluetooth second pass. One agent at a time.
