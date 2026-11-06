# Build host

The local machine cannot build Android: its root filesystem has ~30 GB free, its storage volume is
NTFS (`nocase`, fake symlinks - an AOSP tree needs real symlinks and case-sensitive paths), and
~4 GB of RAM is free while other workloads hold the rest. So the build runs on the NAS.

## Target

| item | value |
|---|---|
| host | OMV NAS, Debian 13 (trixie), x86_64, 16 CPUs, 24 GB RAM + 24 GB swap |
| build root | `/srv/dev-disk-by-label-SSData/aospbuild/` |
| LineageOS tree | `/srv/dev-disk-by-label-SSData/aospbuild/lineage21s` (shallow; `lineage21` is the incomplete first checkout, to be deleted) |
| repo checkout | `/srv/dev-disk-by-label-SSData/aospbuild/VibeBakingFirmware` |

`SSData` is the SSD partition (`CT500MX500SSD1`, 266 GB free at setup). The 7.3 TB pool members were
not chosen: they are spinning HDDs (`ST8000VN004`) inside a mergerfs pool, which is slow for
`repo sync` / ninja, and `/srv/dev-disk-by-label-parity` must never be written to. Budget: tree
~60-70 GB, `out/` ~35-45 GB, so ~110 GB of the 266 GB free.

## Packages installed (track these, remove when done)

Recorded in `/srv/dev-disk-by-label-SSData/aospbuild/installed_packages.txt`:

    git-lfs repo unzip device-tree-compiler brotli gdisk zip

`gdisk` is only needed by `scripts/repartition_gpt.sh` (`sgdisk` computes the GPT CRCs).
Already present before setup: git, python3, curl, make, gcc, g++, patch, cpio, bzip2, pkg-config.
`repo` comes from Debian's package (launcher 2.54; repo offers 2.71 and says to upgrade - harmless).

Removal after the build:

    apt-get purge -y git-lfs repo unzip device-tree-compiler brotli gdisk zip
    apt-get autoremove -y

Nothing else was changed on the NAS: no OMV config, no service restarts, no shares created.

## Access

Password authentication through a wrapper that lives **outside** the repo (so the credential is never
committed): `/tmp/opencode/omv.sh`, which reads the credential from `/tmp/opencode/build_host.env`
(mode 600) via `SSH_ASKPASS` and never puts it in argv.

## Build notes

- `repo init -u https://github.com/LineageOS/android.git -b lineage-21.0 --git-lfs` (the manifest repo
  is LineageOS's `android.git`; the old `android_repo_manifest` name is gone - GitHub returns 404).
- Sync runs with `-c -j4`: single branch, four jobs, so the NAS keeps its docker services responsive.
  Progress: `/srv/dev-disk-by-label-SSData/aospbuild/lineage21/sync.log`.
- Memory: 24 GB with docker already using ~12 GB. Build with a bounded job count (`m -j4`, drop
  to `-j2` if RSS climbs into swap) and watch RSS; Android 14 compilation peaks well above the free
  RAM otherwise.
- Expect to need `abootimg`/`mkbootimg` and `f2fs-tools` later for assembling boot images and the
  repackaged super/userdata. Add them only when actually used, and add them to the tracked list.


## Space plan on the SSD

`/srv/dev-disk-by-label-SSData` holds docker (87 GB) plus the checkout. Android 14 wants 50-70 GB
for `out/`, and the shallow checkout itself needs ~50 GB. So free the incomplete `lineage21/` tree
(~187 GB, ours and reproducible) **before** starting a sync, not after: the shallow sync filled the
volume to 0 free while the old tree was still there. Deleting a repo checkout of that size takes
several minutes (it is hundreds of thousands of files), so run it detached:

    systemd-run --unit=los-cleanup rm -rf /srv/dev-disk-by-label-SSData/aospbuild/lineage21

If space is still tight after the sync, drop `.repo/git` and `.repo/projects` (the git objects) while
keeping `.repo/manifest.xml` and `.repo/manifests/`, because `m dist` reads the manifest. Re-check
`df -h` before starting `make`.

## Shallow sync

GitHub refused the fetches on the big repos (`LineageOS/android`, `android_art`, `android_bionic`,
`android_build`, `android_build_soong`, ~88 projects) with "git requires authentication, but repo
cannot perform interactive authentication". That is GitHub's secondary rate limiting, not a real
credential problem: an anonymous `curl` of `info/refs` returns 200. Lower job count did not fix it
(`-j4`, `-j2` and `-j1 --fail-fast` all left failures), so the workaround is a shallow checkout:

    repo init --depth=1 -u https://github.com/LineageOS/android.git -b lineage-21.0 --git-lfs
    repo sync -c -j4          # retried up to 4 times, 120 s apart

Shallow fetches are far smaller, so they stay under the limit. The build needs no git history.
Even shallow, GitHub kept refusing the biggest repos (`android`, `art`, `bionic`, `build/make`,
`build/soong`, `bootable/recovery`, the sepolicy trees), so the follow-up is a patient pass:
`repo sync -c -j1` with a 3-minute pause between passes (`los-sync7`).
Tree: `lineage21s/`, log: `lineage21s/sync.log` and `sync5.log` (mirrored to the workstation's
`/run/media/Daan/Opslagmonster/build-watch/`).

## Release name, lunch, and how the build is invoked

Android 14 requires `<product>-<release>-<variant>`. The release names are the `.scl` files in
`build/release/build_config/` (there is no `build/release/configs` directory in LineageOS's mirror),
declared by `build/release/release_config_map.mk` and by `vendor/lineage/release/release_config_map.mk`.
LineageOS 21 declares exactly one release: **`ap2a`**, so the combo is

    lunch lineage_rk3399-ap2a-userdebug

There is **no root `Makefile`** in this tree - the manifest only creates root symlinks
(`Android.bp -> build/soong/root.bp`, `bootstrap.bash -> build/soong/bootstrap.bash`), so bare `make`
fails with "No targets specified and no makefile found". After `source build/envsetup.sh` the build
runs through `m`, which calls `soong_ui --make-mode`: `m -j4`, `m dist`, `m otapackage`,
`m superimage`. The build script does exactly that and logs `TARGET_PRODUCT`/`TARGET_RELEASE`.

`vendor/lineage/build/envsetup.sh` is sourced by `build/envsetup.sh`, so a missing `vendor/lineage`
also aborts lunch - it is part of the sync check.

## Device-tree fixes found by the first lunch attempts

`lunch lineage_rk3399-ap2a-userdebug` now succeeds (`BUILD_ID := AP2A.240905.003`, arm64 + arm). Four
things were wrong in the tree we wrote, and Android 14 rejects each one loudly:

| problem | fix |
|---|---|
| `AndroidProducts.mk` set `PRODUCT_LIST` | Android 14 reads **`PRODUCT_MAKEFILES`**; also declare `COMMON_LUNCH_CHOICES` with the `<product>-<release>-<variant>` form |
| `$(LOCAL_DIR)/device.mk` inside the product file | kati's `LOCAL_DIR` there is the last `AndroidProducts.mk` directory, so write the path out: `device/rockchip/rk3399/device.mk` |
| `base.mk` + `base_product.mk` chain | use `full_base.mk` (base + product + `generic_no_telephony`, right for a modem-less head unit) plus `core_64_bit.mk` inherited first, otherwise `TARGET_SUPPORTS_64_BIT_APPS` is unset and board_config aborts |
| prebuilt vendor image | `TARGET_COPY_OUT_VENDOR := vendor` (plus `system_ext`/`product`/`odm`) is required by `board_config.mk:682` |

The product config inherits `vendor/lineage/config/common_full_tablet_wifionly.mk` - the tablet
variant without a telephony stack, which matches this unit (Bluetooth phone comes from the vendor
HALs, no SIM).

## The first `m` produced no boot.img or recovery.img

The successful build (`out/target/product/rk3399/`) contained `super.img`, `system.img`,
`product.img`, `system_ext.img`, `odm.img`, `vendor.img`, `ramdisk.img` and `super_empty.img` - but
no boot or recovery image, and `misc_info.txt` said `no_boot=true`. Two causes, both in our tree:

1. **No partition sizes.** `build/make/core/Makefile:1282` only builds a boot image when
   `BOARD_BOOTIMAGE_PARTITION_SIZE` is set, and the recovery image likewise needs
   `BOARD_RECOVERYIMAGE_PARTITION_SIZE`. Set them from the live unit's `/proc/partitions`: boot is
   `mmcblk2p7` = 32768 KiB (33,554,432 B), recovery is `mmcblk2p8` = 98304 KiB (100,663,296 B).
   Also set `BOARD_FLASH_BLOCK_SIZE := 512` (it was absent from `misc_info.txt`) and
   `BOARD_USES_METADATA_PARTITION := true` - the HU has a 16 MiB `metadata` partition
   (`mmcblk2p12`, mounted at `/metadata` on the stock firmware) that update_engine and vold use.
2. **Load addresses were inert.** `BOARD_KERNEL_OFFSET`/`BOARD_RAMDISK_OFFSET`/`BOARD_SECOND_OFFSET`
   /`BOARD_TAGS_OFFSET` are *not* read by the Makefile - it only passes `--base`, `--pagesize` and
   `--cmdline`. Every offset has to come from `BOARD_MKBOOTIMG_ARGS`, otherwise mkbootimg writes
   defaults and u-boot loads the kernel to the wrong address.

The values now used are read straight out of the vendor's working boot image
(`out/host/linux-x86/bin/unpack_bootimg --boot_img analysis/daisaita_a11/boot/boot.img --format
mkbootimg`): header v2, page size 2048, base 0, kernel `0x10008000`, ramdisk `0x11000000`, second
`0x10f00000`, tags `0x10000100`, dtb `0x11f00000`. Note the Makefile never passes `--header_version`
either - `BOARD_BOOT_HEADER_VERSION` by itself produced a **header v0** boot image (checked with
`unpack_bootimg` on our `boot.img`), and header v0 cannot carry a DTB. So `--header_version 2` goes
into `BOARD_MKBOOTIMG_ARGS` as well. That vendor image also embeds a DTB (157,962 B)
and a Rockchip `RSCE` logo blob (544,768 B) as the second stage - both are kept:
`BOARD_PREBUILT_DTBIMAGE_DIR` + `--second` in `BOARD_MKBOOTIMG_ARGS`, files in
`device/rk3399-px6-hct4/prebuilt/`. Our boot.img is ~32.8 MB (kernel 30.4 MB + Android 14 ramdisk
1.6 MB + logo + dtb), which fits the 32 MiB partition.

Note: the Daisaita Android 11 zip writes `logo.img` into `/dev/block/by-name/logo`, a partition this
unit does not have (its p11 is `cache`) - one more reason that package cannot be flashed here,
besides its 4,890,558,464 B super group. Our logo lives inside boot.img instead.

### Duplicate sysprops in vendor/build.prop

`m recoveryimage` failed at 94% on `out/target/product/rk3399/vendor/build.prop`:
`error: found duplicate sysprop assignments: ro.hwui.use_vulkan= / ro.hwui.use_vulkan=false`.
`build/make/core/main.mk:337` already puts `ro.hwui.use_vulkan=$(TARGET_USES_VULKAN)` and
`ro.sf.lcd_density=$(TARGET_SCREEN_DENSITY)` into `ADDITIONAL_VENDOR_PROPERTIES`, so assigning those
two in `device.mk` collides with them. Fixed by setting `TARGET_USES_VULKAN := false` and
`TARGET_SCREEN_DENSITY := 240` in `BoardConfig.mk` and dropping them from `device.mk`. The same class
of trap applies to any property main.mk derives from a `TARGET_*` variable.

### `ifdef` vs `ifeq` in BoardConfig.mk

`m recoveryimage` then failed with `mkbootimg: error: argument --recovery_dtbo: expected one argument`.
`build/make/core/Makefile` guards that flag with `ifdef BOARD_INCLUDE_RECOVERY_DTBO`, which tests
*definedness*, so writing `BOARD_INCLUDE_RECOVERY_DTBO := false` still emits the flag with an empty
argument. The fix is to not declare the variable at all - it is now commented out in `BoardConfig.mk`.

### `m dist` aborted inside the non-A/B OTA step: zip followed the staging symlinks

`m dist` also builds the OTA package, and it failed with
`common.ExternalError: Failed to run command '['zip', ..., '-r', '.', '-0']' (exit code 18)` plus
`zip warning: Not all files were readable`. Android 14's `build-ota-package-target` hands
`ota_from_target_files` the **target_files directory** (not the zip), and
`build/make/tools/releasetools/non_ab_ota.py` re-zips it with Info-ZIP, which follows symlinks by
default. The staging tree is full of absolute/dangling symlinks (`SYSTEM/bin/linker ->
/apex/com.android.runtime/bin/linker`, `RECOVERY/RAMDISK/d -> /sys/kernel/debug`, ...), so zip read
the *build host's* filesystem - it even walked `/sys/kernel/debug/regulator/` and warned
"file size changed while zipping" - then exited 18 on files it could not read.

Fix: `patches/releasetools-zip-store-symlinks.patch` adds `-y` (store symlinks as symlinks) to that
one call. `scripts/apply_tree_patches.sh` applies it with `git apply` (GNU patch 2.8 rejects the hunks
even though the context matches byte-for-byte); `package.sh` runs it before every packaging pass, and
the check is idempotent.

### The next OTA failure was a missing `cache_size`

With the zip fixed, packaging got further and hit `AssertionError` at
`blockimgdiff.py:1547` (`assert cache_size is not None`). `misc_info.txt` had no `cache_size`, because
that line is only emitted inside the *cache partition's* image-prop block
(`build/make/core/Makefile:2190`) - declaring `BOARD_CACHEIMAGE_PARTITION_SIZE` alone is not enough.
So `BoardConfig.mk` now declares both the size (the real 384 MiB partition, 402,653,184 B) and
`BOARD_CACHEIMAGE_FILE_SYSTEM_TYPE := ext4`, which builds a ~2 MB sparse `cache.img` and adds
`if-wipe erase cache` to the wipe script. blockimgdiff uses cache_size to cap transfer size and
stashed blocks, so a non-A/B OTA genuinely needs the partition.

`BOARD_FLASH_BLOCK_SIZE` is 4096, not 512: our images are ext4 with 4096-byte blocks, and 512 only
makes blockimgdiff's transfer lists 8x bigger.

Note the packaging log's `WARNING: Failed to read VENDOR/etc/build.prop` lines: the vendor image is
prebuilt, so there is no `VENDOR/` staging directory for `add_img_to_target_files` to read props from.
They are warnings, but they mean `target_info` has no vendor build props (no
`ro.product.first_api_level`), which is worth watching if the VINTF/fingerprint checks complain.

### The OTA step kept failing for four separate reasons

`m dist` reached the OTA step in `los-pack9` and then failed four times, each time further than the
last. All four are now fixed except the vendor one (see below).

1. **`KeyError: '/recovery'`** in `common.CheckSize` (`common.py:2594`, called from
   `non_ab_ota.py:189`): CheckSize looks up `info_dict["fstab"][mount_point]` for the raw partitions.
   Our fstab had no `/boot`, `/recovery` or `/misc` rows, so recovery/boot images were never size
   checked. Adding the three `emmc` rows fixed it; the log now says
   `recovery size (43339776) is 43.05% of limit (100663296)`.
2. **`ValueError: Invalid input_file ... Actual: ...target_files.zip`** in
   `common.ReadBytesFromInputFile` (`common.py:766`): after we switched the recipe to pass the zip,
   `zipfile.is_zipfile()` returned False because `$(INTERNAL_OTA_PACKAGE_TARGET)` only depended on
   `$(BUILT_TARGET_FILES_DIR)` (the file list), not on the zip itself - so ninja ran "Package OTA"
   while SOONG_ZIP was still writing the zip. `patches/releasetools-ota-depend-on-target-files-zip.patch`
   makes the zip a real dependency.
3. **`AssertionError: vendor is in target super_hct_dynamic_partitions_partition_list but no
   BlockDifference object is provided`** (`common.py:3961`). Root cause: `HasPartition()`
   (`check_target_files_vintf.py:315`) checks for a `VENDOR/` *directory* entry in the target_files
   archive, and a prebuilt vendor image never produces one (`BUILDING_VENDOR_IMAGE` is unset at
   `board_config.mk:698`, so `Makefile:6581` never copies `$(TARGET_OUT_VENDOR)` into the staging
   tree). `GetBlockDifferences` therefore skips vendor, and the dynamic-partition installer asserts.
   This is also what the `Failed to read VENDOR/build.prop` warnings mean, and it would make the
   VINTF compatibility check meaningless. Two ways out, and the owner picked the first (D13/D15):
   - **Stage vendor from source** (chosen, implemented by `scripts/prebuilt_vendor.sh` +
     `tools/gen_vendor_staging.py`): drop `BOARD_PREBUILT_VENDORIMAGE`, keep
     `BOARD_VENDORIMAGE_FILE_SYSTEM_TYPE := ext4`, and mirror the stock Android 11 partition into
     `vendor/hct4/tree/vendor` with a read-only loop mount + `rsync -a` so `PRODUCT_COPY_FILES` can
     stage it. `vendor.img` is then built from those blobs, which gives a `VENDOR/` staging dir,
     `vendor.map`, the vendor VINTF manifest and a vendor `build.prop`. What the staging had to
     handle:
     - `acp`/`cp` **dereference** symlinks, so the 178 `/vendor/bin` aliases would each become a
       489 KB copy of `toybox_vendor`; they are dropped (those tools resolve through `/system/bin`
       on Android 14), and `/vendor/bin/sh` is a real file in the stock vendor, so our init service
       and Rockchip's shell scripts still work.
     - `libGLES_mali.so` and `libOpenCL.so` are materialised as real copies of
       `egl/libGLES_mali.so`, because Android 14's EGL loader searches
       `libGLES_<ro.hardware.egl>.so` in `/vendor/lib(64)/` and `/vendor/lib(64)/egl/`
       (`frameworks/native/opengl/libs/EGL/Loader.cpp:284-315`). Materialising runs *before* the
       other links are deleted: `libOpenCL.so -> .1 -> .1.1 -> ./egl/libGLES_mali.so` is a chain
       that only resolves while all three links exist (~111 MB added, the super group has ~1.2 GB
       spare).
     - `vendor/etc/vintf/` cannot go through `PRODUCT_COPY_FILES` (`Makefile:131`), so both VINTF
       files are re-written into `device/rk3399-px6-hct4/vintf/` and declared through the vintf
       variables: `DEVICE_MANIFEST_FILE += vintf/vendor_manifest.xml`, `DEVICE_MATRIX_FILE +=
       vintf/device_matrix.xml`, `DEVICE_FRAMEWORK_COMPATIBILITY_MATRIX_FILE +=
       vintf/device_framework_matrix.xml`.
       - The device matrix loses its `<vendor-ndk><version>30</version>` block: Android 14 has no
         VNDK and `checkvintf` reports "Vndk version 30 is not supported".
       - The vendor manifest loses its `<sepolicy><version>30.0</version></sepolicy>`.
         `assemble_vintf` fills a value in *only when the file has none*
         (`system/libvintf/AssembleVintf.cpp:148-174`); an existing value that differs from the
         build's is fatal, so Android 14's `BOARD_SEPOLICY_VERS=202404` aborted `dist` with
         `Cannot override existing value 30.0 with BOARD_SEPOLICY_VERS (which is 202404)`. Dropping
         the block makes the build write 202404 - which is the truth here, because the vendor
         sepolicy in this ROM is Android 14's, compiled by the build.
       - `target-level="5"` is *kept*. Android 14 still ships
         `system/etc/vintf/compatibility_matrix.5.xml`, so an Android 11-era device manifest stays
         compatible; raising the level would drop the HIDL HALs the head unit needs (audio@6.0,
         bluetooth@1.0, camera.provider@2.4, gnss@1.0, composer@2.1, sensors@1.0, weaver@1.0).
       - Our own framework matrix adds the three HALs the Android 14 framework matrices do not
         know: `android.hardware.mtc.mfi`, `rockchip.hardware.outputmanager`,
         `rockchip.hardware.rockit.hw`. It lands in `system/etc/vintf/compatibility_matrix.device.xml`.
     - VINTF compatibility is checked *by the build*: dist runs `checkvintf --check-one` per
       partition and `--check-compat` over the target_files set (`build/make/core/Makefile:5162`,
       `:5391`) into `obj/PACKAGING/check_vintf_intermediates/*.log`, and fails the build when
       incompatible. It cannot be reproduced offline the same way: `--check-compat` also needs
       `/apex/apex-info-list.xml`, which only exists on a running device (the build passes the
       apex info file it generated). `scripts/verify_artifacts.sh` therefore reads those logs.
     - Make cannot express some vendor file names, and all of them are `usb_modeswitch.d` rules.
       `#` starts a comment, so an entry is truncated and `lunch` dies with
       `malformed COPY_FILE "vendor/hct4/tree/vendor/etc/usb_modeswitch.d/12d1_"` (3 files). `=`
       turns the generated `$(dst): $(src)` line into an *assignment*, so `ckati` reports
       `commands commence before first target` at `build/make/core/Makefile:161` (20 files, the
       `uMa=`/`sMo=`/`sVe=` variant rules). Wildcards (`% * ? [ ]`) would create pattern rules and
       whitespace splits the word, so the generator skips anything containing those too
       (`tools/namecheck.py <tree>` shows what is present). `/vendor/bin/usb_dongle` only looks up
       `/vendor/etc/usb_modeswitch.d/%04x_%04x`, so none of the 23 skipped rules are used; the plain
       `<vendor>_<product>` rules are still staged.
     - `.apk` destinations are rejected outright: `check-product-copy-files` aborts with
       `Prebuilt apk found in PRODUCT_COPY_FILES: ...use BUILD_PREBUILT instead!`
       (`build/make/core/Makefile:118`). The partition has exactly one -
       `overlay/framework-res__auto_generated_rro_vendor.apk`, the auto-generated vendor
       resource-overlay package. It is not decoration: it overrides
       `config_autoBrightnessLevels`/`config_autoBrightnessLcdBacklightValues` +
       `config_automatic_brightness_available` (the HU's auto-brightness curve),
       `config_tether_usb_regexs`/`config_tether_bluetooth_regexs`/`config_tether_wifi_regexs`
       (`usb\d`,`rndis\d` / `bt-pan` / `wlan0`,`softap.*` - the tether/hotspot interface names this
       unit uses), `config_networkSupportedKeepaliveCount`, `config_ephemeralResolverPackage` and the
       `config_enable*` bools. So it is kept, installed as a `BUILD_PREBUILT` module:
       `tools/gen_vendor_staging.py` writes `prebuilt_apps/Android.mk` (module class
       `STATIC_LIBRARIES`, suffix `.apk`, `LOCAL_MODULE_PATH := $(TARGET_COPY_OUT_VENDOR)/overlay`),
       and `scripts/prebuilt_vendor.sh` mirrors the blob into that folder so `LOCAL_SRC_FILES`
       resolve. The module keeps the stock name because
       `build/make/core/artifact_path_requirements.mk:9` allows `%__auto_generated_rro_vendor.apk`
       for static-lib artifacts, which is the pattern AOSP uses for its own generated RROs; a
       renamed module would trip the artifact-path check. The generated file also adds it to
       `PRODUCT_PACKAGES`.
     - ELF blobs through `PRODUCT_COPY_FILES` need `BUILD_BROKEN_ELF_PREBUILT_PRODUCT_COPY_FILES :=
       true` (`definitions.mk:3184` checks with `llvm-readobj`).
     - **Destinations that collide with modules the build installs itself** are a hard parse
       error, not a dedup: `PRODUCT_COPY_FILES` turns every pair into an install rule for
       `$(PRODUCT_OUT)/<dest>`, so ckati stops with
       `build/make/core/Makefile:161: error: overriding commands for target
       'out/target/product/rk3399/vendor/bin/applypatch', previously defined at
       out/soong/installs-lineage_rk3399.mk:83800`. Makefile:159 only dedups copy pairs *against
       copy pairs*, never against module rules. `tools/vendor_conflicts.py` compares the copy list
       with `out/soong/installs-<product>.mk` (and the previous build's staging dir, which is where
       legacy Make modules install) and names the module behind each collision; `--write-drop-list`
       records the ones to drop, and `gen_vendor_staging.py --dest-skip` regenerates without them.
       The decision is by source: a module built from upstream AOSP code (`external/toybox`,
       `external/mksh`, `external/libchrome`, `external/libdrm`, `frameworks/av/media/libeffects`,
       `hardware/interfaces/*/default`, `hardware/libhardware/modules/*`, `build/make/tools/fs_config`
       for `/vendor/etc/passwd|group`, `bootable/recovery/applypatch`, `prebuilts/misc` protobuf, the
       generated `/vendor/etc/selinux/*`) is the same component compiled for Android 14, so its file
       wins and the blob is dropped. Nothing Rockchip is dropped: every HU HAL has its own name and
       therefore no collision (`hwcomposer.rk30board.so`, `audio.primary.rk30board.so`,
       `camera.rk30board.so`, `gps.default.so`, `gralloc.default.so`,
       `android.hardware.graphics.allocator@4.0-impl-midgard.so`,
       `android.hardware.graphics.mapper@4.0-impl-midgard.so`, `mfi.default.so`,
       `android.hardware.mtc.mfi@1.0-impl.so`, `hw_output.default.so`,
       `rockchip.hardware.outputmanager@1.0-impl.so`, `memtrack.rk3399.so`, `sensors.rk30board.so`,
       `android.hardware.weaver@1.0-impl.so`). If a collision ever comes from `vendor/` or a device
       tree instead, the opposite fix is needed - keep the blob and remove that module from
       `PRODUCT_PACKAGES` - and the tool says so. `scripts/deploy_device.sh` re-runs the check so a
       changed product config cannot sneak a collision back into a 20-minute build.
     - Legacy **Make** modules install paths too, and nothing enumerates them statically (only Soong
       writes `installs-<product>.mk`), so `vendor_conflicts.py` cannot see them. ckati reveals one
       per parse, and pack16/18 found eleven of them: `bin/hw/rild` + `etc/init/rild.rc` +
       `lib(64)/libril.so` + `lib(64)/libreference-ril.so` (`base_rules.mk:497`/`594`), the legacy
       gralloc stub `lib(64)/hw/gralloc.default.so`, the two **empty** fs_config files
       `etc/fs_config_dirs` and `etc/fs_config_files`, and `etc/NOTICE.xml.gz`
       (`os_licensing.mk:44`). All are Android 14's own build of the same component, and no Rockchip
       HAL is among them - the unit's graphics HAL is the staged midgard allocator/mapper, and its
       radio HAL implementation stays a blob.
       `scripts/package.sh` reveal-and-retries: it reads the ckati error, appends the destination to
       `vendor_build_wins.txt` and to the committed `vendor_dest_skip_extra.txt` (so a fresh build
       host converges in one pass), regenerates the copy list, redeploys and retries - up to 12
       times. With Soong's cache warm a parse costs ~1.5 min, so this converges quickly and every
       step (`bootimage`, `recoveryimage`, `dist`, `superimage`, `otapackage`) goes through the same
       loop. It only reads the slice of `package.log` written by the *current* attempt: pack18
       grepped the whole log, so an unrelated failure (a missing file) was read as the previous
       collision and burned 12 regenerations before giving up.
     - `$(LOCAL_DIR)` / `$(LOCAL_PATH)` are **not** usable in a product-config `.mk`: device.mk is
       included from `AndroidProducts.mk`, so kati leaves them at `build/make/target/product/`. The
       fstab copy written that way made ninja say `'build/make/target/product/fstab.rk30board',
       needed by 'out/target/product/rk3399/vendor/etc/fstab.rk30board', missing and no known rule
       to make it`. Device paths are spelled literally (`device/rockchip/rk3399/...`), and
       `scripts/deploy_device.sh` rejects those variables in the deployed `.mk` files.
     - The stock properties are re-declared from a saved copy of the stock `build.prop`
       (`vendor/hct4/prebuilt/vendor_build.prop.a11`), minus keys Android 14 assigns itself or that
       `device.mk` already sets; `vendor_props_skip.txt` records the collisions.
   - **Ship without an OTA**: flash Android 14 with `fastboot flash` in the ABL (M3). That needs none of the
     above, but then upgrades need the first option.
4. **No installer inside recovery**: `system/bin/recovery` links only the update_engine *client*
   (its strings name `chromeos_update_engine.*` and `/system/bin/update_engine_sideload`), and
   LineageOS's `Updater.apk` ships no native code, so "Local update"/sideload needs
   `update_engine_sideload` in the recovery ramdisk. Nothing in our tree listed it
   (`system/update_engine/Android.bp:582` declares it with `recovery: true`, so `PRODUCT_PACKAGES`
   is what installs it). It is now in `device.mk`.

### `m superimage` before `m dist` staged stale images

`m superimage` builds super from the `IMAGES/` directory inside the target_files staging tree, and
`m dist` (via `add_img_to_target_files`) rebuilds those images. Running superimage first - which is
what `package.sh` used to do - embedded the *previous* pass's images: the offline check compared
`system` against the fresh image and found `embedded_matches=False` while `vendor` (never rebuilt)
matched. `scripts/package.sh` now runs dist first, then superimage, and warns if
`IMAGES/system.img` predates the pass.

## Offline verification of the artifacts

`tools/check_super.py`-style checks run on the build host without touching the unit
(`tmp/check_super.py` there, mirrored in this repo as `scripts/check_super.py` once committed):

- **ext4 magic correction**: the ext4 magic is `0xEF53`, stored little-endian, so the bytes read
  `53 ef`; it sits about 1080 bytes into the filesystem (s_magic is at offset 60 of the ext4 super
  block, which starts at byte 1024). Scanning for `0xEF83` at `+1024` finds nothing - that is what
  made the first layout parse look broken.
- `lpdump` reports the real layout: metadata region 1 MiB, first partition at sector 2048
  (1,048,576 B), extents per partition, group `hct_dynamic_partitions` 3,258,974,208 B inside
  `super_partition_size` 3,263,168,512 B.
- Each logical partition carved out of the raw super is byte-identical to its image and
  `dumpe2fs -h` parses it (block count x block size = the filesystem size).
- `tools/vendor_diff.py` checks the **built** vendor image against the stock reference and classifies
  every difference, so the staging cannot silently drop a blob: *dropped* (the 178 `/vendor/bin`
  aliases, `libOpenCL.so.1/.1.1`, the `/odm` symlink, `default.prop`, `recovery-from-boot.p`, the three
  `#`-named `usb_modeswitch.d` rules), *materialised* (`lib/lib64` `libGLES_mali.so` and `libOpenCL.so`
  must equal the `egl/libGLES_mali.so` blob), *replaced* (`build.prop`, `/etc/fstab.rk30board`, the
  compatibility matrix - same HAL entries, no `<vendor-ndk>`), and *added* (`/etc/init/hu.rc`,
  `/etc/hu_insmod.sh`, `/etc/ueventd.rc`), and the 173 destinations the build installs
  from its own modules (`vendor_build_wins.txt`) - those may differ in size but **must
  be present**, which is what proves the module actually installed them. Anything
  outside those categories fails the check.
  The earlier prebuilt-image run showed 1436 stock files vs 1439 ours, 0 missing, 1 replaced and 3
  added, each overlay byte-identical to its source in `device/rk3399-px6-hct4/`. Note the stock vendor
  has **no** `/etc/ueventd.rc` (it has `/vendor/ueventd.rc`, which Android 14 reads too), and its module
  load is a *service* (`service vendor.insmod_sh /vendor/bin/init.insmod.sh`), not `insmod` lines -
  which is why we supply our own `hu_insmod.sh`. SELinux is permissive for M3
  (`WITH_PERMISSIVE_SELINUX := true`), so a root vendor service is not denied during the boot test.
- `tools/blob_deps.py <vendor-tree> <drop-list> <installed-vendor-list>` proves the kept blobs can
  still load. Of the 217 staged ELF files, 184 stay as blobs and 33 go to the build's own modules.
  None of the kept ones links any library we dropped (libchrome, libdrm, libusb, libvpx, libopus and
  libvorbisidec are dropped with no kept user), and every `DT_NEEDED` resolves:
  `libEGL.so`, `libGLESv2.so`, `libbinder_ndk.so`, `libnativewindow.so`, `libsync.so`, `liblog.so`,
  `libdl.so`, `libm.so` and `libselinux.so` are all in `/system/etc/llndk.libraries.txt`, so the
  vendor namespace may load them, and `libutils.so` + `libbase.so` are installed into
  `/vendor/lib(64)/` by the build's own modules. So `hwcomposer.rk30board.so` (needs libEGL and
  libGLESv2), the midgard allocator/mapper and `camera.rk30board.so` (need libnativewindow and
  libsync) all find their dependencies.
- LineageOS **Updater** is in the image: `system_ext/priv-app/Updater/Updater.apk` plus its
  `init.lineage-updater.rc`, privapp whitelist and default-permissions files.
- The recovery ramdisk carries our fstab as `system/etc/recovery.fstab` (556 entries, gzip cpio),
  so recovery mounts the same logical partitions and knows the raw boot/recovery/misc partitions.
- Boot/recovery image sizes are within their partitions: boot 32,796,672 <= 33,554,432 and
  recovery 43,339,776 <= 100,663,296 (CheckSize passes).

## Rollback artifact

`scripts/build_rollback_super.sh` rebuilds a flashable raw super from the stock package's logical
images, reading `dynamic_partitions_op_list` (group `rockchip_dynamic_partitions` 3,258,974,208 B,
partitions product/vendor/system/odm, 3,125,321,728 B of content) so the Android 10 restore is one
`dd` rather than an improvised re-assembly. It prints the layout with `lpdump` and writes
`sha256sums-rollback.txt`. The authoritative rollback for `boot`/`recovery` is the partition dump
taken off the unit *before* flashing (docs/flash.md), since the installed firmware is not guaranteed
to be byte-identical to the package we have offline.

## Real partition offsets are in the repo

`analysis/hu_partition_offsets.txt` (probe 2026-11-05 19:14, sysfs, no root) holds the unit's actual
LBAs: disk 122,683,392 sectors (62,813,896,704 B), `super` 1,379,328-7,752,703 = **3,263,168,512 B**,
`userdata` 7,752,704-122,683,358 = 58,844,495,360 B, boot = 33,554,432 B, recovery = 100,663,296 B.
Those match `BoardConfig.mk` exactly, which confirms the no-repartition layout (D11 option A).
`scripts/repartition_gpt.sh` now validates against these LBAs and prints the values the repartition
would really produce: super **8,589,410,304**, userdata **53,517,204,992** (sgdisk's 2048-sector
alignment costs 524,288 B of the round 8 GiB).

## fstab form for Android 14

`fstab.rk30board` now uses the Android 14 layout (`device/generic/goldfish/board/fstab/arm64` is the
reference): logical partitions are named in the `<src>` column (`system`, `vendor`, ...) with
`wait,logical,first_stage_mount`, not block paths. `metadata` and `cache` get entries
(`formattable,first_stage_mount`), and `userdata` keeps `checkpoint=enable` for the non-A/B OTA
rollback. The same file is the recovery fstab (`TARGET_RECOVERY_FSTAB` in `device.mk`), because
recovery mounts the same set before update_engine patches the logical partitions.
`scripts/deploy_device.sh` checks the dtb dir, the `second` blob and the prebuilt vendor/kernel
files before the build starts.

## Memory ceiling: docker vs the compile

The NAS has 24 GB RAM and docker holds ~12 GB. `m -j4` climbed to ~19 GB RSS, so the box swapped
hard and SSH stopped answering mid-build ("Connection timed out during banner exchange" ~20 min,
ping still fine). Docker also runs **Pi-hole**, which is this workstation's DNS - while docker is
down, DNS lookups fail here (UDP 53 dropped, TCP 53 refused, HTTPS fine).

Owner's load policy, implemented in `/srv/dev-disk-by-label-SSData/aospbuild/build_fast.sh`:

- **night (22:00-07:00)**: stop every container **except Pi-hole and Home Assistant**, build `-j12`
- **daytime (07:00-22:00)**: leave the whole fleet running, build `-j4` (slow, services stay up)
- containers we stopped are listed in `docker_stopped.txt` and restarted by `trap restore_docker EXIT`,
  so they come back on success, on a failed build, and if the unit is killed

Nothing else on the NAS is touched: no OMV config change, no share change, packages unchanged.

## repo's manifest snapshot inside Soong's sandbox

The build got to 97% and then died on LineageOS's `build-manifest` module
(`vendor/lineage/config/Android.mk:21`, dist-registered in `common.mk:121`), which runs
`repo manifest -o - -r`. repo writes `$HOME/.repo_.gitconfig.json`, but Soong's sbox mounts `/`
read-only, so it failed with `OSError: [Errno 30] Read-only file system: '/root/.repo_.gitconfig.json'`.
Fix: run the build with `HOME=/tmp` (inside the sandbox that is the writable tmpfs), which is what
`build_fast.sh` exports.

## systemd units on the NAS

| unit | does | log |
|---|---|---|
| `los-build` | first build attempt (failed: systemd gave no `HOME`/`GOCACHE`, Soong needs a build cache) | `lineage21/build.log` |
| `los-sync2`/`los-sync3` | retry syncs at `-j2` / `-j1`, both still left fetch failures | `lineage21/sync2.log`, `sync3.log`, `sync4.log` |
| `los-sync5` | shallow (`--depth=1`) checkout in `lineage21s/`, 4 retries | `lineage21s/init.log`, `lineage21s/sync.log` |
| `los-cleanup` | detached deletion of the incomplete `lineage21/` tree (187 GB, ~4 min) | journal |
| `los-sync6` | shallow sync restarted after the volume filled up; left ~15 projects unfetched | `lineage21s/sync.log` |
| `los-sync7` | patient re-sync: `-j1`, 6 passes, 3 min between passes, then a verification block | `lineage21s/sync5.log` |
| `los-build2` | build with `HOME=/root`, `GOCACHE` and `TMPDIR` on the SSD | `lineage21/build.log` |
| `los-build3` | build in `lineage21s/` after the sync lands: device tree + vendor deploy, `lunch lineage_rk3399-<release>-userdebug`, `m -j4` | `lineage21s/build.log` |
| `los-build5` | `m -j4` after the abi fix; swapped hard at ~19 GB RSS while docker held 12 GB, SSH unreachable ~20 min | `lineage21s/build.log` |
| `los-build6` | `build_fast.sh`: docker stopped, `m -j12`, docker restored on exit (also on failure) | `lineage21s/build.log`, `docker_running.txt` |
| `los-build7`/`los-build8` | night full-blast builds; `los-build8` reached 97% of 143,745 steps before the `build-manifest` sandbox failure | `lineage21s/build.log` |
| `los-build9` | daytime run per the owner's policy: fleet stays up, `m -j4`, resumes from the 97% cache | `lineage21s/build.log`, `docker_stopped.txt` |
| `los-build11` | daytime `m -j4`, **build succeeded** (45 min, rc=0, docker untouched) | `lineage21s/build.log` |
| `los-pack4` | `package.sh`: patches + device tree + vendor re-deploy, then `m bootimage`, `m recoveryimage`, `m superimage`, `m dist`, `m otapackage` (docker stays up, `-j4`). boot/recovery/super built; `m dist` stopped at the OTA zip until the zip-symlink patch landed | `lineage21s/package.log` |


`HOME`/`GOCACHE`/`TMPDIR` must be set explicitly for any AOSP build started from systemd; without them
Soong aborts with "build cache is required, but could not be located".


## Missing host tools show up as ninja failures

Debian's NAS had no `zip`, so `//external/guice:guice_munge_srcjar` failed inside Soong's sbox with
`zip: command not found` (exit 127) - a host-tool gap, not a device-tree problem. Added `zip` to the
tracked list. The class of failure to expect: a sbox command referencing a tool the host lacks.
