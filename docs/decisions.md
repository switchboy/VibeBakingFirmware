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
- The first install runs in the **stock** recovery with the **stock** `update-binary` (**D18**), and it
  wipes `userdata`/`cache` inside the updater-script, so our own recovery is not needed for it. Our
  `recovery.img` (built with `BOARD_USES_RECOVERY_AS_BOOT := false`, p8 stays the recovery partition) is
  built and verified but **not flashed** in v1: the stock recovery may be the only path to the mainboard
  MCU firmware, and an unverified custom recovery could brick the unit.
- After that, every upgrade is: copy zip to the stick -> updater app -> reboot to recovery ->
  update_engine applies the logical partitions. The GPT itself is never touched by an upgrade.


## D11 - first flash: repartition first, or flash the current layout? **DECIDED: option A (flash the current layout first)**

Owner picked the safer order: attempt 1 writes only `super.img`/`boot.img`/`recovery.img`, no GPT
rewrite, and the repartition happens later once Android 14 boots and the Android 10 rollback is proven.
Consequences now baked into the tree:

- `BoardConfig.mk` uses `BOARD_SUPER_PARTITION_SIZE := 3263168512` with group `3258974208`, verified
  against the unit's real LBAs (`analysis/hu_partition_offsets.txt`: super = 1,379,328-7,752,703).
  Our images total 2,056 MB, ~1.2 GB spare, so the current layout already carries Android 14.
- The 8 GiB pair stayed as a *proposal* only. `scripts/repartition_gpt.sh` and `docs/repartition.md`
  were removed on Nov 6 (**D19**) - neither was ever written, so nothing implements a GPT rewrite here: a GPT rewrite is the class of write **D18** forbids, and growing
  super buys nothing for the first install.
- If a layout change were ever made, `sgdisk` re-sorts entries by start sector, so `mmcblk2pN` numbers
  would change and every on-device step must use `/dev/block/by-name/*` instead of `mmcblk2pN`.

## D12 - 5 GHz WiFi for wireless CarPlay/Android Auto: **DECIDED: keep the built-in RTL8188E**

Owner declined the dual-band USB dongle (RTL8821CU/RTL8822BU), so wireless CarPlay and wireless
Android Auto stay out of scope: the built-in module is 2.4 GHz only and `wificountrycode=NL` does not
change that. Wired CarPlay/Android Auto stay on the parity list. If this changes later, the vendor
image already ships `8821cu.ko`/`8822bu.ko`, so it is a plug-and-buy change, not a driver port.

## D15 - vendor: built from staged blobs, no longer a prebuilt image (decided by D13)

D9's Android 11 vendor tree was first used as `BOARD_PREBUILT_VENDORIMAGE`, which produced a working
`vendor.img` but left the OTA packer nothing to read: `HasPartition()` (`check_target_files_vintf.py:315`)
looks for a `VENDOR/` directory entry, and a prebuilt image never creates one - no staging directory,
no `vendor.map`, no vendor build.prop, and `DynamicPartitionsDifference` asserts that every partition
in the super group has a `BlockDifference`. The owner chose "fix vendor staging first, then flash", so:

- `scripts/prebuilt_vendor.sh` loop-mounts `vendor/hct4/prebuilt/vendor_a11.img` read-only and mirrors
  it into `vendor/hct4/tree/vendor` with `rsync -a`, which keeps real symlinks (debugfs dumps them as
  0-byte sidecars and loses the target).
- Symlinks are then resolved and dropped, because `PRODUCT_COPY_FILES` copies with `acp`, which
  dereferences: the 178 `/vendor/bin` aliases would each become a 489 KB copy of `toybox_vendor`, and
  the tools resolve through `/system/bin` on Android 14 anyway. `/vendor/bin/sh` is a real file in the
  stock vendor, so our init service and Rockchip's shell scripts still work. `libGLES_mali.so` and
  `libOpenCL.so` are the exception - Android 14's EGL loader looks for `libGLES_<ro.hardware.egl>.so`
  (`frameworks/native/opengl/libs/EGL/Loader.cpp:284-315`), so those four aliases become real copies of
  the blob in `egl/` (~111 MB added; the super group has ~1.2 GB spare).
- `tools/gen_vendor_staging.py` turns the tree into `vendor_staging.mk` (1034 copy entries),
  `vendor_props.mk` (100 stock properties re-declared, since Android 14 generates its own
  `vendor/build.prop`) and `prebuilt_apps/Android.mk` for the one file the copy list cannot carry -
  `overlay/framework-res__auto_generated_rro_vendor.apk`, the stock vendor resource-overlay package
  (`.apk` destinations are rejected by `build/make/core/Makefile:118`). It is kept because it
  overrides the HU's auto-brightness curve and its tether/hotspot interface names
  (`config_tether_*_regexs`), so it is installed by a `BUILD_PREBUILT` module that copies the blob
  unchanged. VINTF metadata cannot go through `PRODUCT_COPY_FILES`
  (`build/make/core/Makefile:131`), so the manifest goes via `DEVICE_MANIFEST_FILE`, and the device
  compatibility matrix is rewritten with its `<vendor-ndk><version>30</version>` block removed -
  Android 14 has no VNDK and `checkvintf` refuses it. Our own framework matrix adds the three HALs the
  Android 14 framework matrices do not know (`android.hardware.mtc.mfi`, `rockchip.hardware.outputmanager`,
  `rockchip.hardware.rockit.hw`).
- Three `usb_modeswitch.d` rules whose names contain `#` cannot be expressed in a Makefile
  (`#` starts a comment, which is what killed `lunch` with "malformed COPY_FILE"). `/vendor/bin/usb_dongle`
  only looks up the `<vendor>_<product>` form, so dropping them costs nothing.
- `PRODUCT_COPY_FILES` also collides with files the build installs itself: 173 destinations are
  install targets of modules - 162 visible in `out/soong/installs-lineage_rk3399.mk`, plus 11 only
  ckati reveals (legacy Make modules: rild and its libraries, the legacy `gralloc.default.so` stub,
  the empty `fs_config_dirs`/`fs_config_files`, `NOTICE.xml.gz`). Make dedups copy pairs against
  copy pairs only, so ckati aborts with "overriding commands for target ...".
  `tools/vendor_conflicts.py` reports them with the module behind each one and drops the ones whose
  module comes from upstream AOSP source (`vendor_build_wins.txt`, fed back into the generator),
  because Android 14 compiles that same component; the ckati-discovered ones are committed in
  `vendor_dest_skip_extra.txt` so a fresh host converges in one pass. No Rockchip HAL is dropped -
  every HU HAL keeps its own file name (`hwcomposer.rk30board.so`, `audio.primary.rk30board.so`,
  `camera.rk30board.so`, `gps.default.so`, allocator/mapper `-impl-midgard`, `mfi.default.so`,
  `hw_output.default.so`, `rockchip.hardware.outputmanager@1.0-impl.so`), so none of them collide;
  a collision from `vendor/` or a device tree would need the module removed from `PRODUCT_PACKAGES`
  instead, and the tool says which. `scripts/deploy_device.sh` re-checks before every build.
- Device paths in a product-config `.mk` are spelled literally: `$(LOCAL_DIR)` there resolves to
  `build/make/target/product/`, which made ninja ask for
  `build/make/target/product/fstab.rk30board` and fail ("missing and no known rule to make it").
- `BUILD_BROKEN_ELF_PREBUILT_PRODUCT_COPY_FILES := true` is required: Android 14 rejects ELF files
  passed through `PRODUCT_COPY_FILES` (`definitions.mk:3184` checks with `llvm-readobj`).
- `tools/vendor_diff.py` now checks the *built* image against the stock reference by classifying the
  differences into dropped / materialised / replaced / added, plus the build-installed paths (which
  must still be present in the image). Anything outside those categories fails the check.

## D16 - the dropped HAL services come back as Android 14 modules, not as blobs

pack20 built a vendor partition that carried every stock blob **except** the 107 destinations the
drop list removed without anything installing them: no audio/bluetooth/camera-provider/GNSS/sensors/
composer/health/memtrack/CAS/OMX service, no `vndservicemanager`, no `vndservice`, no `libhwbinder`.
The reason is a subtlety in how `PRODUCT_COPY_FILES` conflicts are discovered:

- `out/soong/installs-<product>.mk` contains install **rules** for modules Soong *defines*, not for
  modules this product *pulls in*. Android 14 defines the HIDL default HAL services (audio@6.0,
  bluetooth@1.0, camera.provider@2.4, gnss@1.0, sensors@1.0, composer@2.1, health@2.1, memtrack@1.0,
  cas@1.2, media.omx@1.0) but LineageOS's product config asks for the AIDL ones, so the rule exists
  and nothing installs. `tools/vendor_conflicts.py` saw the rule and dropped the staged blob, which
  deleted a head-unit feature that Android 14 never restores by itself.
- The fix is not to copy the stock binaries back (Make would collide again). It is to ask for
  Android 14's own modules: `device/rk3399-px6-hct4/device.mk` lists the 62 modules
  `tools/vendor_module_names.py` attributes the missing paths to, read straight out of
  `out/soong/installs-lineage_rk3399.mk` so every name really exists. The service modules install
  their own `/vendor/etc/init/<service>.rc`, so the `.rc` paths need no entries.
- Two gaps stay open and are **declared**, not silently dropped, in
  `device/rk3399-px6-hct4/vendor_dest_deviations.txt`: the RIL daemon and its libraries (this unit has
  no cellular modem; calls come over Bluetooth), and `etc/init/vendor_flash_recovery.rc` (it re-flashes
  recovery from `/vendor/recovery-from-boot.p`, which is not staged). The OMX service *is* restored:
  the stock manifest declares `android.hardware.media.omx@1.0`, the staged blob carries the Rockchip
  VPU plugin, and Android 14 still builds the service plus its soft-OMX/helper libraries.
- `tools/vendor_dropped_check.py` is the post-build proof: a dropped destination must be in the image,
  be replaced by a **same-kind** peer (`bin/hw` only by `bin/hw`, `lib64` only by `lib64`), or be a
  declared deviation. The first version matched loosely and accepted `etc/permissions/*.xml` as a
  replacement for a HAL service, and `lib/libwifi-hal.so` as a replacement for `lib64/libwifi-hal.so`.
- `tools/vendor_conflicts.py` also used the *previous build's staging directory* as an install oracle.
  That directory holds the blobs an earlier pass copied, so every staged path looked module-installed
  and attribution said `module=?`; `scripts/deploy_device.sh` then refused a deploy for paths nothing
  installs (`bin/rz`, `bin/sz`, `bin/rkhelper`, ...). Removed - ckati remains the authority for legacy
  Make installs, and `vendor_dest_skip_extra.txt` carries its answers forward.

## D18 - the transport is the stock update.zip flow; recovery, uboot, trust, dtbo and RKLoader are never written

Owner (Nov 6, verbatim): *"For the test we dont need to alter part-size right? So we can just use the
update.zip mechanism of how you would flash another version of android 10 dont make it more complicated
then it has to be."* and *"For costum recovery there are a couple of caveats from the community there is
no costum recovery. There might be a good reason for this. The PX6 is like a cardridge that sits on a
mainboard. There is seperate firmware MCU for this mainboard maybe the current recovery is the only
thing able to flash that? Also do we know that a costum recovery will boot and that it is able to detect
touch or button input. If not the device is a brick if we touch that."*

That settles two things:

- **Install transport**: the unit's own `update.zip` mechanism. `scripts/build_hu_package.sh` writes a
  package in the stock format (brotli `.new.dat.br`, empty `.patch.dat`, one `flash` command per
  transfer list, the stock `update-binary` reused verbatim) and an updater-script that uses only the
  functions that binary already implements: `update_dynamic_partitions`, `map_partition`,
  `block_image_update`, `package_extract_file`, `wipe_block_device`. No partition is resized
  (**D11** keeps p14 at 3,263,168,512 B); only the logical partitions *inside* super are recreated,
  and Android 14's `system_ext` is added to the group.
- **Never written**: `recovery`, `uboot`, `trust`, `dtbo`, `RKLoader.bin`, the stock script's
  `write_raw_loader_image()` step, and the stock script's wipe of `/dev/block/by-name/security`. The
  stock recovery is plausibly the only path to the mainboard MCU firmware, and a custom recovery whose
  boot, UI and touch/button handling are unverified would brick the unit if it fails. Our
  `recovery.img` is built and verified but stays unflashed until Android 14 boots and the board's
  recovery handling is proven.

D17 (fastboot as the first-flash transport) is **superseded** and its scripts were removed: fastboot
writes `recovery`/`boot` while bypassing the stock recovery's loader step, which may be the sole route
to the mainboard MCU firmware, so it is a fresh decision rather than a fallback.

Owner also dropped the rollback tooling on Nov 6 (*"Forget about rollback i'll just flash an official
update.zip if rollback is needed dont waste time on it"*): no Android 10 super rebuild, no partition
dumps, no restore scripts. Keeping the stock `update.zip` is the rollback - it recreates the stock
layout and runs its own loader step.

## D19 - no partition-size change, and the layout math already fits

Owner (Nov 6): *"For the test we dont need to alter part-size right? So we can just use the update.zip
mechanism of how you would flash another version of android 10 dont make it more complicated then it
has to be."*

D8 (super 3.04 GiB -> 8 GiB, userdata -> 49.84 GiB) is therefore superseded. The reason it is safe to
drop the repartition is that Android 14's logical content is smaller than Android 10's stock layout:

| partition | Android 14 (built) | stock Android 10 |
|---|---|---|
| system | 929,140,736 | 1,442,840,576 |
| vendor | 412,073,984 | 333,447,168 |
| product | 456,159,232 | 925,892,608 |
| system_ext | 384,802,816 | - (does not exist) |
| odm | 811,008 | 556,793,856 |
| **total** | **2,183,183,264** (block-aligned) | **3,125,321,728** |

Group `hct_dynamic_partitions` is 3,258,974,208 B inside super's 3,263,168,512 B, so there is ~1.07 GiB
spare without touching p14. What a GPT rewrite would buy is headroom for future growth, not a working
install now - and rewriting the GPT means writing partition table bytes, which is exactly the class of
operation **D18** forbids. `analysis/gpt/` keeps the saved head/tail bytes for the record.

If Android 14's images ever grow past the group, that is a fresh decision with its own risk review, not
a scripted `sgdisk` sequence.

## D20 - how /vendor gets the libraries Android 14 does not install there

Android 14 removed the VNDK, so the vendor partition no longer carries a copy of every library a HAL
links. On the stock Android 10 unit those libraries came from `/system/lib/vndk-29/` (VNDK-sp), which the
vendor namespace was allowed to read. Android 14 has no vndk directory: the vendor namespace may load
from `/system` **only** what `system/etc/linker.config.pb` lists as public libraries - `libc.so`,
`libm.so`, `libdl.so`, `liblog.so`, `libsync.so`, `libselinux.so`, `libEGL.so`, `libGLESv2.so`,
`libbinder_ndk.so`, `libnativewindow.so` and friends - and `linkerconfig` turns that list into
`/linkerconfig/ld.config.txt` at boot. Everything else a Rockchip blob links must be in `/vendor`.

`tools/vendor_link_closure.py` walks the DT_NEEDED graph of every staged blob we keep and sorts each
soname into one of four answers:

| answer | what happens | example |
|---|---|---|
| public library | nothing to do, it loads out of /system | `liblog.so`, `libc.so`, `libsync.so` |
| staged blob kept | `PRODUCT_COPY_FILES` copies the Android 11 copy | `libstagefright_foundation.so` |
| Android 14 has a `<name>.vendor` / `<name>.vendor_32` module | **requested through `PRODUCT_PACKAGES`** (`device.mk` includes the generated `vendor_modules_extra.mk`) | `android.hardware.wifi@1.4.vendor`, `libchrome.vendor_32`, `libaudioroute.vendor`, `android.hardware.light-V1-ndk_platform.vendor` |
| the module exists, but Android 14's copy lost a vendor-only symbol | **patch the open-source library in the tree** (`patches/`), keep the module as the build product | `libdrm` -> `drmModeAddFB2_ext` (**D22**) |
| nothing builds it | injected into the staging dir (`vendor_dest_keep.txt`) | normally none |

Overwriting a module's installed path with a staged blob is not a route: the blob is Android 10/11's
ABI, and the module's install rule still claims that path, so the copy only wins by racing the build.
Where Android 14's own library is the right file but does not export something the vendor needs, the
fix belongs in `patches/` (**D22**), not in the staging directory.

Requesting the vendor variant is preferred over copying a file into the staging directory for two
reasons: the file is Android 14's own build, so its ABI matches Android 14's `libhidlbase.so` /
`libbinder_ndk.so`; and a requested module is an *install dependency* of `vendor.img`, which is what
`build_image.py --input-directory-filter-file <vendor_intermediates>/file_list.txt` is generated from.
A hand-written file in the staging dir is not in that filter, so pack25's product `vendor.img`
(412,073,984 B) left the injected libraries out while dist's `IMAGES/vendor.img` (460,693,504 B) had them
- the payload would have shipped a `/vendor` that could not load its own HALs. `sync_vendor_image()` in
`scripts/package.sh` still covers the injected leftovers, by comparing the two images per path.

On pack25's artifacts the closure found **56 vendor variant modules, zero injections and zero
unresolved sonames**: `android.hardware.wifi@1.0-1.4`, `wifi.hostapd@1.0-1.2`, `wifi.supplicant@1.0-1.3`,
`drm@1.0-1.3`, `gatekeeper@1.0`, `keymaster@4.0`, `weaver@1.0`, `libaudioroute`, `libion`, `libssl`,
`libsqlite`, `libnetutils`, `libsysutils`, `libusbhost`, `libutilscallstack`, `libwifi-system-iface`,
`libgatekeeper`, `libchrome`, `libdrm`, `libhwbinder`, `libkeymaster4support`, `libvpx`, `libopus`,
`libvorbisidec`, plus `android.hardware.light-V1-ndk_platform` and `android.hardware.power-V1-ndk_platform`
(Android 14 still ships the `ndk_platform` AIDL variants, so the Rockchip lights/power services keep their
own binaries).

DT_NEEDED being satisfiable is only half the question, so `tools/vendor_abi_check.py` also checks the
**symbols**: for each kept blob, every undefined symbol must be defined by something the vendor namespace
can load (files installed in /vendor, the other kept blobs, public /system libraries). That is the check
that catches Android 14 having rewritten a library's ABI underneath an Android 11 blob - the failure
mode is a boot-time `dlopen failed: cannot locate symbol`, which no partition check would show. Symbol
versions (`memcpy@@LIBC`) are stripped, because the linker matches the base name.

## D21 - WiFi: rebuild the HAL glue in Android 14's own tree, not the blob (Nov 7, DECIDED)

The owner asked whether a 64-bit rebuild of the *driver* for this chip would let the 32-bit WiFi blobs
stay. Three probes answered it:

| layer | what it actually is | what it needs |
|---|---|---|
| kernel driver | `/vendor/lib/modules/8188eu.ko`, Realtek `v5.7.6_33076.20190419` (Rockchip's `drivers/net/wireless/rockchip_wlan/rtl8188eu`), GPL, alias `usb:v0BDAp0179` = RTL8188ETV. Registers a cfg80211 wiphy with `scan`/`connect`/`start_ap`/`add_virtual_intf`/`mgmt_tx`/`remain_on_channel`; strings show **no** vendor HAL hooks and no private-ioctl scan | nothing. A `.ko` is kernel-side code - the 32/64-bit userspace question does not apply to it - and it is nl80211-standard, which is what Android 14 talks to. `hu_insmod.sh` loads it |
| HAL glue | the stock `lib/libwifi-hal.so` (123,576 B, ARM soft-float) + `lib/librkwifi-ctrl.so` (chip detection: `0bda:0179 -> RTL8188EU`) | Android 14 does not use these. `libwifi-hal.so` is an Android 8-`wifi_hal_fn` table, loaded by whoever links it |
| wifi service | staged blob `android.hardware.wifi@1.0-service` (ELF64, 442,968 B, 0 unresolved symbols) | **nothing can use it**: Android 14's wifi service Java has 0 references to `android.hardware.wifi@` (HIDL wifi support is gone), and our vendor manifest declares no wifi entry at all |
| supplicant | blob `wpa_supplicant` (2,831,168 B) needs `sk_dup` + `nl_send_auto_complete` | cannot load on Android 14's OpenSSL 3 / libnl 3.8 - and Android 14 builds its own from `external/wpa_supplicant_8` anyway |
| what ships today | `/vendor/lib64/libwifi-hal.so` (136,888 B) built from `libwifi-hal-fallback` (`wifi_hal_fallback.cpp`) because `BOARD_WLAN_DEVICE` is unset, so Soong takes `conditions_default` | that stub's `wifi_initialize` reports unsupported, so Android 14's wifi framework finds no usable chip |

Android 14's own `frameworks/opt/net/wifi/libwifi_hal/Android.bp` already has a Realtek branch:
`board_wlan_device: realtek -> whole_static_libs: ["libwifi-hal-rtk"]`, and
`build/make/core/board_config_wifi.mk` feeds `BOARD_WLAN_DEVICE` into that Soong config namespace. AOSP
ships no Realtek HAL source, so we add one:

- `libwifi-hal-rtk` as a `cc_library_static { vendor: true }` built from published Apache-2.0 source:
  `github.com/kimocoder/android_wifi_hal` (`hardware/realtek/wlan/wifi_hal`: `rtw_wifi_hal.cpp`,
  `rtw_wifi_rtt.cpp`, `common.cpp`, `cpp_bindings.cpp`, `rtw_wifi_gscan.cpp`, `rtw_wifi_llstats.cpp`,
  `rtw_wifi_logger.cpp`, `rtw_wifi_offload.cpp`) plus `wpa_supplicant_8_lib/driver_cmd_nl80211.c`.
  `github.com/gugugaga-rockchip/android_hardware_rockchip_wifi` has a `lineage-21.0` branch that wires
  exactly this for Android 14, and Rockchip's own `libwifi_hal/rk_wifi_ctrl.cpp` maps `0bda:0179` to
  `RTL8188EU` + `libwifi-hal-rtk.so`.
- `BOARD_WLAN_DEVICE := realtek` (+ `WIFI_DRIVER_MODULE_NAME/PATH/ARG`) in `BoardConfig.mk`.
- Request the services Android 14 builds: `android.hardware.wifi-service` (the AIDL impl,
  `hardware/interfaces/wifi/aidl/impl`), its supplicant and hostapd services, and `wpa_supplicant`/
  `hostapd` from `external/wpa_supplicant_8`. Their manifest fragments land in
  `vendor/etc/vintf/manifest/`, which the packer merges - that is what makes the wifi entry exist.
- Drop the blob `wpa_supplicant`/`hostapd` copies and the orphan `android.hardware.wifi@1.0-service`;
  keep `librkwifi-ctrl.so` only while the rtk glue needs `check_wifi_chip_type_string`.

Cost: one static library from public source, a BoardConfig line and a few `PRODUCT_PACKAGES` entries.
It also retires the `sk_dup` compat library the earlier plan needed - Android 14's own supplicant
replaces the blob.

Accepted caveat (KISS): Realtek's gscan / RTT / offload / llstat paths talk private driver commands, and
this driver has no HAL hooks while `CONFIG_CFG80211_WEXT` is off in the shipped kernel. Those extras will
not work; scan, connect and softap run over nl80211. Wireless CarPlay/AA still needs a dual-band dongle
(**D12** - the chip itself is 2.4 GHz only, which no software change fixes).

### What it took on the build host (Nov 7, verified)

`m libwifi-hal-rtk libwifi-hal android.hardware.wifi-service wpa_supplicant hostapd` builds clean, and
the installed binaries resolve:

| file | size | unresolved symbols |
|---|---|---|
| `vendor/bin/hw/android.hardware.wifi-service` | 567,008 B | 0 |
| `vendor/bin/hw/wpa_supplicant` | 3,347,280 B | 0 |
| `vendor/bin/hw/hostapd` | 1,762,008 B | 0 |
| `vendor/lib64/libwifi-hal.so` (fallback 136,888 B -> now 211,592 B with the Realtek impl) | 211,592 B | 0 |

Manifest fragments installed beside them: `android.hardware.wifi-service.xml`,
`android.hardware.wifi.supplicant.xml`, `android.hardware.wifi.hostapd.xml`, plus
`android.hardware.wifi-service.rc` and `android.hardware.wifi.supplicant-service.rc`.

Four things the config had to get right, each of them a real failure on the first pass:

1. `WPA_SUPPLICANT_VERSION := VER_0_8_X` - `external/wpa_supplicant_8/Android.mk:3` only includes the
   supplicant and hostapd Android.mks for those versions, otherwise `m` says
   "PRODUCT_PACKAGES includes non-existent modules: hostapd wpa_supplicant".
2. `WIFI_HIDL_UNIFIED_SUPPLICANT_SERVICE_RC_ENTRY := true` - otherwise the supplicant installs without
   its init entry (`wpa_supplicant/Android.mk:1980`). hostapd's AIDL variant needs nothing
   (its Android.mk sets `HOSTAPD_USE_AIDL=y` itself).
3. `WIFI_DRIVER_MODULE_NAME := "8188eu"` and `WIFI_DRIVER_MODULE_PATH := "/vendor/lib/modules/8188eu.ko"`
   - with **quotes, no backslashes**. `build/make/core/board_config_wifi.mk` hands the value to Soong's
   config JSON verbatim, and `wifi_hal_common.cpp` uses the macros as string literals
   (`WIFI_DRIVER_MODULE_NAME " "`, `sizeof(...)`): unquoted gives "sizeof on incomplete type",
   `\"`-escaped gives "soong.variables did not parse correctly".
4. The Make-built wifi paths collide with the blob copies, so `vendor_dest_skip_extra.txt` gained
   `bin/hw/wpa_supplicant`, `bin/hw/hostapd`, `etc/init/hostapd.android.rc`, `bin/wpa_cli`,
   `lib(64)/libwpa_client.so` (ckati: "overriding commands for target .../vendor/bin/wpa_cli"), and
   `vendor_dest_deviations.txt` gained the HIDL service, its `.rc`, `lib/libwifi-hal.so` and
   `librkwifi-ctrl.so` in both arches.

The `sk_dup` compat library from the earlier plan is confirmed unnecessary: Android 14's own
`wpa_supplicant` asks for `OPENSSL_sk_dup`, which Android 14's `vendor/lib64/libcrypto.so` exports, and
for `nl_send_auto_complete`, which Android 14's `vendor/lib64/libnl.so` still exports.

## D22 - libdrm: export Rockchip's `drmModeAddFB2_ext` from Android 14's own libdrm (Nov 7, DECIDED)

`lib(64)/hw/hwcomposer.rk30board.so` links `libdrm.so` and asks for one symbol Android 14's libdrm
does not have: `drmModeAddFB2_ext`. It is Rockchip's own addition to libdrm - the same
`DRM_IOCTL_MODE_ADDFB2` ioctl as `drmModeAddFB2WithModifiers()`, but always copying the four plane
modifiers instead of only when a modifier array is handed in. The stock Android 10 vendor carries
Rockchip's libdrm (`vendor/hct4/tree/vendor/lib(64)/libdrm.so`, 54,584 / 83,104 B, exports
`T drmModeAddFB2_ext`), which is where the blob got it.

The earlier plan was to overwrite Android 14's `/vendor/lib(64)/libdrm.so` with that staged copy
(`agentPlan.md` step 3). Dropped: it swaps a build product for an Android 10 ABI file, it does not win
the install rule cleanly, and Android 14's own consumers of libdrm would then run against the older
file. Patching the published source keeps libdrm as a real build product (**D20**).

### What the blob actually asks for

| | value |
|---|---|
| symbol | `nm -D --undefined-only lib64/hw/hwcomposer.rk30board.so` -> `U drmModeAddFB2_ext` (symidx 225, no version suffix), and the same in `lib/hw/hwcomposer.rk30board.so` |
| prototype | `int drmModeAddFB2_ext(int fd, uint32_t width, uint32_t height, uint32_t pixel_format, uint32_t bo_handles[4], uint32_t pitches[4], uint32_t offsets[4], __u64 modifier[4], uint32_t *buf_id, uint32_t flags)` |
| published source | `github.com/TinkerBoard/rockchip-linux-external-libdrm`, branch `linux4.4-rk3288-tinker_board`, `xf86drmMode.c` + `xf86drmMode.h` - a mirror of Rockchip's `external/libdrm` BSP fork. Rockchip's own `github.com/rockchip-linux/libdrm-rockchip` 404s today, so the mirror is the citable copy. Licence: libdrm's MIT/X11-style licence, which `external/libdrm/Android.bp` already declares as `external_libdrm_license` (SPDX MIT + BSD + legacy_unencumbered) |
| call site | one call, in `DrmGenericImporter::ImportBuffer` at `0x5b504`. `prebuilts/clang/host/linux-x86/clang-r510928/bin/llvm-objdump -d` shows ten arguments in `x0..x9`: `x0` fd, `w1/w2` width/height (`ldp w1, w2, [x20]`), `w3` pixel format, `x4` handles, `x5` pitches, `x6` offsets, `x7 = sp + 0x30` the modifier array, `x8 = x20 + 0x3c` the `buf_id` out-param, `w9 = 2` flags |
| cross-check | Rockchip's compiled `drmModeAddFB2_ext` in the staged libdrm reads the same registers (`ldr q1, [x4]`, `[x5]`, `[x6]`, `ldp ..., [x7]`) and encodes the same ioctl (`mov w1, #0x64b8`); ours does the same. So the ABI is proven three ways: the blob's call site, Rockchip's own binary, and the published source |

### The patch

`patches/external-libdrm-rockchip-addfb2-ext.patch` (tree-root paths `a/external/libdrm/xf86drmMode.h`
and `.c`, applied by `scripts/apply_tree_patches.sh`): the declaration and the definition, kept exactly
as Rockchip published them - non-const arrays, `__u64 modifier[4]`, unconditional modifier copy, marked
`drm_public` like every other export in that file. One deviation, documented inside the patch:
`memclear(f)`, because this tree's `drm_mode_fb_cmd2` is newer than the struct Rockchip compiled
against and the published version leaves it uninitialised. Nothing else in libdrm is touched.

Cost to Android 14: one added exported symbol, and 224 B in the 32-bit copy. Nothing is removed or
renamed, so no existing consumer can lose a symbol.

### On the build host (Nov 7, verified)

`scripts/apply_tree_patches.sh ../lineage21s` applied it, `scripts/deploy_device.sh ../lineage21s`
redeployed the device tree, and `m -j4 libdrm libdrm_32 libdrm.vendor libdrm.vendor_32` built clean
(`systemd-run --unit=hu-libdrm`, exit 0, 1m16s). The module names are the ones Soong defines: `libdrm`
and `libdrm_32` for /system, `libdrm.vendor` -> `vendor/lib64/libdrm.so`, `libdrm.vendor_32` ->
`vendor/lib/libdrm.so`. No new `PRODUCT_PACKAGES` entry was needed: `device.mk` already lists `libdrm`,
and that is what installs the vendor variants - `out/soong/installs-lineage_rk3399.mk:192595` installs
`vendor/lib64/libdrm.so` from the module's android_vendor variant, and 42 install rules name it as a
dependency. That is the **D20** criterion: the file is an install dependency of `vendor.img`, not a file
someone wrote into the staging dir.

| file | before | after | exported symbol after the patch (`nm -D --defined-only`) |
|---|---|---|---|
| `vendor/lib/libdrm.so` | 58,920 B | 59,144 B | 0 hits -> `0000bf99 T` |
| `vendor/lib64/libdrm.so` | 135,840 B | 135,840 B (same size, new content) | 0 hits -> `00018e80 T` |

(The 86,104 B for lib64 in the older notes is not this build - the vendor variant installed today is
135,840 B.)

`tools/vendor_abi_check.py lineage21s device/rk3399-px6-hct4`, same tree before and after:

| pass | blobs that would not load | detail |
|---|---|---|
| before | 8 | `lib/hw` + `lib64/hw/hwcomposer.rk30board.so` (1 symbol each), `bin/rockchip.drmservice` (1), `bin/usb_dongle` (5), `lib(64)/libomxvpu_dec.so` + `lib(64)/libomxvpu_enc.so` (2 each) |
| after | 6 | the two composer blobs are gone - **0 unresolved in both arches**. Left: `bin/rockchip.drmservice` (`wifi_load_driver`), `bin/usb_dongle` (5 libbase/libcutils listener symbols), and the four `libomxvpu_*` (the declared `GraphicBufferMapper::lock/unlock` gap) |

`tools/consumer_abi_check.py` (new; imports `vendor_abi_check.py`'s pool logic rather than
reimplementing it) checks the other side of the same edge: every installed `/vendor` ELF whose DT_NEEDED
names `libdrm.so`. Twelve of them, all kept Rockchip blobs - the composer itself, `librkisp.so`,
`libbaseparameter.so`, `hw_output.default.so` and the `allocator@4.0-impl-midgard.so` /
`mapper@4.0-impl-midgard.so` gralloc impls, in both arches - all resolve with **0 unresolved symbols**.
Android 14 builds no `/vendor` module that links `libdrm.so` on this product (the minigbm allocator
services exist in the Soong graph but are not requested, and no `/vendor/bin/hw` daemon links the
library), and nothing in /system, /system_ext or /product does - surfaceflinger talks DRM through the
Composer HAL. So there is no consumer this patch could break: it only adds a symbol.

`out/target/product/rk3399/vendor.img` still holds the pre-patch libdrm until the next packaging pass
(`scripts/package.sh` dists and re-syncs it), so the payload must be rebuilt before any flash.

## D23 - the two remaining vendor binaries: patch open source, rebuild published source (Nov 8, DECIDED)

Two blobs were left unresolved after **D21**/**D22**. Both are ordinary vendor programs, not HALs, so
"patch the library / rebuild from source" beats "swap a blob" and beats "declare a gap".

**What they needed, and how it was proved.** `tools/vendor_abi_check.py` (per ELF class, not per
directory) reported 6 blobs that would not load:

| blob | arch | unresolved symbols | provider |
|---|---|---|---|
| `bin/rockchip.drmservice` | ELF32 | 1: `wifi_load_driver` | only `libwifi-hal.so` - and Android 14 compiles that `compile_multilib: "first"`, so `/vendor/lib` has no copy for a 32-bit binary |
| `bin/usb_dongle` | ELF64 | 5: `SocketListener::{startListener,~SocketListener}`, `NetlinkEvent::findParam`, `NetlinkListener::{ctor,onDataAvailable}` | `libsysutils.so` - Android 14 installs only the 32-bit `/vendor/lib/libsysutils.so`, which exports all five; `/vendor/lib64/libsysutils.so` does not exist |
| `lib(64)/libomxvpu_{dec,enc}.so` | both | 2 each: `GraphicBufferMapper::{lock,unlock}` | declared **v1 gap**, untouched here |

The binaries' own `DT_NEEDED`, `nm -D --undefined-only` and strings say what they do:
`rockchip.drmservice` links `libwifi-hal.so` and mentions `/sys/class/net/wlan0/address`,
`/data/misc/wifi/wlan_mac`, `/dev/mtc-car`, `/dev/rknand_sys_storage` - it loads the WiFi driver and
hands the WiFi MAC to the MCU. `usb_dongle` mentions `external/usb_modeswitch/usb_dongle/{main.cpp,
NetlinkManager.cpp}`, `/vendor/etc/usb_modeswitch.d/%04x_%04x` and
`/vendor/bin/usb_modeswitch -W -v %04x -p %04x -c %s &`.

**Route A - `libwifi-hal` gets a 32-bit variant.** `patches/frameworks-opt-net-wifi-libwifi-hal-
32bit.patch` changes `compile_multilib: "first"` to `"both"` in
`frameworks/opt/net/wifi/libwifi_hal/Android.bp`. No other patch was needed: every dependency already
has a vendor_32 variant (`libnl.vendor_32`, `libbase.vendor_32`, `libcutils.vendor_32`,
`liblog.vendor_32`, `libutils.vendor_32`, `libwifi-hal-common_32`, and our own `libwifi-hal-rtk`
arm variant), and Soong installs them as install dependencies - `libnl.vendor_32` appeared in
`vendor/lib/libnl.so` without being added to `PRODUCT_PACKAGES`. The blob is kept, byte-for-byte; the
staged 32-bit blob `lib/libwifi-hal.so` stays dropped (it has 32 unresolved symbols of its own) and
`vendor_dest_deviations.txt` no longer lists `lib/libwifi-hal.so` as lost, because the build now fills
that destination.

| file | before | after |
|---|---|---|
| `vendor/lib/libwifi-hal.so` | not installed | 111,528 B, `wifi_load_driver` and `init_wifi_vendor_hal_func_table` exported (1 hit each) |
| `vendor/lib64/libwifi-hal.so` | 211,592 B | 211,592 B (unchanged) |
| `vendor/lib/libnl.so` | not installed | 174,872 B |
| `vendor/bin/rockchip.drmservice` | 13,020 B blob, 1 unresolved | same blob, 0 unresolved |

**Route B - `usb_dongle` rebuilt from published source.** Rockchip ships it as
`external/usb_modeswitch/usb_dongle`; published mirror used: `gitlabhost.argos-navy.ru/rockchip/
firefly/rk3588_android12`, commit `e12ba531a1ef63b99ce4d8b17b9daf2ea30f69ec`. All thirteen files carry
the Apache-2.0 AOSP header (the helper itself is Apache-2.0; the `usb_modeswitch` program it shells out
to is GPLv2 and is already built from `device/generic/car/emulator/usbpt/bluetooth/usb_modeswitch`).
The mirror's code is the code the blob was compiled from - the blob's strings name exactly its log
messages, its `usb_modeswitch.d` path and its `-DUSE_USB_MODE_SWITCH` branch (`Unable to create/
start MiscManager`). Vendored into `device/rk3399-px6-hct4/usb_dongle/` with a Soong `cc_binary`
(`proprietary: true`, `compile_multilib: "64"`, `init_rc`), which installs `/vendor/bin/usb_dongle`
and `/vendor/etc/init/usb_dongle.rc`; the blob copies of both paths are dropped
(`vendor_dest_skip_extra.txt`). Adaptations are only: `libbinder`/`libhwbinder` dropped (Soong's
visibility forbids them for a vendor module in this namespace - `system/libhwbinder/Android.bp:105` -
and `nm -D --undefined-only` on the blob names no binder symbol, so they were dead DT_NEEDED entries),
extra `-Wno-*` for newer clang, `#include <limits.h>` for `PATH_MAX`, and two mojibake comments
rewritten in English. No semantic change: same uevent handling, same invocation, same `pause()`.

| file | before | after |
|---|---|---|
| `vendor/bin/usb_dongle` | 29,872 B blob copy, 5 unresolved | 135,344 B module output, 0 unresolved |
| `vendor/etc/init/usb_dongle.rc` | 70 B blob copy | 69 B module output (same three lines, blob's trailing blank line gone) |
| `vendor/lib64/libsysutils.so` | not installed | 134,944 B, exports all five legacy symbols |

**Numbers, same tree before and after** (`tools/vendor_abi_check.py`): blobs that would not load
**6 -> 4**; the four left are `lib/libomxvpu_dec.so`, `lib/libomxvpu_enc.so`, `lib64/libomxvpu_dec.so`,
`lib64/libomxvpu_enc.so` with the declared `GraphicBufferMapper::lock/unlock` gap. `/vendor` libraries
went 511 -> 514 (libwifi-hal 32, libnl 32, libsysutils 64).
`tools/consumer_abi_check.py` - Android 14's own consumers of the touched libraries, all 0 unresolved:

| soname | consumers checked | unresolved |
|---|---|---|
| `libwifi-hal.so` | 2 (`android.hardware.wifi-service`, `bin/rockchip.drmservice`) | 0 |
| `libnl.so` | 5 (wifi service, `hostapd`, `wpa_supplicant`, `lib(64)/libwifi-hal.so`) | 0 |
| `libsysutils.so` | 1 (`bin/usb_dongle`) | 0 |
| `libnetutils.so` | 6 (`rockchip.drmservice`, the five libril blobs) | 0 |
| `libhardware_legacy.so` | 9 | 0 |
| `libdrm.so` | 12 (the **D22** consumers) | 0 |

The WiFi stack itself is unaffected: `android.hardware.wifi-service`, `wpa_supplicant`, `hostapd` and
`lib64/libwifi-hal.so` all still have 0 unresolved symbols. Gates: `scripts/prebuilt_vendor.sh ""
../lineage21s` and `scripts/deploy_device.sh ../lineage21s` pass, `tools/vendor_dropped_check.py` says
186 dropped destinations, 184 present, 2 absent and declared (rild + its .rc).

**Consequences worth watching.** `/vendor` grows by ~426 KB (111,528 + 174,872 + 134,944 + 105,472
over the blob it replaced) inside the existing super group, which D8/D19 left unmodified - no
partition change. Both binaries are `class main`, `oneshot`, exactly like the stock ones, and the WiFi
driver is already insmod'ed before class main starts (`configs/init.hu.rc` starts `hu_insmod` on
`early-boot`; Android 14's `system/core/rootdir/init.rc:1206-1209` starts `core` then `main` at
`on boot`), so `rockchip.drmservice` sees `wlan0` when it reads the MAC. `usb_dongle` needs
`/vendor/bin/sh` for its `system()` call - Android 14 builds it (339,792 B). Nothing new is declared
in the vendor manifest; both are init services, not HAL interfaces.
`out/target/product/rk3399/vendor.img` is still the pre-D23 image (Nov 8 build installed into
`out/target/product/rk3399/vendor/`, no packaging pass was run), so the payload has to be rebuilt
before any flash - same caveat as **D22**.

## D24 - head-unit app layer: staged out of the reference payload and re-signed with our platform key (Nov 8, implemented + verified on the build host)

**Decided (owner, Nov 7/8):** the app layer comes from the **reference payload** (`extracted update.zip`),
not off the live unit, because those images are built for this MCU architecture and are meant as drop-ins.
This implements **D6** ("keep the HCT apps for v1") inside M3, without a packaging pass: `systemimage` +
`productimage` only, nothing partition-shaped touched (**D18**/**D19** still stand).

**Provenance and licensing.** The apks and the OEM libraries are Microntek/HCT binaries with no source in
the payload and no licence grant - they are proprietary prebuilts, kept only for feature parity, exactly
like the vendor blobs of **D4**. Nothing here is Apache/MIT; the payload's Google packages (GmsCore, Chrome,
WebView, Velvet, Phonesky, LatinImeGoogle, `~330 MB` of `/product`) were not taken at all. Extracting them
from the payload and shipping them in our own image is a decision about *this* unit; it is not something to
redistribute. Every copied byte is recorded with its sha256 in `analysis/app_layer_inventory.tsv`, and the
two deliberate byte changes are the re-signing and the one dropped init line.

**How they were extracted.** `debugfs` cannot read a `.new.dat` payload, so `product.img` was reassembled
with `tools/reassemble.py` beside the existing `system.img` (`system_ext` is not in the payload at all - the
Android 10 package has system/product/vendor/odm only). Files were read with `tools/ext4_ls.py` and
`debugfs -R dump`, never mounted. Evidence: `analysis/app_layer_stage.md` (narrative),
`analysis/app_layer_inventory.tsv` (48 candidates: package, sharedUserId, target SDK, size, sha256, permission count),
`analysis/app_layer_package_collisions.txt`, `analysis/app_layer_system_abi.txt`.

**Included:** 32 apks into `/system/app`, 5 into `/system/priv-app` (`HCTCanBus`, `HCTManagerService`,
`HCTBlueToothManager`, `HCTExtAppDocker`, `HCTExtScreenClock`), the `/system/bin` control binaries
(`gocsdk`, `gocsdk5`, `gocsdk6`, `gocsdk8`, `gocsdkrf210`, `sdsdk6`, `sdsdk816`, `sdsdk835`, `sdsdk936`,
`sdsdk968`, `blueletd`, `brlinktd`, `sd_carplay`, `dhcpcd`, `ec_usb_filter`, `sd-link.sh`, `z-link.sh`,
`hctlog.sh`, `ethtether.sh`), the OEM libraries a kept binary or apk actually names (`libGbtsTask.so`,
`libbluelet.so`, `libbt_platform.so`, `libbrlinktd.so`, `libbt_platform_brlinktd.so`, `libgocdfu.so`,
`librockchip_update_jni.so` in both arches), the init fragment as `/system/etc/init/hct.rc`, the OEM
`/system/etc` config (`car_filter.xml`, `alarm_filter.xml`, `ec.conf`, `ec_conn_type`, `operator_table`,
`bluesoleil/TL.INI`) and our own `/system/etc/permissions/privapp-permissions-hct.xml`.

**Excluded, with the reason:**
* the framework-coupled forks `HCTSystemUI10` (package `com.android.systemui`, `android.uid.systemui`),
  `HCTSettings10` (`com.android.settings`), `HCT4Launcher3` (`com.android.launcher3`), `HCTProvision10`,
  `HCTPackageInstaller10` (`com.android.packageinstaller`) - Lineage 21 ships SystemUI, Settings, Trebuchet,
  LineageSetupWizard and PackageInstaller built against Android 14 internals, and every one of those except
  Provision collides by package name;
* `HCTExactCalculator10`, `HCTDeskClock10`, `HCTGallery10` - package collisions with ExactCalculator,
  DeskClock and Gallery2 (table in `analysis/app_layer_package_collisions.txt`);
* `HCTCalendar10` (`com.android.calendar`) - not a head-unit feature, and our build installs no Calendar app,
  so it would add Android 10 UI code on API 34 rather than restore something Lineage removed; owner can add it later;
* `HCT4Launcher` (4,606 B stub, package `com.android.launcher`) - the home screen here is Trebuchet;
* `ExtAospBluetooth10` (package `com.android.bluetooth`, `android.uid.bluetooth`) - that is the Android 10
  Bluetooth *stack implementation*, which Android 14 replaced with an AIDL stack; it would crash, not restore Bluetooth;
* all Google/GMS packages, all stock AOSP apps Android 14 builds itself, and every `oat/` directory (Android 14
  dexopts at boot; Android 10's odex/vdex is unusable dead weight).

**Package collision table** (candidates vs the 90 packages our build installs, `tools/hct_apk_inventory.py
--collision`): 7 collisions - `com.android.calculator2`, `com.android.deskclock`, `com.android.gallery3d`,
`com.android.launcher3`, `com.android.settings`, `com.android.systemui`, `com.android.packageinstaller`.
Nothing included collides: `HCTAudioPreview` is `com.android.music` while Lineage's player is Jelly
(`org.lineageos.jelly`), and `HCTCalendar10`'s `com.android.calendar` is not installed by anyone (our
`CalendarProvider` is `com.android.providers.calendar`).

**Signing decision.** Seven included apks declare `android:sharedUserId="android.uid.system"`
(`HCTCanBus` `android.microntek.canbus`, `HCTManagerService` `android.microntek.service`,
`HCTBlueToothManager` `android.microntek.mtcser`, `HCTExtAppDocker` `com.microntek.externshow`,
`HCTExtScreenClock` `com.microntek.extscreenclock`, `HCTAudioPreview` `com.android.music`,
`HCTFactorySettings` `com.hct.factory`). PackageManager refuses an apk that claims a system shared uid when
it is not signed with this build's platform certificate, so they cannot be shipped as-is.

| certificate | sha256 of the cert DER | who has it |
|---|---|---|
| our platform cert (`build/make/target/product/security/platform.x509.pem`) | `c8a2e9bccf597c2fb6dc66bee293fc13f2fc47ec77bc6b2b0d52c11f51192ab8` | `framework-res.apk`, `SystemUI.apk`, `Settings.apk` in our tree |
| the payload's own Android key | `2d370c21f5dfd553d2a796314b70925fb38adeef90864c920bbbbb12887d3522` | every HCT/Microntek apk in the payload (same `CN=Android` subject, different key) |
| `testkey.x509.pem` | `a40da80a59d170caa950cf15c18c454d47a39b26989d8b640ecd745ba71bf5dc` | `default_system_dev_certificate`, not what platform modules get |
| LineageOS release key | `518325ef7f96c0d1194c2e856b040d636166ffb846717d72fa87f4fae5be7bbb` | `extra_recovery_keys` only |

So the payload's signature is *not* ours, and the key material behind it is not in the payload either (it is
the OEM's private `platform.pk8`, unrecoverable). All 37 apks are therefore re-signed by Soong with
`certificate: "platform"` in `device/rk3399-px6-hct4/apps/Android.bp`, which resolves to
`build/make/target/product/security/platform.{pk8,x509.pem}` (`processMainCert`, `build/soong/java/app.go:664`)
and runs the build's own `signapk` - the same key the framework, SystemUI and Settings carry. Signing the whole
kept set with one key is also what keeps the signature permissions between the HCT apps working
(`android.permission.HCT_FACTORY` is declared by `HCTFactorySettings` and used by others). `apksigner` cannot
be run standalone on the build host (`out/host/linux-x86/bin/apksigner` needs `java`, not installed there), so
verification is done on the installed apks: certificate digest with `tools/hu_apk_cert.py` (openssl PKCS7) and
package + `sharedUserId` with `tools/hct_apk_inventory.py`.

| apk | sha256 before (payload copy) | sha256 after (installed) | package + sharedUserId after | cert digest after |
|---|---|---|---|---|
| `system/app/HCT4Radio/HCT4Radio.apk` | `b7322b3dfea178f74a297774b491251c5fac7cbb39c4313fd7d563ad5355a6ac` | `3219278c2f681c1023717a035c27cf2309c4f6061c567b8c307803af583c3f12` | `com.microntek.radio`, no sharedUserId | `c8a2e9…2ab8` (ours) |
| `system/priv-app/HCTCanBus/HCTCanBus.apk` | `90c587fcf3657d8f4a67f8033bcadc9f3159d469d89890cb699cbd871af15857` | `c7a97a119013ed10bc3b056cf94c20e4fe99ff9e1b095a2d5932af02c3227206` | `android.microntek.canbus`, `android.uid.system` | `c8a2e9…2ab8` (ours) |

Verified on the installed apks (`scripts/verify_hu_apps.sh`, Nov 8): `framework-res.apk`, `HCT4Radio.apk` and
`HCTCanBus.apk` all carry cert digest `c8a2e9bccf...` - the same platform certificate - and
`HCTManagerService.apk` keeps `android.microntek.service` + `android.uid.system`.

**Privapp whitelist.** The payload ships no HCT whitelist (its `/system/etc/permissions` has only the AOSP
platform and Google ones), so we write our own: `/system/etc/permissions/privapp-permissions-hct.xml`, generated
from the apk manifests (`tools/hct_apk_inventory.py --perms`), one `<privapp-permissions>` block per kept priv-app
package. Android 14 enforces it strictly only on `user` builds; on `userdebug` a missing entry is a log line. It is
best effort for v1 - some permission names the apks request no longer exist in Android 14 (`SERIAL_PORT`,
`READ_OWNER_DATA`, `REAL_GET_TASKS`, `GET_TOP_ACTIVITY_INFO`, `RUN_INSTRUMENTATION`, `SYSTEM_OVERLAY_WINDOW`,
`SET_PREFERRED_APPLICATIONS`), so those apps lose the feature that depended on them rather than failing to install.

**Sizes and the super group** (**D19**: no size change, no GPT write, no resize):

| image | before (Nov 6 pass) | after, Nov 8 rebuild | delta |
|---|---|---|---|
| `system.img` | 929,140,736 B | 1,012,817,920 B | +83,677,184 B |
| `product.img` | 456,159,232 B | 456,159,232 B | 0 |
| `system_ext.img` | 384,802,816 B | unchanged | 0 |
| `vendor.img` | 484,196,352 B | 444,424,192 B | -39,772,160 B |
| `odm.img` | 811,008 B | unchanged | 0 |
| total logical content | 2,255,910,144 B | 2,299,015,168 B | +43,105,024 B |

The vendor delta is not the app layer: `m vendorimage` on Nov 8 finally applied the **D21** drop list
(the Android 11 blob `wpa_supplicant`/`hostapd`/`wifi@1.0-service`/`libwifi-hal`/`librkwifi-ctrl` copies
are gone, Android 14's own WiFi stack took their place), plus the **D22** patched libdrm and the **D23**
files (`usb_dongle`, 32-bit `libwifi-hal`/`libnl`, `libsysutils`) - `vendor/lib/libdrm.so` and
`vendor/lib64/libdrm.so` export `drmModeAddFB2_ext` in the new image, and `vendor_abi_check.py` still
counts 4 unresolved blobs (the declared libomxvpu gap). The app layer itself is `~33 MB` of apks
(`analysis/app_layer_inventory.tsv`); the rest of the `system.img` delta is Lineage's own dexpreopt output
that the Nov 6 pass did not carry. Nothing in `misc_info.txt` or the GPT changed (**D19**).

**Gates** (all run on the build host Nov 8, one pass: `scripts/archive/run_d24_gates.sh`, launched with
`nohup` over ssh - **not** systemd-run: a systemd unit's environment makes `build/envsetup.sh` fail with
`TOP: unbound variable`, and the script must not `set -u` for the same reason):
`bash scripts/deploy_device.sh ../lineage21s` exit 0 (it now also checks that every `apk:` in
`apps/Android.bp` exists); `tools/vendor_conflicts.py` exit 0, "no collisions - the copy list can be
parsed" (1021 staged destinations vs 5943 build install targets under /vendor); `m -j4 systemimage
productimage` exit 0 (22 s incremental - the tree builds the app layer reproducibly from a fresh deploy);
`scripts/verify_hu_apps.sh` reports 32 `system/app` + 5 `system/priv-app` HCT dirs, 0 `oat/` dirs under any
HCT app dir (the 53 oat dirs that exist are Lineage's own dexpreopt, not copied Android 10 ones), the init
fragment byte-identical to the payload apart from the dropped `import /init.hct.camera.rc` line, 35 system
destinations copied and 0 colliding with a module install rule in `out/soong/installs-*.mk`;
`vendor_dropped_check.py`: "every dropped destination is present, substituted, or declared as a deviation".
No packaging pass, no OTA zip, no `superimage` (the sizes are read from `misc_info.txt`, not written).
The group `super_hct_dynamic_partitions_group_size=3258974208` (super device 3,263,168,512 B over
`system vendor product system_ext odm`) holds: 2,299,015,168 B of content leaves 959,959,040 B spare, so
it fits with no resize.

**A regression the verification caught.** The agent's `device.mk` edit had swallowed a newline: the
`PRODUCT_COPY_FILES += \` line ended up glued to the comment above it, which in Make makes the whole
line a comment *and swallows the continuation* - the four HU vendor copies (`fstab.rk30board`,
`ueventd.rc`, `init/hu.rc`, `hu_insmod.sh`) silently left the copy list, and `vendor_conflicts.py`
could not see it because it reads the file, not kati. Fixed by restoring the newline; the Nov 8
`vendorimage` rebuild proves the four files land in `out/.../vendor/etc/` and inside `vendor.img`
(`scripts/archive/run_d24_vendor_fix.sh`). Lesson recorded: a product-config .mk edit must be checked with
`grep -n PRODUCT_COPY_FILES` on the *deployed* copy, and `verify_hu_apps.sh` only covers the system side.

**What still breaks at first boot** (all of these are honest gaps, not guesses):
* **Bluetooth is not restored.** No `com.android.bluetooth` exists in our build at all: no install rule for
  `Bluetooth/Bluetooth.apk` in `out/soong/installs-lineage_rk3399.mk`, and no product config asks for it. The
  payload's `ExtAospBluetooth10` cannot fill that hole (Android 10 stack on Android 14 framework internals).
  The fix is Android 14's own `Bluetooth` module in `PRODUCT_PACKAGES` plus a Bluetooth HAL the vendor namespace
  can serve - a separate product-config decision, recorded here rather than folded into this step.
  `HCT4BlueTooth`, `HCT4BtMusic` and `HCTBlueToothManager` will install but have no stack to talk to.
* **The controller daemons do not resolve.** `tools/hu_system_abi_check.py`: `gocsdk`, `gocsdk6`, `gocsdk8`,
  `sdsdk6`, `sdsdk816` (and `gocsdkrf210`) need Android 10's `AudioTrack`/`AudioRecord` constructors and
  `MediaPlayer` ctor (`_ZN7android10AudioTrackC1E...`, `AudioRecord::getMinFrameCount`, `_ZN7android11MediaPlayerC1Ev`)
  which Android 14's `libaudioclient.so`/`libmedia.so` do not export - 3-4 symbols each, 32-bit. `gocsdk5`,
  `gocsdkrf210`'s `libGbtsTask.so`, `blueletd`, `brlinktd`, `dhcpcd` resolve cleanly. BT call/SCO audio and the
  controller-side audio path therefore fail at first boot; the candidate fix is the same shape as **D22**/**D23**
  (a compat shim, or the payload's Android 10 `libaudioclient.so` in a private directory with
  `setenv LD_LIBRARY_PATH` in the service definition - not tested here, and swapping it into `/system/lib` would
  put Android 14's own 32-bit consumers on an Android 10 ABI, so it is not done).
* **Some services the init fragment names have no binary in the payload**: `hctcanbusservice` (the CANBUS service),
  `sdsdk`, `sd-reverse.sh`, `adb-ec-server.sh`, `start_usbmuxd.sh`, and `wb.ko`/`wlan.ko`/`sd_wb.ko` - those service
  lines stay dead. `HCTCanBus` talks to `/dev/mtc-car` directly from Java, so CAN itself is not blocked by this,
  but the `hct.canbus.service=1` route does nothing.
* **CarPlay/Android-Auto helpers need third-party apps.** `sd_carplay` links `libspeedplay.so`, which lives in the
  data dir of `com.suding.speedplay` (not in the payload), and `sd-link.sh`/`z-link.sh` call `sd_mdnsd`, `z-link`,
  `z-mdnsd`, none of which the payload contains; several apps reference `com.zjinnova.zlink` / `com.suding.speedplay`.
* **`/mnt/oem` and `/etc/bluesoleil` cannot be made writable.** `init.hct.rc` does `mkdir /mnt/oem` and
  `mkdir /etc/bluesoleil`; on Android 14 `/etc` is a symlink into the read-only `/system/etc`, so those
  `mkdir`/`chown`/`chmod` lines fail (they failed on Android 10 the same way). Anything that stores state there
  loses it. Also the `chmod`/`chown` of `/dev/mtc-*`, `/dev/ttyS*`, `/dev/ttyV*`, `/dev/goc_serial` only work while
  SELinux stays permissive, which it does today because the shipped boot image carries
  `androidboot.selinux=permissive`; hardening SELinux (**D5**/P6) needs those device nodes handled in ueventd +
  sepolicy instead.
* **Android 10-era apps on API 34.** Every kept apk targets SDK 22..29. Hidden-API and non-SDK interface
  restrictions, the runtime-permission model, and removed APIs (`GET_TASKS`/`REAL_GET_TASKS`, `SERIAL_PORT`,
  `INJECT_EVENTS` for non-platform callers, `SET_PREFERRED_APPLICATIONS`) mean specific features - preferred-app
  replacement, the serial-port route, overlay behaviour, "kill background processes" - may fail even though the
  apk installs. The touch/button and sound-input paths specifically: `HCTCarTouch` installs and is signed with the
  platform key (so `INJECT_EVENTS`/`SYSTEM_ALERT_WINDOW` are granted), but whether Android 14's input stack lets it
  inject is a device-test question; sound input through the framework's `AudioRecord` from Java is unaffected, while
  the controller-side daemons above are.
* **Dexopt cost at boot.** No `oat/` is shipped, so the first boot dexopts 37 apks (this is intended; it makes the
  first boot slower and the second one normal).

## Packaging pass Nov 8 - dist, super, the HU payload, and its offline verification

Canonical record: see `docs/findings.md`, section "Packaging pass Nov 8 - dist, super, the HU payload, and its offline verification".

## Bluetooth route - what a fix would take (note, Nov 8, NOT decided or implemented)

Bluetooth is the one headline feature that is fully absent, and the offline picture is now clear:

* **The framework app is not in the tree at all.** Android 14 moved Bluetooth out of AOSP's
  `packages/apps/Bluetooth` (which does not exist in `lineage21s`) into the LineageOS-maintained
  `packages/services/Bluetooth` project - it is simply not cloned in this tree, and no product config
  requests it. That is the same class of step as **D21**: fetch an Apache-2.0 upstream project
  (`github.com/LineageOS/android_packages_services_Bluetooth`, branch `lineage-21.0`) and request its
  `Bluetooth` module. Unlike the WiFi HAL glue, this one is a large app build (JNI, AIDL, permissions),
  so it is a real build step, not a one-file glue.
* **The vendor HAL is already staged and resolves.** `vendor/hct4/tree/vendor/bin/hw/android.hardware
  .bluetooth@1.0-service` + its `.rc` exist, and `blob_deps.py` shows every DT_NEEDED resolves - the
  Nov 8 `vendor_abi_check.py` counts only the declared codec gap. So the HIDL bluetooth HAL *starts*;
  what is missing is a framework that speaks to it (Android 14 dropped HIDL bluetooth). Whether
  Lineage's `packages/services/Bluetooth` keeps a legacy-HIDL transport on `lineage-21.0`, or whether a
  Realtek/AIDL glue must be built (the WiFi analogy done properly: Lineage has Realtek bluetooth glue
  in `github.com/LineageOS/android_hardware_realtek`), is the open question - the same shape as D21's
  "find the published glue, build it, wire `PRODUCT_PACKAGES`".
* **The MCU-controller audio path is separate.** `gocsdk`/`sdsdk` fail on 3-4 Android 10 audio symbols
  (D24); phone-call audio over the MCU will stay broken until a compat shim exists, regardless of BT.

Decision deferred deliberately: the owner's order is **boot first**, then judge, then fix BT as a
second pass with the probe report in hand. The probe is baked into the ROM for exactly that.

**v1 feature losses restated (Nov 8, after the audio/video question).** Three headlines are not equal:

* **Bluetooth is fully absent** - no framework app, as described above. Everything BT (calls, BT music,
  the phone-audio route) is out until this route lands.
* **Audio *output* is not declared broken.** `audio.primary.rk30board.so` resolves with 0 unresolved
  symbols, `blob_deps.py` shows every DT_NEEDED present, and the audio HAL + `audio.effect` are in the
  VINTF vendor manifest with verdict COMPATIBLE. So playback through Android 14's AudioFlinger into the
  AMP is expected to work; what fails is the **MCU/controller audio path** (`gocsdk`/`sdsdk` on 3-4
  Android 10 `AudioTrack`/`AudioRecord`/`MediaPlayer` symbols, D24) - call/SCO audio and controller-side
  routing, not music out. The probe separates the two (`audio.primary` process vs `CANNOT LINK` lines).
* **Video playback is half broken.** Android 14's own Codec2 software codecs are installed, so an app on
  the `MediaCodec` API decodes AAC/MP3/H.264 in software. The legacy Stagefright/OMX path is dead: the
  Rockchip VPU OMX libs (`libomxvpu_dec/enc`, both arches) do not load (declared gap) and
  `libstagefright_softomx_plugin.so` never reached `vendor.img`, so `android.hardware.media.omx@1.0-service`
  has no soft OMX codecs either. Whether each HCT movie app is on the old MediaPlayer path or MediaCodec
  is a device question - the probe's logcat errors per app answer it.

Both fixes, if wanted, are the same shape as D22/D23 (patch Android 14's own library or add the missing
module), not blob swaps: an OMX/mapper shim for the codecs, and the audio-symbol shim for the daemons.

## No terminal on the unit: how first-boot diagnostics reach us (Nov 8, snag reported by the owner)

Canonical record: see `docs/findings.md`, section "No terminal on the unit: how first-boot diagnostics reach us (Nov 8, snag reported by the owner)".

## Post-boot probe (`/system/bin/hu_probe.sh`, Nov 8)

`hu_system/bin/hu_probe.sh` is ours (not payload), copied to `/system/bin` through `hu_apps.mk`, so it
survives every flash. Read-only; writes only its report file. It prints/saves one markdown report with
the owner's success criteria as headings - boot cmdline + SELinux, WiFi (`wlan0`, driver, `iw reg`,
daemon list), Bluetooth (expected empty), touch/buttons (`getevent -L`, `/dev/mtc-*`), CANBUS
(`/dev/mtc-car`), audio HAL + `/proc/asound/cards` - and the error/warning logcat lines per subsystem
plus `CANNOT LINK` lines from `dmesg`. Delivery matches the Nov 5 probe pattern plus the stick
fallback: `curl -T` to a workstation URL when WiFi is up, `/mnt/udisk` copy when a stick is mounted,
stdout otherwise. Usage is in `docs/flash.md` "First boot".

## D25 - transport: the payload cannot be signed for this recovery, so flash raw images from Android 11 (Nov 8, DECIDED)

**What happened.** The first flash attempt was rejected before anything was written:
`Verifying update package... / E:footer is wrong / E:Signature verification failed / E:error: 21 /
Installation aborted`, and the recovery menu reports `android recovery by HCT V10 3.1`,
`10/QQ2A.200305.004.a1/hct2041215506`, `userdebug/test-keys`. Nothing partition-shaped was touched.

**Why, proven offline (not guessed).** Recovery verifies the package *before* running anything in it.
The two OEM packages we hold carry no ASHU footer at all - `tools/zip_comment_sig.py` finds zero
`ASHU\0\0\0\0` occurrences and instead shows a 1,573 B **zip EOCD comment**: prefix
`signed by SignApk\0` + 1,555 B DER PKCS#7 SignedData, signer cert

```
subject/issuer: C=US, ST=California, L=Mountain View, O=Android, OU=Android,
                CN=Android, emailAddress=android@android.com
cert sha256:    cf2ab3818595c4ed a08cec72bbe39bc3 77a30b764a3e ebde52536eae01808525
```

identical in the Android 10 package (1,203,718,969 B, sha256 `dd3e2ac0610bb64f…`) **and** the
Android 11 package (1,477,122,869 B, sha256 `50775dba8ca9f992…`). Our payload's comment length is 0,
which is why recovery called it "footer is wrong" and then failed the signature.

**Which key is trusted.** `/system/etc/security/otacerts.zip`, dumped with `debugfs` out of *both*
stock system images (`analysis/daisaita_a10/system.img`, `analysis/daisaita_a11/system.img`), contains
exactly one cert - file name `testkey.x509.pem`, fingerprint `cf:2a:b3:81:85:95:c4:ed…`. So HCT
replaced the AOSP tree's testkey with a key of their own carrying the same `CN=Android` subject. The
fingerprints we hold do not match it: AOSP `testkey.x509.pem` is `a40da80a…`, our
`platform.x509.pem` is `c8a2e9bc…`, Lineage's release key is `518325ef…`, and the payload's apk key is
`2d370c21…`. None of them is `cf2ab3…`, and its private half is not in any package or vendor tree we
have (searched: zero `*.pk8`/`*.x509.pem` outside the AOSP security dir). **A package we sign cannot
pass this recovery's check**, and a testkey-signed package would fail the same way.

**Decision.** Keep the recovery partition exactly as it is (**D18** still holds for the partition, not
for the transport) and install through the channel already proven to work on this unit: the Android 11
ROM's own root shell (`/system/xbin/su 0`, Termux carries `dd`/`sha256sum`/`blockdev`).
`scripts/flash_from_android.sh` reads the images off the stick, verifies them against `sha256.txt`,
backs up the head/tail of super and the current boot partition to the stick, then writes `super.img`
(Android 14's system/vendor/product/system_ext/odm **plus** its dynamic-partition metadata, which lives
inside super) and `boot.img`. Exactly two partitions, no resize, no GPT write, no
recovery/uboot/trust/dtbo/RKLoader/logo/security write (**D11**/**D19**). `/data` is *not* wiped from a
mounted Android 11 - the clean wipe is recovery's own "wipe data/factory reset" afterwards (**D10**).
Rollback stays the stock Android 10 package, installed the normal recovery way, because recovery is
untouched and still trusts `cf2ab3…`.

**Images for that transport** (rebuilt Nov 8 20:32 so they carry the auto-probe and the adb key):
`super.img` 2,275,747,780 B, sha256
`2045af9c2d730aa5cb76df48e8a081b677ccf74a3272dbd1d2419aaf8162ff69`; `boot.img` 32,796,672 B, sha256
`83fd2a15c74424e8a6c9663dfa89339a77de8ea53b9659e7e3e58819609104f8`. `super.img` starts with the
dynamic-metadata magic (`ed26ff3a`, raw, not sparse) and its metadata names system/system_ext/
vendor/product/odm plus the group `hct_dynamic_partitions`, so one `dd` recreates the logical layout
inside the unchanged 3,263,168,512 B partition.

**Signing script anyway.** `scripts/sign_hu_package.sh <in-zip> <out-zip> [cert] [pk8]` runs the
tree's own `out/host/linux-x86/framework/signapk.jar` with `prebuilts/jdk/jdk17` (and
`-Djava.library.path=$TREE/out/host/linux-x86/lib64`, because SignApk signs through conscrypt's JNI
library - without that the JVM throws "no conscrypt in java.library.path") and puts
`signed by SignApk\0` + PKCS#7 into the comment: zip in, zip out, nothing more. It reproduces the stock
format exactly. It installs only if the cert handed to it is one the recovery trusts - if HCT's
`cf2ab3…` private key is ever obtained, this same script signs with it.

**Payload signed (Nov 8, second pass).** `scripts/sign_hu_package.sh` ran on the build host and produced
`aospbuild/tmp/hu-package/update-signed.zip`: **945,046,226 B**, sha256
`b81c50cc3eb07b8b0ba5a3ab7f518d8ba2a0339801608c892bbd640e52d04407` (workstation `out-hu/update.zip`, same
sha). Comment 1,738 B = `signed by SignApk\0` + 1,720 B DER PKCS#7, signer cert `a40da80a…` (AOSP
testkey). `unzip -tqq` clean; the entry set is unchanged except SignApk's own `META-INF/com/android/otacert`
(the stock packages carry one too, 1,440 B) and the four directory entries SignApk drops; the
updater-script audit is unchanged: zero uboot/trust/dtbo/RKLoader/loader/security/recovery writes. Route 1
in `docs/flash.md` is flashing this through recovery - a rejection writes nothing, because verification
happens before the updater-script runs. Route 2 is the raw-image transport above.

**Ordering if route 1 is rejected (Nov 8, owner plans a modded ROM next).** Try route 2
(`scripts/flash_from_android.sh`) before installing a third-party mod ROM such as Malaysk or Hal9k.
Route 2 needs nothing new: it writes only super + boot, leaves the stock recovery intact, and the stock
Android 10 package stays installable as the rollback. A mod ROM is a different trade: those images ship
their own recovery plus `uboot.img`/`trust.img`/`dtbo.img`/loader writes, which is precisely the boot
chain that left units stuck at the logo or black-screen with no recovery in the Dasaita thread (**D18**
exists to avoid exactly that), and the mainboard's MCU firmware update path may only be reachable from
the stock recovery. They are also Android 9/10 vendor builds, so installing one replaces the Android 14
line rather than installing it - it becomes a stepping stone whose recovery then has to accept our
package, with a recovery we did not build. If it is ever used, dump the stock recovery first, read-only:
`dd if=/dev/block/by-name/recovery of=/mnt/udisk/recovery-stock.img bs=4096` (needs root, writes only
the stick), which gives both a restore copy and the recovery's trusted cert bundle to read offline.


**Backup naming, so a rollback cannot be mislabelled.** Android 10 = the July 2021 package
(1,203,718,969 B, sha256 `dd3e2ac0…`, build.prop `QQ2A.200305.004.A1`, release 10); Android 11 =
`daisaita_a11.zip` (1,477,122,869 B, sha256 `50775dba…`, build.prop `RQ3A.210705.001`, release 11).
Nov 9 added a third package (`diatsia fw/update(1).zip`, 1,285,817,036 B, sha256 `31bb492a…`) which is
**also Android 10** - the vendor's April 2025 rebuild, release-keys, same trusted cert - so it is the
better rollback; on the stick it is `backup/a10-2025-update.zip`. Full identity table:
`docs/findings.md`, "OEM reference packages on disk".
On the stick they belong in `backup/a10-update.zip` and `backup/a11-update.zip`; rename one to
`update.zip` at the stick root only when a rollback is actually wanted, because some HCT firmware
offers an automatic firmware update the moment it sees `update.zip` at the root.

## SD-card flashing (the Malaysk "SD_firmware_tool" idea) - what this uboot actually supports (Nov 8, measured)

Canonical record: see `docs/findings.md`, section "SD-card flashing (the Malaysk "SD_firmware_tool" idea) - what this uboot actually supports (Nov 8, measured)".

## D26 - the SD/`update.img` restore media is deliberately not built (Nov 9, DECIDED)

Research verdict (`docs/findings.md`, "SD-card / `update.img` route - Nov 9 research verdict"): Rockchip's
SD-upgrade-card flow and its USB-stick variant write the **loader** and the **recovery** partition
unconditionally, and a `parameter`-driven flash recreates the partition table. That violates **D18** and
**D19**, and ~~this HU has no wired `sdmmc` slot for a card to boot from~~ (**corrected Nov 10:** the unit
has microSD slots and u-boot scans `mmc1` before the eMMC, so a card is reachable), so the route cannot be
made safe here. Building the media offline would be harmless but unusable without breaking those decisions, so we
do not build it. Insurance instead: untouched stock recovery + OEM packages (any of the three, all signed
by `cf2ab3…`), ~~the 62.8 GB full-eMMC snapshot on the HDD archive~~ - **that snapshot is not insurance**:
measured Nov 10 `analysis/gpt/disk.img` is zero everywhere except a protective-MBR remnant at byte 448 and
the backup GPT in the last 4 MB (`docs/findings.md`, "What the Nov 5 \"full eMMC snapshot\" actually
contains"), and `gpt_head.bin` is all zeros. What does survive is the backup GPT in `gpt_tail.bin` plus the
Nov 4 probe's LBA table, which is enough to rebuild the partition table by hand.

**Superseded on Nov 9 by D29**: the owner chose the bootable SD burn as this unit's rollback path, so the
media is on the table again - with the loader/IDB risk acknowledged, and now built as a **boot card**
carrying our own rescue initramfs (**D31**) rather than an upgrade card that needs a recovery we do not
have.

## D27 - upstream contributions are registered, not submitted (Nov 9, DECIDED)

`docs/upstream.md` holds the candidate register plus the verified review/licensing rules
(Lineage = Gerrit + charter, SELinux enforcing, blobs via extraction scripts, Apache Category A; AOSP =
CLA + Gerrit, `external/*` fixed upstream first; Lineage wiki changes also go through Gerrit). No change
is submitted until the unit boots and the real feature gaps are known, so we do not spend review goodwill
on speculative patches. Two standing rules from that register: code that is **already** upstream in
Lineage (`libwifi-hal-rtk` in `LineageOS/android_hardware_realtek`, already `compile_multilib: "both"`)
should be depended on instead of vendored in our device tree, and our workstation's adb **public** key
must leave the device tree before any bring-up recipe is published.

## D28 - bring-up access: TCP adb opened by the factory-settings password `adbon` (Nov 9, DECIDED)

USB adb is impossible on this board - every HU socket is host-mode, and the laptop's Type-C port is a
correct host (`data_role=host`, `power_role=source`) that saw **no partner at all** on every socket the
owner tried, including the Android Auto one. Nothing enumerated, `adb devices` stayed empty. The shipped
firmware also has no developer options: tapping the build version repeatedly is a no-op, so USB/wireless
debugging could not be enabled, and network adb was off because `persist.internet_adb_enable` was unset
(ports 22 23 5555 5037 8765 2300 9000 4000 all closed while ping answered).

**The owner found the lever:** the HU factory-settings dialog accepts **`adbon`** instead of `126`, which
enables adb for that session. That sets `persist.internet_adb_enable=1`, the OEM init then sets
`service.adb.tcp.port=5555`, and from the workstation:

```
adb connect 192.168.1.120:5555      # -> device product:rk3399 model:PX6 device:rk3399
adb root                            # -> restarting adbd as root
adb -s 192.168.1.120:5555 shell id  # -> uid=0(root) ... context=u:r:su:s0
```

No authorization prompt appears (`ro.adb.secure` is empty, `ro.debuggable=1`). So this is the standard
transport for bring-up on this unit: **TCP adb over the LAN, root shell, no USB, no terminal on the HU**.
Two properties of it to remember: the prop lives in `/data/property`, so it only survives if the OS that
boots next mounts the same `/data` and reads it the same way; and it is per-session, so the password has
to be entered again after a reboot of the old firmware.

## D29 - rollback policy after the Nov 9 write: SD burn is the owner's chosen blind path (Nov 9, DECIDED, revises D26)

D26 said the SD/`update.img` media is deliberately not built, because Rockchip's SD flow writes the
**loader** and the **recovery** partition and a `parameter`-driven flash recreates the partition table.
The owner now overrides that for this unit: *"go nuclear with the bootable SD card like how I first
unlocked my PX5"*, *"make it a bootable card and go the .img burn route"* - the SD burn is accepted as the
rollback/flash path, exactly as it was used to unlock the PX5 unit. That is a deliberate risk decision,
not an oversight: the card flow touches loader/IDB.

The gate stays technical, not policy: **do not build or burn a card until it is verified that
`fw_update=2` (upstream passes `bUpdateIDBlock=false`) skips the loader/IDB write on this uboot.** That
has not been verified offline. Until it is, the rollback options are a serial console (`console=ttyFIQ0`,
115200 8N1, 3.3 V) `dd` of the OEM `super`/`boot`, or a serial/dd path from a root shell if one appears.
Recovery-menu rollback is not available: no button combo the owner tried reaches that menu.

## D30 - the Nov 9 write left the unit running Android 14 with a black screen (Nov 9/10, RECORDED)

Full log: `docs/findings.md`, "Flash attempt Nov 9/10". The short version, as a decision record:

* `super` (2,275,747,780 B) and `boot` (32,796,672 B) were written with verified shas; `recovery`,
  `uboot`, `trust`, `dtb`, `dtbo`, `vbmeta`, `security`, the loader and the GPT were **not** touched, so
  the OEM boot chain is intact - the unit is not bricked in the sense of a destroyed bootloader.
* The unit then showed **black screen, no boot animation, no OEM logo**, WiFi disappeared (`No route to
  host`), and TCP adb died with it. Android 14 cannot recover Android 10's Wi-Fi credentials, and
  `persist.internet_adb_enable=1` lives in `/data`, so D28's transport does not carry over - a shell on
  first boot is not assumed, only checked.
* The payload itself passed every offline audit that could be done without a display (coherent `lpdump`
  layout with ext4 slices matching an ext4 `fstab.rk30board`, AVB not enforced). ~~Prime suspect is the
  display stack: the vendor declares HIDL `composer@2.1::IComposer/default` plus OEM Midgard
  allocator/mapper blobs, and Android 14 may require AIDL composer3/allocator/mapper.~~
  **Re-measured Nov 10 (**D32**): the prime suspect is now the DTB - our DTB drops the OEM LVDS panel
  timings `mtc,panel_index` 0x21..0x26 and retimes timing4/17/76, which is the one measured difference
  between the firmware that works and ours. The kernel we flashed is also not the shipped one
  (`4.19.193 #24` vs `4.19.111+ #190`). `mali_kbase.ko` in our vendor slice is `vermagic=4.4.167` against
  a `4.19.193` kernel, but the OEM vendor ships the same mismatched module against its own kernel and
  Mali is built into both kernels - so that is a defect to clean up, not the cause. The earlier
  "byte-comparable boot header" audit was weaker than it sounded: Rockchip uses a different boot-header
  field order than AOSP. The composer question stays open. **The next attempt must not be flashed without a
  serial console reading first** - guessing at a second write costs the unit.

## D31 - rescue payload rebuilt from the OEM package; the SD media becomes a boot card (Nov 9/10, IMPLEMENTED offline)

Because the Nov 5 eMMC dump turned out to be empty (**D26** correction), the rollback payload is rebuilt
from the vendor's April 2025 Android 10 package instead of restored from a dump. The rebuilt payload is
built, verified and stored on the NAS archive
`/srv/50911774-19fb-46b6-bc9e-8cf81623d044/aospbuild-archive/vibe-rescue/`:

* `super-a10.img` - 3,263,168,512 B, sha256 `30da961c94ba064d1edce80d5dc3b96ad5ec7480a4971b8ca38d1bdb2cefc11c`;
  OEM Android 10 layout (`rockchip_dynamic_partitions`, max 3,258,974,208 B; system 1,275,330,560,
  vendor 323,530,752, product 986,509,312, odm 539,951,104 at super sectors 2048 / 2494464 / 3127296 /
  5054464). Verified by `lpdump` *and* by carving the system slice and reading it with `debugfs`
  (`init.hct.rc`, `init.rc`, `/system/build.prop` present). No resize beyond the OEM op_list (**D19**).
* `boot-a10.img` - 27,406,336 B, sha256 `04a43ea931de08734d8a25afe9920cba69a099095ab4b4490dbbe4368d0b89c6`
  (the package's own boot image; the previously installed boot backup died with adb on the unit, so this is
  the vendor boot, which is the right rollback semantics).
* Nothing else is needed for a rollback: `uboot`/`trust`/`dtbo`/`RKLoader.bin` stay exactly as the vendor
  shipped them (**D18**), and the restore writes only `super` + `boot`.

The SD media is built as a **boot card** (IDB flag `1`), not an upgrade card: the upgrade flow hands
control to a recovery that flashes `update.img`, and we have no recovery image for this board (the OEM
packages carry no `recovery.img`, and the recovery menu is unreachable on this unit per the owner). On a
boot card u-boot loads the boot image from the SD slot and runs it, so the card carries a rescue initramfs
whose only job is: mount the card, verify the shas, `dd` `super-a10.img` onto
`/dev/block/by-name/super` and `boot-a10.img` onto `/dev/block/by-name/boot`, then reboot. That path needs
no signature, no recovery, no panel, and it is fully readable over the serial console before a single byte
is written.

Rockchip's Linux tools for this are staged in `/tmp/opencode/rktools/` (`afptool`, `rkImageMaker` with
`-storage:SD`, `upgrade_tool`, `programmer_image_tool`, `firmware_merger`, the `sdcard-update-package-file`
and `rk3399-mkupdate.sh` templates), and the OEM loader `RKLoader.bin` (465,230 B, `BOOT` header magic) is
extracted. **The card has not been written to any physical medium yet.** Before it is, four things must be
measured on the desk setup: which slot is u-boot `mmc1`, whether BootROM accepts the card's loader, whether
this u-boot's IDB parser accepts an image built with `rkImageMaker -storage:SD` + `RKLoader.bin`, and where
the card-type flag byte actually lives in the header. See `docs/findings.md`,
"Unbrick SD route - Nov 9/10".

## D32 - the measured defect list for the Nov 9 payload; outside diagnosis reconciled (Nov 10, DECIDED)

The owner asked an outside model for a diagnosis (kernel/DTB mismatch, missing vbmeta patch, dynamic-partition
layout mismatch, uboot/trust mismatch). Checked against measurements on the payload that is on the unit now
(`docs/findings.md`, "Reconciling the outside diagnosis (Gemini, Nov 10)"), the verdict is:

* **Confirmed and sharper:** the kernel and DTB really do differ from what the unit shipped. Our boot image
  carries `Linux version 4.19.193 (root@wuwqbook) #24`, the OEM carries `Linux version 4.19.111+
  (root@meng_book2) #190, Jul 5 2024`; kernel payloads differ in size (30,455,816 vs 25,671,688) and sha
  (`ec3b6631…` vs `59075004…`). So **D3** is not satisfied by the flashed payload. Our DTB keeps the board
  identity (`compatible = "rockchip,rk3399-hct"`, active panel path `panel_in_dsi =
  "/dsi@ff960000/panel@0/ports/port@0/endpoint"`, timing0 0x2349340 Hz) but **drops the OEM's LVDS panel
  timings for `mtc,panel_index` 0x21, 0x23, 0x24, 0x25, 0x26**, adds DSI-only timings 0x4f/0x52/0x53/0x54/
  0x55/0x60/0x62/0x64/0x77, and retimes timing4 (0x3567e00 -> 0x3473bc0), timing17 (0x5f5e100 -> 0x8d9ee20,
  porches changed, `dsi_clk_div4` removed) and timing76 (0x43b5fc0 -> 0x3938700).
* **New, and not in the outside diagnosis - then corrected the same evening:** our vendor slice's GPU
  module is built for the wrong kernel (`mali_kbase.ko` = `vermagic=4.4.167`, 1,045,008 B, listed in
  `modules.load`, while the other 16 modules report `4.19.193`). But the OEM's Android 10 vendor ships the
  *same* `4.4.167` `mali_kbase.ko` against its `4.19.111+` kernel, and both kernel Images have Mali built
  in (25 `mali_kbase` strings each; `midgard` 43 vs 27 hits). The firmware that works today therefore also
  has an unloadable Mali module - Mali comes from the kernel, not the `.ko`. So this mismatch is cosmetic
  and is **not** the differentiator; it is recorded as a defect worth cleaning up, not as the cause.
  Ranking after the correction: **the trimmed DTB panel-index table is the prime suspect** (it is the one
  measured difference between the working firmware and ours), the kernel build difference second, the
  composer/HIDL question third (unmeasured). **Superseded minutes later by D33**: both the kernel and the
  DTB turned out to be the vendor *Android 11* pair sitting on an *Android 10* boot chain, so the
  generation mismatch is ahead of the panel table - the panel-table trimming is a vendor A10->A11
  difference, not our edit.
* **Ruled out:** AVB/vbmeta (orange state, empty vbmeta props, `Not AVB images, AVB skip`, our cmdline says
  `androidboot.veritymode=disabled` where the OEM's says `enforcing`, and `vbmeta` was never written -
  **D18**); uboot/trust mismatch (boot chain untouched, our boot image is header v2 with identical load
  addresses `0x10008000 / 0x11000000 / 0x10f00000 / 0x10000100` and header_size 2,048 as the OEM's, so
  u-boot parses ours like theirs); dynamic-partition layout and fs-type mismatch (super metadata v10.0,
  device size 3,263,168,512 = partition size exactly, group `hct_dynamic_partitions` max 3,258,974,208,
  slices total 2,285,321,536 B, names `system/vendor/product/system_ext/odm`, every slice opens in
  `debugfs` as ext4 and our `fstab.rk30board` declares ext4 for all five).
* **Not testable offline:** SELinux/first-stage hang - bring-up is permissive (**D5**) and our first-stage
  ramdisk decompresses (3,647,232 B cpio newc), so policy is not the blocker; the console decides.
* **Open, console-only:** which DTB u-boot feeds the kernel. This u-boot has both paths (`Found DTB in %s
  part` + `rk-kernel.dtb`, and the boot-image `second size`/`dtb size`/`dtb addr`), we never wrote `dtb`/
  `dtbo`, and the partition's DTB content is unknowable (empty dump), so the serial line naming the DTB
  source settles it.
* Oddity to check: our `odm` slice is 811,008 B containing only `/etc`; the OEM's odm was 539,951,104 B.

**Decision:** the next attempt fixes the measured differences rather than guessing at theories - (1) restore
the OEM panel-timing table in our DTB (the LVDS indices 0x21..0x26 and the original clocks), or prove from
the console which index the unit asks for; (2) decide the kernel question - our `4.19.193` build versus the
shipped `4.19.111+`, both of which carry Mali built in; (3) clean up the `mali_kbase.ko` vermagic mismatch
(defect, not cause). As the conservative alternative, ship the OEM `boot-a10.img` (kernel 4.19.111+ + its
DTB = a matched set) and change only `super`. Whether Android 14 userspace tolerates the vendor 4.19.111+
kernel is **not measured** and must be checked before choosing that option. Nothing is flashed before the
console reading (**D30**).

## D33 - the payload mixes firmware generations: A11 kernel+DTB on an A10 boot chain (Nov 10, DECIDED)

The owner reported XDA's explicit warning against upgrading Android 10 -> 11 this way. Measured
(`docs/findings.md`, "Payload provenance"), this is exactly what our payload does:

* Our `boot.img` kernel payload and its DTB are **byte-identical to the vendor Android 11 package**
  (`diatsia fw/update.zip`, 1.47 GB): kernel 30,455,816 B sha `ec3b6631…`, DTB 157,962 B sha `530b8412…`.
  They are **not** the Android 10 pair (kernel 25,671,688 sha `59075004…`, DTB 152,425 sha `cd4eeb3d…`).
  Only the ramdisk is ours (A14 first-stage init, 1,632,189 B vs vendor 838,018 B). So the kernel we
  flashed is the vendor's **A11** build (`4.19.193 #24`), while the firmware the unit ran was Android 10
  (`4.19.111+`).
* The vendor's own A11 updater-script writes `boot`, `trust`, `uboot`, `logo`, `dtbo` and `RKLoader.bin` -
  it never mixes generations. Those images differ between packages: `uboot` `2954bd15…` (A11) vs
  `a28fd6a0…` (A10); `trust` `f95bd8f3…` vs `7f2c4e52…`; `dtbo` 607 B `ec0ae97c…` vs 803 B `28a07d49…`;
  `logo` exists only in the A11 package.
* The two `dtbo` overlays are not equivalent (`dtc`): the A10 overlay has 3 fragments (`chosen`,
  `firmware_android` adding `vbmeta` **and** `fstab` children marked `status = "disabled"`, `reboot_mode`);
  the A11 overlay has only 2 (`chosen`, `reboot_mode`) and drops the disable-`vbmeta`/`fstab` fragment.
  Neither base DTB has those nodes on its own, so that behaviour is decided by which generation of `dtbo`
  sits in the partition - and we never write `dtbo` (**D18**).
* Because the unit last installed Android 10 firmware, its `uboot`/`trust`/`dtbo` are the A10 generation
  while its kernel and base DTB are now the A11 generation. **That mixed-generation boot is now the leading
  explanation for the black screen**, ahead of the DTB panel table (**D32**) and the composer question.

**Decision.** Two coherent paths, ranked by brick risk:
1. **Preferred, no boot-chain write**: flash `boot-a10.img` (vendor A10 kernel + vendor A10 DTB, matched to
   the unit's A10-era `uboot`/`trust`/`dtbo`) together with our A14 `super`. Before choosing it, answer the
   unmeasured question - does Android 14 userspace survive on `4.19.111+`? String evidence is favourable
   (`bpf` 165 hits, `psi` 72, `cgroup2` present, `ringbuf` 52, `f2fs` 107, no `erofs`, ION/dmabuf present)
   but not proof; the console decides.
2. **Coherent but risky**: install the vendor A11 chain (`uboot`, `trust`, `dtbo`, `logo`, loader) as the A11
   script does, then A14 super. This is what the vendor itself produces, but it writes the boot chain - the
   step that can brick an A10->A11 unit - and the rescue media is still unproven (SD IDB layout unknown).
   **Not allowed until the serial console and a verified rescue card exist.**
Nothing is flashed before the console reading (**D30**), and the rollback payload (**D31**) is unchanged.

## D34 - the payload has no first-stage fstab; that alone explains the black screen (Nov 10, DECIDED)

Measured (`docs/findings.md`, "First-stage fstab"): Android 14 first-stage init reads its fstab from the
devicetree (`/proc/device-tree/firmware/android/fstab`, compatible `android,fstab`) or from the ramdisk at
`/first_stage_ramdisk/fstab.<hardware>` (Android 12+ path; Android 10 used `/fstab.<hardware>`). Our payload
has **neither**: our DTB (the vendor A11 DTB) has no `fstab` node, the unit's untouched A10-era `dtbo` adds
`vbmeta`/`fstab` children marked `status = "disabled"` (so init skips the DT fstab), and our ramdisk contains
no fstab file and no `first_stage_ramdisk/` directory at all. With `androidboot.hardware=rk30board` in the
cmdline, init therefore fails with `failed to read default fstab for first stage mount`, `/system` is never
mounted, second-stage init never runs, and nothing - display, WiFi, adbd - ever starts. That is a defect in
**our** payload and is now the **primary** explanation for the observed no-logo/no-Wifi/no-adb state, ahead of
the generation mismatch (**D33**), which remains a real second-order risk.

**Decision.**
1. Fix = put `/first_stage_ramdisk/fstab.rk30board` into the boot ramdisk, containing our vendor fstab's 5
   logical ext4 entries (`system/vendor/product/system_ext/odm`, all `wait,logical,first_stage_mount`) plus
   `metadata`. Two images are built and verified with `unpack_bootimg`, and **neither is flashed** (**D30**):
   `a14-fixed.img` (32,796,672 B, `f378d4fd…`) = our current payload plus that file, still the vendor A11
   kernel/DTB; `boot-a10k-a14rd.img` (28,231,292 B, `455a9ac8…`) = the generation-coherent shape (OEM A10
   kernel `59075004…` + OEM A10 `second` 924,672 B carrying the A10 DTB `cd4eeb3d…`, `dtb_size 0`, our A14
   ramdisk `146ac4e3…` + fstab, our cmdline, OEM load addresses, header v2).
2. The naive Path 1 - flashing the OEM `boot-a10.img` unchanged with our A14 `super` - is **infeasible**: its
   ramdisk fstab lists only `system/vendor/odm/product`, no `system_ext`, which Android 14 needs. So Path 1
   is now `boot-a10k-a14rd.img`, not `boot-a10.img`.
3. Neither image writes a boot-chain partition (**D18**) and both pair with the A14 `super` already on the
   unit (`2045af9c…`), so the blind rollback path (**D29**, **D31**) is unchanged.
4. The console reading (**D30**) now has a specific thing to confirm: init's fstab messages
   (`First stage mount skipped (missing/incompatible/empty fstab in device tree)`,
   `failed to read default fstab for first stage mount`). If they appear, the fix is confirmed before any
   write; the preferred shape stays `boot-a10k-a14rd.img` + our A14 `super`.
5. Documentation correction: the kernel payload hashes recorded earlier tonight were computed from a wrong
   header offset (the layout is header 1660 B + contiguous sections). Correct values: ours/A11
   `ec3b6631…`, OEM A10 `59075004…`; DTB hashes unchanged. **D33**'s conclusions stand unchanged.

## D35 - bench reanimation procedure (Nov 10, DECIDED)

The owner takes the unit out of the car tomorrow, opens it, and runs it on a desk bench: a butchered
harness with **yellow + red twisted together to a fused +12 V** (both constant and ACC, so the logic and
memory rails both come up from one supply) and **black to the supply GND**; nothing else in the harness is
connected. A **3.3 V** serial-to-USB fob on `console=ttyFIQ0`, 115200 8N1, gives the console that was
missing on Nov 9; the fob goes on a USB port other than the one used for Rockchip USB writes so the log can
be watched while writing. Written up standalone in `docs/reanimation.md` so it works without an assistant.

Measured support for it, tonight:
* Partition sector map (whole-disk 512 B LBAs), from the working firmware's `by-name` symlinks +
  `/proc/partitions`: `uboot` 16384, `trust` 24576, `misc` 32768, `dtb` 40960, `dtbo` 49152,
  `vbmeta` 57344, **`boot` 59392**, `recovery` 124928, `backup` 321536, `security` 550912, `cache` 559104,
  `metadata` 1345536, `frp` 1378304, **`super` 1378328..7752703**, `userdata` 7752704..122683358. So the
  only two ranges anyone may write are `boot` (59392..124927, 32 MiB) and `super` (1378328..7752703).
  Sizes in sectors: `boot-a10k-a14rd.img` 55,237, `boot-a10.img` 53,528, `super-a10.img` 6,374,161.
* Laptop tooling: `upgrade_tool` (`/tmp/opencode/rktools/upgrade_tool`) runs and reports 0 Rockchip USB
  devices today; `rkdeveloptool`, `rkflashtool`, `picocom`, `minicom` are **absent**, `socat` is present -
  hence `scripts/serial_console.sh` uses `stty` + `cat` (+ timestamps) and `socat` for interactive mode.
  Both OEM packages carry `RKLoader.bin` (465,230 B), which is what `upgrade_tool DB` needs to reach
  loader mode.
* Now that the case is open, maskrom becomes the preferred write route (W1 in the guide): `LD` ->
  `RCI` -> `DB RKLoader.bin` -> `PL` (must match the sector map) -> `WL` for partition writes only.
  `UF`, `EF`, `GPT`, `WS` stay forbidden (**D18**, **D19**), and `boot`/`super` remain the only writable
  partitions.
* Reading order unchanged (**D34**): init's fstab messages first, then which DTB u-boot used, whether the
  `dtbo` overlay applied, kernel panel/timing messages, init stage 2 + SurfaceFlinger. The kernel version
  line in the log distinguishes the payload on the unit (`4.19.193 #24`) from the OEM Android 10 boot
  (`4.19.111+ #190`).
* Power caution recorded: the owner's brick is 12 V **2.5 A**; amplifier draw can exceed that, and a
  brownout mid-write is the worst failure mode on this bench. Fuse the + lead, keep the load low, abort if
  the supply falls below ~11 V. A 5 A supply is better if available.

**Amendment Nov 11 (owner measured, supersedes the power paragraph above).** The unit's nameplate is 10 A
and it is fused at 10 A at the rear, so the bench supply must be **12 V / 10 A or better** - a 1 A brick
does not power the unit on, and the 2.5 A brick is below the amp bank's inrush. Recommended: ATX PSU +12 V
rail, 120 W wall adapter, or a car battery; inline fuse 10 A (not 5 A, it would blow at inrush), leads
>= 1.5 mm^2, speaker leads left open for the first boots. Nothing else in D35 changes: still boot/super
only, still no write before a serial reading (**D30**).

## D36 - bench access revised: unpopulated debug header + an HDMI-looking connector (Nov 11, DECIDED)

The owner opened the unit and found the debug UART header **unpopulated**, plus a connector on the PX6
board that looks like **HDMI**. Measured consequences (`docs/findings.md`, "Connectors inside the case"):

1. **Serial is still reachable.** The holes are plated through-holes: press-fit male Dupont pins or
   spring-loaded probe pins, or one wire soldered to the pad ring. Identify with a meter (GND = continuity
   to harness black, TX = idle ~3.3 V pulsing at power-on). There are two UARTs on this board - the console
   (uart2, `ttyFIQ0`) and the MCU uart - so readable boot text vs binary chatter tells you which row you
   found. Plan B (the FAT-stick report from `hu_probe.sh`) only works if init reaches second stage, so it
   can confirm a boot but must not be used to decide a write.
2. **The connector is probably HDMI, and the DTB supports both directions.** `hdmi@ff940000`
   (`rockchip,rk3399-dw-hdmi`) is `status = "okay"` with its input endpoint from **VOP Lite** enabled and
   VOP Big disabled, so an HDMI **output** path exists in the DTB. `tc358749x@0f` on `i2c@ff140000`
   (`toshiba,tc358749`, an HDMI receiver) is `status = "disabled"` with `mtc,for_board = "2x"`,
   `mtc,not_for_board = "21"`, so an HDMI **input** path exists in hardware but is off in this DTB as
   built. The MTC board-variant markers decide what the OEM enables at runtime, so the DTB alone cannot
   name the socket: settle it by experiment (monitor test = output; source test = input; metering pins with
   nothing plugged: steady 5 V or TMDS pairs idling ~2.9-3.3 V = output).
3. **A monitor is a legitimate bring-up display.** Both kernels carry `dw-hdmi`, `tc358749`,
   `rk3399-vop-big` and `rk3399-vop-lit`, so plugging a monitor needs no firmware change and writes
   nothing. If a monitor shows the animation while the DSI panel stays dark, init and SurfaceFlinger are
   alive and the defect is the panel/timing path - that changes the plan completely, so record it either
   way on the first power-on.
4. **Write routes unchanged.** Maskrom via `upgrade_tool` stays the preferred route (**D35**); if the
   HDMI-looking socket is not USB, then the USB-stick socket is the one to test for OTG/maskrom. Still no
   write before a serial reading (**D30**), and still only `boot` + `super` are writable (**D18**, **D19**).
   The monitor test is read-only, so it may run before the console reading; the *decision* may not.

## D37 - rescue SD card = sector-for-sector mirror of the eMMC layout + card-local GPT (Nov 11, DECIDED)

The owner's known-good factory PX6 SD firmware (`bootableSD/bootable_sd_card_10_android_PX6.rar`,
`update_10_android_zavod_PX6.img`, sha `7772a1da...`) settles the layout: it is an RKFW container that the
Windows `SD_Firmware_Tool.exe` lays out on a card, with `IDBLOCK_POS` default **64**, and its partition
table carries exactly the offsets the unit's eMMC uses (uboot 16384, trust 24576, misc 32768, dtbo 49152,
vbmeta 57344, boot 59392, recovery 124928, super ~1378328). Its `trust.img` and `dtbo.img` are
byte-identical to our staged OEM A10 copies, and its `uboot.img` differs only by signature bytes and build
strings. Vendor u-boot lists `boot_targets=mmc1 mmc0 ...` (SD slot tried first) and finds partitions via
`alloc_read_gpt_entries`, so **the card needs a GPT with Rockchip partition names**, not raw dd alone.

Consequences:

1. The card is built by `scripts/write_rescue_sd.sh` on the laptop: wipe, `sgdisk` GPT with the unit's
   partition names/offsets (userdata trimmed to the card's remaining space), then
   `dd bs=512 seek=64 idbloader.bin` (FlashData+FlashBoot, 239,616 B / 468 sectors), uboot@16384,
   trust@24576, dtb@40960 (the RSCE-wrapped DTB carved from the OEM A10 boot's second stage, sha
   `cd4eeb3d...`), dtbo@49152, vbmeta@57344 (4 KB zero - u-boot reports "Not AVB images, AVB skip" on this
   unit and AVB is orange/not enforced), boot@59392 (`boot-a10.img`, sha `04a43ea9...`),
   super@1378328 (`super-a10.img`, sha `30da961c...`). Then `sync` and per-piece read-back sha verification.
2. Identity gate before any write: `RM=1`, vendor "Generic- SD/MMC", 7-8 GB, usb, nothing mounted, and the
   device must not carry a system mountpoint. The workstation's `/dev/sda` is a 7.3 T RAID array and is
   rejected by that gate; the laptop's `/dev/sda` passes (7.4 GB, RM=1, "Generic- SD/MMC", usb) and the
   laptop's own disk is `nvme0n1`.
3. Payload choice: the verified OEM Android 10 pair (`boot-a10.img` + `super-a10.img`) rather than the
   factory container's own boot/super, because ours is already proven coherent (lpdump/debugfs) and matches
   the OTA firmware the unit shipped with. Booting the card gives a working Android 10 from SD, which is the
   unbrick route: `adbon` -> TCP adb -> `adb root` -> then write only `boot`/`super` on eMMC (**D18**, **D19**).
4. Nothing in this decision writes to the unit. It is card-only media, so it is not gated by **D30** (the
   serial-console gate applies to writes on the unit).

**Amendment Nov 11 (measured, corrects point 1 above).** The Malysk factory card, burned with
`SD_Firmware_Tool.exe` on Windows, boots the unit in the GPS SD slot after a **deep power cycle**, while our
GPT card does not boot and Windows sees our GPT (as ~10 unformatted partitions) but sees nothing on the
tool-written card. Vendor u-boot carries both `part_get_info_efi` and `part_get_info_rkparm`, and the tool
writes no Windows-visible partition table - so the Rockchip **parameter** block, not a GPT, is what the boot
path uses. `scripts/write_rescue_sd.sh` stays useful for payload staging, but the layout must be copied from
the tool-written card (dump its first sectors and the RKAF parameter) before any further card build. Nothing
else in D37 changes: card-only media, no eMMC write, payload files unchanged.

**Amendment Nov 11 (owner route, full-OEM unbrick).** The owner chose the known-good route: burn the Malysk
factory PX6 firmware with `SD_Firmware_Tool.exe` on Windows and let the card unbrick the unit. That restores
the **entire** eMMC - including `uboot`, `trust`, `dtb`, `dtbo`, `vbmeta`, `security` and the GPT, which
**D18** had never allowed us to write. This is an OEM restore of the unit's own stock chain (not our payload),
so it is a legitimate recovery; the D18/D19 prohibition still applies to anything *we* build afterwards. Once
the unit is stock Android 10 again, the Android 14 payload is re-applied as **`boot` + `super` only**, using
the verified images (`boot-a10k-a14rd.img` `455a9ac8...` or `a14-fixed.img` `f378d4fd...`, plus our A14
`super`) - never a chain write. The tool-written card will be handed to the laptop after the unbrick so its
first sectors and RKAF parameter can be dumped and mirrored (see the D37 amendment above).

**Amendment Nov 11 (measured on the tool card).** The tool-written card is a *flasher* card: the GPT is real
(and Windows hides it because the MBR carries a genuine NTFS record), the firmware container is stored as a
file in the NTFS region, `super` on the card is erased, and the card's chain images are SD-boot variants that
differ from the container's own chain images. Its primary GPT puts `super` at 1379328 (matching the factory
parameter block) while its backup GPT says 1378328 (matching the eMMC map) - u-boot reads the primary table,
so any card we build must use the primary table's offsets and keep the backup consistent. Payload scope is
unchanged: card media only, no eMMC write from our own builds (D18/D19).

**D38 - the unit's own board DTB lives in the `boot` partition's second stage.** Measured Nov 11: the
flashed factory firmware's DTB is `rockchip,rk3399-hct` but a different HCT variant (130,833 B, sha `9ffc8492`)
that lacks `display-timings-dsi` and `mtc-radio_v0/1/2` and adds the six physical key nodes. The unit's OEM
DTB is 152,425 B, sha `cd4eeb3d`. Because the DTB is embedded in `boot`, flashing the OEM `boot.img`
(`04a43ea9...`, 27,406,336 B) restores the unit's own display/board description without touching the
protected chain (uboot/trust/dtb/dtbo/vbmeta/security/GPT stay untouched). This write needs real access
(serial console per D30, or maskrom per W1) and the factory card kept as the safety net, so it waits until
probe pins or an OTG port exist.
