# Measured findings — evidence, not decisions

This file holds the measurement/evidence records that used to sit inside `docs/decisions.md`.
Decisions stay in `docs/decisions.md` (D1-D37); pointers here point back. Numbers are what the
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

### What the toolchain actually produced (Nov 10, test build in `/var/tmp/rescue-card/`)

A test `update.img` was built with the staged tools to see what the formats really are, using a compact SD
parameter (`TYPE: GPT`, `CMDLINE: mtdparts=rk29xxnand:...` with hex sector counts), `RKLoader.bin` as the
loader, and placeholder partition images:

* `afptool -pack ./ Image/firmware.img` worked: it parses the parameter, lays each listed image at its
  partition's `flash_address` (uboot at sector `0x2000`, trust `0x4000`, misc `0x6000`, boot `0x8000`,
  rescue `0x28000`), refuses overlap, and appends a CRC. `Image/firmware.img` = 41,510,916 B.
* `rkImageMaker -RK330C Image/MiniLoaderAll.bin Image/firmware.img update.img -os_type:androidos
  -storage:SD` (ver 2.23) worked and reports `storage is sd`; output 41,976,280 B. Its header magic at
  byte 0 is **`RKFW`** (the upgrade-package header), loader length 465,230 B, MD5 trailer.
  `rkImageMaker -unpack` re-exports `boot.bin` (the loader) + `firmware.img`, and `afptool -unpack` lists
  the images with their offsets - so the round trip is byte-faithful.
* **But the format u-boot looks for on the card is not `RKFW`.** The uboot strings say
  `Test if storage media have rockchip image`, `Boot Linux Image from rockchip image type`,
  `%s: Failed to read data from IDB`, `Found IDB in SDcard`, `** No boot file defined **`, and it prints
  `storagemedia=%s androidboot.storagemedia=%s` for the SD-boot case. Rockchip's SD-card flow puts an
  **IDB header at sector 64** (the guide's `0xFCDC8C3B` start flag, plus the card-type flag byte 616 bytes
  into that header), followed by the loader and the images the IDB describes - a layout produced by
  Rockchip's Windows `SDCardTool`/`SD_Firmware_Tool`, not by `rkImageMaker`, and `programmer_image_tool`
  only handles `SLC|SPINAND|SPINOR|EMMC`, not SD.

So the pieces we have are: a verified rollback payload (`super-a10.img` + `boot-a10.img`), a valid
`update.img` for those images (`RKFW`, storage=SD), the loader (`RKLoader.bin`, `BOOT` header magic), and
the OEM `uboot.img`/`trust.img`. What is still missing is the **IDB card layout itself** - which sector the
IDB starts on, its version/format, and where the boot-file pointer lives. Two ways to get it without
guessing: read it off a card that is known to work (the owner's PX5 unlock card, if it still exists), or
read it off the PX6's own eMMC once we have a shell (`dd if=/dev/block/mmcblk2 of=head.bin bs=512 count=256`
shows the same structure at sector 64 on a working boot device). Either one settles the format; writing a
card by hand before that is a guess, so no card has been written.

## Reconciling the outside diagnosis (Gemini, Nov 10) with our measurements

The owner asked an outside model for a diagnosis. Its four candidates are checked below against what we
measured offline on the payload we actually flashed (`out-hu/boot.img` sha `83fd2a15…`, `out-hu/super.img`)
and against the OEM Android 10 boot image (`boot-a10.img` sha `04a43ea9…`). Verdict per claim.

### Boot-image field order (a correction to my own reading)

Both images carry `ANDROID!` + header v2. Rockchip's images use the field order
`kernel_size, kernel_addr, ramdisk_size, ramdisk_addr, second_size, second_addr, tags_addr,
header_size, header_version` — **not** the AOSP order (`kernel_size, ramdisk_size, kernel_addr, …`).
My first parse of this evening read the AOSP order and printed nonsense (`hdr_size=284,164,096`,
`page_size=2`, `header_version=0x1c0001aa`); re-read with the correct order both images decode cleanly:

| field | ours (A14) | OEM A10-2025 |
|---|---|---|
| kernel_size | 30,455,816 | 25,671,688 |
| kernel_addr | `0x10008000` | `0x10008000` |
| ramdisk_size | 1,632,189 | 803,440 |
| ramdisk_addr | `0x11000000` | `0x11000000` |
| second_size | 544,768 | 924,672 |
| second_addr | `0x10f00000` | `0x10f00000` |
| tags_addr | `0x10000100` | `0x10000100` |
| header_size | 2,048 | 2,048 |
| header_version | 2 | 2 |

Load addresses and header version are identical, so u-boot's `boot_android` parses our image exactly the
way it parses the vendor's. Ramdisk payloads both decompress (`cpio newc`, `07070100`): ours 3,647,232 B,
OEM 1,870,336 B.

### Claim 1 "incompatible kernel & DTB" - **confirmed, and more specific than the claim**

* The kernel we flashed is **not the shipped kernel**. Strings in the kernel payload:
  ours `Linux version 4.19.193 (root@wuwqbook) … #24 SMP PREEMPT`, OEM `Linux version 4.19.111+
  (root@meng_book2) … #190 SMP PREEMPT Fri Jul 5 14:39:56 CST 2024`. Payload shas differ
  (`ec3b6631…` vs `59075004…`). So **D3** ("keep the shipped 4.19 kernel") is not satisfied by the payload
  that is on the unit now - it carries a different 4.19 build from someone else's machine.
* The DTB also differs: ours 157,962 B, OEM 152,425 B, both `compatible = "rockchip,rk3399-hct"` +
  `"rockchip,rk3399"` and both with the board name `Rockchip RK3399 HCT Board`, so the board identity is
  intact - but the vendor's **panel-timing table** was trimmed and edited. `diff` of the decompiled DTBs
  (`dtc`, 5,091-line diff) shows, inside `panel@0`:
  * removed LVDS timings `timing33/35/36/37/38` = `mtc,panel_index` **0x21, 0x23, 0x24, 0x25, 0x26**
    (all `lvds-format = <0x00>`) - the OEM table has LVDS indices 0x00..0x26, ours stops at 0x20;
  * added DSI-only timings 0x4f, 0x52, 0x53, 0x54 (twice), 0x55, 0x60, 0x62, 0x64, 0x77
    (`panel_hv_mode`, `dsi,flags = <0x803>`, `dsi,lanes = <0x04>`);
  * edited clocks: timing4 `0x3567e00 -> 0x3473bc0`, timing17 `0x5f5e100 -> 0x8d9ee20` plus its porch
    values and the removal of `dsi_clk_div4`, timing76 `0x43b5fc0 -> 0x3938700`, and one 0x400x258
    timing's `hfront-porch` 0x28 -> 0x3c.
  * The **active panel path is unchanged**: both DTBs set
    `panel_in_dsi = "/dsi@ff960000/panel@0/ports/port@0/endpoint"` and timing0 = 0x2349340 Hz
    (`lvds-format = <0x00>`), `edp_timing0` = 0x8d9ee20 Hz. So this is not an LVDS-to-DSI swap; it is a
    shortened panel-index lookup table plus retimed modes. If the HU's panel index is one of the removed
    LVDS indices, the driver finds no matching timing and nothing scans out while the MCU keeps the
    backlight lit - exactly the symptom the owner sees.
  * Both kernels contain the vendor panel properties (`mtc,panel_index`, `dsi_clk_div4`, `lvds-format`,
    `panel-init-sequence` all present as strings in both binaries), so the driver code is there; what
    changed is the data it reads.
* **The decisive new finding, which no outside model mentioned**: our vendor slice's GPU driver is built
  for the wrong kernel. `debugfs` extraction of `/lib/modules` from the vendor slice gives 17 modules;
  vermagic per module: `8188eu/8188fu/8189fs/8723bu/8733bs/8821cs/8821cu/8822bu/8822cs/aic8800_bsp/
  aic8800_fdrv/goodix/sd_user_hid/usb_f_iap/usb_f_iap2/virtual_tp` all `vermagic=4.19.193` - matching the
  kernel we flashed - but **`mali_kbase.ko` is `vermagic=4.4.167`** (1,045,008 B), and `modules.load` lists
  it.
  * **Corrected minutes later, same evening**: this mismatch is **not** the differentiator. The OEM's
    Android 10 vendor image (`ref-a10/vendor.img`) ships the *same* `mali_kbase.ko` with
    `vermagic=4.4.167` against its `4.19.111+` kernel, and both kernel Images contain Mali code built in
    (25 `mali_kbase` strings in each; `midgard` hits 43 in ours, 27 in the OEM's). So the unit that works
    today has an unloadable Mali module too - Mali comes from the kernel, not from the `.ko`. The module
    mismatch is cosmetic; it cannot explain the black screen. Note the OEM vendor's module list is
    completely different (`bcmdhd.ko`, `sprdwl_ng.ko` alongside the Realtek ones), which is the
    **D21** WiFi question, not a boot failure.
  * Ranking after that correction: the DTB panel-timing table (**the one measured difference between the
    working firmware and ours**) is the prime suspect; the kernel build difference is second; the
    composer/HIDL question is third and still unmeasured.
* Unresolved, and only measurable with the console: **which DTB u-boot actually feeds the kernel**. This
  u-boot has both paths - `Found DTB in %s part` / `rk-kernel.dtb` (the `dtb` partition, which we never
  wrote, per **D18**, and whose content we cannot read because the eMMC dump is empty) and the boot-image
  path (`%ssecond size`, `%sdtb size`, `%sdtb addr`). u-boot prints one of these lines over serial; that
  single line tells us whether our DTB ran or the vendor's.

### Claim 2 "AVB / vbmeta mismatch" - **ruled out** (already measured, and the claim contradicts the payload)

`ro.boot.verifiedbootstate=orange`, `ro.boot.vbmeta.device_state`/`avb_version`/`digest` empty, u-boot
carries `Not AVB images, AVB skip`, and our own cmdline says `androidboot.veritymode=disabled` where the
OEM's says `androidboot.veritymode=enforcing`. We never wrote `vbmeta` (part of the untouched chain,
**D18**). Nothing in this boot path verifies or halts on signatures, so a "missing patched vbmeta" cannot
cause the hang.

### Claim 3 "partition layout / dynamic-partition mismatch, EROFS vs EXT4" - **ruled out**, with one real oddity

`lpdump` on the flashed super (after `simg2img`, 3,263,168,512 B): metadata v10.0, max 65,536 B, used 668 B,
2 slots, device size **3,263,168,512** = the exact `super` partition size from the Nov 4 probe, group
`hct_dynamic_partitions` max **3,258,974,208** (same max the OEM Android 10 op_list declares), slices at
512-byte-sector offsets 2048 / 1980416 / 2822144 / 3715072 / 4466688 totalling 2,285,321,536 B - inside the
group, inside the device. Partition names `system, vendor, product, system_ext, odm`; our
`fstab.rk30board` lists all five as `ext4 ro,barrier=1 wait,logical,first_stage_mount`, plus
`/metadata`, `/cache`, `userdata` (f2fs). Filesystem type check: every slice opens in `debugfs` and
`ls /` returns real content (`system` has `acct/apex/bin/bootstrap-apex/bugrepo…`, `vendor` has
`build.prop`, `firmware`, `lib/modules`, `product` has `app/fonts/lib64`, `system_ext` has
`framework/lib`) - so they are ext4 and the fstab agrees; there is **no EROFS/EXT4 mismatch** (my first
magic check read offset 1080 instead of 1024 and was wrong; `debugfs` opening is the proof).
* Real oddity worth noting: `odm` is only **811,008 B** and contains just `/etc` (4,052 B). The OEM's odm
  was 539,951,104 B. Nothing fails to mount, but any OEM content the HCT apps expect under `/odm` is gone.

### Claim 4 "uboot/trust mismatch for Android 14" - **ruled out**

Our payload never wrote `uboot`, `trust`, `dtbo`, `dtb`, `vbmeta`, `misc`, `security`, the loader or the GPT
(**D18**/**D19**), so the boot chain is exactly what the vendor shipped. Android does not require a newer
u-boot: our boot image is header v2 with the same load addresses and page size as the OEM's, and AVB is
skipped. Gemini's premise "Android 14 builds expect an updated U-Boot/Trust stage" does not apply here.

### Claim 5 "SELinux / first-stage init hang" - plausible, not testable offline

Bring-up deliberately runs **permissive** SELinux (**D5**), so policy denials cannot block first stage, and
our first-stage ramdisk decompresses fine. Missing drivers, not policy, is the measured defect. This claim
needs the console to confirm or eliminate.

### What this changes for the next attempt

Per **D30**, nothing is flashed again before the console reading. The measured defect list, cheapest fix
first:
1. `mali_kbase.ko` vermagic mismatch (4.4.167 blob inside a 4.19.193 vendor image) - replace it with a
   module built for the kernel we ship, or stop needing Mali at all.
2. Our DTB's trimmed panel-index table (LVDS indices 0x21..0x26 missing) and retimed modes - restore the
   OEM table, or prove from the console which index the unit asks for.
3. Whether to ship the OEM kernel+DTB (`boot-a10.img`) and change only `super` - the conservative option,
   since kernel 4.19.111+, its modules and its DTB are a matched set. Open question for that option:
   whether Android 14 userspace tolerates the vendor 4.19.111+ kernel (not measured; do not assume).
4. The `odm` slice being nearly empty is worth checking against the OEM's `/odm` content.

## Payload provenance: our boot image is the vendor **Android 11** pair on an **Android 10** boot chain (Nov 10, measured)

The owner pointed out that XDA warns explicitly against upgrading Android 10 -> 11 this way. That is now
**measured, not a guess**. Byte comparison of the boot images (`sha256` over the kernel payload and the DTB
blob inside `second`):

| image | file size | kernel size | kernel sha (16) | second size | DTB size | DTB sha (16) |
|---|---|---|---|---|---|---|
| our A14 payload | 32,796,672 | 30,455,816 | `ec3b663149a1d1a5` | 544,768 | 157,962 | `530b84129eb0b140` |
| vendor **A11** package (`diatsia fw/update.zip`, 1.47 GB) | 32,004,096 | 30,455,816 | `ec3b663149a1d1a5` | 544,768 | 157,962 | `530b84129eb0b140` |
| vendor **A10** 2025 package (`update(1).zip`) | 27,406,336 | 25,671,688 | `590750047e47ce5f` | 924,672 | 152,425 | `cd4eeb3daeceb0e9` |

So our `boot.img` is the vendor Android 11 kernel **and** the vendor Android 11 DTB, byte-identical
(`ours == A11: True` for both kernel and DTB; `ours == A10: False`). The only part of our boot image that is
ours is the ramdisk (A14 first-stage init, 1,632,189 B vs the vendor's 838,018 B). The `Linux version
4.19.193 (root@wuwqbook) #24` string is the vendor's A11 build, not a foreign or hand-made kernel - so
**D3** ("keep the shipped kernel") was satisfied in the sense "vendor kernel", but it is the **Android 11**
generation kernel, while the firmware the unit was running before the flash was Android 10
(`QQ2A.200305.004.A1 eng.hct2.20220412.155213`, kernel `4.19.111+`).

### What the vendor's own A11 upgrade writes, and why mixing generations is wrong

`META-INF/com/google/android/updater-script` of the A11 package (`Target: rockchip/rk3399/rk3399:11/
RQ3A.210705.001/eng.hct2.20250401.153219:userdebug/release-keys`) writes, in order: dynamic partitions
(`system_ext` included - the A11 op_list has 5 partitions), then **`boot.img`, `trust.img`, `uboot.img`,
`logo.img`, `dtbo.img`**, plus `RKLoader.bin`. The A10 package's script does the same minus `logo.img`. The
boot-chain images differ between the two generations:

* `uboot.img`: A11 `2954bd15…` vs A10 `a28fd6a0…`
* `trust.img`: A11 `f95bd8f3…` vs A10 `7f2c4e52…`
* `dtbo.img`: A11 607 B `ec0ae97c…` vs A10-2025 803 B `28a07d49…` (both wrapped with a `d7b7ab1e` header,
  overlay DTB at offset 64)
* `logo.img`: only in the A11 package (385,024 B)

Decompiled with `dtc`, the two overlays are **not equivalent**:

* A10 overlay = 3 fragments: `target = <&chosen>` (`bootargs_ext = "androidboot.boot_devices=fe330000.sdhci"`),
  `target = <&firmware_android>` which adds `vbmeta` **and** `fstab` children with `status = "disabled"`,
  and `target = <&reboot_mode>`.
* A11 overlay = 2 fragments: `chosen` (same `bootargs_ext`) and `reboot_mode`. The `firmware_android`
  fragment that disables `vbmeta`/`fstab` is **gone**.
* The A11 overlay carries `__fixups__` (`chosen`, `reboot_mode`) while the A10 one carries plain references.

Neither base DTB contains `vbmeta`/`fstab` nodes of its own - they come only from the overlay. So the
Android-version-dependent behaviour (whether `firmware/android/fstab` and `firmware/android/vbmeta` exist and
whether they are disabled) is decided by **which generation `dtbo` is in the partition**, and we never write
`dtbo` (**D18**). The unit last installed Android 10 firmware, so its `dtbo`, `uboot`, `trust` are the A10
generation, while its kernel and base DTB are now the A11 generation. That is precisely the mixed state XDA
warns about: the vendor never mixes them, its own upgrade replaces the chain.

### Consequence for the next attempt (brick risk ranked)

* **Lowest-risk coherent option**: write `boot-a10.img` (vendor A10 kernel `4.19.111+` + vendor A10 DTB, a
  matched pair for the unit's A10-generation `uboot`/`trust`/`dtbo`) and keep our A14 `super`. Nothing else
  is written, so the boot chain stays untouched (**D18**) and the rollback path is unchanged. Open question
  that must be answered before choosing it: whether Android 14 userspace works on `4.19.111+` - string
  evidence is favourable (`bpf` 165 hits, `psi` 72, `cgroup2` present, `ringbuf` 52, `f2fs` 107, no `erofs`,
  ION/dmabuf present) but that is not proof; the console tells us whether init's bpf/cgroup setup survives.
* **Coherent-but-risky option**: install the A11 chain too (`uboot`, `trust`, `dtbo`, `logo`, loader) as the
  vendor's A11 script does, then A14 super. This is the state the vendor itself produces, but it writes the
  boot chain - the step that can brick an A10->A11 unit - and our rescue media is still unproven (the SD IDB
  layout is unknown). Not acceptable before the serial console and a verified rescue card exist.
* **Current state** (A11 kernel/DTB + A14 super on an A10 chain) is a mixed-generation boot, which is now the
  leading explanation for the black screen, ahead of the DTB table and the composer question.

## First-stage fstab: our payload had no fstab source at all (Nov 10, measured)

This is a defect in **our own payload**, not in the vendor's firmware, and by itself it explains a black
screen with no WiFi and no adb.

**What Android 14 init looks for.** Strings in our ramdisk's `init` (3,644,288 B, ARM aarch64 static):
`/first_stage_ramdisk/fstab.` , `/first_stage_ramdisk/system/etc/fstab.` , `/fstab.` ,
`/system/etc/fstab.` , `/odm/etc/fstab.` , `/vendor/etc/fstab.` , `/proc/device-tree/firmware/android/`,
`android,fstab`, `fstab/compatible`, `fstab/status`, `fstab_suffix`, `hardware`, plus the failure messages
`First stage mount skipped (missing/incompatible/empty fstab in device tree)`,
`failed to read default fstab for first stage mount`, `Cannot read default fstab`. The Android 10 init in
the OEM boot image only has `/fstab.` (no `first_stage_ramdisk` path) - Android 12+ moved the first-stage
fstab into that directory.

**Our ramdisk has no fstab anywhere.** Extracted tree (uncompressed 3,647,232 B): `init`, `dev`
(`console`, `null`, `urandom`), `debug_ramdisk`, `metadata`, `mnt`, `proc`, `second_stage_resources`,
`sys`, `system/etc/ramdisk/build.prop` - and no `first_stage_ramdisk/` directory, no `fstab*` file
(`find -name "*fstab*"` prints nothing).

**The DTB cannot supply one either.** Our DTB is the vendor A11 DTB (`530b8412…`) and has no
`firmware/android/fstab` node (`grep -c fstab ours.dts` = 0, likewise `oem.dts` = 0). The unit's untouched
`dtbo` partition holds the A10 overlay (803 B, `28a07d49…`), whose `firmware_android` fragment adds `vbmeta`
and `fstab` children with `status = "disabled"` - init logs `dt_fstab: Skip disabled entry` and reports the
device-tree fstab as missing/incompatible, then falls back to the file paths above, which do not exist. So
first-stage mount has **no** fstab source: `/system` is never mounted, second-stage init cannot read
`/system/etc/init/hw/init.rc`, nothing (SurfaceFlinger, WiFi, adbd) ever runs.

**The OEM A10 boot image is not a drop-in replacement.** Its ramdisk has `/fstab.rk30board` (Android 10
root path) with 12 entries, of which the logical ones are **`system`, `vendor`, `odm`, `product` - only 4,
no `system_ext`**. Android 14 requires `/system_ext`, so pairing OEM `boot-a10.img` as-is with our A14
`super` cannot mount `/system_ext`: the naive Path 1 is infeasible.

**Which filename init needs.** Our cmdline contains `androidboot.hardware=rk30board`, so the fallback file
must be `fstab.rk30board`. Our vendor slice `/etc/fstab.rk30board` has 5 logical ext4 first-stage entries
(`system/vendor/product/system_ext/odm`, all `wait,logical,first_stage_mount`) plus
`/dev/block/by-name/metadata` (`wait,formattable,first_stage_mount`), cache/boot/recovery/misc and
`userdata` (f2fs, keyed). init resolves logical partitions through `/dev/block/by-name` and
`/dev/block/bootdevice/by-name` and `androidboot.boot_devices` - measured cmdline key parity across our
image and both OEM images: `androidboot.baseband/console/hardware/selinux/verifiedbootstate/veritymode/
wificountrycode`; neither OEM cmdline passes `boot_devices`, it comes from the `dtbo` overlay's
`bootargs_ext = "androidboot.boot_devices=fe330000.sdhci"`.

### Boot-image layout measured (authoritative, via AOSP `unpack_bootimg`)

Header is **1660 B**, then sections **contiguous**: header -> kernel -> ramdisk -> second -> tail padding to
`pagesize` (2048). So the kernel payload starts at offset 1660, and `dtb_size`/`dtb_addr` sit at header
offsets 1648/1652 (`dtb_addr` is 64-bit, `0x11f00000`).

* OEM **A10** boot declares `dtb size: 0` and carries its DTB **inside `second`** (152,425 B at +5,900 of
  the `second` region).
* OEM **A11** boot declares `dtb size: 157,962` and carries a DTB both inside `second` (+4,031) and in the
  tail `dtb` section. Our payload mirrors A11 (`second` + tail, DTB `530b8412…` twice).
* Both vendor kernel payloads contain an **embedded initramfs** (`070701` newc magic inside the kernel
  region: A10 at 18,141,388, A11 at 22,715,372), and both boot ramdisks start with 2,428 zero bytes before
  the gzip stream - the OEM boot path tolerates that prefix, so the patched images keep it verbatim.

**Hash correction:** the kernel payload hashes recorded earlier tonight (`31dcf789…`, `a514a3ff…`) were
computed from a wrong header offset. Re-measured at offset 1660 over the kernel payload:
ours/A11 `ec3b663149a1d1a5` (30,455,816 B), OEM A10 `590750047e47ce5f` (25,671,688 B); the DTB hashes
(`530b8412…`, `cd4eeb3d…`) are unchanged because DTB extraction is offset-independent. The equality
conclusions of **D33** stand: ours == vendor A11 kernel and DTB, ours != vendor A10.

### Two candidate boot images built - neither flashed

In NAS `/var/tmp/a14repack/`:

| file | size | sha256 | shape |
|---|---|---|---|
| `a14-fixed.img` | 32,796,672 | `f378d4fd…` | our current payload + `/first_stage_ramdisk/fstab.rk30board` (added with `repack_bootimg --local --ramdisk_add vfstab.txt:first_stage_ramdisk/fstab.rk30board`, ramdisk 1,632,189 -> 1,631,944). Still the vendor **A11** kernel/DTB, so the generation mix stays. |
| `boot-a10k-a14rd.img` | 28,231,292 | `455a9ac8…` | generation-coherent: OEM **A10** kernel payload (`59075004…`) + OEM **A10** `second` 924,672 B (`ddc00a09…`, DTB inside = `cd4eeb3d…`) + our A14 ramdisk with the fstab (`146ac4e3…`) + our cmdline; header v2, `kernel_addr 0x10008000`, `ramdisk_addr 0x11000000`, `second_addr 0x10f00000`, `tags_addr 0x10000100`, `dtb_size 0` (like OEM A10), page 2048. |

Verified on the build host with `unpack_bootimg`: header fields as tabulated above, and the extracted
ramdisk contains `init` **and** `first_stage_ramdisk/fstab.rk30board`. Both images pair with our existing
A14 `super` (sha `2045af9c…`) and write **no** boot-chain partition (**D18**).

`mkbootimg --header_version 2` refuses `--dtb`-less builds ("DTB image must not be empty") and no longer
accepts `--os-version`/`--os-patch-level`, which is why the coherent image was assembled byte-wise from the
OEM A10 sections rather than with `mkbootimg`.

### Reproducing them

`scripts/rebuild_boot_with_fstab.sh` builds both images on the NAS build host
(`SRC_BOOT=<our boot.img> OEM_A10_BOOT=<OEM A10 boot.img> FSTAB=<fstab.rk30board> OUT=<dir>`); it
repacks the fstab into our image, assembles the coherent image byte-wise, verifies both with
`unpack_bootimg` + a cpio extract, and prints shas. A clean rerun into a fresh directory produced the
same two images byte-for-byte (`f378d4fd…`, `455a9ac8…`). The fstab itself is 3,138 B, sha
`0682e0fc4b317c8a3dd65eb3f68ca8098eaf8bb4907a7da4860456f1a9d84109`. Both images and the fstab are archived
in `…/aospbuild-archive/vibe-fix/`. Step 2 reads the ramdisk from step 1's output, so the coherent image
inherits the fstab - running it against the unfixed image yields a coherent image *without* fstab (caught
on the first run).

## Bench power, owner-measured Nov 11

The unit's nameplate says **10 A** and the rear of the unit is **fused at 10 A**. The 1 A bench brick did
not power the unit on at all, and the 2.5 A brick recorded earlier is also below what the amplifier bank
needs at power-on (its capacitor charging is inrush, which trips a small current-limited supply). Practical
minimum for the bench: a **12 V / 10 A (120 W)** supply, an ATX PSU's +12 V rail (short green PS_ON to any
black to start; yellow = +12 V, black = GND; some PSUs need a small load on 5 V/3.3 V to start), or a car
battery with a charger. Inline fuse **10 A**, leads >= 1.5 mm^2, crimped terminals. A brief rail dip at
power-on is normal; it must recover to >= 12 V. Procedure lives in `docs/reanimation.md` §2.

## Connectors inside the case, owner observed Nov 11

Opened the unit: the **debug UART header is unpopulated** (plated through-holes, no header fitted), and
there is a connector on the PX6 board that looks like **HDMI**. The holes are still usable electrically, so
serial is reachable with press-fit Dupont/probe pins or a wire soldered to the pad ring.

What the DTB says about that connector (identical node set in our payload's DTB and the OEM's):

* `hdmi: hdmi@ff940000`, `compatible = "rockchip,rk3399-dw-hdmi"`, `status = "okay"`, `reg-io-width = 4`,
  clocks `iahb/isfr/vpll/grf/cec`; its port `hdmi_in` has `hdmi_in_vopb` **disabled** and `hdmi_in_vopl`
  enabled -> the HDMI output is wired to **VOP Lite** (`vop@ff8f0000`, status okay; `vop@ff900000` big is
  also okay). Node also carries `mtc,not_for_pcb_test = "2x"`.
* HDMI **input** hardware is present too: `tc358749x: tc358749x@0f` on `i2c@ff140000` (`compatible =
  "toshiba,tc358749"`, address 0x0f, `clocks = refclk`, `reset-gpios` from phandle 0x4d bank 0x0b),
  **`status = "disabled"`**, `mtc,for_board = "2x"`, `mtc,not_for_board = "21"`, endpoint `hdmiin_out0` ->
  remote-endpoint phandle 0x4e, `data-lanes = <1 2 3 4>`, `link-frequencies = <0x11b3dc40>`. A second
  variant `tc358749x_v3@0f` sits on `i2c@ff3d0000` (alias `hdmiin_out0_v3`).
* AV-in composite path is separate and enabled: `adv7181` under `isp_sensor` (`status = "okay"`,
  `i2c_add = <0x42>`, interfaces `cvbs_ntsc` / `cvbs_pal`) - CVBS, not HDMI.
* The primary display stays DSI: `dsi@ff960000` `status = "okay"`, `mtc,not_for_board = "11,22,24"`, panel
  endpoint `panel_in_dsi` (as measured before).
* MTC board-variant markers (`mtc,for_board`, `mtc,not_for_board`, `mtc,not_for_pcb_test`) select which
  nodes the OEM enables for which board revision, so a DT `status` alone does not tell you what the socket
  physically does. Settle it by experiment: plug a monitor (output test) or a source (input test), and meter
  the pins with nothing plugged (steady 5 V on one pin = bus power being supplied = source/output; TMDS
  pairs idling ~2.9-3.3 V also indicate an output; all near 0 V and no 5 V = sink/input).
* Both kernels carry the drivers for either path: strings `rockchip,rk3399-dw-hdmi` (1 hit), `tc358749`
  (2), `rockchip,rk3399-vop-big` / `rockchip,rk3399-vop-lit` (2 each), plus HDMI PHY compatibles for
  rk3228/rk3328/rk3288/rk3368 - so a monitor experiment needs no firmware change and writes nothing.

## Bootable SD firmware, owner-supplied Nov 11 (settles the SD layout question)

Owner supplied `bootableSD/bootable_sd_card_10_android_PX5.rar` and `...PX6.rar` (the Windows
`SD_Firmware_Tool.exe` + `Rockchip Create Upgrade Disk Tool v1.53.exe` bundle plus a factory firmware
container). The PX6 one is the relevant example: `update_10_android_zavod_PX6.img`, 2,477,425,112 B,
sha256 `7772a1da0e719cda0522084ad8728b24d4661fa4b5408edbeec48cf42d103e02`, dated 2020-10-12. Extracted
to ext4 at `/var/tmp/bootableSD-px6/` (tmpfs rejects large unrar writes with "Invalid ioctl").

It is an **RKFW `update.img` container**, not a raw card dump - the Windows tool unpacks it and lays it
out on the card. Its own config.ini documents the tool's knobs: `IDBLOCK_POS` ("default is 64"),
`USE_FW_LOADER=true`, `UPDATE_FW_MODE=TRUE`, `SDBOOT_MODE`; `sd_boot_config.config` is the factory
SD-boot switch (`loader_update=0`, `display_led=1`, `display_lcd=1`, `pcba_test=0`, `fw_update=0`).

`afptool -unpack` refuses both containers ("check crc failed"), so the partition table was read directly
from the RKAF parameter block inside the container (magic `RKAF`, chip string `RK3399`, 80-byte item
records: partition name at +48, filename at +80, and the numeric fields in the 20 bytes before the next
name). Decoding gives this partition map, in whole-disk 512-byte sectors:

| partition | start | size (sectors) | image bytes |
|---|---|---|---|
| bootloader (MiniLoaderAll) | - | - | loader stored as a `BOOT` blob at container offset 102 |
| parameter | - | - | RKAF block at 387,506 |
| trust | 24576 | 8192 | 4,194,304 |
| uboot | 16384 | 8192 | 4,194,304 |
| misc | 32768 | 8192 | - |
| boot | 59392 | 65536 | 27,133,952 |
| dtbo | 49152 | 8192 | 803 |
| vbmeta | 57344 | 8192 | 4,096 |
| recovery | 124928 | 196608 | 38,848,512 |
| super | 1379328 | 6373376 | 2,402,202,560 |
| backup | RESERVED | - | - |

**Every start sector matches the unit's own measured eMMC map** (uboot 16384, trust 24576, misc 32768,
dtb 40960, dtbo 49152, vbmeta 57344, boot 59392..124927, recovery 124928, super 1378328...). Only
`super` differs slightly (factory 1,379,328 vs unit 1,378,328 - a 1000-sector factory build offset, not a
layout change). So the SD card is a **sector-for-sector mirror of the eMMC layout**, which is exactly the
design recorded in `docs/reanimation.md` §4.

Byte-level comparison of the factory PX6 payload against our staged OEM Android 10 files:

* `trust.img` - **byte-identical** to `/tmp/opencode/rkrescue/trust.img` (`7f2c4e52...`, 4 MB).
* `dtbo.img` - **byte-identical** (`28a07d49...`, 803 B, present twice in the container).
* `uboot.img` - 4,194,092 of 4,194,304 bytes identical; the differences are the RSA signature block at
  0x18..0x43 plus build-date strings ("Aug 3 2020" vs "Jun 2 2020") and a version string ("3/3" vs "2/2").
  Functionally the same u-boot; both carry `boot_targets=mmc1 mmc0 usb0 pxe dhcp`, `mmc1`, `sdcard` and
  `baseparameter` strings.
* Vendor u-boot boot logic (strings): `bootcmd_mmc1=setenv devnum 1; run mmc_boot`,
  `Could not find baseparameter partition`, `alloc_read_gpt_entries`, `Backup GPT repair fail!` -> the SD
  slot is `mmc1` and is tried **first**, and partitions are located through a **GPT on the card**. So the
  card needs a GPT with the Rockchip partition names, not just raw dd.

Real boot headers found inside the container (validated header fields, page 2048): a plain boot.img at
0x8cc9b4 (kernel 25,421,832, ramdisk 803,440, second 903,168) and a **recovery.img at 0x22af9b4 with a
12,515,795-byte ramdisk** - the factory's SD-flash rescue environment. The container's payload area is
sequential with page padding, so the factory's own boot kernel (25,421,832 B) differs from the OTA A10
boot kernel (25,671,688 B); our staged `boot-a10.img` (27,406,336 B, sha `04a43ea9...`) is the OTA one and
stays the rescue boot image because it is already proven coherent with `super-a10.img`.

DTB note: the OEM A10 boot image's "second" stage starts with ASCII `RSCE` (Rockchip second-stage wrapper)
and contains a raw DTB at +2048, totalsize 152,425 B, sha `cd4eeb3daece...`, `compatible =
"rockchip,rk3399-hct", "rockchip,rk3399"` - the same DTB already recorded in findings. That DTB is what the
card's `dtb` partition (sector 40960) gets.

## Card writer measured on the laptop Nov 11 (block size matters)

The first burn attempt aborted, and the measurements explain why:

* `bs=512` writes on this reader run at ~270 KB/s (the card queue is `max_sectors_kb=1024`,
  `nr_requests=2`), so `super` (6.37 M tiny writes) would take ~3 hours. `bs=4096` is used instead: every
  partition start is a multiple of 8 sectors, so its byte offset is a multiple of 4096 and the placement is
  byte-identical (`boot` still lands on sector 59392, `super` on 1378328). Only `dtbo` (803 B) and
  `dtb.dtb` (152,425 B) get a rounded-up tail inside their own 4 MB partitions, which is harmless.
* Wiping only the first 8 MiB destroys the main GPT but leaves the **backup** GPT alive, and sgdisk then
  reports "invalid main GPT header, but valid backup / Invalid partition data!" and exits non-zero, so the
  script stopped before writing any payload. The wipe now zeroes the first and last 8 MiB and runs
  `sgdisk --zap-all` before creating a fresh table, and the partition list is verified with `fdisk -l`
  (expecting 15 partitions) before anything is written.
* Vendor u-boot strings confirm the SD path and the safety rails: `Found IDB in SDcard` (ID block loader is
  read from the card) and `Forbid to flash mmc 1(sdcard)` (u-boot refuses to write the SD slot through
  fastboot, so a card in the slot cannot be overwritten by a stray flash command). Partition-name strings
  present in the binary: `baseparameter`, `dtbo`, `security`, `userdata`, `vbmeta`, plus
  `android_image_load_by_partname` / `part_get_info_efi` / `part_get_info_rkparm` and
  `rkimg_bootdev=if mmc dev 1 && rkimgtest mmc 1; ...` -> the SD slot (mmc1) is tested first and partitions
  are resolved either by EFI name or by the Rockchip parameter block.

## Verification must drop the page cache (Nov 11, caught during the first real burn)

The card writer's read-back check initially proved nothing: after `dd` writes 3.26 GB of `super`, a `dd`
read of the same device offsets is satisfied from the write's own cached pages. Measured on the laptop: the
device write counter (`/sys/block/sda/stat` field 6) had only ~817 MiB reached the media while the script was
already reporting pieces "ok", and device reads were ~8.5 MiB - i.e. the verification was reading cache, not
the card. The script now runs `sync; echo 3 > /proc/sys/vm/drop_caches` before the verification loop and uses
`conv=fsync` on each write, so every sha comparison is read from media.

## Rescue SD card built and verified on media, Nov 11

Built on the laptop (`/dev/sda`, 7580 MiB, RM=1, vendor "Generic- SD/MMC", usb, 15,523,840 sectors) with
`scripts/write_rescue_sd.sh`, detached as systemd unit `sdburn`. `fdisk -l` lists all 15 partitions with the
unit's offsets (uboot 16384, trust 24576, misc 32768, dtb 40960, dtbo 49152, vbmeta 57344, boot 59392,
recovery 124928, backup 321536, security 550912, cache 559104, metadata 1345536, frp 1378304,
super 1378328..7752703, userdata 7752704..15523806).

Cold verification (`sync; echo 3 > /proc/sys/vm/drop_caches`, then `dd bs=4096` with `skip = sector/8` and
truncated to the file's exact byte length) - every piece matches its payload sha on the card:
idbloader.bin `a6e6502d` @64, uboot.img `a28fd6a0` @16384, trust.img `7f2c4e52` @24576, dtb.dtb
`cd4eeb3d` @40960, dtbo.img `28a07d49` @49152, vbmeta.img `ad7facb2` @57344, boot-a10.img `04a43ea9` @59392,
super-a10.img `30da961c` @1378328.

Correction to the paragraph above about the device counters: `/sys/block/sda/stat` fields are
"reads completed, reads merged, sectors read, ms reading, writes completed, writes merged, **sectors
written**, ms writing, ...". Field 6 is writes *merged*, not sectors; sectors written is field 7, which was
24,204,752 sectors (12.4 GB) across all runs. The card was never under-written - the apparent "817 MiB"
reading was this field mix-up, not a missing write.

## SD boot works, but only after a deep power cycle - Nov 11 (owner measured)

The Malysk factory card (`update_10_android_zavod_PX6.img`, burned with `SD_Firmware_Tool.exe` on Windows)
boots the PX6 in the **GPS-slot SD reader**, but the first power-on looked like a failure: "lights on, screen
totally black, no backlight". It only came up after a **deep power cycle** (supply disconnected long enough
for the PMIC / amplifier capacitor bank to bleed down). A quick re-power does not restart BootROM cleanly on
this unit. So on the bench: power off, wait tens of seconds, then power on - and do not conclude the card is
bad from the first attempt.

Two layout facts from the same experiment:

* Windows showed ~10 "unformatted" partitions on **our** GPT card, and saw **nothing** on the card the
  Windows tool wrote. So the tool does not write an EFI/GPT table that Windows can parse; vendor u-boot
  resolves partitions through the Rockchip **parameter** block (`part_get_info_rkparm` is in the u-boot
  binary next to `part_get_info_efi`). Our card-local GPT approach (D37) is therefore not what BootROM +
  miniloader expect - the parameter-based layout is authoritative. The next step is to read the tool-written
  card directly (first sectors + the RKAF parameter block) and mirror it exactly.
* The unit boots from the SD slot that Windows sees as the card-reader path, which confirms the SD slot
  (`sdhci@fe330000`, the controller named by `androidboot.boot_devices` in the dtbo overlay) is a real boot
  path on this board.

## What the tool-written card actually contains - Nov 11 (dumped, sha `1225bccd`, 7,948,206,080 B)

Parsed with `scripts/parse_sd_layout.py`. Earlier conclusions were partly my own parser bugs (GPT entry
fields are type@0 uuid@16 first@32 last@40 attrs@48 name@56; a binary DTB stores property values as raw
NUL-separated strings, not quoted DTS; the FDT magic is `d00dfeed`, not the legacy `d0020700`).

* The card DOES have a real GPT (main @LBA1 + backup @last LBA, 128 entries of 128 B) with the unit's own
  offsets: uboot 16384, trust 24576, misc 32768, dtb 40960, dtbo 49152, vbmeta 57344, boot 59392,
  recovery 124928, backup 321536, security 550912, cache 559104, metadata 1345536, frp 1378304,
  userdata 7752704. Windows saw "nothing" because the MBR carries a genuine NTFS record (type 0x07,
  start 329728, size 15,192,064 sectors) - an MBR disk with a real partition masks the GPT from Windows.
  Our card had no MBR record, so Windows parsed our GPT and showed ~10 unformatted partitions.
* Main and backup GPT DISAGREE: main lists `frp` 1378304..1379327 and `super` 1379328..7752703, backup lists
  frp 1378304..1378327 and super 1378328..7752703. The main table matches the factory parameter block
  (super @1379328); the backup matches the eMMC map we measured. u-boot reads the main table.
* `super` on the card is erased (0xFF at both 1378328 and 1379328), and the container is stored as a FILE
  inside that NTFS region - the stray `RKAF` hits at sectors 350004 / 614403 / 630689 are the container's
  own parameter chunks (`RKAF` + "RK3399" + package-file/bootloader/parameter/trust/uboot/misc/boot...).
  So the card is a flasher card, not a full-system boot card.
* Partition images sit verbatim at their GPT LBAs: boot @59392 begins with `ANDROID!`. The card's boot
  partition's first 27,131,904 B hash `59310ba4...` = the container's `boot-factory.img` byte-for-byte.
  My earlier "every piece DIFFERS from our payload" was padding past the image length, not a content diff.
* The card's chain images DIFFER from the container's own chain images (card uboot `e287939a` vs container
  `8407e60d`, card trust `5699a86b` vs staged OEM `7f2c4e52`): the tool writes an SD-boot-specific chain on
  the card and puts the container's chain into the eMMC. Nothing at sector 64 carries a `BOOT` loader magic
  in the first 8 MB (only `RSAK` at bytes 151560 / 231712 / 260352); `SDBoot.bin` in the tool bundle starts
  with `BOOT` (`42 4f 4f 54`) and is 152,366 B, rk32xx_loader and our A10 RKLoader.bin also start with BOOT.
* Card misc partition holds the AOSP recovery trigger: `boot-recovery`, `recovery`, `--wipe_all`. Card
  security partition holds HCT lock-state records (`A54E481B8B69424182B83ACF16E99E2A/.01000000/lock_state`).
* Boot image header fields in these Rockchip images are BYTE counts, not 512-byte page counts: boot
  kernel 25,421,832 B, ramdisk 803,440 B, second 925,696 B; recovery's +16 field = 12,515,795 B, which is
  exactly the container's recovery ramdisk size we measured earlier. Kernel loads at 0x10008000, ramdisk at
  0x11000000, console `console=ttyFIQ0`, cmdline `androidboot.baseband=N/A androidboot.wificountrycode=US`.

## The flashed firmware is an HCT board firmware, but NOT the unit's own DTB - Nov 11

`scripts/find_dtb.py` on the container's boot image: the factory firmware's embedded DTB is
`rockchip,rk3399-hct` + `rockchip,rk3399`, totalsize 130,833 B, sha `9ffc8492` - it IS an HCT firmware.
But the unit's own OEM DTB (from `diatsia fw` boot second stage, +2048) is 152,425 B, sha `cd4eeb3d`,
model "Rockchip RK3399 HCT  Board". Diffing the two with dtc (148 vs 154 nodes):

* only in the OEM DTB: `display-timings-dsi`, `mtc-radio_v0`, `mtc-radio_v1`, `mtc-radio_v2`, `opp-1512000000`
* only in the factory DTB: `back-key`, `camera-key`, `home-key`, `menu-key`, `vol-up-key`, `vol-down-key`,
  and five extra opp-frequency nodes

So the factory firmware has the physical buttons the OEM DTB lacks, and lacks the DSI display timings and
the mtc-radio nodes the OEM DTB has. That is a credible cause for "booting but screen totally dark", and it
means the OEM boot image (which carries the unit's own DTB in its second stage) is the targeted fix - not a
boot-chain rewrite: `boot` is where the board DTB lives.

The OEM packages cannot be burned by SD_Firmware_Tool: `diatsia fw/update(1).zip` and `update.zip` are
recovery-style update packages (META-INF updater-script, dynamic_partitions_op_list, *.new.dat.br, plus
RKLoader.bin/boot.img/dtbo.img), not RKFW `update.img` containers.

## Recovery IS reachable via an SD-boot card, and the OEM package restores the unit's own chain - Nov 11

The owner built a bootSD that lands in a real recovery environment (contradicts the earlier assumption that
the recovery menu is unreachable, D29/D25: the recovery *image* is reachable by SD boot even though the
on-unit menu never appears). Reading `diatsia fw/update(1).zip` before flashing it:

* It is an A10 OEM OTA package: `post-build=rockchip/rk3399/rk3399:10/QQ2A.200305.004.A1/eng.hct2.20250401.152740:userdebug/release-keys`,
  `pre-device=rk3399`, `ota-type=BLOCK`, signed by SignApk (OEM key).
* updater-script patches the logical partitions product/vendor/system/odm, then writes
  `boot.img`, `trust.img`, `uboot.img`, `dtbo.img` to `/dev/block/by-name/*` and calls
  `write_raw_loader_image()` on `RKLoader.bin`. So the package rewrites the boot chain as well as boot -
  these are the unit's own OEM bytes, verified below, so it is an OEM restore, not one of our builds.
* `dynamic_partitions_op_list` starts with `remove_all_groups`, then re-creates the A10 group with
  `resize product/vendor/system/odm ... from 0` and group max 3,258,974,208 B. That wipes our Android 14
  `super` (including system_ext) - intended as the rollback; the A14 payload goes back afterwards.
* Every image in the package matches our staged OEM copies byte-for-byte: trust `7f2c4e52` (4,194,304 B),
  uboot `a28fd6a0` (4,194,304 B), boot `04a43ea9` (27,406,336 B), dtbo `28a07d49` (803 B),
  RKLoader `847ebf39` (465,230 B) - the same A10 loader used for bench writes.
* The package's boot.img carries the unit's own board DTB: totalsize 152,425 B, sha `cd4eeb3d`,
  model "Rockchip RK3399 HCT  Board", compatible `rockchip,rk3399-hct`, `rockchip,rk3399`. So flashing it
  replaces the factory firmware's variant DTB (`9ffc8492`, missing `display-timings-dsi`/`mtc-radio`) with
  the unit's own - the credible fix for the dark screen (D38).
* Our Android 14 boot images also carry an HCT DTB: `boot-a10k-a14rd.img` uses the OEM DTB `cd4eeb3d`
  (152,425 B), `a14-fixed.img` and `a11-boot.img` use `530b8412` (157,962 B, our edited copy). So the A14
  re-application does not need a DTB write either - `boot` carries it.

## Unbrick succeeded - the unit boots its own OEM Android 10, screen alive - Nov 11 (owner measured)

Route: a bootSD built by the owner reaches a real recovery environment; `diatsia fw/update(1).zip` passed
key verification (OEM SignApk accepted) and patched product/vendor/system/odm unconditionally, then wrote
boot/trust/uboot/dtbo and the raw loader. Result: the unit gets past the bootloader and the boot animation
and lands on the **setup screen** - display working, so the dark screen was indeed the factory firmware's DTB
variant (missing `display-timings-dsi` and `mtc-radio_v0/1/2`) and the OEM boot image (`04a43ea9`, carrying
the unit's own DTB `cd4eeb3d`) fixed it. D38 confirmed, D39 route confirmed.

Network state right after that boot: a live host at 192.168.1.126 (port 5555 refused, so not adb yet),
192.168.1.120 no longer responding, no adb device on either machine. TCP adb opens only after `adbon` is
typed in the factory settings dialog (D28).

## Stock Android 10 baseline: every owner criterion is satisfied on the shipped firmware - Nov 11 (adb over TCP)

`adbon` typed in the factory settings dialog opened TCP adb (`adb connect 192.168.1.120:5555`, `adb root`
accepted, `uid=0`). Build `rockchip/rk3399/rk3399:10/QQ2A.200305.004.A1/eng.hct2.20250401.152740:userdebug/release-keys`,
kernel `Linux version 4.19.111+ ... #190 ... Fri Jul 5 2024` = the OEM A10 kernel. eMMC is `mmcblk2`;
`super` is 3,263,168,512 B, matching our measured map (boot p7, trust p2, uboot p1, dtb p4, dtbo p5,
vbmeta p6, misc p3, security p10, metadata p12, frp p13, super p14, userdata p15, backup p9, cache p11).

Measured hardware state on this stock firmware (all read-only probes):

* **WiFi** works: `wlan0` state UP with `inet 192.168.1.120/24`, `persist.sys.wifi.type=RTL8188EU`,
  `vendor.wifi_hal_legacy` and `wificond` both running, MAC `44:ef:bf:37:a3:e0`.
* **Screen** works: boot animation then setup screen (owner observed); `dumpsys input` shows live windows on
  displayId=0 plus a second displayId=2 surface.
* **Touch** works: `/dev/input/event0..event2` present, eventhub records `deviceId=3 source=0x00001002`
  (touchscreen) with real MOVE and UP MotionEvents.
* **Buttons** work: KeyEvents recorded for keyCode 4 (BACK) and 3 (HOME).
* **CANBUS / MCU** work: `/dev/mtc-car`, `/dev/mtc-av`, `/dev/mtc-cvbs`, `/dev/mtc-cvbs2`, `/dev/mtc-dab`,
  plus `ttyS0/ttyS1/ttyS4`; `persist.product.mcuversion=MTCE_HXD_V3.56_1`, `hct.hub.sta=1`,
  `hct.data.copy=1`, `init.svc.hctprecopy` ran, `vendor.weaver-hal-1-0` running.
* **Sound input** works: `/proc/asound/devices` lists a digital audio *capture* node (card 0 has playback and
  capture; card 1 playback), so the audio input path exists on the shipped firmware.

So the brick was purely software: our Android 14 payload's missing first-stage fstab (D34) plus the wrong DTB
(D38). The hardware, kernel and vendor HALs are all fine on the OEM A10 build.

Backup note (D40): `scripts/pull_stock_backup.sh` pulls disk head (8 MB), backup GPT tail, and uboot/trust/
misc/dtb/dtbo/vbmeta/boot/recovery/security/metadata/frp/super with a sha256 manifest, and refuses to run if
adb is not root or the build is not stock A10. It reads partitions while Android is running, so `super` is a
live-mounted snapshot - good enough as a rollback, and the recovery route can take a second copy later.

## Stock backup verified on the NAS; dtb partition empty; module vermagics measured - Nov 11

`scripts/pull_stock_backup.sh` pulled 3.3 GB / 14 files and the manifest now uses relative paths so it
verifies anywhere (`cd "$OUT" && sha256sum ./*.bin`). Verified on the workstation and again on the NAS copy
at `/srv/50911774-.../aospbuild-archive/hu-stock-backup/`: all 14 `OK`.

* Chain partitions match the staged OEM images exactly: `uboot.bin a28fd6a0`, `trust.bin 7f2c4e52`; image
  prefixes inside the padded partition slices are `boot.bin 04a43ea9` (SAME), `dtbo.bin 28a07d49` (SAME).
* `dtb.bin` is entirely zero - 0 non-zero bytes, no FDT magic anywhere in the 4 MiB partition. The board DTB
  is only ever read from `boot`'s second stage, which confirms D38.
* `vbmeta.bin` is an `AVB0` v1 structure but its digest does not match our staged `vbmeta.img`
  (`d2e19797` vs `ad7facb2`). It does not gate boot: `ro.boot.avb_version=` empty,
  `ro.boot.verifiedbootstate=orange`, so AVB is not enforcing on this unit.
* `misc.bin` still contains `boot-recovery` / `recovery` / `--wipe_all` even though the unit booted fine to
  the setup screen - vendor u-boot does not act on it here. Worth zeroing at the next write for cleanliness.
* Module vermagics: stock OEM A10 vendor (from `super.bin`) = **18 x `4.19.111`**, 2 x `4.4.167`
  (`mali_kbase`), 2 x `4.19.101`. Our A14 vendor slice = **16 x `4.19.193`** + 1 x `4.4.167`. So the OEM
  modules are built for the shipped kernel, and our modules are built for the A11 kernel we flashed. This is
  the one new risk in the second attempt if the A10 kernel boot image is chosen.

## Kernel/module story confirmed: prebuilt vendor kernel, no legacy-kernel patch tree - Nov 11

Checked what the build actually uses, because "are we on a legacy-kernel LineageOS branch?" needs a real
answer. Measured:

* Build tree on the NAS: `/srv/dev-disk-by-label-SSData/aospbuild/lineage21s` - a LineageOS 21 tree. It has
  our device tree `device/rockchip/rk3399` (AndroidProducts.mk, lineage_rk3399.mk, hu_apps.mk,
  fstab.rk30board, prebuilt, hu_system). `kernel/` holds only `configs`, `prebuilts`, `tests` - no kernel
  source, and no legacy-kernel patch directory anywhere in the tree. `.repo/manifest.xml` has no realtek or
  kernel project entry.
* `device/rk3399-px6-hct4/BoardConfig.mk:65`: `TARGET_PREBUILT_KERNEL := vendor/hct4/prebuilt/kernel_a11`
  - the vendor **A11** kernel binary (`4.19.193 #24`). We ship a binary kernel, we never build one (D3), so
  there is nothing to patch and no legacy-kernel branch involved. Android 14's minimum kernel is 4.14, so a
  vendor 4.19 kernel is in range without extra patches; the requirement is instead that userspace, HALs and
  `.ko` files match the kernel we ship.
* WiFi split (D21): the HAL glue is ours (`device/rk3399-px6-hct4/wifi_hal`, `libwifi-hal-rtk`,
  `BOARD_WLAN_DEVICE := realtek`, `WIFI_DRIVER_MODULE_NAME := "8188eu"`,
  `WIFI_DRIVER_MODULE_PATH := "/vendor/lib/modules/8188eu.ko"`). The **kernel driver** is not in our tree -
  the `.ko` files are vendor binaries. Our A14 vendor slice carries 16 modules at `vermagic=4.19.193` +
  `mali_kbase.ko` `4.4.167`, which match `kernel_a11`; that is why attempt 1's modules were coherent and why
  only switching to the A10 kernel image creates a mismatch.
* The community org the owner pointed at exists but does not fit this device:
  `github.com/lineageos-on-rockchip` targets the RK3326 LeapPad Academy (UYT4) on **LineageOS 18.1**
  (Android 11), kernel 4.19.193, branches named `lineage-18.1`. Its repos are
  `android_device_rockchip_rk3326-common`, `android_device_vtech_uyt4`, `android_device_vtech_uyt4-kernel`
  (prebuilts), `android_kernel_rockchip_rk3326`, `android_hardware_rockchip`, `u-boot`,
  `twrp_device_vtech_uyt4`. There is **no RK3399 device tree** there, and its profile README states the repos
  are experimental and that "how to build" inquiries are reported and ignored. Useful analogy only: it shows
  the same shape we use (device tree + kernel prebuilts repo + vendor dump), not a tree we can build from.
* Module payload for the A10-kernel variant is now staged: `adb pull /vendor/lib/modules` gave 21 `.ko`
  (111,163,391 B) into `/var/tmp/hu-stock-backup/vendor-modules/modules/`. Vermagics: most `4.19.111`
  (`8188eu`, `8188fu`, `8189fs`, `8723bu`, `8733bs`, `8821cs`, `8821cu`, `8822bu`, `8822cs`, `aic8800_*`,
  `goodix`, `sd_user_hid`, `usb_f_iap`, `usb_f_iap2`, `virtual_tp`), `sprdwl_ng`/`bcmdhd` at `4.19.101`,
  `mali_kbase` at `4.4.167`. Dropping these into our A14 vendor partition makes `boot-a10k-a14rd.img`
  (kernel `4.19.111+`) coherent without building anything.
* Rebuilding a driver is possible if we ever need it: the running unit exposes `/proc/config.gz` (34,030 B),
  so the exact config of the shipped `4.19.111+ #190` kernel is available for out-of-tree builds.

## Recovery trust, dual certs, and why the write must not happen while super is mounted - Nov 11

Attempt 2 ended with a black screen: the installer wrote `super` while stock Android 10 had its logical
partitions mounted, so the framework collapsed before anything rebooted. Not a boot-chain brick - the
chain (uboot/trust/dtb/dtbo/vbmeta/security/misc) was never touched - and the bootSD rollback restored
stock Android 10 (adb came back, `/data` came back empty: 1.4 GiB used of 54 GiB).

Measured consequences and decisions:

* The rollback zip's `boot.img` is 27,406,336 B, so the first 27,406,336 B of the boot partition were
  rewritten and everything above stayed leftovers of our previous Android 14 image (partition prefix
  readback `1f48dc302392`, stock dump prefix `e7150f7cd3d9`, full stock dump `3d2741f04f31` / 33,554,432 B).
  Writing our full 32,796,672 B image overwrites all of that; the trailing 757,760 B of the partition are
  unread padding (u-boot sizes the read from the boot header).
* Recovery cannot be the installer. Its `format()` calls `make_f2fs` from `/vendor/bin`, and our vendor
  slice has no mkfs binaries, so once super holds Android 14 recovery cannot format `/data`.
* The cert store cannot be patched on live stock either: stock mounts `/` (system-as-root) and `/vendor`
  through device-mapper (`/dev/block/dm-2`, `dm-1`, `dm-0`, `dm-3`, read-only, seclabel), so
  `/system/etc/security/otacerts.zip` is not writable from the running ROM.
* The dual-cert store lives in OUR system slice instead - recovery reads its cert store from the mounted
  system partition, so once Android 14 is installed recovery trusts both keys. Extracted from the stock
  system extent in `hu-stock-backup/super.bin` (extent offset block 2560720): HCT's cert der-sha
  `cf2ab3818595c4ed...`, our AOSP testkey der-sha `a40da80a59d170ca...`. `/var/tmp/otac-dual.zip`
  (3,345 B, entries `hct.x509.pem` + `testkey.x509.pem`) is written into `system-slice.img` at
  `/etc/security/otacerts.zip` and re-injected into `raw-super.img` at the system extent (block 2048).
  Verified by extracting the system extent back out of the super: both entries present.
  New payload shas: super `58991d74432e...` (3,263,168,512 B), boot unchanged `933e2ecc4237...`.
  Original stock cert store kept as `hu-stock-backup/otacerts-original.zip` (1,049 B).
* The install is therefore ONE detached shot from stock Android (where stock's own `make_f2fs` exists):
  write boot+super, verify readback, `stop`, unmount `/data`, format fresh plain f2fs, reboot. It must run
  under `setsid` because `stop` stops class main, which contains adbd, so the adb session dies mid-script
  and an adb-child shell would be killed before the reboot.

## Late Nov 11 - recovery route, make_f2fs.oem, signing format, and the shell/disk stall

Measured after the stock restore (adb came back, `/data` came back wiped: 1.4 GiB used of 54 GiB, boot
partition prefix `1f48dc302392` because the rollback's `boot.img` is only 27,406,336 B and left our
earlier image's tail in the partition):

* Payload re-staged on the workstation: `boot-a14.img` `933e2ecc42375a...` (32,796,672 B) and
  `super-a14.img` `d4b4990931cc...` (3,263,168,512 B). Both pushed to `/data/local/tmp/a14/` and
  sha-verified on the unit (`933e2ecc...`, `58991d74...` - the super was pushed twice, the second push
  failed because the unit went offline with the battery low, so `d4b4990931cc` still needs pushing).
* `raw-super.img` carries, in order: patched fstab, `hu-adb.rc`, dual-cert `otacerts.zip`, and the
  stock mkfs binaries as `/system/bin/make_f2fs.oem` (49,544 B) + `/system/bin/fsck.f2fs.oem`
  (153,872 B). Verified by extracting the system extent (block 2048) back out of the super:
  `make_f2fs.oem` is byte-identical to the stock binary, and `otacerts.zip` lists both pem entries.
  Our slice's own `/system/bin/make_f2fs` is Android 14's build (201,496 B) - newer f2fs-tools can
  write features this 4.19 kernel cannot mount, which is why the stock binary is used for the wipe.
* `/bin` in these system-as-root images is a symlink, so debugfs writes must target `/system/bin/...`
  ("write: Ext2 inode is not a directory" otherwise).
* Recovery image measured properly: `recovery.bin` (33,554,432 B) is header v2 with kernel + a real
  ramdisk of 12,519,199 B + second 924,672 B, `dtb_size = 0`, cmdline `console=ttyFIQ0 ...
  androidboot.selinux=permissive`. Its ramdisk has NO `/res/keys`; `init.rc` does
  `symlink /system/bin /bin`, defines `service recovery /system/bin/recovery` and a disabled
  `service adbd /system/bin/adbd --root_seclabel=u:r:su:s0`, and starts adbd only via
  `on property:sys.usb.config=adb`. So recovery's binaries and its cert store both come from the
  mounted system partition - which is why the dual-cert store in OUR system slice is the right place,
  and why recovery would need our `make_f2fs.oem` rather than `/vendor/bin`.
* Signing format is legacy SignApk: the zip comment is
  `"signed by SignApk"` + NUL + PKCS#7 + `signature_start` (u16) + `0xff 0xff` + `total_size` (u16),
  measured from `diatsia fw/update(1).zip`: comment 1,573 B, `total_size` field 1,573, message
  `"signed by SignApk"` is **17** bytes (so the PKCS#7 starts at offset 18), PKCS#7 length 1,549 B,
  `signature_start` = 1,555 = pkcs7 length + 6. The PKCS#7 is **detached** (`d.data: <ABSENT>`),
  `md_algs = sha256`, signer cert der-sha `cf2ab3818595c4ed` (HCT's cert, present in stock
  `otacerts.zip`; its subject is the cloned `CN=Android` cert, serial `92A528C773D7A141`).
  `openssl asn1parse -i` on the extracted PKCS#7 (1,549 B) shows the SignerInfo has **no signed
  attributes** (version 1, no context-[0] node), digest `sha256`, `rsaEncryption`, and the signature is
  a **BIT STRING** at offset 822 (`hl=4 l=257`: one unused-bits byte + 256 value bytes). The 256-byte
  OCTET STRING at offset 1289 is inside the certificate (its public key), not a signature - that is why
  an earlier probe "extracted the signature" from an OCTET STRING and every candidate range then failed
  `openssl dgst -verify`. `scripts/find_zip_digest_scope.py` now collects BIT STRINGs as well and tries
  each 256-byte candidate against every byte range.
* `signapk.jar` fails on both JDKs (workstation OpenJDK 27 and the tree's prebuilt jdk17) with a
  conscrypt native-library error, and openssl `smime -sign` gives attached content plus
  `sha1WithRSAEncryption`, which is the wrong shape. So `scripts/sign_update_zip.py` assembles the
  PKCS#7 by hand in the measured shape (detached `pkcs7-data`, sha256, one cert, one SignerInfo with the
  cert's issuer-and-serial, `RSA(PKCS#1 v1.5 DigestInfo(sha256(<scope>)))`) and appends the comment the
  same way SignApk does.
* Which byte range recovery hashes is **not** reproducible offline, measured with
  `scripts/recover_zip_digest.py` (it RSA-publics the signature and strips PKCS#1 v1.5, so it recovers
  the digest the signer actually hashed rather than guessing ranges). Provenance is proven first: the
  certificate is self-signed and its own signature unpads to `sha256(tbs)` = `8e3715d963965e41...`,
  so the modulus (256 B, exponent 3) and the unpadding code are correct.
  * `diatsia fw/update(1).zip` (1,285,817,036 B, sha256 `31bb492ab6036dd1...`): recovered digest
    `e3e49511d33715d8b39393f44e65c59a9b0fdc2da61ef25e7fa70dc721fb9886`.
  * The NAS archive copy `update.zip` (1,203,718,969 B, sha256 `dd3e2ac0610bb64f...`) is a DIFFERENT
    file, and its recovered digest `b14a9e21f053c03f...` is different too.
  * Neither digest matches any of: whole file, minus EOCD(22), minus EOCD+comment, minus comment,
    content+EOCD(comment_len=0), content only, concatenated entry contents. Both copies are signed by
    the same cert (`cf2ab3818595c4ed`), so the packages were signed over bytes that these copies no
    longer are - consistent with both having been modified after signing (downloads/repacking), and
    consistent with recovery accepting them anyway.
  * Consequence: recovery's content digest cannot be settled from these files, so
    `scripts/sign_update_zip.py` takes `--scope` as a documented guess (default
    `content-plus-EOCD-clen0`, the commentless archive that SignApk hashes while streaming). That guess
    is safe, because recovery verifies a package BEFORE running its updater-script: a wrong scope means
    the install is refused with nothing written. The adb-root installer stays the primary route; the
    recovery zip stays the fallback.
  * `scripts/find_zip_digest_scope.py` was the earlier attempt and is kept as the negative result: it
    collected only OCTET STRINGs, so it grabbed the certificate's key instead of SignerInfo's signature
    and reported `Verification failure` for every range.
* Our hand-built PKCS#7 now parses the way the OEM's does. Measured Nov 12 on the smoke zip and on the
  shipped fallback zip, `openssl pkcs7 -print` gives `type: pkcs7-signedData`, `version: 1`,
  `md_algs: algorithm: sha256 (2.16.840.1.101.3.4.2.1)`, `contents: type: pkcs7-data` with
  `d.data: <ABSENT>` (detached), one certificate (der-sha `a40da80a59d170ca`), and a SignerInfo whose
  children match the OEM's node-for-node: `INTEGER 01`, the issuer Name SEQUENCE, the serial INTEGER, a
  sha256 AlgorithmIdentifier, an rsaEncryption AlgorithmIdentifier, then the 256-byte OCTET STRING
  signature. The script's self-check RSA-publics our own signature and recovers `sha256(<scope>)`, the
  same route `recover_zip_digest.py` proved correct on this kind of certificate.
* Getting there took five fixes, each measured rather than assumed:
  * the hardcoded OID hex decoded as `1.2.840.113549.1.5.5.3.4.5.5`, not sha256 - OIDs are now computed
    from their arcs (sha256 = `2.16.840.1.101.3.4.2.1`, rsaEncryption = `1.2.840.113549.1.1.1`);
  * the legacy SignerInfo holds **issuer + serial**, not issuer + subject (that is CMS), wrapped in its
    own SEQUENCE, and each child must be a complete DER node - slicing the value without its tag/length
    header made openssl report `Field=issuer_and_serial, Type=PKCS7_ISSUER_AND_SERIAL, wrong tag`;
  * long-form DER length wrote `tag, 0x80|n, length` and dropped the body, giving a 64-byte PKCS#7 that
    claimed to hold a 1,196-byte certificate;
  * the EOCD's comment length sits at `+20`, not `+16` (`+16` is the central-directory offset), so every
    signed zip looked commentless to our own reader; `rfind('PK\x05\x06')` can also land inside the
    PKCS#7 bytes, so the scan walks backwards until the declared length accounts for the tail exactly;
  * `openssl pkeyutl -rawin` hashes the padded block again, so signing uses `openssl dgst -sha256 -sign`,
    which is exactly `RSA(DigestInfo(sha256(content)))`.
* The evening's blocker (empty shell output, root filesystem at 0 bytes free, `/tmp` 81% used) was cleared
  during the night: `/` now has ~14 GiB free and tmpfs is at 84 MiB used. The shell tool still returns
  empty stdout for every command, so commands redirect to files under `/run/media/Daan/Opslagmonster/`
  and the results are read back - that is the working pattern, not a bug to chase.
* `a14-work/a14chk/sha256.txt` was stale: it listed `a14-fixed.img` as `933e2ecc...` and `raw-super.img`
  as `0ed0d341...`, both pre-patch images. Re-measured Nov 12 and rewritten to name the files that are
  actually pushed - `raw-super.img` `d4b4990931cc...`, `a14-boot-fixed.img` `933e2ecc4237...`,
  `a14-fixed.img` `f378d4fd1342...`, `boot-a10k-a14rd.img` `455a9ac8e461...` - and `sha256sum -c` passes
  (exit status 0; the Dutch locale prints `goed`, not `OK`). The old file is kept as `sha256.txt.stale.bak`.
* Name mismatch between the two staging scripts, fixed Nov 12: `scripts/stage_a14_payload.sh` pushed the
  local filenames (`a14-boot-fixed.img`, `raw-super.img`) and wrote no manifest, while
  `scripts/install_a14_from_adb_root.sh` requires `$SRC/boot-a14.img`, `$SRC/super-a14.img` and a
  `<hash> <name>` `sha256.txt` - tomorrow it would have aborted with "no sha256.txt". The staging script
  now pushes under the installer's names, builds the manifest from those names, pushes it, and reads it
  back on the unit (the two read-back checks are `|| true`, because stock A10's `sha256sum` may not
  support `-c` and an informational failure must never abort a good staging).

## Queued for the morning (nothing written to the unit since the stock restore)

Done during the night, so these no longer need doing: freeing the root filesystem (now ~14 GiB free,
tmpfs 486 MiB used), housekeeping to NAS cold storage, committing the dual-cert slice / `make_f2fs.oem` /
installer files (`f332cd2`) and the housekeeping + signing scripts (`d17185a`), and probing the zip
digest (result: not reproducible offline - see the `recover_zip_digest.py` bullet above).

Still queued:

1. Push `super-a14.img` (`d4b4990931cc`) and `boot-a14.img` (`933e2ecc4237`) again - the unit rebooted
   stock, `/data/local/tmp/a14` was wiped by the rollback, and the second super push never completed.
   They live in `/run/media/Daan/Opslagmonster/a14-work/a14chk/` now, and `scripts/stage_a14_payload.sh`
   defaults to those paths.
2. The recovery fallback package is built and signed: `scripts/build_recovery_fallback_zip.sh` produces
   `/run/media/Daan/Opslagmonster/a14-work/huzip-card/update.zip` (4,315 B, sha256 `5a6bc296c67128d6…`)
   containing only `updater-script` + notes - recovery dd's the images straight from the card root, so the
   3.2 GiB payload is never unpacked on the unit. Card root layout: `update.zip`, `super-a14.img`
   (= `raw-super.img`), `boot-a14.img` (= `a14-boot-fixed.img`). The hashed byte range is still a
   documented guess, and that is safe: recovery verifies before running the updater-script, so a wrong
   scope means "install refused", nothing written. Primary install route stays
   `scripts/install_a14_from_adb_root.sh` under `setsid` with `WIPE=1`.
3. Measure zLink against the firmware actually on the unit (see the zLink section below): our vendor
   slice is staged from the A11 dump, and zLink only started working after the newest diatsia firmware.
4. `SSData` is still at 100% (797 MiB free) - the only filesystem still blocking builds. Scratch now
   lives on the repo volume, but anything that needs the tree's own `out/` may still fail there.
5. The recovery route is ready to run once the unit is powered again: power on, `adbon`, `adb connect
   192.168.1.120:5555`, `adb root`, then `scripts/flash_recovery_from_adb_root.sh` with
   `a14-work/recovery-patched/recovery-patched.img` (`a0cd9de3…`) and its `recovery-sha256.txt` pushed to
   `/data/local/tmp/rec/`. That only writes partition 8. Then boot the bootSD card with a roomy card
   carrying `hu-install.flag`, `super-a14.img`, `boot-a14.img` and `hu-checksums.txt`
   (`scripts/stage_hu_card.sh`), watch `/dev/console` and read `/tmp/hu-install.log`, and deep power-cycle
   afterwards. Rollback for partition 8 alone: push `hu-stock-backup/recovery.bin` (`1fdf5ea77fc6…`) and
   dd it back. The console banner itself proves which recovery booted: `hu-install: hash tool = …` means
   the patched partition 8 loaded, and without a flag it prints `no hu-install.flag found on any card ...
   nothing written` and exits 0, leaving the stock recovery menu.

## zLink started working on the restored stock firmware - Nov 11 evening

Owner report: after reflashing the newest `diatsia` firmware via the recovery SD card, zLink works again
where it previously did not, and the guess is that it now matches the MCU better. Worth treating as a
vendor-blob constraint, not a coincidence: our vendor slice is staged from the older A11 dump
(`ref-a10/` + D15), so whatever changed in this firmware's zLink/MCU path may not be in our payload.
Two things to measure in the morning, both offline against the running stock image:
* which binaries own zLink (`/system/app`, `/system/lib|lib64`, `/vendor/lib/hw`) and their sizes/hashes;
* compare them against our staged vendor slice, so the A14 vendor slice can be re-staged from the
  firmware that is actually on the unit now rather than the A11 dump.
The MCU side is already known-good on stock (`persist.product.mcuversion=MTCE_HXD_V3.56_1`,
`mtc-car`/`mtc-av`/`mtc-cvbs`/`mtc-cvbs2`/`mtc-dab`, `ttyS0/1/4`), so zLink is a userspace/blobs question.

## Recovery partition measured - Nov 12 (what the D42 patch works on)

**AVB cannot reject a patched recovery or our patched boot.** `vbmeta.bin` (1,048,576 B) holds **19
non-zero bytes in total**: `AVB0`, header version 1, flags 0, `authentication_data_block_size = 0`,
`auxiliary_data_block_size = 0`, `metadata_block_size = 0`, and the string `avbtool 1.1.0` at offset 128.
Zero hash or chain descriptors, so nothing is verified against nothing. Neither `boot.bin`,
`recovery.bin` nor our payload boot has an AVB footer - their last 64 bytes are all zeros. The kernel
cmdline already says `androidboot.verifiedbootstate=orange`, `androidboot.veritymode=enforcing` and
`androidboot.selinux=permissive`. `vbmeta` stays untouched, so D18 is unaffected either way.

**Stock recovery image layout** (`sha256 1fdf5ea77fc66f48977d7846c468959a5845d0222dc73c3fe07a1b96b6cb023b`,
100,663,296 B - partition-sized, zero padding after the last part): header version 2, header size field
1660, page size 2048, os 10.0.0 patch level 2020-05; kernel 25,671,688 B load `0x10008000` (file offset
2048); gzip cpio ramdisk 12,519,199 B load `0x11000000` (file 25,687,296); second bootloader 924,672 B
load `0x10f00000` (file 38,202,880); recovery dtbo 803 B at file 39,129,600 = `0x254F000`, which the
header stores as an offset field; dtb size 0 at `0x11f00000`. The derived offsets match the stored field,
so the layout is confirmed rather than assumed.

**Recovery already gives a shell without any patch.** `init.rc` imports `/init.recovery.${ro.hardware}.rc`,
`prop.default` carries `ro.debuggable=1`, and `on fs && property:ro.debuggable=1` sets
`sys.usb.config adb`, which starts `service adbd /system/bin/adbd --root_seclabel=u:r:su:s0
--device_banner=recovery`. `init.recovery.rk30board.rc` sets `sys.usb.controller "fe800000.dwc3"`,
`sys.usb.configfs 1` and `start console`. Recovery's adb is USB functionfs/configfs only - no TCP path -
so the serial fob is the reliable channel and the USB direction of the head unit's port is still unverified.

**init never mounts `/system` in recovery.** `on fs` in `init.rc` only builds the USB gadget and mounts
functionfs; the partition mounts come from `/system/etc/recovery.fstab`, handled by `/system/bin/recovery`
itself (`/system`, `/vendor`, `/odm`, `/cache`, `/metadata`, `/data` as f2fs, `cust`/`custom`,
`/mnt/external_sd` = `mmcblk0p1`, `/mnt/internal_sd`). Anything that needs `/system/bin/linker64`
therefore only works after recovery has started, which is what `hu-install.sh` waits for (D43).

**The recovery ramdisk's `/sbin` is a static 32-bit ARM world.** `busybox` 1,807,056 B (`ELF 32-bit LSB
executable, ARM, EABI5, statically linked, for GNU/Linux 2.6.14`) and `sh` 206,684 B (static), plus
`e2fsck`, `eio`, `insmod`, `iwlist`, `mkdosfs`, `pcba_core`, `resize2fs`, `rmmod`. No `adbd`, no
`recovery`, no applet symlinks. Probing the binary's strings: `dd`, `stat`, `mount`, `umount`, `reboot`,
`sync`, `wc`, `cut`, `sed`, `cp`, `ls`, `df`, `du`, `sleep`, `head`, `tail`, `cat`, `od`, `expr`, `tr`
appear; `sha256sum` and `blockdev` do not; `md5sum`, `sha1sum`, `cmp`, `cksum` and `hexdump` appear in the
strings but cannot be confirmed without running the binary (no qemu-arm on this host, unit powered off),
which is why `hu-install.sh` probes its hash applets at runtime instead of assuming them.

**Correction: `hu-stock-backup/sys-region.bin` is our payload's system slice, not the stock one.** debugfs
shows Android 34 binaries (`toybox` 562,832 B, `make_f2fs` 201,496 B, `blkid`, `sh`, all "for Android 34",
interpreter `/system/bin/linker64`) and HCT apps dated 8-Nov-2026 (`blueletd`, `brlinktd`) - it is the
region cut out of `raw-super.img` to inject `otacerts.zip`. The stock Android 10 mkfs is
`hu-stock-backup/make_f2fs` (49,544 B, "for Android 29", byte-identical to `oem-in-super.bin`). No stock
64-bit binaries were extracted: the stock `super.bin` system slice is not at a page-aligned offset we can
find (the ext4 magic `53 ef` has no hit at 0, 1 MiB or 2 MiB), and D43 does not need them.

**Tool quirks measured today.** `unpack_bootimg` needs `--boot_img`. `repack_bootimg` is a frozen binary
that shells out to `unpack_bootimg` and `mkbootimg`, so the host `bin/` directory must be on PATH, and it
refuses absolute destination names ("destination file name cannot be absolute"). Lineage's `mkbootimg`
then rejects this header (version 2 with `--recovery_dtbo` and dtb size 0) and leaves a **1,648-byte**
truncated image behind - hence `scripts/repack_recovery_python.py`, which splices the ramdisk and updates
only `ramdisk_size` and the stored dtbo offset. `debugfs` has no `-r` option (it is read-only unless `-w`).
And in this shell environment, ssh output redirected with `>` into a file comes back **0 bytes** while
`| tee file` delivers the real content.

**The patched recovery image is built and verified - Nov 12.** `scripts/patch_recovery_autorun.sh`
splices `/sbin/hu-install.sh`, `/sbin/make_f2fs.oem` and the appended `init.recovery.rk30board.rc` into
the stock ramdisk and produces `a14-work/recovery-patched/recovery-patched.img` (39,108,608 B, sha256
`a0cd9de318a8fb284a44495431f79cd75c45332bb9dffcfb121655e38e71f51a`; the NAS copy hashed identically, so
the base64 transport is proven). `unpack_bootimg` on stock and patched differs in exactly two lines:
ramdisk size 12,519,199 → 12,504,405 (gzip -9 beats the original compression) and recovery dtbo offset
`0x254f000` → `0x254b800`. Kernel, second bootloader and dtbo hashes are identical, and the extracted
patched ramdisk holds the three injected files with hashes matching their sources, `service hu_install`
and `start hu_install` once each, and the stock `console` service plus the `sys.usb.controller` line still
present. The image is content-sized rather than partition-sized - readers go by the header's sizes, and the
flash script compares only the bytes it wrote.

**What the bootSD archive actually is - Nov 12.** NAS `cold/vibe-baking/research/bootableSD/` holds only
Rockchip's SD-boot tooling: `SDBoot.bin` (152,366 B), `rk32xx_loader_v1.00.232.bin`, the Windows
`SD_Firmware_Tool.exe` and `Create Upgrade Disk Tool v1.53.exe`, `config.ini` and `sd_boot_config.config`.
No Android image and no recovery image are in it. The card's boot config is six keys -
`loader_update = 0`, `display_led = 1`, `display_lcd = 1`, `pcba_test = 0`, `fw_update = 0`,
`demo_copy = 0` - so the card feeds the SoC a loader/minuboot and everything else comes from the eMMC
chain. Two consequences: the recovery partition we patched is the one that runs on this route, and
`config.ini` states in its own comments that the OEM upgrade flow deliberately leaves the recovery partition
alone, which is the same scope D18/D19 enforce. Whether the SD path lands in recovery or in normal boot is
still only known from the owner's own measurement; the console banner settles it on the next power-on.

## The recovery installer logic-tested offline - Nov 13

`scripts/hu_recovery_install.sh` had never been run anywhere except on paper: busybox is not on this
workstation, the unit is powered off, and no card was staged. `scripts/smoke_recovery_installer.sh` runs
the real script against a fake card and fake partitions - sparse files at the measured payload sizes,
`/proc/partitions` and `/dev/block/*` rewritten to files in the scratch dir, `$BB` mapped onto host
coreutils, `/dev/console` rewritten to a file and say()'s `>` turned into `>>` so the transcript is the
whole log rather than the last line - and asserts eight scenarios. Two bugs came out of it, both of
which would have been discovered at the bench after a power-on. Neither writes anything, so both were
"the install refuses" rather than a corrupt unit, but the route would not have run.

**Bug 1 - the payload size check refused every write.** The installer derived KiB by dropping the last
three decimal digits of the byte count, which divides by 1000, not 1024. `raw-super.img` (3,263,168,512 B)
came out as 3,263,168 KiB against a partition of 3,186,688 KiB, and `a14-boot-fixed.img` (32,796,672 B)
as 32,796 KiB against 32,768 KiB, so both comparisons failed and the first thing the installer printed
after finding the flag was `super payload exceeds partition - nothing written`. Nothing may be divided
here: busybox ash arithmetic uses a 32-bit long, so a byte count above 2,147,483,648 wraps. The size now
comes from the card. `hu-checksums.txt` gained `size <bytes> <blocks> <name>` lines written by
`scripts/stage_hu_card.sh`; the installer compares the declared byte count against `stat -c %s` as a
decimal string (no arithmetic) and uses the declared block count for the `dd` counts and the readback.
The largest number it ever computes is 796,672 blocks * 4 = 3,186,688 KiB, far under the wrap.
`stage_hu_card.sh` refuses a payload whose byte count is not a multiple of 4096, so blocks * 4096 ==
bytes by construction, and a mismatch would be caught by the readback hash anyway.

**Bug 2 - the digest check verified nothing.** `scripts/stage_hu_card.sh` named the algorithms
`sha1`/`sha256`/`md5`, while the installer matched the manifest against the applet name it probed
(`sha1sum`). No line ever matched, `ok=1` was pre-set, and the loop verified zero files while reporting
success - a corrupted card would have been flashed with no integrity check at all. The installer now
accepts both spellings (`sha1` and `sha1sum` etc.) and refuses a manifest that carries no line for the
digest it can actually compute: `no sha256sum line in ... - cannot verify the payload, nothing written`.
The staging script writes the applet names (`sha256sum`/`sha1sum`/`md5sum`), so the match is direct, and
its own read-back loop now checks the size lines too. Measured staging output against a fake card:
`size 3263168512 796672 super-a14.img`, `size 32796672 8007 boot-a14.img`, plus one digest line per
algorithm, and staging exits 1 on a payload truncated to 32,796,673 B.

The scenarios, all passing offline (`scripts/smoke_recovery_installer.sh`, rc 0): inert with no flag and
nothing written; good manifest writes super then boot, formats userdata through the stub mkfs and passes
both readbacks; the old `sha256` spelling still matches the probed applet; a manifest whose digest lines
are for an algorithm busybox does not have refuses; a manifest with no size lines refuses before any
write; a declared byte count that does not match the file refuses; a partition smaller than the payload
refuses with `super payload exceeds partition`; a payload with one byte changed inside it is caught by
the digest check before the write.

**Consequence: the recorded patched recovery image is now stale.** `a14-work/recovery-patched/
recovery-patched.img` (39,108,608 B, sha256 `a0cd9de3…`) carries `hu-install.sh` with hash
`ea8858cc…`, which is the buggy script. Flashing partition 8 with it would take the refuse-everything
route, so `scripts/patch_recovery_autorun.sh` must run again before the flash and `analysis/
recovery-patched.txt` must be rewritten with the new hashes. That script splices the ramdisk on the
build host (`unpack_bootimg`, `repack_recovery_python.py`, the cpio checks), and the access wrapper it
uses (`/tmp/opencode/omv.sh` + `/tmp/opencode/build_host.env`) is gone - `/tmp` was cleared - so the
build-host credential has to be re-supplied before the image is rebuilt. Nothing was flashed today.

What the smoke harness does *not* prove: the shell dialect. busybox ash is not available on this host,
so POSIX syntax still has to be checked on the build host with `dash -n` and `busybox ash -n`, which is
what the Nov 12 run did for the previous script.
