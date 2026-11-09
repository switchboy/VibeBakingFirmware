# Measured findings — evidence, not decisions

This file holds the measurement/evidence records that used to sit inside `docs/decisions.md`.
Decisions stay in `docs/decisions.md` (D1-D31); pointers here point back. Numbers are what the
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
  `scripts/verify_hu_apps.sh` now checks the service definition, the trigger, and that the workstation's
  adb **public** key is staged at `/system/etc/hu_adb_key.pub` for `/data/adb/adb_keys` injection. It does
  not check `ro.adb.secure`: that prop stays **1** (assigned by `build/make/core/main.mk`, see
  `device.mk:95`), so authorization is granted by key rather than switched off.

## SD-card flashing (the Malaysk "SD_firmware_tool" idea) - what this uboot actually supports (Nov 8, measured)

The owner asked whether we can ship a bootable SD card that flashes the ROM, the way Malaysk's tool does.
Checked against the uboot image we hold (`uboot.img` from the payload, 4,194,304 B), not assumed:

* u-boot's boot targets are `mmc1 mmc0 usb0 pxe dhcp`, with `bootcmd_mmc0=setenv devnum 0; run mmc_boot`.
  So mmc boot exists in general - but the eMMC comes first, so a card is only reached when the board is
  put into SD-boot mode (a hardware/boot-mode trigger), and this HU has no wired SD slot for `/sdcard`.
  The SD route the Dasaita threads describe is the *recovery* reading a FAT32 card, not u-boot SD boot.
* ~~No sdcard-burn code is in the image: zero `sdcard`/`sd_update`/`update.img` strings.~~
  **Corrected Nov 10: this bullet was wrong.** The grep pattern missed the Rockchip update strings; the
  image does carry them (`Found IDB in SDcard`, `Found IDB in U-disk`, `sdfwupdate`, `usbfwupdate`,
  `Forbid to flash mmc 1(sdcard)`, `rkimgtest`) and the env probes `mmc dev 1` first. See
  "Unbrick SD route - Nov 9/10" below for the re-measurement. What still holds from Nov 8 is the
  structural objection: a `parameter`-driven flash recreates partitions (**D19**) and the card flow
  touches the loader (**D18**), so it is rescue media only, never our normal install path.
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


## SD-card / `update.img` route - Nov 9 research verdict (offline, no device touched)

The Nov 8 section above is the measurement. The Nov 9 web research (opened pages cited below) answers
the mechanism question; the verdict is **not viable for this HU under D11/D18/D19**, and the reason is
structural, not uncertain:

| variant | works on RK3399 generally? | satisfies our constraints? | why |
|---|---|---|---|
| Rockchip `SD_Firmware_Tool` "Upgrade Firmware" card (flag 0) | documented for rk3399 | **no** | the card-carried recovery flashes a whole `update.img`; that code writes the **loader** and the **recovery** partition unconditionally, and rewrites the `parameter` partition when it differs from the device's. Needs a wired `sdmmc` slot - this HU has none |
| same payload on a USB stick (`usbfwupdate` / `boot_from_udisk`) | exists in Rockchip u-boot code, **not** verified for HCT's build | **no** | loader + recovery are still written unconditionally. The parameter/GPT write *is* skipped on the USB path, so that half is constraint-friendly |
| per-partition writes from a booted Android (our route 2) | yes | **yes** | only `super` + `boot` are written; no loader, no recovery, no partition table |

* ~~u-boot on this unit has no sdcard-burn code at all (zero `sdcard`/`sd_update`/`update.img` strings),~~
  **Corrected Nov 10:** the strings are present and `rkimg_bootdev` probes `mmc dev 1` before the eMMC, so
  the SD slot *is* scanned (`boot_targets=mmc1 mmc0 usb0 pxe dhcp`). The rest of this bullet's reasoning
  stands: RK3399 u-boot mmc1 = SD, mmc0 = eMMC (Linux numbers them sdio=0/sdmmc=1/sdhci=2, which is why
  the eMMC shows up as `mmcblk2`). Verified from mainline U-Boot board docs:
  <https://docs.u-boot.org/en/latest/board/rockchip/rockchip.html> (RK3399, TF-A `PLAT=rk3399`, SD boot
  `dd if=u-boot-rockchip.bin of=/dev/sda seek=64`, MaskROM fastboot `2207:330c`). Rockchip staging tree
  <https://github.com/rockchip-linux/u-boot> is active (default `next-dev`).
* If an `update.img` were ever built, the offline toolchain is Rockchip's own: `afptool` (packs the
  `parameter` + image list into `package-file`) and `rkImageMaker` (adds the loader header to produce
  `RKAndroid.bin`/`update.img`). Both ship as proprietary binaries inside Rockchip's flash tool suites
  (`rkdeveloptool` is the open one: <https://github.com/rockchip-linux/rkdeveloptool>). The `parameter`
  file is a plain text file that declares the whole partition table, and flashing it **recreates
  partitions** - i.e. it rewrites the GPT, which **D19** forbids. We do hold a loader:
  `RKLoader.bin` (465,230 B) is inside the Android 11 package.
* The owner-side extras the HCT/Dasaita flow checks: the card's `MACHINE_MODEL` must equal
  `ro.product.model`, and unless `USE_RSA_CHECK` is set the integrity check is only CRC32 (owner-documented
  behaviour, not spec from us).

**Decision (Nov 9): we do NOT build the emergency restore media.** It would be knowledge/insurance only -
building it is harmless offline, but *using* it requires writing the loader and the recovery partition,
which violates **D18**. ~~and this board has no `sdmmc` slot to boot a card from~~ - **corrected Nov 10:**
the board does have microSD slots and u-boot scans `mmc1` first, so a card can be reached; the loader
objection still stands, which is why the route is rescue-only (**D29**). The brick insurance that
does exist stays: the untouched stock recovery plus the OEM packages (`docs/findings.md`, "OEM reference
packages on disk"). ~~and the full-eMMC snapshot (`analysis/gpt/disk.img` on the HDD archive, 62.8 GB)~~
is **not** insurance - measured Nov 10 it is zero except the backup GPT (see "Unbrick SD route - Nov 9/10").
The tracked GPT dumps still help (`analysis/gpt/gpt_head.bin` is itself all zeros; `analysis/gpt/gpt_tail.bin`
holds the backup GPT, which together with the Nov 4 probe's LBA table is enough to rebuild the partition
table by hand if the layout is ever damaged).

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

## Flash attempt Nov 9/10 (night session) - what actually happened, with timestamps

This is the record of the first real write to the unit. Times are local (CET) as the laptop/unit showed
them. Nothing here is inferred: every line is either a command output we captured or an owner report.

### Bring-up access (this is how we got in - no USB adb, no terminal, no developer options)
* USB adb is impossible on this unit: all three HU sockets are host-mode. The laptop's Type-C port is
  correctly a host (`data_role=host`, `power_role=source`) but saw **no partner at all** - `state`,
  `partner_data_role`, `partner_power_role`, `vconn` all empty - on every socket the owner tried,
  including the one that does Android Auto. Nothing ever enumerated on bus 003/004, zero
  `new ... USB device` kernel lines. `adb devices` stayed empty all night.
* The running firmware has no developer options: tapping the build version repeatedly does nothing
  (owner tried), so USB debugging / wireless debugging could not be turned on.
* Network adb was off: `22 23 5555 5037 8765 2300 9000 4000` all closed on `192.168.1.120` (ping ok,
  rtt ~9-92 ms). The OEM init enables TCP adb only on `persist.internet_adb_enable=1`.
* **The owner's discovery that opened the unit:** in the HU's factory-settings dialog the password
  **`adbon`** (instead of `126`) enables adb for one session, which sets `persist.internet_adb_enable=1`
  and therefore `service.adb.tcp.port=5555`. After that, from the laptop:
  `adb connect 192.168.1.120:5555` -> `device product:rk3399 model:PX6 device:rk3399`, then
  `adb root` -> `uid=0(root) ... context=u:r:su:s0`, no authorization prompt appeared.
  Post-root props read over TCP: `ro.debuggable=1`, `ro.adb.secure=` (empty),
  `ro.boot.verifiedbootstate=orange`, `ro.boot.vbmeta.device_state=` (empty),
  `ro.boot.avb_version=` (empty), `ro.boot.vbmeta.digest=` (empty), `persist.internet_adb_enable=1`,
  `persist.sys.usb.config=adb`. `/data` = 54G with 48G free, no `/mnt/udisk` (no stick), and
  `/dev/block/by-name/` had backup boot cache dtb dtbo frp metadata misc recovery security super trust
  uboot userdata vbmeta (+ mmcblk2, mmcblk2boot0, mmcblk2boot1).

### Staging (laptop, over ssh - nothing on the unit until the flash)
* `/tmp/hu/stage/hu14/` on the laptop: `super.img` 2,275,747,780 B, `boot.img` 32,796,672 B,
  `flash.sh` (from `scripts/flash_from_android.sh`), `sha256.txt`. scp of super took 59.7 s; `sha256sum -c`
  on the laptop: both OK.
* On the unit: `adb push` into `/data/local/tmp/hu14/` - `super.img` 2,275,747,780 B in **675.6 s at
  3.2 MB/s** over TCP adb; `boot.img` 32,796,672 B in 9.0 s. `sha256sum -c` on the unit: both OK
  (`2045af9c2d730aa5cb76df48e8a081b677ccf74a3272dbd1d2419aaf8162ff69`,
  `83fd2a15c74424e8a6c9663dfa89339a77de8ea53b9659e7e3e58819609104f8`).

### flash.sh - two bugs found by running it, both fixed
1. **mksh 32-bit arithmetic.** Android's `/system/bin/sh` (mksh) wraps integers above 2 GiB negative:
   `echo $((2147483648+1))` on the unit prints `-2147483647`. The size guard
   `[ "$super_img" -gt "$super_size" ]` therefore compared `2275747780` against a **negative**
   `3263168512` and aborted with a false "not plausible" message on the first run (19:39). Fixed by
   comparing in awk (`BEGIN{ exit (img+0 > part+0 || img+0 < 1000000000) ? 1 : 0 }`) and by printing the
   `/proc/partitions` fallback with `printf "%.0f"`.
2. **`dd` skip units.** The tail backup used `skip=3246391296` with `bs=4096`, i.e. a skip in *blocks*,
   not bytes -> `Can't skip`, so `super-tail.bin` was never written. Correct value is `792576` blocks
   (`(3263168512 - 16777216)/4096`, verified with awk; the first fix in this file said 792552, which is
   wrong). Fixed in the script on Nov 10: the skip is now computed in awk as a block count. The manual retry of that dd got no reply
   because adb went offline a moment later, so **the tail backup of super is NOT verified** - the head
   backup and the whole `boot` partition are.

### The write itself (19:39:51, captured output)
```
hu14 flash - Mon Nov  9 19:39:51 CET 2026
running rom: 10 rk3399-userdebug 10 QQ2A.200305.004.A1 eng.hct2.20220412.155213 test-keys
target device confirmed running Android 10
  ok   super.img  2045af9c...   ok   boot.img  83fd2a15...
super partition 3263168512 B ; super.img 2275747780 B ; boot.img 32796672 B
16777216 bytes (16 M) copied, 0.089422 s, 179 M/s        <- super head backup
/dev/block/by-name/super: Can't skip                     <- super tail backup FAILED
33554432 bytes (32 M) copied, 0.179183 s, 179 M/s        <- boot partition backup (full)
2275747780 bytes (2.1 G) copied, 34.105447 s, 64 M/s     <- super written
32796672 bytes (31 M) copied, 0.941266 s, 33 M/s         <- boot written
sync  ... done: super and boot now hold Android 14
```
Note the running ROM line: the unit was **Android 10** (`QQ2A.200305.004.A1`, build
`eng.hct2.20220412.155213`, test-keys) - not Android 11 as our docs assumed. Android 11 is what the
`diatsia fw/update.zip` package contains, not what was installed.

### What the unit did afterwards (owner reports)
* adb went `device offline` during the backup pull attempts, then `ping 192.168.1.120` = **No route to
  host** - the unit's WiFi disappeared. So Android 14 did not reconnect (expected: Android 14 cannot
  recover Android 10's Wi-Fi credentials, and the `persist.internet_adb_enable=1` prop lives in `/data`).
* **Black screen: no boot animation, no Android 10 logo.** Power-cycling the unit keeps the display off.
* **No recovery menu** - no button combo the owner tried reaches it.

### Offline verification after the failure (why we think the payload itself is sound)
* `out-hu/boot.img` vs the OEM Android 11 image: same header shape (header_size 2048, page field 2 at the
  Rockchip offsets), same kernel size 30,455,816 B (the same OEM 4.19 kernel), same load addresses
  kernel `0x10008000`, ramdisk `0x11000000`, second `0x10f00000`, tags `0x10000100`, gzip ramdisk at the
  same offset (`1,632,189 B` ours vs `838,018 B` OEM), cmdline of the same shape. Differences: ramdisk is
  Android 14's first-stage init, `androidboot.veritymode=disabled` vs OEM `enforcing`,
  `androidboot.wificountrycode=NL` vs `CN`, and the `second` (recovery dtbo) blob differs by hash
  (`cb42e271...` vs OEM `beaa3b8b...`) - u-boot's `android_get_dtbo` path could apply that blob, so it is a
  minor suspect worth testing.
* `lpdump` of the raw super (simg2img of `out-hu/super.img`, 3,263,168,512 B): metadata v10.0, slot count
  2, group `hct_dynamic_partitions` max **3,258,974,208 B**, partitions system/vendor/product/system_ext/odm
  starting at byte offsets 1,048,576 / 1,013,972,992 / 1,444,937,728 / 1,902,116,864 / 2,286,944,256 - and
  the ext4 superblock magics (`53 ef`) were found exactly at those filesystem starts. The five partition
  images total 2,285,122,532 B (system 1,012,834,304; product 456,159,232; system_ext 384,802,816;
  vendor 430,514,176; odm 811,008), so nothing overflows the unchanged partition or group.
* `/vendor/etc/fstab.rk30board` inside the vendor filesystem is present and in Android 14 form
  (`wait,logical,first_stage_mount` for system/vendor/product/system_ext).
* Vendor HAL set inside the written vendor: `/lib64/hw` holds the OEM impls (`hwcomposer.rk30board.so`,
  `gralloc.default.so`, `audio.primary.rk30board.so`, `allocator@4.0-impl-midgard.so`,
  `mapper@4.0-impl-midgard.so`, `hw_output.default.so`, mtc/mfi/sensors/weaver/gnss/camera/health), and
  `/etc/vintf/manifest.xml` declares
  `<name>android.hardware.graphics.composer</name>` with `@2.1::IComposer/default` (HIDL).

### Most likely cause, ranked (the payload boots into Android, but Android does not bring up the panel)
1. **Display stack**: Android 14's SurfaceFlinger against an **HIDL composer@2.1** + OEM Midgard
   allocator/mapper blobs. If the composer service fails to register or the blobs need Android 10-era
   symbols, SF never presents anything -> kernel boots, no boot animation, black screen. This matches the
   observed symptom exactly.
2. **first-stage init / vendor bring-up**: an early crash-loop in a required HAL (composer, gralloc,
   audio) or a missing vendor library would give the same black screen.
3. Boot-image handshake - ruled out by the header comparison above.
4. AVB/trust - ruled out: `verifiedbootstate=orange` before the flash, `vbmeta` untouched, u-boot has
   `Not AVB images, AVB skip`, and `trust.img` runs before u-boot and was never written.
5. super layout / fstab - ruled out by the lpdump + ext4-magic + fstab checks above.

### State we left the unit in, and what restoring means
* `super` and `boot` hold our Android 14 payload (verified shas written at 64 MB/s and 33 MB/s).
* `recovery`, `uboot`, `trust`, `dtb`, `dtbo`, `vbmeta`, `security`, the loader and the GPT are untouched.
  So the OEM boot chain is intact and the unit is not bricked in the sense of a destroyed bootloader.
* Backups on the unit: `/data/local/tmp/hu14-backup/` = `super-head.bin` (16 MB), `boot-current.bin`
  (32 MB, whole boot partition), `super-tail.bin` (unverified), plus `hu14-flash.log`. These live in
  userdata, so they survive a `super` rewrite; they were never pulled to the laptop (adb died first).
* Rollback needs a blind path: either a serial console (`console=ttyFIQ0`, 115200 8N1, 3.3 V) to `dd`
  OEM `super`/`boot` back, or the SD burn route through the untouched u-boot (`rkimg_bootdev=if mmc dev 1
  && rkimgtest mmc 1`, `sdfwupdate`, `Found IDB in SDcard`, plus `Forbid to flash mmc 1(sdcard)`). The
  recovery menu is unreachable by button combo, so recovery-based rollback is not available tonight.
* Outer insurance: the OEM Android 10 packages (all three trusted by recovery) and the GPT dumps. The
  62.8 GB "full-eMMC snapshot" is **not** insurance - measured Nov 10 it is zero except the backup GPT,
  so the rollback payload was rebuilt from `diatsia fw/update(1).zip` instead
  (`docs/findings.md`, "The real rollback payload, rebuilt from the Android 10 (April 2025) package").

### Open questions to measure before any second attempt
1. Serial console output of Android 14's boot: does init reach second stage, which services crash-loop,
   what does SurfaceFlinger say? This is the decisive measurement.
2. Does Android 14 need an **AIDL** composer/gralloc on this kernel, i.e. must we build
   `composer3`/`allocator`/`mapper` AIDL wrappers around the OEM blobs (instead of declaring HIDL 2.1)?
3. Does u-boot apply our boot image's `second` (recovery dtbo) blob on a normal boot? If yes, either
   suppress it or make it byte-identical to the OEM stub.
4. Is `/data` from Android 10 mountable by Android 14 at all, and does the `persist.internet_adb_enable=1`
   prop survive long enough to give us a shell on first boot? (Tonight it did not: WiFi never returned.)
5. Which physical SD slot is the sdmmc one (`dwmmc@fe320000` = Android `sdcard1` = u-boot `mmc 1`) - the
   boot-card slot - versus the recovery slot (`dwmmc@fe310000` = `sdcard2`).

## Unbrick SD route - Nov 9/10 (measured on the uboot image, offline; unit untouched)

The Nov 8 section above claimed this uboot has "zero sdcard/sd_update/update.img strings". That was
**wrong** - the grep pattern missed the Rockchip firmware-update strings. Re-measured on
`uboot.img` (4,194,304 B, sha `a28fd6a0…` from the Android 11 package):

* Code strings present: `Found IDB in SDcard`, `Found IDB in U-disk`, `usbfwupdate`,
  `sdfwupdate`, `Forbid to flash mmc 1(sdcard)`, `%s: Failed to read data from IDB`,
  `rkimgtest` ("Test if storage media have rockchip image"), `RKPARM: Invalid parameter part table`,
  `invalid rkparm parameter`.
* Embedded env: `bootcmd=boot_android ${devtype} ${devnum};bootrkp;run distro_bootcmd;` and
  `rkimg_bootdev=if mmc dev 1 && rkimgtest mmc 1; then setenv devtype mmc; setenv devnum 1;
  echo Boot from SDcard; elif mmc dev 0; ...`, with `boot_targets=mmc1 mmc0 usb0 pxe dhcp`.
  So the SD slot is scanned **first** (`mmc1`), and `Forbid to flash mmc 1(sdcard)` means the flash
  target is the eMMC (`mmc0`), never the card itself.
* Mechanism (Rockchip's SD Card Boot reference, V1.0 2018, plus the SDDiskTool changelog): the card
  carries an IDB-format firmware image whose header sits at **sector 64** (magic `0xFCDC8C3B`); a
  flag byte near the header selects the card type - `0` = upgrade card (u-boot adds `sdfwupdate` to
  the kernel cmdline and the recovery flashes the card's `update.img`), `1` = boot card (u-boot reads
  the firmware from the card and boots it, cmdline gets `storagemedia=sd`), `2` = repair card (the
  firmware is copied from the card while still in the loader stage). SDDiskTool v1.67 added
  `sdfwupdate` to misc, v1.68 replaced it with `rk_fwupdate`.

### What the Nov 5 "full eMMC snapshot" actually contains (measured now, byte-by-byte)

`analysis/gpt/disk.img` (62,813,896,704 B = exactly 122,683,392 sectors) is **not a usable backup**.
A full scan of all 62.8 GB found only two nonzero regions: a remnant at byte 448 (`0200eeffffff0100…`,
protective-MBR-ish) and the backup GPT in the last 4 MB (byte 62,812,848,128). Everything else -
including the primary GPT area, `boot`, `super`, `recovery`, `cache` - is zero. Carving the partition
ranges by the probe's LBAs gave fourteen files whose sha256 is the same for every 4 MiB partition
(`bb9f8df6…`) and zeros everywhere else, which is what a zero-filled file does, not what a live eMMC
does. `analysis/gpt/gpt_head.bin` is likewise all zeros; only `gpt_tail.bin` holds real data
(backup GPT: partition names `u.b.o.o.t…` visible).

Consequence: partition **sizes and names** are trusted (they come from the Nov 4 probe), but partition
**content** is not recoverable from the snapshot. The rollback payload therefore has to be rebuilt from
the OEM package - see next section. The GPT layout can still be reconstructed from `gpt_tail.bin` plus
the probe's LBA table if the partition table is ever damaged.

### The real rollback payload, rebuilt from the Android 10 (April 2025) package (Nov 9/10, verified)

Rebuilt offline on the NAS (`/srv/50911774-19fb-46b6-bc9e-8cf81623d044/aospbuild-archive/vibe-rescue/`),
from `diatsia fw/update(1).zip` (sha `31bb492a…`), using `brotli` to decode the `.new.dat.br` payloads
and `tools/reassemble.py` for the transfer lists:

| partition | bytes | note |
|---|---|---|
| system | 1,275,330,560 | matches `resize system` in `dynamic_partitions_op_list` exactly; 99.6% written |
| vendor | 323,530,752 | matches `resize vendor`; 99.7% written |
| product | 986,509,312 | matches `resize product`; 99.6% written |
| odm | 539,951,104 | matches `resize odm`; 99.6% written |

Group `rockchip_dynamic_partitions`, max **3,258,974,208 B**, super device size **3,263,168,512 B**,
metadata v10.0, 2 slots, 592 B used - the Android 10 vocabulary, no `system_ext` (**D19** layout stays
as the OEM one, nothing resized beyond what the OEM op_list declares).

`super-a10.img` - 3,263,168,512 B, sha256 `30da961c94ba064d1edce80d5dc3b96ad5ec7480a4971b8ca38d1bdb2cefc11c`.
`lpdump` reads it: system at super-sector 2048, vendor 2494464, product 3127296, odm 5054464 (512-byte
sectors, i.e. byte offsets 1,048,576 / 1,277,164,288 / 1,601,178,368 / 2,587,884,288). Content verified,
not just parsed: carving the system slice (`dd bs=512 skip=2048`) opens as ext4 in `debugfs`, `ls /`
shows `init`, `init.rc`, `init.hct.rc`, `init.zygote64_32.rc`, `default.prop`, `lib`, `sbin`, `product`,
`odm`, `oem`, and `stat /system/build.prop` gives inode 862, 2,470 B. So this really is an Android 10
system image, and `init.hct.rc` is present in it.

`boot-a10.img` - the package's own `boot.img`, 27,406,336 B, sha256 `04a43ea931de08734d8a25afe9920cba69a099095ab4b4490dbbe4368d0b89c6`
(header: kernel 25,671,688 B, kernel addr `0x10008000`, ramdisk addr `0x11000000`, second `0x10f00000`,
tags `0x10000100`, header_size 2048, page field 2, cmdline starts `console=ttyFIQ0 androidboot.baseband=N/A
androidboot.basename=...`). It is **not** byte-identical to the boot the unit was running (that backup,
`boot-current.bin` 32 MB, died with adb on the unit), so the rollback restores the vendor's April 2025
boot image rather than the previously installed one - which is the intended rollback semantics.

The OEM updater-script also writes `trust.img`, `uboot.img`, `dtbo.img` and runs `write_raw_loader_image()`
from `RKLoader.bin` (`BOOT` header magic, 465,230 B). Those are the vendor's own boot-chain images; a
stock install restores them too (**D18** note: our payload never wrote them, so the unit's boot chain is
whatever the vendor shipped, untouched).

### Rockchip Linux tools staged for the card build (downloaded Nov 9/10)

From `github.com/vicharak-in/rockchip-linux-tools` into `/tmp/opencode/rktools/`:
`afptool` (packs `parameter` + image list into a firmware image; needs `FIRMWARE_VER`, `MACHINE_MODEL`,
`MACHINE_ID`, `MAGIC: 0x5041524B`, `TYPE: GPT`, `CMDLINE: mtdparts=...`; errors on overlap),
`rkImageMaker` (`<-RKXX> <loader.bin> <image> <out> [-os_type:RKOS|ANDROIDOS] [-storage:FLASH|EMMC|SD|SPINOR|SPINAND|SATA|PCIE]`,
plus `-unpack`), `upgrade_tool` v2.22 (`UF/UL/WL/RL/EF/EXF`, USB/rockusb only - no SD write),
`programmer_image_tool` v1.26 (`-t SLC|SPINAND|SPINOR|EMMC`, `-f UPDATE|PARAMETER|IMAGE` - it converts a
firmware into a programming image for those storages, **not SD**), `firmware_merger`,
`mkrawimg.sh`, `unpack.sh`, `sdcard-update-package-file`, `rk3399-package-file`, `rk3399-mkupdate.sh`.

Note what the package files imply: an SD upgrade card's own package is deliberately small -
`bootloader Image/MiniLoaderAll.bin`, `parameter Image/parameter-sdupdate.txt`, `uboot_a Image/uboot.img`,
`misc Image/sdupdate-ab-misc.img`, `recovery Image/recovery.img` - i.e. the card carries the boot code plus
a recovery, and the full firmware is a separate `update.img` on the card's visible partition. Rockchip's
own guide states an SD upgrade `update.img` must contain `MiniloaderAll.bin`, `parameter.txt`, `uboot.img`,
`trust.img`, `misc.img`, `resource.img`, `recovery.img` or the tool reports "write MBR failed".

### Why the card design for THIS unit is a boot card, not an upgrade card

The upgrade-card flow hands control to a **recovery** that flashes `update.img`. We do not have a working
recovery image for this board: the OEM packages contain no `recovery.img`, and the recovery partition's
content is unknowable because the dump above is bogus - and the owner reports no button combo reaches any
recovery menu. So the plan is the **boot card (flag 1)** variant: the card supplies a boot image that
u-boot loads from the SD slot, and that boot image is a rescue initramfs which mounts the card and `dd`s
the verified rollback images onto `/dev/block/by-name/super` and `/dev/block/by-name/boot`. Nothing
depends on recovery, on signatures, or on the panel working, and it is fully observable over the serial
console (`console=ttyFIQ0`, 115200 8N1, 3.3 V) before anything is written.

Still unverified before any burn (**and the reason the physical card has not been written**):
1. Which physical microSD slot maps to u-boot `mmc1` (`dwmmc@fe320000` = Android `sdcard1`) vs `mmc0`/`sdcard2`.
2. Whether BootROM on this PX6 will load the card's loader, or whether only u-boot's `rkimgtest` path is
   reachable (the latter still boots the card's boot image, since `rkimg_bootdev` sets `devnum 1`).
3. Whether this u-boot's IDB parser accepts an image built with `rkImageMaker -storage:SD` and the OEM
   `RKLoader.bin` (chip tag must match - the `BOOT` header carries it; not yet decoded).
4. The flag byte offset inside the IDB header for card type - the guide says "sector 64 + 616 bytes"; the
   built image must be inspected, not assumed.
