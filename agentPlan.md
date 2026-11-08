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
| D22 | The composer blob's `drmModeAddFB2_ext` | **decided (Nov 7)** | patch Android 14's own `external/libdrm` in `patches/` so it exports the Rockchip symbol; keep `libdrm.vendor`/`libdrm.vendor_32` as the build product | the Rockchip symbol is published open source (MIT, libdrm's own licence), so adding it costs one symbol and 224 B in the 32-bit copy; overwriting the module with Android 10's libdrm would swap a build product for an older ABI file and put Android 14's own libdrm consumers on that file (docs/decisions.md D22) |



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

## Next action (Nov 7 — first boot, with the HCT apps in the same flash)

**Owner change of plan (Nov 7, revised Nov 8):** the first flash ships the head-unit app layer too, so the
unit is usable after one flash instead of two (**D6** moves from "later" into M3). Apps live in `system`,
not `vendor`. The Nov 8 revision: the layer comes out of the **reference payload** (`extracted update.zip`),
not off the live unit, because those images are built for this MCU architecture and are meant as drop-ins
(**D24**). The unit's own app set is the HCT8/HCT8_1 generation (`pm list packages -f` in probe
20261105-1914) and the payload carries the HCT4 generation (Mar 2021) - so package names differ from the
probe's list, and the payload is the one that gets staged.

Three vendor gaps come out of the ABI run (`tools/vendor_abi_check.py`, arch-aware version); two are
fixed in the tree, one is declared:

| gap | fix |
|---|---|
| `drmModeAddFB2_ext` - the composer blob `hwcomposer.rk30board.so` (both arches) | **D22 (landed Nov 7)**: patch Android 14's own libdrm instead of overwriting it - `patches/external-libdrm-rockchip-addfb2-ext.patch` adds Rockchip's published `drmModeAddFB2_ext()` (`github.com/TinkerBoard/rockchip-linux-external-libdrm`, branch `linux4.4-rk3288-tinker_board`, libdrm's MIT licence) to `external/libdrm/xf86drmMode.c` + `.h`. `libdrm.vendor`/`libdrm.vendor_32` install the patched file, so there is no blob overwrite and no injection: `scripts/inject_vendor_blobs.sh` gains no overwrite mode. Verified: both arches export the symbol, the composer blobs resolve (0 unresolved), Android 14's 12 libdrm consumers still resolve (0 unresolved, `tools/consumer_abi_check.py`) |
| WiFi: blob `wpa_supplicant` needs `sk_dup` (OpenSSL 3 dropped it) + `nl_send_auto_complete`, and Android 14's wifi framework has **zero** HIDL wifi references | **D21**: rebuild Android 14's own Realtek glue instead of salvaging blobs - add `libwifi-hal-rtk` (`cc_library_static`, vendor, from `github.com/kimocoder/android_wifi_hal`, Apache-2.0; wiring exists in `gugugaga-rockchip/android_hardware_rockchip_wifi` branch `lineage-21.0`), set `BOARD_WLAN_DEVICE := realtek` (Soong picks it via `build/make/core/board_config_wifi.mk`), request `android.hardware.wifi-service` + the AIDL supplicant/hostapd services + `wpa_supplicant`/`hostapd` from `external/wpa_supplicant_8`. Drop the blob supplicant/hostapd and the orphan `android.hardware.wifi@1.0-service`. No driver rebuild: `8188eu.ko` is kernel-side and nl80211-standard. No `sk_dup` compat library needed either |
| HW video codecs: `libomxvpu_dec/enc.so` need `GraphicBufferMapper::lock/unlock`, which Android 14's `libui` no longer exports | **declared gap for v1** (`vendor_dest_deviations.txt`). Swapping Android 10's `libui.so` in would cost Android 14 7 symbols, so it is not an option; a real fix needs a mapper shim, which is M4 work. |

Steps, in order:

1. **Disk first** (the SSD had 14 GB free): prune old attempts, then move the read-only reference
   firmware to the HDD pool and symlink it back. See `docs/build-host.md` "Space plan".
2. **App layer: staged (Nov 8, D24).** The set comes from the **reference payload**, not the live unit:
   the owner's decision is that the payload's images are built for this MCU architecture and are meant
   as drop-ins. Reassembled `product.img` beside the existing `system.img` (`system_ext` does not exist
   in the payload at all), read the app dirs/binaries/libs/permissions with `tools/ext4_ls.py`, and
   staged them as real build modules:
   * `device/rk3399-px6-hct4/apps/Android.bp` - 37 `android_app_import` modules (32 `/system/app`,
     5 `/system/priv-app`), `certificate: "platform"` (the seven `android.uid.system` apps need our
     platform key or PackageManager refuses them), `dex_preopt: { enabled: false }`, no `oat/`.
   * `device/rk3399-px6-hct4/hu_apps.mk` (included from `device.mk`) - `/system/bin` control binaries,
     the OEM `/system/lib` libraries they and the apps name, the init fragment as
     `/system/etc/init/hct.rc` (Android 14's init reads that directory; the `import
     /init.hct.camera.rc` line is dropped because that file is not in the payload), the OEM `/system/etc`
     config files, and our own `/system/etc/permissions/privapp-permissions-hct.xml`.
   * Excluded: the framework-coupled forks (`HCTSystemUI10`, `HCTSettings10`, `HCT4Launcher3`,
     `HCTProvision10`, `HCTPackageInstaller10`), the package-colliding forks (`HCTExactCalculator10`,
     `HCTDeskClock10`, `HCTGallery10`), `ExtAospBluetooth10` (the Android 10 Bluetooth *stack*, package
     `com.android.bluetooth`), the Google/GMS apks, and every `oat/` directory. Collision table:
     `analysis/app_layer_package_collisions.txt`, full inventory `analysis/app_layer_inventory.tsv`,
     ABI evidence `analysis/app_layer_system_abi.txt`, narrative `analysis/app_layer_stage.md`.
   **Verified on the build host Nov 8** (`scripts/run_d24_gates.sh`, run with `nohup` over ssh - not
   systemd-run, whose unit environment makes `build/envsetup.sh` bail with `TOP: unbound variable`; the
   script must not `set -u` for the same reason): deploy exit 0, `vendor_conflicts.py` exit 0 ("no
   collisions", 1021 staged destinations vs 5943 vendor install targets), `m -j4 systemimage productimage`
   exit 0 (22 s incremental), `scripts/verify_hu_apps.sh`: 32 + 5 HCT dirs installed, 0 `oat/` dirs under
   any HCT app dir (the 53 that exist are Lineage's own dexpreopt), init fragment byte-identical apart
   from the dropped import line, 35 system destinations with 0 module collisions, re-signed apks carry our
   platform cert digest `c8a2e9…` with package and `android.uid.system` intact, system.img 1,012,817,920 B
   (+83.7 MB), product.img unchanged, total 2,338,787,328 B against the 3,258,974,208 B group - 920 MB
   spare, no resize (**D19**).
   Still open from this step (recorded in D24): the payload has no `hctcanbusservice`, no
   `com.android.bluetooth` module is in our build at all, and the gocsdk/sdsdk daemons need Android 10
   `AudioTrack`/`AudioRecord` constructors that Android 14 does not export.
3. WiFi is landed (**D21**): `libwifi-hal-rtk` compiles unchanged for arm64 and arm, and Android 14's own
   `android.hardware.wifi-service` / `wpa_supplicant` / `hostapd` install with their `.rc` files and VINTF
   fragments, all resolving with 0 unresolved symbols (`docs/decisions.md` D21 for the four config gotchas).
   libdrm is landed too (**D22**): after `scripts/apply_tree_patches.sh` Android 14's own libdrm
   exports `drmModeAddFB2_ext` in both arches and the composer blob resolves, so nothing is injected
   and `scripts/inject_vendor_blobs.sh` gains no overwrite mode. Still to do here: `scripts/package.sh`
   (re-dist so `vendor.img` carries the patched libdrm) and `scripts/verify_artifacts.sh`. Watch
   `check_vintf_compatible.log` in that pass: the derived vendor
   manifest still carries the stock HIDL `wifi@1.3`/`hostapd@1.1`/`supplicant@1.2` blocks, which now
   describe services that do not exist - if VINTF objects, drop those blocks from `vintf/vendor_manifest.xml`.
4. **Payload built + offline-verified (Nov 8), rebuilt so the probe ships inside - flash the rebuilt zip.** First run of `scripts/build_hu_package.sh` (its
   relative `<out-zip>` broke `zip` from the scratch dir - fixed by absolutizing `OUT`). Resize values
   system 1,012,834,304 / vendor 444,424,192 / product 456,159,232 / system_ext 384,802,816 /
   odm 811,008 B; logical content 2,299,031,552 B of the 3,258,974,208 B group - spare 959,942,656 B,
   no resize (**D19**); brotli -q 9 sizes 462,219,217 / 127,220,764 / 195,341,325 / 115,347,508 /
   216,933 B; store zip 945,043,557 B, sha256 `8da3fe4c54a90e2e773557eb176a96b0b3b93d09749c81d1e0f4237ad45c7f0e`
   (NAS `aospbuild/tmp/hu-package/update.zip`, workstation `out-hu/update.zip`; the two older
   zips - 945,061,278 B `c1e5ea5a…` and 945,070,196 B `05b468b0…` - are superseded and must not be flashed). Offline audit green:
   27 entries exactly, `unzip -tqq` clean; op list `add_group hct_dynamic_partitions 3258974208` with
   system_ext as fifth partition, resize sum 2,299,031,552 <= group; updater-script has **zero**
   uboot/trust/dtbo/RKLoader/loader/security/recovery writes (comment words only); uboot/trust/dtbo/
   RKLoader.bin and update-binary byte-identical to stock (sha256), boot.img identical to the product
   copy (32,796,672 B, header v2, cmdline `rk30board` + `selinux=permissive`); vendor.new.dat.br
   decompresses to 444,424,192 B, ext4 magic `53 ef` at 1080, debugfs reads /bin/hw + /lib, and the
   decompressed system image shows `/bin/hu_probe.sh` (0755, 8,086 B), `/etc/init/hu_probe.rc` (0644,
   1,183 B) and `/etc/hu_adb_key.pub` (0644, 714 B) - the auto-probe service and the adb key ship in it. VINTF
   verdict COMPATIBLE, no manifest edit needed. Honesty notes in `docs/decisions.md` (packaging pass
   Nov 8).
   **Nov 8 second pass - the first flash was rejected, and the payload is now signed.** Recovery printed
   `E:footer is wrong` / `E:Signature verification failed` / `E:error: 21` because our zip had an empty
   EOCD comment while both OEM packages carry SignApk's PKCS#7 in the comment (`tools/zip_comment_sig.py`).
   `scripts/sign_hu_package.sh` reproduces that layout with the tree's own `signapk.jar -w` plus the
   prebuilt JDK and the AOSP testkey: **`update-signed.zip` 945,046,226 B, sha256
   `b81c50cc3eb07b8b0ba5a3ab7f518d8ba2a0339801608c892bbd640e52d04407`**, a 1,738 B comment signed by
   cert `a40da80a…` (testkey), entry set unchanged apart from SignApk's own `META-INF/com/android/otacert`,
   updater-script still zero uboot/trust/dtbo/RKLoader/security/recovery writes, `unzip -tqq` clean.
   The flash is a free experiment: recovery verifies before running anything, so a rejection writes no
   partition. If it is rejected again (**D25**, `docs/decisions.md` - the stock `otacerts.zip` holds only
   HCT's own cert `cf2ab3…`), install from the Android 11 root shell with `scripts/flash_from_android.sh`:
   `super.img` 2,275,747,780 B `2045af9c…` + `boot.img` 32,796,672 B `83fd2a15…`, then recovery's wipe
   data/factory reset. Stick backups stay unambiguous: `backup/a10-update.zip` = Android 10
   (1,203,718,969 B, `dd3e2ac0…`), `backup/a11-update.zip` = Android 11 (1,477,122,869 B, `50775dba…`),
   and nothing named `update.zip` at the stick root until a rollback is actually wanted.
5. First boot: run the baked-in `/system/bin/hu_probe.sh` (Nov 8) - `curl -T` upload to the
   workstation when WiFi is up, `/mnt/udisk` copy when the stick is mounted, stdout otherwise - then
   judge display/audio/tuner/CAN/AV-in/GPS/BT before anything else. Bluetooth fix is a deliberate
   second pass (`docs/decisions.md` "Bluetooth route"): fetch Lineage's `packages/services/Bluetooth`
   (Android 14 moved BT out of `packages/apps/Bluetooth`, which is not in our tree) and wire the HAL
   transport - the staged `android.hardware.bluetooth@1.0-service` blob already resolves cleanly.

Older numbered action (still true, now folded into step 3): `scripts/package.sh` runs
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
