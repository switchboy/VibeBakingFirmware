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
one call. `scripts/apply_tree_patches.sh` applies it with `git apply` (GNU patch 2.8 rejects the hunks even though the context matches byte-for-byte); `package.sh` runs it before
every packaging pass, and `patch --forward` makes it idempotent.

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
