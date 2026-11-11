# Housekeeping plan - cold storage moves (queued; needs a working shell)

Why this exists: the workstation root filesystem is at 100% (262 GiB used of 279 GiB) and the NAS
`/srv/dev-disk-by-label-SSData` is also at 100% (753 MiB free). That has already broken one
`lpmake` run ("Disk quota exceeded") and, tonight, the shell tool itself. Scratch files from this
week's payload work are the bulk of the new usage.

## Safety rules (do not break these)

* **Never `dd` `/dev/sda` on the workstation** - it is the 7.3 TiB array. Card burns use the
  laptop's `/dev/sda` (7.4 GiB Generic- SD/MMC) only.
* **Never delete the stock rollback**: `/var/tmp/hu-stock-backup/` (14 files, 3.3 GB, `MANIFEST.sha256`)
  and its NAS mirror `/srv/50911774-19fb-46b6-bc9e-8cf81623d044/aospbuild-archive/hu-stock-backup/`.
  Also keep `otacerts-original.zip`, `make_f2fs`, `fsck.f2fs`, `boot.bin`, `super.bin`.
* **Never delete the active payload**: `/var/tmp/a14chk/raw-super.img` (`d4b4990931cc...`,
  3,263,168,512 B), `/var/tmp/a14chk/a14-boot-fixed.img` (`933e2ecc4237...`), the five `*-slice.img`
  files, `pristine-a14-boot.img` (`83fd2a15c744`), `sha256.txt`.
* **Never delete the NAS build tree** `/srv/dev-disk-by-label-SSData/aospbuild/lineage21s` or the
  staged OEM blobs in `aospbuild-archive/ref-a10/` (the vendor slice is built from them).
* Move, do not delete. Verify the copy landed (`sha256sum` or `cmp`) before removing the original.

## Pick the cold target first (measure, don't guess)

```
sh /tmp/opencode/omv.sh "df -h /srv/*/ | tail -8; lsblk -o NAME,SIZE,MOUNTPOINT | tail -12"
```
The NAS exposes `dev-disk-by-label-data3`, `dev-disk-by-label-parity`, `dev-disk-by-label-SSData` and
raw uuid mounts. `SSData` is full and holds the live build tree, so cold storage should be whichever
of `data3` / `parity` has room - `parity` is redundancy-backed, so prefer `data3` for archives unless
`data3` is the parity member. Create `/srv/dev-disk-by-label-<chosen>/cold/vibe-baking/` and record the
choice here once measured.

## Move candidates (measure each size before moving)

Workstation:

| path | what it is | action |
|---|---|---|
| `/var/tmp/a14repack/` | boot repack scratch from Nov 10, superseded by `/var/tmp/a14chk/` | move to cold |
| `/var/tmp/a14chk/*.sparse`, `super-a14-rebuilt.img`, `/tmp/opencode/vendor-in-super.img`, `/tmp/opencode/sys-in-super.img`, `/tmp/opencode/a10-system.img` | one-off verification scratch | move to cold |
| `/tmp/opencode/*.sh` except `omv.sh`, `askpass.sh`, `laptop_askpass.sh` | one-off session scaffolding from Nov 4-9 | move to cold, keep the ssh wrappers |
| `/tmp/opencode/allinone.sh`, `autocontinue*.sh`, `build*.sh`, `d23*.sh`, `wifi_*.sh`, `pack*.sh`, `probe.sh` | same | move to cold |

NAS:

| path | what it is | action |
|---|---|---|
| `/var/tmp/a10-system.img` (1.27 GB), `/var/tmp/sys-region.bin`, `/var/tmp/rec-full.bin`, `/var/tmp/recrd/` | tonight's offline extraction | move to cold |
| `/var/tmp/mkfs/`, `/var/tmp/otac/`, `/var/tmp/otac-dual.zip`, `/var/tmp/huzip/` | cert + mkfs extraction | move to cold after the payload is signed |
| `/srv/.../aospbuild-archive/extracted update.zip/` | unpacked OEM package, re-extractable from the repo zip | move to cold |
| `/srv/.../aospbuild-archive/vibe-fix/`, `vibe-rescue/`, `a11boot/`, `out/` | old build/packaging passes (`lpmake.log` lives in vibe-rescue) | move to cold |
| `/srv/.../aospbuild-archive/props.txt`, `*.log` | old probes | move to cold |

Do not touch: `lineage21s/`, `ref-a10/`, `hu-stock-backup/`, `stage/`, `system.img`/`vendor.img` used
for slice regeneration.

## After moving

1. `df -h /` on the workstation and `df -h /srv/dev-disk-by-label-SSData` on the NAS - the goal is
   enough free space that `lpmake`/`repack_bootimg` can run again.
2. Re-verify the payload hashes still resolve: `sha256sum /var/tmp/a14chk/raw-super.img` must still be
   `d4b4990931cc...`, boot must stay `933e2ecc4237...`.
3. Commit the pending repo changes (see the "Queued for the morning" section in `docs/findings.md`).
