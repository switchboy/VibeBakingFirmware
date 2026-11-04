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

## Memory ceiling: docker vs the compile

The NAS has 24 GB RAM and docker already holds ~12 GB. `m -j4` climbed to ~19 GB RSS, so the box
started swapping hard and SSH stopped answering mid-build ("Connection timed out during banner
exchange" for ~20 minutes, ping still fine). That also degrades the docker services, so the owner
decided: **temporarily stop docker during builds and go full blast**, then restart it (night hours,
nobody using the box).

`/srv/dev-disk-by-label-SSData/aospbuild/build_fast.sh` does exactly that and restores it even if the
build fails or the unit is killed:

- `docker ps --format '{{.Names}}' > docker_running.txt` first, so the restore is the exact set that
  was running (OMV's docker plugin containers do not come back on their own after a daemon stop)
- `systemctl stop docker docker.socket`
- `m -j12` (16 CPUs, ~17 GB free RAM once docker is down)
- `trap restore_docker EXIT` → `systemctl start docker docker.socket`, then `docker start` each name
  from the captured list, and prints how many came back

Nothing else on the NAS is touched: no OMV config change, no share change, packages unchanged.

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


`HOME`/`GOCACHE`/`TMPDIR` must be set explicitly for any AOSP build started from systemd; without them
Soong aborts with "build cache is required, but could not be located".


## Missing host tools show up as ninja failures

Debian's NAS had no `zip`, so `//external/guice:guice_munge_srcjar` failed inside Soong's sbox with
`zip: command not found` (exit 127) - a host-tool gap, not a device-tree problem. Added `zip` to the
tracked list. The class of failure to expect: a sbox command referencing a tool the host lacks.
