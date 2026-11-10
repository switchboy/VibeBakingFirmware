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

## Current state (Nov 9/10)

1. **The unit is up for the first write and now holds our Android 14 payload.** Route 2 ran on Nov 9 over
   TCP adb: `super` 2,275,747,780 B and `boot` 32,796,672 B written with verified shas; `recovery`,
   `uboot`, `trust`, `dtb`, `dtbo`, `vbmeta`, the loader and the GPT untouched, so the boot chain is
   intact (**D30**). Outcome: black screen, no boot animation, no OEM logo, WiFi gone, TCP adb dead, and
   no recovery menu reachable by button combo. Full log: `docs/findings.md`, "Flash attempt Nov 9/10".
2. **How access works here (D28):** USB adb is impossible (all HU sockets are host-mode, the laptop's
   Type-C host saw no partner), developer options are absent, so the factory-settings password **`adbon`**
   sets `persist.internet_adb_enable=1` -> port 5555 -> `adb connect 192.168.1.120:5555` -> `adb root` ->
   uid 0. It does not carry over to Android 14: the prop lives in `/data`, which Android 14 formats fresh,
   and Android 14 cannot recover Android 10's Wi-Fi credentials.
3. **Next move - measure, don't re-flash (D33).** Get a serial console reading (`console=ttyFIQ0`,
   115200 8N1, 3.3 V), in this order: (a) which DTB u-boot used - it prints either `Found DTB in <part>` or
   the boot-image `second size`/`dtb size`/`dtb addr` line, and whether the `dtbo` overlay applied
   (`android_get_dtbo`, `%s: failed to read dtbo`); (b) kernel panel/timing messages - our DTB has no LVDS
   timings for `mtc,panel_index` 0x21..0x26; (c) does init reach second stage, does its bpf/cgroup setup
   survive, which services crash-loop, what does SurfaceFlinger say. The measured problem is a
   **mixed-generation boot** (**D33**): vendor A11 kernel+DTB in `boot`, vendor A10-era `uboot`/`trust`/
   `dtbo` in the untouched partitions. Two coherent paths: (1) flash `boot-a10.img` (A10 kernel 4.19.111+ +
   A10 DTB, matched to the unit's chain) and keep our A14 `super` - no boot-chain write, but first confirm
   Android 14 userspace survives on that kernel (string evidence: `bpf` 165, `psi` 72, `cgroup2`, `ringbuf`
   52, `f2fs` 107, no `erofs`); (2) install the vendor A11 chain (`uboot`, `trust`, `dtbo`, `logo`, loader)
   as the vendor's script does - riskier, it is the step that can brick an A10->A11 unit, and our rescue
   media is unproven, so it is not allowed before serial plus a verified rescue card. `mali_kbase.ko`
   vermagic will be rejected but is not fatal (Mali is built into both kernels; the OEM ships the same bad
   module). The composer question stays open (Android 14 may need AIDL `composer3`/`allocator`/`mapper`
   wrappers around the OEM blobs rather than the declared HIDL `composer@2.1::IComposer/default`).
4. **Rollback is blind (D29) and the payload is ready (D31).** Rebuilt from `diatsia fw/update(1).zip`:
   `super-a10.img` 3,263,168,512 B sha `30da961c…` and `boot-a10.img` 27,406,336 B sha `04a43ea9…`, in the
   NAS archive `…/aospbuild-archive/vibe-rescue/`, verified with `lpdump` + `debugfs`. Serial `dd` of those
   two restores Android 10. The SD media is built as a **boot card** (IDB flag 1) carrying the same two
   images plus a rescue initramfs that `dd`s them - an upgrade card is useless here because it needs a
   recovery we do not have. Rockchip's Linux tools are staged in `/tmp/opencode/rktools/` (`afptool`,
   `rkImageMaker -storage:SD`, `upgrade_tool`, `programmer_image_tool`). Card goes in the sdmmc slot
   (`dwmmc@fe320000` = `sdcard1` = u-boot `mmc 1`), not `sdcard2`. **No physical card has been written**:
   the slot mapping, BootROM loader acceptance, IDB-parser acceptance for a `-storage:SD` image with
   `RKLoader.bin`, and the flag-byte offset all need measuring on the desk with serial. The Nov 5 eMMC
   "snapshot" is empty (zero except backup GPT), so it is not insurance; `/data/local/tmp/hu14-backup/`
   on the unit (super head 16 MB, whole boot 32 MB, super tail backup failed) is unreachable until the
   unit is on the desk.
5. Owner's success criteria stay: **not brick**, **boot**, **WIFI**, **screen**, **sound input**
   (touch + physical buttons + CANBUS). Bluetooth is a deliberate second pass (`docs/decisions.md`).
   One agent at a time.
