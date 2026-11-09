# Measured findings — evidence, not decisions

This file holds the measurement/evidence records that used to sit inside `docs/decisions.md`.
Decisions stay in `docs/decisions.md` (D1-D25); pointers here point back. Numbers are what the
build host / dumps / probes actually produced - do not edit a number here without re-measuring.

## Packaging pass Nov 8 - dist, super, the HU payload, and its offline verification

**Run on the build host** with the daytime policy (`-j4`, docker fleet untouched, everything via
`nohup` over ssh - never systemd-run, whose unit env breaks `envsetup.sh`; scratch under
`aospbuild/tmp`). Order mirrored `scripts/package.sh` minus `m otapackage` (the HU payload does not
need it): deploy exit 0, `m dist -j4` rc=0, `m superimage -j4` rc=0, `m bootimage -j4` rc=0.
Mid-dist the SSD dipped to 6.6 GB free while the regenerable symbol/img/proguard zips were being
written; they were pruned (the `prune_dist` list) and the pass finished with ~14 GB free. The dist
flow ran `ota_from_target_files` itself, so a fresh `lineage_rk3399-ota.zip` (1,012,957,295 B,
sha256 `931bbb45…`) exists too - it is not the flash transport, the HU payload is.

**Gate verdicts (`scripts/verify_artifacts.sh`), honest:**
* super layout: `ALL LOGICAL PARTITIONS VERIFIED: True` - every embedded partition byte-identical to
  the raw image in the product dir, ext4 parses, used 2,301,386,752 of 3,258,974,208 (group spare
  957,587,456), group inside super_partition_size 3,263,168,512.
* VINTF: `check_vintf_compatible.log` COMPATIBLE, no ERROR lines; the derived vendor manifest carries
  10 HIDL HAL entries (audio, audio.effect, bluetooth, camera.provider, allocator, composer, mapper,
  omx, memtrack, sensors) + 5 fragments (health@2.1, cas@1.2, wifi-service, hostapd, supplicant); no
  duplicate FqInstance, no vendor-ndk. The stock wifi@1.3/hostapd/supplicant HIDL blocks are *not* in
  the manifest.xml the image assembled, so the watch above did not need an edit.
* boot header: v2, Android 14.0.0, patch 2026-10, cmdline keeps `androidboot.hardware=rk30board` and
  `androidboot.selinux=permissive`; `boot.img` 32,796,672 B (the bootimage rebuild was a ninja no-op).
* recovery ramdisk carries `update_engine_sideload` + `libfusesideload.so` + `recovery.fstab` rows for
  boot/recovery/misc/userdata/cache/metadata.
* `vendor_abi_check.py`: 4 unresolved blobs - exactly the declared `libomxvpu_dec/enc` gap (x2 arches),
  unchanged from D23. `blob_deps.py`: every DT_NEEDED of the kept blobs resolves.
* `vendor_diff.py` and `vendor_dropped_check.py` exit non-zero. Checked against the image, the flags
  are mostly tool noise: the `usb_modeswitch.d` names containing `=`/`#` are intentionally unstaged
  (`gen_vendor_staging.py` records why - Make cannot carry them in a `src:dst` pair, and the HU's
  `usb_dongle` only looks up `%04x_%04x`); the manifest "MISSING HAL" lines are the HIDL-vs-AIDL key
  mismatch (the same services are declared, as fragments/AIDL); the missing `wifi@1.0-service`,
  `librkwifi-ctrl` and `rild` paths are the D21 drop / declared deviations, replaced by the AIDL wifi
  stack. One flag is a real content gap: **`libstagefright_softomx_plugin.so` is not in vendor.img**
  (the staging dir holds it and `installed-files-vendor.txt` lists it, but the dist image filter drops
  it) - `android.hardware.media.omx@1.0-service` therefore cannot dlopen soft OMX codecs. Android 14's
  media stack uses Codec2 and the Rockchip VPU OMX plugin is already the declared gap, so the loss is
  confined to legacy OMX paths (some HCT media apps); not fixed in this pass, recorded here.
  `libwpa_client.so` shared lib is absent but inert: `wpa_supplicant`/`hostapd` link it statically and
  the installed `libwifi-hal.so` (both arches) does not name it (readelf-checked from the image).

**The payload (`scripts/build_hu_package.sh`, first run).** Its relative `<out-zip>` broke `zip`
when the script ran from the scratch dir (`../tmp` from `tmp/hupkg.XXXX` is `tmp/tmp`); fixed by
absolutizing `OUT` (and creating its dir) before anything uses it. Numbers:

| partition | raw image | resize | `new.dat.br` (brotli -q 9) |
|---|---|---|---|
| system | 1,012,817,920 | 1,012,817,920 | 462,236,938 |
| vendor | 444,424,192 | 444,424,192 | 127,220,764 |
| product | 456,159,232 | 456,159,232 | 195,341,325 |
| system_ext | 384,802,816 | 384,802,816 | 115,347,508 |
| odm | 811,008 | 811,008 | 216,933 |

logical content 2,299,015,168 B of group `hct_dynamic_partitions` 3,258,974,208 B - spare
959,959,040 B, no resize (**D19**); super device size stays 3,263,168,512 B (**D11**). Store zip
945,061,278 B, sha256 `c1e5ea5a855070ba051af13d02f3defcbaeceb385eae7bceb77152d944bc534f`. NAS:
`aospbuild/tmp/hu-package/update.zip`; workstation: `out-hu/update.zip` (same sha, verified).

**Rebuilt twice after the probe landed (Nov 8) - the second rebuild is the flashable one.**
`/system/bin/hu_probe.sh` was added to `hu_apps.mk` and `m systemimage` carried it into `system.img`
(byte-identical repo copy, sha256 `04bb6e03…`). First rerun of `scripts/build_hu_package.sh`: `system`
resize 1,012,826,112 B, zip 945,070,196 B, sha256 `05b468b0…`. Second rerun, after the auto-probe
service `/system/etc/init/hu_probe.rc` (1,183 B) and the adb key `/system/etc/hu_adb_key.pub` (714 B)
were staged: `system` raw/resize 1,012,834,304 B, logical content 2,299,031,552 B, spare 959,942,656 B,
brotli system 462,219,217 B with vendor/product/system_ext/odm byte-identical to the earlier pass.
**Final payload: store zip 945,043,557 B, sha256
`8da3fe4c54a90e2e773557eb176a96b0b3b93d09749c81d1e0f4237ad45c7f0e`**, NAS
`aospbuild/tmp/hu-package/update.zip`, workstation `out-hu/update.zip` (same sha), `unzip -tqq` clean,
updater-script audit unchanged (zero bootloader/recovery/security writes). `debugfs` on the decompressed
system image shows `/bin/hu_probe.sh` (inode 413, 0755, 8086 B), `/etc/init/hu_probe.rc` (797, 0644,
1183 B) and `/etc/hu_adb_key.pub` (772, 0644, 714 B) - the auto-probe and the adb key are provably in
the payload. The two earlier zips (`c1e5ea5a…`, `05b468b0…`) are superseded, not flashable.

**Offline payload audit (owner's pre-flash gate), all proven:**
* `unzip -l`: 27 entries exactly - `dynamic_partitions_op_list`, 5 transfer lists, 5 `.new.dat.br`,
  5 empty `.patch.dat`, `boot.img`, `uboot.img`, `trust.img`, `dtbo.img`, `RKLoader.bin`,
  `META-INF/com/google/android/{update-binary,updater-script}`. No super.img, no stray files;
  `unzip -tqq` clean.
* op list: `add_group hct_dynamic_partitions 3258974208`, five `add` (system_ext included), five
  `resize` summing to 2,299,015,168 <= the group; stock vocabulary only.
* updater-script: device assert, `update_dynamic_partitions`, five `block_image_update`, the boot
  write, `wipe_block_device` userdata+cache 8 MiB; zero uboot/trust/dtbo/RKLoader/loader/security/
  recovery writes (those words appear only in the trailing comment). Removed from the stock script:
  the trust/uboot/dtbo writes, `RKLoader.bin` -> `/tmp` + `write_raw_loader_image()`, the whole
  `super.img` write, the `security` wipe; added: the `system_ext` partition and the two wipes.
* byte-identity (sha256): `uboot.img` `8407e60d…`, `trust.img` `7f2c4e52…`, `dtbo.img` `28a07d49…`,
  `RKLoader.bin` `02cade6d…`, `update-binary` `80571323…` all equal the stock package copies;
  `boot.img` `83fd2a15…` equals the product-dir copy.
* vendor `.new.dat.br` decompresses (brotli -d) to exactly 444,424,192 B; ext4 magic `53 ef` at
  offset 1080, `dumpe2fs -h` reports Block count 108502, `debugfs` reads /bin/hw (wifi-service) and
  /lib (libwifi-hal.so) - nothing mounted.

## No terminal on the unit: how first-boot diagnostics reach us (Nov 8, snag reported by the owner)

The first flash has no shell. Checked, not assumed:

* **LineageOS ships no Terminal app in this tree** - `packages/apps/` has none, and nothing in
  `vendor/lineage/product/config` requests one. There is also no `su`/root addon requested, so the
  Android 10 route the Nov 5 probe used (`/system/xbin/su` + Termux, `incoming/probe-20261105-1914.md`)
  does not exist here. Shipping Termux would be a large app plus its own bootstrap packages, and as an
  app uid it still could not run `iw`, `dmesg` or `getevent` (DAC, not SELinux, blocks those), so it is
  not the answer.
* **USB adb works but needs two things**: USB *device* mode on the board (the stick ports are host-mode;
  the RK3399 OTG controller is present, `dwc_otg.speed=0` is in the boot cmdline), and adb authorization,
  which is a prompt on the unit's screen - unusable if touch does not come up. `ro.adb.secure=1` is
  assigned by `build/make/core/main.mk:399`, so assigning it in `device.mk` fails with
  "found duplicate sysprop assignments" (the same trap the `ro.hwui.use_vulkan` comment records), and
  setting it to 0 would remove authorization outright. Instead `hu_system/etc/hu_adb_key.pub` (the
  workstation's own adb *public* key, staged to `/system/etc/hu_adb_key.pub`) is appended to
  `/data/adb/adb_keys` by `hu_probe.sh` at boot: USB adb then connects authorized **by key**, security
  untouched. `adb root` is available regardless because `ro.debuggable=1`.
* **The FIQ serial console is real**: the boot cmdline carries `console=ttyFIQ0` (Rockchip's FIQ
  debugger UART), so a UART adapter on those pins is a root shell with no adb - the fallback if OTG
  turns out not to work.
* **The gap is closed inside the ROM**: `/system/etc/init/hu_probe.rc` (ours, copied through
  `hu_apps.mk`) defines a `oneshot`/`disabled` service running `/system/bin/hu_probe.sh` as root when
  `sys.boot_completed=1` fires. init forwards the service's stdout to `/dev/kmsg`, and the script also
  writes `/data/local/tmp/hu-probe-<ts>.md` (mode 0644 from root, so pullable with `adb pull` without
  root) and copies to `/mnt/udisk` after waiting ~2 min for the stick to mount (`persist.sys.storage_manager
  .usb_storage=true` is already set). So the report lands on the stick that carried `update.zip` even if
  neither adb nor serial is reachable - which is exactly what the owner asked for. SELinux stays
  permissive during bring-up (**D5**), hence the borrowed `u:r:shell:s0` label, same as `hu_insmod`.
  `scripts/verify_hu_apps.sh` now checks the service definition, the trigger, and `ro.adb.secure=0`.

## SD-card flashing (the Malaysk "SD_firmware_tool" idea) - what this uboot actually supports (Nov 8, measured)

The owner asked whether we can ship a bootable SD card that flashes the ROM, the way Malaysk's tool does.
Checked against the uboot image we hold (`uboot.img` from the payload, 4,194,304 B), not assumed:

* u-boot's boot targets are `mmc1 mmc0 usb0 pxe dhcp`, with `bootcmd_mmc0=setenv devnum 0; run mmc_boot`.
  So mmc boot exists in general - but the eMMC comes first, so a card is only reached when the board is
  put into SD-boot mode (a hardware/boot-mode trigger), and this HU has no wired SD slot for `/sdcard`.
  The SD route the Dasaita threads describe is the *recovery* reading a FAT32 card, not u-boot SD boot.
* No sdcard-burn code is in the image: zero `sdcard`/`sd_update`/`update.img` strings. Rockchip's
  `update.img` + `parameter` flow is not what this uboot carries; a `parameter`-driven flash also
  recreates partitions from that file, which is exactly what **D19** forbids.
* **AVB and a bootloader lock state are present**: strings `avb-locked`, `bootloader-locked`,
  `at-lock-vboot`/`at-unlock-vboot`, `avb_write_lock_state`, `android_avb_boot_flow`,
  `Android avb boot failed, error %d`, `FAILThe device is locked, can not flash!`, and there is a
  `vbmeta` partition (`mmcblk2p6`, 1,048,576 B). `/proc/cmdline` was not readable from the Nov 5 non-root
  probe, so the lock state is still unknown - but init turns `androidboot.*` into props, so it reads
  without root: `getprop ro.boot.vbmeta.device_state`. If that says **locked**, a replaced `boot.img`
  fails AVB verification and *no* transport (recovery, adb dd, SD-burn, mod ROM) boots Android 14 - the
  whole plan changes and the vbmeta/bootloader policy (**D18**) needs revisiting with the owner. If it
  says unlocked, AVB is not enforced and the boot-image write is fine.
  `hu_probe.sh` now reports `device_state`, `avb_version` and `vbmeta_digest` on Android 14 too.

Ranking stays: route 1 (testkey-signed zip) -> route 2 (adb root + dd) -> SD-burn only if AVB is
unlocked *and* we build a parameter file with byte-identical partition sizes and no bootloader
partitions -> mod ROM last. The SD/mod routes have no signature gate at all, which today is the only
thing protecting us from a bad flash.

## OEM reference packages on disk - what each one is (Nov 9, measured)

Three OEM packages live on this workstation (the originals are also on the NAS archive
`/srv/50911774-19fb-46b6-bc9e-8cf81623d044/aospbuild-archive`). Names alone are ambiguous, so identify
them by sha256. Read `META-INF/com/android/metadata` for the build, and the zip EOCD comment via
`tools/zip_comment_sig.py` for the signature. All three OEM packages are signed by the **same** OEM
certificate, which is the one the unit's recovery trusts (**D25**).

| file | size B | sha256 | Android / build | key type | signer cert (EOCD comment) | role |
|---|---|---|---|---|---|---|
| `update.zip` (repo root) | 1,203,718,969 | `dd3e2ac0610bb64f0715e520300e5ee2dd6652e80fc33bdb0f1a02ba87528013` | 10 / `QQ2A.200305.004.A1`, `eng.hct2.20210311.174916` (2021-03-11) | userdebug **test-keys** | `cf:2a:b3:81:85:95:c4:ed:a0:8c:ec:72:bb:e3:9b:c3:77:a3:0b:76:4a:3e:eb:de:52:53:6e:ae:01:80:85:25` | rollback package the owner decided on (**D18**, `docs/flash.md`) |
| `diatsia fw/update.zip` | 1,477,122,869 | `50775dba8ca9f99200ede8ec006498baaa383aec963a00de5742896afe6330e8` | 11 / `RQ3A.210705.001`, `eng.hct2.20250401.153219` (2025-04-01) | userdebug **release-keys** | same cert `cf2ab3...` | the OS the unit runs today; the vendor base for **D9**/**D15** |
| `diatsia fw/update(1).zip` | 1,285,817,036 | `31bb492ab6036dd10a9dc9c33be900af23499eef049a260bf267b166f239db4c` | 10 / `QQ2A.200305.004.A1`, `eng.hct2.20250401.152740` (2025-04-01) | userdebug **release-keys** | same cert `cf2ab3...` | the vendor's 2025 rebuild of Android 10 - the **better rollback candidate** (same cert, newer build, patch level still 2020-05-05) |
| `out-hu/update.zip` | 945,046,226 | `b81c50cc3eb07b8b0ba5a3ab7f518d8ba2a0339801608c892bbd640e52d04407` | 14 / our LineageOS 21 payload | userdebug test-keys | `a4:0d:a8:0a:59:d1:70:ca:a9:50:cf:15:c1:8c:45:4d:47:a3:9b:26:98:9d:8b:64:0e:cd` (AOSP testkey) | OUR payload; the recovery rejects it (**D25**) |

What that changes:
* `diatsia fw/update(1).zip` was unlabelled until Nov 9 - it is Android 10, not Android 11, and it is
  newer than the repo-root package (`post-timestamp` 1743492149 vs 1615456030). If the rollback is ever
  needed, this is the package to prefer: same trusted cert, a 2025 build, release-keys, and it still
  installs through the untouched stock recovery.
* All OEM packages carry `RKLoader.bin`, `uboot.img`, `trust.img`, `dtbo.img`, `logo.img` and a
  `dynamic_partitions_op_list`. So a stock install restores the OEM bootloader too - that is fine for a
  rollback (it returns the unit to vendor state), but it is also why our payload deliberately writes
  neither the bootloader nor the partition table (**D18**/**D19**).
* Signature verification happens in recovery *before* any partition write, so re-flashing an OEM package
  to test the rollback path is safe; a rejected package writes nothing.
