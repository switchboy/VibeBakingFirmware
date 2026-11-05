# Producing the install package (SD-card route, D10)

## What the build produces

`make` yields, in `out/target/product/rk3399/`:

| image | goes to | note |
|---|---|---|
| `super.img` | partition `super` | contains system/vendor/product/system_ext/odm as logical partitions; vendor is the prebuilt A11 image. Sparse, so the pushed file is ~2.0 GB while the partition is 3,263,168,512 B |
| `boot.img` | partition `boot` | header v2: our overlaid kernel, Android 14 ramdisk, the vendor DTB and the RSCE logo as `second` |
| `recovery.img` | partition `recovery` | update_engine lives here; this is what applies an OTA |
| `dtbo.img`, `vbmeta.img` | not built, not flashed | we do not build either, so their current content stays (`verifiedbootstate=orange`) |

For an upgrade you only need the logical partitions, and `update_engine` gets them from the OTA zip.

## Building the OTA zip

```
m -j4
m dist
m otapackage -j4          # -> out/target/product/rk3399/lineage_rk3399-ota.zip
```
`m dist` runs the non-A/B OTA packaging, so `scripts/apply_tree_patches.sh` must have been applied
first (`patches/releasetools-zip-store-symlinks.patch`, see `docs/build-host.md`) - otherwise zip
follows the staging tree's symlinks into the host filesystem and exits 18.
This tree has no root `Makefile` (the manifest builds symlinks instead), so bare `make` fails with
"No targets specified and no makefile found". `source build/envsetup.sh` provides `m`, which calls
`soong_ui --make-mode`; use `m` for every build target.
LineageOS releases sign with test keys by default (`BOARD_SIGNING_KEYS` unset), which is fine for a
single-unit flash: recovery in an unlocked device accepts it. The zip carries
`dynamic_partitions_op_list` plus `system/vendor/product/system_ext/odm.transfer.list` payloads, so it
resizes logical partitions inside `super` without ever touching the GPT (that is why upgrades never
need the repartition step again).

If `m otapackage` is not available in this tree, fall back to:

```
m dist && python3 build/make/tools/releasetools/ota_from_target_files.py \
     -p out/host -k build/make/target/product/security/testkey \
     --block -b out/dist/target_files.zip lineage_rk3399-ota.zip
```

## Changing super's size without a full rebuild

`BOARD_SUPER_PARTITION_SIZE` has to match the partition `sgdisk` actually wrote (see
`docs/repartition.md` - alignment can shave a few hundred KiB). If the number changes after the
first build, paste the new value into `device/rk3399-px6-hct4/BoardConfig.mk` and run

    m superimage -j4      # re-stages system/vendor/product/system_ext/odm into super.img

That reuses the compiled partitions, so it takes minutes, not hours. The OTA zip must be rebuilt
afterwards too (`m otapackage`) because it carries the resize rules.

## Applying it on the unit

1. Copy the zip to the SD/USB stick (external storage root, or a subdirectory like `download/`).
2. The ROM ships LineageOS's **Updater** app (`vendor/lineage/config/common.mk` adds `Updater`,
   source in `packages/apps/Updater`). Its menu entry **"Local update"** (`UpdateImporter`) takes a
   path relative to the external storage root, runs `RecoverySystem.verifyPackage()`, then
   `RecoverySystem.installPackage()` - so no TWRP and no "apply from SD card" menu is needed (AOSP/LOS
   recovery has no such menu).
3. Recovery boots, update_engine applies the logical partitions, reboot.
4. The unit factory-resets if `--wipe_data` is requested; the owner re-adds accounts/apps (D10).

The zip must verify against the key recovery trusts: our build signs with test keys, and our recovery
carries that same key, so the import check passes on this single unit.

Fallback when no app is available yet: `adb sideload` from the NAS over the OTG gadget port.

## First install (before our recovery exists)

The very first `boot`/`recovery`/`super` write cannot come from an OTA - it needs the Rockchip flash
path (Loader/Boot-ADB mode). Per D11 that first flash keeps the partition table as it is, so the GPT
blobs in `analysis/gpt/` stay unused until the repartition (D8) is applied later; see `docs/flash.md`
for the dd sequence and `docs/repartition.md` for the table change itself.
