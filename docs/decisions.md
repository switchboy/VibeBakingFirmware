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
  were removed on Nov 6 (**D19**): a GPT rewrite is the class of write **D18** forbids, and growing
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
| nothing builds it | injected into the staging dir (`vendor_dest_keep.txt`) | normally none |

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
