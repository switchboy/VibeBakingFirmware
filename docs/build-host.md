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

    git-lfs repo unzip device-tree-compiler brotli gdisk

`gdisk` is only needed by `scripts/repartition_gpt.sh` (`sgdisk` computes the GPT CRCs).
Already present before setup: git, python3, curl, make, gcc, g++, patch, cpio, bzip2, pkg-config.
`repo` comes from Debian's package (launcher 2.54; repo offers 2.71 and says to upgrade - harmless).

Removal after the build:

    apt-get purge -y git-lfs repo unzip device-tree-compiler brotli gdisk
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
- Memory: 24 GB with docker already using ~12 GB. Build with a bounded job count (`make -j4`, drop
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
keeping `.repo/manifest.xml` and `.repo/manifests/`, because `make dist` reads the manifest. Re-check
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
Tree: `lineage21s/`, log: `lineage21s/sync.log` (mirrored to the workstation's
`/run/media/Daan/Opslagmonster/build-watch/`).

## Release name and lunch

Android 14 requires `<product>-<release>-<variant>`, and the release configs live in
`build/release/configs` (not `build/make/release`). `lineage21/build.log` showed
`Invalid lunch combo` because both `build/release` and `vendor/lineage` were unfetched. The build
script reads the available configs and picks the LineageOS one:

    REL=$(ls build/release/configs | grep -m1 '^lineage')     # else the first config listed
    lunch lineage_rk3399-$REL-userdebug                        # logs TARGET_PRODUCT/TARGET_RELEASE

`vendor/lineage/build/envsetup.sh` is sourced by `build/envsetup.sh`, so a missing `vendor/lineage`
also aborts lunch - it is part of the sync check.

## systemd units on the NAS

| unit | does | log |
|---|---|---|
| `los-build` | first build attempt (failed: systemd gave no `HOME`/`GOCACHE`, Soong needs a build cache) | `lineage21/build.log` |
| `los-sync2`/`los-sync3` | retry syncs at `-j2` / `-j1`, both still left fetch failures | `lineage21/sync2.log`, `sync3.log`, `sync4.log` |
| `los-sync5` | shallow (`--depth=1`) checkout in `lineage21s/`, 4 retries | `lineage21s/init.log`, `lineage21s/sync.log` |
| `los-build2` | build with `HOME=/root`, `GOCACHE` and `TMPDIR` on the SSD | `lineage21/build.log` |
| `los-build3` | build in `lineage21s/` after the sync succeeds: cleanup, device tree + vendor deploy, detected lunch combo, `make -j4` | `lineage21s/build.log` |


`HOME`/`GOCACHE`/`TMPDIR` must be set explicitly for any AOSP build started from systemd; without them
Soong aborts with "build cache is required, but could not be located".
