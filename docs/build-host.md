# Build host

The local machine cannot build Android: its root filesystem has ~30 GB free, its storage volume is
NTFS (`nocase`, fake symlinks - an AOSP tree needs real symlinks and case-sensitive paths), and
~4 GB of RAM is free while other workloads hold the rest. So the build runs on the NAS.

## Target

| item | value |
|---|---|
| host | OMV NAS, Debian 13 (trixie), x86_64, 16 CPUs, 24 GB RAM + 24 GB swap |
| build root | `/srv/dev-disk-by-label-SSData/aospbuild/` |
| LineageOS tree | `/srv/dev-disk-by-label-SSData/aospbuild/lineage21` |
| repo checkout | `/srv/dev-disk-by-label-SSData/aospbuild/VibeBakingFirmware` |

`SSData` is the SSD partition (`CT500MX500SSD1`, 266 GB free at setup). The 7.3 TB pool members were
not chosen: they are spinning HDDs (`ST8000VN004`) inside a mergerfs pool, which is slow for
`repo sync` / ninja, and `/srv/dev-disk-by-label-parity` must never be written to. Budget: tree
~60-70 GB, `out/` ~35-45 GB, so ~110 GB of the 266 GB free.

## Packages installed (track these, remove when done)

Recorded in `/srv/dev-disk-by-label-SSData/aospbuild/installed_packages.txt`:

    git-lfs repo unzip device-tree-compiler brotli

Already present before setup: git, python3, curl, make, gcc, g++, patch, cpio, bzip2, pkg-config.
`repo` comes from Debian's package (launcher 2.54; repo offers 2.71 and says to upgrade - harmless).

Removal after the build:

    apt-get purge -y git-lfs repo unzip device-tree-compiler brotli
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
- Memory: 24 GB with docker already using ~12 GB. Build with a bounded job count (`make -j6` or
  `ninja -j6`) and watch RSS; Android 14 compilation peaks well above the free RAM otherwise.
- Expect to need `abootimg`/`mkbootimg` and `f2fs-tools` later for assembling boot images and the
  repackaged super/userdata. Add them only when actually used, and add them to the tracked list.


## Space plan on the SSD

`/srv/dev-disk-by-label-SSData` holds docker (87 GB) plus the checkout, so after a full sync there is
about 83 GB free - not enough for `out/` (Android 14 wants 50-70 GB with intermediates). Plan: once
`repo sync` succeeds, delete `.repo/` (~59 GB of git objects). The build does not need repository
history; if we ever need to sync again, re-run `repo init` + `repo sync`. Re-check `df -h` before
starting `make`.

## Sync retry

The first `repo sync -c -j4` left ~152 projects unfetched ("Unable to remote fetch project ..."), which
is why `vendor/lineage` and `build/make/release` were missing and `lunch` rejected the combo. Retry with
`repo sync -c -j2` (log: `lineage21/sync2.log`). GitHub rejects some concurrent fetches, so lower job
count, not higher.

## systemd units on the NAS

| unit | does | log |
|---|---|---|
| `los-build` | first build attempt (failed: systemd gave no `HOME`/`GOCACHE`, Soong needs a build cache) | `lineage21/build.log` |
| `los-sync2` | retry sync, then prints available release configs and lunch choices | `lineage21/sync2.log` |
| `los-build2` | build with `HOME=/root`, `GOCACHE` and `TMPDIR` on the SSD | `lineage21/build.log` |

`HOME`/`GOCACHE`/`TMPDIR` must be set explicitly for any AOSP build started from systemd; without them
Soong aborts with "build cache is required, but could not be located".
