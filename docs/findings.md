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
* Module payload for the A10-kernel variant is now staged: `adb pull /vendor/lib/modules` gave 21 files
  (19 `.ko` + `modules.alias`/`modules.dep`) into `/var/tmp/hu-stock-backup/vendor-modules/modules/`, now at
  `a14-work/hu-stock-backup/vendor-modules/`. Vermagics, re-measured Nov 14 from those files: `4.19.111+`
  for `8188eu`, `8188fu`, `8189fs`, `8723bu`, `8733bs`, `8733bs_ap`, `8821cs`, `8821cu`, `8821cu_ap`,
  `8822bu`, `8822cs`, `aic8800_bsp`, `aic8800_fdrv`, `aic8800_fdrv_ap`, `sd_user_hid`, `usb_f_iap`,
  `usb_f_iap2`, `virtual_tp`; `4.19.101+` for `sprdwl_ng` and `bcmdhd`; `mali_kbase` at `4.4.167`. **There
  is no touch-driver module at all** - an earlier draft of this line named `goodix`, which is not in the
  pulled set (and not in `debugfs -R ls /lib/modules` of `analysis/daisaita_a10/vendor.img`): the Goodix
  driver is built into the kernel, so the Nov 13 panic cannot be fixed by swapping a module. Dropping these
  modules into our A14 vendor partition makes `boot-a10k-a14rd.img` (kernel `4.19.111+`) coherent without
  building anything.
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

## The live vendor is byte-for-byte the Android 10 reference, not the Android 11 dump - Nov 13/14

A fresh probe ran at 20:16 CET on Nov 13 (`incoming/probe-20261113-2016.md`) on the firmware the unit
boots today, as root: `id` reports uid 0 with context `u:r:su:s0`, `su` is present, magisk is not. The
build is `rockchip/rk3399/rk3399:10/QQ2A.200305.004.A1/eng.hct2.20250401.152740:userdebug/release-keys`
(the April 2025 OEM rebuild the owner flashed via the bootSD route, **D39**), SELinux Permissive, and the
cmdline is the usual one: `console=ttyFIQ0`, `androidboot.console=ttyFIQ0`,
`earlycon=uart8250,mmio32,0xff1a0000`, `androidboot.selinux=permissive`,
`androidboot.verifiedbootstate=orange`, `androidboot.veritymode=enforcing`, `androidboot.dtbo_idx=0`,
`androidboot.boot_devices=fe330000.sdhci`, `storagemedia=emmc`. Root read of the block sizes gives
`super 3,263,168,512` and `userdata 58,844,495,360`; the sysfs size for `mmcblk2` comes back as
`-1610612736` in the probe's arithmetic, because 62,813,896,704 B wraps a signed 32-bit read - partition
sizes must come from `blockdev`/root, not from sysfs. The probe's own card listing found no
`/storage/sdcard0`, and it asks whether the owner keeps a copy of the zip currently installed; the answer
is yes - `diatsia fw/update(1).zip` is that firmware (**D39**/**D40**).

`tools/vendor_blob_check.py` hashes the paths the probe hashed (vendor HAL binaries, `.ko` modules,
`build.prop`, the vintf manifest) and re-reads the same paths out of reference images with debugfs.
Run against the three reference vendor images:

| reference | identical | differ | live-only | meaning |
|---|---|---|---|---|
| `analysis/daisaita_a10/vendor.img` + its `system`/`product`/`odm` | 126 | 0 | 0 | the whole hashed surface of the live firmware is byte-for-byte the Android 10 reference (rc 0) |
| `analysis/daisaita_a11/vendor.img` | 1 | 75 | 2 | almost every vendor blob differs from the Android 11 dump |
| `analysis/images/assembled/vendor.img` | 96 | 17 | 2 | mostly A10-era, 17 blobs differ |

The committed comparison file `analysis/vendor_blob_live_vs_oem_a10.tsv` is the first row: 126 rows, all
`identical`. Without the `--system`/`--product` images the tool reports `/product/build.prop` and
`/system/build.prop` as `live-only`, because they are not inside the vendor image - that is why the
vendor-only runs exit 1 while the full run exits 0.

**What this changes.** `scripts/prebuilt_vendor.sh` stages `vendor/hct4/tree/vendor` from
`vendor/hct4/prebuilt/vendor_a11.img`, and `scripts/package.sh` prefers `daisaita_a11.zip` when it needs
to re-unpack, so the vendor our payload ships is the Android 11-era tree. The unit runs the Android 10-era
tree byte-for-byte, and that is the tree whose zLink/MCU behaviour the owner measured working on Nov 11.
Among the 75 paths that differ from the live unit are the HALs the owner's criteria depend on:
`audio.primary.rk30board.so`, `hwcomposer.rk30board.so`, `sensors.rk30board.so`, `gps.default.so`,
`power.default.so`, `vibrator.default.so`, the `mtc.mfi` service and impl, `bluetooth`, `wifi`, `rild`,
`hostapd`, `wpa_supplicant`, the WiFi `.ko` modules and `vendor/etc/vintf/manifest.xml` itself. Re-staging
the vendor slice from the Android 10 firmware the unit actually runs revises **D9**/**D15**, so it is a
decision for the owner rather than a change to make silently.

## The Nov 13 20:03 kernel panic: the touch driver hands `input_dev->phys` a stack buffer (Nov 14, offline)

**Provenance.** The unit went offline before this analysis, so everything below is worked from the RAMoops
record pulled over `adb root` on Nov 13 (`/sys/fs/pstore/dmesg-ramoops-0`), now committed as
`analysis/panic-20261113-2003-ramoops.txt` (263,797 B, sha256 head `d9b04399…`). Nothing was re-measured
today; where a fact could only be seen on the live unit it is marked as such. The record's own header is
`Panic#2 Part1` - the counter says a *previous* panic existed in the persistent RAM region, and only
`dmesg-ramoops-0` was pulled (`/sys/fs/pstore` was never listed), so any earlier panic record is not in
hand. Re-measure the pstore listing when the unit is reachable.

**The fault, verbatim from the record** (`Panic#2 Part1`, kernel `4.19.111+ #190`, `Tainted: G W`,
`Hardware name: Rockchip RK3399 HCT  Board (DT)`, `Modules linked in: usb_f_iap2 8188eu aic8800_bsp`):

| item | value |
|---|---|
| first line | `[3334.164797] Unable to handle kernel paging request at virtual address ffffff8009d73c70` |
| `ESR` | `0x96000007` - DABT (current EL), `ISS = 0x00000007`, `SET=0 FnV=0 EA=0 S1PTW=0`, IL 32 bits |
| page tables | `pgd=f7ffe003`, `pud=f7ffe003`, `pmd=00250003`, **`pte=0000000000000000`** (4k pages, 39-bit VAs) |
| oops | `Internal error: Oops: 96000007 [#1] PREEMPT SMP` |
| process | `Process InputReader (pid: 4122)`, `CPU: 3` |
| `pc` / `lr` | `__pi_strlen+0x60/0x84` / `str_to_user+0x24/0xf8` |
| registers | `x0 = ffffff8009d73c78`, `x1 = ffffff8009d73c70`, `x11 = 0x0101010101010101` (the strlen zero-byte magic), `sp = ffffff800f863c90` |
| trace | `__pi_strlen` → `evdev_ioctl_handler+0x1174/0x16b8` → `evdev_ioctl+0x10/0x18` → `do_vfs_ioctl+0xbc/0xda8` → `ksys_ioctl+0x84/0x98` → `__arm64_sys_ioctl+0x18/0x28` → `el0_svc_common` → `el0_svc` |
| `Code:` tail | `f10020ff cb0703e7 (a8c10c22)` = `ldr x3, [x0], #8` - strlen walking the buffer it was handed |
| end | `---[ end trace 2c55f59c8f1de4c7 ]---`, then `[3334.300295] Kernel panic - not syncing: Fatal exception`; SoC temp at panic was 68 C (`rockchip-thermal ff260000.tsadc: channal 0`) |

The trace ids run consecutively - `2c55f59c8f1de4c6` is the earlier WARN (§ below), `…c7` is this panic -
so both happened in the *same* boot. `Kernel Offset: disabled` (`kaslr_offset() == 0`) and
`# CONFIG_ARM64_RANDOMIZE_TEXT_OFFSET is not set` (`analysis/daisaita_a10_kernel_config.txt:5770`).

**What the faulting address is.** Decoding it against the shipped config, not against a guess. Line numbers
below are `analysis/daisaita_a10_kernel_config.txt`, which is byte-identical to the live
`/proc/config.gz` dump committed as `analysis/hu_kernel_config_live-20261113.txt` (5774 lines, `diff -q`
clean):
`CONFIG_ARM64_VA_BITS=39` (`:380`) → `VA_START = 0xffffff8000000000`; `# CONFIG_KASAN is not set` (`:5620`)
→ `MODULES_VADDR = VA_START`, and `MODULES_VSIZE` is `SZ_128M`
(`arch/arm64/include/asm/memory.h` from `rockchip-linux/kernel` `develop-4.19`) →
`KIMAGE_VADDR = MODULES_END = 0xffffff8008000000`; `TEXT_OFFSET = 0x00080000` (`arch/arm64/Makefile:96`) →
`_text = 0xffffff8008080000`. The Android boot image header in the D40 stock backup's `boot.bin` says the
kernel Image is **25,671,688 B**, and the live `boot` partition dump taken Nov 13 reports the same size, so
`_end = 0xffffff80098fb808`. The `pc` (`0xffffff8008e14120`) is 13.6 MB inside that image - real kernel
text. The faulting address is **4.7 MB past `_end`**, i.e. in the vmalloc area, and `pte=0` says the page
is simply not mapped. `PAGE_OFFSET = 0xffffffc000000000` is the linear map, and the register values that
come from it (`x24 = 0xffffffc0d78c4600`, `x23 = 0xffffffc0eede2000`, `x8 = 0xffffffc0eede0800`) are live
kernel objects on the `evdev`/`input_dev` side of the request - those are fine; only the `phys` pointer is
stale. `CONFIG_VMAP_STACK=y` (`:628`) puts thread stacks in vmalloc, and `sp` is
likewise past `_end`, so the current stack is a vmalloc'd one: **the address `dev->phys` points at is a
stack page of some earlier thread that has since been freed and unmapped.**

**The driver bug.** Rockchip's BSP touch driver, not mainline's. In
`drivers/input/touchscreen/gt9xx/gt9xx.c` (`rockchip-linux/kernel`):

```c
static s8 gtp_request_input_dev(struct i2c_client *client, struct goodix_ts_data *ts)
{
    s8 ret = -1;
    s8 phys[32];                     /* 2066: on the STACK */
    ...
    ts->input_dev = devm_input_allocate_device(&client->dev);   /* 2072: lives until the i2c client goes */
    ...
    sprintf(phys, "input/ts");       /* 2111 */
    ts->input_dev->name = goodix_ts_name;   /* 2112: "goodix-ts" (line 69), a static string - fine */
    ts->input_dev->phys = phys;      /* 2113: points the long-lived struct at the frame that dies */
    ts->input_dev->id.vendor = 0xDEAD; ts->id.product = 0xBEEF; ts->id.version = 10427;
```

The `input_dev` is `devm`-allocated, so it outlives `gtp_request_input_dev()`; `phys` does not. Same code
is in every branch we checked: `develop-4.4` (lines 2047/2092/2094), `develop-4.19`, `develop-6.1` and
`master` (all 2066/2111/2113). Mainline's rewrite is unaffected -
`drivers/input/touchscreen/goodix.c` assigns literals: `input->phys = "input/pen"` (line 339) and
`ts->input_dev->phys = "input/ts"` (line 1147). So the fix is one line in the vendor driver.

The driver is **built into the kernel**: `CONFIG_TOUCHSCREEN_GT9XX=y` is in the config of the kernel that
runs today (`analysis/hu_kernel_config_live-20261113.txt:2032`) **and** in the Android 11 kernel's config
(`analysis/daisaita_a11_kernel_config.txt:2070`), the stock vendor partition carries no touch `.ko`
(`a14-work/hu-stock-backup/vendor-modules/modules/` has 19 `.ko`, none touch-related - the Android 11
package *does* ship a `goodix.ko` in `/lib/modules/modules.load`, which is worth checking against a kernel
that already has the driver built in), and the boot log registers it directly
(`input: goodix-ts as /devices/platform/ff3d0000.i2c/i2c-4/4-0014/input/input1`,
`incoming/probe-20261113-2016.md:7472`). So switching kernel generations does **not** dodge this bug, and a
module swap cannot fix it; the kernel source has to change.

**Why it only bites sometimes.** Android 10's `EventHub::openDevice_locked` asks the kernel for the three
identity strings on every device open: `EVIOCGNAME` (`a10-EventHub.cpp:1203`), `EVIOCGPHYS` (`:1241`),
`EVIOCGUNIQ` (`:1249`), fetched from `android.googlesource.com/platform/frameworks/native`
`refs/heads/android10-release`. `EVIOCGPHYS`/`EVIOCGUNIQ` go through `str_to_user()`, which does
`strlen(str)` - and `strlen` on a dangling stack pointer is harmless while the vmalloc page happens to
still be mapped (it copies whatever garbage sits there) and fatal once that page is freed. Both ends of
that match what the unit printed:

* Garbage-but-mapped: `/proc/bus/input/devices` read via `adb root` on Nov 13 showed goodix-ts with
  `P: Phys=` followed by raw non-string bytes, `U: Uniq=` empty, and `Vendor=dead Product=beef
  Version=28bb` (= the driver's `0xDEAD/0xBEEF/10427`). This was a live read **not** captured in the probe
  report, so it is not reproducible while the unit is offline - re-read it on the next reachable session.
* Freed page: the Nov 13 panic, `pte=0`.

The upstream rule this breaks is stated plainly by Dmitry Torokhov on LKML in
"[syzbot] [input?] KASAN: slab-use-after-free Read in `input_dev_uevent`" (Aug 23 2023): a driver must not
point `input_dev->name`/`phys`/`uniq` at memory it has already freed. The vendor driver does exactly that.

**What set the ioctl off in this boot** (all times are uptimes from the record):

| t | event |
|---|---|
| 3325.637752 | `init: Service 'vendor.sensors-hal-1-0' (pid 290) exited with status 255`, init restarts it |
| 3328.430911 | `binder_alloc: 466: binder_alloc_buf, no vma` - system_server (pid **466**) is gone |
| 3328.515860 / 3328.545520 | `bootanim` started by surfaceflinger (pid 184); `init: Service 'zygote' (pid 266) received signal 9` → **the framework restarts** |
| 3333.631361 | `idmap2d` started from pid **3989 (system_server)** - the *new* system_server |
| 3333.865666 | sensors-hal (pid 3818) exits 255 again; init restarts it at 3333.868249 |
| 3334.164797 | the panic, in `InputReader` pid **4122** - a child of the new system_server, doing the first `EVIOCGPHYS` of a fresh `EventHub` open of `/dev/input/event1` |

So the panic needs a *framework restart*: the goodix-ts device is re-opened, the dead `phys` pointer is
read again, and by then its stack page is gone. Touch itself kept working after the reboot, which fits:
nothing re-opens the device during a normal boot. **Honest gap:** the kernel log cannot say *why* system_server
died - logcat is not in pstore. The twice-exiting `vendor.sensors-hal-1-0` (status 255, uid 1000) is the
nearest candidate and is itself a defect worth chasing (`docs/head-unit-findings.md`), but the causal link
is unproven. Reboot completed 20:03:30 CET (`ro.runtime.firstboot = 1794596610003`, probe line 656) and
`ro.boot.bootreason = kernel_panic,fatal_exception` (probe line 358); with 3334 s of uptime that puts the
crashed boot's start at ≈19:47:56 CET (derived arithmetic, not a measured boot timestamp).

**The taint came from the WiFi fork.** Earlier in the same boot, `[1566.010716] WARNING: CPU: 3 PID: 1070 at
drivers/net/wireless/rockchip_wlan/rtl8188eu/hal/hal_com.c:12050 rtw_lps_state_chk+0x58/0x70 [8188eu]`,
`Comm: RTW_CMD_THREAD`, that record's own line says `Not tainted` - it is what made the panic's
`Tainted: G W`. The warning is fork-only: `rtw_lps_state_chk()` polls `REG_TCR`'s `BIT_PWRBIT_OW_EN` for
`LPS_ACTIVE_TIMEOUT` ms and, on failure, prints `PS_MODE_ACTIVE check failed` then `rtw_warn_on(1)`
(`hal_com.c:12035-12052` at `develop-4.19`), reached via `HW_VAR_LPS_STATE_CHK` (`hal_com.c:12410-12412`)
from `rtw_set_ps_mode()` (`core/rtw_pwrctrl.c:1004`, the function defined at `:858`) - i.e. power-save
leave timing on our USB 8188eu. Mainline
cannot be told about it as-is: `drivers/staging/r8188eu/*` returns 404 on `torvalds/linux` master (the
driver was removed from staging), so this belongs in `rockchip-linux/kernel`'s issue tracker. It did not
kill anything; it just taints and logs.

**Consequence for our firmware.** The bug is *provable* on the kernel the unit runs today (`#190`), because
that is where the panic came from. Our payload ships the vendor **Android 11** kernel (`4.19.193 #24`,
**D33**), and the same three lines exist in every Rockchip branch we could read
(`develop-4.4`/`4.19`/`6.1`/`master`) - but the vendor kernel *source* is not in hand
(`docs/findings.md`, the Nov 11 module/kernel story), so for the A11 kernel this is an inference from the
BSP family, not an inspection result. Shipping the prebuilt kernel unchanged therefore inherits a panic that
fires whenever an input device is re-opened after that stack page is freed. The fix is a one-line vendor
source patch (`ts->input_dev->phys = "input/ts";`) plus a kernel rebuild, which is a real build step
(**D9**'s prebuilt-kernel stance) - recorded as a risk and an owner question, not decided here. See
`docs/upstream.md` for the report we could send, which is written to be safe to post without our OEM data.

## Which kernel Android 14's VINTF actually accepts - measured Nov 15 (offline, no unit touched)

This settles the "keep the working A10 kernel vs ship the vendor A11 kernel" argument with numbers rather
than preference. Method: fetched the Android 14 kernel requirement lists from
`android.googlesource.com/kernel/configs` branch `android14-release` (`q/android-4.19`, `r/android-4.19`,
`s/android-4.19`: `android-base.config`, `android-recommended.config`, `android-recommended-arm64.config`,
`android-base-conditional.xml`) and diffed them against the two config dumps on disk
(`analysis/hu_kernel_config_live-20261113.txt` = the running `4.19.111+ #190`,
`analysis/daisaita_a11_kernel_config.txt` = `4.19.193 #24`). Parser: `/tmp/opencode/kc_check.py`; the
conditional XML has multiple root elements, so it is wrapped before parsing. "BASE-ONLY" is the set libvintf
enforces for compatibility (base + conditional, arm64 groups gated by `CONFIG_ARM`/`CONFIG_ARM64`);
"WITH-RECOMMENDED" adds the recommended lists, which VTS checks and `check_vintf_compatible` does not.

| kernel FCM branch | `minlts` | requirements | A10 `#190` unmet | A11 `#24` unmet |
|---|---|---|---|---|
| `q` (FCM 4) base-only | 4.19.42 | 372 | **0** | **0** |
| `q` with recommended | 4.19.42 | 372 | 2 (`CONFIG_KPROBES`, `CONFIG_KPROBE_EVENTS`) | 3 (+ `CONFIG_SDCARD_FS`) |
| `r` (FCM 5) base-only | 4.19.110 | 395 | **19** | **2** |
| `r` with recommended | 4.19.110 | 395 | 20 | 4 |
| `s` (FCM 6) base-only | 4.19.191 | 403 | 26 (+ fails `minlts`: 4.19.111 < 4.19.191) | 10 |

The 19 unmet items on the A10 kernel (`r`): want `y` but absent - `CONFIG_ANDROID_BINDERFS`,
`CONFIG_BPF_JIT`, `CONFIG_BPF_JIT_ALWAYS_ON`, `CONFIG_DM_SNAPSHOT`, `CONFIG_DUMMY`,
`CONFIG_EXT4_FS_POSIX_ACL`, `CONFIG_F2FS_FS_POSIX_ACL`, `CONFIG_FS_VERITY`,
`CONFIG_FS_VERITY_BUILTIN_SIGNATURES`, `CONFIG_HID_STEAM`, `CONFIG_NETFILTER_XT_MATCH_QUOTA2_LOG`,
`CONFIG_STATIC_USERMODEHELPER`, `CONFIG_UTS_NS`, `CONFIG_VETH`; want `n` but present -
`CONFIG_FW_CACHE`, `CONFIG_IP6_NF_NAT`, `CONFIG_MODULE_FORCE_UNLOAD`, `CONFIG_RT_GROUP_SCHED`; plus
`CONFIG_ANDROID_LOW_MEMORY_KILLER`/`CONFIG_VHOST` absent as symbols. The A11 kernel's only two base-only
misses are options that do not exist in that kernel at all (`CONFIG_ANDROID_LOW_MEMORY_KILLER`,
`CONFIG_VHOST`).

What the payload declares, read out of the staged vendor slice
(`/run/media/Daan/Opslagmonster/a14-work/a14chk/vendor-slice.img`, `/etc/vintf/manifest.xml`):
`<manifest version="8.0" type="device" target-level="5">`, `<sepolicy>` (202404) and
**`<kernel target-level="5"/>`** (lines 5 and 61). So the payload demands kernel FCM 5 = branch `r`, which
`#24` satisfies and `#190` does not. Downgrading the kernel means downgrading the manifest to
`target-level="4"` (branch `q`, both kernels pass) - and that changes the HAL/interface expectations the
whole vendor story is built on (**D15**/**D16**), not just the kernel.

**Modules are kernel-specific, and they are coupled to the boot image.** Measured Nov 15 from the artifacts:

| artifact | contents |
|---|---|
| payload vendor slice `/lib/modules` | 17 `.ko`: WiFi/aic8800/`sd_user_hid`/`usb_f_iap`/`usb_f_iap2`/`virtual_tp`/`goodix` at **`vermagic=4.19.193`**, `mali_kbase` at `4.4.167`; `modules.load` lists 17 services |
| stock backup `vendor-modules/modules/` | 19 `.ko`: 18 at **`4.19.111+`**, `sprdwl_ng`/`bcmdhd` at `4.19.101+`, `mali_kbase` `4.4.167`; the stock A10 vendor image has **no `modules.load` file** (Rockchip's patched init + `init.insmod.cfg` did the loading, which Lineage init lacks - hence `device/rk3399-px6-hct4/configs/hu_insmod.sh`) |
| boot images | `a14-boot-fixed.img` 32,796,672 B, kernel payload **30,455,816 B** = A11 `#24` (sha `933e2ecc…`); `boot-a10k-a14rd.img` 28,231,292 B, kernel payload **25,671,688 B** = A10 `#190` (sha `455a9ac8…`); `a14-fixed.img` also 30,455,816 B |

So `a14-boot-fixed.img` + our super is a coherent pair, and `boot-a10k-a14rd.img` + our super is **not**:
every loadable module would be refused on vermagic (WiFi, USB HID, iAP gadget, virtual touchpad).
`mali_kbase.ko` is dead weight on both kernels: the GPU is built in
(`CONFIG_MALI_MIDGARD=y`, `analysis/hu_kernel_config_live-20261113.txt:3282`, same in the A11 config), so
`hu_insmod.sh` deliberately never attempts the Mali `.ko`s. `goodix.ko` is likewise never attempted now:
`CONFIG_TOUCHSCREEN_GT9XX=y` is built in on both kernels (`:2032` and `:2070`), which is also why the Nov 13
panic is inherited whichever kernel is shipped (**D45**).

**DTB difference (contents measured, consequence inferred).** The Android 11 DTB our boot image embeds has a
`/firmware/optee` node (`compatible = "linaro,optee-tz"`, `a14-work/a14chk/ours.dts:282-286`, plus
`firmware_android`); the OEM Android 10 DTB embedded in `boot-a10k-a14rd.img` has only `/firmware/android`
(`a14-work/a14chk/oem.dts:5698-5702`). Panel `timing0` is byte-identical in both (`clock-frequency 0x2349340`,
`hactive 0x320`, `vactive 0x1e0`), so display bring-up is not a DTB delta. The consequence that matters is the
OP-TEE binding: a `keymaster@4.0-service.optee` needs `/firmware/optee` and the matching TAs in `trust`, and we
keep the A10 `trust` (`7f2c4e52`). That pairing is unmeasured; the software-KeyMint route in
`docs/feasibility.md` sidesteps it.

**Doc/script drift fixed Nov 15 (this is a real trap, not cosmetics).** `docs/flash.md` told the operator to
flash `boot-a10k-a14rd.img` with our A14 super, while every staging path actually ships
`a14-boot-fixed.img` (`scripts/stage_hu_card.sh:36`, `scripts/stage_a14_payload.sh:21`,
`scripts/build_recovery_fallback_zip.sh:72`), and the comments in `stage_hu_card.sh`, `hu_recovery_install.sh`,
`stage_a14_payload.sh` and the fallback-zip README said "A10 kernel" for an image that carries the A11 kernel.
All five now state the kernel/module coupling. Nothing was flashed; both images remain unflashed (**D30**).

## Shape A checked against Android 14's actual code - Nov 15 (offline; no unit, no build run)

Owner direction Nov 15 (**D46**, answers received): shape A (OEM Android 10 kernel + Android 10 vendor
restaged + Android 14 framework) is primary, manifest at `target-level="4"`, software KeyMint, raw `dd` once
the offline gates pass (**D47**), public BSP kernel build now with vendor source pursued alongside (**D48**),
and **GPS added as a hard criterion** (**D49**). A research agent argued the FCM-4 contract; two of its
claims did not reproduce and are corrected below, so every line here is either fetched from Android 14 /
Lineage 21 source or measured out of the reference images on disk.

**FCM-4 cannot block boot.** `compatibility_matrix.4.xml` fetched from
`android.googlesource.com/platform/frameworks/native/+/refs/heads/android14-release` (the matrix data lives
under `libs/vintf/data/compatibility/`): 61 HAL entries, **all `optional="true"`, zero mandatory**, no AIDL
entries, no `<sepolicy>`, no `<kernel>`. The gap list is therefore advisory: 41 optional HALs the vendor does
not declare (`gnss@2.0`, `radio@1.4`, `thermal@2.0`, `usb@2.0`, `configstore@1.1`, `media.c2`,
`keymaster@4.0::strongbox`, …) and none of them is required to boot.

**No `<kernel>` tag must be added.** `platform/system/libvintf/+/android14-release/HalManifest.cpp`:
kernel compatibility is only checked when the manifest declares `<kernel>` (`shouldCheckKernelCompatibility()`
at line 576, used at 554), and `inferredKernelLevel()` (844-857) only infers for release ≥ S/R. The stock
Android 10 manifest (`/tmp/opencode/a10-manifest.xml`, dumped from `analysis/daisaita_a10/vendor.img`)
declares `manifest version="1.0" target-level="4"`, `<sepolicy><version>29.0</version>` and **no `<kernel>`**
- so shape A keeps `target-level="4"` verbatim, drops the `<sepolicy>` block (the generator already does that),
and adds nothing. That also removes the FCM-5 kernel requirement list entirely, which is the point: `#190`
fails FCM-5 by 19 items and passes FCM-4 by 0 (**D46**).

**GPS is recoverable as shipped - the agent's "gnss dead" inference was wrong.** Android 14's framework
GNSS JNI still walks the HIDL service chain: `platform/frameworks/base/+/android14-release/services/core/jni/gnss/Gnss.cpp`
lines 140-165 try `IGnss_V2_1::getService()`, then `IGnss_V2_0`, then `IGnss_V1_1`, then `IGnss_V1_0`, with
`Gnss.h` including `<android/hardware/gnss/1.0/IGnss.h>` … `2.1/IGnss.h`. Android 14 also still builds the
`android.hardware.gnss@1.0` interface (`hardware/interfaces/gnss/1.0/Android.bp`, non-updatable `hidl_interface`
→ vendor variant installed into `/vendor/lib64`). The OEM Android 10 GPS stack is intact and loadable:

| file in the A10 reference vendor | size | DT_NEEDED (measured, `readelf -d`) |
|---|---|---|
| `/bin/hw/android.hardware.gnss@1.0-service` | 11,656 B | liblog, libcutils, libbase, libutils, libhardware, libbinder, libhidlbase, **libhidltransport**, `android.hardware.gnss@1.0`, libc++ |
| `/lib/hw/android.hardware.gnss@1.0-impl.so` | 96,744 B | liblog, libhidlbase, **libhidltransport**, libutils, `android.hardware.gnss@1.0`, libhardware, libc++ |
| `/lib/hw/gps.default.so` | 37,168 B | liblog, libcutils, libutils, libc++ |

`libhidltransport.so` really exists in Android 14 (`platform/system/libhidl/+/android14-release/Android.bp:121-122`,
`vendor_available: true`), and `libhardware`/`libcutils`/`libutils`/`libbase` all have vendor variants - so GPS
needs **no new HAL code**, only the three files above kept in the restaged vendor. The AIDL `IGnss` interface
exists in Android 14 too (`hardware/interfaces/gnss/aidl/`), and its `default` service is the fixture-based
example (`Gnss.cpp` → `DeviceFileReader`/`FixLocationParser`), i.e. it would report a fake fix, not real
satellites - we do not ship that one.

**Audio input needs three imported libraries plus one Android 14 vendor variant.** Measured DT_NEEDED of
`/lib64/hw/audio.primary.rk30board.so` **and** `/lib/hw/audio.primary.rk30board.so` (both arches are
identical): `liblog libcutils libtinyalsa libaudioutils libaudioroute libhardware_legacy libspeexresampler
libc++ libc libm libdl`. Android 14 *does* build most of them as vendor variants (the research agent said
four were gone): `libtinyalsa` (`external/tinyalsa/Android.bp:19-21`, `vendor_available: true`),
`libhardware_legacy` (`hardware/libhardware_legacy/Android.bp:72-74`, `vendor_available: true`) and
**`libaudioutils`** - which the agent missed: Android 14 builds it in
`platform/system/media/+/android14-release/audio_utils/Android.bp:35-36` with `vendor_available: true`, so
requesting `libaudioutils.vendor` / `libaudioutils.vendor_32` puts it in `/vendor/lib(64)/` with Android 14's
own ABI. Plus `libexpat` (`external/expat/Android.bp:42`) and `libdrm` (`external/libdrm/Android.bp:81,91`)
for the composer path. What Android 14 genuinely does **not** build is `libion` (`system/core/libion` is gone
- directory 404), `libaudioroute` (`hardware/libhardware_legacy/audio/` builds `libaudiohw_legacy` only, no
`audio_route`) and `libspeexresampler` (`external/speexresampler` is gone - directory 404). Byte-exact copies
of all four exist in the Android 10 reference system image (`analysis/daisaita_a10/system.img`, which carries
`/system/lib(64)/` rather than a VNDK APEX):

| soname | 64-bit | 32-bit | its own DT_NEEDED (all resolvable on Android 14) | route |
|---|---|---|---|---|
| `libion.so` | 15,184 B | 15,176 B | liblog, libc++, libc, libm, libdl | prebuilt module, both arches |
| `libaudioroute.so` | 23,680 B | 19,460 B | liblog, libcutils, libutils, libexpat, libtinyalsa, libc++ | prebuilt module, both arches |
| `libaudioutils.so` | 87,376 B | 75,864 B | libcutils, liblog, libspeexresampler, libc++ | Android 14's own vendor variant |
| `libspeexresampler.so` | 24,208 B | 24,108 B | libc++, libc, libm, libdl | prebuilt module, both arches |

The symbol-level check (`nm -D --undefined-only`) says which of these actually carry live calls and which are
only linker obligations, and it is the same list for both arches of the audio blob:
`create_resampler release_resampler` (libspeexresampler), `pcm_open pcm_read pcm_write pcm_close
pcm_get_htimestamp pcm_is_ready pcm_get_error pcm_get_buffer_size pcm_frames_to_bytes` (libtinyalsa),
`property_get property_set str_parms_create str_parms_create_str str_parms_add_str str_parms_get_str
str_parms_has_key str_parms_to_str str_parms_destroy` (libcutils, which Android 14 ships as a vendor
variant). Nothing references `libaudioroute`, `libaudioutils` or `libhardware_legacy` symbols, so those three
only have to *exist* for the linker. `/lib64/librga.so` needs `libion.so` in DT_NEEDED and its own undefined
symbols are `hw_get_module property_get _Znwm _ZdlPv` plus two libc++ symbols - no ion calls, so libion is a
linker obligation for the composer path rather than a symbol dependency.

The route is **modules, not staging-dir injection**: `device/rk3399-px6-hct4/prebuilt_vendor_libs/Android.bp`
declares `libion`, `libaudioroute` and `libspeexresampler` as `cc_prebuilt_library_shared` vendor modules with
arch-specific `lib`/`lib64` srcs, and `vendor_libs.mk` requests them plus `libaudioutils.vendor(_32)`. That is
deliberate: an injected file is not an install dependency, so `build_image.py`'s file filter excludes it and
the *product* vendor.img omits it - pack25 lost an injected `libchrome.so` exactly that way - and the shape-A
build skips `m dist`, so there is no dist-built vendor.img to recover it from. `tools/extract_reference_libs.py`
now also finds libraries under `/system/lib(64)/` (its arch filter used to match only a leading `lib`/`lib64`
directory, which is why the Android 10 system copies were invisible to it).

**Screen and CANBUS are the same class of problem, and both are covered.** `/lib64/hw/hwcomposer.rk30board.so`
(and the 32-bit copy) needs `librga.so`, and `/lib64/librga.so` needs **`libion.so`** - hence the libion
injection above is what protects the display path. `libsync_vendor.so`, `libdrm.so`, `libui.so` (vendor variant)
and the public `libEGL`/`libGLESv2` cover the rest. For CANBUS: `/bin/hw/android.hardware.mtc.mfi@1.0-service`
needs `libhardware_legacy` (Android 14 vendor variant ✓) and `android.hardware.mtc.mfi@1.0.so` - an OEM-custom
interface Android 14 never defines, which the OEM vendor ships itself: `/lib64/android.hardware.mtc.mfi@1.0.so`
167,832 B, `/lib/…` 127,308 B, plus `/lib(64)/hw/android.hardware.mtc.mfi@1.0-impl.so` 33,920 B / 29,124 B.
Those are staged as blobs, not built.

**Audio/composer clients exist in Android 14:** `frameworks/av/media/libaudiohal/Android.bp` keeps
`required: [libaudiohal@4.0, @5.0, @6.0, @7.0, @7.1, @aidl]` with HIDL impls (`DeviceHalHidl.cpp`,
`DevicesFactoryHalHidl.cpp`) in `impl/`, so an audio@5.0 vendor service is still consumable; SurfaceFlinger
keeps composer@2.1 (`HidlComposerHal.cpp`). Not on the owner's criteria and genuinely unusable: `radio@1.1`
(Android 14's RIL types the proxy as `V1_4` - telephony dead), `health@2.0` (healthd links 2.1 only), and the
`soundtrigger`/`cas`/`weaver`/`rockit.hw` entries with no Android 14 client.

**SELinux:** Android 14 ships compat maps for vendor policy versions `29.0` … `33.0`
(`platform/system/sepolicy/+/android14-release/private/compat/` lists exactly those five), so a vendor policy
at 29 maps cleanly. Our build builds its own vendor policy (the generator drops the stock `<sepolicy>` block),
and bring-up stays permissive (**D5**), so neither shape needs the OEM policy file.

**Build-host state measured Nov 15:** the credential wrappers outside the repo were restored (see
`docs/build-host.md`) and the NAS answered (`apollo`, Debian 6.12.107). `SSData` was **100% full** (0 free):
`lineage21s/out` 124 GB, `prebuilts` 60 GB, `.repo` 35 GB, `docker-root` 35 GB. The Nov 8 pass was moved to
cold storage (`cold/vibe-baking/aosp-out-nov15/`: `out-dist`, `out-target-product`, `aospbuild-tmp` packaging
dumps, `out-logs`) with a `payload-sha256.txt` manifest recorded **before** the move, `rc=0` - SSData now has
**9.5 GB free**, which is not enough for a `m dist` pass (dist regrows ~7 GB), so the shape-A build plan
skips `m dist` and builds `superimage`/`bootimage` directly.

## The shape-A boot image was malformed: components are page-aligned, not header-contiguous (Nov 15)

`scripts/rebuild_boot_with_fstab.sh` assembled the coherent image by slicing and writing components
**contiguously from the 1660-byte header size** (`kernel` at 1660, `second` after the previous component).
That is wrong: the layout measured Nov 15 out of four images on disk (`a14-work/hu-stock-backup/boot.bin`,
`a14-work/a14chk/a14-fixed.img`, `a14-work/a14chk/a14-boot-fixed.img`,
`a14-work/a14chk-shapeA/boot-a10k-a14rd.img`) is a header block **padded to `page_size`** (the header struct
is 1660 B, page size 2048 - the pagesize field itself reads 0, meaning the default), then each component
aligned to `page_size`:

| image | kernel | ramdisk | `second` | filesize |
|---|---|---|---|---|
| stock `boot.bin` (`#190`) | 25,671,688 B @ 2,048 | 803,440 B @ 25,675,776 | 924,672 B @ 26,480,640 | 33,554,432 |
| `a14-fixed.img` (A11 kernel) | 30,455,816 B @ 2,048 | 1,631,944 B @ 30,459,904 | 544,768 B @ 32,092,160 | 32,796,672 |
| old `boot-a10k-a14rd.img` | 25,671,688 B @ 2,048 | 1,631,944 B @ 25,675,776 | 924,672 B @ **27,309,144** | 28,231,292 |
| regenerated `boot-a10k-a14rd.img` | 25,671,688 B @ 2,048 | 1,631,866 B @ 25,675,776 | 924,672 B @ **27,308,032** | 28,233,728 |

The offsets were verified by content, not by trusting the header: the gzip ramdisk (`1f 8b`) and the OEM
`second` blob (`52 53 43 45`) sit exactly at the aligned offsets in the stock and A11 images, while the old
coherent image had `00 00 00 00 00 00 00 00` at the offset a boot loader computes (27,308,032) and the real
blob 1,112 B later. So the shipped shape-A image would have handed u-boot/init padding where the **DTB
inside `second`** lives (**D38**) - a black-screen-class failure, the same family as the missing first-stage
fstab (**D34**). `dtb_size` stays 0 at header offset 1648, like the OEM Android 10 image.

The script now computes `page_of()` (offset 56, default 2048), derives
`ko = page`, `ro = ko + roundup(kernel_size, page)`, `so = ro + roundup(ramdisk_size, page)` for both input
images, refuses padding-looking payloads, and **reads the finished image back** the way a boot loader would
before declaring success. Step 1 (`repack_bootimg`) needs `toybox`, which only exists in the AOSP host bin, so
the run happens on the NAS: `HOST_BIN=/srv/dev-disk-by-label-SSData/aospbuild/lineage21s/out/host/linux-x86/bin`
(`out/host/linux-x86/bin/toybox`, 2,476,056 B). Locally `/usr/bin/repack_bootimg` aborts with
`FileNotFoundError: 'toybox'`, which silently left the fstab out of step 1's ramdisk - worth remembering,
because step 2 inherits step 1's output and would then ship a boot image with no fstab.

Regenerated Nov 15 on the NAS (`OUT=/tmp/hu-shapeA-nov15`, log `/tmp/hu-shapeA-nov15.log`, launched
`setsid nohup … > log 2>&1 < /dev/null &`), inputs `pristine-a14-boot.img` `83fd2a15…` and the stock
`boot.bin` `3d2741f04f3185a20f6b3956bff31ff4ce205f1be78e543c7acf79e47be8711f` (byte-identical to the
workstation copy and the NAS archive copy):

* `a14-work/a14chk-shapeA/a14-fixed.img` - 32,796,672 B, sha `933e2ecc42375a3bcac71c23aac610c0c3236ea1448bf05e5ddd3ac03b96e441`
  (the A11 kernel `#24`, shape B; reproduces the sha already recorded in `docs/flash.md`).
* `a14-work/a14chk-shapeA/boot-a10k-a14rd.img` - 28,233,728 B, sha `3cf4012980d0a824c37ed3f24982a9c7e50d2c8c8497030be139e1184a647375`.
  `unpack_bootimg` reports kernel 25,671,688 / `0x10008000`, ramdisk 1,631,866, `second` 924,672 / `0x10f00000`,
  page 2048, header v2, `dtb size: 0`, and the ramdisk carries `first_stage_ramdisk/fstab.rk30board` (4,190 B,
  all five logical entries with `first_stage_mount`). The kernel payload is byte-identical to
  `a14-work/a14chk/oem-kernel.bin` and still reads `Linux version 4.19.111+ … #190 SMP PREEMPT Fri Jul 5 2024`
  (`root@meng_book2`) at offset 14,420,096; `second` is byte-identical to the OEM stock second stage and its DTB
  magic `d0 0d fe ed` sits at 27,310,080 with a size field of 152,425.

The old malformed image is kept, renamed `a14-work/a14chk/boot-a10k-a14rd.img.stale-misplaced-second`
(28,231,292 B, sha head `455a9ac8…`) so the mistake stays auditable; nothing was written to the unit.

## Coupling measured with `tools/payload_coupling_check.py` - both shapes pass against their own vendor (Nov 15)

The new gate reads the artifacts, and its first run is on the reference images on disk (no unit, no build):

| pair | boot layout | kernel | modules in that vendor | verdict |
|---|---|---|---|---|
| shape A: `analysis/daisaita_a10/vendor.img` + `a14chk-shapeA/boot-a10k-a14rd.img` | kernel 25,671,688 B @2048, ramdisk 1,631,866 B @25,675,776, second 924,672 B @27,308,032, `dtb_size 0`, DTB at +2048 size 152,425 | `4.19.111+` (#190) | 21 `.ko`, vermagics `4.19.111+`, `4.19.101+`, `4.4.167`; **all 14 modules `hu_insmod.sh` loads are present at `4.19.111+`** | PASS |
| shape B: `analysis/daisaita_a11/vendor.img` + `a14chk/a14-boot-fixed.img` | kernel 30,455,816 B @2048, ramdisk 1,631,866 B @30,459,904, second 544,768 B @32,092,160, `dtb_size 157,962`, DTB at +1536 | `4.19.193` (#24) | 17 `.ko`, vermagics `4.19.193` and `4.4.167`; the 14 insmod modules present at `4.19.193` | PASS |
| stale `455a9ac8…` image vs the same A10 vendor | second computed at 27,308,032 reads `00 00 00 00 00 00 00 00`; ramdisk has no fstab | `4.19.111+` | - | FAIL (D38 + D34) |

Two things this settles. First, **the vermagic rule is per-module, not partition-wide**: the stock vendor
partitions carry leftovers from other kernels (GPU `.ko` at `4.4.167`, some aic8800-era `.ko` at
`4.19.101+`) which `hu_insmod.sh` never attempts and `insmod` refuses harmlessly, so "every vermagic equals
the kernel" would fail a legitimate payload. What must match is the list the boot script loads - WiFi chips,
`usb_f_iap`/`usb_f_iap2`, `sd_user_hid` - and both vendor partitions supply all fourteen at their own kernel
version. Second, **the Android 11 stock manifest declares `<kernel target-level="5"/>` and the Android 10 one
declares none**, which is exactly why shape A keeps `target-level="4"` without adding a `<kernel>` tag
(**D46**): the gate reports the tag as a fact and fails only if a payload declares a level it is not supposed
to be at. Manifest counts measured here: Android 10 = 26 inline `<hal format="hidl">` declarations + 3
fragments (`cas@1.1`, `weaver@1.0`, `rockit.hw@1.0`), Android 11 = 11 inline declarations, `version="2.0"`,
`target-level="5"`.


## The NAS archive's `ref-a10` is not the firmware the unit runs - restaged from `ref-a10-live` (Nov 15)

W2's first restage used the archive copy `aospbuild-archive/ref-a10/vendor.img` (333,447,168 B, sha
head `b4e50b55…`). It is **not** the Android 10 firmware this head unit has executed. The reference the
unit's vendor blobs were compared against all along is `analysis/daisaita_a10/vendor.img` (323,530,752 B,
sha `3fe2f53aa1f1…`), and its `/lib/modules` holds 21 `.ko`; the archive image holds 10.

| `/lib/modules` | archive `ref-a10` (`b4e50b55…`) | live `analysis/daisaita_a10` (`3fe2f53a…`) |
|---|---|---|
| `.ko` count | 10 | 21 |
| present in both | `8188eu`, `8189fs`, `8723bu`, `8821cs`, `8821cu`, `8822bu`, `8822cs`, `bcmdhd`, `mali_kbase`, `sprdwl_ng` | same ten (sizes differ by a few bytes: `8188eu` 2,251,264 vs 2,251,256 - a different build, not a rename) |
| only in the live image | - | `8188fu`, `8733bs`, `8733bs_ap`, `8821cu_ap`, `aic8800_bsp`, `aic8800_fdrv`, `aic8800_fdrv_ap`, `sd_user_hid`, `usb_f_iap`, `usb_f_iap2`, `virtual_tp` |

Nine of those are the modules `hu_insmod.sh` loads, so the archive tree loses the criteria outright: the
WiFi chips the HU may use (`8188fu`, `8733bs`), the AP6476/aic8800 pair, the USB HID gadget module behind
the steering-wheel/USB input path, and `usb_f_iap`/`usb_f_iap2` (iAP accessory = CarPlay-style input).
`sd_user_hid` is also one of the fourteen. The first restage therefore staged 10 modules at
`vermagic=4.19.101+` into `vendor/hct4/tree_a10/vendor/lib/modules` and echoed that as the module set.

Two fixes came out of this. `scripts/prebuilt_vendor.sh` now treats `REF_IMG`/`BOOT_IMG` as
**authoritative**: it compares sha256 of the existing prebuilt copy with the reference and replaces it
when they differ, instead of reusing whatever was already on disk because it was "not missing" (which is
what silently shipped the wrong tree). And `scripts/deploy_device.sh` now checks the coupling **per
module**: every module named in `configs/hu_insmod.sh` must exist in the staged tree *and* carry the
kernel's version in its vermagic, so a reference missing `sd_user_hid.ko` aborts the deploy before any
build hours are spent. The partition-wide "all vermagics must equal the kernel" rule that was there
before was wrong anyway (stock trees ship `mali_kbase.ko` at `4.4.167` and some aic8800-era `.ko` at
`4.19.101+`, which `insmod` refuses harmlessly), and it also compared a version string that had a
trailing space, which flagged every module as mismatched.

The correct pair is mirrored on the NAS as `aospbuild-archive/ref-a10-live/` (`vendor.img`
`3fe2f53a…` 323,530,752 B, `system.img` `298e8a4c…` 1,275,330,560 B), byte-identical to the workstation
copies. `scripts/package.sh`'s shape-A reference lookup now lists only `ref-a10-live/`, and the stale
`ref-a10/` directory stays untouched as an archive of that other build. Nothing was written to the unit.

## How this board actually loads its kernel modules, and what the OEM insmod step covers (Nov 15, offline)

Read out of the stock Android 10 images rather than guessed, because `hu_insmod.sh` is our own invention
and it has to load exactly what the OEM did:

* The OEM's module list is `/vendor/etc/init.insmod.cfg` (Rockchip's patched init reads it). Measured from
  `analysis/daisaita_a10/vendor.img`, uncommented lines: `bifrost_kbase.ko`, `midgard_kbase.ko`,
  `mali_kbase.ko`, `rk30_mirroring.ko`, `rk29-ipp.ko`, `pvrsrvkm.ko`, `aic8800_bsp.ko` - GPU and
  mirroring only. The commented lines (`ump.ko`, `mali.ko`, `/system/lib/modules/rtk_btusb.ko`,
  `rk30xxnand_ko.ko`, `drmboot.ko`) point at files that do not exist in this partition.
* So the WiFi / USB-HID / iAP modules are **not** loaded by that file. They load through kernel uevent
  auto-loading: `/vendor/lib/modules/modules.dep` lists all 21 modules and `modules.alias` carries the
  modalias strings (`usb:v0BDAp0179d*... 8188eu`, `sdio:c*v024CdF179* 8189fs`, `usbfunc:iap usb_f_iap`
  and `usbfunc:iap usb_f_iap2`, `of:N*T*Carm,mali-midgard* mali_kbase`). Android's init resolves a uevent
  against that alias table and insmod's the match - which is why the running unit has WiFi and an iAP
  gadget without any explicit insmod.
* Two modules have **no alias at all**, so nothing can autoload them: `virtual_tp.ko` (`description=viratul
  tp`, module params `width`/`height`, exports `gaei_virtual_init`) and `sd_user_hid.ko`
  (`drivers/mtc/sd_user_hid.c`, `description=hid driver`, author `xt`, `intree=Y`). Both are MTC-specific:
  the virtual touchscreen device used for phone projection, and the MTCE's USB HID gadget. Neither is in
  `configs/hu_insmod.sh`'s list except `sd_user_hid`, so `virtual_tp` stays unloaded here exactly as it is
  unloaded on the stock firmware - no owner criterion depends on it (touch comes from the built-in
  `CONFIG_TOUCHSCREEN_GT9XX=y` driver, buttons from the HID/CAN path), and it is listed as an unexplored
  piece rather than a gap.
* Our own loader is `configs/init.hu.rc` -> `service hu_insmod /vendor/bin/sh /vendor/etc/hu_insmod.sh`,
  started on `post-fs-data`. LineageOS init does not carry Rockchip's patch, so the explicit list is
  belt-and-braces on top of the uevent path: every load is best-effort and never fatal.

## Soong rejects a prebuilt library that lists both architectures (Nov 15, first shape-A build)

The first shape-A packaging pass died in Soong's bootstrap, before any compile work
(`/srv/dev-disk-by-label-SSData/aospbuild/lineage21s/package.log`, 22:06):

```
error: device/rockchip/rk3399/prebuilt_vendor_libs/Android.bp:36:9: module "prebuilt_libion"
        variant "android_vendor_arm64_armv8-a_shared": srcs: multiple prebuilt source files
error: ... :52:9: module "prebuilt_libaudioroute" ...
error: ... :68:9: module "prebuilt_libspeexresampler" ...
fatal errors encountered
```

`cc_prebuilt_library_shared` takes **one file per variant** - `build/soong/cc/prebuilt.go:126` raises
`multiple prebuilt source files` when a variant sees more than one, so listing `lib64/libion.so` and
`lib/libion.so` together under `compile_multilib: "both"` is illegal. `Srcs` is declared
`android:"path,arch_variant"` (`prebuilt.go:47`), so the supported form is one module named by its
soname with per-arch srcs:

```
compile_multilib: "both",
arch: {
    arm64: { srcs: ["lib64/libion.so"] },
    arm:   { srcs: ["lib/libion.so"] },
},
```

Splitting into two modules instead would install the 32-bit copy under a different file name: none of
these blobs has a `DT_SONAME` (measured during extraction: `lib/libion.so` 15,176 B and
`lib64/libion.so` 15,184 B are "no DT_SONAME"), and Soong falls back to `<module name>.so` when the
ELF carries none. `check_elf_files` is set to `false` on all three: the blobs are the Android 10 ABI and
`DT_NEED` libtinyalsa / libcutils / libexpat, whose Android 14 vendor variants only become resolvable at
install time, and Soong's ELF check runs before that. Fixed in
`device/rk3399-px6-hct4/prebuilt_vendor_libs/Android.bp`; the pass was relaunched at 22:13 with
`SHAPE=a10 SKIP_DIST=1`.

## GPS survives because Android 14's `gnss@1.0` service is a legacy wrapper, not a fixture (Nov 15, source read)

The shape-A restage produced a larger drop list than shape B's: 199 destinations the build installs
itself (the `vendor_build_wins.txt` drop list, generated during the restage and not tracked), among them
`bin/hw/android.hardware.gnss@1.0-service`,
`lib/hw/android.hardware.gnss@1.0-impl.so`, `lib64/hw/android.hardware.gnss@1.0-impl.so`,
`etc/init/android.hardware.gnss@1.0-service.rc`, and the same trio for `sensors@1.0` and
`composer@2.1`. That looked like a GPS criterion break (**D49** says keep the OEM GNSS trio), so the
question was measured in Android 14's source rather than assumed:

* `out/soong/installs-lineage_rk3399.mk:57071` installs
  `vendor/bin/hw/android.hardware.gnss@1.0-service` from
  `hardware/interfaces/gnss/1.0/default` - Android 14 still builds the HIDL 1.0 GNSS service, and
  `device.mk` asks for it (`android.hardware.gnss@1.0-service`, line 170), so the staged OEM binary at
  that path collides and the stock copy loses (the collision rule in **D9**-era tooling: a module built
  from upstream AOSP source wins).
* Android 14's `android.hardware.gnss@1.0-impl` is the **legacy wrapper**:
  `hardware/interfaces/gnss/1.0/default/Gnss.cpp:741` calls
  `hw_get_module(GPS_HARDWARE_MODULE_ID, ...)` and opens the device at 745 - it is not the fixture
  player. The fixture service is Android 14's **AIDL** default (`DeviceFileReader`/`FixLocationParser`),
  which we do not request, and the earlier note in this file already says so.
* The real GNSS comes from the staged OEM module: `lib/hw/gps.default.so` is **not** in the drop list
  (Android 14 builds no `gps.hardware` module), so the wrapper opens the OEM HAL that talks to the
  AP6476/glgps path. `bin/hw/mtc.mfi@1.0-service` (CANBUS), `librga.so` (screen), and
  `lib/hw/audio.primary.rk30board.so` + `lib64/hw/audio.primary.rk30board.so` (sound input) are likewise
  absent from the drop list - only `audio.primary.default.so` and `audio.effect.default.so`-style AOSP
  defaults are replaced.

So **D49**'s intent holds, with one wording correction: the shipped GNSS pair is *Android 14's*
`@1.0-service` + `@1.0-impl` (built here, correct ABI for this framework) loading the *OEM*
`gps.default.so`, not the OEM service binary. That is the stronger arrangement, and the coupling gate
(`tools/payload_coupling_check.py`) checks the three files exist, not who built them; the criterion needs
`gps.default.so` to be the OEM module, which it is. `libkeymaster4support`/`keystore` engine libraries
stay, and the OEM `keymaster@3.0` service + impl + rc were dropped by ckati in this pass - Android 14's
keystore2 cannot drive a keymaster HIDL blob, so the software KeyMint service
(`android.hardware.security.keymint-service`, AOSP `hardware/interfaces/security/keymint/aidl/default`,
linked against `libpuresoftkeymasterdevice`) was added to `device.mk` in the same pass; it installs its
own VINTF fragments for keymint/sharedsecret/secureclock, so the staged Android 10 manifest keeps its
`keymaster@3.0` entry untouched and the payload still declares no `<kernel>` tag.

## Android 14's init never reads `/vendor/etc/init/hw/`, and the `akmd` line that stopped `m superimage` (Nov 16)

`m superimage` (shape A, Nov 15 22:40) aborted in packaging with:

```
host_init_verifier: Command 'mkdir /data/vendor/akmd 0771 akmd akmd'
  (vendor/hct4/tree_a10/vendor/etc/init/hw/init.connectivity.rc:39)
  failed: Unable to decode UID for 'akmd': getpwnam failed
```

Three measured facts, all from Android 14's own source and the stock Android 10 image:

* **How init loads scripts.** `system/core/init/init.cpp:338-356` parses `/system/etc/init/hw/init.rc`
  explicitly, then `ParseConfig("/vendor/etc/init")`. `system/core/init/parser.cpp:159`
  (`Parser::ParseConfigDir`) reads *only* `DT_REG` entries - "Ignore directories and only process
  regular files". So every OEM script under `/vendor/etc/init/hw/` (init.rk30board.rc,
  init.rockchip.rc, init.connectivity.rc, init.rk30board.usb.rc, init.mount_all.rc, init.optee.rc, the
  bootmode scripts) is **inert** on Android 14; Rockchip's OEM init fork had its own loader for that
  directory. `host_init_verifier` still validates the whole vendor image recursively, which is why the
  build failed on a line the running init would never execute.
* **`akmd` is dead config.** Audited against the generated aid table
  (`out/soong/.intermediates/bionic/libc/generated_android_ids/gen/generated_android_ids.h`, 115 names,
  the list `host_init_verifier.cpp:114` matches against `android_ids[]`): 80 staged init scripts and the
  ueventd file reference `audio, audioserver, bluetooth, camera, cameraserver, drmrpc, gps, graphics,
  media, mediacodec, mediadrm, mtp, net_bt, net_bt_admin, nfc, nobody, radio, root, shell, system, wifi`
  - **all valid except `akmd`**, which appears exactly once (connectivity.rc:39). Our own five config
  files are clean. And `akmd` is not in the firmware at all: no `akmd` binary in the Android 10 vendor or
  system partition, no vendor init service names it - the mkdir created a directory nothing reads. Fix:
  `device/rk3399-px6-hct4/configs/init.connectivity.rc` is the stock file byte-for-byte with that block
  removed (diff measured: one line), copied by `device.mk` to
  `$(TARGET_COPY_OUT_VENDOR)/etc/init/hw/init.connectivity.rc`, and `SKIP_DEST` in
  `tools/gen_vendor_staging.py` leaves the staged copy out so the destination is not duplicated.
* **The hw/ scripts are not needed for the owner's criteria.** What they carry is covered elsewhere:
  WiFi's `/data/vendor/wifi` dirs are created by Android 14's own `hostapd.android.rc` (built
  `vendor/etc/init/hostapd.android.rc:10-12`); BT/GPS UART permissions come from our `ueventd` copy
  (`/dev/ttyS0 0660 system system`, `/dev/ttyS1 0660 bluetooth bluetooth`); the HAL services live in
  `/vendor/etc/init/` (top level, e.g. `android.hardware.mtc.mfi@1.0-service.rc` = CANBUS). GPS:
  `lib/hw/gps.default.so` (37,168 B, staged from the OEM partition, not dropped) reads NMEA itself -
  its strings name `/dev/ttyS0`, `/dev/mtc-car`, `nmea_reader_parse`, `nmea_reader_update_sv_status_gnss`
  - and Android 14's `gnss@1.0-service.rc` runs it as `user gps`, `group system gps radio`, so the
  `system`-group ttyS0 is group-readable. **Correction to `docs/head-unit-findings.md`'s hypothesis:**
  there is no `glgps` binary, no `gpsd` binary and no `/system/etc/gps/gpsconfig.xml` in the Android 10
  firmware (`debugfs ls /system/bin` = 138 entries, none matching gps; `/system/etc/gps` does not exist;
  `/bin`, `/etc` are symlinks there), so `service gpsd /system/bin/glgps` in `init.rockchip.rc:149` points
  at a file that never existed. GPS needs no daemon, only the HAL + ttyS0 permissions.
* **The GPU modules in `init.insmod.cfg` are dead on this kernel too** (measured Nov 16 against
  `analysis/hu_kernel_config_live-20261113.txt`): the display pipeline is *built in* -
  `CONFIG_DRM_ROCKCHIP=y`, `CONFIG_DRM_ROCKCHIP_RK618=y`, `CONFIG_MALI400=y` - and there is no
  `CONFIG_MALI_MIDGARD` entry, while the only GPU module in the partition is `mali_kbase.ko` at
  `vermagic=4.4.167`, which kernel `#190` (`4.19.111+`) refuses. Vermagic table of all 21 modules:
  14 modules at `4.19.111+` (the ones `hu_insmod.sh` loads, matching the kernel banner),
  `bcmdhd.ko`/`sprdwl_ng.ko` at `4.19.101+`, `mali_kbase.ko` at `4.4.167` - leftovers the boot script
  never attempts, so the screen criterion rests on the built-in DRM plus `librga.so`/`libion`, not on
  an insmod. Touch likewise: `CONFIG_TOUCHSCREEN_GT9XX=y` is built in.

## Shape C kernel: what the public BSP actually contains, measured during the Nov 16 prepare stage

`scripts/build_hu_kernel.sh prepare` on the NAS (`/srv/dev-disk-by-label-SSData/aospbuild/hu-kernel-4.19`,
`rockchip-linux/kernel` `develop-4.19` at `f39b590ea`) produced these facts:

* **The touch driver's defect is exactly as recorded, and it is a stack array.**
  `drivers/input/touchscreen/gt9xx/gt9xx.c` line 2066 declares `s8 phys[32];`, line 2111 does
  `sprintf(phys, "input/ts");`, and line 2113 assigns `ts->input_dev->phys = phys;`. `input_dev->phys` is
  read by the input core long after probe returns (it is printed by `input_show_phys()` for sysfs and for
  each event), so the dead frame is the Nov 13 panic (`analysis/panic-20261113-2003-ramoops.txt`). The
  prepare step now patches both spellings (variable form and literal form) to
  `ts->input_dev->phys = "input/ts";` - mainline's `goodix.c` uses that literal - keeps a `gt9xx.c.orig`
  next to the file, and aborts if the assignment is not the literal afterwards. `gt9xx_update.c` carries no
  phys assignment, so it is reported and skipped rather than patched.
* **The live config does not round-trip through the BSP tree.** `analysis/hu_kernel_config_live-20261113.txt`
  has 1691 `CONFIG_` lines; after `make olddefconfig` against `develop-4.19` the result has 1717, i.e. 26
  symbols the BSP adds or selects by dependency. The report stage diffs the two sorted lists and counts the
  differing lines, so a shape-C kernel's config drift is measured, not assumed.
* **Host packages the kernel build needs** (`docs/build-host.md`): `bison`, `flex`, `python-is-python3`
  (`make olddefconfig` failed with `bison: not found`, and four BSP scripts invoke `python`), plus a cross
  gcc. Debian 13 ships nothing older than gcc-12 for arm64, while kernel `#190` was built with Linaro gcc
  6.3.1 - so `CC_BIN=/usr/bin/aarch64-linux-gnu-gcc-12` is the closest available match, and the script
  builds a `CROSS_COMPILE` prefix directory of symlinks around it (`CROSS_COMPILE` prefixes every tool, not
  just the compiler).
* **`CONFIG_IKCONFIG_PROC=y` survives olddefconfig**, so `/proc/config.gz` on a shape-C unit still lets us
  compare the running kernel with the config it was built from.

## The second `m superimage` blocker: `verity_load_state`, and the OEM init chain that really runs (Nov 16)

`m superimage` stopped again at 20:09:34, on the next staged script:

```
host_init_verifier: vendor/hct4/tree_a10/vendor/etc/init/hw/init.rk3399.rc: 37: Invalid keyword 'verity_load_state'
host_init_verifier: Failed to parse init scripts with 1 error(s).
```

Measured, not assumed:

* Android 14's builtin command table is `system/core/init/builtins.cpp`'s `builtin_functions` map (starting
  at line 1323). It carries `verity_update_state` (`do_verity_update_state`, line 839) but **no**
  `verity_load_state`, so the parser rejects the file. Audit of all 80 staged init scripts against that map
  plus `service_parser.cpp`'s keyword table (`capabilities class console critical disabled enter_namespace
  file gentle_kill group interface ioprio keycodes namespace oneshot onrestart oom_score_adjust override
  priority reboot_on_failure restart_period rlimit seclabel setenv shutdown sigstop socket stdio_to_kmsg
  task_profiles timeout_period updatable user writepid`, 55 builtin commands) found exactly one rejected
  statement: `init.rk3399.rc:37`. (Three apparent extras were continuation lines of a multi-line command,
  which init joins before parsing.)
* `configs/init.rk3399.rc` is the stock file byte-for-byte minus that statement and its comment (diff
  measured: two lines), shipped by `device.mk` at `$(TARGET_COPY_OUT_VENDOR)/etc/init/hw/init.rk3399.rc`,
  with `SKIP_DEST` dropping the staged copy. dm-verity is not used on this layout (partitions are written
  raw, `docs/flash.md`), and `verity_update_state` on line 13 is valid on Android 14 and stays.
* **The hw/ chain executes.** `/system/etc/init/hw/init.rc:10` imports
  `/vendor/etc/init/hw/init.${ro.hardware}.rc`, the stock kernel cmdline has
  `androidboot.hardware=rk30board`, and `hw/init.rk30board.rc:1-7` imports rockchip/connectivity/
  `${ro.board.platform}` (= rk3399)/optee; `hw/init.rockchip.rc:1-4` imports `${ro.hardware}.usb.rc`,
  `${ro.hardware}.environment.rc`, `init.debug.rc` and `init.mount_all.rc`. So `init.rk30board.rc`,
  `init.rockchip.rc`, `init.connectivity.rc`, `init.rk3399.rc`, `init.rk3399.usb.rc`,
  `init.rk30board.usb.rc`, `init.rk30board.environment.rc` and `init.mount_all.rc` all run; only
  `init.rk30board.bootmode.{emmc,nvme,unknown}.rc` (nothing imports them) are dead. Android 14's
  `ParseConfigDir` ignoring subdirectories only means the *unimported* files are never read.
* **The OEM `service wpa_supplicant` would have displaced Android 14's supplicant.** Android 14's built
  `vendor/etc/init/android.hardware.wifi.supplicant-service.rc` defines a service named `wpa_supplicant`
  too, and `service_parser.cpp:710` ignores the *later* duplicate definition of a service name. init.rc is
  parsed before `/vendor/etc/init` and reaches the connectivity file through the chain above, so the OEM
  definition registers first and Android 14's AIDL supplicant (`interface aidl
  android.hardware.wifi.supplicant.ISupplicant/default`, `socket wpa_wlan0`,
  `-O/data/vendor/wifi/wpa/sockets`) is dropped - WiFi is an owner criterion, so the OEM block is removed
  from `configs/init.connectivity.rc` (its dirs, p2p property mappings, bcmdhd chowns and BT ttyS chowns
  stay). The block's `interface android.hardware.wifi.supplicant@1.0/1.1/1.2` lines are HIDL, which Android
  14's WiFi framework no longer speaks (**D21**), and `bin/hw/wpa_supplicant` is already the AOSP-built
  binary (it is in `vendor_build_wins.txt:182`).

## The third `m superimage` blocker: two malformed HAL names in the OEM vendor manifest (Nov 16)

The relaunched pass (20:34) got bootimage and recoveryimage green again, then stopped inside
`m superimage` on the manifest assembly:

```
FAILED: out/target/product/rk3399/gen/ETC/vendor_manifest.xml_intermediates/manifest.xml
Input file has unknown format.
Error when attempting to convert to manifest: Could not parse element with name <hal> in element
<manifest>: Cannot create FqInstance with package='android.hardware.usb.gadget@1.0', version='1.0',
interface='IUsbGadget', instance='slot1'
```

Measured from the generated `vintf/vendor_manifest.xml` (which is the stock Android 10 manifest
minus the `<sepolicy>` block and the two fragment-carrying HALs):

* Two `<hal>` blocks put the version **inside** `<name>`:
  `android.hardware.usb.gadget@1.0` (instance `slot1`) and `android.hardware.usb@1.1`
  (`<version>1.0</version`, instance `solt1` - a typo for `slot1` in the OEM file). Android 10's
  libvintf tolerated that; Android 14 derives the FqInstance from `<name>` + `<version>`, so the
  whole manifest is rejected. `assemble_vintf` reports only the first bad block.
* Those declarations describe nothing that exists in either firmware generation: `vendor/bin/hw/`
  of the staged Android 10 tree has no usb or usb.gadget HAL binary (`ls ... | grep -i usb` is
  empty), and Android 14 builds none for this device either - the built
  `out/target/product/rk3399/vendor/etc/init/` has only `usb_dongle.rc`, and
  `vendor_build_wins.txt` mentions usb only as `bin/usb_modeswitch`, `etc/init/usb_dongle.rc` and
  `bin/usb_dongle`. Android 14's framework matrices (`system/etc/vintf/compatibility_matrix.5..8.xml`,
  `compatibility_matrix.202404.xml`) list `android.hardware.usb` and `android.hardware.usb.gadget`
  with `optional="true"`, so a missing declaration is not a compatibility requirement. USB on this
  unit is host-mode (usb_modeswitch/usb_dongle), not HAL-driven. `tools/gen_vendor_staging.py` now
  drops every `<hal>` block whose `<name>` contains an `@` (`strip_versioned_names`) and prints the
  dropped names; the regenerated manifest has 24 `<hal>` blocks and parses as XML (checked with
  ElementTree on the local a10 tree).
* The `android.hardware.radio` block has no `<version>` element (only `<fqname>`s) and parses fine,
  so it stays.

## `target-level="4"` on Android 14: no framework matrix at level 4, and nothing runtime reads it (Nov 16)

The generator comment used to say Android 14 ships `compatibility_matrix.4.xml`. It does not. Measured:

* `find out/target/product/rk3399 -name compatibility_matrix.4.xml` returns nothing; the built
  system image ships `compatibility_matrix.5.xml`, `.6.xml`, `.7.xml`, `.8.xml`,
  `compatibility_matrix.202404.xml` and `compatibility_matrix.device.xml` (the device matrix carries
  the one entry we added, `android.hardware.mtc.mfi`, plus the seven HIDL meta entries from the OEM
  matrix; the vendor-side matrix in `VENDOR/etc/vintf/compatibility_matrix.xml` has those 7).
* `system/libvintf/include/vintf/Level.h` still lists `Level::Q = 4` in `kValidLevels`, so a level-4
  manifest parses - `assemble_vintf` accepted ours.
* `VintfObject::checkCompatibility` (`system/libvintf/VintfObject.cpp:993-1014`) partitions the
  matrix fragments by level and, when none matches the device manifest level, returns
  `NAME_NOT_FOUND` with "Cannot find framework matrix at FCM version 4". Grepping
  `checkCompatibility(` across `frameworks/native`, `hardware/interfaces`, `system/core` and
  `build/` finds callers only in `system/libvintf/test/`; the build runs it through `m dist` /
  `otapackage` (`check_vintf_compatible.log`), which stays skipped (`SKIP_DIST=1`, SSData is tight).
* HAL registration is not gated by matrices on this firmware: `system/bin/hwservicemanager` is
  installed and does not use libvintf, and Android 14's AIDL `servicemanager` consults manifests,
  not matrices (`frameworks/native/cmds/servicemanager/ServiceManager.cpp:58-70`,
  `VintfObjectRecovery` + `getDeviceHalManifest`).

So the OEM's `target-level="4"` is kept (it is what the Android 10 firmware ships, and raising or
lowering it changes which HIDL HALs the HU declares); what it costs is diagnostic/CTS accuracy -
`check_vintf`, `lshal` and CTS will report an unsupported FCM level, which is expected for a
vendor staged from Android 10 firmware onto an Android 14 framework.


## Closing the legacy vendor chains: 26 lost destinations, measured one by one (Nov 16)

The three audits run after the converged pass (`SHAPE=a10`) gave the picture, and every line was
re-measured before deciding:

* `tools/vendor_dropped_check.py`: 194 dropped destinations, 150 present in `vendor.img`, 44 absent.
  6 are the already-declared deviations, 12 are "substituted by another provider of the same
  interface" (the HIDL wifi service, the audio 5.0 impls, drm/gatekeeper/keymaster/light/power/cas
  service binaries, `bin/wpa_cli`), and **26 are LOST with no replacement**. Two of those are
  "built OUTSIDE /vendor by Android 14" (`android.hardware.audio.common@5.0-util.so` in `lib/` and
  `lib64/`). 12 of the 26 say "soong defines an install rule, but the module is not in this
  product's install closure"; the remaining 14 say "no module installs this path at all".
* `tools/vendor_abi_check.py`: 28 unresolved symbols on kept blobs - 13 protobuf symbols
  (`_ZN6google8protobuf...`) for `android.hardware.drm@1.2-service.clearkey`, `lib*/libwvhidl.so`,
  `lib*/mediadrm/libwvdrmengine.so`, `lib*/libwebrtc_audio_preprocessing.so`, plus 8
  `gatekeeper::` symbols for `lib*/hw/gatekeeper.rk30board.so` and `lib*/librkgatekeeper.so`.
* `tools/vendor_link_closure.py`: 112 vendor-variant modules requested, 2 not installed -
  `lib/libprotobuf-cpp-lite.so` and `lib64/libprotobuf-cpp-lite.so`.

### Graphics: the screen criterion was silently broken (fixed, D52)

`vendor.img` had `lib*/hw/gralloc.rk30board.so` (the staged Mali blob) but **no mapper and no
allocator impl** - Android 14 defines install rules for
`vendor/lib64/hw/android.hardware.graphics.mapper@2.0-impl-2.1.so`,
`vendor/lib64/hw/android.hardware.graphics.allocator@2.0-impl.so`,
`vendor/bin/hw/android.hardware.graphics.allocator@2.0-service` and its `.rc`, and no module of this
product asks for them, so `vendor_conflicts.py` dropped the staged copies and nothing replaced them.
Android 14's libui then has nothing to talk to:

* `frameworks/native/libs/ui/GraphicBufferMapper.cpp:60-77` tries Gralloc5, Gralloc4, Gralloc3,
  Gralloc2 in order and ends in `LOG_ALWAYS_FATAL("gralloc-mapper is missing")`. None of 5/4/3 is
  installed (Android 14's minigbm AIDL mapper has rules - `vendor/lib64/hw/mapper.minigbm.so`,
  `vendor/etc/init/allocator.rc`, `vendor/etc/vintf/manifest/mapper.minigbm.xml` - but none is in
  the closure), so the HIDL 2.0/2.1 route is the only one that can work with the staged Mali gralloc.
* `frameworks/native/libs/ui/GraphicBufferAllocator.cpp:68-70`:
  `LOG_ALWAYS_FATAL_IF(!mAllocator->isLoaded(), "Failed to load matching allocator for mapper
  version %d")`. SurfaceFlinger aborts in its singleton ctor, so the HU would boot black.
* The impls Android 14 builds are passthrough wrappers over the legacy gralloc HAL:
  `hardware/interfaces/graphics/allocator/2.0/default/passthrough.cpp` and
  `hardware/interfaces/graphics/mapper/2.1/default/passthrough.cpp` both do
  `GrallocLoader::load()`. So installing them wraps the staged `gralloc.rk30board.so` - exactly the
  OEM arrangement, and nothing else needs to change.
* Neither module installs a vintf fragment: `grep -rn vintf_fragments hardware/interfaces/graphics/
  allocator/2.0 hardware/interfaces/graphics/mapper` is empty, and
  `hardware/interfaces/graphics/{allocator/2.0,mapper/2.1}/default/` contains no `.xml`. The OEM
  manifest's `graphics.allocator@2.0` / `graphics.mapper@2.0` blocks stay the only declaration, so
  `assemble_vintf` cannot hit "Conflicting FqInstance".
* The standalone allocator service is restored rather than relying on SurfaceFlinger registering one:
  `frameworks/native/services/surfaceflinger/main_surfaceflinger.cpp:44-63` only calls
  `registerPassthroughServiceImplementation<...IAllocator>()` when
  `android::sysprop::start_graphics_allocator_service(false)` is true
  (`SurfaceFlingerProperties.cpp:151-157`), and nothing in this build sets it
  (`grep -c surface_flinger device/rockchip/rk3399/vendor_props.mk` -> 0). The stock Android 10 init
  script runs the service itself (`vendor/etc/init/android.hardware.graphics.allocator@2.0-service.rc`
  in the staged tree: `service vendor.gralloc-2-0 ...`, `class hal animation`, `user system`,
  `group graphics drmrpc`), which is what lets a /system process reach the allocator through
  hwservicemanager instead of dlopening a vendor library its namespace cannot see. No sysprop is
  added: that would register a second instance of the same interface.
* The HIDL machinery really is running, so the registration is reachable: Android 14 installs
  hwservicemanager in **system_ext**, not system - `find` over target_files gives
  `SYSTEM_EXT/bin/hwservicemanager`, `SYSTEM_EXT/etc/init/hwservicemanager.rc` and
  `SYSTEM_EXT/etc/vintf/manifest/hwservicemanager.xml` - and `SYSTEM/etc/init/hw/init.rc:488-489`
  does `start hwservicemanager` / `start vndservicemanager`. (The D51 note above said
  `system/bin/hwservicemanager`; the binary is in system_ext.)

### protobuf: Android 14 only ships versioned sonames, Lineage's vendorcompat blob is the match

Measured against files dumped out of `vendor.img` with `debugfs -R dump`:

| consumer | protobuf symbols asked for | `libprotobuf-cpp-lite-21.12.so` | `libprotobuf-cpp-lite-3.9.1.so` | Lineage vendorcompat |
|---|---|---|---|---|
| `bin/hw/android.hardware.drm@1.2-service.clearkey` | 36 | 13 missing | 10 missing | **0 missing** |
| `lib64/libwvhidl.so` | 55 | (same lib) | 15 missing | **0 missing** |
| `lib64/mediadrm/libwvdrmengine.so` | 54 | - | - | **0 missing** |
| `lib64/libwebrtc_audio_preprocessing.so` | 47 | - | - | **0 missing** |

* Android 14's vendor variant `libprotobuf-cpp-lite.vendor` installs
  `vendor/lib64/libprotobuf-cpp-lite-**21.12**.so` (module-info: `installed` -> that path), not the
  plain `libprotobuf-cpp-lite.so` the blobs ask for - which is why the closure reported 2 modules
  requested but not installed. Requesting `libprotobuf-cpp-lite-vendorcompat` (and `_32`) instead
  installs `/vendor/lib64/libprotobuf-cpp-lite.so` and `/vendor/lib/libprotobuf-cpp-lite.so`
  (`hardware/lineage/compat/Android.bp:514-528`, `cc_prebuilt_library_shared` over the Android 10
  VNDK v29 blob at `hardware/lineage/compat/vndk/v29/{arm,arm64}/libprotobuf-cpp-lite.so`), so the
  two requests do not collide: different destinations.
* The stock Android 10 firmware ships **no protobuf at all**: `debugfs` over
  `analysis/daisaita_a10/{vendor,system,product,odm}.img` (including `/lib64`, `/lib`,
  `/lib64/vndk-sp`, `/lib/vndk-sp`) returns zero `libprotobuf*`; `vendor_tree` has none either. So
  widevine, clearkey and CAS were already non-functional on the OEM unit. Restoring the soname makes
  the kept blobs loadable on our ROM; it does not resurrect anything that worked there.
* `lib*/mediacas/libclearkeycasplugin.so` asks for both `libprotobuf-cpp-lite.so` and
  `libprotobuf-cpp-full.so` (53 symbols, 23 of them only in *full*: `DescriptorPool::generated_pool`,
  `InternalAddGeneratedFile`). That blob is build-owned (Android 14 installs its own copy), so its
  symbol gap does not apply to us - and no kept blob asks for `libprotobuf-cpp-full.so`
  (scan over every staged, non-dropped ELF: 0 consumers).

### OMX plugin: invisible to the DT_NEEDED walk

`android.hardware.media.omx@1.0-service` (kept and requested) **dlopen**s
`lib*/libstagefright_softomx_plugin.so`, so it is not a DT_NEEDED entry and
`tools/vendor_link_closure.py` could not see it. Android 14 builds the plugin with
`vendor_available: true`, so `libstagefright_softomx_plugin.vendor` / `.vendor_32` put it in
`/vendor/lib64` and `/vendor/lib`. Neither destination is staged (Android 14 defines rules for both,
so the staged copies are dropped), so requesting them cannot collide.

### Gatekeeper: a real gap, not a missing library

* `lib*/hw/gatekeeper.rk30board.so` and `lib*/librkgatekeeper.so` need `libgatekeeper.so`;
  `nm -D --undefined-only` shows the 8 `gatekeeper::` symbols (`EnrollRequest`, `VerifyRequest`
  (j/y variants), `EnrollResponse`, `VerifyResponse` ctors/dtors). No file in the Android 14 tree,
  the Android 10 reference firmware or the Android 11 reference firmware defines them.
* `libgatekeeper.so` is not in the stock Android 10 system partition either
  (`debugfs -R "ls /lib" analysis/daisaita_a10/system.img` has no gatekeeper/keymaster/protobuf
  entry; the image has no `/lib64` at all), so Gatekeeper was already dead on the OEM firmware.
* `libteec.so` (Trusty TEE client) *is* staged and kept, so the TEE half would load - it is
  `libgatekeeper.so` that decides. Android 14 removed Gatekeeper in favour of KeyMint, so the whole
  chain (service rc, `android.hardware.gatekeeper@1.0-impl.so`, `gatekeeper.rk30board.so`,
  `librkgatekeeper.so`, `libRkTeeGatekeeper.so`, x2 arches = 9 paths) is declared in
  `vendor_dest_deviations.txt` instead of shipping files that cannot be dlopened. `libRkTeeWeaver.v1.so`
  and `libRkTeeKeymaster.so` also link `libteec.so` and stay staged.

### light vs power: the legacy HAL lookup decides which one can come back

* power is restored: Android 14's `frameworks/native/services/powermanager/PowerHalLoader.cpp:59-125`
  still loads `IPower` V1_0 and casts up to 1.1/1.2/1.3 after trying AIDL, so the HIDL HAL is a live
  fallback rather than dead code. Android 14's default impl is a passthrough over the legacy `power`
  HAL, and the lookup does find a provider on this unit: it tries `power.<ro.hardware>.so`
  (`power.rk30board.so`, absent) then `power.default.so`, which is staged and present in
  `vendor.img` (`debugfs -R "ls /lib64/hw"` lists `power.default.so` and `power.rk3399.so`).
* light is declared: Android 14's lights are AIDL
  (`frameworks/base/core/java/android/hardware/lights/SystemLightsManager.java`,
  `frameworks/base/services/core/java/com/android/server/lights/LightsService.java`; a grep for
  `light@2` in frameworks/native + frameworks/base finds only tests/jni/Watchdog/VintfObject), and the
  legacy lookup would look for `lights.rk30board.so` or `lights.default.so` while the staged blob is
  `lights.rk3399.so` - nothing opens it, so `light@2.0-service` would fail at impl load and init would
  restart it. Same check for `android.hardware.drm@1.0-impl.so`: the kept DRM services are the 1.2
  ones and Android 14's libmediadrm still has `DrmHalHidl.cpp`/`CryptoHalHidl.cpp`, so a 1.2 factory
  covers 1.0/1.1 instances; the 1.0 service is declared. `cas@1.1-service.rc` likewise: Android 14's
  `cas@1.2-service` (requested) installs its own rc and registers `ICasFactory` at 1.2.
* weaver is **not** a gap: Android 14 builds its own service and impl, and both are already in
  `vendor.img` (`bin/hw/android.hardware.weaver@1.0-service`, `lib*/hw/android.hardware.weaver@1.0-impl.so`),
  so the OEM rc/impl gap is only "Android 14's own copy replaced it".
* `lib*/libwpa_client.so` and `lib*/android.hardware.audio.common@5.0-util.so` have zero consumers:
  a DT_NEEDED scan over every staged vendor ELF that is not dropped returns 0 files linking either,
  and Android 14's built supplicant/hostapd link the AIDL wifi libs instead (full NEEDED lists in
  `vendor_dest_deviations.txt`). Both are declared.


## After the D52 requests: what the same audits say now, and two more gaps (Nov 16, D52b)

The pass launched at 23:06 with the new device.mk (bootimage rc=0, recoveryimage rc=0, superimage rc=0;
`vendor.img` 556,789,760 B sha `62e65d3509...`, `super.img` 2,401,638,464 B sha `a03cb8a8ba...`,
`boot.img` unchanged at 28,012,544 B sha `9605fb9fe6...`). Partition sizes fit the group: system
1,012,871,168 + vendor 556,789,760 + product 456,159,232 + system_ext 384,802,816 + odm 811,008 =
2,411,433,984 against `super_hct_dynamic_partitions_group_size=3258974208`
(`super_super_device_size=3263168512` unchanged, D18/D19 hold - nothing was resized).

* `vendor.img` now contains the restored chain, both arches:
  `bin/hw/android.hardware.graphics.allocator@2.0-service` + `etc/init/android.hardware.graphics.
  allocator@2.0-service.rc`, `lib*/hw/android.hardware.graphics.allocator@2.0-impl.so`,
  `lib*/hw/android.hardware.graphics.mapper@2.0-impl-2.1.so`, `lib*/libprotobuf-cpp-lite.so`
  (alongside Android 14's own `lib*/libprotobuf-cpp-lite-3.9.1.so` and `-21.12.so`, different
  destinations), `lib*/libstagefright_softomx_plugin.so`, and
  `bin/hw/android.hardware.power@1.0-service` + rc + `lib*/hw/android.hardware.power@1.0-impl.so`.
  The gatekeeper files are gone from the image (declared), and the closure shrank to 110 requested
  modules because those blobs are no longer kept (kept staged 137 -> 131, dropped staged 126 -> 132).
* `tools/vendor_dropped_check.py`: 202 dropped destinations, 161 present, 41 absent, **31 of them
  declared deviations**, and the sentence at the end is "every dropped destination is present,
  substituted, or declared as a deviation" - the LOST-with-no-replacement category is empty.
  The tool needed one fix: the "built OUTSIDE /vendor by Android 14" category did not consult
  `vendor_dest_deviations.txt`, so the two declared `android.hardware.audio.common@5.0-util.so` paths
  were still reported as "needs a vendor variant or an injection"; it now skips declared paths
  (`p not in accepted`).
* `tools/vendor_abi_check.py` reports **5 blobs that would not load** (down from the protobuf +
  gatekeeper set, which is resolved):
  * `bin/hw/android.hardware.health@2.0-service` - needs
    `_ZN7android7String8C1ENS0_13StaticLinkageE`, Android 10's libutils `String8(StaticLinkage)`
    constructor, which Android 14's libutils does not export. Provenance measured: the destination is
    staged (copy entry present, `vendor_build_wins.txt` has no line for it), so this is the OEM blob
    really running - init would start it, fail at load and restart it on backoff. Android 14's own
    `android.hardware.health@2.1-service` (+ `lib*/hw/android.hardware.health@2.0-impl-2.1.so`) is
    installed and serves battery info, so the blob is declared (2 paths).
  * `lib*/libomxvpu_enc.so` / `lib*/libomxvpu_dec.so` - need Android 10's libui legacy gralloc1
    exports `GraphicBufferMapper::lock(const native_handle_t*, uint32_t, const Rect&, void**, int*)`
    and `GraphicBufferMapper::unlock`, which Android 14's libui does not have. `libui.so` is public and
    loaded from /system, so injecting an Android 10 libui into /vendor would give a process two copies
    of libui - worse than losing the codec. Their support components are used only by them
    (DT_NEEDED scan over every staged, non-dropped vendor ELF: `libOMX_Core.so` -> 0 consumers;
    `libRkOMX_Resourcemanager.so` -> only `lib*/libOMX_Core.so` + the two plugins;
    `libgralloc_priv_omx.so` -> only the plugins), so the whole Rockchip OMX component set is declared
    (10 paths). Android 14's own OMX service + soft-OMX + the requested software codecs replace it,
    which is why the OMX service and plugin stay restored.
  * The VPU itself is not lost for JPEG: `lib*/libvpu.so` has 6 consumers
    (`lib*/hw/camera.rk30board.so`, `lib*/libjpeghwenc.so`, `lib*/librk_vpuapi.so`), so
    `lib*/libvpu.so` and `lib*/librk_vpuapi.so` remain staged.

Total declared deviations: 48 paths in 16 groups (the Nov 6 owner-accepted RIL/recovery/wifi groups
plus the D52 and D52b engineering groups).


## The corrected super arithmetic, `verify_artifacts.sh` on Nov 17, and the smoke harness's scratch (Nov 17)

* **Partition arithmetic, corrected.** The Nov 16 23:42 pass is system 1,012,871,168 + vendor
  556,072,960 + product 456,159,232 + system_ext 384,802,816 + odm 811,008 = **2,410,717,184 B**,
  inside the unchanged `hct_dynamic_partitions` group whose maximum is 3,258,974,208 B, so
  **848,257,024 B (~809 MiB) spare** - not the 2,411,433,984 / 847,540,224 pair that a note in
  `docs/flash.md` carried, which came from the earlier 23:06 pass where vendor was still 556,789,760 B
  before the gatekeeper/OMX blobs were declared and dropped (556,789,760 - 556,072,960 = 716,800 B,
  exactly the difference). `lpdump` on the flattened container settles it per partition, in 512 B
  sectors: system 1,978,264 / vendor 1,086,080 / product 890,936 / system_ext 751,568 / odm 1,584 =
  4,708,432 sectors = 2,410,717,184 B, group name and maximum unchanged, super device 3,263,168,512 B
  unchanged (**D18**/**D19** - nothing was resized).
* **`scripts/verify_artifacts.sh` on the Nov 16 pass (NAS, Nov 17):** rc=1, and the only two `!`
  lines are the coupling section's, both the same root cause - the *built* `boot.img` has no
  `/first_stage_ramdisk/fstab.rk30board` (**D34**), which makes `tools/payload_coupling_check.py` exit
  non-zero and `verify_artifacts.sh` print "boot image and vendor partition disagree" next to it.
  Everything else in that run passed: dropped-destination check rc=0 (214 dropped / 161 present / 53
  absent / 43 declared, LOST category empty), closure rc=0 (109 modules requested, 0 not installed),
  ABI check rc=0 ("every kept blob resolves its undefined symbols"), `hu_insmod.sh` 14/14 modules
  present with correct vermagic, the four injected libraries in both arches, the criterion HAL files
  (`gnss@1.0-service`, `gnss@1.0-impl.so`, `gps.default.so`), manifest `target-level=4` with 24 inline
  HALs and no `<kernel>` tag, the three check_vintf logs parsing cleanly, and the recovery ramdisk
  carrying `update_engine_sideload` + `libfusesideload.so` + `recovery.fstab`. So the verdict
  "flashable build = NO" is about the *raw* boot image, not the payload: the thing we would flash is
  `a14-work/a14chk-shapeA/boot-a10k-a14rd.img`, which carries the fstab in its ramdisk and passes the
  same gate ("boot image and vendor partition in this payload agree", kernel banner `4.19.111+`,
  21 `.ko`, DTB inside `second`).
* **The super-layout gate was silently not running.** `scripts/check_super.py` opened
  `out/dist/lineage_rk3399-target_files-root.zip` eagerly at the top of its comparison loop, and
  `SKIP_DIST=1` never creates it, so the section died with a `FileNotFoundError` traceback after
  printing only the raw size and group line - the byte-comparison of every logical partition against
  its image, and the `dumpe2fs` proof that the filesystem inside super parses, simply did not happen.
  `verify_artifacts.sh` pipes it through `tail -14` without checking the exit status, so the crash
  never showed up as a `bad` line. Fixed: the zip is opened only when it exists and only as a
  last-resort source (the product dir's raw `<name>.img` and the staging dir's `IMAGES/` are the real
  sources), and the script says so when there is no dist zip.
* **The recovery-installer smoke harness needs ~7 GiB of scratch, not a few MB.** The card copy is a
  real 3,263,168,512 B payload file and `dd` fills the fake super partition with real bytes, so the
  harness peaks near 6.6 GiB. With the default `${TMPDIR:-/tmp/opencode}` on the workstation's `/tmp`
  (a 16 GiB tmpfs with ~4.4 GiB free at that moment) scenario 2 aborted at
  `hu-install: ABORT - dd super failed` - an out-of-space failure, not an installer bug. With
  `TMPDIR=/run/media/Daan/Opslagmonster/a14-work/smoke-tmp` (on `/dev/sda2`, ~439 GiB free) all 8
  scenarios pass: inert without the flag, good manifest, the old sha1 spelling matched to the applet,
  a manifest with no digest line refused, missing size lines refused before writing, a size mismatch
  refused, an oversized payload refused, and a corrupted payload caught before the write. The note is
  now in the script header.


## Shape B re-measured against its own container, and what it does not carry (Nov 17)

The fallback pair was checked against the vendor partition inside its own super, not against the stock
reference image: `a14chk/a14-boot-fixed.img` (sha `933e2ecc…`, kernel payload 30,455,816 B) with the
vendor carved out of `a14chk/raw-super.img` (sha `d4b49909…`, container 3,263,168,512 B) using
`lpdump`'s extents - vendor `0 .. 840847` in 512 B sectors = 430,514,176 B at super offset
1,013,972,992 B, carved with `dd bs=4096 skip=247552 count=105106`. `tools/payload_coupling_check.py` says PASS:

* boot layout: page 2048, kernel 30,455,816 B @2048, ramdisk 1,631,866 B @30,459,904,
  `second` 544,768 B @32,092,160, header `dtb_size 157,962`, DTB magic at +1536 size 157,962.
* kernel banner `4.19.193` (the vendor Android 11 kernel #24); 17 `.ko` in that vendor at vermagic
  `4.19.193` and `4.4.167`; the 14 modules `hu_insmod.sh` loads are all present at `4.19.193`.
* `libion.so`, `libaudioroute.so`, `libaudioutils.so`, `libspeexresampler.so` in both arches;
  `bin/hw/android.hardware.gnss@1.0-service`, `lib/hw/android.hardware.gnss@1.0-impl.so` and
  `lib/hw/gps.default.so` present; manifest `version=8.0`, `target-level=5`, 10 inline HALs and it
  **does** declare `<kernel target-level=5>` - the Android 11 reference manifest behaviour, which is why
  shape B is the FCM-5 route and shape A is the FCM-4 route (**D46**).

What that container does NOT carry, because it is the Nov 11 build and predates **D52**: no
`lib*/libprotobuf-cpp-lite.so` (only `libprotobuf-cpp-lite-3.9.1.so` and `-21.12.so`), no
`lib*/libstagefright_softomx_plugin.so`, no `android.hardware.power@1.0-service` or its impls, and the
Rockchip OMX plugins (`lib*/libomxvpu_{enc,dec}.so`, `lib*/libgralloc_priv_omx.so`) are still present in
it - declared away only in shape A. Its graphics chain is a different, complete one: Android 14's own
`lib*/hw/android.hardware.graphics.allocator@4.0-impl-midgard.so`,
`lib*/hw/android.hardware.graphics.mapper@4.0-impl-midgard.so`,
`bin/hw/android.hardware.graphics.allocator@4.0-service` and its rc, so libui's mapper lookup resolves
at Gralloc4 there instead of through the 2.0/2.1 passthrough wrappers over the staged
`gralloc.rk30board.so`. It also carries `lib*/libgatekeeper.so` and
`bin/hw/android.hardware.gatekeeper@1.0-service.optee`, which shape A declares (D52) because that
library exists in no Android 14 tree. So the conclusion is: shape B is internally coherent
(kernel/modules/manifest agree), but it is not D52-current and must be rebuilt from a `SHAPE=a11`
packaging pass before it is offered as the fallback.

* **The super gate runs now, and passes.** With `TREE=lineage21s` and `WORK` on the cold-storage archive
  (SSData had 5.2 GiB free then, the script peaks ~5.3 GiB), `scripts/check_super.py` on the Nov 16 pass
  printed, per partition, `embedded_matches=True size_matches_extent=True ext4_magic_offset=1080
  debugfs_parses=True` with the offsets `system 1,048,576 / vendor 1,013,972,992 / product 1,570,766,848
  / system_ext 2,027,945,984 / odm 2,412,773,376` and extents exactly equal to the image sizes
  (1,012,871,168 / 556,072,960 / 456,159,232 / 384,802,816 / 811,008), then
  `used inside super: 2,413,584,384 ; spare 849,584,128 (810 MiB)`, `group spare 845,389,824`,
  `group fits inside super_partition_size: True` and `ALL LOGICAL PARTITIONS VERIFIED: True`. It also
  says `no dist target_files zip (...) - comparing against the product dir / staging IMAGES only`, which
  is the new honest note instead of a traceback. The two "used" figures differ from the content total
  2,410,717,184 B because the first partition starts after the super metadata header (system is at
  offset 1,048,576 = sector 2048), so the script counts that region as used.


## Card staging dry-run, and the installer harness per shape (Nov 17)

* `SHAPE=a10 bash scripts/stage_hu_card.sh a14-work/hucheck-card-dryrun` (a plain directory standing in
  for a card - no card was mounted, nothing was connected to the unit) finished with `card staging rc=0`.
  It copied `super-a14.img` 3,263,168,512 B, `boot-a14.img` 28,233,728 B, `hu-install.sh` 13,656 B
  (the installer itself), `update.zip` 4,315 B (route 1's signed package: `updater-script` 1,976 B +
  `a14-notes.txt` 365 B, SignApk comment present), created `hu-install.flag` and wrote a 478 B
  `hu-checksums.txt`, then verified every line by reading the card back: sizes in bytes and 4096 B
  blocks (796,672 / 6,893), and sha256/sha1/md5 for both payloads. The digests it recorded are the
  payload identities we ship: super `d81f913a…` / `ae20fb2cfe8178793bed370b6f148ddca9d588ce` /
  `dc81744b66d70f31d0468c63adc670c2`, boot `3cf40129…` / `9dc876e69528ba4f563c626f518e6e75dde72a1a` /
  `679a750ef09f38628e02bd2d7f16bb9c`. Both payloads are multiples of 4096, so the installer's
  `dd bs=4096` cannot leave a tail unwritten.
* `scripts/smoke_recovery_installer.sh` was shape-blind until now: its fake payload sizes were the
  Nov 11 shape-B pair (boot 32,796,672 B), so it never exercised the shape-A boot payload it is meant to
  protect. It is now `SHAPE=a10` (default) / `SHAPE=a11`, taking 28,233,728 B and 32,796,672 B
  respectively; the super container is 3,263,168,512 B in both, which is the partition size itself
  (**D18**). Measured Nov 17 with a roomy `TMPDIR`: **8/8 scenarios pass in both shapes** (inert without
  the flag, good manifest, the old sha1-style applet spelling, a manifest without a computable digest
  refused, missing size lines refused before writing, a size mismatch refused with the super untouched,
  an oversized payload refused, a corrupted payload caught before the write).
* `scripts/hu_recovery_install.sh`'s card-layout comment said `boot-a14.img` is "vendor A11 kernel
  (4.19.193 #24)" with `vermagic 4.19.193` modules - true only for the fallback. It now names both
  shapes (shape A's `boot-a10k-a14rd.img`, OEM `4.19.111+ #190`, 28,233,728 B, modules at
  `4.19.111+`/`4.19.101+`/`4.4.167`; shape B's `a14-boot-fixed.img`, `4.19.193 #24`, 32,796,672 B) and
  states that `super-a14.img` is always 3,263,168,512 B. Comments only; the logic is unchanged, which is
  why the harness passes identically.
* What route 1's zip does *not* do, restated because it decides the preference: its `updater-script` runs
  `dd if=/external_sd/super-a14.img of=/dev/block/by-name/super bs=4096 conv=fsync` and the same for boot,
  then `make_f2fs.oem -f /dev/block/by-name/userdata` - no digest or size check at all. The card installer
  route (**D43**) is the one that verifies before and after writing.

* `scripts/verify_artifacts.sh` now picks scratch by itself. It runs `check_super.py` with
  `WORK=${WORK:-…/aospbuild/tmp}`, and SSData is routinely below what that section needs, so the gate
  silently failed there before. The script measures `df -Pk "$WORK"` and, when it is under
  5,600,000 KiB (5,468 MiB), switches to the cold-storage archive and prints why. Proven Nov 17 on the
  NAS by forcing a small location: `WORK=/run/hucheck-test` (2,361,912 KiB free) printed
  "scratch: /run/hucheck-test has 2361912 KiB free, the super gate wants 5468 MiB - using
  /srv/50911774-19fb-46b6-bc9e-8cf81623d044/aospbuild-archive/hucheck instead" and the run then produced
  the same report as the explicit-WORK run: five partitions verified, `ALL LOGICAL PARTITIONS
  VERIFIED: True`, the three check_vintf logs parsed, and the only two `!` lines still the D34 pair
  about the raw `boot.img`. With SSData at 7.5 GiB free (after deleting the stale 3.26 GB scratch copy)
  the default location is used and the gate passes there too.


## What is inside the container we would actually flash (Nov 17, carved from `a14chk-shapeA/raw-super.img`)

`vendor.img` on disk is Android sparse, so `debugfs` cannot read it directly; the thing `dd` writes is
the flattened container, so the vendor partition was carved out of it and read there: vendor is at
1,980,416 sectors of the container = byte offset 1,013,972,992, extents `0 .. 1086079` = 556,072,960 B
(`dd bs=4096 skip=247552 count=135760`, which produces exactly 556,072,960 B, and the super gate already
proved those bytes are byte-identical to `vendor.img`). Reading it with `debugfs` confirms every decision
in the partition itself, not in a recipe:

* **D52 restored chain, both arches**: `lib*/hw/android.hardware.graphics.allocator@2.0-impl.so`,
  `lib*/hw/android.hardware.graphics.mapper@2.0-impl-2.1.so`,
  `bin/hw/android.hardware.graphics.allocator@2.0-service` + `etc/init/…allocator@2.0-service.rc`,
  `lib*/libprotobuf-cpp-lite.so` (next to Android 14's own `-3.9.1.so` and `-21.12.so`),
  `lib*/libstagefright_softomx_plugin.so`, and `bin/hw/android.hardware.power@1.0-service` + rc +
  `lib*/hw/android.hardware.power@1.0-impl.so`.
* **D52b declared gaps are really absent**: no `lib*/hw/gatekeeper.rk30board.so`, no
  `lib*/librkgatekeeper.so`, no `lib*/libRkTeeGatekeeper.so`, no `lib*/libomxvpu_{enc,dec}.so`, no
  `lib*/libOMX_Core.so`, no `lib*/libRkOMX_Resourcemanager.so`, no `lib*/libgralloc_priv_omx.so`, no
  `bin/hw/android.hardware.health@2.0-service` - battery info comes from
  `bin/hw/android.hardware.health@2.1-service` + `lib*/hw/android.hardware.health@2.0-impl-2.1.so`.
  What stays of the VPU is `lib*/libvpu.so` (JPEG/camera path) and the staged
  `lib*/hw/gralloc.rk30board.so` that the 2.0/2.1 passthrough wrappers load.
* **D50's edited init copies are the shipped ones**, at `/etc/init/hw/`: `init.connectivity.rc` (3,372 B)
  carries the two deviation comments and no `mkdir /data/vendor/akmd` (the stock staged copy has that
  mkdir at line 39) and no OEM `service wpa_supplicant` block; `init.rk3399.rc` (3,189 B) has no
  `verity_load_state` (stock has it at line 37). Both were removed because Android 14's init rejects
  those lines outright, which is what stopped `m superimage` on Nov 16. The rest of that directory is the
  OEM chain kept as staged: `init.mount_all.rc`, `init.optee.rc`, `init.rk30board.rc`,
  `init.rk30board.environment.rc`, `init.rk30board.usb.rc`, `init.rk3399.usb.rc`,
  `init.rk30board.bootmode.{emmc,nvme,unknown}.rc`, `init.rockchip.rc`.
* `/etc/init` has 30 `.rc` files, including the criterion ones: `android.hardware.gnss@1.0-service.rc`,
  `android.hardware.mtc.mfi@1.0-service.rc` (CANBUS), `android.hardware.audio.service.rc` +
  `android.hardware.audio@2.0-service.rc`, `android.hardware.wifi-service.rc`,
  `android.hardware.wifi.supplicant-service.rc`, `hostapd.android.rc`, the camera provider pair,
  `android.hardware.media.omx@1.0-service.rc`, plus our own `hu.rc` and `hu-adb.rc`,
  `vndservicemanager.rc` and `vendor_flash_recovery.rc` (declared: it re-flashes recovery from
  `/vendor/recovery-from-boot.p`, which is not staged).
* `/etc/vintf` holds `manifest.xml` + `compatibility_matrix.xml` (the device matrix) - the same bytes the
  coupling gate read, `target-level=4` with no `<kernel>` tag (**D51**).


## The coupling gate now checks the criterion chain itself (Nov 17)

`tools/payload_coupling_check.py` only demanded the four injected libraries and the three GPS files by
default, so a payload could PASS while silently missing the screen chain or the CANBUS service. Its
defaults are now the contract we ship:

* `--expect-libs` adds `libprotobuf-cpp-lite.so` and `libstagefright_softomx_plugin.so` (both arches) -
  the two sonames Android 14 either installs under a versioned name or not at all (**D52**).
* `--expect-files` adds the CANBUS service (`bin/hw/android.hardware.mtc.mfi@1.0-service`,
  `lib/hw/android.hardware.mtc.mfi@1.0-impl.so`, `lib/hw/mfi.default.so`), the audio HAL
  (`lib/hw/audio.primary.rk30board.so`), the whole graphics chain the screen criterion needs
  (`lib*/hw/gralloc.rk30board.so`, `lib*/hw/android.hardware.graphics.mapper@2.0-impl-2.1.so`,
  `lib*/hw/android.hardware.graphics.allocator@2.0-impl.so`,
  `bin/hw/android.hardware.graphics.allocator@2.0-service`), plus
  `bin/hw/android.hardware.media.omx@1.0-service` and `bin/hw/android.hardware.health@2.1-service`
  (battery comes from Android 14's service, not the Android 10 2.0 blob - **D52b**). GPS stays first.

Measured with those defaults, no flags:

* **shape A passes against the flashed container** (`a14chk-shapeA/raw-super.img`'s vendor carved at
  offset 1,013,972,992, 556,072,960 B) with `boot-a10k-a14rd.img`: kernel `4.19.111+`, 21 `.ko`,
  14/14 `hu_insmod.sh` modules, both injected lib sets, all 15 criterion files, manifest
  `target-level=4` with no `<kernel>` tag - PASS.
* **shape A passes against the built `vendor.img` too**, inside `scripts/verify_artifacts.sh` on the NAS
  (the sparse image is converted by the tree's `simg2img`), and that run still fails only on the D34
  pair about the raw `boot.img`.
* **shape B's Nov 11 container now FAILS the contract**, which is the honest result and the reason it
  must be rebuilt: `/lib64` and `/lib` lack `libprotobuf-cpp-lite.so` and
  `libstagefright_softomx_plugin.so`, and the graphics criterion files are missing - that vendor carries
  Android 14's midgard 4.0 impls and no staged `gralloc.rk30board.so` at all, so its mapper route is
  Gralloc4 rather than the 2.0/2.1 passthrough wrappers. Its kernel/module/manifest coupling is still
  coherent (14/14 modules at `4.19.193`, `<kernel target-level=5>`), so the failure is about the D52
  restorations, not about shape B's shape.

* `scripts/verify_artifacts.sh` passes the criterion list per shape now: shape A uses the tool's default
  list (the 2.0/2.1 passthrough chain), shape B passes its own - `lib*/hw/gralloc.default.so`,
  `lib*/hw/android.hardware.graphics.mapper@4.0-impl-midgard.so`,
  `lib*/hw/android.hardware.graphics.allocator@4.0-impl-midgard.so`,
  `bin/hw/android.hardware.graphics.allocator@4.0-service` (the Android 11 vendor tree ships those as
  staged copies and Android 14 defines no install rule for the `-impl-midgard` names, so the staged blobs
  win), plus the same GPS/CANBUS/audio/OMX/health files. Measured Nov 17 against the carved vendor of the
  Nov 11 shape-B container with that list: **every criterion file present**, kernel `4.19.193`, 14/14
  insmod modules, manifest `target-level=5` with `<kernel>` - and the only two failures are
  `lib*/libprotobuf-cpp-lite.so` and `lib*/libstagefright_softomx_plugin.so`, the two sonames the Nov 16
  requests added (D52) after that container was built. So a `SHAPE=a11` packaging pass, which carries the
  same shape-independent `PRODUCT_PACKAGES` blocks, would close both and pass the whole gate; the Nov 11
  container on disk cannot.

## Live session Nov 17 19:21-19:30 CET: permanent TCP adb, and the W4 probes (read-only)

The unit came back online after the owner re-ran `adbon` (**D28**), then the owner asked to make adb
permanent ("make adb on permanent for now"). Measured read-only over `adb root`, nothing written.

**adb is permanent, and the reboot proved it.** `persist.internet_adb_enable` is stored in
`/data/property/persistent_properties` (`strings` shows the key at line 55), and
`/vendor/etc/init/hw/init.rk30board.rc:250-257` reacts to it:

```
on property:persist.internet_adb_enable=1
    setprop service.adb.tcp.port 5555
    restart adbd
on property:persist.internet_adb_enable=0
    setprop service.adb.tcp.port 0
    restart adbd
```

Deliberately rebooted the unit and reconnected without touching the RSA dialog: `uptime` 1 min,
`persist.internet_adb_enable=1`, `service.adb.tcp.port=5555`, `adbd` pid 1038 (uid `shell`) listening,
`adb root` -> uid 0 `u:r:su:s0`. Two caveats worth keeping in mind: the property lives in `/data`, so a
factory reset kills it (and our own install route wipes `/data` per **D10**, so adb must be re-enabled
after our payload boots), and the off switch is `setprop persist.internet_adb_enable 0`.

**The serial numbers disagree.** `ro.serialno` = `D5362B7F96DAB676` (the value every earlier probe
reported), `ro.boot.serialno` = `c3bc6b060ec025bb` (what the kernel command line passes as
`androidboot.serialno`). Something in the OEM init chain overrides `ro.serialno` after boot. Recorded as
a fact, not a defect: our payload sets `ro.serialno` from the same source the OEM init does, so the
apps that key on the serial (MicronTEK services, the head-unit apps) keep seeing the familiar value.

**A clean boot in pstore.** `/sys/fs/pstore` holds `console-ramoops-0` (107,830 B) and
`pmsg-ramoops-0` (262,132 B), timestamped 19:21, i.e. the boot that just happened. Head of the console
log: `Linux version 4.19.111+ (gcc 6.3.1 Linaro GCC 6.3-2017.05) #190 SMP PREEMPT Fri Jul 5 14:39:56 CST
2024`, `Machine model: Rockchip RK3399 HCT Board` - the same **#190** banner that `boot-a10k-a14rd.img`
and the stock backup's `boot.bin` carry. `grep -c 'Unable to handle kernel\|Kernel panic\|gt9xx'` = **0**,
so the Nov 13 `gt9xx` fault did not fire on this boot (**D45** stays accepted).

**Input devices right now:** `mtc-key` -> `event0`, `goodix-ts` -> `event1`, `gpio-keys` -> `event2`, three
devices, each with handlers `eventN cpufreq`. The HID/virtual devices (`sd_user_hid.ko`, `virtual_tp.ko`)
are absent this boot because those modules are not loaded - `lsmod` again lists only `usb_f_iap2`
(20480, used by 2), `8188eu` (1,253,376), `aic8800_bsp` (45,056). Touch is `event1` as before.

**`/dev/ion` exists, `/dev/dma_heap` does not.** `/dev/ion` is `crw-rw-rw-` major 10 minor 63, label
`u:object_r:ion_device:s0`; `/dev/binder` is major 10 minor 48, `u:object_r:binder_device:s0`;
`/dev/dma_heap` is "No such file or directory". Confirmed against the running kernel's config
(`analysis/hu_kernel_config_live-20261113.txt`): `CONFIG_ION=y`, `CONFIG_ION_SYSTEM_HEAP=y`,
`CONFIG_ION_LEGENCY=y` + `CONFIG_ION_LEGENCY_ROCKCHIP=y`, `CONFIG_DMA_CMA=y`, and **no `DMA_HEAP`
option at all**. So the allocator/mapper chain shape A ships (gralloc.rk30board + allocator@2.0/mapper@2.1
passthrough, ION-backed) is the only graphics route this kernel can serve; Android 14's dmabuf path and
shape B's midgard 4.0 impls would need a kernel with dma-heaps, which this 4.19.111+ build does not have.

**WiFi link measured:** `iw dev wlan0 link` -> connected to `4c:ed:fb:a5:08:01`, SSID `hoefijzer`,
`freq: 2417`, `signal: -56 dBm`, `tx bitrate: 150.0 MBit/s`. The Nov 13 "~99/99 at -44 dBm" note stays
unverified; this is the current live figure.

**The link then dropped because wireless Android Auto started - not because of a crash.** The owner
reports Android Auto fired up and WiFi dropped; `ping 192.168.1.120` -> Destination Host Unreachable.
The RTL8188EU dongle is a single 2.4 GHz radio, so wireless AA and the LAN adb route cannot coexist:
probing pauses whenever AA runs, and no kernel panic occurred (this is the measurement **D45** was
waiting on - the framework-restart trigger did not recur).

**CANBUS service is alive on stock:** `android.hardware.mtc.mfi@1.0-service`, pid 290, uid `system`,
state `binder_thread_read`. `/dev/mtc-car` exists (`crw-rw-rw-`, 10,55). That is the criterion chain
**D50** ships in the manifest and **D55**'s coupling gate now demands.

**GPS: the chain runs, the wire carries data, and there are zero fixes - with the antenna unplugged.**
`android.hardware.gnss@1.0-service` pid 282 uid `gps`, fd 8 -> `/dev/ttyS0` (the HAL really holds the
port); `/vendor/lib64/hw/gps.default.so` 32,440 B; `/dev/ttyUSB*` absent. `dumpsys location` for the gps
provider: `mTopHalCapabilities=0x1 ( SCHEDULING )` only, `mGnssMeasurementsProvider.isRegistered()=false`,
`mGnssNavigationMessageProvider.isRegistered()=false`, `native internal state: null`, and the whole
GNSS_KPI window (start +18s685ms -> end +3m26s320ms) reports **0 location reports, 0 TTFF, 0 position
accuracy reports, 0 CN0, 0 sv-status messages**. Clients do request fine GPS:
`android.microntek.service`, `com.telenav.launcher`, `com.google.android.apps.maps` all hold
`ACCURACY_FINE` records. `/proc/tty/driver/serial` counts: port 0 (`mmio:0xFF180000 irq:36`)
`tx:70 rx:55755 RTS|DTR`, port 1 (`0xFF190000`) `tx:41061 rx:61508`, port 4 (`0xFF370000`)
`tx:5062 rx:7728`.

Interpretation: **55,755 received bytes on UART0 means the GPS module is powered and streaming even with
no antenna** - the hardware path is intact, and the owner confirms the antenna is not connected right now,
so zero fixes is expected and **D49** cannot be validated on this bench until the antenna is fitted. The
other side is worth watching on the next antenna-connected session: `tx:70` in three minutes means the HAL
writes almost nothing to the module, so if the module needs an initialisation/NMEA command sequence the
zero-fix result is not *only* an antenna problem. The Android-14-relevant part of this measurement is the
HAL leg, and it is good: Android 14's `gnss@1.0` legacy wrapper is exactly the service that runs here and
holds `/dev/ttyS0`, so shape A's staged `gps.default.so` chain is coherent with what stock does.

**Sensors HAL: the exit-255 loop has a mundane cause (open question 5).** `logcat -s SensorsHal` shows the
HAL (pid 292) alive and looping every ~27 s:

```
I SensorsHal: set batch: handle = 0, period_ns = 20000000ns, timeout = 0ns
D SensorsHal: Couldn't open /dev/mma8452_daemon (No such file or directory)
I SensorsHal: MmaSensor update delay: 20ms
E SensorsHal: fail to perform GSENSOR_IOCTL_APP_SET_RATE, result = -1, error is 'Bad file descriptor'
```

`/dev/mma8452_daemon` does not exist, yet the kernel has the driver built in:
`CONFIG_SENSOR_DEVICE=y`, `CONFIG_GSENSOR_DEVICE=y`, **`CONFIG_GS_MMA8452=y`** (config lines 2083-2086).
So the driver is compiled but never created its daemon node - no I2C probe/DT node for the accelerometer on
this board - and the HAL cannot set its sample rate. Sensors are not on the owner's criteria, and in this
session's logcat window the HAL stays running rather than exiting 255, which weakens the "sensors HAL dies
and cascades the framework restart" hypothesis behind **D45**.

### Follow-up probes on the same session (after Android Auto released the radio)

`lshal` shows the interfaces the criteria depend on, live: `android.hardware.gnss@1.0::IGnss/default`
(pid 282), `android.hardware.graphics.allocator@2.0::IAllocator/default` (pid 283),
`android.hardware.health@2.0::IHealth/default` (pid 285), `android.hardware.audio@5.0::IDevicesFactory`
and `audio.effect@5.0::IEffectsFactory` (pid 273), and
`android.hardware.mtc.mfi@1.0::IMfi/default` (pid 290) marked **`N`** - the CANBUS service runs but is
**not declared in the vendor manifest**, exactly the gap **D50/D51** close in our payload. No `glgps`
process exists on this firmware (`ps -A | grep glgps` empty), so the vendor tree's `glgps` mention is
inert here; the GNSS path is the HIDL service alone.

UART0 is genuinely streaming: `/proc/tty/driver/serial` port 0 went `rx:445768 -> rx:448018` over a 10 s
window (**+2,250 B, ~225 B/s**), while `tx` stayed at **70**. So the module emits data continuously and
the HAL writes essentially nothing to it - no NMEA/init command sequence. With the antenna unplugged that
is consistent with zero fixes; with the antenna fitted, `tx` is the number to watch, because a module that
needs host commands would still produce no fix.

## Stock backup refresh on Nov 17, and what actually changed since Nov 11 (read-only)

`scripts/pull_stock_backup.sh` ran against the live unit over TCP adb and produced
`a14-work/hu-stock-backup-refresh/` (3.3 GiB, `MANIFEST.sha256` with 13 files, relative paths so it
verifies anywhere). The Nov 11 backup `hu-stock-backup/` is untouched and its own manifest still checks
clean (`sha256sum -c` = all OK). Pull order: `disk-head-8mb.bin` `2958aec000c3`, `disk-tail-gpt.bin`
`f423cdce2c87`, then by-name partitions: `uboot.bin` `a28fd6a0e6c6`, `trust.bin` `7f2c4e52e595`,
`misc.bin` `909bdd979111`, `dtb.bin` `bb9f8df61474`, `dtbo.bin` `e5c1d28c4b6f`, `vbmeta.bin`
`76ff77959f24`, `boot.bin` `4121b58f7759`, `recovery.bin` `1fdf5ea77fc6`, `security.bin`
`6ff044d01c2b`, `metadata.bin` `055d780c5cae`, `frp.bin` `07854d2fef29`, `super.bin`
`11e91ea677e1` (3,263,168,512 B).

Five shas differ from the Nov 11 capture, and each was located byte-wise (`cmp -l` + a 1 MiB chunk
diff), so the story is measured rather than guessed:

* **`uboot.bin`, `trust.bin`, `dtb.bin`, `dtbo.bin`, `vbmeta.bin`, `security.bin`, `recovery.bin`,
  `frp.bin`, `disk-tail-gpt.bin` are byte-identical** - the boot chain, DT partitions, AVB metadata and
  the backup GPT are exactly what they were on Nov 11. `recovery.bin` is still `1fdf5ea77fc6`, which is
  the stock recovery the D42 patch works on.
* **`super.bin` differs only in its first 2 MiB.** A 1 MiB chunk diff finds exactly two differing chunks
  (offsets 0 and 1 MiB); every logical partition's bytes beyond that are identical to Nov 11. So the
  dynamic-partition *content* is unchanged, only the metadata region moved - the Nov 13 re-flash of the
  OEM package (`**D39**`) re-ran `update_dynamic_partitions`, which rewrites super's metadata header.
* **`metadata.bin` changed** (`8814f72c8d45…` -> `055d780c5cae…`): that partition is update_engine's
  own metadata store, rewritten by the same restore.
* **`boot.bin` differs by 1,625,326 bytes, entirely inside boot's second stage.** Kernel bytes are
  identical (sha `a514a3ffb77e`, banner still `#190`), the first-stage ramdisk is identical, and the DTB
  inside `second` is identical - magic at `second+1,633,792`, totalsize 157,962 B, sha `530b84129eb0` in
  both captures. The difference sits in the ~1.63 MB blob *before* that DTB (`second` region
  30,459,904..32,092,092). That is the blob the OEM package's `boot.bin` carries and the Nov 13 re-flash
  wrote, versus the byte-exact capture taken from the unit on Nov 11. Both boot today with a working
  screen, so neither is broken; but **the rollback image for partition 7 is now the refreshed
  `boot.bin` (`4121b58f7759`), not the Nov 11 `3d2741f0…`**, because that is what the unit boots right
  now. Shape A's `boot-a10k-a14rd.img` was rebuilt from the Nov 11 capture, so its `second` stage carries
  the Nov 11 blob; the DTB it needs is the same bytes either way (`530b84129eb0`, **D38**).
* **`disk-head-8mb.bin` differs by exactly 20 bytes**, at offsets 33,305 / 33,307 / 34,289 / 34,290 and
  the same pattern every 524,288 bytes (557,593 / 1,081,881 / 1,606,169 / 2,130,457 …). The context is
  the Rockchip loader area marked `RK28`, and the changed bytes are its version/date fields
  (`…24 01 04` -> `…26 01 05`, `44 56` -> `46 56`). The partition payloads themselves are unchanged
  (`uboot.bin`/`trust.bin` identical), so the Nov 13 re-flash touched only the loader copies' version
  fields, never the boot chain's payload. Our routes never write that area (**D18**/**D19**), and the
  refreshed head file is kept as a record of what the disk holds today.

The pull script's own guard held: it refused nothing, required `adb shell id` = uid 0 and the fingerprint
`QQ2A.200305.004.A1`, so this is a backup of the known-good firmware. Nothing was written to the unit.

## Shape B rebuilt with the D52 requests, and what its gate says now (Nov 17)

`SHAPE=a11 SKIP_DIST=1 scripts/package.sh` ran on the NAS at 20:09-20:33 CET: `m bootimage` and
`m recoveryimage` rc=0, `m dist` skipped, `m superimage` rc=0. Products: `boot.img` 32,796,672 B
(sha `cf05255148b8…`, kernel `4.19.193`), `recovery.img` 44,689,408 B, `vendor.img` 432,275,456 B,
`system.img` 1,012,871,168 B, `product.img` 456,159,232 B, `super.img` 2,277,550,048 B
(sha `2a1246aaf055…`), group 3,258,974,208 B with 2,289,852,416 B used (spare 969,121,792 B).
`scripts/verify_artifacts.sh` with `SHAPE=a11` reports:

* `ALL LOGICAL PARTITIONS VERIFIED: True`, group fits inside `super_partition_size` True, VINTF
  vendor/system/device manifests all "Successfully processed".
* **Coupling: PASS on everything except the D34 pair.** 17 `.ko` at vermagic `4.19.193` (+ one
  `4.4.167`), `hu_insmod.sh` 14/14 present at the right vermagic, manifest `target-level=5` and it
  *declares* `<kernel>`, and the criterion list is fully satisfied: `/lib64` **and** `/lib` now carry
  `libion`, `libaudioroute`, `libaudioutils`, `libspeexresampler`, **`libprotobuf-cpp-lite.so`** and
  **`libstagefright_softomx_plugin.so`**, and every criterion HAL file is present (GPS, CANBUS MTC,
  audio, `gralloc.default.so`, the midgard 4.0 mapper/allocator impls, the allocator service, the OMX
  service, `health@2.1-service`). So the two failures **D55** measured against the Nov 11 container are
  gone - the packaging pass closed them, exactly as predicted.
* The only coupling failures are `boot.img ramdisk has no first_stage_ramdisk/fstab.rk30board (D34)` and
  the derived "do not flash this pair" line. Shape B needs the same fstab rebuild shape A got
  (`scripts/rebuild_boot_with_fstab.sh`) before it can be offered.
* **New gap found: `lib64/libhwbinder.so`.** The Android 11 vendor tree ships it (10,824 B staged), Android
  14 has no VNDK and builds `libhwbinder` for `/system` only with no vendor variant, so the destination
  cannot be restored by a module. Measured, not assumed: scanning every `*.so` and every `bin/hw/*`
  binary in shape B's `target_files` VENDOR set for a `DT_NEEDED libhwbinder.so` found **zero
  consumers**, and the same scan over the staging tree found zero. So it is declared absent in
  `device/rk3399-px6-hct4/vendor_dest_deviations.txt` (now 49 declared paths) rather than injected - an
  injected copy would be dead weight in `/vendor`. Shape A never had this destination, which is why the
  Nov 16 closure came out LOST-empty.
* `vendor_diff.py` still says "only the intended changes = False": `etc/usb_modeswitch.d/*` destinations
  are missing from the built vendor (build-owned paths), and the intended size changes are the two
  edited OEM init copies plus the cas/health/hostapd manifest fragments.
* The OTA zip is still the stale Nov 8 one (`931bbb45…`), because `m dist` is skipped.

`VERDICT: flashable build = NO` for shape B today, for the D34 fstab reason only once the declared
libhwbinder gap is counted - the criterion chain, module coupling and manifest are coherent.

### Shape B's gate, run against the fstab-injected boot (Nov 17 21:22-21:30 CET)

`scripts/rebuild_boot_with_fstab.sh` ran on the NAS with the new shape-B `boot.img` as `SRC_BOOT` and the
archived stock `boot.bin` as `OEM_A10_BOOT`, into `aospbuild/hu-a11-repack/`. It produced
`a14-fixed.img` 32,796,672 B sha `55be70ab423c…` (kernel `4.19.193 #24`, DTB 157,962 B inside `second`,
ramdisk carrying `first_stage_ramdisk/fstab.rk30board` 4,190 B with five logical `first_stage_mount`
rows) and a fresh `boot-a10k-a14rd.img` 28,233,728 B sha `c9f0f9fe434f…`. The latter is the same size and
the same kernel bytes (`a514a3ffb77e`) as the gated shape-A artifact `3cf40129…`, but its first-stage
ramdisk differs because today's build regrows it after the D52/D52b requests - the gated shape-A pair
stays `3cf40129` + container `d81f913a`, and nothing was flashed.

`scripts/verify_artifacts.sh` gained a `BOOT` override (`BOOT=${BOOT:-$PROD/boot.img}`) so the coupling
gate can read the repacked image without rebuilding the pass. With `SHAPE=a11 BOOT=<a14-fixed.img>` it
reports `PASS: boot image and vendor partition in this payload agree` and `VERDICT: flashable build =
yes`. Measured artifacts: `vendor.img` 432,275,456 B sha `90ed4009ce96…`, `super.img` 2,277,550,048 B
sha `2a1246aaf055…`, raw `boot.img` sha `cf05255148b8…`, `recovery.img` 44,689,408 B sha
`eb0f86b37bf7…`. What remains non-blocking is informational only: `vendor_diff.py`'s
"only the intended changes = False" (build-owned `etc/usb_modeswitch.d/*` destinations plus the intended
init/manifest edits) and the stale Nov 8 OTA zip (`931bbb45…`, since `m dist` is skipped).

## Nov 18 - the two payload writes, and the offline re-measure that corrected four claims

### The two writes, both failing

| attempt | boot image | sha256 | super image | sha256 | what the panel showed |
|---|---|---|---|---|---|
| 1, ~10:25 | `boot-diag.img` 28,233,728 B | `85dd11383ca132ec68196fbdbdc9ee8fad6af5028ed4430aefc382b84b71f409` | `super-diag.img` 3,263,168,512 B | `da9961f757dd6a3d7cb9682f30b9585d99bb2124f5ec6c57352c6f0ce70fe2dc` | OEM boot logo only, repeating in a loop; no animation, no text. The SD logger (`hu_sdlog.sh`, hung off `early-fboot`/`early-boot`) wrote **nothing** to the card |
| 2, ~11:05 | `boot-min.img` 28,233,728 B | `3cf4012980d0a824c37ed3f24982a9c7e50d2c8c8497030be139e1184a647375` | `super-min.img` 3,263,168,512 B | `354ce4c5b08e4ea8b61ef3c48e78114bd6ea1cbd08c117b5b0533d16c5080417` | completely black - no logo, no animation |

Only `boot` + `super` were written (**D18**/**D19**), no wipe, and the owner restored Android 10 with their
own route afterwards; `/data` was never formatted. Both images sit in `a14-work/a14diag/` with
`sha256.txt`.

### What the two attempts actually prove, and what they do not

* The logo is drawn by **u-boot/trust**, from the RSCE blob in the boot image's `second` stage and the
  board's `reserved-memory/drm-logo` region, before Android exists. Android's boot animation needs `/data`
  plus SurfaceFlinger. So "reached SurfaceFlinger" was never true for any Android 14 attempt: every attempt
  died **before init started a service**, and the SD logger proves that independently of the panel.
* `boot-min.img` and `boot-diag.img` differ by **exactly 9 header bytes**, at bytes 397..405: `" panic=12"`.
  Kernel, ramdisk, `second`, and every load address are byte-identical. So the black screen in attempt 2 is
  not a payload-content regression; the two attempts are one failure read through two reboot paths. With
  `panic=12` a dying PID 1 warm-resets and u-boot redraws the logo each cycle; without it the kernel can
  finish the DRM handover and then sit on a black panel.
* Neither attempt tells us *where* it died. That is still the open question, and the offline work below
  narrows it.

### Boot-header byte diff, stock `boot.bin` against the flashed `boot-min.img`

Decoded with `unpack_bootimg` (authoritative), then confirmed as a raw byte diff of the 2048-byte header
page. The whole deviation set is five regions:

| bytes | field | stock `boot.bin` | `boot-min.img` |
|---|---|---|---|
| 16..19 | `ramdisk_size` | 803,440 | 1,631,866 |
| 44..47 | `os_version` / `os_patch_level` | 10.0.0, 2020-05 | 14.0.0, 2026-10 |
| 133..397 | cmdline field | `wificountrycode=US`, `veritymode=enforcing` | `wificountrycode=NL`, `veritymode=disabled` (the later ranges are the same text shifted by one byte because `disabled` is longer than `enforcing`) |
| 576..595 | content hash over kernel+ramdisk+second | `cd0eda5e…` | `1f7c25f6…` |
| 1654..1659 | `dtb_load_address` (uint64 at 1652) | `0x11f00000` | `0x00000000` |

`dtb_size` is 0 in **both** images, and these are the only differences: kernel blob identical
(`25,671,688` B, sha `a514a3ffb77e`), `second` blob identical (`924,672` B, sha `fb80617e7c97`), page size
2048, header v2, kernel `0x10008000`, ramdisk `0x11000000`, second `0x10f00000`, tags `0x10000100`. So the
payload keeps the OEM kernel and the OEM `second` stage, and carries only a different first-stage ramdisk.

Two earlier claims in this repo were wrong and are corrected here:

* "second size points at 285,212,672" was a field mislabel. `0x11000000` is the **ramdisk load address** at
  byte 20; the real `second_size` is 924,672 at byte 24, and byte 32 is `kernel_tags_addr` `0x10000100`.
* The `dtb_load_address` was zeroed by our own packing step: `scripts/rebuild_boot_with_fstab.sh` writes
  `dtb_size` and `dtb_addr` at bytes 1648/1652 and sets both to 0, mirroring the OEM `dtb_size 0` but
  discarding the OEM address. Restoring `0x11f00000` is a header-page-only edit that moves nothing.

### DTB re-measured - my earlier "no DTB in the images" was a wrong magic

The DTB magic is big-endian `d00dfeed` (`\xd0\x0d\xfe\xed`). An earlier scan searched `d0fe0fb`, which
matches nothing, and produced the false "no DTB present" conclusion. Re-scanned with the correct magic:

| file | DTB blobs found (offset, declared total size) | sha |
|---|---|---|
| `hu-stock-backup-refresh/boot.bin` (33,554,432 B) | 26,482,688 (152,425) inside `second`; 32,093,696 and 32,636,928 (157,962 each) in the tail | `cd4eeb3daece` / `530b84129eb0` |
| `a14diag/boot-min.img` and `boot-diag.img` (28,233,728 B) | 27,310,080 (152,425) inside `second`; **no tail DTB** | `cd4eeb3daece` |
| `hu-stock-backup-refresh/dtb.bin` (partition 4) | none - 4 MiB with no `d00dfeed` anywhere | - |
| `hu-stock-backup-refresh/dtbo.bin` (partition 5) | 64 (739) | `e48134ad0ec7` |

The payload's DTB is **byte-identical** to stock's `second`-embedded DTB (`cd4eeb3daece`), so the DTB the
board needs is present. The two tail DTBs are a *different variant* (5,091 differing `dtc` lines): they add
the mmc aliases `mmc0 = /dwmmc@fe310000`, `mmc1 = /dwmmc@fe320000`, `mmc2 = /sdhci@fe330000` and change the
display routes to `logo,uboot = "logo.bmp"` + `logo,kernel = "logo_kernel.bmp"`, where the `second` variant
has no mmc aliases and `logo,kernel = "logo.bmp"`. They are the A11-era DTB the OEM package ships (`530b8412…`,
already recorded at `docs/decisions.md:1176`).

Because partition 4 holds no DTB at all, the kernel's device tree can only come from the boot image. Two
consequences worth measuring separately:

* The flashed image's own bytes stop at 28,233,728, and `dd` wrote exactly that into the 33,554,432 B
  partition, so the stock tail DTBs at 32,093,696 and 32,636,928 were **never overwritten** and survived both
  attempts. **Measured later on Nov 18**, not inference: the live partition's tail region
  (32,093,696..32,795,136) reads `d00dfeed` with declared size 157,962 and sha256
  `bfbf7e1c58cedf7e039b5d4ef5ce1b6ef5590d6c044e9907d9727946cdafda5f`, identical to the carve of the same
  region out of the stock capture. The first read attempt looked like zeros only because `toybox dd`'s
  `skip` counts input *blocks*: 32,093,696 / 512 = 62,683, and `skip=62879` lands at 32,194,048.
* The header's `dtb_load_address` went to 0. If the OEM boot path uses that field to place the DTB, a zero
  address is a real defect; if it uses its own fixed address, it is harmless. Only a UART read of u-boot's
  own log can settle which.

### The byte-faithful boot rebuild, built offline (**D60**)

`tools/rebuild_boot_faithful.py` produces the image the boot-only ladder needs. The layout rule it uses is
the one a Rockchip boot loader computes - `kernel @ 2048`, `ramdisk @ roundup(2048 + kernel_size)`,
`second @ roundup(ramdisk_offset + ramdisk_size)` - rounding **after** adding the header page. Rounding each
size by itself puts every component one page early; the RSCE magic and the DTB magic sit exactly at the
add-then-round offsets in the OEM boot image, the payload image and the OEM recovery image, which is what
settled the rule.

Measured output for OEM `boot.bin` + `boot-min.img`:

| field | value |
|---|---|
| size | 33,554,432 B - the partition's own size, so a rollback `dd` and this write cover the same span |
| sha256 | `8073406527126838443a3df744aeb37d80b8401db254ee39421ae919f83bb1a1` - Nov 18, **superseded**: it zero-filled the splash region (**D68**). The corrected image is `e504655bd32c3c9c6bcb0de3de6a2a9a3f67c33f3638e7bac022151217b11f4f` |
| kernel | carried verbatim, sha `a514a3ffb77e`, `25,671,688` B |
| `second` | carried verbatim, sha `fb80617e7c97`, `924,672` B, at offset 27,308,032 |
| ramdisk | the payload's, padded to offset 25,675,776, declared size 1,631,866 |
| DTBs | three: 27,310,080 (152,425, `cd4eeb3daece`), 32,093,696 and 32,636,928 (157,962 each, `530b84129eb0`) |
| header page | differs only in `ramdisk_size` (bytes 16..19) and the cmdline field (64..575) |
| `dtb_load_address` | restored to the OEM `0x11f00000`; `dtb_size` stays 0 like the OEM image |
| `os_version` / `os_patch_level` | OEM `10.0.0` / `2020-05` - the failed payload shipped `14.0.0` / `2026-10`, so this is now a ladder variable, not a silent change |

The tool refuses if the kernel blob or the `second` blob differs from the OEM image, if the components reach
the OEM tail resource header, or if any header byte outside `ramdisk_size` and the cmdline field changed. It
re-reads the finished image and checks every component at the offsets a loader computes, checks that the bytes
from its own content end to the partition end equal the OEM bytes, and re-verifies the carried resource entries
against their declared SHA1 (**D68**). The Nov 19 identity gate showed the earlier rule zero-filled the splash
region instead of carrying it; that output (`807340652712…`) is superseded by the corrected one below.

One field stays unresolved and is deliberately **not** recomputed: the 20 bytes at header offset 576. Stock,
payload and recovery each carry a different value there, and no sha1 of any concatenation of the header page,
kernel, ramdisk, `second`, DTB or tail pieces reproduces the OEM value, so we cannot derive the rule. The
byte-faithful image carries the OEM value verbatim, and step L0 (**D62**) is the experiment that tells us
whether the boot loader reads it: L0 repacks the stock content with this tool and must boot Android 10.

This image is **not flashed**. Nothing under **D60** goes to the unit before L0 passes.

### Payload vendor provenance - it is a rebuild, not the stock vendor

Carved both `vendor` extents and compared them:

| fact | stock Android 10 vendor | payload vendor (Nov 18 `super-min.img`) |
|---|---|---|
| extent | super sectors 1,928,824..2,560,720 (323,530,752 B) | super sectors 1,980,416..3,066,496 (556,072,960 B) |
| filesystem | ext4, volume `vendor`, UUID `2b96c597-1e2f-5ee1-9851-c4a9fa9de36e` | ext4, volume `vendor`, **same UUID** |
| fingerprint | `rockchip/rk3399/rk3399:10/QQ2A.200305.004.A1/hct204011522:userdebug/release-keys` | `HCT/lineage_rk3399/rk3399:14/AP2A.240905.003/eng.root.20261115.223943:userdebug/test-keys` |
| api level | `ro.product.first_api_level=29` | `ro.product.first_api_level=34`, `ro.board.api_level=202404` |
| VINTF manifest | version `1.0`, `target-level="4"` | version `8.0`, `target-level="4"` |

So the payload's vendor is built by our own tree (D15's staging route), with the OEM blobs carried in. The
`lib64/hw` union across the two vendors is 41 files: **15 byte-identical** (the OEM hardware blobs -
`hwcomposer.rk30board.so` 506,816, `gralloc.rk30board.so` 24,136, `camera.rk30board.so` 1,475,440,
`audio.primary.rk30board.so` 318,280, `vulkan.rk30board.so` 16,755,032, `gps.default.so` 32,440,
`sensors.rk30board.so`, `keystore.rk30board.so`, `lights.rk3399.so`, `memtrack.rk3399.so`, `mfi.default.so`,
`power.rk3399.so`, `weaver@1.0-impl`, `mtc.mfi@1.0-impl`, `graphics.composer@2.1-impl.so`), **15 rebuilt**
(the generic `.default.so` stubs and interface impls, each ~134 KB), **6 stock-only**
(`gatekeeper@1.0-impl`, `keymaster@3.0-impl`, `light@2.0-impl`, `audio@5.0-impl`, `audio.effect@5.0-impl`,
`gatekeeper.rk30board.so`) and **5 payload-only** (`audio@6.0-impl`, `audio.effect@6.0-impl`,
`health@2.0-impl-2.1`, `android.hidl.memory@1.0-impl`, `vulkan.pastel.so` 27,616,872).

Correction to **D56**: `libhwbinder.so` is **not** missing from the payload. The payload vendor ships
`lib64/libhwbinder.so` 133,384 B (`7c91089433ae`), `lib64/libbinder.so` 799,688 B (`ddbb6e0174ec`) and
`lib64/libhidlbase.so` 859,288 B (`25a32abb331b`). Stock vendor ships none of those three - its HALs link
against spliced VNDK libs instead - so the Android 14 libs are there, but they are Android 14 builds sitting
underneath Android 10-era blobs, which is the compatibility question, not a missing-file question.

### Payload super metadata against stock super

| fact | stock super | payload super |
|---|---|---|
| metadata | version 10.0, slot 0, 668 B used / 65,536 max, 2 slots | version 10.0, slot 0, 592 B used, 2 slots |
| group | `rockchip_dynamic_partitions`, max 3,258,974,208 | `hct_dynamic_partitions`, max 3,258,974,208 |
| partitions | product 1,926,776 / vendor 631,896 / system 2,490,880 / odm 1,054,592 sectors, all `readonly`, **no system_ext** | system 1,978,264 / vendor 1,086,080 / product 890,936 / system_ext 751,568 / odm 1,584 sectors, attributes **none** |
| backing | super first sector 2048, size 3,263,168,512 | identical |

`lpdump` reports a coherent layout for the payload in both slots: five logical partitions inside one group,
extents non-overlapping, and the group ceiling matches. The payload adds `system_ext` and drops the OEM's
`readonly` flags; the super size is untouched (**D19**).

### Live facts measured Nov 18 (read-only, adb)

| probe | result | what it means |
|---|---|---|
| `uname -r` | `4.19.111+` | the kernel is 4.19, not the 4.4-class I had assumed; Android 14 userspace on 4.19 is supported for upgrade paths, so the kernel wall is far lower than estimated |
| `/sys/block/dm-*/dm/name` | `product vendor system odm` | the running Android 10 already owns dm targets with the logical partition names, so a harness that asks for those names can never succeed cleanly |
| `/proc/sys/kernel/printk_devkmsg` | `ratelimit` | "N output lines suppressed due to ratelimiting" is the kernel's `/dev/kmsg` ratelimiter, not init's own; `on` defeats it, and `printk.devkmsg=on` does it on the boot cmdline |
| `/proc/iomem` | no `ramoops` entry | **Re-measured Nov 18: this proves nothing.** `dmesg` shows `ramoops: attached 0xf0000@0x110000`, `pstore: Registered ramoops as persistent store backend` and `console [pstore-1] enabled`, so the driver does register; reserved-memory regions simply are not listed in `/proc/iomem`. `/sys/fs/pstore` is mounted (pstore, rw) and read empty on the boot after the owner's cold restore |
| `/proc/filesystems` | `vfat` present (1 match) | an SD-card logger is mountable by the stock kernel |
| `/sys/kernel/uevent_seqnum` | 2978 | the uevent counter is live and readable - a cheap read-only detector for init's cold-boot uevent flood |
| `/proc/sys/kernel/random/boot_id` | `092756bc-1f4b-4a29-9452-d992e8cc4d9d` | a reboot detector that does not need pstore: snapshot it before a run, compare after |

### The namespace harness is frozen, and why

The harness proved the payload's static first-stage `init` can execute on this kernel
(`init first stage started!`, `ReadFstabFromDt()` failing harmlessly, `Failed to read vbmeta partitions.`
nonfatal, `AVB is not enabled, skip verity setup for '/metadata'`, `/metadata` `check_fs()` success), but it
cannot answer the question it was built for, and it damaged the host:

* The host already owns dm targets named `system`/`vendor`/`product`/`odm`, so the payload init either gets
  `EBUSY` on `DM_DEV_CREATE` or reuses Android 10's devices. Either way a valid logical-mount outcome is
  impossible here.
* Mount and PID namespaces do not isolate device-mapper, block devices, binder, GPU, panel, sysctls, sysrq,
  power state or physical storage. Runs correlated with `SYSTEM_RESTART`, `system_server_lowmem` and
  `system_server_crash` in dropbox, and eventually a kernel-level reboot (`up 0 min`).
* `toybox unshare -mp` does not fork, so init is not PID 1 of its PID namespace; a fatal abort in it reaches
  the host PID namespace's `reboot(2)`. That is the likely reboot mechanism.
* Android's `/data` is a shared mount, so namespace mounts propagate back into the host mount table; the fix
  is `mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL)` before any mount, which toybox cannot do and needs a
  native helper.
* First-stage init's device scan writes `add` to every `/sys/**/uevent`, which broadcasts to the host's
  `ueventd`, `vold`, `healthd` and `system_server`; `/sys/kernel/uevent_seqnum` is the read-only detector.
* A head-region sha fingerprint of a partition proves almost nothing. A real guard must remove write access
  (`BLKROSET` per partition, never the whole disk) and diff `/proc/diskstats` write sectors before/after, plus
  `boot_id` for a kernel reboot and saved `system_server`/zygote/surfaceflinger/vold PIDs and
  `logcat -b events | grep am_proc_died` for a framework restart.

Not resumed until those are implemented, and even then it cannot answer the logical-mount question.

### Dead ends, recorded

* **QEMU**: `-machine virt` boots EDK2 and prints, but neither the OEM kernel blob nor the tree kernel prints
  under it; the failing stage needs real GPT names, the real DTB and the PMIC.
* **kexec**: `# CONFIG_KEXEC is not set` on the running kernel.
* **RAMoops**: works, and the earlier "not registered" reading was a wrong probe (`dmesg` shows
  `ramoops: attached 0xf0000@0x110000`, `pstore: Registered ramoops as persistent store backend`,
  `console [pstore-1] enabled`, `pstore: Using compression: deflate`). Its limits are real: the record lives
  in DRAM, so a cold power cycle destroys it, and reading a pstore file deletes it. A warm `reboot` test is
  still owed.

### Ranked causes after the Nov 18 re-measure

Three frontier reviews (Gemini, ChatGPT, Claude) converged on the same route: offline first, then a
boot-only ladder, then UART. Claude's four checks were verified: the `second_size` mislabel, the host dm-name
clash, the uevent flood being detectable, and the 9-byte `panic=12` difference. The kernel correction moves
the estimates:

| rank | hypothesis | confidence | state |
|---|---|---|---|
| 1 | PID 1 aborts in first stage or early second stage, then panic or fatal reboot | ~35% | unproven; harness cannot test it |
| 2 | boot-image header fidelity: `dtb_load_address 0`, and the image carrying only the 152,425 DTB variant while the boot chain's other variant (157,962, with the mmc aliases) lives in the tail | ~25% | partially measurable offline, fixable offline - **lowered to ~10% by the Nov 18 live session**, see "The unit came back" below: the running stock kernel has no mmc aliases at all, so the small variant is what the board actually uses |
| 3 | OEM u-boot/trust boot-chain acceptance | ~15% | only UART can settle it |
| 4 | Android 14 userspace against an Android 10 vendor: manifest `target-level 4` under `api_level 34`, Android 10-era blobs under Android 14 binder libs | ~15% | a second-stage wall, not a first-stage one |
| 5 | AVB / vbmeta / `misc` | ~5% | not the leading suspect: the payload fstab has no `avb=` row and init continues after the vbmeta message |

One suspect is now **ruled out**: the live cmdline carries `androidboot.boot_devices=fe330000.sdhci`,
`storagemedia=emmc`, `board.sel`, `b.mode`, `dtbo_idx`, `serialno`, `slot_suffix`, `earlycon`, `swiotlb` and
`coherent_pool`, and **none of those are in the stock header cmdline either** - so u-boot appends them, and
the payload inherits them too. "Missing `boot_devices`" is not a payload defect.

## Nov 18 (late session) - the unit came back, and partition 7's real state is measured

`192.168.1.120` answers again. The blocker was the host's own `adb` daemon, not the unit: `adb kill-server`,
`adb start-server`, `adb connect 192.168.1.120:5555` gives `connected` and `adb root` returns
`restarting adbd as root`. `ping` shows 0% loss. The unit runs the stock April 2025 Android 10 again
(`ro.build.fingerprint = rockchip/rk3399/rk3399:10/QQ2A.200305.004.A1/eng.hct2.20250401.152740:userdebug/release-keys`,
`ro.build.date = Tue Apr 1 15:22:29 CST 2025`), kernel `4.19.111+ #190`, uptime 984 s. Everything below is
read-only; nothing was written and the unit was not rebooted.

### Partition 7 is not the rollback capture - it is a truncated restore plus payload remnants

The live partition reads 33,554,432 B sha256 `0bd1cc806740a1f3c69b95d222ef51f7e1fc47e5a91446e0217fd732b817bc51`,
which is **not** the Nov 17 capture (`4121b58f7759…`) and not the Nov 11 capture (`3d2741f04f31…`). Pulling it
over `adb exec-out` with `dd | toybox base64` and stripping the CR characters reproduces the device digest
exactly, so the comparison below is trustworthy (a plain `exec-out dd` adds 88 CR bytes and hashes differently).

| region | live content | how it was identified |
|---|---|---|
| 0..27,406,336 | exactly `vibe-rescue/a10pkg/boot.img` (27,406,336 B, sha256 `04a43ea931de08734d8a25afe9920cba69a099095ab4b4490dbbe4368d0b89c6`) | byte-equal, and also byte-equal to the capture's first 27,406,336 B |
| 27,406,336..28,233,728 | exactly the same slice of `a14diag/boot-min.img` - the Android 14 payload's padding, not stock bytes | byte-equal to that slice |
| 28,233,728..33,554,432 | identical to the capture's same region, tail DTBs included | byte-equal; tail region sha `bfbf7e1c58cedf…` matches the capture carve |

So the restore wrote **only 27,406,336 bytes** and left the payload's bytes sitting in the middle of the boot
partition. That is harmless for booting because the loader consumes only through `second`'s padded end
(`roundup(26,480,640 + 924,672) = 27,407,104`), and the stock `second` blob is intact: the exact 924,672 B at
26,480,640 hashes `fb80617e7c970501c6ef63f39e4779ab017a20417f482a37ca021aa97f63f2f3` in both live and capture.
The 606,121 differing bytes against the capture all sit in 27,406,336..28,192,288, i.e. stock zero padding
replaced by payload padding. Restoring the full 33,554,432 B capture is therefore a write of stock content, not
a regression, and it also clears the payload remnants.

### The rest of the boot chain is verified byte-exact against the Nov 17 capture

| partition | live sha256 (16-hex) | capture | verdict |
|---|---|---|---|
| uboot (p1) | `a28fd6a0e6c63ef8` | `a28fd6a0e6c6…` | identical |
| trust (p2) | `7f2c4e52e595b792` | `7f2c4e52e595…` | identical |
| misc (p3) | `909bdd979111bcd5` | `909bdd979111…` | identical |
| dtb (p4) | `bb9f8df61474d25e` | `bb9f8df61474…` | identical |
| dtbo (p5) | `e5c1d28c4b6f9161` | `e5c1d28c4b6f…` | identical |
| vbmeta (p6) | `76ff77959f2451ee` | `76ff77959f24…` | identical |
| recovery (p8) | `1fdf5ea77fc66f48` | `1fdf5ea77fc6…` | identical, so no patched recovery is on the disk (**not** state S2) |
| security (p10) | `6ff044d01c2b8631` | `6ff044d01c2b…` | identical |
| frp (p13) | `07854d2fef297a06` | `07854d2fef29…` | identical |
| metadata (p12) | `f92994ce1c2a1daf5f866c8c9f594da98a544a882477b1a824bd952fb3514b04` | `055d780c5cae…` | differs - update_engine's own metadata moved during the restore |

This is the first digest-level verification of **D30**'s claim that nothing beyond `boot` + `super` was ever
written: nine partitions hash exactly as captured.

### Super: logical content identical to stock, only the metadata slots moved

Live super (p14) is 3,263,168,512 B, sha256 `535dac26946dee10a6040b8b2431120485d198437ec66058a629e0e395acc5b1`,
head 2 MiB `bfc68890ef2e60eb313b8835b1c45876be360ba4feb11b45f98e4510f3c09e72`, tail 8 MiB
`2daeb1f36095b44b318410b3f4e8b5d989dcc7bb023d1426c492dab0a3053e74`. The tail digest matches the Nov 17 capture
**and** both payload supers, so the logical partition bytes are stock again. Against the capture's head 2 MiB the
live bytes differ in only 148 bytes across two regions (77,836..77,904 + 78,212..78,340 and the mirrored
208,908..208,976 + 209,284..209,380) - the two metadata slots. The geometry block at offset 4096 is byte-identical.

### The live device tree has no mmc aliases, which settles the DTB-variant suspect

`/proc/device-tree/aliases/mmc0`, `mmc1`, `mmc2` read **empty**; `serial2 = /serial@ff1a0000`. The stock kernel
on this board therefore runs with the device tree that has no mmc aliases - the 152,425-byte variant inside
`second` - and storage works anyway, because u-boot brings up the storage itself and appends
`androidboot.boot_devices=fe330000.sdhci`, `storagemedia=emmc`, `board.sel`, `b.mode`, `dtbo_idx`, `serialno`,
`slot_suffix` to the cmdline (`/proc/cmdline` and `/proc/device-tree/chosen/bootargs` read identical). Our
payload's DTB is byte-identical to that variant (`cd4eeb3daece`), so "the image carries only the small variant"
is not a boot-blocking defect, and **D60**'s tail-DTB carry is fidelity work, not a fix candidate.

### pstore works; the earlier reading of it was wrong

`dmesg` on the live kernel shows `console [pstore-1] enabled`, `pstore: Registered ramoops as persistent store
backend`, `ramoops: attached 0xf0000@0x110000`, `pstore: Using compression: deflate`. The DTB declares
`ramoops@110000` with `reg = <0x00 0x110000 0x00 0xf0000>` (983,040 B) and `record-size 0x20000`
(131,072), `console-size 0x80000` (524,288), `pmsg-size 0x50000` (327,680) - the three declared sizes sum to
exactly the region. `/sys/fs/pstore` is mounted and reads empty today because the last boot was a cold power
cycle after the owner's restore, and records are deleted when read; the Nov 13 record
(`analysis/panic-20261113-2003-ramoops.txt`) and the Nov 17 clean-boot records prove the channel works. The
warm-`reboot` probe is still owed.

### Kernel config answers that close three open questions in the proposed blind plan

From `incoming/probe-20261113-2016.md`, cross-checked against the live kernel:

| option | state | consequence |
|---|---|---|
| `CONFIG_PSTORE_RAM`, `CONFIG_PSTORE_CONSOLE`, `CONFIG_PSTORE_PMSG`, `CONFIG_PSTORE` | `y` | pstore console is a real channel |
| `CONFIG_VT`, `CONFIG_TTY_PRINTK` | **not set** | `console=tty0` / fbcon screen output is impossible - that channel does not exist on this kernel |
| `CONFIG_USER_NS` | **not set** | the namespace route can never work here; it reinforces **D59**'s freeze and makes **D64**'s guard set impossible on this kernel |
| `CONFIG_DRM_FBDEV_EMULATION` | `y` | DRM keeps fbdev, but without `CONFIG_VT` nothing can print through it |
| `CONFIG_MMC_DW_ROCKCHIP`, `CONFIG_MMC_SDHCI`, `CONFIG_MMC_SDHCI_PLTFM` | `y` | both storage controllers are built in; an SD card is usable for logging without a driver load |
| `CONFIG_VFAT_FS` support set (`NLS_CODEPAGE_437`, `NLS_ISO8859_1` `y`), `/proc/filesystems` lists `vfat` | present | the earlier vfat logger was mountable, so "logger never worked" is not a driver problem |
| `CONFIG_USB_STORAGE` | `y` | a USB stick is a possible log target, though the ports are host-side |
| `CONFIG_CGROUPS`, `CONFIG_CGROUP_BPF`, `CONFIG_BPF_SYSCALL`, `CONFIG_MEMCG`, `CONFIG_PSI`, `CONFIG_SECCOMP_FILTER` | `y` | Android 14 init's cgroup/BPF/PSI needs are met by the OEM 4.19.111 kernel |
| `CONFIG_CONSOLE_LOGLEVEL_DEFAULT` | `7` | a quiet cmdline really does drop lines from the pstore console; `loglevel=8`/`ignore_loglevel` is worth carrying |

### Two arithmetic traps measured today, both cheap to avoid

* `toybox dd`'s `skip` counts **input blocks**, like GNU dd. 32,093,696 / 512 = 62,683; using `skip=62879`
  lands on 32,194,048 and reads unrelated bytes. This is what produced the "the tail DTB is gone" reading.
* Android's mksh does 32-bit arithmetic: `sz=$(( sectors * 512 ))` for super's 6,373,376 sectors wraps to
  -1,031,798,784 and `dd count=` then reads nothing (`sha256sum` of empty input). Use exact counts: super is
  3112 MiB, so `dd bs=1M count=3112`.

### What is owed next

1. Warm `reboot` pstore probe (step **P0**, no write): `scripts/pstore_probe.sh` (added Nov 19). Without
   `HU_CONSENT=1` it is a dry run that reads nothing from `/sys/fs/pstore` and touches nothing - measured today,
   it prints the unit's boot id, uptime, the empty pstore listing and the four RAMoops lines pulled from
   `dmesg`. With the owner's consent (`HU_CONSENT=1`) it reboots once, reconnects, and pulls
   `console-ramoops-0`, `dmesg-ramoops-0` and `pmsg-ramoops-0` into the scratch dir through `toybox base64` (a
   plain `exec-out cat` of binary data adds CR bytes and corrupts the digest). It costs one boot cycle, no
   write, and it comes before the ladder's first flash because it decides whether a failed boot can be read at
   all.
2. A `boot`-only identity round-trip: repack the stock capture content with our tooling and prove the result is
   byte-identical or differs only in documented bytes. `tools/identity_gate.py` now does that (**D67**), and its
   Nov 19 run proved the round trip byte-identical after fixing the zero-filled tail (**D68**).
3. The `misc` partition is untouched (`909bdd97…`) and stays that way unless the owner approves a BCB write.

## Nov 19 - the identity gate ran, found a real pipeline defect, and now passes

`tools/identity_gate.py` (**D67**) is the gate that must pass before any image is proposed for a write. Its
first run failed check 1, and that failure is what exposed a defect in our own packing tooling - exactly the
class of problem the gate was built to catch. Nothing was written to the unit; the gate is offline.

### What the OEM boot partition actually holds past the Android boot image

The Android boot image proper ends at 27,406,336 (the padded end of `second`). The partition is 33,554,432 B,
so 6,148,096 bytes of OEM content sit past it, and none of it was described by any header field:

| region | content | evidence |
|---|---|---|
| 27,407,104..32,092,160 | 4,685,056 B of splash data, 2,624,960 of them non-zero (ARGB-looking pixel runs, no magic) | sha256 of the region `be1b54c9debfedbd6a1a85a4ffc894bf5b477107d6f413ebc1fda0eae3bbba9a` |
| 32,092,160 | a second Rockchip resource image: `RSCE`, version 0, flag `0x10101`, entry count 2 | magic and header fields read from the capture |
| entry records | 512 B each: `ENTR`, a name padded to 224, a 20-byte **SHA1** at record+224, then `hash_len` u32 at record+256, an offset in **512-byte blocks** at +260, a size u32 at +264 | decoded Nov 19; every declared SHA1 verifies |
| 32,093,696 | `rk-kernel.dtb`, 157,962 B, declared SHA1 `a6da38a41c07…`, computed `a6da38a41c07…` | matches the declared hash exactly |
| 32,251,904 | `logo.bmp`, 384,572 B, declared SHA1 `a52ea8dbca38…`, computed identical | matches |
| 32,636,928 | a second copy of the same 157,962 B DTB (same SHA1), **not** listed in the header; ends 32,794,890 | magic scan plus SHA1 equality with the declared entry |
| 32,794,890..33,554,432 | zeros | byte scan |

`second` is itself a resource image of the same format at 26,480,640, with three entries: `rk-kernel.dtb`
(4 blocks -> 26,482,688, 152,425 B, SHA1 `0ce0df4dcbe6…`), `logo.bmp` (302 blocks -> 26,635,264, 384,788 B,
SHA1 `aee81fc3c0dc…`) and `logo_kernel.bmp` (1054 blocks -> 27,020,288, 384,788 B, the same SHA1, so it is a
second copy of the same bitmap). All three declared hashes verify. The OEM recovery image carries the same
three entries at its resource header (offset 38,195,200) with the same hashes, so the format is the OEM's
convention, not an artefact of one image.

The kernel's own device tree confirms which of these the running board uses: `/reserved-memory/drm-logo` reads
`reg = <0x00000000f5f00000 0x00000000119800>` - u-boot fills the logo node with a DRAM buffer of 1,148,928 B,
which is the logo carried inside `second`. The variant the kernel receives has no logo aliases; only the tail
variant adds `logo,uboot`/`logo,kernel`. So the logo path runs through `second`, which our payload carries
verbatim.

### The defect the gate caught: the rebuild zero-filled that region

`tools/rebuild_boot_faithful.py` (**D60**) carried only the tail DTBs and zero-filled everything between the
payload's content end and the first DTB. Measured on the Nov 18 artifact `boot-faithful-tool.img`:
4,613,900 zero bytes inside the 4,685,056 B splash region and no `RSCE` header at 32,092,160. So feeding the
stock capture through our own tooling did **not** reproduce it byte-for-byte, and a "byte-faithful" image
actually deleted 4.6 MB of OEM content the partition keeps.

The rule is now: the OEM bytes from the rebuilt image's own content end to the partition end are carried
**verbatim**; the tool refuses if the payload's components reach the tail resource header (32,092,160), and it
re-verifies every carried resource entry against its declared SHA1. The DTB check distinguishes the DTB inside
`second` (which moves with the payload's ramdisk size) from the tail copies (which must stay put).

### Gate result, offline, Nov 19

Inputs: the Nov 17 capture `hu-stock-backup-refresh/boot.bin` (`4121b58f7759…`) and `super.bin`, and the payload
images `a14diag/boot-min.img` and `super-min.img`.

* **Check 1 - identity: PASS.** Stock content through our tooling reproduces the 33,554,432 B capture
  byte-for-byte; the artifact hashes exactly `4121b58f7759…`.
* **Check 2 - payload fidelity: PASS.** The rebuilt payload image is 33,554,432 B sha256
  `e504655bd32c3c9c6bcb0de3de6a2a9a3f67c33f3638e7bac022151217b11f4f`. Header page differs only in
  `ramdisk_size` (16..19) and the cmdline field; kernel identical (25,671,688 B); `second` identical
  (924,672 B), moved from 26,480,640 to 27,308,032 by the payload's ramdisk size; the tail is identical from
  28,233,728 B to the partition end (5,320,704 B: splash, resource header, both DTB copies). Content differs
  in 56,362 ranges totalling 2,273,364 B, all inside the ramdisk span (25,675,776..27,307,642) and the
  padding span (28,232,704..28,233,728) - nothing outside them.
* The same gate run against `boot-diag.img` + `super-diag.img` also passes, and the only header difference
  against the min variant is the 9-byte ` panic=12` tail in the cmdline field; its faithful image is
  `9ed667e99c39b7a7ad5f5761698861c71282a1a8117a0c91022719d3016a7db7`. Both payload variants therefore enter
  the ladder through the same verified pipeline (**D62**), one variable per rung.
* **Check 3 - super metadata: PASS with a documented delta.** Device size identical (3,263,168,512 B), first
  sector identical (2048), metadata slots identical (2); metadata size 592 -> 668; group
  `rockchip_dynamic_partitions` -> `hct_dynamic_partitions`, both maximum 3,258,974,208; attributes
  `readonly` -> `none` on all four shared partitions; payload adds `system_ext`; every extent differs. No
  resize (**D18**).

The Nov 18 output `807340652712…` is **superseded** by `e504655bd32c…`: the same header rule, plus the verbatim
tail. Neither image is flashed.

### What a payload write necessarily costs, and why it is survivable

A payload whose ramdisk is bigger than stock's necessarily lands its own `second` and padding on top of the
first 826,624 bytes of the OEM splash region (27,406,336..28,233,728). That is inherent to the layout, not a
tooling choice, and the live partition proves it is survivable: today it holds payload bytes in exactly that
slice and still boots Android 10 with a logo, because the logo the boot path needs lives in `second` (carried
verbatim) and the tail resource header at 32,092,160 survived both Nov 18 writes.

## Nov 19 (daytime) - the ladder images are staged offline, and one cmdline token turned out to be fake

`scripts/stage_ladder.sh` builds the boot-only ladder (D62) from the stock capture and refuses to run if the
capture's digest is not `4121b58f7759…`, so a stale input cannot produce an image nobody can trace. Every output
is verified the same way the identity gate verifies: the only bytes that may differ from the capture are inside
the header's 512-byte cmdline field, the tail resource header must still sit at 32,092,160, and the three DTB
copies must still be at 26,482,688 / 32,093,696 / 32,636,928. Outputs and their digests (manifest at
`a14-work/ladder/MANIFEST.sha256`):

| image | sha256 | what it changes |
|---|---|---|
| `L0-stock.img` | `4121b58f77598d73b1b7958c36d1c5a81c8b82ba176cce9f6863b67992ce5b3d` | nothing - the capture repacked through our tooling, byte-identical. Writing it also clears partition 7's payload remnants (D66) |
| `L1-printk-devkmsg-on.img` | `3a70fbf94444f6a0d789cdbee1b45d3c8c784dfe6981d519bd842ee357bb6c09` | one token: `printk.devkmsg=on` (kernel; today `printk_devkmsg=ratelimit` drops lines) |
| `L1-panic-12.img` | `95e99c2188f892b0290e17e63d8d14bc715b0c9069b0e0c76bf0a26adb056d9a` | one token: `panic=12` - the 9-byte difference between the two Nov 18 payload images that produced a logo loop instead of a black panel |
| `L1-loglevel-8.img` | `e8d352b3ce0a74d90cfec6a45a21784953c35536673ea533f581b597d54f9c8c` | one token: `loglevel=8` (`CONFIG_CONSOLE_LOGLEVEL_DEFAULT=7`, so a quiet cmdline really does lose lines from the pstore console) |
| `L1-androidboot-init-fatal-reboot-target-bootloader.img` | `3de9da9f7f8b81d3ca24cf7202b5b6b0b2dd691b1a9842128e41dd8da4473385` | one token: `androidboot.init_fatal_reboot_target=bootloader` - a dying init would warm-reset into the boot chain instead of looping, using the DT's `reboot-mode` syscon node |

The token set was checked against the ramdisks themselves, which **D62** demands because an unverified token is
a silent no-op. Both ramdisks are gzip at 25,675,776: the stock Android 10 one is declared 803,440 B and
decompresses to a 1,870,336 B cpio whose `/init` is 1,867,160 B; the payload's is declared 1,631,866 B and
decompresses to 3,651,840 B with a 3,644,288 B `/init`. `strings` on both shows
`androidboot.init_fatal_reboot_target=` and the values `bootloader` and `recovery`, and **neither contains
`init_fatal_panic`** - so the token planned for that rung is not real and was dropped. `recovery` is deliberately
not used as a value: it writes the boot control block in `misc`, a write surface **D30** forbids without the
owner's go (question 12 in `docs/head-unit-findings.md`).

Two other things the extraction settled: the stock Android 10 `/init` chain is a first-stage logical-mount chain
like Android 14's (`fstab.rk30board` lists `system` and `vendor` with `wait,logical,first_stage_mount`), so
stock init already creates the by-name logical devices - the dm-name clash that froze the namespace harness
(**D59**) is a payload-side problem, not something stock init does. And the stock header's field order is
`kernel_size @8`, `kernel_addr @12`, `ramdisk_size @16`, `second_size @24`, which is what
`tools/rebuild_boot_faithful.py` reads; the offsets it computes match the magics on all three OEM images
(ramdisk at 25,675,776, `second` at 26,480,640 on boot, 27,308,032 on the payload, 38,195,200 on recovery).

Nothing is flashed. Each rung needs the owner's go (**D38**/**D40**), and step **P0** (the warm-reset pstore
probe, `scripts/pstore_probe.sh`) comes before the first write.

## Nov 19 (evening) - P0 ran, L0 was written, and stock Android 10 boots from our repack

The owner's answers, recorded here because they change the rules (**D71**): **P0 then L0** approved for the
session; **UART stayed declined** (**D63** stays parked, pstore stays the instrument); **`misc` is now permitted**
for a recovery hand-off, which supersedes **D30**'s blanket ban for that one partition only - `uboot`, `trust`,
`dtb`, `dtbo`, `vbmeta`, `security`, `recovery`, the loader and the GPT stay forbidden, and `super` is never
resized (**D18**/**D19**).

### P0: the console record survives a warm reset, and it is readable

`HU_CONSENT=1 sh scripts/pstore_probe.sh` at 19:32 CET: one `adb reboot`, no partition write. Boot ids in order:
`62cab3af-fa50-401c-8131-cc73fd945a14` (the boot we left), `c8dd902a-d41e-49d5-b871-c5f700a5d95b` (the boot P0
landed in), `1eb3055f-734f-44e7-babf-74fd34f9c997` (the boot now running our repacked image). Two records were
present after the reset, and no `dmesg-ramoops-0` (this kernel has no pstore *record* backend, only console and
pmsg):

| file | size | sha256 |
|---|---|---|
| `console-ramoops-0` | 97,430 B | `88e35fe7aa66655db5c8db8708401fbf538243ace161384148c143fc73de8ff5` |
| `pmsg-ramoops-0` | 262,132 B | `2f4f26ae99db289e36d09b81d80b14105d763f67c508ff206b0e2b8be5c1cf2d` |
| `dmesg-before.txt` (our capture) | 1,898 lines | `ecaab1934c6fd8f298db6187a3914747c63fb294ce3b5212591a8619fce2ab47` |
| `dmesg-after.txt` (our capture) | 1,190 lines | `d23ddec142d41320e588bb5ba8238e1db48db055874777bc151da3783620315d` |

The console record is plain uncompressed kernel text (deflate fails on it - the kernel did not compress this
backend), 1,479 non-empty lines, from `Booting Linux on physical CPU 0x0000000000 [0x410fd034]` all the way to
`reboot: Restarting system with command 'adb'` at 74,190 s. So it is the **whole boot**, PID-1's own messages
included: `init: init first stage started!` at 1.022631, `ReadFstabFromDt(): failed to read fstab from dt`,
`Using Android DT directory /proc/device-tree/firmware/android/`, `Created logical partition product on device
/dev/block/dm-0` / `vendor` on dm-1 / `system` on dm-2 / `odm` on dm-3, `init: 15 output lines suppressed due to
ratelimiting` at 1.145926 and `7 output lines suppressed due to ratelimiting` at 2.730404, `Loading SELinux
policy` at 1.385886, `init: init second stage started!` at 1.620864, `Running restorecon...`, then
`starting service 'adbd'...` at 8.911207. That is the log shape a payload boot is compared against, and it shows
**the console backend is not subject to init's reader ratelimiting** - the suppression counters are init's own
kmsg reader, and the console line still lands in the record. Reading a record deletes it, so the record of a
failed boot is gone if anything else reads it first (**D65**).

Captured afterwards at 19:52, from the boot that started at 19:32 and in which partition 7 was written:
`console-ramoops-l0-boot.txt`, 67,502 B, sha256 `9a25b05dfa959fd53b263cd3a347e8bf69920241c942d9bbe590c3511cb2a366`,
ending at `reboot: Restarting system with command 'adb'` 156.351318 s. Files:
`a14-work/tmp/pstore-20261119-183202/`.

### The live kernel cmdline is assembled by u-boot, not copied from our header field

The record prints the assembled command line verbatim, 670 B. Our header's 334-byte field appears inside it
byte-for-byte; the firmware **prepends** `storagemedia=emmc androidboot.storagemedia=emmc androidboot.mode=normal
androidboot.dtbo_idx=0 androidboot.verifiedbootstate=orange androidboot.slot_suffix= androidboot.serialno=c3bc6b060ec025bb
board.sel=306,0,0,403 b.mode=normal` and **appends** `earlycon=uart8250,mmio32,0xff1a0000 swiotlb=1
coherent_pool=1m androidboot.boot_devices=fe330000.sdhci`. Two consequences: `androidboot.boot_devices` is
supplied by the boot chain itself, so the payload's first-stage mount does not need that token in the header
field (the header-fidelity suspect from Nov 18 stays dropped); and the ladder's tokens live inside the header
field, which has 178 free bytes today, so an added token cannot overflow the field - the largest L1 image puts
382 B in a 512 B field.

### L0: our packing pipeline is now trusted by the unit, not just offline

Executed 19:33-19:34 CET, `boot` only (**D18**), nothing else written. The pushed image hashed on the device as
the manifest line before the write. `toybox dd if=/data/local/tmp/ladder.img of=/dev/block/by-name/boot
bs=1M count=32 conv=fsync` moved 33,554,432 B (`32+0 records out`, 112 M/s), and partition 7 went from
`0bd1cc806740…` to `4121b58f7759…` - the payload padding in 27,406,336..28,233,728 is gone (**D66** is now
satisfied, see the amendment in `docs/decisions.md`). After `adb reboot`: `sys.boot_completed=1`, fingerprint
`rockchip/rk3399/rk3399:10/QQ2A.200305.004.A1/eng.hct2.20250401.152740:userdebug/release-keys` unchanged,
`wlan0` `operstate` `up`, TCP adb reachable, partition 7 still `4121b58f7759…`, and `misc` still
`909bdd979111…` exactly as captured - untouched, though now permitted. The owner's criteria (**D58**) are met:
boot, WiFi and a panel showing content - `a14-work/tmp/screencap-l0.png`, 219,026 B, sha256
`fa5d5f66f9d389c6b9e2ef480c4eef651959ccc40cbc0a2d066ddd34b53a4077`, IHDR 1024x600 colortype 6, 614,400 pixels,
488,393 of them pure black, 1,346 distinct sampled colours. That is a rendered UI on a dark background, not the
black panel of Nov 9.

**What L0 buys**: the identity gate (**D67**) now holds *live* - the byte-identical repack our own tooling
produced boots exactly as the OEM image does. So every L1 rung measures its token, not our pipeline, and a
payload result after L1 is interpretable. Nothing in this session tested Android 14 content: L0 changed no
content byte at all.

### Traps measured this session (they cost a false reading each)

* `adb reboot` drops adbd root, and `/dev/block/mmcblk2p7` is `brw------- root root`, so a partition read after
  a reboot returns `Permission denied` and `dd` yields empty input - its hash is `e3b0c44298fc…` (the empty-input
  digest), which looks like a "changed partition" if it is not spotted. Re-run `adb root` after every reboot.
* `toybox getprop` does not exist on this build; `getprop` resolves to `/system/bin/getprop` in the shell's own
  PATH, so a `toybox getprop …` line silently prints nothing.
* `adb exec-out 'screencap -p' | tr -d '\r'` corrupts a PNG: `0x0D` is a legal byte inside compressed IDAT data,
  so stripping CR truncates the stream (`zlib: incomplete or truncated`). Pull screenshots only through
  `exec-out 'screencap -p | toybox base64'` then `tr -d '\r\n' | base64 -d`, the same route partitions need.

## Nov 19 (night) - baseline record, and L1 rung 1 (`printk.devkmsg=on`) measured on the unit

The owner approved a baseline capture and the first L1 rung. Both ran; nothing beyond `boot` was written.

**Baseline** (one warm reboot, no write): the console record of the boot running our repacked L0 image, pulled at
22:29 CET - `console-ramoops-0` 67,035 B sha256 `d0ec28e66adf…`, `pmsg-ramoops-0` 262,132 B `ab46803751b2…`,
boot_id `0e246b97-1a3e-4bb5-836c-c3c87d885d29`, 1,085 lines spanning 0..10,466 s, head `[    0.000000] Booting
Linux…`, tail `reboot: Restarting system with command 'adb'`. It carries three ratelimit notices -
`init: 12 output lines suppressed due to ratelimiting` (1.113109), `apexd: 14 output lines suppressed…` (2.050219)
and `init: 7 output lines suppressed…` (2.738234) - and 65 `init:` lines in total. Files:
`a14-work/tmp/pstore-baseline-222912/`.

**L1 rung 1** - `L1-printk-devkmsg-on.img` (`3a70fbf94444…`) was pushed and its digest verified on the device
before the write, then `dd bs=1M count=32 conv=fsync` wrote all 33,554,432 B; partition 7 went
`4121b58f7759…` -> `3a70fbf94444…`. After reboot: `sys.boot_completed=1`, OEM fingerprint unchanged, `wlan0` `up`,
`/proc/cmdline` contains `printk.devkmsg=on`, partition 7 still `3a70fbf94444…`, `misc` still `909bdd979111…`,
and the panel renders (`screencap-l1.png` sha256 `07f1110d4052…`, 1024x600, 488,080 of 614,400 pixels pure black,
1,338 distinct sampled colours). Boot id `21da100f-6722-4863-8cd9-066e8c6b65fd`; the record of that boot was read
after the next warm reboot into `a14-work/tmp/pstore-l1-223905/`.

The token's effect is measurable and large. The record of the boot that ran it (`console-ramoops-0` 147,261 B
sha256 `9d10b6ef4394…`, `pmsg-ramoops-0` 262,132 B `8daa5ecc2ffd…`) is 2,012 lines covering 0..80.718766 s, has
**no** ratelimit notice at all, and carries **819 `init:` lines against the baseline's 65**. So the devkmsg
ratelimit really was dropping init's log output on this build, and turning it off multiplies the console text
roughly twentyfold during early boot (~1.8 KB/s against the baseline's ~0.02 KB/s over a 3-hour uptime).

**Consequences recorded as D72**: (1) this rung is worth keeping, because a payload init that dies early now
forwards its whole log instead of a ratelimited slice; (2) the console record's ceiling is the DT's declared
`console-size` 524,288 B (node `/proc/device-tree/reserved-memory/ramoops@110000`: `record-size` 0x00020000 =
131,072 B, `console-size` 0x00080000 = 524,288 B, `pmsg-size` 0x00050000 = 327,680 B, total 983,040 B =
`ramoops: attached 0xf0000@0x110000`), so at devkmsg=on volume a boot that lives long **evicts its own early
lines** - read the record soon after booting, and read it before anything else touches it. Live `/proc/config.gz`
also settles a question **D69** left open: `CONFIG_PSTORE=y`, `CONFIG_PSTORE_CONSOLE=y`, `CONFIG_PSTORE_PMSG=y`,
`CONFIG_PSTORE_RAM=y` are set, `CONFIG_PSTORE_RECORD` is **absent**, and `CONFIG_CONSOLE_LOGLEVEL_DEFAULT=7` with
`CONFIG_MESSAGE_LOGLEVEL_DEFAULT=4` - so a kernel panic cannot create `dmesg-ramoops-0` on this kernel; panic text
lands in the console record instead, which is why `loglevel=8` is the next rung.

## Nov 19 (night, second half) - the other three L1 rungs ran, all booted, and the unit is back on the stock capture

Rungs 2-4 ran one at a time without a prompt between them, each writing only `boot` (**D18**), each verified on
the device before the write, each followed by a boot check (`sys.boot_completed`, fingerprint, `wlan0`,
`/proc/cmdline` for the token, partition and `misc` digests). A copy of the rollback capture was staged on the
unit first: `/data/local/tmp/stock.img` hashes `4121b58f7759…` there, byte-equal to `hu-stock-backup-refresh/boot.bin`.

| rung | image | partition 7 after the write | boot result | the record of that boot (pulled after the next warm reboot) |
|---|---|---|---|---|
| 1 `printk.devkmsg=on` | `3a70fbf94444…` | `3a70fbf94444…` | boots, WiFi up, panel renders | console 147,261 B `9d10b6ef4394…`, 2,012 lines, **no** ratelimit notice, 819 `init:` lines |
| 2 `panic=12` | `95e99c2188f8…` | `95e99c2188f8…` | boots, WiFi up, panel renders (`screencap-l2.png` `96e225641491…`) | console 148,104 B `c4d21f1d1231…` (the rung-1 verification boot, 605.996 s), still no ratelimit notice, 824 `init:` lines |
| 3 `loglevel=8` | `e8d352b3ce0a…` | `e8d352b3ce0a…` | boots, WiFi up, panel renders (`screencap-l3.png` `799d11ba3ffe…`) | console 66,958 B `b91f069168ea…` (the rung-2 boot, 122.5 s), token `panic=12` in the record's cmdline, ratelimit notices back (12/13/7), 65 `init:` lines |
| 4 `androidboot.init_fatal_reboot_target=bootloader` | `3de9da9f7f8b…` | `3de9da9f7f8b…` | boots, WiFi up; the token is in `/proc/cmdline`; no screencap taken for this rung | console 67,995 B `6dd7d37092b1…` (the rung-4 boot, 104.073 s), 1,094 lines, ratelimit notices present, 71 `init:` lines |

The comparison is clean because each rung differs from the capture by one token only. Two pairs prove the
diagnostics were real: with `printk.devkmsg=on` the ratelimit notices vanish and `init:` console lines go from 65
to 819/824, and dropping it (rung 3's boot) brings them back - 12/13/7 suppressed lines and 65 `init:` lines.
And `loglevel=8` raises the record from 1,085 lines (baseline) to 1,254 (`595168ba1c40…`, the rung-3 boot), i.e.
the debug-level messages `CONFIG_CONSOLE_LOGLEVEL_DEFAULT=7` hides now reach the console. The console record's
ceiling is 524,288 B, and at devkmsg=on the rung-1 boot wrote 148,104 B in 606 s (~0.24 KB/s steady after the
early burst), so a boot that lives long enough can evict its own early lines; read the record soon after booting.

**End state.** Partition 7 was restored with the staged capture at 22:57 CET: it hashes `4121b58f7759…` again, and
after reboot `sys.boot_completed=1`, the OEM fingerprint, `wlan0` up, `misc` still `909bdd979111…` (untouched,
though permitted - **D71**), `super` hashes `535dac26946d…` which is exactly the Nov 18 live digest, so super did
not move this session, and the panel renders (`pstore-restore-225749/screencap-restored.png`, `8cee01af28a1…`).
Boot ids this night: baseline `0e246b97-…`, L1 `21da100f-…`, rung-1 verification `cdaef4b1-…`, rung-2 `bc4a7ab8-…`,
rung-3 `626cc2f4-…`, rung-4 `8d09fcba-…`, restored stock `aed8174e-…`. Files:
`a14-work/tmp/pstore-baseline-222912/`, `pstore-l1-223905/`, `pstore-rung2-224916/`, `pstore-rung3-225115/`,
`pstore-rung4-225401/`, `pstore-restore-225749/`. Nothing but `boot` was written all night; `misc` was never
written; no `uboot`/`trust`/`dtb`/`dtbo`/`vbmeta`/`security`/`recovery`/loader/GPT write, and `super` was not
resized (**D18**/**D19**).

Full digests of the pulled records, so any later session can verify the file it is reading:
`pstore-baseline-222912/console-ramoops-0` `d0ec28e66adfeb30bd1ac1574a5cd0fbae8f4c19a08584663366588dd597df3d`,
`pstore-baseline-222912/pmsg-ramoops-0` `ab46803751b2245705c62d4d8c44e928273996a0f8008aabda08cf1e3ef5f6c8`,
`pstore-l1-223905/console-ramoops-0` `9d10b6ef4394e8112569b8f6395cc15ad275c0e6c10f5ecd01ee4c046ee7ae6c`,
`pstore-l1-223905/pmsg-ramoops-0` `8daa5ecc2ffd7ce3c1fad551cd15cc7e45b8acbac95ca78e585d3869bc5c2995`,
`pstore-rung2-224916/console-ramoops-0` `c4d21f1d1231b2f314c992608adea9c9eb8a9abd895fc7232a51942a4cef5d5b`,
`pstore-rung2-224916/pmsg-ramoops-0` `54af8364e13bdd65c72d615abc54ba3c113c3d65b543089a3ed823e4a519fb7f`,
`pstore-rung3-225115/console-ramoops-0` `b91f069168ea77093da8a44c2dd0f62be3aef8f347c069fe61a90a030cf87683`,
`pstore-rung3-225115/pmsg-ramoops-0` `9418f9c77cd1a9268342275c48b6bdad86c17a64db42640458203fd6b6458019`,
`pstore-rung4-225401/console-of-rung3-boot.txt` `595168ba1c40d012fa8e3e2983c853c1b7a9ad2fe06873a0675d9f79fcd60070`,
`pstore-rung4-225401/console-of-rung4-boot.txt` `6dd7d37092b163ee451e08247aa91ad7fdccaca73540200875e70e38d2030eed`,
`pstore-rung4-225401/pmsg-of-rung4-boot.txt` `01336214d87c3d9b3b13a4d9dbbe1543a400d28db59e3b95e8e422d70461b875`,
`screencap-l2.png` `96e2256414918c6114864d2d082ce08f10e5b7e53e3aa1efc62cf54fbf71290a`,
`screencap-l3.png` `799d11ba3ffec45626e530ed84dc494e371bc9bd7deddbeb9ec8b8f4bb5c3c4b`,
`screencap-l1.png` `07f1110d405265c3dc5eaf863a79ecddf3ffaaa54bed8bb244dffe239bf12d09`,
`pstore-restore-225749/screencap-restored.png` `8cee01af28a18fe2ba58f96aff6c39309a1c8f2a7e3d7865cdb1fe0f71246a27`.

## Nov 19 (night, third half) - L2 was written, and the unit stopped answering; no log could be read

**L2** (**D62**: Android 14's static first-stage `init` inside the stock Android 10 ramdisk, against the Android
10 `super`) was built offline with two new tools and written once. It is the only Android 14 content the unit has
been given since Nov 18.

What was built:

* `scripts/build_l2_ramdisk.sh` unpacked the capture's own ramdisk (gzip 803,440 B at 25,675,776, cpio
  1,870,336 B), replaced `/init` with Android 14's first-stage binary (`631f960cbb96…`, 3,644,288 B, extracted
  from the payload ramdisk), and added `/first_stage_ramdisk/fstab.rk30board` - the **stock** fstab, not our
  payload's, because our payload fstab lists `system_ext` which Android 10's `super` does not contain. Verified
  by unpacking the archive again: `/init` hashes as the payload init, the fstab under `first_stage_ramdisk` is
  byte-equal to the stock one. Result: gzip 1,628,683 B, sha256 `6456104e82c0…`.
* `tools/build_l2_boot.py` assembled the partition from that ramdisk with the OEM kernel (`a514a3ffb77e`) and OEM
  `second` (`fb80617e7c97`) carried verbatim, header changed only in `ramdisk_size` (1,628,683 B) and the
  cmdline field, ramdisk at 25,675,776, `second` at 27,305,984, content end 28,231,680, and the OEM tail carried
  verbatim from there - the resource header stays at 32,092,160 and both its entries still verify (`rk-kernel.dtb`
  157,962 B `a6da38a41c07`, `logo.bmp` 384,572 B `a52ea8dbca38`). Cmdline 418 B: the stock 334-byte field plus
  `printk.devkmsg=on`, `loglevel=8`, `panic=12` (**D72**/**D73**) and
  `androidboot.init_fatal_reboot_target=recovery`.
* Final image: `a14-work/ladder/L2-init14-in-a10rd.img`, 33,554,432 B, sha256 `eaf9b7de30f9…`.

What happened: the image was pushed, its digest matched on the device before the write, `dd bs=1M count=32
conv=fsync` wrote all 33,554,432 B, partition 7 went `4121b58f7759…` -> `eaf9b7de30f9…`, `misc` still
`909bdd979111…`. `adb reboot` at 23:34:56 CET. After that the unit **never answered again**: no TCP adb through
eight connection tries, then eight further probes over ten minutes (last 23:44:09), and `ping -c 3` returns 100 %
packet loss with "No route to host". So this boot did not reach the point where adbd comes up, and the write left
the unit unreachable.

**The measurement we needed is lost.** The console record of the L2 boot lives in RAM; reading it needs a shell,
and the only shell we have is TCP adb. A warm reboot would have handed it over - but the boot that ran L2 never
came back up to be rebooted, and a cold power cycle erases the RAM records (the Nov 18 restore proved that). So we
know *that* it failed and not *where*. What the record would have shown is what **D69** established for a working
boot: init's own first-stage lines, and Android 14 init reports its failure reasons directly (`First stage mount
skipped`, `Could not bind mount /first_stage_ramdisk to itself`, AVB and fstab errors, `Failed to mount required
partitions early ...`). Two candidate causes are consistent with everything measured offline, and neither is
provable from what we have: Android 14's init refusing the Android 10 SELinux policy (the payload's own vendor is
A14-era while `/system` is A10's), or first-stage mount failing on the A10 partition set the stock fstab describes.
`androidboot.init_fatal_reboot_target=recovery` was in the cmdline, and u-boot does honour a recovery hand-off
(`uboot.bin` contains `reboot-recovery`, `b.mode=recovery`, `Could not found misc partition, just run recovery`),
so the likely physical state now is the stock recovery partition - which runs `adbd` over the USB gadget only
(`recovery.bin`'s ramdisk `init.rc`: `service adbd /system/bin/adbd --root_seclabel=u:r:su:s0
--device_banner=recovery`, `socket adbd`, `setprop sys.usb.config adb`) and has no wireless-adb property, because
`persist.internet_adb_enable` lives in `/data` and recovery does not mount `/data`. That is why our route is gone,
and it is the rule **D75** now records.

**Partition state at the moment it went silent** (all read before the reboot): partition 7 `eaf9b7de30f9…`, `misc`
`909bdd979111…` exactly as captured - never written, `super` `535dac26946d…` = the Nov 18 live digest, unchanged,
`uboot`/`trust`/`dtb`/`dtbo`/`vbmeta`/`security`/`recovery`/`frp` untouched, `/data` untouched. The rollback image
is still on the unit at `/data/local/tmp/stock.img` (`4121b58f7759…`) and in
`a14-work/hu-stock-backup-refresh/boot.bin`, but nothing we can reach can write it: the card route (**D39**, the
owner's bootSD) or USB adb into the stock recovery are the only ways back to Android 10, and both are owner-side.

Full digests of the L2 files, so any later session can verify what it is holding:
`a14-work/ladder/L2-ramdisk.gz` `6456104e82c0a7cc32d7effdaaa2178a7e97af4aad0968f02912f942f780cd97` (gzip
1,628,683 B, cpio 3,650,048 B), `a14-work/ladder/L2-init14-in-a10rd.img`
`eaf9b7de30f9ee8447ca4a4f27e82782f253faa3388171a51c02962b8ade3b70` (33,554,432 B), and the Android 14
first-stage `init` that went into it `631f960cbb96149069228b04287739129e40ac83c8c0b82ddd6c65f05d4a4c56`
(3,644,288 B, from `a14-work/tmp/ramdisks/a14/init`). Partition 7 held that image when the unit went silent,
and `/data/local/tmp/l2boot.img` on the unit carries the same digest.

## Nov 20 (afternoon) - the owner restored the unit through recovery on the SD card, and the L2 log is gone

The owner reached the recovery menu by their own forced-recovery grip ("vulkandeathgrip") and installed the OEM
package from the external SD card. The unit booted Android 10 again without a `/data` or `cache` wipe, and TCP adb
came back by itself at `192.168.1.120:5555` - reachable at 14:32:17 CET, first probe. Everything below was read
after that; nothing was written.

**Partition 7 no longer holds the Nov 17 capture.** The package rewrote `boot`, and the partition now hashes
`b449aee98c01a7da797be1c2aa8238ce4bef3e5ee3ae731afdcf3c53218c4384` (`b449aee98c01…`), captured to
`a14-work/hu-stock-postflash-143452/boot.bin` (33,554,432 B). Against the capture `4121b58f7759…` it differs in
605,548 bytes, all inside one span starting at 27,406,336 - the area between the Android image's own content end and
the tail resource header. The kernel blob, the ramdisk blob, the `second` blob, the header fields
(kernel 25,671,688 / ramdisk 803,440 @ 25,675,776 / second 924,672 @ 26,480,640), the cmdline field, both DTB
copies in the tail (`32,093,696` and `32,636,928`, 157,962 B) and both resource entries (`rk-kernel.dtb`
`a6da38a41c07`, `logo.bmp` `a52ea8dbca38`) are byte-identical, and the DTB copy inside `second` sits at 26,482,688
in both. In that middle span the capture carried 587,556 non-zero bytes that look like splash pixel data
(`e818d20980ffffff…`), while the package's image carries 70,595 there - the beginning of a DTB whose visible
strings are `opp-table0`, `operating-points-v2`, `cpu_leakage`, `specification_serial_number`, `customer_demand`,
`soc-thermal` and the `opp-*` nodes. So the difference is OEM data the boot path does not need, and both images
boot. Consequence: the rollback image for partition 7 is now this post-flash capture, not the Nov 17 one (**D76**).

**The L2 boot's console record is gone, and its cause stays unknown.** The record that survived into this boot is
the *flash* boot's: `console-ramoops-0` 54,883 B `2f8289fa9abff09a0cefad954c0ed6832cae73e98e7ac8b57cca4da483344aa3`,
916 lines, ts 0.0 .. 365.763177, ending `reboot: Restarting system with command ''`. Its `Kernel command line`
line carries `storagemedia=sd`, and one line says `init: First stage mount skipped (recovery mode)` - i.e. it is
the recovery-from-SD boot, not the L2 boot. It contains no `printk.devkmsg=on`, no `loglevel=8`, no `panic=12`, no
`androidboot.init_fatal_reboot_target`, so the L2 text was overwritten by the boot that followed it. That fixes the
limit that **D69** left open: a console record carries the *previous* boot's text, so a failed boot's log is
readable only from the boot immediately after it, and an intervening recovery or flash boot destroys it.

`pmsg-ramoops-0` survived as 1,004 B `374e8080cbd6028e96d1ab72d10dbb5c0a7e272fa7a1c715f0e96b9af0288914` and holds
recovery's own log, which is the record of the restore itself: `adbd` messages `opening control endpoint
/dev/usb-ffs/adb/ep0`, `UsbFfsConnection constructed`, `USB event: FUNCTIONFS_BIND` (**D74**: recovery's adbd does
bind a USB gadget), then `recovery:last_install./mnt/external_sd/update.zip` with the success flag `1`,
`time_total: 333` s, `retry: 1`, `target_build: eng.hct2.20250401.152740`, `bytes_written_dm-0: 985632768`,
`bytes_written_dm-1: 323530752`, `bytes_written_dm-2: 1273569280`, `bytes_written_dm-3: 539951104` (3,124,451,704 B
written through the update engine), `temperature_start: 24444`, `temperature_end: 34444`, `temperature_max: 34444`.
The entry appears twice, so the flash ran once and was logged twice, or the record holds two identical entries.

**What the L2 failure looked like, and what the partitions say about it.** The owner observed, after the write I
made (not after the stock.zip flash): the OEM logo, then a continuously black but illuminated LCD - the logo, not a
boot animation. So u-boot drew its splash, the kernel took over the framebuffer, and PID 1 never reached the point
where the framework starts the animation. The two measurements that constrain the cause: `misc` still hashes
`909bdd979111…` byte-exactly as captured, so init never wrote a Boot Control Block - the fatal-reboot path never
ran, which is why the unit did not enter recovery on its own and needed the owner's forced grip; and the boot
partition stayed the L2 image while it was silent, so every retry ran the same failing image. That makes "init
hung or exited before the fatal-reboot path" the reading consistent with the evidence, and leaves the actual
failure line unmeasured. Android 14's own init reasons (`First stage mount skipped`, `Could not bind mount
/first_stage_ramdisk to itself`, `Failed to mount required partitions early ...`) never reached the console, so the
two candidates from Nov 19 - Android 14 init rejecting Android 10's SELinux policy, or first-stage mount failing on
Android 10's partition set - remain unresolved.

**State after the restore** (all read at 14:32-14:35 CET): `sys.boot_completed=1`, fingerprint
`rockchip/rk3399/rk3399:10/QQ2A.200305.004.A1/eng.hct2.2025`, `wlan0` up, `init.svc.surfaceflinger` running,
`init.svc.bootanim` stopped, kernel `4.19.111+`, boot id `e227f00b-e8ef-4dd6-8599-a9b4f7c39ea7`, uptime 705 s at the
screencap. The panel renders: `a14-work/tmp/pstore-after-stock-143217/screencap.png` 218,799 B
`4edfe7a4ec107cdf5b448ee1df14fb0f4472bb2f93444d01bd88088ebd738a7e`, 1024x600, 9,033 distinct sampled colours,
488,446 pure black of 614,400 pixels. `/data` is intact and unwiped: `df /data` reports
`/dev/block/mmcblk2p15 56123392 9183420 46939972 17%`, and `/data/local/tmp` still holds `stock.img` (the Nov 17
capture), `l2boot.img` (`eaf9b7de30f9…`), `l3.img`, `l4.img`. `super` still hashes `535dac26946d…` = the Nov 18
live digest, `misc` still `909bdd979111…`, and nothing outside `boot` was written by the package's own install as
far as our read route could see. Files: `a14-work/tmp/pstore-after-stock-143217/` (`console-ramoops-0`,
`pmsg-ramoops-0`, `screencap.png`, `state.txt` `10d2f5805b3fd14fc981a0093f92a1681ce0a248c996655f6e0608a7a474f0e5`).

## Nov 20 (late afternoon) - the diagnostic token set moved onto the new base image, and recovery has no adb route

The rung built from the post-flash capture (`b449aee98c01…`) with `tools/patch_boot_cmdline.py`, adding
`printk.devkmsg=on`, `loglevel=8`, `panic=12` (**D73**) and nothing else:
`a14-work/ladder/L5-diag-on-newbase.img` `3de96f683b7409f8f8d3c3b7784a0c17231598597ed69db626f0e73a50a14ad5`
(33,554,432 B). It differs from the capture in **38 bytes**, all inside the 512-byte cmdline field (398..435) - the
patch tool verifies that no byte outside the field moves. The cmdline became 372 B: the capture's own 334 B plus the
three tokens.

Executed 15:20-15:26 CET, one write, whole partition, rollback staged first (`/data/local/tmp/stock2.img` = the
capture, digest verified on the device): partition 7 `b449aee98c01…` -> `3de96f683b74…`, `misc` untouched. Android
10 booted unchanged (`sys.boot_completed=1`, OEM fingerprint, `wlan0` up, boot id `66e23c41-9f0b-48f3-a45a-459938914283`),
with all three tokens in `/proc/cmdline` after u-boot's own additions. A warm reboot then handed over that boot's
record: `console-of-diag-boot.txt` 183,405 B `7ffec7b1641d9e5cd0abdc2f4b0b0ade48a2f3cae5a171c2308a1e2da749f89b`,
2,411 lines, ts 0.0 .. 135.359064, no ratelimit notice, 832 `init:` lines, `console [pstore-1] enabled` at
0.054359, `pstore: Registered ramoops as persistent store backend`, `pstore: Using compression: deflate`, and the
three tokens in the record's cmdline line. `pmsg-of-diag-boot.txt` 262,132 B `42b99f7e341aa96ddeda387640a20d6a2b1e31389e475a31c6bf4f37e7a5a4e0`.
Both screencaps render: `pstore-diag-152104/screencap-diag.png` `665bfb3153cc9847c5dcce7d1ac86f25e2cce389f1ad23f8a79dffdf66f0651d`
(1024x600, 9,033 distinct sampled colours, 488,314 pure black) and
`pstore-diag-restore-152510/screencap-restored.png` `408f53caf4d9b45995f96466777c563e92b83631f6f26fc3764a34babc72785c`
(9,035 colours, 488,001 pure black). Partition 7 was then restored to the capture and verified again at 15:25:54 CET:
`b449aee98c01…`, `boot_completed=1`, `wlan0` up, zero tokens in `/proc/cmdline`, `misc` `909bdd979111…`, `super`
`535dac26946d…`; the record pulled from that boot is `console-of-diag-restore-boot.txt`
`d60bc08eb7257aa168ddc878bc66573da99ae5eed9216057e6b2b932cfd9e1d4` (it carries the diag boot's text, as **D77**
predicts). Boot ids this afternoon: restore-into-Android10 `e227f00b-…`, diag boot `66e23c41-…`, restored again
`ea6147d4-…`. Only `boot` was written; `misc` was never written; `super` was not resized (**D18**/**D19**).

**Recovery cannot be reached as a shell from this workstation.** The owner reports that none of the unit's USB
ports drive adb - they are host-mode ports (their phone is on the one most suspected of being the adb port), and
the head unit cannot be made the device-side controller. So the `adbd` we saw in recovery's pmsg log was bound to
whatever host was attached, not to us, and recovery stays owner-side (**D74** unchanged). Offline, the recovery
ramdisk also shows it would not mount pstore by itself: its `init.rc` has no `mount pstore` line (only `cgroup`,
`tmpfs /tmp`, `configfs`, `functionfs adb/fastboot`), so a shell there would have to mount it manually. What
recovery *does* open is a serial shell: `init.recovery.rk30board.rc` has `on fs && property:ro.debuggable=1 ->
start console`, and `service console /system/bin/sh` with the `console` keyword - and this unit is
`ro.debuggable=1`, `ro.build.type=userdebug`, with `console=ttyFIQ0` in the kernel cmdline. That makes the UART
route (**D63**, still declined Nov 19 "Not yet") the only channel that can read a failed boot when TCP adb is gone,
and it is now a root-level shell in recovery rather than only a console log (**D79**).

## Nov 20 (recovery unbanned) - partition 8 becomes writable under one condition, and it is the route that was missing

The owner lifted the ban in writing: *"I hereby officially lift the ban on writing recovery as long as functionality
including MTC fralshing remains intact. Signed The owner"* (**D80**). Measured at the moment of the lift, all reads,
nothing written:

* Partition 8 hashes `1fdf5ea77fc6…` over its full 100,663,296 B (`dd bs=1M count=96` through `toybox base64`),
  byte-identical to `a14-work/hu-stock-backup-refresh/recovery.bin` - so the capture is a faithful rollback image,
  and the patched candidate built Nov 12 (`a14-work/recovery-patched/recovery-patched.img`, 39,108,608 B content-sized,
  `a0cd9de318a8…`) is the only patched recovery we have.
* Nothing on this firmware re-flashes recovery behind our back: `/vendor/recovery-from-boot.p` is absent and
  `/vendor/etc/init/vendor_flash_recovery.rc` is absent (`ls` both, at 16:1x CET). The stock flow that re-flashes
  recovery from `boot` is therefore not present in the Android 10 vendor, which is what makes a patched recovery
  stick until someone writes partition 8 again. **Corrected Nov 21 (D82): the flow is present, it just lives in
  `/system` instead of `/vendor`. `/system/bin/install-recovery.sh` - init service `flash_recovery`, measured
  running at t=19.9 s in the boot's own console record - runs `applypatch` with target
  `recovery:39122944:f75bcfb46815…` and source `boot:27406336:ecb5315f120b…`, so partition 8 is rewritten back to
  stock on every Android 10 boot while partition 7 hashes that source digest. A patched partition 8 does not stick
  across an Android 10 boot; it persists only while partition 7 holds a payload whose digest differs.**
* The recovery boot we captured Nov 20 ran with `androidboot.selinux=permissive` and
  `androidboot.veritymode=enforcing` in its cmdline, so a script there is not blocked by policy, only by the kernel.
* The recovery ramdisk's tool set is complete (`system/bin/` lists `sh`, `mount`, `umount`, `dd`, `mkdir`, `cp`,
  `cat`, `toybox`, `sha256sum`, `unzip`, `losetup`, `make_f2fs`, `mke2fs`, `recovery`, `adbd`, `fastbootd`,
  `microcom`, `devmem`), and its `init.rc` creates the `/cache`, `/data`, `/system`, `/metadata` and `/sideload`
  mount points, starts `ueventd` (so `/dev/block/by-name/*` exists), and its `recovery.fstab` names
  `user`/`external_sd` (`/mnt/internal_sd`, `/mnt/external_sd`), `system`, `vendor`, `odm`, `cache`, `metadata`,
  `userdata`, `misc`, `boot`, `recovery` and the Rockchip-only entries (`cust`, `custom`, `radical_update`,
  `charge`, `resource`, `parameter`, `backup`, `frp`, `trust`, `baseparamer`, `vbmeta`, `dtbo`).
* The trusted cert in that ramdisk (`system/etc/security/otacerts.zip`, single entry `testkey.x509.pem`) is HCT's
  own clone: serial `92A528C773D7A141`, notBefore Dec 23 2014, sha256 fingerprint
  `cf:2a:b3:81:85:95:c4:ed:a0:8c:ec:72:bb:e3:9b:c3:77:a3:0b:76:4a:3e:eb:de:52:53:6e:ae:01:80:85:25`. Our key pair is
  the AOSP testkey (`CN=Android`, serial `936EACBE07F201DF`, fingerprint `a4:0d:a8:0a:59:d1:70:ca…`), whose modulus
  does not match that cert - so a package we sign is *not* accepted by this recovery (**D25** unchanged), which is
  why the route that matters is a patched partition 8, not a package.

Consequence for the ladder: the condition that made a second Android 14 attempt unwritable (**D78**) can now be met
without UART (**D63** stays declined) and without a card slot we cannot drive - recovery itself becomes the reader
and the restorer. What is owed next is the patched image built from the current capture, then one recovery boot to
prove the script runs and that the stock install path is untouched.

## Nov 20 (evening) - partition 8 got the patched recovery, and the first run stopped at the recovery menu

**A tooling bug rebooted the workstation.** `scripts/hu_recovery_evidence.sh` ended with a bare
`reboot 2>/dev/null || $BB reboot 2>/dev/null`. The offline dry-run ran the script on the workstation, so the
first word reached the host's own `/usr/sbin/reboot` and the workstation went down (Nov 20, ~17:0x CET; it came
back with 14 min of uptime). Nothing on the unit or in the repo was written by that: the script had only touched
its fake tree under `a14-work/tmp/rec-smoke/`. The script now refuses to run without
`/dev/block/by-name/misc` and `/sbin/busybox` (the recovery ramdisk's own markers) and its reboot goes through
busybox only. This is recorded as a failure, not smoothed over: **a script written for the unit must never be
runnable on the host**, which the dry-run exposed because the dry-run execs the real file.

**Four offline scenarios pass after the fix**, run against the mapped fake tree (device paths, `/sbin/busybox`,
`/sbin/sh`, `/sys/fs/pstore`, `/dev/mem` all redirected into `a14-work/tmp/rec-smoke/`): package on the card and
no request -> records copied, UI left alone, no reboot; request present and rollback equals partition 7 ->
`restore-skipped.txt`, reboot requested; request present and rollback differs -> `restore-ok.txt`, reboot
requested, partition 7 digest equals the rollback's; guard tripped (no `misc`, no `busybox`) -> exits 1 and does
nothing. The fake busybox maps applets onto host coreutils, so the size/digest lines in the fake log are shim
artefacts, not measurements.

**Partition 8 now holds the patched recovery.** Built from the current capture by
`scripts/patch_recovery_evidence.sh`: `a14-work/recovery-evidence/recovery-evidence.img` 39,086,080 B
`a4cf5533482e88e66b6bd6c250e7052887ba15bebeff2d1712ca8eaff6a7413c`. Against the capture `1fdf5ea77fc6…`: kernel
blob `a514a3ffb77e`, `second` blob `fb80617e7c97` and `recovery_dtbo` `28a07d4946e9` byte-identical; header page
differs only at bytes 16..19 (`ramdisk_size`) and 1636..1643 (the stored dtbo offset); ramdisk 12,519,199 ->
12,481,780 B (485 cpio entries); the appended block adds exactly one `service hu_evidence` and one
`start hu_evidence`, and the stock `service console` and `sys.usb.controller` lines are still there once each.
Written with `dd bs=4096 count=9546` (39,086,080 B) and read back: the partition's first 39,086,080 B hash
`a4cf5533482e…`, byte-for-byte equal to the image; partition-wide digest moved `1fdf5ea77fc6…` ->
`a022cfb26ef9…`. Partition 7 stayed `b449aee98c01…` and `misc` stayed `909bdd979111…`. A read-path trap worth
knowing: `dd bs=4096 count=9546 … | toybox base64` came back 14,336 bytes longer than the requested span (zero
padding), so a digest taken over that pipe is not the image digest - compare over the exact byte count instead.
Before the write, `/cache/hu-rollback-boot.bin` (`b449aee98c01…`) and `/cache/hu-restore.request` were staged
over adb, so the recovery was supposed to restore-and-reboot by itself.

**Then the unit stopped answering and the owner found it sitting in the recovery menu.** `adb reboot recovery`
reported "device not found" (TCP adb does not exist in recovery, **D74**), and from ~17:17 CET onward there is no
adb and no ping reply - through 18:47 CET the unit has not answered at all. The owner reports the panel shows the
recovery menu, which is good news about the patch: the stock recovery UI is alive on the patched image, so the
mainboard/MTC flashing path is intact (**D80**'s condition). The bad news is that the automatic hand-back did not
happen with the request staged, so either the service never ran, `/cache` was not mountable in recovery, or
busybox's `reboot` did nothing. Which of those is true is written in `/cache/hu-evidence.log`, and that file only
becomes readable once the unit boots Android 10 again.

**What is owed to the owner, and what the answer costs.** A cold power cycle, not a menu choice: this unit enters
recovery through the kernel's reboot-mode, not through `misc` (`misc` did not change on Nov 20 when recovery ran
from the card, and it did not change tonight), so a menu reboot can land back in recovery. A cold cycle boots
u-boot -> partition 7 -> stock Android 10, and `/cache` survives because it is flash. The cost is the recovery
boot's own console record (**D69**: a cold cycle erases RAM records) - the record we wanted tonight is the
*Android 10* boot's text, which the script would have copied into `/cache` before the cycle, so if the log says it
ran, the record is already saved; if the log is missing, we learn the service did not run and fix that before any
Android 14 image goes back on the unit (**D75**/**D78** still hold until this route is proven).

## Nov 20 (late evening) - the evidence script was rebuilt and logic-tested offline; four defects came out of it

The first patched recovery is on partition 8 (`a4cf5533482e…`, see above) and the unit is parked in the recovery
menu, so nothing further was written tonight. What ran tonight was offline: the ramdisk's real tool set was
measured out of the capture, `scripts/hu_recovery_evidence.sh` was rewritten against that measurement, and
`scripts/smoke_recovery_evidence.sh` runs the real script against a fake world. Four defects were found; three
of them would have cost the owner a boot.

**The ramdisk's tool set, measured by strings over the extracted `sbin/busybox`.** `awk cat cut date echo expr
grep head md5sum mkdir mount reboot sed sha1sum sleep stat sync tail touch umount` - and **no `dd`, no `wc`, no
`cp`, no `rm`, no `ls`, no `tr`, no `sha256sum`**. The same ramdisk ships `/system/bin` (toybox plus real
binaries: `sha256sum dd tr rm wc cp ls blockdev devmem sh`, most of them symlinks to `toybox`) together with
`/system/bin/linker64` (1,445,568 B) and `/system/lib64` (`libc.so`, `libdl.so`, `libc++.so`), so those run
here before recovery mounts the system slice. The script therefore never asks busybox for something it does not
have: partition reads go through `cat`, sizes through `stat -c %s`, the raw RAM read through `tail -c +N | head -c`,
nothing is deleted, digests prefer `/system/bin/sha256sum` and fall back to `sha1sum`/`md5sum`, and printable
extraction uses `/system/bin/tr`. The harness refuses `dd wc cp rm ls tr sha256sum` on its busybox shim, so a
regression that reaches for them fails loudly instead of passing.

**Defect 1 - the evidence directory vanished under the mount.** The run mounted cache but had created
`/cache/hu-evidence` *before* the mount, so the directory disappeared under the mount point and every copy
failed with `No such file or directory` - that is why the first run produced no evidence and no log. `/cache` is
mounted first, then the directory is created inside the mounted partition. The harness asserts the mount line
precedes the directory line, and asserts a consumed request cannot re-arm a restore.

**Defect 2 - a digest that could not be read looked like a match.** The restore compared `before` and `want`;
when the digest tool produced nothing, both sides were empty strings and compared **equal**, so the script wrote
`restore-skipped.txt`, left the risky image in partition 7 and reported success. `dig()` now checks the *output*
being non-empty rather than the pipeline's exit status (the exit status belongs to the last command in the
pipeline), and an unreadable digest means "write the rollback anyway" with the result recorded as
`restore-unverified.txt`. Writing the known-good image is the safe direction; skipping on an unreadable digest is
not. Scenario 7 of the harness covers exactly that.

**Defect 3 - a request could re-arm the restore, and busybox cannot delete it.** With no `rm` applet, the
request file survived, so every later recovery boot would restore again. The request now carries a nonce, and the
done-marker is named after it (`/cache/hu-evidence/restore-done-<nonce>.txt`); a fresh request with a new nonce
arms a fresh restore, the same nonce never does. `restore-nonce.txt` records which nonce was consumed.

**Defect 4 - rebooting from recovery can land back in recovery.** This unit enters recovery through the kernel's
reboot-mode, not through `misc` (findings, "Nov 20 (evening)"): `misc` did not change when recovery ran from the
card, and did not change tonight. So the tail of the script only attempts `$BB reboot` when this boot actually
did something - evidence copied, a restore performed, or a restore skipped - and the log line names the fallback:
*"if this lands back in the recovery menu (reboot-mode), a cold power cycle boots partition 7"*. Whether a plain
warm reboot clears the mode is not measured yet; tonight's parked menu is the evidence that it may not.

**The offline gate, `scripts/smoke_recovery_evidence.sh`, rc 0 (9 scenarios).** Fake `/proc/mounts` in
mounts-style lines, fake by-name files, fake `/sys/fs/pstore`, fake `/dev/mem` covering `0x110000..0x210000`, and
two fake bin trees (`binfull` mirrors what the ramdisk ships, `binbare` carries the file tools but no digest tool).
Scenario results: guard outside the unit - rc 1, nothing written, no mount attempted; no request - cache mounted
before the directory, records copied, partition 7 untouched, reboot requested so the record becomes readable over
adb; request staged and partition 7 differs - rollback written through `cat`, digest verified, done-marker named
after the nonce, request file kept; same nonce cannot re-arm; partition 7 already on the rollback - skipped, not
written; request with no rollback - partition 7 untouched, reason recorded; no digest tool - restores anyway and
writes `restore-unverified.txt`, never a false skip; a package on the card - the restore still runs but recovery
is left alone, no reboot (**D80**'s condition); pstore absent - the raw RAM read lands at the right offset and the
printable view comes from `/system/bin/tr`. Partition-7 assertions compare digests, not sizes, because `truncate`
does not clear bytes that are already there.

**What the harness does not prove:** the shell dialect. busybox ash is not on this host, so POSIX syntax is
checked here with `bash --posix -n` (passes) and still has to be checked with `dash -n` and `busybox ash -n` on
the build host before partition 8 is written again.

**Rebuilt candidate.** `scripts/patch_recovery_evidence.sh` ran on the current capture:
`a14-work/recovery-evidence/recovery-evidence.img` is 39,088,128 B, sha256
`d64ebd22d6142554d0b788373889059e88d66c7b1eddb8453ccadbb3fb76094a`, replacing the `a4cf5533482e…` build that is
on the disk now. Kernel blob `a514a3ffb77e`, `second` blob `fb80617e7c97` and `recovery_dtbo` `28a07d4946e9` are
byte-identical to the capture; ramdisk gzip 12,519,199 -> 12,483,273 B at 25,675,776 (485 cpio entries, no
duplicates); header changes only `ramdisk_size` and the stored dtbo offset (offset 1636); the appended rc block
keeps the stock 663 B verbatim and adds 431 B (one `service hu_evidence`, one `start hu_evidence`, stock
`service console` and `sys.usb.controller` lines still one each). The injected `/sbin/hu-evidence.sh` hashes
`6c69e501d9d452ff10cb09f62f35fc26338c77553d34d284c7d044ad0af5479e`, identical to `scripts/hu_recovery_evidence.sh`.
Nothing was flashed in this pass; the unit stays parked until the owner cold-cycles it. Evidence file:
`analysis/recovery-evidence.txt`.

## Nov 21 (early) - partition 8 is stock again, and the reason is `install-recovery.sh`, not the OEM package

**Partition 8 read back as the capture.** A full read of partition 8 (`toybox dd bs=1M count=96` through
`toybox base64`, decoded locally) is 100,663,296 B hashing `1fdf5ea77fc66f48977d7846c468959a5845d0222dc73c3fe07a1b96b6cb023b`
- byte-identical to `a14-work/hu-stock-backup-refresh/recovery.bin`. The kernel blob is `a514a3ffb77e`, and the
first 39,104,512 B compared against the capture with **zero differing bytes**. So the patched recovery
(`a4cf5533482e…`, then the 21:34 build) is off the disk today. Partition 7 still hashes
`b449aee98c01…` (**D76**) and `misc` is unchanged.

**The mechanism, found by reading the boot's own console record.** The record the recovery run copied
(`/cache/hu-evidence/console-ramoops-0`, 67,548 B, 1,093 lines, sha256 `0691c6be…`) is the text of the
*Android 10* boot that preceded the recovery boot: its kernel cmdline carries `androidboot.mode=normal` and
`b.mode=normal`, and its last line is `reboot: Restarting system with command 'recovery'`, preceded by
`init: Received sys.powerctl='reboot,recovery' from pid: 8684 (/system/bin/adbd)` - our own adb-triggered
reboot. Inside that record, at t=19.9 s: `init: Service 'flash_recovery' (pid 313) exited with status 0`.
The Nov 13 probe already carried `init.svc.flash_recovery: stopped` and `ro.boottime.flash_recovery`, and
this boot carries `ro.boottime.flash_recovery: 3759993000`. The service is `/system/bin/install-recovery.sh`:

```
applypatch --check EMMC:/dev/block/by-name/recovery:39122944:f75bcfb46815c97c6464a939fcbcc9fdff6991c5
applypatch --patch /system/recovery-from-boot.p --source EMMC:/dev/block/by-name/boot:27406336:ecb5315f120b5008094ff8bf6b62063257fc363d --target ...
```

Both digests verify against the images we hold: partition 8 over its first 39,122,944 B hashes exactly
`f75bcfb46815…` (so today's check passes and says "Recovery image already installed"), and partition 7 over
its first 27,406,336 B hashes exactly `ecb5315f120b…` - the same digest for the Nov 11 stock backup boot and
the post-flash `b449aee9` image, which is what L0's byte-identical repack produced. The patch file is
`/system/recovery-from-boot.p` (11,805,157 B, sha1 `fd7418c590e0…`), applied by `/system/bin/applypatch`.

**Why the Nov 20 claim was wrong.** The Nov 20 note checked `/vendor/recovery-from-boot.p` and
`/vendor/etc/init/vendor_flash_recovery.rc` and found both absent, concluding nothing re-flashes recovery.
This firmware keeps the patch in `/system`, not `/vendor`, and defines the service in init rather than in a
vendor rc - so the check missed the real path. Consequence, stated precisely: **while partition 7 holds an
image whose first 27,406,336 B hash to `ecb5315f…` (the OEM Android 10 boot, and our byte-identical repacks),
every Android 10 boot rewrites partition 8 back to stock**; a patched partition 8 therefore only survives
between writing it and the next Android 10 boot. With an Android 14 payload on partition 7 the source digest
no longer matches, `applypatch` cannot reconstruct the target, and partition 8 stays as we put it - which is
exactly the behaviour the evidence route needs during payload experiments, and exactly the self-healing
behaviour that protects **D80**'s condition after a restore to stock Android 10.

**Why the 22:06 run never reached the restore step.** `/cache/hu-evidence.log` ends at
`copied pmsg-ramoops-0: 262132 bytes, digest 795baae5…`. The next line the script writes is
`say "p8 digest $(dig /dev/block/by-name/recovery)"`, and that line never appears - the digest of a 96 MiB
block device through `sha256sum` never returned. So the script stalled there and the staged request
(`/cache/hu-restore.request`, nonce `nov20-rung2-1795208096-27817`) was never acted on. Partition 7 needed no
restore anyway: it already equals the rollback. `dig()` now reads through `head -c` with a 64 MiB cap, so a
digest is a bounded read and cannot wait on a device; partition 7's digest stays exact (its partition is
32 MiB), partition 8's is a first-64-MiB digest, and the offline gate asserts the capped value.

**The interpreter is mksh, and the gate can run on the unit.** `busybox-applets.txt` came back 0 bytes on the
unit because this busybox build has no `ash` applet and no `--version`/`--list` handling: run as
`busybox --version` it answers `applet not found`. The recovery ramdisk's `/sbin/sh` is **MIRBSD KSH R40**
(`KSH_VERSION=@(#)MIRBSD KSH R40 2011-10-07`, static 32-bit ARM, 206,684 B) - the same family as Android's
`/system/bin/sh`. Pushing that exact binary to `/data/local/tmp` and syntax-checking the script with it gives
`hush -n /data/local/tmp/hu-evidence.sh` rc 0 on the unit, and the device's own `sh -n` also gives rc 0. The
dialect gate is therefore the ramdisk's own mksh on the unit, not `dash -n` or `busybox ash -n`, and it no
longer needs the build host. Nothing was executed against a partition: `-n` parses and stops, and the script
itself refuses to run outside the recovery ramdisk (its guard needs `/dev/block/by-name/misc`, `/sbin/busybox`
and `/sbin/sh`, none of which exist in Android 10).

**Rebuilt candidate, offline.** `scripts/patch_recovery_evidence.sh` ran against the capture:
`a14-work/recovery-evidence/recovery-evidence.img` is 39,088,128 B, sha256
`dfe61ba7b3d6e0344dc5831c49e219fb157baaac73ad4812655cbdac761fb199`. Kernel blob `a514a3ffb77e`, `second`
blob `fb80617e7c97` and `recovery_dtbo` `28a07d4946e9` byte-identical to the capture; ramdisk gzip
12,519,199 -> 12,482,657 B at 25,675,776 (485 cpio entries, no duplicates); header changes only
`ramdisk_size` and the stored dtbo offset; stock `init.recovery.rk30board.rc` keeps 663 B verbatim and adds
431 B (one `service hu_evidence`, one `start hu_evidence`, stock console and usb-controller lines still one
each). Its sha1 over the applypatch target span is `c72cae70cb96…`, which is why the check fails and the
patch rewrites recovery on an Android 10 boot. Injected `/sbin/hu-evidence.sh` hashes
`646c0a709742a53116bdaa7de1bbf3ef7c5a96e063adcb20548371c398ed3747`, equal to `scripts/hu_recovery_evidence.sh`.

**The offline gate now covers what the device actually taught us.** `scripts/smoke_recovery_evidence.sh`
still passes rc 0, nine scenarios, with new assertions: the tool listings (`list-sbin.txt`,
`list-systembin.txt`, `list-by-name.txt`, `mounts.txt`, `busybox-version.txt`) must be written; the `p8 digest`
line must be *reached*; and its value must equal the sha256 of the first 64 MiB of the partition, which is the
regression guard for the stall. The harness maps `/sbin`, `/system/bin` and `/dev/block/by-name` onto fake
directories so `record_tools` lists the fake world instead of the workstation's, and its busybox shim keeps
refusing `dd wc cp rm ls tr sha256sum`.

## Nov 21 (late morning) - the reverter is `/init.rc`'s `flash_recovery`, and it fires before adbd comes up

**The isolation test.** Partition 8 was written twice today from `/cache/hu-patched-recovery.bin`
(`dd bs=512 count=76720` = the exact 39,086,080 B image span; the written span read back as the image's own
sha256 both times), then a plain `adb reboot` (bootreason `reboot,adb`, mode normal). The first read the
moment adbd answered - ~40 s after the reboot, `uptime` still under a minute - already showed partition 8
back on the capture: its first 39,086,080 B hash `3308f7136600ff01d118a5cdb71d931144777fabce67c988e8922829d58a516c`
and its first 67,108,864 B hash `311bfc0f69103db253c7c356dbee641c4350983794a1679e7af9b5a817ade456`, both exactly
the stock capture's prefixes. So the revert happens *before* adbd, not during the recovery boot: a recovery
boot is not needed to undo a patched partition 8. The same boot carries init.svc.flash_recovery stopped and
ro.boottime.flash_recovery 3759993000 - the service ran at boot time 3.76 s, which is why nothing was
seen: the oldest line surviving in logcat at first read was 16 s after boot, and `/dev/kmsg` had rolled too.

**Where the service is defined.** Grepping `/system/etc/init`, `/vendor/etc/init`, `/odm/etc/init` and the
boot ramdisk's `init.rc` found nothing, because the service is in the *root* init rc: a bounded
`find / -maxdepth 4 -name '*.rc'` + `grep -l flash_recovery` returns /init.rc, whose line 854 defines
service flash_recovery /system/bin/install-recovery.sh with class main and oneshot - started with the
main class, hence 3.76 s, no property trigger needed. The Nov 20 check for
`/vendor/etc/init/vendor_flash_recovery.rc` looked only at vendor paths and concluded the wrong thing.

**Boot-stage copy ruled out.** The restore is byte-exact stock over the applypatch target span
(39,122,944 B), and nothing outside Android holds a stock copy: backup (p9, 112,263,168 B) is all zeros;
`mmcblk2boot0`/`boot1` are 4 MiB each, too small; the partitions occupy the disk contiguously (sum
122,666,974 of 122,683,392 sectors, the 8.4 MiB tail is the backup GPT), so there is no hidden region;
`uboot.bin`'s four `ANDROID!` hits are `Kernel load addr 0x%08x` format strings, and uboot has no bspatch
machinery - its flash writes only run in loader mode (`fb_mmc_flash_write`, "Flashing Raw Image"); the boot
partition's tail beyond its content end (27,406,336 B) is pointer-table data, not a patch; boot ramdisk and
`second` reference nothing recovery; vendor kernel modules are WiFi/BT/GPU drivers; no binary outside
`install-recovery.sh` itself references `recovery-from-boot` or `by-name/recovery`. The only stock source is
the patch: `/system/recovery-from-boot.p`, applied against partition 7.

**The pin that explains the payload plan.** `boot.bin`'s content end is 27,406,336 B - exactly the length
applypatch hashes as its source - and the stock `recovery.bin` content end is 39,122,944 B, exactly its
target length. So the patch encodes *this OEM boot image* -> *this stock recovery image*. While partition 7
hashes `ecb5315f…` (stock Android 10 boot, or our byte-identical repacks like `b449aee98c01…`) every Android
10 boot rewrites partition 8 back to stock. With an Android 14 payload on partition 7 the source digest no
longer matches and applypatch cannot reconstruct the target, so partition 8 keeps what we wrote - the
evidence route stays intact during payload boots, and after a restore to Android 10 recovery self-heals,
which is the protection **D80** wanted (**D82** releases the restriction outright).

**Why a patched recovery still boots.** Recovery boots do not run Android's init: the recovery ramdisk's own
`init.rc`/`init.recovery.rk30board.rc` define no flash service, and the kernel loads the recovery kernel and
ramdisk from partition 8 before anything can rewrite it. That is why the Nov 20 patched ramdisk ran at all,
and why the script can read pstore there. Practical rule for the ladder: **write the patched partition 8, then
enter recovery directly - never boot Android in between**, because one Android boot erases the patch again.

**Rebuilds are not byte-reproducible.** The splice re-gzips the ramdisk, and gzip stores timestamps, so three
builds of the same content hash differently: `dfe61ba7b3d6…` (39,088,128 B, earlier script),
`f8a4a779b2fb98786ae0613536c65ff2635bfede3938206c825ddcc2c9660fc7` (written to partition 8 twice today before
the revert experiments) and `8201bde5021eccbb83adb1f66a3ffc6fee9054c9edba9410f7b89c649e295509` (39,086,080 B, current script `646c0a709742…`, after the evidence-file rename away from
names that collide with the offline harness's path mapping). What is registered is the digest of the *staged
copy* that gets written; today `/cache/hu-patched-recovery.bin` = `8201bde5021eccbb83adb1f66a3ffc6fee9054c9edba9410f7b89c649e295509`
and partition 8 was verified live to that digest. Offline gates re-run before any write: `scripts/smoke_recovery_evidence.sh` 9 scenarios
rc 0, and the sandbox harness at `a14-work/tmp/rec-smoke/run-scenarios.sh` scenarios A-F pass (its `run.sh` is
regenerated from the repo source by sed each run, so the harness cannot drift behind the script again).

**Live staging right now.** Partition 8 holds `8201bde5021e…`; `/cache` holds the restore request
(nonce `nov20-rung2-1795208096-27817`, still unconsumed - partition 7 equals the rollback, so the recovery run
will log a skip) and `/cache/hu-rollback-boot.bin` (`b449aee98c01…`, 33,554,432 B). Android must not boot
before the owner enters recovery.

## Nov 21 (afternoon) - the recovery binary read offline: what a recovery of ours may replace

A read-only reverse-engineering pass (nothing executed, nothing flashed) produced
`a14-work/tmp/rec-re/RECOVERY-RE.md` and its working artifacts (`recovery.asm.txt`, `recovery.symbols.dem.txt`,
`refs_all.txt`, `flow_main.txt`, `flow_rku.txt`). What it measured, and what it means for "make it our own"
(**D83**):

**The image layout, corrected.** Page size 2048; kernel 25,671,688 B loaded at `0x10008000` placed at file
offset 2048; ramdisk 12,519,199 B loaded at `0x11000000` placed at 25,675,776; second 924,672 B loaded at
`0x10f00000`; tags at `0x10000100`; the `header_size` and `header_version` slots hold junk, and there are no
v3/v4 dtbo/splash header fields - the dtbo's position (803 B at file offset 38,732,288) is a placement
convention, not a declared field. The cmdline block carries no `androidboot.mode`. The partition tail beyond the
last non-zero byte (offset 38,732,321) is 61,541,596 B of pure zeros: the partition tail beyond the dtbo is
zeros and splash and resource live inside second. That second is the `RSCE` container whose entries carry SHA1
digests (`rk-kernel.dtb`, `logo.bmp`, `logo_kernel.bmp` all verified MATCH) - so any future edit of it must
rehash per entry and keep its 512-byte block layout.

**The recovery kernel banner is #190, not #2416.** The kernel inside recovery.bin reports build #190 dated
Jul 5 2024 CST (banner at file offset within the kernel blob) - an earlier note naming #2416 was wrong. The
kernel is what carries the flashing nodes and reboot-mode driver: `vendor_storage`, `rknand`, the MTC driver
`/dev/mtc-car`, fiq console. Replacing the kernel kills both flashing paths, so it stays byte-for-byte.

**The entry mechanism, corrected.** Recovery is entered because the bootloader picks the recovery partition
image after the kernel's reboot-mode driver matches a dtbo `reboot_mode` marker: normal `0x5242c300`, loader
`0x5242c301`, fastboot and recovery share `0x5242c303`, bootloader `0x5242c309`, charge `0x5242c30b`. Because
recovery and fastboot share reboot-mode marker 0x5242c303 and the misc BCB stage distinguishes them, the misc
Boot Control Block (`boot-recovery` vs `boot-fastboot`, plus `recovery/...` args and `/cache/recovery/command`)
is the discriminator - which reconciles the Nov 19 finding that recovery was reached without `misc` ever being
written by init (the owner's grip forced a key/usb-mode entry) with **D71**'s misc permission. The dtbo also
disables the DT fstab and AVB vbmeta in recovery, so mounts come from `recovery.fstab` and verified boot is off
there.

**The ramdisk is the verifier.** setup_install_mounts does not mount /system, so the ramdisk's otacerts is what
verifies packages. `setup_install_mounts()` mounts only `/ /tmp /cache /mnt/external_sd /mnt/usb_storage`;
`verify_package()` reads the ramdisk's `/system/etc/security/otacerts.zip`, whose single entry is the HCT clone
cert (DER 1023 B, sha256 `cf2ab3818595c4eda08cec72bbe39bc377a30b764a3eebde52536eae01808525`, serial
`92A528C773D7A141`) - the same DER appears verbatim eight times in the stock `system.img`. Consequence: adding
our own cert to that zip inside the patched ramdisk is the only way a package of ours verifies in recovery, and
keeping the HCT entry keeps the OEM `update(1).zip` installable. That reopens the route-1 idea rejected on Nov 9
(**D25**): a signed package would pass verification with a ramdisk cert of ours - still subject to **D83**'s
pairing rule (writing the payload from the recovery boot does not touch partition 8 in the same flash).

**The flashing paths, mapped.** Package discovery: `check_media_package()` scans
`/mnt/usb_storage`, `/mnt/external_sd`, `/storage/external_sd`, `/storage/usb_storage` and `/mnt/media_rw` for
`update.zip`/`update.img`; `check_media_mcu()` scans the same directories for `gmcu/hmcu/imcu/dmcu/nmcu.img`,
`dmcu.ext` and `dmcu.cfg`; plus `/backup/update.zip` and `/sideload/package.zip`. SD-boot reads
`storagemedia=sd` on the cmdline then `/mnt/external_sd/sd_boot_config.config` (keys `pcba_test`, `fw_update`,
`demo_copy`, `volume_label`). Install: `install_package()` -> `verify_package()`; AB branch forks
`update_engine_sideload`; the OEM branch `install_rkloader_package()` extracts the zip entry `RKLoader.bin` to
`/tmp/RKLoader.bin` and runs `do_rk_firmware_upgrade()`; PCBA forks `/sbin/pcba_core`; a factory exit writes the
BCB `recovery\n--wipe_all\n`. The Rockchip flashing engine (`CRKUsbComm`) opens /dev/vendor_storage (the node
name comes from `emmc_point_name`) and writes below the Android partitions: IDB/loader plus the special items
`parameter` and `backup`, scratch `/tmp/flash.bin`, ioctls `0x7203` TestBadBlock, `0x7204` ReadSector,
`0x7205` WriteSector, `0x721a` ReadFlashInfo, `0x7252` EndWriteSector, `0x7253` GetLockFlag, `0x7254`
GetPublicKey. The MCU path is separate: the RKA flashing engine writes through /dev/vendor_storage below the
Android partitions while install_mcu pushes dmcu.ext then dmcu.cfg then the five MCU images over /dev/mtc-car -
ioctl code `0x10000 | strlen(command)`, `updateMcuCfg` codes `0x83/0xc3/0x11d/0x20d/0x22d`, with
`IAP_A_REQ timed out %d counts` and `IAP_WRITE timed out %d counts`. The five `*.img` MCU files are firmware
pushed over IAP, not eMMC writes. UI is stock `ScreenRecoveryUI` with menu strings `Reboot system now`,
`Reboot to bootloader`, `Select file to view`, `Choose a package to install:`, `Try again`, `Factory data reset`,
`just_exit`, plus OEM prompts `Please choose system updata file device!!` and `Please choose mau updata file
device!!`, under the title `Android Recovery by HCT V10.3.1`.

**The made-ours boundary.** Inside the ramdisk (the proven splice): replaceable are `init.rc`,
`init.recovery.rk30board.rc`, `prop.default`, `ueventd.rc`, `ld.config.txt`, `cgroups.json`, our own scripts and
binaries (`/system/bin` arm64 via `linker64`, or `sbin`/`vendor/bin` 32-bit ARM via its linker),
`recovery.fstab` (23 entries), `res/images`, `res/*.sh`, the SELinux contexts (enforcement is off in recovery,
`androidboot.selinux=permissive`, but keep `/dev/vendor_storage` labelled `storage_device` in case it returns),
and `otacerts.zip` (add our cert, keep HCT's). Byte-for-byte: the kernel, `second` (rehash SHA1 entries if ever
touched), the dtbo, the header page (addresses, page size, cmdline - payload placement is an implicit
convention), and `system/bin/recovery` itself - all RKA and MTC/IAP logic exists only in that binary (424,472 B,
dynamic aarch64, 22 NEEDED libs, `librecovery_ui_ext.so` dlopen'd at runtime). Toybox 0.8.0-android ships 171
applet symlinks in `system/bin`; the 32-bit static busybox 1.11.1 (1,807,056 B) serves `res/*.sh` via
`#!/sbin/sh`. So a recovery of ours = stock binary + our ramdisk services + our cert, not a rewritten UI - and
the OEM card-install route keeps working because HCT's cert stays in the zip.

## Nov 21 (evening) - a USB-Ethernet dongle on the host port makes recovery reachable, and the recovery script gains a network phase

**The Ethernet route exists, and it needs no driver work.** The owner plugged a USB-Ethernet adapter into one of
the head unit's USB host ports at 14:50, and `eth0` appeared bound on the host controller `fe3c0000.usb`
(device path `usb1/1-1/1-1.2`), driver `ax88179_178a` - an ASIX AX88179_178A gigabit adapter (MAC
`00:0a:cd:27:a5:b2`, the ASIX OUI). `carrier=1`, `operstate=up`, `speed=1000`, `mtu=1500`. That driver is
**built into the kernel** - it is absent from `lsmod`, and the kernel blob we boot in recovery (the same #190
build) carries the strings `ax88179_178a`, `asix_`, `cdc_ether`, `cdc_ncm` and `r8152`. So recovery needs no
module, no firmware file and no supplicant for this route: the kernel probes the dongle itself, and the interface
appears without userspace help. The WiFi chip stays the fallback (RTL8188EU USB, driver `rtl8188eu`, module
`8188eu.ko` vermagic `4.19.111+ SMP preempt mod_unload modversions aarch64` matching that kernel), but WiFi needs
an association path busybox does not have: this busybox has no `wpa_supplicant`, `/system/bin/wpa_supplicant` does
not exist on the live unit, and `/vendor/bin/hw/wpa_supplicant` is a HAL binary that talks to binder - which does
not run in recovery.

**The LAN is real and fast over Ethernet.** Ping from the workstation (`192.168.1.161`) to the unit
(`192.168.1.120`) answered at 1.0-3.3 ms, gateway `192.168.1.1` answered from the unit, and the ARP table lists
both interfaces (`eth0` and `wlan0`) reaching both hosts. Reading 120 MiB through adb took 1 s (125,829,120 B in
one second, ~120 MB/s) - the gigabit path, not the WiFi chip's ~3-5 MB/s. Writing is the storage's limit, not the
link's: `adb push` of 100 MiB into `/cache` took 12 s (~8.3 MB/s), and a 200 MiB `dd` there failed with ENOSPC,
because `/cache` is 356 MiB total with 185 MiB free (`/dev/block/mmcblk2p11`). Payload staging therefore goes
straight to the partition (streamed `dd`, or busybox `wget` pulling from a workstation HTTP server), not through
`/cache`. `/proc/net/fib_trie` shows a single local address `192.168.1.120` in a `/29` node (host entries `.120`
and `.127`) alongside two `/24` routes on `wlan0` and `eth0` - the netd-assigned mask is odd, but same-subnet
traffic to the workstation works either way.

**SELinux does not stand in the way.** The kernel cmdline carries `androidboot.selinux=permissive`, `getprop
ro.boot.selinux` says `permissive` and `getenforce` says `Permissive`. The recovery ramdisk's shipped policy defines
domains `init`, `logd`, `recovery`, `shell`, `toolbox`, `ueventd`, and the names `adbd`, `adbd_exec`, `adbd_socket`,
`adb_service`, `ctl_adbd_prop`, `net_bind_service`, `ethernet_service` and `tcp_socket` are present in it; init.rc
defines `service adbd /system/bin/adbd --root_seclabel=u:r:su:s0 --device_banner=recovery` (disabled, socket
`adbd stream`) and `service recovery ... seclabel u:r:recovery:s0`. Enforcement is off, so binding a TCP socket or
writing a partition from our service is allowed regardless of what the policy says; the script records what the
environment can do instead of trusting that. Recovery's `adbd` honours `service.adb.tcp.port` and
`persist.adb.tcp.port` (both strings are in the shipped `/system/bin/adbd`), and `init.recovery.rk30board.rc`
starts `console` on userdebug - the same cmdline also carries `firmware_class.path=/vendor/etc/firmware`, which
recovery never mounts, so a kernel firmware request (cfg80211's `regulatory.db`) falls back to the built-in default
regdomain; that only matters for the WiFi fallback, not for Ethernet.

**The partition map, measured on the live unit through `/dev/block/by-name`.** `uboot`=`mmcblk2p1`,
`trust`=`mmcblk2p2`, `misc`=`mmcblk2p3`, `dtb`=`mmcblk2p4`, `dtbo`=`mmcblk2p5`, `vbmeta`=`mmcblk2p6`,
`boot`=`mmcblk2p7`, `recovery`=`mmcblk2p8`, `backup`=`mmcblk2p9`, `security`=`mmcblk2p10`, `cache`=`mmcblk2p11`,
`metadata`=`mmcblk2p12`, `frp`=`mmcblk2p13`, `super`=`mmcblk2p14`, `userdata`=`mmcblk2p15`. This corrects the
earlier assumption that `misc` is partition 9: partition 9 is the all-zero `backup`, and `misc` is partition 3.
Recovery's init starts `ueventd`, so `/dev/block/by-name/*` exists in recovery as it does in Android.

**The applets the net phase needs are already in the ramdisk.** Strings over the ramdisk's static busybox show
`ifconfig`, `route`, `telnetd`, `telnet`, `httpd`, `udhcpc`, `ping`, `brctl`, `wget`, `tftp`, `insmod`, `lsmod`,
`modprobe`, `rmmod` and `devmem`; the ramdisk's `/system/bin` (toybox 0.8.0 plus real binaries) carries `dd`, `ls`,
`cp`, `rm`, `tr`, `wc`, `nc`, `netcat`, `netstat`, `getprop`, `setprop`, `strings`, `base64`, `insmod`, `lsusb`,
`devmem`, `adbd`, `ueventd`, `sh` and `linker64`. The script resolves each tool through `tool()` (the `/system/bin`
copy when it exists, else the busybox applet), so no applet is assumed.

**What the script now does (extension of `scripts/hu_recovery_evidence.sh`, no new service, no rc change).** Three
additions, all inert unless asked for:

* **The BCB capture.** Every recovery boot copies the first 4 KiB of `misc` into `/cache/hu-evidence/misc-bcb.bin`
  (plus a printable view through `strings`, or a busybox `grep` for `boot-recovery` when `strings` is missing).
  Whether a plain `reboot` from recovery clears the boot request or parks the menu again becomes measurable by
  comparing that file across boots instead of guessing from the Nov 20 parking.
* **The network phase.** `/cache/hu-net.request` (nonce, done-marker named after the nonce, same rule as the
  restore) arms it. It waits up to 12 s for `/sys/class/net/<iface>` (`eth0` by default), sets
  `192.168.1.120/255.255.255.0` with busybox `ifconfig`, adds a default route to `192.168.1.1`, starts TCP adb
  (`setprop service.adb.tcp.port 5555` then `setprop ctl.start adbd`, reporting `init.svc.adbd` afterwards), starts
  `busybox telnetd -l /sbin/sh` (the login shell is mksh R40, root in recovery), and records the listening ports
  (`netstat -tn`) and the interface listing into `/cache/hu-evidence/`. When no interface appears it tries the WiFi
  fallback only if the ramdisk actually carries a module (`/sbin/modules/8188eu.ko` or `/lib/modules/8188eu.ko`) and
  `/cache/hu-net.conf` names an open AP - `insmod`, then `iw dev wlan0 connect <ssid>`, then the same IP and
  daemons. Without both it stops and behaves exactly as before.
* **Reboot suppression while a session is armed.** If the network came up the script does not reboot: recovery
  stays up so the workstation can drive partition writes and read the evidence, and the log says so. With no
  network armed the old reboot-out path (and its cold-cycle note) is unchanged. An install package on a card still
  exits before any of this, so the owner's OEM card route keeps the untouched recovery UI.
* **A write probe, measured not assumed.** The phase opens partition 7 for writing through `dd conv=notrunc bs=1
  count=0` - zero bytes - and logs whether that open succeeded, which answers the open question of whether a
  recovery-side shell can write partitions at all.

**Offline gates re-run after the extension.** `bash --posix -n` on the script passes; the repo gate
`scripts/smoke_recovery_evidence.sh` now covers thirteen scenarios (the nine existing ones plus Ethernet armed,
consumed net request, no-interface reboot path, and the WiFi-fallback branch) and exits 0 - 91 assertions. The
sandbox driver `a14-work/tmp/rec-smoke/run-scenarios.sh` covers A-I and reports `ALL SCENARIOS PASS`; its shims
now record `ifconfig`/`route`/`telnetd`/`insmod` into `state.net` and `setprop`/`getprop` into `state.props`
instead of executing them, so a dry-run can never touch the workstation's interfaces, routing table or module
loader. The rebuilt candidate is `a14-work/recovery-evidence/recovery-evidence.img`, 39,088,128 B, sha256
`90923603efc1cf081102653070e6c30726dece83a512534d34e62ea4bafe00ce`, injecting
`hu-evidence.sh` `5e663ff46bbe74d7db164029e81e675fdc2a551491044f47acaed34833eaebbf` over an rc whose stock prefix
is verbatim; kernel blob `a514a3ffb77e…`, second blob `fb80617e7c97…` and dtbo `28a07d4946e9…` are byte-identical
to the capture, and the builder refused no byte outside the ramdisk span.

**Still to measure on the unit, in order.** (1) Whether the dongle enumerates inside a recovery boot - the host
controller probes at boot regardless of userspace, but recovery's gadget config is on the *other* controller
(`fe800000.dwc3`), so this is expected and must still be observed. (2) Whether a plain `reboot` from recovery
boots partition 7 or parks the menu again, read from `misc-bcb.bin` before and after. (3) Whether recovery-side
partition writes succeed (the probe's answer). (4) Whether recovery's cmdline also carries
`androidboot.selinux=permissive`. None of these was written in this pass: partition 7 stays `b449aee98c01…`,
`misc` stays `909bdd979111…`, and partition 8 still holds the previously staged build until the owner enters
recovery or a new build is written under **D83**'s pairing rule.


**Nov 21 (late evening): the tool split inside recovery, the mksh dialect gate, and the net-module build.**
Step 2 (reduced scope) and Step 3 (probe + network merged) ran read-only; nothing was flashed.

* **Step 2 evidence.** `/cache/state-android.txt` (4,307 B, pulled to `a14-work/tmp/state-android.txt`) shows
  `eth0` live on the dongle: address `00:0a:cd:27:a5:b2`, driver `ax88179_178a`, `carrier=1`, `operstate=up`,
  `speed=1000`, `duplex=full`, `mtu=1500`, address `192.168.1.127/24`, and the route table carries only `eth0`.
  No `dhcp.eth0.*` properties exist, so the lease is netd-assigned rather than busybox-leased, and `net.dns1`
  is `192.168.1.1`. The regulator/clk/debugfs pass the owner cut from Step 2 was not run.
* **Step 4 dropped.** The dongle enumerates inside a recovery boot on its own: hub `1-1` (0424:2514) at 0.97 s,
  dongle `0b95:1790` at 1.36 s, `ax88179_178a … eth0: register` at 1.698 s of the 16:28 recovery console. The
  missing piece is userspace bring-up, so no USB enabler, no `usb_dongle`, no `usb_modeswitch`.
* **The tool split, measured by running the ramdisk's own busybox.** A strings pass over `sbin/busybox` was
  misleading (applet names do not each sit on their own line), so the recovery binary was pushed to the unit
  exec-only and `busybox --help` printed its applet table: BusyBox v1.11.1 carries `ifconfig route netstat
  dmesg udhcpc telnetd mount umount head tail grep stat sync kill sleep date cat ls awk sed cut tr cp rm mkdir
  touch basename dd md5sum sort wc`, and the gaps that matter to this module are sha256sum and timeout. The
  ramdisk's `/system/bin` is toybox, 196 applets, which carries `cat ls tail grep cut head sed stat cp mkdir rm
  touch basename tr umount setprop getprop dmesg dd sha256sum timeout` and does NOT carry awk. The real trap is
  the call shape: busybox is multi-call, so `$BB ifconfig eth0 up` is correct, while `$SB cat` execs the
  *directory* `/system/bin` with `cat` as an argument - toybox needs `$SB/cat`. That distinction is now a rule
  in `scripts/hu_h_common.sh` (its ramdisk name is `/sbin/hu-h-common.sh`), and the offline gate audits both
  the gaps and the call shape.
* **The dialect gate ran the recovery shell, not Android's.** `/sbin/sh` in the recovery ramdisk is
  `@(#)MIRBSD KSH R40 2011/10/07`; Android's `/system/bin/sh` is `@(#)MIRBSD KSH R57 2019-03-01 Android`, so
  parsing under Android's shell proves nothing. The recovery binary was pushed to `/data/local/tmp/hu-dialect/`
  (exec-only, no partition touched) and `rec-sh -n` returned rc 0 on all seven module files, and a construct
  probe under R40 confirmed `${f##*/}` basename stripping, `$((i + 1))`, a dotted-quad `case` glob, nested
  command substitution inside double quotes, `. file` sourcing, a function that echoes a timestamped line, and
  `set --`/`shift`.
* **Offline gate.** `scripts/smoke_recovery_netmodule.sh` runs the six module scripts against a fake `/sys`,
  `/proc`, `/cache` and `/dev` plus a busybox shim faithful to the applet table above - the two applets this
  busybox does not have (sha256sum and timeout) are REFUSED, so a script reaching for them fails loudly, and
  toybox calls written as `$SB <applet>` are caught by the source audit. Net applets are recorded, never
  executed. 14 scenarios pass, rc 0:
  (no reboot, no marker), consumed nonce, inert without a request, nonce refresh extending the window, the
  card channel both ways, and the source audit (no digest, no `dd`, no reboot, no reference to the retired
  `hu_evidence` service).
* **The build, not yet written.** `scripts/patch_recovery_netmodule.sh` spliced
  `a14-work/hu-stock-backup-refresh/recovery.bin` (`1fdf5ea77fc6…`) into
  `a14-work/recovery-netmodule/recovery-netmodule.img`: 39,090,176 B, sha256
  `0ab64a039cdd8ea8f99f45a2c530076c6b8d4d99856448565fbe39e3c5b0adac`. Ramdisk-only: the ramdisk went
  12,519,199 B -> 12,484,781 B, and the kernel blob (`a514a3ffb77e…`), the RSCE second
  (`fb80617e7c97…`) and the recovery dtbo (`28a07d4946e9…`) are byte-identical; the builder refused no byte
  outside the ramdisk span (header changes limited to `ramdisk_size` and the dtbo offset). Inside the ramdisk:
  seven module files, `prop.default` changed on exactly three lines (`ro.system.build.fingerprint` and
  `ro.build.display.id` gain `-HUPATCH`, and `ro.adb.secure=0` is added because the recovery ramdisk ships no
  adb keys), and `init.recovery.rk30board.rc` keeps its stock 663 B verbatim with 1,224 B appended defining
  seven oneshot services, each started exactly once, with the retired `hu_evidence` absent. The write span for a
  future flash is `0..39,090,176` of partition 8's 100,663,296 B; everything past it is left untouched.
* **Nothing was written in this pass.** Partition 7 stays `b449aee98c01…`, `misc` stays byte-identical to the
  Nov 21 readback (md5 unchanged, no `boot-recovery`), and partition 8 is still the stock
  `1fdf5ea77fc6…` - the only staged artefact is the new image on the workstation. The net module exists as a
  build plus offline and dialect gates; its recovery-boot behaviour is unmeasured until the owner approves the
  p8 write.

* **The p8 write, on the owner's GO (Nov 21, 20:11 CET).** PRE-FLASH checks first: the image contains **0
  occurrences** of `hu-restore`, `hu-rollback` or `rollback-boot` (byte scan of the whole image plus the spliced
  ramdisk), and no `hu-evidence.sh` is in the ramdisk - the module reads only `hu-net.request`, `hu-net.stop`,
  `hu-mark.log`, `misc-head.bin`, `pstore-*` and `state-recovery-*`. `hu-restore.request` and the stale
  `hu-net.request` were moved to `/cache/old-requests/`. The stock rollback image `1fdf5ea77fc6…` was staged at
  `/cache/hu-stock-recovery.bin` (100,663,296 B) and verified by host-side readback, byte-identical to the
  workstation capture. `/sbin/hu-udhcpc.script` (1,062 B, `316c4e48767c…`) is in the ramdisk and `hu-net.sh`
  passes it with `-s`; neither the script nor the module references `/system/etc`, and neither the stock nor the
  patched ramdisk has a `usr/share/udhcpc` directory, so `-s` is mandatory. The write was
  `dd if=/cache/hu-patched-recovery.bin of=/dev/block/by-name/recovery bs=512 count=76348 conv=notrunc` - rc 0,
  76,348 records, 39,090,176 B at 10 MB/s. Host-side readback of exactly that span hashes to
  `0ab64a039cdd8ea8…` and `cmp` is byte-identical to the build; the 61,573,120 B beyond the write span are
  byte-identical to stock. Partition 7 still hashes `b449aee98c01a7da…` and `misc` still hashes
  `909bdd979111bcd5…` with no `boot-recovery`, both read back from the workstation after the write; `super`
  (3,263,168,512 B) was not touched. The rollback is one line:
  `dd if=/cache/hu-stock-recovery.bin of=/dev/block/by-name/recovery bs=512 count=196608 conv=notrunc`.
  The fresh nonce `nov21-netmod-1795288264-71` was staged after the flash, and no `hu-net.stop` or `net-done-*`
  marker exists yet. Recovery must be entered from **eMMC** (`storagemedia=emmc`), not from an SD-boot card,
  because an SD-boot card runs the card's own partitions and would not boot the patched partition 8.

* **The marker property the UI actually prints, and the second build (Nov 21 evening).** The card's own
  recovery proved the header comes from the boot image: its ramdisk `prop.default` carries
  `ro.bootimage.build.fingerprint=…/hct210121336:userdebug/test-keys` and display id
  `eng.hct2.20201012.134120 test-keys`, which is exactly the yellow header the owner read - and `prop.default`
  has no `ro.build.fingerprint` line at all. So the marker must sit on `ro.bootimage.build.fingerprint`; the
  first build only marked `ro.system.build.fingerprint` and `ro.build.display.id`. The builder now appends
  `-HUPATCH` to all three and still adds `ro.adb.secure=0` (4 changed lines, gated). Rebuilt image
  `a14-work/recovery-netmodule/recovery-netmodule.img`, 39,090,176 B, sha256
  `412cd032bed3353adff064890bc585f43f5407096e2ceea59f2eb13244200990`; kernel blob `a514a3ffb77e…`, second
  `fb80617e7c97…` and dtbo `28a07d4946e9…` byte-identical, stock rc verbatim with seven services. Note on
  determinism: the splice is byte-stable in CONTENT, but `cp` gives the injected files fresh mtimes, so the
  cpio (and thus the image sha256) depends on the build moment - verify by `cmp` against the file actually
  staged, and by the blob digests, not by re-running the builder.

* **The recovery boot of Nov 21 evening, read back through pstore (read-only).** `/cache` only kept the
  lines written before ~1.7 s, but `/dev/kmsg` did not: the current `console-ramoops-0` (57,183 B, sha256
  `2a59ffff9ff71e2c…`) contains the whole recovery boot, region `a14-work`-side extract
  `/tmp/opencode/rec-boot-kmsg.txt` sha256 `2894687a4c4b62f2…`. Timeline from it: `init: First stage mount
  skipped (recovery mode)` 1.037; `EXT4-fs (mmcblk2p11)` mounted 1.639; module services begin 1.68-1.73;
  `IPv6: ADDRCONF(NETDEV_UP): eth0: link is not ready` 2.081; `ax88179_178a 1-1.2:1.0 eth0: ax88179 - Link
  status is: 1` 5.128 (the dongle's carrier, not 1.70 s); `hu: net: ifconfig eth0 up issued` 11.79;
  `hu: net: udhcpc finished` 41.83 with no lease, so the static fallback `192.168.77.2` was used
  (`hu: net: address=192.168.77.2` 59.99); `init: Received control message 'start' for 'adbd' from pid: 480
  (/system/bin/setprop ctl.start adbd)` 76.06 followed by `hu: net: adbd svc=running tcpport=5555 secure=0`
  and `hu: net: adbd listen line=none` - setting `service.adb.tcp.port` on an already-running adbd binds
  nothing, exactly as the stock `init.rc` shape predicts (no trigger on that property); `hu: net: telnetd on
  2323 (login /sbin/sh)` 78.18 proves busybox 1.11.1 `telnetd -l /sbin/sh -p 2323` works; heartbeat ticks
  continued to 558 s; `hu: state end` at 54.88 (up=6.72), 79.85 (31.71) and 169.86 (121.71);
  `init: Received sys.powerctl='reboot,' from pid: 134 (/system/bin/recovery)` 560.42 after the owner chose
  "Reboot system now", preceded by a second `EXT4-fs (mmcblk2p11)` mount at 560.397; the boot ends with
  `reboot: Restarting system with command ''`. The previous Android boot's buffer ends with
  `reboot: Restarting system with command 'recovery'` - the entry that `adb reboot recovery` produced.
  Durability finding: files written to `/cache` during recovery did not survive the reboot
  (`state-recovery-{5,30,120}.txt`, `misc-head.bin`, `net-done-<nonce>.txt` are absent afterwards;
  `hu-mark.log` came back with only its pre-1.7 s content) while the pstore copy `pstore-1.69/console-ramoops-0`
  survived. The card copy taken at up=47 s is `/mnt/media_rw/363A-7751/hu-mark.log` 807 B, sha256
  `a5a93789454777fefcfd04f2e0f9b7f7cb2734c830960a457557e47e501b325e`, and its sibling
  `state-recovery-5.txt` 2,252 B, sha256 `89e01edf37b9cc6962466474aa18fd79ab2b8aa3b3a10d6e3032ac33578ffb00` -
  both prove the snapshot existed inside recovery even though `/cache` lost it afterwards. The recovery UI's own strings carry `/cache/`, `unlink`, `format_volume` and
  `EnsurePathUnmounted`, and the card mount logged `FAT-fs (mmcblk0p1): Volume was not properly unmounted`,
  so unmounts at reboot are lazy: treat `/cache` writes made inside recovery as unreliable and read evidence
  from kmsg-after-reboot and from the FAT card copies instead.
* **What the BCB actually held (step 5).** `hu-early.sh` read the misc head read-only at up=36.84 s and
  copied it to the card: `/mnt/media_rw/363A-7751/misc-head.bin` 2,048 B, sha256
  `e5a00aa9991ac8a5ee3109844d84a55583bd20572ad3ffcd42792f3c36b183ad`, all
  zeros - recovery had already cleared the BCB by then. After the reboot the whole 4 MiB misc partition
  hashes `909bdd979111bcd531d6f410…`, byte-identical to the pre-write baseline. So `adb reboot recovery`
  does write a BCB (the bootloader honoured it and entered recovery, and the kernel logged
  `Restarting system with command 'recovery'`), and recovery zeroes it early - a misc read taken from
  inside recovery can never show it. Also measured: the `stat` call in `hu-state.sh` printed an empty size
  because `\"$out\"` inside a double-quoted string passes the quote characters to toybox `stat` as part of
  the argument; the unquoted call in `hu-early.sh` printed 2048 correctly.

* **Build v3 of the net module (Nov 21 night, built - not written).** The owner's revised order is
  implemented in `scripts/hu_net.sh`: poll `carrier` (the driver only reports it after
  `ax88179 - Link status is: 1`), then address the interface immediately - static `192.168.1.250/24`
  with gateway `192.168.1.1` plus an `eth0:1` alias on `192.168.77.2` - then restart adbd in the
  measured order (`ctl.stop adbd`, sleep 2, `service.adb.tcp.port=5555`, `ctl.start adbd`) and read
  `/proc/net/tcp` for `15B3` state `0A` before logging success, with `telnetd -l /sbin/sh -p 2323` in
  the same block; everything runs within ~15 s of carrier. DHCP became diagnostic only:
  `hu-udhcpc.script` records the offer (`ip`, `mask`, `gw`, `dns`) and never calls `ifconfig`/`route`,
  and `hu-net.sh` runs it in a background subshell for ~60 s with stderr into the log, sampling
  `/sys/class/net/eth0/statistics/{rx_packets,tx_packets,rx_errors,tx_errors,rx_dropped}` before and
  after, plus `ifconfig eth0` and `/proc/net/arp`. Durability: `say()` and `guarded()` now `sync` after
  every write, `hu-state.sh` copies its snapshot to whichever card mount is live, and `hu-card.sh`
  keeps its own mount alive until the 120 s snapshot has landed. The `stat` argument quoting bug is
  fixed (unquoted argument). Built image `a14-work/recovery-netmodule/recovery-netmodule.img`,
  39,090,176 B, sha256 `b96fe5f262bb29e6786aaaf03459635a18a7ca9c37853cd6fe1b7291ed999a5f`; kernel blob
  `a514a3ffb77e…`, second `fb80617e7c97…`, dtbo `28a07d4946e9…` byte-identical; stock rc 663 B verbatim
  + 1224 B; the injected-file digest list for that build was taken through a `hu-*.sh` glob, so the
  names in that list were not aligned with the values - the explicit, name-checked list for build v4
  below is authoritative, and every built copy is `cmp`-checked against its repo source. Offline gate
  passes 15 scenarios including the new adbd-order
  assertion and a scenario that emulates the Nov 21 failure (`no-listener` -> the module says
  `NO TCP LISTENER` and does not claim success); dialect gate `mksh-R40 -n` rc 0 on all seven scripts.
* **Build v4 - the static address is the router's MAC-bound lease (Nov 21 night, built - not written).**
  Asked to confirm that `192.168.1.250` was excluded from the router's DHCP pool, the owner answered that
  the DHCP server now MAC-binds this dongle (`00:0a:cd:27:a5:b2`) to `192.168.1.127` and chose that
  address instead, so the recovery address equals the Android address and is always the same
  (`docs/decisions.md` D88). Only `STATICIP` in `hu-h-common.sh` and the comments changed;
  `hu-early.sh`, `hu-hb.sh`, `hu-state.sh`, `hu-card.sh` and `hu-udhcpc.script` are byte-unchanged from
  build v3. Built image `a14-work/recovery-netmodule/recovery-netmodule.img`, 39,092,224 B, sha256
  `d5ac116dda3315c2c377b2f8233242945aa5a6686557a4a19820996365779a8f`; kernel (25,671,688 B), second
  (924,672 B) and dtbo (803 B) blobs again `cmp`-identical to the capture. Name-explicit digests:
  `hu-h-common.sh 86df3639ce95def4`, `hu-early.sh 9812ad519f080e06`, `hu-hb.sh e47639d0a974b858`,
  `hu-state.sh d61685b771f25082`, `hu-net.sh 8e7d90da9a0ab672`, `hu-card.sh 9e2292857a059e24`,
  `hu-udhcpc.script b877ed13e30e0c6a`, `init.recovery.rk30board.rc b57d152d9634efd1`,
  `prop.default 92dbf6d62fb0b5b5`. Offline gate 15 scenarios rc 0 (expectations re-pointed at
  `192.168.1.127`), dialect gate `mksh-R40 -n` rc 0 on all seven scripts.

* **Build v4's recovery boot (Nov 21 night, 22:45, read-only through pstore and the card).** The patched
  partition 8 ran (`-HUPATCH` visible in the OEM header per the owner), the dongle enumerated, and the
  module ran to completion, but carrier never came. Exact lines from this boot's `console-ramoops-0`
  (57,014 B, sha256 `63b3c3ed912b7f8dab1c600c146ad03d904d4306f46cd3d5f5d23230735e6f50`): `[    0.975554] --mtc ann 1-1 0424` (hub);
  `[    1.262027] usb 1-1.2: new high-speed USB device number 3 using ehci-platform`;
  `[    1.359610] --mtc ann 1-1.2 0b95` and `[    1.359638] usb 1-1.2: New USB device found,
  idVendor=0b95, idProduct=1790 … Product: AX88179`;
  `[    1.699389] ax88179_178a 1-1.2:1.0 eth0: register 'ax88179_178a' at usb-fe3c0000.usb-1.2,
  ASIX AX88179 USB 3.0 Gigabit Ethernet, 00:0a:cd:27:a5:b2`. `ax88179 - Link status is: 1` appears
  **zero** times in this boot and there is no `ADDRCONF` line for `eth0` at all. The module's own lines:
  `hu: net: waiting for carrier on eth0 (t=0s) carrier=none` … `(t=55s) carrier=none`, then
  `hu: net: no carrier on eth0 after 60 s - stopping, no reboot` at 110.728 s and
  `init: Service 'hu_net' (pid 144) exited with status 0`. No static/alias/route line, no
  `ctl.stop`/`ctl.start`, no listener line, no telnetd, no DHCP attempt - the critical path never ran, by
  design. The snapshot proves the link was idle: `=== l2 counters (rx_packets=0 tx_packets=0 rx_errors=0
  tx_errors=0 rx_dropped=0 )` and busybox `ifconfig` shows `BROADCAST MULTICAST` without `RUNNING`,
  `carrier:0`.
* **Why carrier never arrived: an ordering deadlock introduced by build v4, proven by comparing boots.**
  Build v4 polls `carrier` *before* touching the interface. In the 20:57 boot (build v2) the kernel
  logged `IPv6: ADDRCONF(NETDEV_UP): eth0: link is not ready` at 2.081 s and
  `ax88179_178a 1-1.2:1.0 eth0: ax88179 - Link status is: 1` at 5.128 s - the interface had already been
  brought UP, which is what makes this driver negotiate the PHY. Build v2 logged
  `hu: net: ifconfig eth0 up issued` only at 11.789 s because `guarded 10` delays the *log*, not the
  command: the `ifconfig eth0 up` itself executed at ~1.71 s. Build v4 never brought `eth0` UP, so there
  is no `ADDRCONF(NETDEV_UP)`, no negotiation, counters stay 0/0 and `carrier` stays empty. So class
  **(B)** - enumerated but no carrier - is caused by the module's own order, not by USB power/timing and
  not by the cable: the fix is to bring the interface UP first, then wait for carrier.
* **Durability fixes worked as designed (D86).** The card copy is now complete and self-consistent:
  `/mnt/media_rw/363A-7751/hu-mark.log` 8,614 B sha256
  `d9970d17d8d30284f8364d1f25c269e308544891bff5575b51f48b2afb4c87a8` (full timeline, not just the
  first 1.7 s), `state-recovery-5.txt` 4,536 B sha256 `8869de48a861f016…`,
  `state-recovery-30.txt` 4,611 B sha256
  `765c53667e7bd9c6ea948361fb8071912d096188536f383775a333d48d9276b1`,
  `state-recovery-120.txt` 4,643 B sha256 `a86f4d6fc26fbe00…`, `misc-head.bin` 2,048 B sha256
  `e5a00aa9991ac8a5…` (all zeros, recovery clears the BCB early). `state end out=… size=4536` shows the
  `stat` quoting fix working, and `state copied to card rc=0` shows the per-snapshot card copy working.
  Partition state after this boot: p7 `b449aee98c01a7da…`, p8 auto-reverted to stock
  `1fdf5ea77fc66f48…`, `misc` `909bdd979111bcd5…` equal to the recorded baseline, nonce
  `nov21-netmod4-1795297537-64` unconsumed (no `net-done-*` marker, because the marker is written only
  after the listener check).

* **Build v5 - the bring-up order is node -> OPEN -> address -> adbd, carrier only afterwards
  (Nov 22, built - not written).** Build v4's boot proved class **(B)**: the dongle enumerated at
  1.262 s and `ax88179_178a` registered `eth0` at 1.699 s, but `ax88179 - Link status is: 1` never
  appeared and there was no `ADDRCONF` line at all, because v4 polled `carrier` before touching the
  interface - this driver negotiates the PHY only once the interface is opened (build v2's boot:
  UP at ~1.71 s -> `ADDRCONF(NETDEV_UP)` at 2.081 s -> `Link status is: 1` at 5.128 s). v4 also
  showed `hu: net begin` at 1.661 s, *before* the node existed, so an `ifconfig` issued at that
  moment cannot work. `hu-net.sh` now waits for `/sys/class/net/eth0` (poll interval chosen at
  runtime: 0.5 s if the ramdisk's toybox accepts a fractional sleep, else busybox's integer 1 s -
  busybox 1.11.1 rejects fractions, and the choice is logged once as `nap:`), brings the interface UP
  with `guarded 2` retried every 2 s and logs the real exit status, verifies the open from
  `/sys/class/net/eth0/flags` (IFF_UP in bit 0; the sysfs value is hex and goes straight into the
  arithmetic), then sets the static address/alias/gateway and restarts adbd and telnetd - none of
  that waits for carrier, since a TCP listener binds without a link - and only then watches carrier
  for ~120 s logging carrier together with the five L2 counters every 5 s. Nothing stops early
  because carrier is missing; the window closes only at its end. DHCP stays diagnostic only.
  `hu-h-common.sh` gained `nap_probe`/`nap` and `iface_up_state`; the other five scripts are
  byte-unchanged. Built image `a14-work/recovery-netmodule/recovery-netmodule.img`, 39,094,272 B,
  sha256 `ab9af9798a987084060c8afef60b96f282bb6fd45ae7786d841c362194e6983a`; kernel (25,671,688 B),
  second (924,672 B) and dtbo (803 B, sha256 `28a07d4946e9f278…`) blobs `cmp`-identical to the
  capture. The ramdisk grew (lz4 12,519,199 -> 12,489,526 B is the second blob's compressed size
  shrinking as the archive changes), so exactly four header bytes differ from the capture: the
  ramdisk-size field at 16..18 and the low byte of the dtbo offset at 1637 (39,120,896 ->
  39,092,224) - the builder refuses any other header byte change, and cmdline/boardname/kernel size
  are verbatim. The dtbo blob is byte-identical and now lives inside the written span; the partition
  region beyond the span is zeros up to the untouched stock dtbo blob at 39,120,896. Name-explicit
  digests: `hu-h-common.sh 18f941443d02cac9`, `hu-early.sh 9812ad519f080e06`, `hu-hb.sh
  e47639d0a974b858`, `hu-state.sh d61685b771f25082`, `hu-net.sh 526089b31cb8df19`, `hu-card.sh
  9e2292857a059e24`, `hu-udhcpc.script b877ed13e30e0c6a`, `init.recovery.rk30board.rc
  b57d152d9634efd1` (unchanged), `prop.default 92dbf6d62fb0b5b5` (unchanged). Each built copy was
  `cmp`-checked against its repo source. Offline gate now 19 scenarios rc 0 (the fake `/sys` only
  reports carrier 1 after a successful `ifconfig eth0 up`, and scenarios cover a late node, an
  `up` that fails twice then succeeds, a dark link that still runs the critical path, and a node
  that never appears); dialect gate `mksh-R40 -n` rc 0 on all seven scripts. The hex arithmetic in
  `iface_up_state` was checked against the unit's mksh: `0x113` -> 275 with bit0=1, `0x102` -> 258
  with bit0=0, and the ramdisk ships `/system/bin/sleep -> toybox`, so the fractional probe execs.

* **Build v5's recovery boot (Nov 22, 00:14 - adb-in-recovery PROVEN).** The patched partition 8 ran
  and the workstation reached it inside recovery: first probe at epoch 1795302894 (~45 s after the
  reboot command) showed `arp 192.168.1.127 dev enp4s0 lladdr 00:0a:cd:27:a5:b2 REACHABLE`, port 5555
  **open**, port 2323 open, and `adb connect 192.168.1.127:5555` attaching a transport reported as
  `recovery`. Read-only, nothing written: `adb exec-out dd if=/dev/block/by-name/boot bs=1M count=32`
  pulled 33,554,432 B and hashed on the workstation to
  `b449aee98c01a7da797be1c2aa8238ce4bef3e5ee3ae731afdcf3c53218c4384` (`b449aee98c01…`), equal to the
  recorded p7 value. `adb root` then read `/proc/net/tcp6`: `0: …:15B3 … 0A` (LISTEN) plus an
  ESTABLISHED socket from the workstation (192.168.1.161) to 192.168.1.127, and `0913` (2323) LISTEN
  for telnetd; `/proc/net/tcp` holds no `15B3` entry, which is why the module's own verification
  printed `net: adbd listen line=none` and `NO TCP LISTENER` - **adbd binds the TCP port on IPv6, so
  a tcp-only listener check cannot see it**; the link itself was up long before that line
  (`addr=192.168.1.127 carrier=1 flags=1`), so that verdict is a false negative of the check, not a
  failure of the module. Ordering proof from this boot's console (pulled live with `toybox dmesg`,
  74,365 B, sha256 `5098560499c00c70e14f5cb08dd2f213c4fb192cdb3edb9fe2f97f63c51b7462`; pstore still
  held the previous Android boot while recovery ran - its own copy is 70,521 B, sha256
  `d28157abd1c677ccd0b46ad78dfcfaadca406e192283be58778727f04bd32bae`, ending
  `reboot: Restarting system with command 'recovery'`): `[    0.980798] --mtc ann 1-1 0424`,
  `[    1.374710] --mtc ann 1-1.2 0b95`, `[    1.668081] hu: net begin nonce=nov22-netmod5-…`,
  `[    1.711054] ax88179_178a 1-1.2:1.0 eth0: register … 00:0a:cd:27:a5:b2`,
  `[    2.215148] hu: nap: poll interval 0.5s via toybox fractional=1`,
  `[    2.296757] hu: net: iface eth0 node present at up=2.27 (t=0s)` (begin ran at 1.668 s, before
  the node at 1.711 s - the node wait caught it), `[    2.664172] IPv6: ADDRCONF(NETDEV_UP): eth0:
  link is not ready` (build v4 had no ADDRCONF at all), `[    4.397558] hu: net: ifconfig eth0 up
  issued, flags=1 (UP) at up=4.37`, `[    5.644167] ax88179 - Link status is: 1`,
  `[    5.653859] IPv6: ADDRCONF(NETDEV_CHANGE): eth0: link becomes ready`,
  `[   10.660828] hu: net: address=192.168.1.127 alias_addr=192.168.77.2 carrier=1 flags=1`,
  `[   10.929907] ctl.stop`, `[   13.091216] ctl.start`, `[   19.417127] svc=running tcpport=5555
  secure=0`. Link negotiated at 1000 Mbps full duplex (`/sys/class/net/eth0/speed=1000`,
  `duplex=full`), counters climbed with zero errors (t=90 s snapshot: rx_packets=403 tx_packets=184
  rx_errors=0 tx_errors=0 rx_dropped=0). DHCP stayed diagnostic: `dhcp offer observed … ip=none …
  (eth0 untouched)` and the address after it stayed 192.168.1.127. Timing from the marker log: node
  2.27 s, open confirmed 4.37 s, carrier 5.64 s (kernel) / first carrier-watch tick 26.77 s uptime,
  address 10.66 s, adbd restarted 13.09 s, listener verdict 19.44 s, workstation connected ~45 s after
  the reboot command.
* **Evidence channels this boot (all read-only).** `/tmp/recovery.log` does not exist in this
  recovery ramdisk (`/tmp` is empty and there is no `/cache/recovery`), so the module log plus the
  live console are the record. `/cache/hu-mark.log` 4,750 B sha256
  `6381600d5051c7441c4d11ec15e0aaab8c49be3551eaa67654813530c2555a31` (mid-boot copy); the FAT32 card
  was mounted by `hu-card` at `/mnt/hucard` and re-copied every tick, then that mount went away while
  the boot continued, so the copies were re-read through a fresh **read-only** vfat mount:
  `hu-mark.log` 6,551 B sha256 `4775b711d6374324e420c21832d68894d97e331bb0ed75d3af2362612050837b`
  (full timeline), `state-recovery-5.txt` 6,470 B sha256
  `05ec5e24c548ef01ce3f2241120911fabe3b809f4d8f1dc74c3fb19414b190ba`, `state-recovery-30.txt` 6,588 B
  sha256 `ee8f1663a4c6b03917ab96c82becc7298e5c0f4364fec9ca28f55ea948ef6a86`, `state-recovery-120.txt`
  6,210 B sha256 `9ea881fa4c8fce97cb505d45f4727f6c1364a27d2c9850e8087b88e94a9fe699`, `misc-head.bin`
  2,048 B sha256 `e5a00aa9991ac8a5ee3109844d84a55583bd20572ad3ffcd42792f3c36b183ad` (all zeros). The
  `/cache` copies of the state files hash identically to the card copies. Nonce
  `nov22-netmod5-1795302845-40` consumed once (`/cache/net-done-nov22-netmod5-…txt`, 0 B). p7
  unchanged, `misc` head all zeros (recovery clears the BCB), p8 still patched until Android's
  `install-recovery.sh` reverts it.

* **Remote exit from recovery works (Nov 22, 00:33).** After the read-only evidence above was saved,
  `adb shell setprop sys.powerctl reboot` left recovery with **no menu interaction**: 47 s later
  `arp 192.168.1.127 … REACHABLE`, port 5555 open and `adb devices` reported `device` (Android), not
  `recovery`. Partition state after that boot: p7 still
  `b449aee98c01a7da797be1c2aa8238ce4bef3e5ee3ae731afdcf3c53218c4384`, partition 8 auto-reverted to
  stock `1fdf5ea77fc66f48…` by `init.rc`'s `flash_recovery`/`install-recovery.sh` (expected - patched
  recovery only survives until the next Android boot), `misc` byte-identical to the recorded baseline,
  nonce `nov22-netmod5-1795302845-40` back in `/cache/hu-net.request` with no `net-done-*` marker
  (the marker written inside recovery does not survive the reboot - D86 - which is why the card copy
  and the pulled copies, not `/cache`, are the evidence of record).

* **Build v6 - the listener check reads both TCP tables (Nov 22, built - not written).** One change,
  per the owner's direction: `hu-net.sh` now greps `/proc/net/tcp /proc/net/tcp6` for `15B3` state
  `0A` and keeps the filename in the recorded line, because build v5's boot printed
  `NO TCP LISTENER` while the workstation was already connected - adbd binds 5555 on IPv6
  (`/proc/net/tcp6: 0: …:15B3 … 0A` plus an ESTABLISHED entry from the workstation).
  `hu-h-common.sh` is byte-unchanged from v5 (`18f941443d02cac9`); `hu-net.sh` is
  `fc9c169cae16bad6`; the other five scripts, the appended rc (`b57d152d9634efd1`) and `prop.default`
  (`92dbf6d62fb0b5b5`) are unchanged. Built image 39,092,224 B, sha256
  `b2821cce34ae352a370cc5ccd0eba2a4698ae9de4da5a350b397c8f06195bb39`, write span
  `bs=512 count=76352` = `bs=2048 count=19088`; kernel/second/dtbo blobs again `cmp`-identical to the
  capture. Offline gate 19 scenarios rc 0 (152 assertions): the fake `ctl.start adbd` now puts the
  listener in the tcp6 table only, matching the unit, and the source-side assertion
  `the listener check reads ipv4 AND ipv6 tables` guards the regression. Dialect gate `mksh R40 -n`
  rc 0 on all seven scripts.
* **The A14 payload cannot rewrite partition 8 on an Android boot (Nov 22, read-only debugfs).** The
  staged vendor (`a14-work/tmp/v_vendor.img`, the vendor extent of `raw-super.img` `d81f913a…`) ships
  `/etc/init/vendor_flash_recovery.rc` (Inode 605, 226 B):
  `service vendor_flash_recovery /vendor/bin/install-recovery.sh` / `class main` / `oneshot` /
  `user root` / `disabled`, started only `on property:persist.vendor.recovery_update=true`. Its
  executable is NOT staged - `/bin` contains `applypatch` but no `install-recovery.sh`, and there is
  no `/recovery-from-boot.p` in the root - and the property is not set, so the service cannot run and
  cannot touch `EMMC:/dev/block/by-name/recovery`. The payload's `/etc/init/hw/init.rc` has no
  `flash_recovery`/`install-recovery` stanza and `/system/bin` has no `install-recovery.sh`
  (`a14-work/a14chk/system-slice.img`, read-only). `boot-a10k-a14rd.img` contains zero hits for
  those names. The partition-8 rewriter we keep seeing is therefore the STOCK Android 10 firmware's
  `/init.rc:854 service flash_recovery /system/bin/install-recovery.sh` - which disappears from the
  boot chain the moment partition 7 holds the A14 boot image. Live `misc` head read in Android today:
  the first 2048 B are all `\0` (the factory `boot-recovery/recovery/--wipe_all` text recorded Nov 4
  is no longer in the head region).
* **Gate inventory for the loop (Nov 22, from the repo, no new tooling).** Offline gates that exist:
  `scripts/verify_artifacts.sh <lineage-tree>` (vendor staging, vendor diff, `scripts/check_super.py`,
  recovery installability, VINTF via the dist `check_vintf` logs, boot header, and the D47 coupling
  gate `tools/payload_coupling_check.py`); `tools/vendor_link_closure.py` (link-closure);
  `tools/identity_gate.py` (byte-identical repack + payload fidelity + lpdump super diff, standalone);
  the recovery-module logic gates `scripts/smoke_recovery_installer.sh`,
  `scripts/smoke_recovery_evidence.sh`, `scripts/smoke_recovery_netmodule.sh`. Gaps stated honestly:
  there is **no standalone fstab gate** (the first-stage fstab is a sub-check inside the coupling
  gate, D34) and **no dedicated offline vintf/fragment-closure tool** (it is indirect: dist logs +
  coupling's target-level check, skipped when `SKIP_DIST=1`). The dialect gate is UNIT-side, not
  offline (`mksh -n` with the ramdisk's own `/sbin/sh`, D82) - and it can now run **inside recovery**
  over adb, because recovery ships that shell, so a failed boot does not need Android to syntax-check
  a candidate script.

## Phase A arming tests (Nov 22, afternoon - the BCB is honoured, a panic alone is not)

* **Build v6 ran in recovery and its own success verdict became truthful (epoch 1795343451).**
  Partition 8 was written with `bs=512 count=76352 conv=notrunc` from Android at epoch 1795342854
  (39,092,224 B @ 8.7 MB/s, rc 0); the host readback of the span (`bs=2048 count=19088`) hashed
  `b2821cce34ae352a370cc5ccd0eba2a4698ae9de4da5a350b397c8f06195bb39` (`b2821cce34ae352a…`) and `cmp`
  matched the build; the 28,672 B beyond the span stayed stock bytes. Partition 7 stayed
  `b449aee98c01a7da797be1c2aa8238ce4bef3e5ee3ae731afdcf3c53218c4384` and `misc` stayed at the recorded
  baseline `909bdd979111…` (prefix only, as registered) before the reboot into recovery.
  Recovery answered at epoch 1795343499 (~48 s later) with transport `recovery`. This boot's live
  console (`toybox dmesg`, 66,607 B, sha256 `fe075f5363984fcab8ec536305f7419e37b64f60ca312a9e4c2cab482a6fad1b`)
  shows the listener verdict now names the table it found:
  `[   13.217749] hu: net: adbd listen line=/proc/net/tcp6:   0: …:15B3 … 0A … (elapsed from carrier: 11 s)`
  - no `NO TCP LISTENER` line, which is the point of build v6 (D89b). The unit's recovery header
  carried `-HUPATCH` (`ro.bootimage.build.fingerprint` read over adb:
  `rockchip/rk3399/rk3399:10/QQ2A.200305.004.A1/hct204011522:userdebug/release-keys-HUPATCH`),
  confirming the patched prop line reaches the UI.

* **The BCB write recipe, verified byte-for-byte.** The blob is the AOSP `bootloader_message` head:
  `boot-recovery\0` at offset 0 (`command[32]`), all-zero `status[32]` at 32, `recovery\n` at offset 64
  (`recovery[768]`), zero-padded to 2048 B - sha256 `ceaae1a6314a19927ab431d55b46d08a6aaf73e9bcceb578244783c06bffd00e`
  (`ceaae1a6314a1992…`), no arguments. Written with `dd bs=2048 count=1 conv=notrunc` onto `misc`: the
  full 4 MiB then hashed `a7c5eaf9cd0b62938af6d2cc427602cbbc4e43ca8fa68d2dbe5030c8564562ea` and exactly
  22 bytes changed (offsets 0-12 and 64-72); bytes 2048..4 MiB stayed byte-identical to the recorded
  baseline. The staged copy in `/cache` did not survive the next recovery boot, so the blob was written
  later from `/data/local/tmp/hu-bcb.bin` (same digest), which is the durable staging place for Android-side writes.

* **Warm reboot with the BCB armed lands in recovery (epoch 1795343730).** From patched recovery, with
  `misc` armed, `setprop sys.powerctl reboot` produced another recovery boot - transport `recovery`,
  sdk 29, header still `-HUPATCH`. Its console (70,314 B, sha256
  `3f460518bc4ff26de1d7e050fa07fdd1862253f9090e6698f20a896615bd8d8d`) begins with
  `Kernel command line: … androidboot.mode=normal … b.mode=recovery …` and the console of the boot that
  preceded it (61,019 B, sha256 `78b6afcdb6d5a0004b7c3abae062ac4ed18b12c67216413c5dfc3e553254b73f`)
  carries the two markers `hu: bcb write begin blob=ceaae1a6314a1992 command=boot-recovery recovery=recoveryNL offset=64 span=2048`
  and `hu: bcb armed; warm reboot test; …` and ends `reboot: Restarting system with command ''`.
  So the reboot-mode path was **normal** (`androidboot.mode=normal`) and u-boot still chose recovery
  (`b.mode=recovery`) - the eMMC `misc` BCB is honoured on a warm reboot, independently of the register.
  Inside that recovery boot the armed head read back as all zeros
  (`e5a00aa9991ac8a5ee3109844d84a55583bd20572ad3ffcd42792f3c36b183ad`): recovery clears the BCB early,
  exactly as the owner warned.

* **Panic with the BCB NOT armed lands in Android.** From patched recovery, `misc` head all zeros,
  `echo c > /proc/sysrq-trigger` rebooted the unit and it came back as Android (transport `device`,
  sdk 29, `sys.boot_completed=1`). That is the control: a panic alone does not enter recovery.

* **Panic with the BCB armed lands in recovery (epoch 1795344145 crash).** From Android (stock p8),
  the blob was written into `misc` (readback verified: full `a7c5eaf9cd0b6293…`, head equal to the blob),
  then `echo 10 > /proc/sys/kernel/panic` and `echo c > /proc/sysrq-trigger`. The crashed boot's console
  is recorded in **`dmesg-ramoops-0`** (105,125 B, sha256 `ae188fd27c3b81c5c68a46ac15da5d39e5e67b8b8ad78e06ebc608166752c523`):
  `hu: bcb armed for PANIC-from-Android blob=ceaae1a6314a1992 command=boot-recovery recovery=recoveryNL`
  at 89.612 s, `sysrq: Trigger a crash` at 90.950 s, `pc : sysrq_handle_crash+0x20/0x30`,
  and `Kernel panic - not syncing: Fatal exception` at 91.108 s. The boot that followed it is the stock
  recovery UI - the owner saw a header **without** `-HUPATCH` because Android had already reverted
  partition 8 - and its console (50,598 B, sha256 `a138c1f755dd3101fcfe3269ed7dfbed498cd641619b9ed1c6eb0c73fe14996a`)
  contains **no** module lines and begins `Kernel command line: … androidboot.mode=normal … b.mode=recovery`,
  ending `reboot: Restarting system with command ''` at 576.141 s (the owner's menu reboot). Again:
  normal register, recovery landing, so the armed BCB alone is enough on the panic path too.

* **`b.mode=panic` is what a panic reboot leaves behind.** The boot that followed the first crash carried
  `b.mode=panic` in its command line and booted Android normally, so the panic path does set its own
  marker; u-boot does not turn it into recovery. `androidboot.mode=normal` stayed normal in all four
  boots examined, which is why the register cannot be used as the safety mechanism.

* **`/dev/mem` is absent in this recovery ramdisk, so the register cannot be probed on the unit.**
  `ls -l /dev/mem` reports MISSING, busybox 1.11.1 answers `devmem: applet not found`, and
  `toybox devmem 0xff320300` fails on the missing node. The register rows of the arming matrix are
  therefore filled from boot command lines (`androidboot.mode=` / `b.mode=`) rather than from writes
  at `0xff320300`, and that branch stops per the owner's instruction.

* **pstore truth updated (Android side).** In Android, `/sys/fs/pstore` holds three entries -
  `console-ramoops-0` 50,598 B, `pmsg-ramoops-0` 174 B (sha256 `ce67a923acaeed8b0e78d5562157f5363de4b3f338683306d19c9611f27603c8`,
  a few adbd lines), and **`dmesg-ramoops-0`** which was never listed inside recovery: that is the crash
  record backend, so a panic boot leaves a readable record that the *following* boot can pull. The
  entries survived being read twice in this session, so the earlier "reading deletes it" note holds only
  for the console slot's turnover across boots, not for deletion on read.

* **State at the end of Phase A.** Partition 7 `b449aee98c01a7da797b…` (untouched), partition 8 stock
  `1fdf5ea77fc66f48977d7846c468959a5845d0222dc73c3fe07a1b96b6cb023b` (`cmp`-identical to the rollback
  capture), `misc` byte-identical to the recorded baseline `909bdd979111bcd531d6…` with an all-zero head
  (recovery cleared the armed BCB). Android is up over the dongle: carrier=1, speed=1000, duplex=full,
  ARP `REACHABLE`, port 5555 open. Both MMC cards were out for this whole cycle, so no card copies exist;
  the marker log `hu-mark.log` (4,101 B, sha256 `6ef4fb6f39f04315ab7b04cbd88964b2803f750c1515e0e10654a3f5f1c00223`)
  is the workstation record and shows `card: no mountable FAT32 card found - channel unused` in both
  patched recovery boots, while Android-written files in `/cache` (`dd-out-v6.txt`) did survive
  recovery boots. The idempotent partition 7 write was **not** performed.

* **Idempotent partition 7 write - a no-change write, recorded for D62 (Nov 22, evening).** The first
  4,096 B of `a14-work/hu-stock-postflash-143452/boot.bin` (the D76 rollback capture,
  `b449aee98c01a7da797b…`) were staged in `/data/local/tmp/hu-p7-head.bin` (`cmp`-identical to the
  capture head, head digest `fac15a4b138e113f6e3d…`) and written onto `/dev/block/by-name/boot` with
  `dd bs=4096 count=1 conv=notrunc`, rc 0, 4,096 B @ 7.2 MB/s. Host readback of the first 4 KiB hashed
  `fac15a4b138e113f6e3d…` and `cmp` matched the source head; the full partition then hashed
  `b449aee98c01a7da797be1c2aa8238ce4bef3e5ee3ae731afdcf3c53218c4384` both **before and after**, and was
  byte-identical to the capture. Partition 8 stayed stock `1fdf5ea77fc66f48977d…` and `misc` stayed at
  the baseline in the same operation, so the D62 pairing rule was not violated: partition 7 and
  partition 8 were not written in the same flash, and writing identical bytes leaves partition 7
  unchanged. This is the calibration of the Phase C write path: `dd` from a staged file plus a host
  readback proves the write without a digest change.

* **Cold-entry test with the BCB armed (Nov 22, evening - the cold column is filled).** From Android,
  partition 8 was flashed with build v6 (`bs=512 count=76352 conv=notrunc`, rc 0, 39,092,224 B @
  9.3 MB/s; host readback of the `bs=2048 count=19088` span hashed `b2821cce34ae352a370cc5ccd0eba2a4698ae9de4da5a350b397c8f06195bb39`
  and `cmp` matched the build), then the BCB blob went into `misc[0:2048]` (full readback
  `a7c5eaf9cd0b62938af6d2cc427602cbbc4e43ca8fa68d2dbe5030c8564562ea`, head byte-identical to the blob,
  exactly 22 bytes changed, bytes 2048..4 MiB identical to the baseline). Marker lines:
  `1795346793 p8-flash-v6-cold-begin`, `1795346798 p8-flash-v6-cold-end`,
  `1795346835 cold-arm bcb blob=ceaae1a6314a1992 p8=b2821cce34ae352a awaiting-power-cut`. **No reboot
  command was issued** - Android was still running (uptime 2007 s) when the owner cut power for 60 s.
  The unit came back sitting in recovery with `-HUPATCH` visible and the activity LED active. Over adb:
  transport `recovery`, sdk 29, `ro.bootimage.build.fingerprint` ending `release-keys-HUPATCH`,
  carrier=1 speed=1000 duplex=full, ARP `REACHABLE`, port 5555 open. Its live console (69,946 B, sha256
  `7d78f8aed65543299f8e055dfa63958b768cab101ebf4a9efc42379b6b1527ad`) begins
  `Kernel command line: … androidboot.mode=normal … b.mode=recovery`, and the module ran normally:
  `hu: card: no mountable FAT32 card found - channel unused` at 1.624 s, `node present at up=2.24`,
  `ADDRCONF(NETDEV_UP)` 2.642 s, UP 4.34 s, `Link status is: 1` 5.635 s, address 10.641 s,
  `ctl.start` 13.069 s, `adbd listen line=/proc/net/tcp6: … 15B3 … 0A (elapsed from carrier: 11 s)`
  at 13.192 s, carrier watch tick 20.45 s. So **a power-on with an armed BCB enters recovery**, and
  `androidboot.mode=normal` shows the reboot-mode register was not involved.
* **What the cold cycle showed about durability.** Inside that recovery boot `/sys/fs/pstore` was
  **empty** (`total 0`) - RAMoops content does not survive a hard power cut - so after a cold cycle the
  failed boot's console is gone and only the live console plus card copies are evidence. After the
  remote exit (`setprop sys.powerctl reboot`, rc 0, Android back ~40 s later, `sys.boot_completed=1`)
  Android's pstore held the recovery boot's console: `console-ramoops-0` 60,234 B sha256
  `7d81c45bd1bb2c8e60ab13e9f320bdc85294bb60f3c8ed3b2d4c08d52c656c82` (same boot as the live pull:
  `hu: net begin nonce=nov22-netmod5-…` at 1.624731 s, ending `reboot: Restarting system with command ''`
  at 189.150892 s) and `pmsg-ramoops-0` 3,685 B sha256 `f0e6782aa30df03fe2b417f069e17261627feb5978cc74b6750dafab4db9b57c`,
  with **no** `dmesg-ramoops-0` because nothing panicked. Partition state after that Android boot: p7
  unchanged `b449aee98c01a7da797b…`, partition 8 back to stock `1fdf5ea77fc66f48977d…`, `misc`
  byte-identical to the baseline `909bdd979111…` (recovery cleared the armed head, read back as
  `e5a00aa9991ac8a5ee31…` all zeros inside the recovery boot). Blob staging: `/data/local/tmp` was
  **not** visible in that recovery boot (`hu-bcb.bin` and `hu-patched-recovery.bin` not found), while
  the Android-written marker log survived - `hu-mark.log` 5,107 B sha256
  `5d5d08b8bed4bf2edae3010d38ddee450dac4ed52a1404844c94b521dc3e3455` keeps the cold-arm lines, and the
  recovery boot's own lines carry the unsynced device clock (`1514808001`), versus Android's clock
  (`android epoch=1795348010`, `Sun Nov 22 12:46:50 CET 2026`), so marker epochs across boots are not
  comparable and must be correlated by content.
* **Toolchain inventory on the workstation (Nov 22 evening, read-only).** Present: `clang version 23.1.4`
  (host target `x86_64-pc-linux-gnu`), `LLD 23.1.4`, `gcc (GCC) 16.2.1 20260810`,
  `GNU ld (GNU Binutils) 2.47`, `/usr/bin/qemu-system-aarch64`. Absent: `zig`,
  `aarch64-linux-musl-gcc`, `aarch64-linux-gnu-gcc`, `qemu-aarch64`, `qemu-aarch64-static`,
  `/usr/aarch64*` sysroot directories, and any Android NDK. `ld --help` lists only
  `elf_x86_64 elf_i386 elf32_x86_64 i386pep i386pe elf64bpf` - no aarch64 emulation. A probe compile
  (freestanding, `-nostdlib`, raw syscalls, `-fuse-ld=lld`, `-Wl,--build-id=none`, `-Wl,-e,_start`)
  produced a 1,072 B ELF: `ELF 64-bit LSB executable, ARM aarch64, version 1 (SYSV), statically linked`,
  no dynamic section, no `INTERP`, sha256 `b11327b88ba284c84d6160c43c7eb6201cc94b0cff1bc08bfb240551b8b9f1f8`.
  It is kept as evidence of what clang+lld can do here and is **not** used: the owner directed to stop
  because none of the preferred toolchains (zig, musl-gcc, aarch64-linux-gnu-gcc) exist, and not to
  install packages or improvise a route without asking.

## Nov 22 (evening) - the wrapper is built, HU_TEST runs, and three injected boot images are staged offline

* **Toolchain, installed by the owner.** `sudo pacman -S zig qemu-user` from the official repositories,
  no AUR and no full upgrade. Measured here: `zig version` 0.17.1, `qemu-aarch64 version 11.1.3`,
  `llvm-strip, compatible with GNU strip` from LLVM 23.1.5, `clang version 23.1.5` - the inventory
  earlier in this file recorded clang 23.1.4, the package install moved LLVM and clang to 23.1.5.
  GNU ld 2.47 still lists no aarch64 emulation and no `/usr/aarch64*` sysroot appeared, so zig and
  qemu-user are the only cross-target and user-mode runners.
* **Build.** `tools/hu_wrap.c` sha256 `fa0eedb6bf62ce0bd94a053084e73a90f3a6c219dcc791b989ac660b76bc3647`.
  `scripts/build_hu_wrap.sh` compiles with `zig cc -target aarch64-linux-musl -static -Os -Wl,--build-id=none`
  and then `llvm-strip`, with the same flags for `-target x86_64-linux-musl`, and `SOURCE_DATE_EPOCH=1760000000`.
  `hu-wrap-aarch64` is 13,968 B sha256 `99627bcec382241b15c97b140fba4bfbbc70e68fc6460843d81d54c372477051`,
  reported by `file` as `ELF 64-bit LSB executable, ARM aarch64, version 1 (SYSV), statically linked, stripped`,
  with no `NEEDED` entry and no `INTERP` segment. `hu-wrap-x86_64` is 13,264 B sha256
  `d141941a515a1b9b6050be63511f6ab18fc0e4826fd4d919ad5a24e30f99eb6d`, same two gates. The build log is
  a14-work/wraptest-nov22/build.log sha256 `39afc476073d4f0b5fdd855fb01a287d17593580c3f34ae1adcc1aa954ad5d82`.
  A second build into a different directory reproduces the aarch64 digest byte-for-byte: the packing is
  deterministic.
* **HU_TEST on the workstation.** `scripts/smoke_hu_wrap.sh` runs the x86_64 build natively and the
  aarch64 build under `qemu-aarch64 -L / -0 <argv0>`, against a plain file standing in for `misc`, with
  the reboot syscall suppressed in test mode. Six scenarios plus twelve source-level assertions,
  **0 failures**: healthy arm (`bcb pwrite=2048`, `bcb verified`, `init.real` ran, file equals the BCB
  blob), misc missing (`ARM FAILED: misc open failed`, boot continues), write fails (read-only file
  untouched, boot continues), passthrough (`argv0=/sbin/adbd` reached the exec untouched, no BCB write),
  watchdog fires (`BCB still armed, rebooting into recovery`, reboot suppressed), disarmed before the
  watchdog (`BCB disarmed, no reboot`).
* **HU_TEST on the unit.** The same binary was pushed to `/data/local/tmp/hu-wraptest`, copied as `init`
  so `argv0` has basename `init` and as `notinit` for the passthrough leg, run against loopback files
  with `HU_TEST=1`. s1 healthy arm: `pwrite=2048`, readback verified, `init.real` ran. s2 misc missing:
  `ARM FAILED: misc open failed`, boot continues. s4 passthrough (`argv0=./notinit`):
  `passthrough: not PID-1-as-init`, no `pwrite`, loopback untouched. s5 watchdog: still armed at the
  tick, reboot suppressed. s6 disarmed before the tick: `BCB disarmed, no reboot`. Logs and loopbacks
  are archived in a14-work/wraptest-nov22/unit/; the armed loopbacks `unit-misc1.bin` and `unit-misc5.bin`
  hash to the registered BCB blob `ceaae1a6314a19927ab431d55b46d08a6aaf73e9bcceb578244783c06bffd00e`,
  `unit-misc4.bin` is all zeros. Scenario logs sha256: s1 `170c185ba1c377d24296f9d99800030c90aafb14b5a03566cd63ee750e284c0f`,
  s2 `3d58448852b01d2b6222bef4db6155ed25e50f72a36ef990d00989c24fa81c4d`, s4 `0d2e2c8b64ee68737dbb3283d3b2bc3d24829998d96d335c1bb47bbcc7e8421f`,
  s5 `4fa83894bd55f0ca2fef6d29cda7309adc47569642e20ea4427d2b7ab381f49e`, s6 `4618d363b7516d30956d63fa27f5984a52d3fc27280120ac70a5fe6823eae4b0`.
  **The write-fail leg cannot be enforced on the unit**: as root under permissive SELinux a `0444`
  regular file is still writable, so the unit's s3 reports `bcb pwrite=2048` rather than `ARM FAILED`.
  That leg is host-only; the node-level failure path is exercised by the misc-missing leg.
* **The ramdisk cpio layout, measured.** Both ramdisks decompress to a cpio whose entry headers are
  **110 bytes**: thirteen eight-hex-character fields - inode at 6, mode at 14, uid at 22, gid at 30,
  nlink at 38, zero at 46, filesize at 54, zero at 62, zero at 70, devmajor at 78, devminor at 86,
  namesize at 94, zero at 102 - then the name, padded so the entry data starts on a 4-byte boundary,
  and the data itself padded to 4 bytes. The last entry is `TRAILER!!!`, followed by trailing padding:
  172 B in the stock Android 10 ramdisk, 252 B in the Android 14 payload ramdisk. `cpio -itv
  --format=newc` and `7z l` read these archives and list the payload's device nodes with their
  devmajor/devminor (`dev/console` 5:1, `dev/null` 1:3, `dev/urandom` 1:9). `cpio -idm` as a non-root
  user fails on those nodes: `cpio: dev/console: mknod() is not permitted`, and the same for `dev/null`
  and `dev/urandom`, so extract-and-repack cannot be used for the payload ramdisk.
* **Injection is an in-place byte transform.** `scripts/inject_hu_wrap_boot.py` walks the archive,
  copies untouched entries verbatim, renames the entry named `init` to `init.real` (only the name and
  namesize bytes change), inserts one new `init` entry holding the wrapper with mode `0755` and inode
  max+1 at that position, keeps the trailer and its trailing padding, and recompresses with gzip
  `mtime=0` and no stored filename. `scripts/verify_hu_wrap_boot.sh` checks it independently: two builds
  produce the same image; `7z x` extracts `/init` byte-identical to the wrapper binary and `/init.real`
  byte-identical to the base image's original `/init`; the fstab is unchanged; the wrapper extracted
  from the image passes the arm and passthrough scenarios; device nodes keep their mode and
  devmajor:devminor; the resource entries inside `second` and in the tail match their declared SHA1s.
  `7z` cannot create device nodes as a non-root user, so the node check compares the cpio streams, not
  the extracted directories.
* **Three staged images, all 33,554,432 B, built offline; nothing was flashed.**

  | image | sha256 | base | header diff | ramdisk gz | content end |
  |---|---|---|---|---|---|
  | hu-wrap-stock-a10.img | `b1378cd794979f97fd0715087b2191f2bcc89ad4204361922d88e44542b45467` | stock p7 capture `b449aee98c01a7da797b…` | bytes 16..19 | 810,786 B | 27,412,480 B |
  | hu-wrap-a14rd.img | `8f287e8bfa98b3fc2e7286f9bc914ceff06a34ee4d4337929a15d4ac0cca074a` | faithful A14 base `e504655b…` | bytes 16..19 | 1,637,631 B | 28,239,872 B |
  | hu-wrap-a14rd-diag.img | `02ac85b9aee47174786ef758db0255dfec20a21e2196d6248589832d77a2cd7a` | same base | bytes 16..19 and 397..440 | 1,637,631 B | 28,239,872 B |

  The base a14-work/hu-wrap-boot/base-a14rd-faithful.img sha256 `e504655bd32c3c9c6bcb0de3de6a2a9a3f67c33f3638e7bac022151217b11f4f`
  is `tools/rebuild_boot_faithful.py` output from the Nov 20 stock capture and the shape A payload, and its
  digest is **identical to the Nov 19 faithful image** recorded earlier in this file: the rebuild reproduces
  across the capture refresh. `tools/identity_gate.py` passes on that pair: the pipeline reproduces the stock capture byte-for-byte,
  the kernel blob (25,671,688 B) and the `second` blob (924,672 B) are identical, the tail is identical
  from the content end onward, and the payload's header deviations stay inside bytes 16..19 and 64..575.
  All three images carry the tail verbatim from their own content end, so the splash data and the tail
  resource header at 32,092,160 B keep their base positions.
* **Cmdline tokens ride in partition 7's header - the earlier claim was wrong.** The header cmdline
  field is 512 B at bytes 64..575 and D60 already permits writing it. Measured again today:
  `boot-min.img` `3cf40129…` and `boot-diag.img` `85dd1138…` differ by **exactly 9 bytes at 397..405**,
  `" panic=12"`, with kernel, ramdisk, `second` and every load address identical. The stock header
  cmdline (334 B) appears **verbatim** inside the live `/proc/cmdline` (670 B), which is what u-boot
  appends to. So `ignore_loglevel`, `panic=10` and `softlockup_panic=1` can be carried in p7 alone: the
  staged hu-wrap-a14rd-diag.img puts them at bytes 397..440, 377 B total inside the 512 B field. Whether
  this vendor kernel honours those tokens is **not measured** - that is a boot-time question.
* **Gates that cannot run on this workstation:** `tools/payload_coupling_check.py` and
  `scripts/verify_artifacts.sh` need the Lineage tree at /srv/dev-disk-by-label-SSData/aospbuild/lineage21s
  (build host, not mounted here), `tools/vendor_link_closure.py` needs the same tree,
  `scripts/check_super.py` runs on the build host, and offline vintf stays indirect through the dist
  `check_vintf` logs, which are skipped with `SKIP_DIST=1`.

## Nov 22 (night) - the NAS build host is reachable again, and the gates that were blocked ran

* **Access restored.** The owner gave the NAS root credential and the wrapper outside the repo was
  rebuilt: /tmp/opencode/build_host.env (mode 600), /tmp/opencode/askpass.sh (700) and
  /tmp/opencode/omv.sh (700). Password authentication goes through `SSH_ASKPASS`, the credential never
  appears in argv, stdout, docs or the repo. `sh /tmp/opencode/omv.sh 'echo NAS_OK'` returns `NAS_OK`
  from host `apollo` at `192.168.1.29` (Debian 13, kernel 6.12.107+deb13-amd64, as root), ping rtt
  0.13-0.21 ms. On that host: `python3 3.13.5`, `/usr/sbin/debugfs`, `cpio`, `gzip`, `sha256sum`;
  `simg2img` and `lpdump` are not on PATH but exist in the tree at
  /srv/dev-disk-by-label-SSData/aospbuild/lineage21s/out/host/linux-x86/bin. Space: SSData is 372 G
  with **2.7 G free** (100% used), NAS `/tmp` is tmpfs with 8.2 G free, `free -h` shows 23 Gi total
  and 12 Gi available.
* **Nothing moved to cold storage.** `/srv/cold` exists on the NAS, but the build artifacts are still in
  the tree: /srv/dev-disk-by-label-SSData/aospbuild/lineage21s is present, `out` is 118 G, and the
  product dir is `out/target/product/rk3399` (not `rk3399-px6-hct4`). The repo checkout on the NAS is
  /srv/dev-disk-by-label-SSData/aospbuild/VibeBakingFirmware, and its `device/rk3399-px6-hct4/` still
  holds the generated drop list `vendor_build_wins.txt`.
* **Artifact digests read on the NAS (12-hex prefixes).** `boot.img` 32,796,672 B `cf05255148b8…`,
  `vendor.img` 432,275,456 B `90ed4009ce96…`, `super.img` 2,277,550,048 B `2a1246aaf055…` - these are the
  registered shape B artifacts, unchanged. Also there: `system.img` 1,012,871,168 B `3f177a1bee01…`,
  `system_ext.img` 384,802,816 B `41e0cd3047ac…`, `product.img` 456,159,232 B `45e70fbb69dd…`,
  `odm.img` 811,008 B `6135f61bc449…`, `recovery.img` 44,689,408 B `eb0f86b37bf7…`,
  `ramdisk.img` 1,632,189 B `73966919b9dc…`, `super_empty.img` 4,644 B,
  `lineage_rk3399-ota.zip` 1,012,957,295 B `931bbb45cff1…` dated 2026-11-08 13:29.
  `vendor/hct4/prebuilt/vendor_a10.img` is 323,530,752 B `3fe2f53aa1f1…`; it was pulled to the
  workstation and both sides hash to that value.
* **What the shape A reference vendor actually contains.** Inside `vendor_a10.img`: `/lib64` 43 entries,
  `/lib` 71 entries, `bin`, `etc`, `firmware`, `odm`, `overlay`, `build.prop`, `default.prop`,
  `ueventd.rc`. `debugfs -R "find /"` finds **no** `libion.so` anywhere in it, `/lib` has
  `libstagefright_softomx_plugin.so`, `/bin/hw` carries `android.hardware.health@2.0-service`
  (**not** 2.1), and its manifest is version 1.0 target-level 4 with 26 inline HAL declarations and no
  `<kernel>` tag. So the injected Android-14-era libraries and the 2.1 health service come from the
  patched shape A vendor, not from this reference image.
* **Coupling gate for the iteration-1 pair: PASS.** The vendor that ships with the shape A payload was
  carved out of a14-work/a14chk-shapeA/raw-super.img with `lpdump` (extent `0 .. 1086079 linear super
  1980416`) into 556,072,960 B sha256 `7a5ce939be0f…`. `tools/payload_coupling_check.py` against
  hu-wrap-a14rd.img reports: kernel banner 4.19.111+, DTB inside `second` at +2048 size 152,425,
  21 `.ko` with vermagic 4.19.101+/4.19.111+/4.4.167, `hu_insmod` list 14 module(s) 14 present
  0 absent 0 wrong vermagic, `/lib64` and `/lib` each carrying libion.so, libaudioroute.so,
  libaudioutils.so, libspeexresampler.so, libprotobuf-cpp-lite.so and
  libstagefright_softomx_plugin.so, criterion HAL files present (the GNSS trio, the MFI trio,
  audio.primary.rk30board.so, gralloc.rk30board.so, the 2.0 mapper/allocator impls and services,
  the omx service, and health@2.1), manifest version 8.0 target-level 4 with no `<kernel>` tag.
* **`scripts/verify_artifacts.sh` ran on the NAS** with `SHAPE=a10` and `WORK=/tmp/a14gate` (the SSData
  scratch has only 2.7 G free, and the script switches to a scratch with room). Results: raw super
  3,263,168,512 B, group `hct_dynamic_partitions` 3,258,974,208 B, all five logical partitions
  byte-identical to their product-dir images with ext4 magic at offset 1080 and debugfs parsing them -
  **ALL LOGICAL PARTITIONS VERIFIED: True**; used 2,289,852,416 B, spare 973,316,096 B, group fits
  inside `super_partition_size`. VINTF logs are successful: `check_vintf_compatible.log` 155 lines,
  `check_vintf_system.log` 57 lines, `check_vintf_vendor.log` 22 lines, each reporting
  `Successfully processed VINTF information` - that closes the "offline vintf is indirect" gap with
  evidence. The recovery ramdisk carries a real installer: `ramdisk-recovery.img` 13,523,948 B
  decompressed to 38,768,128 B, `update_engine_sideload` 2,942,312 B,
  `system/lib64/libfusesideload.so` 135,200 B, `system/etc/recovery.fstab` 4,190 B with rows for
  metadata, cache, boot, recovery, misc and userdata. The OTA zip unzips cleanly (26 entries).
* **The tree's current pass is shape-B-flavored and does not satisfy the shape A expectations.** The
  built `boot.img` carries kernel 4.19.193 (30,455,816 B), `second` 544,768 B and header `dtb_size`
  157,962; its ramdisk has **no** `first_stage_ramdisk/fstab.rk30board` (**D34**), the built vendor's
  manifest is version 8.0 **target-level 5** and **declares `<kernel>`**, and `lib/hw/gralloc.rk30board.so`
  is missing from it. `tools/vendor_link_closure.py` reports 12 audio/bluetooth common libraries
  "not installed yet (rebuild after device.mk picks them up)" and one kept blob needing symbols Android
  14 does not export (the audio 4.0/5.0 `IDevicesFactory`/`IStreamOut` symbols, 309 more listed). The
  gate's verdict line: `VERDICT: flashable build = NO` for that artifact set. The pair that is flashable
  for iteration 1 is the staged shape A pair measured above, not these tree images.
* **Nothing was written on the NAS except its own /tmp scratch.** The closure tool ran against a copy of
  the device dir in /tmp/a14gate, so the repo copy's generated files were untouched; /tmp/a14gate was
  removed after the run. No build was started, no tree file changed, no head-unit write happened.

* **After that gate run, additive copies were made into cold storage on the NAS** (the mergerfs DataPool,
  which the Nov 11 note wrongly called ZFS). The Nov 22 wrapper work, the four staged boot images, the
  pulled vendor images and the tree's finished pass are mirrored there; every copy was verified by
  digest on the NAS side, nothing was moved or deleted, and the tree's `out/` stays inside `lineage21s`.
  The paths, byte totals and verification counts, and the warning that the pool's older `hu-stock-backup`
  is a Nov 11 backup rather than the iteration-1 rollback, are recorded in docs/housekeeping.md.

## Nov 22 (late) - Phase B leg 1: partition 8 then partition 7 written; the wrapper's first boot is in flight

* **Baseline before any write** (read-only pulls, hashed on the workstation): partition 7 `b449aee98c01…`
  33,554,432 B, partition 8 `1fdf5ea77fc6…` 100,663,296 B, `misc` `909bdd979111…` 4,194,304 B with its head
  all zeros, `androidboot.mode=normal`, `sys.boot_completed=1`, Android 10 over TCP 5555. The cache partition
  measures 402,653,184 B; Android mounts `/cache` with 189 MB free.
* **Staged in `/cache` from Android**, each verified on-device with `toybox sha256sum`: candidate
  `hu-candidate-boot.bin` `b1378cd79497…` (33,554,432 B), rollback `hu-rollback-boot.bin` `b449aee98c01…`,
  and `hu-net.request` carrying nonce `iter1-nonce-a`. No `hu-restore.request` was created, so the recovery
  service's auto-restore path stays dormant. The v6 recovery image was also pushed to
  `/data/local/tmp/rec/` with its digest file for the flash script.
* **Flash 1 - partition 8 only, from Android** with `scripts/flash_recovery_from_adb_root.sh`: staged digest
  `b2821cce34ae…`, wrote 39,092,224 B, the script's readback reported ok. Recovery was entered immediately
  after (`setprop sys.powerctl reboot,recovery`, epoch `1795374906`); Android was never booted in between,
  which is the D82 staging rule.
* **Recovery answered on TCP 5555 within seconds** and `adb devices` reported state `recovery`.
  `/proc/cmdline` carries `b.mode=recovery` alongside `androidboot.mode=normal` (**D90** holds). The v6 net
  module armed on the nonce: the marker `net-done-iter1-nonce-a.txt` was written, `eth0` took
  `192.168.1.127` with carrier=1, adbd's listener shows `0x15B3` state `0A` in `/proc/net/tcp6`, and
  telnetd listens on 2323 (`0x0913`).
* **Measured: entering recovery clears the BCB.** The misc head read inside that recovery boot is all zeros
  (`e5a00aa9991a…` over 2048 B) although the same boot's cmdline shows `b.mode=recovery`. So the armed
  message is consumed by the recovery boot itself: a reboot out of recovery either re-arms `misc` or boots
  partition 7 normally.
* **Measured: the v6 recovery services do not mount `/cache`.** `/proc/mounts` had no `/cache` entry, yet
  `hu-net.sh` and `hu-state.sh` wrote their markers and snapshots - `cache_ready` passes on the ramdisk
  directory, so those files live in RAM and die with the boot. Pulling them over adb while recovery runs is
  what makes them durable; all four were pulled: `hu-mark.log` 7053 B `dc3769d21127…`,
  `state-recovery-5.txt` 6438 B `4a6c2ce2f5ae…`, `state-recovery-30.txt` 6291 B `64cb0e563381…`,
  `misc-head.bin` 2048 B `e5a00aa9991a…`. Mounting the partition by hand works and costs nothing:
  `/sbin/busybox mount -t ext4 /dev/block/by-name/cache /cache` returns rc 0 and the staged files become
  readable there with their digests.
* **Measured: a card is mounted at `/mnt/hucard` by `hu-card.sh`** and received the snapshots
  `state-recovery-5.txt` 6438 B, `state-recovery-30.txt` 6291 B and `state-recovery-120.txt` 6213 B. The
  handoff says both MMC cards are out, so this contradicts that note; which card is in the slot has not been
  identified yet and must be checked before treating the card copies as durable evidence.
* **Flash 2 - partition 7 only, from recovery with partition 8 frozen**:
  `/system/bin/dd if=/cache/hu-candidate-boot.bin of=/dev/block/by-name/boot bs=4096 conv=fsync` returned
  `8192+0 records out`, rc 0. The workstation readback of all 33,554,432 B hashes to `b1378cd79497…`, equal
  to the staged candidate. Partition 8 read back over its image span (39,092,224 B) hashes to
  `b2821cce34ae…`, unchanged. The misc head is still all zeros after this write.
* **The wrapper's first boot is pending.** `setprop sys.powerctl reboot` was issued at epoch `1795375253`.
  At 130 s later: ping lost with no ARP entry for `192.168.1.127`, TCP 5555 closed, `adb devices` shows only
  the stale `offline` entry, and the owner reports button backlighting with a black screen. The wrapper's
  watchdog (~300 s, re-reads the BCB through its open fd) has not been observed yet; the monitor runs on the
  workstation. Nothing was written after the reboot was issued.
* **No answer within the monitor window.** The monitor ran from 130 s to 390 s after the reboot was issued
  and saw nothing but a stale `offline` adb entry until it disappeared; at 712 s ping still lost with no
  neighbour entry for `192.168.1.127`, TCP 5555 and 2323 (recovery's telnetd port) were both closed and
  `adb devices` listed no device. The owner reports only button backlighting and a black screen. So neither
  Android nor a networked recovery boot answered: the wrapper's watchdog reboot has not been observed, and
  no environment exists right now that can read the dead boot's console. Nothing was written after the
  reboot was issued; partition 7 holds `b1378cd79497…` and partition 8 holds `b2821cce34ae…`.
* **The owner stopped the attempt and took physical control** (reported Nov 22, late): they tried to boot
  from the stock recovery aiming to keep the head unit's data intact, that was not successful, the recovery
  menu's `reboot to bootloader` option keeps the bricked state, and they are applying the `update.zip` route
  (**D97**). Nothing was written from the workstation after the reboot was issued, and the workstation's adb
  transport stayed dead throughout.

## Nov 22 (late) - the owner's install brought the unit back; checked read-only, no re-clone

* **Restored, with userdata intact** (owner report). Measured from the workstation at epoch `1795376757`+:
  ping OK (rtt 0.580/0.838/1.097 ms), ARP `REACHABLE` for `00:0a:cd:27:a5:b2`, TCP 5555 open,
  `adb devices` state `device`, `adb root` works, Android 10 `rk3399-userdebug 10 QQ2A.200305.004.A1
  eng.hct2.20250401.152740 release-keys`, `sys.boot_completed=1`, `androidboot.mode=normal`.
* **Partition state checked with bounded 4 KiB head digests, not by re-cloning partitions** (owner
  instruction: do not waste space or time re-cloning the HU's current state). Partition 7 head
  `fac15a4b138e…` equals the head of the pre-restore stock capture; partition 8 head `b06dc33648a3…` equals
  the head of the pre-restore stock capture; `misc` head `0f2ec43e7a5c…` equals the baseline capture and its
  first 64 B are all zeros. Head equality over 4 KiB is not full-partition equality; it says the images are
  back on the stock heads. Sizes unchanged: boot 33,554,432 B, recovery 100,663,296 B, misc 4,194,304 B,
  cache 402,653,184 B, super 3,263,168,512 B. `ro.boottime.flash_recovery` read 3754681376 ns (3.76 s), so
  partition 8's self-heal ran (**D82**).
* **`/data` survived the install:** `/dev/block/mmcblk2p15 54G 10G 44G 19% /data`, and `/data` lists
  `adb anr apex app app-asec app-ephemeral`.
* **Nothing was written.** Only bounded reads and property reads. The wrapper candidate `b1378cd79497…` and
  the v6 recovery `b2821cce34ae…` are no longer on the unit; both remain staged offline on the workstation
  and mirrored in cold storage (**D96**).

## Nov 22 (late) - the SD-boot card becomes the recovery carrier; STEP 0 read-only measurements

* **Owner decision, superseding the deathgrip test (**D98**).** The deathgrip does not reach any recovery.
  The owner got out of the soft-brick only with the SD-boot card - its stock recovery ran the OEM
  `update.zip` - so the SD-boot card is now the networked recovery carrier and its own partition 8 is the
  recovery that gets patched. eMMC partition 8 is out of the loop; eMMC partition 7 stays gated by the
  ladder later.
* **Owner report of the boot sequence, verbatim:** "Card inserted and reboot either power cycle reset
  button or 10 sec home+press on volume knob". Nothing about this sequence is measured; it is recorded as
  reported.
* **Device identification by size and type** (measured with `cat /sys/block/mmcblk*/device/type` and
  `blockdev --getsize64`, on a running Android 10 with the card in): `mmcblk0` type=SD size=31,266,439,168 B,
  mounted read-write by Android as `/mnt/media_rw/363A-7751`; `mmcblk1` type=SD size=7,948,206,080 B, which
  is the SD-boot card, and mmcblk1 is not mounted by Android; `mmcblk2` type=MMC size=62,813,896,704 B, the
  eMMC. Nodes are identified by size and type, never by number alone.
* **`/dev/block/by-name/*` in Android with the card present** still points at mmcblk2 partitions only:
  boot -> `mmcblk2p7`, recovery -> `mmcblk2p8`, misc -> `mmcblk2p3`, cache -> `mmcblk2p11`,
  super -> `mmcblk2p14`, userdata -> `mmcblk2p15`. No card-side by-name links exist while Android runs.
* **Card partition sizes measured on the device** (`blockdev --getsize64`): p1 4,194,304, p2 4,194,304,
  p3 4,194,304, p4 4,194,304, p5 4,194,304, p6 1,048,576, p7 33,554,432, p8 100,663,296, p9 117,440,512,
  p10 4,194,304, p11 402,653,184, p12 16,777,216, p13 524,288, p14 3,263,168,512, p15 3,978,804,736.
* **Rollback position:** no spare blank card of the same size is available, so the verified workstation
  image of the whole card is the rollback. The capture is pull 1 stored plus pull 2 re-read and hashed; the
  two digests must match before anything is written.
* **The re-arm step exists as `scripts/arm_card_misc.sh` `026f22a31da8…`.** It resolves the SD card by size
  7,948,206,080 B and type SD, takes partition 3 sized 4,194,304 B, refuses any `mmcblk2` target by
  construction, builds the 2048 B blob whose digest is the registered `ceaae1a6314a…`
  (`boot-recovery\0` at 0, `recovery\n` at 64, zero padding, no arguments), writes it with
  `dd conv=notrunc bs=2048 count=1`, then reads back 2048 B and compares digests. `HU_MISC_FILE` plus
  `HU_OFFLINE=1` runs the same logic against a regular file, and a file target must exist and be
  partition-sized or the script writes nothing.
* **Offline gate `scripts/smoke_card_rearm.sh` `c43bd57fedea…`: five scenarios pass, failures=0.** Against a
  zeroed 4,194,304 B file it re-armed with rc 0, the head digest equalled the registered blob digest, offsets
  13..63 and 73..2047 stayed all zero, the byte at 2048 was untouched, a second arm left the whole-file digest
  at `6c3d06b0`, an eMMC-shaped target was refused with rc 1 and stayed byte-identical, and a missing target
  was refused with rc 1. `tools/sd_card_layout.py` reads the GPT out of the captured card
  image and checks each partition span against the size the device reported.
* **The single-stream card pull stalled after 241,047,471 B of 7,948,206,080 B.** The file's mtime stayed at
  epoch `1795377882` while the workstation's `adb exec-out` process ran 46 min; both socket tables showed
  tx/rx queues of 0, `ss` showed the connection ESTAB with 0/0, ping answered, `adb devices` reported state
  `device`, and the card node still read type SD size 7,948,206,080 B. The partial stream is kept as
  `a14-work/sdcard/stall-partial-241MB.bin` 241,047,471 B sha256 `a2eaa567cf17…`; the capture script aborted
  on the size mismatch, so nothing was trusted from it.
* **Chunked capture in use instead.** The card is read in 1 GiB chunks (`bs=1M skip=<i*1024> count=1024`),
  each chunk checked against its expected size, digested on the workstation, and bounded by a 300 s timeout;
  the node's size and type are re-checked before every chunk. A verification pass re-reads every chunk and
  compares digests before the assembled image is trusted, and per-chunk rate is logged rather than assumed.
* **Transport measurements, taken on a running Android with the card in** (`toybox dd` timings and
  `dd ... of=/dev/null` on-device): reading the raw card on-device into `/dev/null` moved 268,435,456 B in
  18.39 s = 14 MB/s, so the card itself reads at 14 MB/s; a fresh 64 MiB exec-out read from the card
  (`bs=1M skip=600 count=64`) returned 67,108,864 B in 6 s = 11.18 MB/s with rc 0; a 64 MiB exec-out read
  of `/dev/zero` returned 62,010,848 B of the 67,108,864 B requested in 60 s and exited rc 0. The chunked
  1 GiB pass measured 559,392,735 B in 300 s = 1.86 MB/s before hitting its timeout.
* **Capture in use: base64 chunks of 33,554,432 B** (`bs=1M count=32`, `dd | base64` over exec-out,
  decoded on the workstation), the size proven reliable in the iteration-1 readbacks. 237 chunks
  (236 full plus a 29,360,128 B remainder), each re-checking the node by size and type, each decoded to its
  expected byte count and digested, then a second pass re-reads every chunk and the assembled image is
  compared against the re-read digest before anything is trusted.
* **Card-boot mode of the net module is built and gated offline (`scripts/smoke_card_module.sh` `0b49ba06255c…`).** The card
  build bakes `/sbin/hu-card-boot.flag` into the card's own ramdisk; with that flag present the module keeps
  its markers and log in RAM (`CACHE`, `LOG`, `NETREQ` point at `/tmp`), resolves the misc head from the
  card's own node by size and type (`/proc/partitions` blocks plus `/sys/block/<n>/device/type`: SD at
  7,761,920 blocks, partition 3 at 4,096 blocks), and never opens a partition. Measured in the offline gate:
  RAM paths confirmed; misc resolved to the fake card node; a wrong-size SD and a wrong-size partition 3 were
  both refused with rc 1 and stated why; the misc head read 2,048 B from the card node and did not carry the
  planted eMMC marker; the pstore copy landed in RAM; `hu-card.sh` refused with rc 0 and the fake mounted card
  stayed byte-identical; `hu-state.sh` refused its card copy and the snapshot stayed in RAM; `hu-net.sh` armed
  without any nonce file (`nonce=card-boot`) with the window default 360 ticks of 10 s = 30 min, while the
  eMMC path keeps its 120-tick 20 min default; no `mount -t ext4` was invoked; the card misc node and the
  eMMC-shaped node were byte-identical after the whole run. failures=0, exit status 0.
* **The builder's card mode is `HU_CARD_BUILD=1`** in `scripts/patch_recovery_netmodule.sh`: the appended rc is
  generated from the capture's own stock `init.recovery.rk30board.rc` plus `scripts/hu_net_module_block_card.rc`
  (state snapshots to `/tmp`, `hu_card` defined but not started, `hu_install` absent), the flag is baked, and the
  gate now expects `hu_card` started 0 times in the card build and refuses `hu_install` in it. The existing
  gates stay green with the flag absent: `smoke_recovery_netmodule.sh` 153 assertions pass (its early-service
  expectation now reads the node-aware line `early misc node=... head size=2048`), `smoke_recovery_evidence.sh`
  and `smoke_recovery_installer.sh` pass, `smoke_hu_wrap.sh` passes with 0 failures, pytest 19 passed.
* **The card's partition table is vendor-written and self-inconsistent.** From the first 2 KiB of the capture
  stream: the header signature is `EFI PART`, revision 65536, header_size 92, entry_count claimed 0,
  entry_size claimed 15,523,839 (not 128), entry CRC 0, `first_usable_lba` 34, `last_usable_lba` 15,523,806,
  and LBA0 is all zeros (no protective MBR). The records themselves are well formed at a 128 B stride with the
  name field at record offset 56, but the start/end LBA fields sit at record offset 32/40, not the standard 8/16.
  Read from those offsets the records tile the disk: uboot 16384..24575, trust 24576..32767, misc 32768..40959,
  dtb 40960..49151, dtbo 49152..57343, vbmeta 57344..59391, boot 59392..124927, recovery 124928..321535,
  backup 321536..550911, security 550912..559103, cache 559104..1345535, metadata 1345536..1378303,
  frp 1378304..1379327, super 1379328..7752703, userdata 7752704..15523806. Converted to bytes those spans
  equal the sizes the unit reported for p1..p8 (`blockdev --getsize64`), so the layout is consistent with the
  device even though the header's own counts are not. 8 MiB between `first_usable_lba` 34 and the first
  partition at LBA 16384 holds no partition record.
* **`tools/sd_card_layout.py` `41f60ea834e8…` and `tools/card_image_analysis.py` `aab15720a666…` read that layout.** The layout tool tries the
  candidate record offsets and picks the one that yields monotonic, non-overlapping spans bounded by the
  header's declared disk size; the analysis tool shares the same reader and then reads the card's own boot and
  recovery contents. Measured on the partial stream's complete p7 and p8 spans: card boot (p7) header says
  kernel 25,421,832 B, ramdisk gz 803,440 B, second 903,168 B, DTB at 26,232,832 size 130,833 B, partition
  digest `1b47dbc48aee…`; card recovery (p8) header says kernel 25,421,832 B, ramdisk gz 12,515,795 B,
  second 903,168 B, partition digest `04ed02a2713c…`. The kernel blob is the same in both:
  `a11c2667f843…`, banner `Linux version 4.19.111+ … Linaro GCC 6.3`, and it carries `ax88179_178a` strings
  (`ax88179_178a.c` among them). The p8 ramdisk listing and its `init.recovery.rk30board.rc`,
  `recovery.fstab`, `prop.default` and `system/bin/recovery` digests come from the verified image, not from
  this partial stream.
* **The base64 pull pass measured 3.36-3.73 MB/s per chunk and assembled the whole card.** 237 chunks of
  33,554,432 B (last chunk 29,360,128 B) were decoded on the workstation and concatenated: 7,948,206,080 B,
  digest `ca6d1f4d3384…` at epoch `1795384713`. The verification pass re-reads every chunk and compares digests
  before the image is trusted; it was still in progress at the time of writing, so this digest is the assembled
  stream, not yet a verified copy of the card.
* **STEP 0.3 on the verified image.** The card's own boot (p7, offset 30,408,704, digest `1b47dbc48aee…` - the
  same digest the partial stream gave, so the two pulls agree) and recovery (p8, offset 63,963,136, digest
  `04ed02a2713c…`) share one kernel blob `a11c2667f843…` (25,421,832 B) and one second blob `948d678b9b9e…`
  (903,168 B). p8 ramdisk gz `65fd99c053e1…` 12,515,795 B, 484 entries. p8 carries a DTB at 37,945,344 size
  130,833 `9ffc84924422…` and a second DTB-shaped payload at 38,846,528 size 739 `e48134ad0ec7…` - so the card's
  recovery dtbo span is 739 B, not the eMMC's measured 803 B. p8 files measured: `init.rc` 6,363 B `c57d847660c8…`,
  `init.recovery.rk30board.rc` 663 B `8938ae4348de…`, `prop.default` 11,025 B `17cc18c1fd71…` (299 keys; it carries
  `ro.system.build.fingerprint`, `ro.build.display.id` and `ro.bootimage.build.fingerprint` and no `ro.adb.secure`
  line), `system/bin/recovery` 416,280 B `3aff97ce31d4…`, `sbin/sh` 206,684 B `93fa195954a3…`,
  `sbin/busybox` 1,807,056 B `e9ad9c4e8999…`, and `default.prop` is a symlink to `prop.default`.
  `recovery.fstab` is ABSENT from the card's recovery ramdisk (484 entries, none named recovery.fstab).
  The kernel blob contains 4 `ax88179` strings including `ax88179_178a.c`; whether the driver is built in or a
  module is not established by that measurement, and the discriminating measurement is whether an
  `ax88179_178a.ko` exists in the ramdisk listing (it does not appear in the 484 entries) versus the driver
  registering eth0 during a card boot.
* **The card's misc partition is not a clean BCB region.** Its first 2048 B digest is `51d5a08cb654…`:
  `boot-recovery\0` at offset 0 (run 0..12), and at offset 64 the stage line reads `recovery\n--wipe_all\0`
  (run 64..82), so the card currently instructs `--wipe_all` alongside the recovery stage. Bytes 2048..4,194,303
  are not zero - there is an `AB0` marker at 2049 followed by binary content, 412,385 separate non-zero runs in
  the partition. The re-arm step writes only the first 2048 B and leaves 2048..4,194,303 untouched; its blob is the
  registered `ceaae1a6314a…` BCB WITHOUT arguments, which differs from the card's current `--wipe_all` stage line.
* **Card-boot mode is approved (**D99**, owner: nonce-less arm, 30 min window, second card as the evidence channel) and the offline gate is green.** `scripts/smoke_card_module.sh` now reports failures=0 with exit status 0: an existing second-card mount is used without issuing a mount; a mount whose source is the boot card is refused and the second card is mounted instead at /mnt/hucard; the boot card's whole-device node and its misc node stayed byte-identical through the whole run; no eMMC node was mounted and no ext4 mount was invoked; the state snapshot and the log copy landed on the second card. The eMMC-side gates are unchanged and still pass: smoke_recovery_netmodule.sh, smoke_recovery_evidence.sh, smoke_recovery_installer.sh, smoke_card_rearm.sh and smoke_hu_wrap.sh all exit 0, pytest 19 passed. Module digests after the two fixes:
  scripts/hu_h_common.sh `a53640d56840…`
  scripts/hu_state.sh `a29c37e4a45d…`
  scripts/hu_card.sh `613494c28a0b…`
  scripts/hu_net.sh `da6acfae3910…`
  scripts/hu_early.sh `6450ebb0385a…`
  scripts/hu_net_module_block_card.rc `6b7c1d2be09a…`
  scripts/patch_recovery_netmodule.sh `1581b4ad7332…`

* **STEP 1: the card's own p8 is patched offline (Nov 23) and nothing was written to any device.**
  `HU_CARD_BUILD=1 HU_PART_BYTES=100663296 HU_DTBO_SIZE=803 scripts/patch_recovery_netmodule.sh
  /run/media/Daan/Opslagmonster/a14-work/sdcard/analysis/p8.bin /run/media/Daan/Opslagmonster/a14-work/card-p8`
  exited 0 and produced `card-p8/recovery-netmodule.img`, 100,663,296 B, digest `03dcdad7af92…`. A second
  independent build (`card-p8-repro`) gives the same digest, so the image of record is reproducible.
  * Header: only bytes 16..17 differ - the declared ramdisk size goes 12,515,795 -> 12,515,402. The declared
    dtbo size 803 at byte 1632, the dtbo offset 38,846,464 at byte 1636, header_size 1660 at byte 1644, the
    cmdline 64..575, page size 2048 and header version 2 are identical to the capture.
  * Kernel blob `a11c2667f843…`, second bootloader `948d678b9b9e…` at 37,943,296 and the dtbo region there are
    unchanged: the 803 B region digest is `28a07d4946e9…` and the 739 B payload after the 64-byte DTB header is
    `e48134ad0ec7…`, both unchanged by the patch. Everything from 37,943,296 to the end of the partition is
    byte-identical, including the 61,816,029 B of vendor data beyond the dtbo (`beca4ef242e1…`).
  * Ramdisk: 12,515,402 B gzip holding 493 cpio entries against the capture's 484 - 9 entries added, none
    removed: `sbin/hu-h-common.sh`, `sbin/hu-early.sh`, `sbin/hu-hb.sh`, `sbin/hu-state.sh`, `sbin/hu-net.sh`,
    `sbin/hu-card.sh`, `sbin/hu-udhcpc.script`, `sbin/hu-card-boot.flag` (0 B) and `sbin/hu-pad.bin`
    (25,948 B `649556ea25dd…`).
  * Why `hu-pad.bin` exists: the loader computes second_offset = ramdisk_offset + align(declared ramdisk size,
    2048). Without the pad the patched gzip is 12,487,018 B, which lands in the previous page and would move
    the second bootloader and the dtbo, so inplace mode binary-searches the filler size until the output lands
    inside the stock page span (12,515,328, 12,517,376]; 25,948 B of deterministic filler lands at 12,515,402 B.
    No rc or `init.rc` line names `hu-pad.bin`, so nothing reads it.
  * Files byte-identical to the capture's extraction (`sdcard/analysis/rd8/`): `system/bin/recovery`
    `3aff97ce31d4…`, `sbin/busybox` `e9ad9c4e8999…`, `sbin/sh` `93fa195954a3…`, `init.rc` `c57d847660c8…`. The
    stock menu and its `update.zip` path stay intact because the recovery binary and `init.rc` are untouched.
  * `prop.default` `17cc18c1fd71…` -> `81aa46e67f36…`: three build strings gain `-HUPATCH` and `ro.adb.secure=0`
    is appended. Measured byte effect 11,025 B -> 11,065 B, 8 diff lines (3 changed, 1 added, a blank line and
    the dropped final newline); the patched file no longer ends with a newline.
  * `init.recovery.rk30board.rc` `8938ae4348de…` -> `3d6a4b127c20…`: the capture's stock 663 B kept verbatim as
    the prefix plus the appended 1,519 B card block = 2,182 B. Each hu service is defined exactly once and
    started exactly once, `hu_install` is absent, and `hu_card` is started (**D99** approved evidence channel).
  * The write STEP 2 would need is the header page 0..2,047 plus the ramdisk span 25,425,920..37,943,295 =
    12,519,424 B of the 100,663,296 B partition. Inside that span 12,464,811 B differ across 50,745 runs;
    nothing outside it differs.
  * Superseded first run: the same tree built with `HU_DTBO_SIZE=739` and an unnormalised cpio gave
    `3af09dfaad04…`, declared 12,515,482 B, filler `sbin/hu-pad.bin` 25,766 B `cc1787d0c124…`, and reported its
    tail as the 61,816,093 B slice `891bdb3275c2…`. Those values are kept for traceability; the boundary only
    changes where the builder reports the tail starting, not the bytes - the output from the dtbo offset
    onward is identical in both builds, and nothing outside the header page and the ramdisk span ever differs.
  * Naming note: the builder's `rd-src` is the overlaid working tree (it already carries the hu files and the
    markers), not a clean extraction; `rd-patched` is a re-extraction of the output image, and its digests
    equal the working tree's, which is what proves the image carries the intended files.

* **The card image of record is mirrored into NAS cold storage (Nov 23, additive).**
  `/srv/50911774-19fb-46b6-bc9e-8cf81623d044/cold/vibe-baking/hu-card-p8-nov23/` holds
  `recovery-netmodule.img` (100,663,296 B), `MANIFEST.sha256`, `patch.log`, the `inject/` files and the three
  write spans (`spans/header-page.bin` 2,048 B, `spans/ramdisk-span.bin` 12,517,376 B,
  `spans/bcb-rearm.bin` 2,048 B) under `MIRROR.sha256` `c523dc48008a…`. `sha256sum -c` run on the NAS returns
  rc 0 with 16 of 16 entries OK; the directory is 109 MB and nothing existing was moved or deleted, so
  **D96** still holds.

* **STEP 2 executed (Nov 23, owner GO): the SD-boot card carries the patched p8 and a re-armed misc.**
  * Pre-state: the card's p8 pulled over adb was 100,663,296 B digest `04ed02a2713c…`, byte-identical to the
    verified capture. The card was resolved by whole-device size 7,948,206,080 B and type SD;
    `/dev/block/by-name/*` still points only at eMMC nodes, so no by-name path was used anywhere.
  * Writes: the header page (partition bytes 0..2,047) and the ramdisk span (partition bytes
    25,425,920..37,943,295 = 12,517,376 B) into `/dev/block/mmcblk1p8` with `conv=notrunc`, from blobs pushed
    to `/data/local/tmp`. Pulling the whole p8 back afterwards gave 100,663,296 B digest `03dcdad7af92…` -
    byte-identical to the record image - and every difference against the capture falls inside those two
    spans (12,464,811 bytes in 50,745 runs). The kernel span, second bootloader, dtbo and vendor tail are
    untouched.
  * Misc re-arm: `scripts/arm_card_misc.sh`, corrected to digest `d05786794c87…`, resolved the SD card misc
    by whole-device size and type, wrote exactly 2,048 B and read it back equal - blob and readback digest
    `ceaae1a6314a…`, so the card's stage line no longer carries `--wipe_all`. Bytes 2048..4095 of that
    partition are still identical to the capture.
  * Two Android-side defects in that script, found by running it: `stat` is not a bare Android binary (it is
    only a toybox applet), and Android's normal boot has no `/tmp` (recovery does), so the BCB blob could
    never be created. Both calls now go through the script's `tool()` resolver and the blob is built in the
    first writable of `/tmp` and `/data/local/tmp`. The first run aborted with an empty blob size and wrote
    nothing, which is the safe outcome; `scripts/smoke_card_rearm.sh` still reports failures=0.
  * Nothing else changed: the card's p7 4 KiB head `5f1d9939bb0d…` matches the capture, and the eMMC heads
    are unchanged (p7 `fac15a4b138e…`, p8 `b06dc33648a3…`, misc `0f2ec43e7a5c…`). The card's misc 4 KiB head
    is now `89b2d3ba61b1…`. The second SD card is not present in this boot - only `mmcblk1` (SD
    7,948,206,080 B) and `mmcblk2` (MMC 62,813,896,704 B) exist - so the approved evidence channel needs
    that card put back in before a card boot can copy anything.
  * Pull timing: 100,663,296 B of card p8 in 24 chunks of 4,194,304 B took 32 s before the write and 33 s
    after.

* **STEP 3: the deliberate card boot ran (Nov 23, performed by the owner) and the patched recovery answered.**
  Evidence of record is the workstation pulls in `/run/media/Daan/Opslagmonster/a14-work/card-boot-nov23/`:
  `hu-mark.log` `b4e70ce0f16b…`, `state-recovery-120.txt` `62e590e5c5d8…`, and
  `cmdline-mounts-partitions.txt` `13b3b5c7df77…`.
  * Boot identity: `/proc/cmdline` carried `storagemedia=sd` and `b.mode=recovery` while
    `androidboot.mode=normal` (true of every boot, **D90**); `ro.bootimage.build.fingerprint` ends
    `-HUPATCH`; `/sbin/hu-card-boot.flag`, `hu-card.sh`, `hu-net.sh` and `busybox` are present;
    `sys.boot_completed` is empty; `ps -A` shows `init` plus one `recovery` process (pid 133) and no
    framework services. This is the card's recovery boot from the patched p8.
  * Network: `eth0` appeared with driver `ax88179_178a` - that answers the built-in-versus-module question,
    the driver registers eth0 during a card boot - HWaddr `00:0a:cd:27:a5:b2`, address 192.168.1.127/24,
    alias eth0:1=192.168.77.2, carrier up from t=0 (`net: iface eth0 node present at up=2.19`), address
    unchanged after dhcp (`net: address after dhcp=192.168.1.127`). TCP 5555 and TCP 2323 were open from
    watcher tick 1 through tick 276 (~23 min). The heartbeat logged `window complete (240 ticks)` at
    up=1200.81.
  * Card-boot mode ran as designed: `net: card-boot mode - arming without a nonce; window 30 min`,
    `net begin nonce=card-boot`, snapshots in `/tmp` (`state-recovery-5/30/120.txt`), and
    `early pstore copied files=0` - `/sys/fs/pstore` is empty after a cold power cut (**D90**).
  * The card's misc was NOT cleared by this boot: its first 2048 B still read `ceaae1a6314a…` at up=1210
    and again after ~20 min (`misc-after-boot.bin`). **D90**'s "entering recovery clears the BCB" was
    measured on an eMMC recovery boot. Candidate here: the cleared BCB is written by the menu path rather
    than by recovery startup; the discriminating measurement is a misc read after a menu action versus
    after recovery exits without one.
  * Evidence channel: nothing landed on the second card in this boot. The log reads
    `evidence: /mnt/external_sd is mounted from /dev/block/mmcblk0p1, which is not the second card -
    refusing it as a destination`, then `no second SD card of 30533764 blocks present`. Three measured
    defects, now fixed in the module (`scripts/hu_h_common.sh` `ec3fb6582c9c…`,
    `scripts/hu_card.sh` `b74b147295d0…`):
    - `EVID_CARD_BLOCKS` was 30,533,764; `/proc/partitions` reports mmcblk0 as 30,533,632 blocks, which is
      31,266,439,168 B / 1024. The old value was an arithmetic slip, so no device ever matched it.
    - `is_evidence_card()` read sysfs `device/type` on the mount's node name. A partition node
      (`mmcblk0p1`) has no sysfs directory, so the type came back empty and the approved channel was
      refused; it now resolves the parent device first.
    - Timing: at up=1.5 s `/proc/partitions` had no mmcblk0 at all, so `hu-card.sh` gave up before the
      second card existed. It now waits up to `CARD_WAIT_TICKS` (default 12 x 10 s) before giving up, and
      writes nothing while waiting.
  * The eMMC was untouched during the card boot: p7 head `fac15a4b138e…`, p8 head `b06dc33648a3…`, misc
    head `0f2ec43e7a5c…` all equal their heads of record; `by-name` points only at eMMC nodes; no eMMC node
    is mounted, and the only mounts are `/metadata` (ext4) and `/mnt/external_sd` (vfat) from the stock
    recovery rc. The second card's older copies from Nov 21 are still present and unchanged.
  * Gate additions for the partition-node case: scenario 4d (a partition-node mount of the second card is
    accepted on its parent, no mount issued) and 4e (a partition-node mount of the boot card is refused and
    the second card is mounted instead). `scripts/smoke_card_module.sh` reports failures=0 and the other
    five gates plus pytest stay green.

* **Re-flash with the corrected module (Nov 23, owner GO): the card now carries `b32bff398f3b…`.**
  * Cold copy first, additive: `/srv/50911774-19fb-46b6-bc9e-8cf81623d044/cold/vibe-baking/hu-card-p8-nov23-fixed/`
    under `MIRROR.sha256` `751ad7c46659…`; `sha256sum -c` on the NAS returns rc 0 with 15 of 15 entries OK.
  * Writes on the SD node resolved by size (7,948,206,080 B, type SD): the header page 0..2,047
    `3ac2688c63c7…` and the ramdisk span 25,425,920..37,943,295 (12,517,376 B) `a3cd88ee6d5c…`, both with
    `conv=notrunc`. The whole-partition readback of 100,663,296 B equals the record image, and 12,464,879
    bytes differ from the capture - all of them inside those two spans.
  * Declared ramdisk size 12,515,437 B; only header bytes 16..17 change; everything from 37,943,296 onward is
    byte-identical to the capture, so the kernel, second bootloader, dtbo and vendor tail are untouched.
  * The card's misc stayed armed through this write: its first 2048 B reads `ceaae1a6314a…` before and after.

* **Second card boot: the evidence channel works after the fixes (Nov 23).** The boot again carried
  `storagemedia=sd`, `sys.boot_completed` was empty and one `recovery` process was running. The module's
  bounded wait paid off: at t=1 s `evidence: mounting /dev/block/mmcblk0 failed - copies stay in RAM`, then
  at t=10 s `card begin (card-boot mode, destination /mnt/external_sd)` once the stock recovery had mounted
  the second card's partition, and `state copied to card rc=0` followed. Pulled back from the second card
  into `/run/media/Daan/Opslagmonster/a14-work/card-boot-nov23-second-card/`: `hu-mark.log` `97ec7de41076…`
  (7,961 B), `misc-head.bin` `ceaae1a6314a…` (2,048 B), `state-recovery-5.txt` `45b054512f7b…` (6,458 B),
  `state-recovery-30.txt` `2f2916d592ca…` (6,732 B) and `state-recovery-120.txt` `13a440266799…` (6,373 B). Copies are additive;
  nothing else on that card was touched, and the boot card and eMMC were never written by the module.
  * Two measured differences from the first card boot: this boot's log timestamps start at epoch
    1514808001 (2018-01-01) while the first boot's started at 1795430134, and the 120 s snapshot is 3,810 B
    here versus 6,240 B there. Candidate for the clock difference: the RTC is only populated in some boots;
    the discriminating measurement is comparing each log's epoch base against `/proc/uptime` at the same
    ticks. The smaller snapshot is content-dependent, and `/sys/fs/pstore` was empty again.
  * The card's misc stayed armed after this boot too: its first 2048 B still reads `ceaae1a6314a…`.

* **Measurement report for the second card boot (Nov 23, read-only only).** Pulls sit in
  `/run/media/Daan/Opslagmonster/a14-work/card-boot-nov23-boot2/` with its own `MANIFEST.sha256`:
  cmdline/mounts/partitions/uptime text `cac793911cfa…`, RAM `hu-mark.log` `3e3bb2f2e413…` (12,018 B),
  `pstore-tmp-eth0.txt` `a21a6afb22b1…`, the card misc 4 KiB head `a91c9b257401…`, the whole card p8
  `b32bff398f3b…`, the card p7 4 KiB head `5f1d9939bb0d…`, and the eMMC heads `fac15a4b138e…`,
  `b06dc33648a3…` and `0f2ec43e7a5c…`.
  * The card's p8 pulled after the boot equals the record image `b32bff398f3b…` (100,663,296 B, 33 s pull):
    the recovery boot did not modify its own partition.
  * Card misc: first 2048 B still the armed blob `ceaae1a6314a…`, and bytes 2048..4095 are byte-identical to
    the capture, so nothing outside the 2048 B BCB region changed in either boot.
  * The two card-copy digests were re-measured per file after the first pull mislabelled them: the 5 s
    snapshot is `45b054512f7b…` and the 120 s snapshot is `13a440266799…`, the opposite of the earlier entry.
  * The three state snapshots on the second card equal their RAM counterparts byte-for-byte
    (`45b054512f7b…`, `2f2916d592ca…`, `13a440266799…`). The log copy `97ec7de41076…` is the 7,961 B snapshot
    taken at copy time while the RAM log had grown to 12,018 B by the pull, so the card holds the log up to
    the copy, not the whole boot.
  * eth0 stayed at 192.168.1.127/24 with RX 3499 packets and 0 errors or dropped; TCP 5555 and TCP 2323 were
    open from watcher tick 3 (~24 s after the boot) onward. `/sys/fs/pstore` was empty again.
  * Clock difference measured: this boot's log starts at epoch 1514808001 and its own tick deltas match
    `/proc/uptime`, while the first boot's log started at 1795430134. Candidate: the RTC is populated in
    some boots only; the discriminating measurement is the log's epoch base against `/proc/uptime` at the
    same ticks, which holds in both boots.

## Nov 23 (afternoon) - the SD-boot card becomes the Android 14 test bed

Everything here is read-only measurement unless a write is named, and every write went to the card.
The eMMC's heads were printed before and after each write and never changed: p3 `0f2ec43e7a5c…`,
p7 `fac15a4b138e…`, p8 `b06dc33648a3…`.

* **The card has the eMMC's partition layout.** From `/proc/partitions` in the card recovery boot:
  `mmcblk1` 7,761,920 blocks with p1..p15, where p3 is 4,096 blocks, p5 4,096, p7 32,768, p8 98,304,
  p12 16,384, p14 3,186,688 and p15 3,885,551. The card's p14 is a real liblp container: geometry magic
  `0x616c4467` at byte 4096, `metadata_max_size` 65,536, 2 slots, logical block size 4,096, four metadata
  copies at 12,288 / 77,824 / 143,360 / 208,896, one block device `super` of 3,263,168,512 B with alignment
  1,048,576 and `first_logical_sector` 2,048.
* **Why `by-name` resolves to the eMMC even from a card boot.** The card's dtbo (p5) is a `dt_table`
  (magic `0xd7b7ab1e`) with a single 739-byte FDT at offset 64, whose `__overlay__` property `bootargs_ext`
  holds the 40-byte string `androidboot.boot_devices=fe330000.sdhci`, starting at byte 188 with the device
  name at byte 213. The live card-boot cmdline ends in exactly that token. Controllers measured from sysfs:
  `mmcblk0` -> `fe310000.dwmmc`, `mmcblk1` -> `fe320000.dwmmc`, `mmcblk2` -> `fe330000.sdhci`.
* **The card's first-stage fstab is the stock one** (`fstab.rk30board`, 1,932 B, `7b8581f69b88…` inside the
  card's p7 ramdisk): `system`, `vendor`, `odm` and `product` are `logical,first_stage_mount`, and
  `metadata`, `misc`, `cache` and `userdata` come from `/dev/block/by-name/...`. So which device the card boot
  uses is decided entirely by the boot-devices token, not by the fstab.
* **On-device whole-partition hashing works in recovery, and it is fast.** `toybox sha256sum` on
  `/dev/block/mmcblk1p7` returned `1b47dbc48aee…` - the registered card p7 carve digest - in 2.5 s, and
  sequential reads run at 14 MB/s. The older "a whole-partition hash never returns" note was an Android 10
  observation, not a property of the recovery environment. Card writes measured 2.8-4.5 MB/s.
* **Baseline before any write**, from `scripts/flash_card_a14.sh verify`: card p3 `c637af0b71c6…`,
  p5 `adc64fd980bd…`, p7 `1b47dbc48aee…`, p8 `b32bff398f3b…` (our patched recovery, unchanged),
  p14 `0b925b8c7df5…`. Every one equals the digest carved offline from the whole-card capture, so the capture
  and the live card agree.
* **The Android 14 kit, built offline** in `a14-work/card-a14/` with its own manifest: `card-p5-a14.bin`
  4,194,304 B `1de2005b2406…` (the dtbo with 14 bytes changed to `fe320000.dwmmc`; only 6 bytes actually
  differ, the FDT total size stays 739 and the property re-reads correctly), `card-p7-a14.img` 33,554,432 B
  `e504655bd32c…` (the identity-gated shape A boot image, unmodified), and the super below. Rollbacks in the
  same directory: `card-p5-stock.bin` `adc64fd980bd…`, `card-p7-stock.img` `1b47dbc48aee…`,
  `card-p14-stock.img` `0b925b8c7df5…`, `card-p3-stock.bin` `fa8258a8fcf8…`.
* **The Android 14 payload ramdisk, measured.** 18 entries, 3,651,840 B uncompressed:
  `first_stage_ramdisk/fstab.rk30board` 4,190 B, `init` 3,644,288 B, `system/etc/ramdisk/build.prop` 860 B
  and the device nodes. Its header cmdline is 333 B and already carries `androidboot.veritymode=disabled`
  and `androidboot.selinux=permissive`.
* **Write 1 - the super, and the corruption it exposed (**D102**).** The shape A super `d81f913aee91…` was
  staged on the second card and written to card p14; `dd` reported all 3,263,168,512 B copied and the whole
  partition read back `5b26b47c1654…` - three 1 MiB blocks (1479, 2169, 2238) differing by exactly one byte
  each, each a single cleared bit. Mapped through liblp and ext4 they sat in `/vendor/lib64/librkisp.so`,
  `/priv-app/SystemUI/oat/arm64/SystemUI.odex` and `/priv-app/TrebuchetQuickStep/TrebuchetQuickStep.apk`.
  The image with exactly those three bits cleared hashes to `5b26b47c1654…`, so the destination held our
  data to the byte except three bits.
* **The source was the problem, not the destination.** The staged file on the second card hashes differently
  on different reads once the page cache is dropped - `cfe08e1d3abd…`, then `e3f9ecea45de…`, with 12 of 32
  chunks wrong. Staging each of the three MiB blocks in the unit's RAM instead, verifying it there and
  writing it to card p14 from RAM, made all three read back correct, and the whole partition then hashes
  `d81f913aee91…`, byte-exact to the registered super. So the boot card is healthy, the second card is not a
  reliable data path, and every readback that is meant to prove what a medium holds needs
  `drop_caches` first (**D104**).
* **Writes 2, 3 and 4, all staged in RAM and verified by whole-partition readback.** Card p7 =
  `fa8e4463573f…` (the shape A boot image plus the diagnostic cmdline; 95 bytes changed inside the header
  cmdline field at 397..491, kernel, ramdisk, `second` and tail byte-identical to `e504655bd32c…`), card p5 =
  `1de2005b2406…` (`bootargs_ext` now `androidboot.boot_devices=fe320000.dwmmc`), and the card's BCB cleared
  to 2048 zero bytes `e5a00aa9991a…`, leaving the misc 4 KiB head `262bab4c55da…`. The pre-write digests were
  the expected ones every time (`1b47dbc48aee…`, `adc64fd980bd…`, `ceaae1a6314a…`), and the eMMC's p3/p7/p8
  heads were printed before and after each of the four writes and never changed.
* **The diagnostic cmdline.** `ignore_loglevel printk.devkmsg=on panic=0 panic_on_oops=1
  softlockup_panic=1 hung_task_panic=1`, appended to the image's own 333 B header cmdline for a total of
  428 B inside the 512 B field. `printk.devkmsg=on` is the token **D72** measured taking init's console
  lines from 65 to 819; the three panic tokens convert a silent hang into a panic with a stack trace, and
  `panic=0` keeps the unit from looping while no auto-recovery path exists yet.
* **Two defects fixed in the write path before it was used again**, both found by review rather than by the
  unit: `bcb-clear` wrote the 2048 B Boot Control Block with no pre-write digest gate (it now refuses unless
  the BCB is our armed blob `ceaae1a6314a…` or already all zeros `e5a00aa9991a…`), and an unreadable
  partition left the pre-write digest empty, which would have matched a blank line in a `.before` file (the
  digest must now be 64 characters).

## Nov 23 (late afternoon) - Android 14 attempts 1 to 3 on the card

* **Attempt 1** - card p7 `fa8e4463573f…` (shape A boot image plus the diagnostic cmdline), card p14
  `d81f913aee91…`, card p5 `1de2005b2406…`, BCB cleared. Started with the reset button. The owner reports a
  black screen with the buttons illuminated; the network never answered (watcher saw the reset at 14:54:43
  and nothing for the rest of the window). Afterwards, read from the Android 10 boot: `/sys/fs/pstore`
  **empty** (**D105**), card p12 `5eac140209ed…` byte-identical to the capture, card p5 and p7 exactly as
  written. So the attempt produced no log and touched nothing.
* **Attempt 2** - the same payload with the PID-1 wrapper injected (`d60b6ea965a7…`, cmdline `panic=10`).
  Started with `adb reboot` from Android 10, which the owner confirmed boots the card. Black screen again,
  and nothing on the network for about three minutes, so no panic fired. **But the card's BCB read
  `ceaae1a6314a…` afterwards - armed.** Nothing else writes that blob, so u-boot booted card p7, the stock
  kernel ran, the initramfs ran with the wrapper as PID 1, the wrapper resolved the card's misc by block
  count, wrote and verified the 2048 B BCB, and execed Android 14's own `init`. The whole chain up to
  Android 14's userspace works, and the failure is inside it, without a panic.
* **The wrapper, gated offline.** `scripts/smoke_hu_card_arm.sh` runs ten scenarios under qemu-aarch64 with a
  fake `/proc/partitions` and a loopback misc: the happy path resolves `mmcblk1` and `mmcblk1p3` by block
  count and writes the registered BCB `ceaae1a6314a…` with nothing past byte 2048, two devices of the card's
  size are refused rather than guessed, a misc of the wrong block count is refused, a non-`init` argv[0] is
  passthrough with the misc untouched, an unopenable misc fails open, the watchdog fires in software after
  its delay, it stands down if the BCB is cleared inside the window, and it never starts when nothing was
  armed. `summary: failures=0`.
* **Attempt 3** - `aaa4fe5fc21d…`, the same image plus the watchdog, written to card p7 and verified by
  whole-partition readback, with the BCB cleared again and the reboot issued over adb. The wrapper binary is
  `adc4b2b764b4…`, built `zig cc -target aarch64-linux-musl -static -Os` with `SOURCE_DATE_EPOCH=1760000000`.
* **Attempt 3 ended without a report.** The boot stayed black for about nine minutes with no panic, the 150 s
  watchdog reboot never happened, and the owner's hard reset at 15:24 came back as Android 10 from the eMMC at
  15:25:27 with `/sys/fs/pstore` empty (**D105**) and the card's BCB armed again - the wrapper ran and armed on
  attempt 3 too. `/dev/watchdog` does not exist on this kernel, so a hardware watchdog was never an option.
  Why the child never rebooted the unit is not measured; the next attempt does not depend on the reboot
  syscall working, and does not depend on which media boots next (**D106**).
* **Attempt 4 built offline, gated, not yet written.** The wrapper is `1013b19082e3…` (13,840 B, static
  aarch64, `SOURCE_DATE_EPOCH=1760000000`) and the card p7 image is `6ba537be0f70…` (33,554,432 B. The child
  waits 60 s, then dumps every task's backtrace with sysrq `t`, copies the pstore records into the card's
  unpartitioned head (**D107**), and crashes the boot with sysrq `c` so `panic=10` reboots in software; it
  stands down if the BCB was cleared or if the mount table already shows `/data`, so a working Android 14
  boot is never killed. If sysrq is unavailable or refused it falls back to the reboot syscall with the
  kernel's real magics, and test mode never calls reboot or sync at all - the gate runs on the workstation.
  Every fd the wrapper opens is O_CLOEXEC, so Android's init inherits no writable fd to the raw card.
  `scripts/smoke_hu_card_arm.sh` now runs sixteen scenarios, `summary: failures=0`: the sink bounds (nothing
  before the log region, nothing between it and p1, a record larger than the region capped), a p1 start read
  from sysfs that overlaps the region disables the sink, and init.real seeing no wrapper fd after execve.
* **Attempt 4 - the reporting child never wrote anything.** Card p7 `6ba537be0f70…` written and verified by
  whole-partition readback, BCB cleared, the 1 MiB log region at 2,097,152 B confirmed all-zero, eMMC heads
  unchanged; `adb reboot` at 18:52:41. Black screen, nothing on the network, no automatic reboot; the owner
  reset the unit and Android 10 came up from the eMMC at about 19:00:06. Afterwards the card BCB read
  `ceaae1a6314a…` (armed - the wrapper ran and handed off, as on attempts 2 and 3), `/sys/fs/pstore` was empty,
  and the log region was still all zero after `drop_caches` - so the child did not even reach the header it
  writes first after its 60 s sleep. Three attempts in a row, a forked child that sleeps and then acts has
  never acted. Not measured: whether the whole system froze (arm64 has no hard-lockup detector here, which
  would fit "no panic ever"), timers stopped, or the child was killed.
* **Attempt 5 built offline, gated, not yet written: a flight recorder.** The child now writes at once and
  then every second: it drains `/dev/kmsg` (from the oldest record in the ring, so the boot from time zero
  plus every line Android's init writes there) into the card's unpartitioned head, rewrites a 64-byte
  heartbeat `HULOG2 tick= up_ms= bytes= state=`, and fsyncs the card. The region grows to 5 MiB,
  2,097,152..7,340,032, measured all-zero on the unit in 1 MiB steps with p1 still at sector 16384. After 90 s
  with the BCB armed and no `/data` mount it dumps task backtraces with sysrq `t`, records three more
  seconds, and crashes with sysrq `c`. After any reset the last heartbeat separates a whole-system freeze
  (heartbeat stops with the log) from a userspace hang (heartbeat runs to the deadline). Wrapper
  `fe92d58d24bd…` (13,752 B), card p7 image `4d1e839d96bf…`. `scripts/smoke_hu_card_arm.sh` runs seventeen
  scenarios, 57 checks, `summary: failures=0`, including a heartbeat and the log from time zero on the card
  within 3 s, and a 6.2 MB log capped at the region end.
* **Attempt 5 - the recorder wrote once, then card I/O (or the whole system) stopped.** Card p7
  `4d1e839d96bf…` written and verified, BCB cleared, the 5 MiB region confirmed zero; `adb reboot` at 19:11:53,
  black screen, owner reset, Android 10 back at about 19:16:15. The card held the heartbeat
  `HULOG2 tick=0 up_ms=1009 bytes=67346 state=start` and 67,346 B of kmsg ending with the wrapper's own
  `execing init.real` at 1.004794 s. There was never a tick 1: about one second after Android 14's init was
  executed, the child could no longer put a heartbeat on the card, and no panic fired despite `hung_task`,
  softlockup and oops panics. Every earlier child's first action after its sleep also needed card I/O
  (attempt 3's reboot shuts the MMC devices down; attempt 4's fsync), so the three silent attempts are one
  observation: within about a second of Android 14's first stage starting, the system freezes or card I/O
  hangs. Separately, attempt 4's pstore copy asked for filesystem type `pstorefs`, which does not exist (the
  kernel's name is `pstore`), so that copy could never have worked.
* **Step 0 control built, gated, not yet written.** The same wrapper built with `-DHU_CONTROL`: it arms the
  BCB, copies the previous boot's pstore to 6..7 MiB of the card, runs the recorder for 120 one-second ticks
  in 2..6 MiB, and never executes Android 14's init - PID 1 just sleeps. If the heartbeat still stops about a
  second in, the hang is in the kernel, the card or the wrapper and Android 14 is innocent; if it reaches tick
  120, Android 14's first stage is what kills card I/O, and the next step is a staged first-stage init that
  repeats its steps one at a time, starting with the `super`/dm-linear setup over the card. The crasher (sysrq
  `t`, `w`, `l`, `c` with no block I/O) stays in the source and is compiled out of the control. Control
  wrapper `ad501c668c00…` (14,680 B), card p7 image `b5ad5d58a56f…`; normal wrapper `9a9a97c0de27…`
  (16,176 B). `scripts/smoke_hu_card_arm.sh` runs nineteen scenarios, 69 checks, `summary: failures=0`.
* **Attempt 6 - the step-0 control: without Android 14's init, nothing hangs.** Card p7 `b5ad5d58a56f…`
  written and verified, BCB cleared, `adb reboot` at 19:24:44; the owner reset with the card left in and the
  unit came up in the card's recovery (D106 corrected). The card held `HULOG2 tick=120 up_ms=122108
  bytes=67989 state=done`: the recorder ran every one of its 120 ticks, and the kmsg on the card runs from
  time zero through the wrapper's `CONTROL build - not executing init.real, idling` to ordinary driver lines
  at 62 s. So the kernel, the card, the dwmmc path and the wrapper are healthy for two minutes, and attempt 5's
  heartbeat stopping one second after `execing init.real` is caused by Android 14's first-stage init.
  The previous-boot copy also worked: 6..7 MiB held `HUPREV1 bytes=333545 records=2`, Android 10's shutdown
  console from the warm `adb reboot` - the mount type `pstore` is right.
* **The stop is system-wide, not just card I/O.** The kernel in the Android 14 boot image is `4.19.111+`
  (built Jul 5 2024) with an embedded config: `CONFIG_DEFAULT_HUNG_TASK_TIMEOUT=10`, `CONFIG_DETECT_HUNG_TASK=y`,
  `CONFIG_SOFTLOCKUP_DETECTOR=y`, and our cmdline sets `hung_task_panic=1 softlockup_panic=1`. Had only card
  I/O wedged, attempt 5's recorder would have sat in `fsync` in D state and the kernel would have panicked
  within 10-20 s; the owner waited about four minutes and nothing fired. So the hung-task detector itself did
  not run: the scheduler, timers or interrupts stopped, within about a second of Android 14's first stage
  starting. The ramdisk carries no kernel modules; the first-stage fstab mounts five logical partitions and
  `/metadata`. A read-only analysis by the local model (a14-work/qwen-suspects/REPORT.md, checked against the
  files) ranked an init blocked on a uevent first; that cannot stop a separate process from writing, so it does
  not explain the measurement.
* **Attempt 7 built, gated, not yet written: unmodified Android 14 with a 100 ms recorder.** The recorder now
  ticks ten times a second, so every kmsg line Android 14's first stage prints more than about 100 ms before the
  stop reaches the card, and the last one names the step. The no-I/O crasher is enabled again for this run: if
  the system is not fully frozen it panics at 45 s and the console survives into the card recovery. Wrapper
  `62d3e0f0f377…` (16,208 B), card p7 image `f6bea79586b8…`; gate nineteen scenarios, 69 checks,
  `summary: failures=0`.
* **Attempt 7 - root cause found: Android 14's first stage never froze the system; it failed in 70 ms and
  rebooted into a target that does not come back.** Card p7 `f6bea79586b8…`, 100 ms recorder. The card log
  shows, after the wrapper's `execing init.real` at 1.049 s: `init: init first stage started!` (1.085 s),
  `Unable to open /lib/modules, skipping module loading`, `ReadFstabFromDt(): failed to read fstab from dt`,
  `Failed to read vbmeta partitions`, `realpath failed: /dev/block/by-name/super: No such file or directory`
  (1.117 s), `Failed to create devices required for first stage mount`, `InitFatalReboot: signal 6`,
  `Reboot ending, jumping to kernel`, `reboot: --mtc restart` (1.133 s). `InitFatalReboot` restarts into the
  bootloader target by default, which on this unit is a silent loader mode: black screen, no network, no
  panic, no detector, and a cold reset afterwards. That one fact explains attempts 1-5, and corrects the
  "system-wide stop" reading above: the kernel shut down cleanly on init's request.
* **Why `/dev/block/by-name/super` was never made (MEASURED + AOSP android14-release source).** The cmdline
  carried `androidboot.boot_devices=fe320000.dwmmc`; the card and all fifteen partitions were enumerated by
  0.735 s; `mmcblk1p14` has `PARTNAME=super`; its sysfs path resolves to the platform device
  `fe320000.dwmmc`, which is what `DeviceHandler::FindPlatformDevice` expects. But
  `BlockDevInitializer::HandleUevent` (init/block_dev_initializer.cpp) matches the wanted devices by partition
  name alone and stops at the first match - and the eMMC's `mmcblk2p14` is also named `super`, because the
  card is a clone of the eMMC layout. The eMMC is not a boot device, so handling its uevent makes only
  `/dev/block/platform/fe330000.sdhci/by-name/super`; `super` is then struck off the wanted list and the
  card's partition is never handled. The same collision applies to `metadata`, the other first-stage name.
  `androidboot.partition_map` does not help: it only links partitions that have no GPT name.
* **The fix, not yet built.** Give the card's two first-stage partitions unique GPT names (p14 and p12), pass
  `androidboot.super_partition=<new name>` on the boot image's cmdline (fs_mgr.cpp
  `fs_mgr_get_super_partition_name` honours it when there is no slot suffix), and point the ramdisk fstab's
  `/metadata` line at the new name. liblp's `GetPhysicalPartitionDevicePath` maps the metadata's super block
  device to the super path init resolved, not to the literal name `super`, so the super image itself does not
  change. Second stage is unaffected: ueventd only makes `/dev/block/by-name/*` for boot devices.
* **Attempt 8 built and checked, not yet written: unique card names for the two first-stage partitions.**
  - Card GPT: p12 `metadata` -> `sd_metadata`, p14 `super` -> `sd_super`, by `tools/gpt_rename.py` from the
    card's own sectors read back in recovery (head 0..33 `cb48df2139ae…`, tail 15523807..15523839
    `75596805bbe7…`, both byte-identical to the Nov 23 capture). New blobs: head `5d61edbb916a…`, tail
    `12f048d4272b…`. Only the two name fields (in both arrays) and the four CRC fields change; every range, the
    other thirteen names and the protective MBR are identical; both headers' CRCs verify; `sgdisk -v` on a
    sparse image of the card reports "No problems found" (its caution about p15's alignment is pre-existing).
    `scripts/write_card_gpt.sh` writes the two spans on the device: card found by its exact 15,523,840-sector
    size, refuses unless the card holds the recorded before-digests, reads both spans back after a cache drop,
    hashes the eMMC head before and after and never writes it. Built by the local model, reviewed and checked
    independently; pytest now 32 tests, including thirteen for the rename. Rollback: write back the captured
    original head and tail.
  - Card p7 `1f4713f9f092…`: unmodified Android 14 with `androidboot.super_partition=sd_super` on the cmdline
    and the ramdisk's first-stage fstab pointing `/metadata` at `by-name/sd_metadata` (one line,
    `ca631046608a…`, put in by the injector's new `--replace` option, which keeps the entry's mode and inode).
    Wrapper `c378cf7c7a36…`: the 100 ms recorder now runs 180 s and the crasher fires at 90 s, so a slow first
    boot that is progressing is not cut short.
  - Not changed and noted for later: the vendor image's own `/vendor/etc/fstab.rk30board` still names
    `by-name/metadata`; second stage's `mount_all` skips `/metadata` because first stage already mounted it.
* **Attempt 8 - Android 14 runs: first stage passes, second stage reaches `/data` and the boot animation, then
  `bpfloader` fails and init reboots.** GPT rename, card p7 `1f4713f9f092…` and BCB clear written and verified
  in the card recovery (`write_card_gpt.sh` read both spans back, the kernel re-read the table and reported
  p12 `sd_metadata`, p14 `sd_super`; eMMC heads unchanged). Card log: first-stage mount succeeds, second stage
  runs `mount_all --early`, `fs_mgr_do_format` formats the card's userdata as f2fs (`make_f2fs` 1.16.0, 3794 MB)
  and `/data` mounts at 36.4 s; the recorder and the crasher both stand down on `/data`. The boot then ended in
  a software reboot, so pstore survived into the card recovery for the first time: `console-ramoops-0`
  (338,545 B) and `pmsg-ramoops-0` (262,132 B). The console shows `bootanim` running for 84 s and `apexd` for
  77 s, then at 121.19 s `NetBpfLoad` (Tethering APEX 350090000, `kver:413006f`) writing `0` to
  `/proc/sys/kernel/unprivileged_bpf_disabled` -> EINVAL (not fatal) and failing to open
  `/proc/sys/net/core/bpf_jit_enable` (No such file or directory) -> exit 1; the `bpfloader` service carries
  `reboot_on_failure`, so init rebooted with `reboot,bpfloader-failed` at 123.95 s.
* **Why: the kernel has eBPF but no JIT.** The embedded config has `CONFIG_BPF_SYSCALL=y`, `CONFIG_CGROUP_BPF=y`,
  `CONFIG_NETFILTER_XT_MATCH_BPF=y`, `CONFIG_NET_CLS_BPF=y`, but `# CONFIG_BPF_JIT is not set`, so the sysctl
  `net.core.bpf_jit_enable` does not exist. Programs can still run in the interpreter. Removing
  `reboot_on_failure` alone is not enough: `/system/etc/init/netbpfload.rc` itself records that a bpfloader
  failure leads to a netd crashloop and a system_server crashloop. The system image is plain ext4 (no
  `shared_blocks`), 247,283 blocks, 750 free, so it can be edited in place.
* **Attempt 8's other blockers: one broken vendor manifest behind three abort loops.** From 38 s until the
  reboot, `vendor.keymint-default`, `keystore2` and `surfaceflinger` aborted every 4-5 s (signal 6). The
  userspace log (`pmsg-ramoops-0`) shows the cause 95 times: `getDeviceHalManifest: VINTF parse error: Cannot
  add manifest fragment /vendor/etc/vintf/manifest/android.hardware.health@2.1.xml: HAL
  "android.hardware.health" has a conflict: @2.0::IHealth/default (from /vendor/etc/vintf/manifest.xml) vs.
  @2.1::IHealth/default`. With no device manifest, KeyMint cannot register (`Check failed: status ==
  STATUS_OK (status=-3)`), keystore2 cannot reach a TEE KeyMint (`HARDWARE_TYPE_UNAVAILABLE`) and
  surfaceflinger aborts with `failed to get hwcomposer service`. The vendor's `manifest.xml` is the stock
  Android 10 one (target-level 4): it declares `health@2.0` although the image ships
  `android.hardware.health@2.1-service`, and `keymaster@3.0` although there is no keymaster binary (the AIDL
  KeyMint service replaces it). All other fragments are AIDL or HIDL `cas@1.2` and do not collide.
* **Attempt 9 plan (being built offline).** Two edits inside super, both at their existing extents: vendor's
  `manifest.xml` loses the `health@2.0` and `keymaster@3.0` blocks; system gains `tools/hu_netbpfload.c`
  (7,280 B static, `7dac0ee0245a…`) as `/system/bin/hu-netbpfload`, and `netbpfload.rc` starts it instead of
  netbpfload. The wrapper unshares its mount namespace, makes its mounts private, mounts a tmpfs over
  `/proc/sys/net/core` holding `bpf_jit_enable` and `bpf_jit_kallsyms`, and execs the real netbpfload, so
  programs load into the kernel's interpreter and are pinned in the shared bpffs; every other process keeps
  the real `net.core`. Fail-open: any failed step still execs netbpfload unchanged.
* **Nov 24 00:0x - the workstation's data drive has NTFS corruption; the working copy moved off it.**
  `/dev/sda2` (NTFS, mounted `errors=continue`, holding the old repo checkout and every a14-work artifact)
  logs `ntfs_lookup(): Found stale reference to inode ... returning -EIO. Run chkdsk.` for several directory
  indexes since 23:32; there are no block-level I/O errors, so it is filesystem metadata damage. Git then
  failed with `unable to open .git/objects/62: Invoer-/uitvoerfout` (the blob itself, `6269af8b…`
  `scripts/deploy_device.sh`, hashes correctly from the working file). Nothing more is written to that drive:
  the repo was cloned fresh from GitHub to `/home/Daan/vbf-work/VibeBakingFirmware` (ext4, `git fsck` clean),
  and the live artifacts were copied to `/home/Daan/vbf-work/a14-work/`, each verified against its registered
  digest (all twelve matched). Repairing the NTFS volume is the owner's decision; nothing was attempted.
* **Attempt 9 written: super with the two fixes, plus an unattended crasher.** Card p14 was confirmed to hold
  the old super (`d81f913aee91…`, whole-partition read), then only the eight 4 MiB chunks that differ were
  written (`write_card_chunked.sh` with `CHUNK_MIB=4 ONLY_CHUNKS="0 32 74 81 224 241 259 337"`), each verified,
  and the whole partition then read back as the new super `afa3ca57d691…`. Card p7 `cc5133f59072…` is
  attempt 8's image with one change: the wrapper is built `-DHU_CRASH_ALWAYS -DHU_CRASH_SECS=300`
  (`44d02b1307e7…`), so with nobody to press reset every boot ends at 300 s in a warm reboot (sysrq `t`, `w`,
  `l`, then `c`) and its console and Android log survive in pstore into the card recovery. The default build is
  unchanged (`c378cf7c7a36…`); gate 69 checks, `failures=0`.
* **Attempt 9 - the VINTF fix works; the netbpfload wrapper never ran.** `VINTF parse error` appears 0 times
  (95 on attempt 8), and with the keymint/keystore2/surfaceflinger abort loops gone the boot reaches
  `bpfloader` at 45 s instead of 121 s; `/data` mounts at 33.6 s. NetBpfLoad then failed exactly as before
  and init rebooted with `bpfloader-failed` at 47.0 s; pstore carried `console-ramoops-0` (191,688 B) and
  `pmsg-ramoops-0` (62,745 B) into the card recovery. No `hu-netbpfload:` line was logged: the Tethering
  APEX ships `/etc/netbpfload.33rc` with `service bpfloader /apex/com.android.tethering/bin/netbpfload` and
  `override`, which replaces the /system rc's `bpfloader` definition, so the edited service line was never
  used. The only trigger is the /system rc's `on load_bpf_programs: exec_start bpfloader`.
* **Attempt 10 written: the wrapper under its own service name.** The /system rc now reads
  `exec_start hu_bpfloader` and `service hu_bpfloader /system/bin/hu-netbpfload` (two lines; every option of
  the service, including `reboot_on_failure reboot,bpfloader-failed`, unchanged), so the APEX's override has
  nothing to replace. The wrapper (`7ebfda3348e9…`, 7,480 B) now execs the APEX binary,
  `/apex/com.android.tethering/bin/netbpfload`, falling back to `/system/bin/netbpfload` only if it is missing.
  Both files keep mode, owner and `security.selinux`; e2fsck clean. Super `b3f350783336…`: five 4 MiB chunks
  differ from attempt 9's, written with `ONLY_CHUNKS`, whole p14 read back equal.
* **Attempt 10 - bpfloader passes; the framework runs and RescueParty reboots it at 200 s.** The boot got past
  `bpfloader` (no `bpfloader-failed`) and ended with `reboot,RescueParty` at 199.8 s after RescueParty chose
  `WARM_REBOOT`; pstore held a full 524,276 B console ring (from 125 s on) and 262,132 B of userspace log. In
  the surviving console the whole display/framework group was restarted 15 times together (`zygote`,
  `zygote_secondary`, `surfaceflinger`, `netd`, `audioserver`, `cameraserver`, `media`, `wificond`, each
  signal 9), triggered each time by `vendor.hwcomposer-2-1` dying with signal 11; `vendor.audio-hal` (abort:
  `Could not register Audio Core API`) and `vendor.rockit-hal-1-0` (abort: seccomp policy
  `/vendor/etc/seccomp_policy/rockit.vendor.base-arm.policy` missing) also crash every cycle. Tombstones were read
  from the card's `/data/tombstones` (userdata mounted read-only with `norecovery` in the card recovery).
* **The composer crash is an ABI mismatch in the HWC1 device struct (MEASURED).** tombstone_00: composer@2.1-service,
  SIGSEGV at pc 0 from `HWC2On1Adapter::populateCapabilities()+64`, called from `HwcLoader::openDeviceWithAdapter`.
  The Rockchip module `hwcomposer.rk30board.so` (`329a6d722870…`, identical to the daisaita_a10 stock tree) is an
  HWC1 device; stock Android 10 also drove it through `libhwc2on1adapter.so`, but its adapter (`8601c434465f…`)
  was built in Rockchip's tree. `populateCapabilities` is source-identical in android10-release and
  android14-release, yet the stock adapter loads `query` from `[device, #0xb8]` and ours (`c32e3e68bb5b…`, built
  from AOSP) from `[device, #0x98]`: Rockchip's `hwc_composer_device_1` carries 32 extra bytes before `query`, so
  ours calls a NULL slot. Rockchip also changed other HWC1 structs historically, so patching offsets is not safe.
* **Attempt 11 written: the stock Android 10 composer pair, built against Rockchip's header.** vendor gets the stock
  `android.hardware.graphics.composer@2.1-service` (`11870e3b9af6…`, 11,664 B) and `libhwc2on1adapter.so`
  (`8601c434465f…`, 159,976 B) in place of ours, with the original mode, owner and `security.selinux`
  (`hal_graphics_composer_default_exec`, `vendor_file`). All their C++ imports resolve against the Android 14
  vendor libraries (composer@2.1, libbinder, libhidlbase, libhidltransport, libutils, libcutils, libhardware,
  libc++, liblog, libsync); the rest are bionic names. A stock adapter with our Android 14 service would not
  work: the two sources differ in members, so `make_unique` would allocate the wrong class size. Super
  `9dbfc7b5c757…`, five 4 MiB chunks written, whole p14 read back equal.
* **Attempt 11 - the composer runs; the boot animation plays; surfaceflinger aborts in its shader warm-up.**
  With the stock composer pair `vendor.hwcomposer-2-1` no longer crashes and `/product/media/bootanimation.zip
  is loaded successfully` appears five times. No RescueParty this time: the boot ran to the unattended crasher
  at 300 s (sysrq dump then panic; pstore added `dmesg-ramoops-0`, 327,561 B). The display group was still
  restarted 9 times, now triggered by `surfaceflinger` itself (signal 6). tombstone_29 (read from the card's
  `/data/tombstones`): `Abort message: 'Failed to create a valid texture. [128,128] isProtected:0 isWriteable:0
  format:22'` from `AutoBackendTexture::AutoBackendTexture` <- `SkiaRenderEngine::mapExternalTextureBuffer` <-
  `skia::Cache::primeShaderCache` <- `SkiaRenderEngine::primeCache`. Format 22 is RGBA_FP16: the startup shader
  warm-up draws an FP16 buffer the Mali-T860 r18p0 driver cannot import. `vendor.audio-hal` (9x) and
  `vendor.rockit-hal-1-0` (8x) keep aborting as on attempt 10.
* **Attempt 12 written: `service.sf.prime_shader_cache=0`.** The property is read by this build's surfaceflinger
  (present in its strings). Added to `/vendor/build.prop` above `# end of file`, mode 0600, owner and
  `security.selinux` kept; e2fsck clean. Super `f15cf47dbc81…`, two 4 MiB chunks written, whole p14 equal.
* **Attempt 12 - surfaceflinger survives; system_server starts its services and aborts in ClatCoordinator on
  bpffs labels.** `Failed to create a valid texture` appears 0 times and surfaceflinger is gone from the restart
  list; the boot ran to the 300 s crasher. system_server reached `Starting phase 200` and its
  `NetworkStatsServiceInitializer`; tombstone_08 (`system_server_native_crash`): abort in
  `register_com_android_server_connectivity_ClatCoordinator` <- `JNI_OnLoad` of
  `/apex/com.android.tethering/lib64/libservice-connectivity.so`. The log before it: `context of
  '/sys/fs/bpf/net_shared/prog_clatd_schedcls_egress4_clat_rawip' is 'u:object_r:fs_bpf:s0' !=
  'u:object_r:fs_bpf_net_shared:s0'` (six such lines, all under `net_shared`). So the netbpfload wrapper worked:
  the clatd programs and maps are pinned. But Android 14 labels bpffs subdirectories by path (platform policy
  `genfscon bpf "/net_shared" fs_bpf_net_shared` and seven more), and this kernel gives every bpffs object the
  root's `fs_bpf` (inferred: no path-based genfs labelling for bpffs in this vendor 4.19).
* **Attempt 13 written: one labelled bpffs mount per policy subdirectory.** Before anything else,
  `hu-netbpfload` (`08ea8311e660…`, 28,048 B) mounts a bpffs instance in the shared namespace on each of the
  eight policy paths (`loader`, `net_private`, `net_shared`, `netd_readonly`, `netd_shared`, `tethering`,
  `uprobestats`, `vendor`) with `context=u:object_r:<label>:s0`, so every object pinned there carries the
  policy's label; then the private JIT knobs and the exec as before. Super `ff51ee63d69e…`, three chunks.
* **Attempt 13 - per-directory bpffs mounts break the loader; and `/metadata` never mounted.** All eight
  labelled mounts succeeded (`hu-netbpfload: bpffs /sys/fs/bpf/net_shared mounted with
  context=u:object_r:fs_bpf_net_shared:s0`, ...), but NetBpfLoader pins into one directory and renames into
  another: `rename /sys/fs/bpf/netd_readonly/tmp_map_netd_configuration_map
  /sys/fs/bpf/netd_shared/map_netd_configuration_map -> -1 [18:Cross-device link]`, then `CRITICAL FAILURE
  LOADING BPF PROGRAMS FROM .../netd_shared/`, and init rebooted with `bpfloader-failed` at 62 s. Separately,
  first stage logged `Invalid ext4 superblock on '/dev/block/by-name/sd_metadata'` at 1.33 s: card p12 is a
  clone of an eMMC partition that was never ext4, so `/metadata` was never mounted and every `mkdir
  /metadata/...` in init.rc failed (`Read-only file system`).
* **Attempt 14 written.** (1) `hu-netbpfload` (`1188381ad8ad…`, 27,488 B) mounts ONE fresh bpffs over
  `/sys/fs/bpf` with `context=u:object_r:fs_bpf_net_shared:s0` before anything is pinned, so renames stay inside
  one filesystem and every object carries the label ClatCoordinator checks; super `31e636727427…`, three chunks.
  (2) Card p12 holds a fresh 16 MiB ext4 (`4caa7500c6cc…`, label `metadata`, made with `-O
  ^orphan_file,^metadata_csum_seed,^64bit` because the workstation's mke2fs 1.47 would otherwise enable
  `orphan_file`, which kernel 4.19 cannot mount read-write), written whole and read back equal.
* **Attempt 14 - `/metadata` works; one bpffs labelled net_shared fails the other check.** With card p12 now
  ext4, `mount_all` took 114 ms instead of 20 s and `/data` was up at 13.9 s. NetBpfLoad no longer failed, but
  system_server aborted again (tombstone_06, `system_server_native_crash`) after `context of '/sys/fs/bpf' is
  'u:object_r:fs_bpf_net_shared:s0' != 'u:object_r:fs_bpf:s0'`: ClatCoordinator checks the root as `fs_bpf`
  AND `net_shared` as `fs_bpf_net_shared`. Still cycling every boot: `vendor.audio-hal` (18x),
  `vendor.rockit-hal-1-0` (19x), `vendor.sensors-hal-1-0` (exit 255, 10x); zygote restarted 10x.
* **Relabelling bpffs is impossible on this kernel (MEASURED in the card recovery, 4.19.111+, permissive).**
  On a throwaway bpffs at `/tmp/bt`: `chcon u:object_r:fs_bpf_net_shared:s0 /tmp/bt/net_shared` ->
  `Operation not supported on transport endpoint` (EOPNOTSUPP); the directory stays `fs_bpf`. So neither
  path-based genfs labelling nor in-core relabelling exists for bpffs here.
* **Attempt 15 written: only `/sys/fs/bpf/net_shared` is a separate labelled bpffs.** init's root bpffs stays
  `fs_bpf`; `hu-netbpfload` (`19d496147974…`, 27,696 B) mounts a bpffs on `net_shared` with
  `context=u:object_r:fs_bpf_net_shared:s0` and mode 01777. A loader rename into or out of `net_shared` from
  another directory would still fail with EXDEV; the clatd objects live in `net_shared` itself. Super
  `c2634e99e6be…`, three chunks.
* **Attempt 15 - net_shared is also a staging directory.** With only `/sys/fs/bpf/net_shared` mounted as a
  separate labelled bpffs before loading, NetBpfLoader failed at 22.3 s with `rename
  /sys/fs/bpf/net_shared/tmp_map_netd_uid_counterset_map /sys/fs/bpf/netd_shared/map_netd_uid_counterset_map ->
  -1 [18:Cross-device link]` and init rebooted with `bpfloader-failed`. So no separate mount may exist while
  loading; `rename(2)` also needs the same mount, not just the same filesystem, so bind mounts cannot help.
* **Attempt 16 written: re-pin `net_shared` under a labelled bpffs after loading.** `hu-netbpfload`
  (`7ce1467065b8…`, 38,208 B) forks: the child loads exactly as on attempt 12 (private JIT knobs, init's single
  bpffs); the parent waits in the shared namespace and, only on success, opens every object in
  `/sys/fs/bpf/net_shared` with `BPF_OBJ_GET`, mounts a bpffs with `context=u:object_r:fs_bpf_net_shared:s0`
  over that directory, and pins each object again under the same name with its mode and owner (and the
  directory's). The root stays `fs_bpf`. init's `exec_start` waits for the wrapper, so this completes before
  netd or system_server start. Super `4c765d10575d…`, three chunks.
* **Queued from the local model's read-only HAL analysis (a14-work/qwen-hal-report.md), to be checked before
  use:** the vendor manifest declares `android.hardware.audio@5.0`/`audio.effect@5.0` while the image ships only
  `@6.0` impls (the audio HAL's `Could not register Audio Core API`); `light@2.0` and `gatekeeper@1.0` are
  declared with nothing installed (endless lazy-start retries); the rockit HAL has no seccomp policy in any stock
  tree and nothing on Android 14 depends on it, so it can be disabled. Its claim that the composer is still the
  blocker is out of date: attempt 11 measured the stock pair working.
* **Attempt 16 - the re-pin half-worked; RescueParty escalated to FACTORY_RESET.** The wrapper re-pinned the
  three clatd maps, but `BPF_OBJ_GET` on the three clatd programs failed with errno 13 (EACCES): the service has
  `CHOWN SYS_ADMIN NET_ADMIN` but not `DAC_OVERRIDE`, and the loader pins programs with restrictive owner/mode.
  Their net_shared paths were then missing (`context of '.../prog_clatd_...' is '' != ...`), system_server
  aborted again (tombstone_38), and RescueParty went to `FACTORY_RESET`: it wrote the card's BCB as
  `boot-recovery`, `recovery`, `--prompt_and_wipe_data`, `--reason=RescueParty`, `--locale=en_US`
  (`5370ef096334…`) and rebooted. The card recovery resolves `misc` to the eMMC (p8's dtbo), whose BCB was clear
  and whose head was unchanged (`0f2ec43e7a5c…`), so nothing acted on it; the card's `/data` was intact
  (tombstones up to tombstone_49 present). The next attempt's bcb-clear overwrites it, as before every attempt.
* **Attempt 17 written: re-pin with chown-first, plus the vendor HAL cleanups.** `hu-netbpfload`
  (`fa9a506917ce…`, 38,376 B) first makes each old pin root-owned and 0600 (CAP_CHOWN suffices; the old pin is
  hidden under the labelled mount afterwards, and restored if that mount fails), then opens it. Vendor (checked
  against the image before use): manifest `android.hardware.audio` and `audio.effect` `@5.0` -> `@6.0` (only
  `@6.0` impls ship, 32- and 64-bit), and the declared-but-absent `soundtrigger@2.0`, `light@2.0` and
  `gatekeeper@1.0` entries removed (22 -> 19 HALs); `disabled` added to the stock `vendor.audio-hal-2-0` service
  (two services would both register `IDevicesFactory/default`) and to `vendor.rockit-hal-1-0` (no seccomp policy
  for it exists in any stock tree, nothing on Android 14 uses it). Each file keeps mode, owner and label; e2fsck
  clean. Super `60bfc7a95603…`, seven chunks.
* **Attempt 17 - the bpffs labels pass; system_server reaches phase 550 and SystemUI starts; system_server then
  dies in Codec2's ION setup.** `hu-netbpfload: repin: 9 of 9 net_shared objects pinned again under
  fs_bpf_net_shared`, and no `context of ...` mismatch was logged. system_server got to `Starting phase 550`,
  SystemUI's KeyguardService started, and the boot animation went on to part1. The audio HAL no longer aborts
  on its own and rockit is gone. RescueParty still escalated to FACTORY_RESET (the same BCB `5370ef096334…`) after
  nine system_server deaths, every one the same native crash (tombstones 41-49): SIGSEGV at 0 in
  `std::string(...)` <- `C2AllocatorIon::setUsageMapper` <- `UseComponentStoreForIonAllocator` <-
  `C2PlatformAllocatorStoreImpl::fetchIonAllocator` <- `CCodecBufferChannel::start`, thread `NDK MediaCodec_`.
  There is no vendor Codec2 service; kernel 4.19 has no DMA-BUF heaps, so Codec2 uses ION, and the allocator's
  traits are only set if `/dev/ion` opens - so system_server could not open `/dev/ion`.
* **Why `/dev/ion` was root-only: Android 14 ignores the legacy `/vendor/ueventd.rc`.** The rule
  `/dev/ion 0666 system system` (and 149 others: sensor nodes, `mpp_service`/`vpu_service`, cameras) is in the
  stock `/vendor/ueventd.rc`; this build sets `ro.product.first_api_level=34`, so ueventd reads only
  `/system/etc/ueventd.rc` and its import `/vendor/etc/ueventd.rc`, which carried only the curated MTC/GPU/USB rules.
  The sensors HAL exiting with status 255 every cycle (8x) is consistent with the same missing sensor-node rules.
* **Attempt 18 written: the legacy rules carried into `/vendor/etc/ueventd.rc`.** All 150 legacy `/dev` and `/sys`
  rules come first, then the curated rules, which take precedence for the same node because they are later.
  Mode, owner and `vendor_configs_file` label kept; e2fsck clean. Super `8b274a84de8e…`, six chunks. The bcb-clear
  allowlist now also takes the exact RescueParty command (read in full first).
* **Attempt 18 - BOOT_COMPLETED.** With `/dev/ion` openable, system_server no longer crashes:
  `Posting BOOT_COMPLETED user #0`, `broadcastIntent-0-android.intent.action.BOOT_COMPLETED took to complete: 18ms`,
  and the stock HCT app logged `MicrontekReceiver>>>>> BOOT_COMPLETED`. RescueParty still escalated to
  `FACTORY_RESET` (same card BCB) because of app crash loops, read from the card's `/data/tombstones`:
  `com.android.systemui` and `com.android.launcher3` abort with `Failed to create context, error =
  EGL_NOT_INITIALIZED` in `libhwui EglManager::initialize`, and `com.android.bluetooth` aborts with
  `main_thread_start_up: unable to enable real time scheduling`.
* **Why.** (1) The curated ueventd rule `/dev/mali0 0660 system graphics` overrides the stock `0666` (stock
  Android 10 `/vendor/ueventd.rc` line 77), so app processes, which are not in group graphics, cannot open the
  GPU; surfaceflinger can. (2) The kernel config has `CONFIG_RT_GROUP_SCHED=y`, and Android 14's init.rc creates
  the cpuctl children without any `cpu.rt_runtime_us`, so no task in a child group may use SCHED_FIFO/RR.
* **Attempt 19 written.** `/dev/mali0`, `/dev/dri/card0` and `/dev/dri/renderD128` 0666 in `/vendor/etc/ueventd.rc`;
  new `/vendor/etc/init/hu-rt-cgroups.rc` giving each of the seven cpuctl children 100000 us of RT runtime in
  `on init` (the root keeps 950000 per 1000000 us). Labels kept/set to `vendor_configs_file`; e2fsck clean.

  Super `6f2059d9d175…`.
* **Attempt 19 - SystemUI and Launcher3 run; Bluetooth is the last crash loop.** `Posting BOOT_COMPLETED user #0`
  again; the RT budgets were applied (`processing action (init) from (/vendor/etc/init/hu-rt-cgroups.rc:7)`), and
  the newest ten tombstones are all Bluetooth: `android.hardware.bluetooth@1.0-service` aborts with `Open: No
  Bluetooth Address!` in `VendorInterface::Open` of `/vendor/lib64/hw/android.hardware.bluetooth@1.0-impl.so`,
  and `com.android.bluetooth` then aborts on the dead HAL (`Failed HIDL return status not checked`). RescueParty
  again went to FACTORY_RESET (same BCB). The AOSP-built impl (`db0f24627f4f…`) only looks for the address in
  properties (`persist.service.bdroid.bdaddr`, `ro.boot.btmacaddr`, `ro.bt.bdaddr_path`); the stock Rockchip impl
  (`39f52397bc4e…`) also reads it from Rockchip vendor storage (`Get local bdaddr from vflash`), and
  `/dev/vflash 0660 bluetooth net_bt_stack` is among the carried-over ueventd rules.
* **Attempt 20 written: the stock Bluetooth impl.** `/vendor/lib64/hw/android.hardware.bluetooth@1.0-impl.so` is the
  stock one, plus the library it needs that the image lacked, `/vendor/lib64/librkwifi-ctrl.so` (`9e04d2b5f005…`,
  23,920 B). All 89 imports of the impl and every C++ import of librkwifi-ctrl resolve against the Android 14 vendor
  libraries (libbase still exports the old `LogMessage(..., LogId, ...)` constructor); the rest are bionic names.
  Both files 0644 root, `vendor_file`; e2fsck clean.

  Super `987962713825…`.
* **Attempt 20 - the stock Bluetooth impl gets further, then talks to the wrong UART.** The HAL now loads
  `libbt-vendor.so`, finds no `/vendor/etc/bluetooth/bt_vendor.conf` and no rfkill (`init_rfkill: open
  /sys/class/rfkill/rfkill0/type failed`), opens `/dev/ttyS0` and aborts on what it reads: `OnDataReady:
  Unimplemented packet type 0`; com.android.bluetooth follows it down and RescueParty again went to FACTORY_RESET.
  Our `libbt-vendor.so` is byte-identical to stock (`620f9deea1f9…`), a generic library that defaults to
  `/dev/ttyS0`, and the stock image carries no `bt_vendor.conf` either (only `rtkbt.conf`). `/dev/ttyS0` is the
  GPS UART on this board; the unit's Bluetooth is the GOC module on `/dev/goc_serial`, driven by the HCT apps
  (`bt.goc.type=11`). So Android's own Bluetooth stack has no HCI controller to drive here.
* **Attempt 21 written: Android's Bluetooth stack turned off (decision, reversible).** Removed the feature files
  `android.hardware.bluetooth.xml` (`08305a972411…`) and `android.hardware.bluetooth_le.xml` (`845f59a4e13f…`) from
  both `/system/etc/permissions` and `/vendor/etc/permissions`, so system_server does not start its Bluetooth
  service; `disabled` added to `vendor.bluetooth-1-0`; the `android.hardware.bluetooth@1.0` entry dropped from the
  vendor manifest (19 -> 18 HALs). Restoring them from the attempt-20 images undoes it. e2fsck clean on both.

  Super `40209ef4136e…`.
* **Attempt 21 - the boot ran to the 300 s crasher; RescueParty still fired, on the Bluetooth app.** With the HAL
  and the two feature files gone, `Posting BOOT_COMPLETED user #0` again and the unattended crasher ended the boot
  at 301.1 s (`dmesg-ramoops-0` written). But `com.android.bluetooth` (persistent, in the btservices APEX) was
  still started and aborted every few seconds with `assertion 'bt_hci_ != nullptr' failed` in
  `bluetooth::hal::HciHalHidl::start_hidl()`, and RescueParty went to FACTORY_RESET once more.
  BluetoothManagerService was running (`MESSAGE_TIMEOUT_BIND`): the feature was still declared, by
  `/vendor/etc/permissions/tablet_core_hardware.xml` line 33 (`<feature name="android.hardware.bluetooth" />`); no
  other permissions or sysconfig file in system, vendor, product or system_ext declares it.
* **Attempt 22 written: the feature line removed from `tablet_core_hardware.xml`** (replaced by a comment; the
  rest of the device profile unchanged; mode, owner, `vendor_configs_file` kept; e2fsck clean).

  Super `57de0a9ab1a5…`.
* **Attempt 22 - Android 14 boots and stays up on the card: no crash loop, no RescueParty (MILESTONE).** The boot
  ran until the unattended crasher at 300 s; RescueParty never ran (0 `rescue level`/`RescueParty` lines), the card
  BCB afterwards was our own armed blob (`ceaae1a6314a…`), no tombstone was written during the boot (newest is
  attempt 21's), and the userspace log ring holds no `FATAL EXCEPTION`, `Fatal signal`, `ANR in` or `has died`.
  The framework reached the UI: `Displayed com.android.settings/.FallbackHome for user 0: +699ms`,
  `Start proc ...:com.android.launcher3/u0a142 for service {com.android.launcher3/com.android.quickstep.
  TouchInteractionService}`, display configuration `w683dp h372dp 240dpi ... land ... mBounds=Rect(0, 0 - 1024,
  600)`. Not yet seen on the screen itself (nobody watching) and not reachable over the network: the unit
  does not answer ping while Android 14 runs, so ethernet/adb under Android 14 is the next thing to bring up.
* **Left running for the owner.** Card p7 is back to `card-p7-a14-sdnames.img` (`1f4713f9f092…`): the default
  wrapper build, whose crasher stands down once `/data` is mounted, so a working boot is not cut short; it still
  arms the card BCB, so a button reset with the card in lands in the networked card recovery. Card p14 holds super
  `57de0a9ab1a5…` (attempt 22), card p12 the ext4 metadata, the card GPT the `sd_super`/`sd_metadata` names. The
  eMMC was never written all night (heads `0f2ec43e7a5c…`, `fac15a4b138e…`, `b06dc33648a3…` unchanged at every write).
* **Changes made on the way, all on the card and reversible (attempts 9-22):** vendor manifest (health@2.0 and
  keymaster@3.0 removed; audio/effect @5.0 -> @6.0; soundtrigger, light, gatekeeper and bluetooth removed); stock
  Android 10 composer@2.1-service + libhwc2on1adapter (Rockchip HWC1 ABI) and stock bluetooth@1.0-impl +
  librkwifi-ctrl; `service.sf.prime_shader_cache=0`; the stock Android 10 ueventd rules carried into
  `/vendor/etc/ueventd.rc`, GPU nodes 0666; RT budgets for the cpuctl children; `vendor.audio-hal-2-0`,
  `vendor.rockit-hal-1-0` and `vendor.bluetooth-1-0` disabled; Android's Bluetooth feature removed (the unit's BT
  is the GOC module driven by the HCT apps); `/system/bin/hu-netbpfload` (fork, private JIT knobs, re-pin of
  net_shared under a labelled bpffs) started as `hu_bpfloader`. Owner decisions still open: whether Android's own
  Bluetooth stack should come back, and repairing the NTFS data drive (`/dev/sda2`).
* **Attempt 23 - the setup wizard is on screen; the default build's crasher is not trustworthy.** With
  `card-p7-a14-sdnames.img` (default wrapper: crasher at 90 s, meant to stand down once `/data` is mounted) the
  userspace log has `Displayed org.lineageos.setupwizard/.WelcomeActivity for user 0: +3s955ms`, so Android 14 got
  as far as the LineageOS setup wizard's welcome screen. But the boot panicked at 91.25 s (`dmesg-ramoops-0` holds
  the sysrq dump): the crasher's single 4 KiB `pread` of a mount table opened at boot did not find ` /data ` at
  90 s, although the recorder's identical check had found it at 12 s. Not yet measured why (mount table grown past
  4 KiB, or the bootstrap-vs-default mount namespace init switches to); the heuristic needs fixing before the
  crasher is used again on a working boot.
* **Left running for the owner (attempt 24): card p7 `card-p7-a14-stay.img`.** The same image with the wrapper
  built `-DHU_NO_CRASHER` (`84657a3ba1df…`): no crasher at all; the recorder still stands down at `/data`; the card
  BCB is still armed, so a button reset with the card in lands in the networked card recovery.

  Card p7 image `47c863467e1f…`.
* **Attempt 24 (owner watching) - boot animation, a mis-fitting LineageOS welcome screen, then back to the boot
  animation.** The owner's cold reset emptied pstore; the post-mortem came from card `/data/system/dropbox`: 20 of
  20 `system_server_crash` entries are the same: `Unable to start receiver
  android.microntek.service.MicrontekReceiver: android.app.BackgroundServiceStartNotAllowedException: Not allowed
  to start service Intent { cmp=com.microntek.radio/.RadioService }: app is in background uid null`
  (`MicrontekReceiver.java:40` -> `:67`, `startServiceAsUser`). The HCT receiver (HCTManagerService, uid 1000) runs
  on system_server's main looper, so the exception kills system_server and the framework restarts from the boot
  animation. Android 10 allowed the background start; Android 14 does not. The receiver also starts BlueToothService,
  ManageService, OBD, CanBus and TXZ services. Density is 240 as in stock Android 10, so the wizard's fit is left alone
  for now.
* **Attempt 25 written: `/system/etc/sysconfig/hct-background-allowlist.xml`** puts the 30 HCT/Microntek app
  packages that are not uid 1000 (from the card's `packages.list`) on the power-save allowlist with
  `<allow-in-power-save>`. ActivityManager exempts allowlisted apps from background service start restrictions.
  Mode 0644, root, `system_file`; e2fsck clean. Card p7 stays `card-p7-a14-stay.img` (no crasher).

  Super `134f7bc2a996…`.
* **Attempt 25 - the radio crash is gone; system_server now dies in HCT ManageService.** 4 of 4 new
  `system_server_crash` entries: `java.lang.NoSuchMethodError: No virtual method clearLock([BI)Z in class
  Lcom/android/internal/widget/LockPatternUtils;` at `android.microntek.service.ManageService.onCreate
  (ManageService.java:225)`; the call sits in a `catch (Exception)`, which does not catch an Error.
  The owner saw the welcome screen fall back to a shorter boot animation, three times, and the ethernet dongle
  without lights.
* **The HCT framework layer is missing from Android 14 (finding, roadblock for the HCT apps).**
  `tools/dex_api_check.py` (reads the dex tables directly; baksmali 2.5.2 cannot read Android 14's
  framework dexes) checks HCTManagerService's 903 invoke references against the Android 14 boot-classpath
  jars in /system: missing are `LockPatternUtils.clearLock([BI)Z`, `DisplayManager.setTemporaryBrightness(I)V`,
  `INetworkManagementService.setDataUidRule(IZ)V`, and every `android.microntek.*` class (`CarManager`,
  `HCTApi`, `MfiManager`, ...). Stock Android 10 carries 33 `android.microntek.*` classes in `framework.jar`
  (`classes2.dex`) and the MCU service itself, `com.android.server.microntek.CarService` (+ `MfiService`,
  `HCT_CMD`), in `services.jar`, with its JNI in `libandroid_servers.so`. Porting that layer to Android 14
  is a project of its own and an owner decision.
* **Why the ethernet dongle is dark: USB power comes from the car MCU.** The dongle (AX88179, `0b95:1790`)
  sits behind the onboard SMSC hub (`0424:2514`, `usb 1-1` on `fe3c0000.usb`). In the card recovery the
  kernel logs `--mtc @ usb on` (an MCU message) at 0.26 s and the hub at 0.75 s; in Android 14's log the
  MCU says `@ >boot 2` instead of `@ >boot 1`, never `usb on`, and `usb 1-1` never appears. The two kernels
  differ (recovery: HCT 4.19.111 #2416, 2020; Android 14: 4.19.111 #190, 2024), but both carry the same
  mtc driver and run `car_init` and `otg force host`. CarService's `native_setParameters` is
  `open("/dev/mtc-car", O_RDWR); ioctl(fd, strlen(s), s)` (disassembled), and it sends
  `rpt_service_ready=true` on start and `rpt_boot_complete=true` at BOOT_COMPLETED. Sent by hand in the
  card recovery, `rpt_service_ready=true` returned 0 and the kernel logged `--mtc b sready`. The hypothesis is
  that on a warm boot the MCU powers USB only after the host reports in; attempt 26 tests it.
* **Attempt 26 written (four separately visible changes):**
  (1) `tools/hu_mtc_param.c` -> `/system/bin/hu-mtc-param` with `/system/etc/init/hu-mtc.rc`:
  `rpt_service_ready=true` at post-fs-data, `rpt_boot_complete=true` at `sys.boot_completed=1` and, as a
  fallback, 60 s after post-fs-data; every send is logged to kmsg as `hu-mtc: sent ...`.
  (2) adb over ethernet: `ro.adb.secure=0` in `/system/build.prop`; `/system/etc/init/hu-adb-tcp.rc` sets
  `service.adb.tcp.port 5555` at init and starts adbd at boot_completed.
  (3) HCTManagerService set aside (`HCTManagerService.apk` -> `HCTManagerService.apk.disabled-attempt26`):
  without the HCT framework it can only crash system_server.
  (4) Card p7 `card-p7-a14-deadman.img`: wrapper built `-DHU_DEADMAN -DHU_CRASH_SECS=300`. Every boot
  crashes into the networked card recovery at 300 s **unless disarmed over adb with `pkill -x
  hu-crasher`** (the crasher and recorder now name themselves `hu-crasher`/`hu-recorder` via PR_SET_NAME);
  the next boot re-arms it. `scripts/watch_live_a14.sh` tells Android 14's adbd from the recovery's (same
  address) by `ro.build.version.release` and disarms on the first answer.

  Super `ed0c18014bdd…`; card p7 `0fab10a5f2b4…`; hu-mtc-param `0052e2a02174…`; dead-man wrapper `c0624f4132b1…`.
* **Attempt 26 - adbd runs, the MCU takes `rpt_boot_complete`, but the boot completes late and nothing is
  seen on the network.** The dead-man crasher fired at 301 s as designed (nobody answered on adb). The console
  ring (276-302 s) shows `sys.boot_completed=1` only at 295.5 s, `adbd` already running ("requested start,
  but it is already running"), and `--mtc b boot comp` / `hu-mtc: sent 'rpt_boot_complete=true' ret=0`.
  The unit never answered ping while Android 14 ran, and whether the 60 s fallback ran and what USB did
  between 15 s and 276 s is not visible: the recorder stood down at `/data` (14 s), the console ring holds only
  the last 26 s, and `hu_insmod` restarts every 5 s fill it.
* **Attempt 27 written: observability only.** Card p7 `card-p7-a14-deadman2.img`: dead-man wrapper rebuilt
  `-DHU_DEADMAN -DHU_CRASH_SECS=600 -DHU_WDT_SECS=600`. Its recorder no longer stands down at `/data` and
  records kmsg for the whole boot into the card's 4 MiB region (fsync once a second), so the MCU sends, the
  USB enumeration and the network bring-up are visible after the crash. Super unchanged (attempt 26).

  Card p7 `9424c98a66dc…`; wrapper `c12f53e6b4c2…`.
* **Attempt 27 - the full-boot recorder works (2.16 MB, 505 s); the MCU reports do not power USB.**
  `hu-mtc: sent 'rpt_service_ready=true' ret=0` (`--mtc b sready`) at 22.3 s and `rpt_boot_complete=true`
  (`--mtc b boot comp`) at 82.3 s; BOOT_COMPLETED at 87 s. No `@ usb on`, no `usb 1-1`, no eth0, and the owner
  saw no dongle lights. HCT's own `up_eth0` fails (`Cannot find '/system/bin/busybox'`). system_server died at
  94.5 s and 18 more times (19 `system_server_crash`, all `NoClassDefFoundError: Failed resolution of:
  Landroid/microntek/CarManager;` at `android.microntek.mtcser.BlueToothService.onCreate`), then an orderly
  reboot at 504 s, before the 600 s deadline.
* **The trigger for USB power is in the kernel, not in warm vs cold boot.** The card recovery that came up
  after this warm reboot (`@ >boot 5`) logged `--mtc @ usb on` at 0.23 s again. Both device trees' `mtc-init`
  nodes (board 0x/1x/2x/3x tables, `otg_drv`, `sdio_en`, `mac_pwr`) are identical in structure, so the
  difference is in the 2024 kernel's mtc code or in another node; the recovery's live GPIOs have `otg_drv`
  (gpio-155) and `sdio_en` (gpio-91) high.
* **Attempt 28 written:** (1) `/system/bin/hu-diag.sh` + `/system/etc/init/hu-diag.rc` dump
  `/sys/kernel/debug/gpio`, the regulator summary, the USB device list and `/sys/class/net` into kmsg
  (`hu-diag[pfd]:`, `hu-diag[boot]:`) for the recorder; (2) the five remaining uid-1000 HCT apps that run in
  system_server set aside (`.apk.disabled-attempt28`): HCTCanBus, HCTBlueToothManager, HCTFactorySettings,
  HCTExtAppDocker, HCTExtScreenClock.

  Super `4186828d6b36…`.
* **Attempt 28 - system_server stable; USB 5 V found; the unit then suspended.** No system_server crash in the
  recorder; BOOT_COMPLETED at 91 s. The owner saw a black screen and restarts: at 152.5 s the panel switched
  off (`--mtc mtc_lcd_dis`), and at 154.5 s the kernel went to `PM: suspend entry (deep)`. The recorder ends
  there, and the unit came back cold into the card recovery. `hu-diag[pfd]` shows the cause of the dark dongle:
  **`gpio-155 otg_drv` is `out lo` under Android 14** but `out hi` in the card recovery. Every other line
  matches (sdio_en hi, lcdc_en hi, gps_pwr hi, ...). The USB device list has only the root hubs, and there is no eth0.
* **What Android 10 sent the MCU driver besides CarService:** its `libbootanimation.so` opens
  `/dev/mtc-car` and sends `rpt_logo_runing=true`, `rpt_boot_android=true`, `rpt_logo_complete=true` (and
  `rpt_android_cid=%s`); the 2024 kernel's mtc-car parser knows them (`--mtc b android`, `--mtc b logo comp`)
  together with `ctl_keep_wake` and `sta_sleep_enable`. Android 14's own boot animation sends nothing.
* **Attempt 29 written:** `hu-mtc.rc` sends `rpt_logo_runing=true rpt_service_ready=true` at post-fs-data and
  `rpt_boot_android=true rpt_logo_complete=true rpt_boot_complete=true` at boot completion (and 60 s after
  post-fs-data); a kernel wakelock `hu_keepawake` at early-boot and, at boot completion,
  `stay_on_while_plugged_in 7` plus a maximal `screen_off_timeout`; `hu-diag` runs a third time 90 s after post-fs-data
  (`hu-diag[late]`) to show whether `otg_drv` went high.

  Super `893cac8902a5…`.
* **Attempt 29 - MILESTONE: ethernet and adb under Android 14.** At 82.6 s `hu-mtc` sent
  `rpt_boot_android=true`, `rpt_logo_complete=true` and `rpt_boot_complete=true` (`--mtc b android`,
  `--mtc b logo comp`, `--mtc b boot comp`); at 82.7 s the MCU answered `--mtc @ usb on`, `@ >on3`,
  `@ first boot`; at 82.9 s `usb 1-1` (SMSC 2514 hub) enumerated, then `usb 1-1.2` AX88179 (`eth0`,
  `00:0a:cd:27:a5:b2`) and `usb 1-1.4` (Realtek `0bda:0179` WLAN). eth0 got `192.168.1.127/24`, and Android 14's
  adbd answered at 13:01:38, 97 s after the reboot. The owner saw the dongle come online after the boot animation. Which of the
  three strings switches USB (and with it `otg_drv`) is not yet separated; `rpt_boot_android` is the candidate,
  because Android 10's libbootanimation sent it. No system_server crash this boot; two app crashes
  (`android.rockchip.update.service`, `NoClassDefFoundError: android.microntek.CarManager`).
* **Root over adb on LineageOS 21:** `adb root` is refused ("ADB Root access is disabled by system setting"),
  and neither `persist.sys.root_access=3` nor `lineage.service.adb.root=1` lifts it. On this userdebug build with
  SELinux permissive, `adb shell 'setprop service.adb.root 1; setprop ctl.restart adbd'` restarts adbd as uid 0.
  That disarmed the dead-man crasher (`pkill -x hu-crasher`) at 183 s; `scripts/watch_live_a14.sh` now does this.
* **Staying awake:** attempt 29's early-boot `write /sys/power/wake_lock hu_keepawake` is accepted but never
  listed (this kernel's interface does not hold it), and the boot-completed `settings put` (exec as system)
  did not take. Set by hand over adb: `stay_on_while_plugged_in 7`, `screen_off_timeout 2147483647`,
  `svc power stayon true`, after which PowerManager reports `mStayOn=true`. These need to move into the image.
* **Attempt 29, live with the owner:** the touch screen works (`goodix-ts`). The hardware buttons do nothing:
  input devices are `gpio-keys` (event2), `mtc-key` (event0) and `goodix-ts` (event1), and while the owner
  pressed buttons `getevent` saw nothing on event0/event2. The kernel logs `--mtc key 0111` / `--mtc key
  0119` per press. The keys reach the MCU driver, and on Android 10 HCT's CarService turned them into key
  events. Stock Android 10 has no `mtc`/`hct` key layout either.
* **Owner decision (2026-11-24): port the HCT framework layer to Android 14.** Architecture chosen:
  (1) the 33 `android.microntek.*` client classes from Android 10's `framework.jar` as a new
  `/system/framework/hct-framework.jar` on the boot classpath; (2) `com.android.server.microntek.CarService`
  (+ MfiService) from Android 10's `services.jar`, hosted in a new persistent system-uid app that registers
  the binder service itself, with its JNI reduced to the `/dev/mtc-car` ioctl transport (already
  reimplemented in `tools/hu_mtc_param.c`); (3) the set-aside HCT apps (attempts 26/28) restored afterwards.
  Android 14's own `services.jar` stays untouched.
* **WiFi under Android 14 (attempt 29, analysis by the local model, verified):** `wlan0`/`p2p0` exist (8188eu/8188fu loaded);
  the WiFi module checks HIDL before AIDL, finds `android.hardware.wifi@1.3::IWifi/default` declared in
  `/vendor/etc/vintf/manifest.xml` and waits forever for `@1.0::IWifi/default` ("Could not find
  'android.hardware.wifi@1.0::IWifi/default' for ctl.interface_start", `dumpsys wifi`: "Wifi Service is not
  started"), while the AIDL HAL `vendor.wifi_hal_legacy` (`android.hardware.wifi-service`, IWifi V2) is
  declared by its fragment and running. The vendor manifest also still declared HIDL hostapd@1.1 and
  supplicant@1.2 next to the AIDL fragments.
* **Attempt 30 written:** the three HIDL WiFi entries removed from the vendor manifest (18 -> 15 HALs; the AIDL
  fragments `android.hardware.wifi-service.xml`, `...hostapd.xml`, `...supplicant.xml` stay);
  `/system/bin/hu-stayon.sh` + `/system/etc/init/hu-stayon.rc`: at boot completion a root service retries
  `settings put global stay_on_while_plugged_in 7`, `screen_off_timeout 2147483647`, `svc power stayon true`
  and logs `hu-stayon:` to kmsg; `on property:hu.disarm=1` runs `pkill -x hu-crasher` (no-root disarm).

  Super `b1a810b794a7…`.
* **Attempt 30 - WiFi works (one step done live).** The WiFi service now uses the AIDL HAL (`WifiHalAidlImpl:
  Creating the Wifi HAL using the AIDL implementation`, `Remote Version: 2`), and `hu-stayon: applied after 0
  retries`. Enabling WiFi then failed in the HAL: `finit_module return: -1: File exists` / `Failed to load
  WiFi driver` / `Wifi HAL start failed`. The cause was our own `hu_insmod` (`/vendor/etc/hu_insmod.sh`), which
  preloads every WiFi module and, lacking `oneshot`, was restarted by init every 5 s (also the source of the
  AIC8800 `sdio: host isn't initialization successfully` spam). Live: `setprop ctl.stop hu_insmod`,
  `rmmod 8188eu 8188fu aic8800_bsp`, `cmd wifi set-wifi-enabled enabled`. The HAL loaded `8188eu` itself,
  `Wifi is enabled` on `wlan0` (`ConcreteClientModeManager ... ROLE_CLIENT_PRIMARY`), and the scan lists the
  surrounding 2.4 GHz networks. Left: `Failed to get driver version` / `Failed to register debug response;
  result = -95` (cosmetic).
* **Attempt 31 prepared (vendor image, not yet written):** `hu.rc` gets `oneshot`; `hu_insmod.sh` loads
  only `usb_f_iap usb_f_iap2 sd_user_hid`; same change in `device/rk3399-px6-hct4/configs/`.
* **Attempt 29 logcat digest** (written by the local model, spot-checked): `docs/a14-attempt29-logcat-digest.md`. Open items it
  lists beyond what is fixed: `android.rockchip.update.service` crash-loops on `android.microntek.CarManager`
  (crash dialog; fixed by the framework port), the `memtrack@1.0` HAL aborts once (`FORTIFY: readdir: null
  DIR*`), USB gadget mode is dead (`configfs-gadget fe800000.dwc3: failed to start g1: -19`, so adb only over
  ethernet), the radio HAL is old (`getCurrentCalls not supported on service VOICE < 1.4`), mtc GPS writes
  fail (`--mtc write_gps: could not send $PCAS06,6*1D`), and many unused HAL lookups. Its WiFi section predates
  attempt 30.
* **Attempt 31 (pending):** also `disabled` on `vendor.weaver-hal-1-0` (no VINTF entry; it exited and
  restarted every 5 s).
* **Attempt 30, owner test on the unit:** WiFi finds networks, and a WPA2 connection to the owner's network
  succeeded. WiFi works end to end on Android 14 (AIDL WiFi HAL + `8188eu` loaded by the HAL).
* **HCT framework port - survey** (local model, `docs/hct-framework-port-survey.md`): Android 10 registered
  `com.android.server.microntek.CarService` as `carservice` and `MfiService` as `mfiservice` in
  `SystemServer.startOtherServices()`; CarService reads MCU frames (0xFA-framed) from `/dev/ttyV2` at
  38400 baud through `SerialManager`, dispatches them to `ICarManageCallback`s, and talks back through the
  `/dev/mtc-car` ioctl (2 JNI natives); MfiService sits on the vendor HIDL HAL `android.hardware.mtc.mfi@1.0`.
  The client side is 33 `android.microntek.*` classes (no natives). About 40 hook sites in stock framework
  and services code (permission/broadcast exemptions for `com.microntek.`/`com.hct.`, audio focus, the
  MCU beep, PhoneWindowManager key forwarding) are listed for later.
* **Attempt 31 written - step 1 of the port: `android.microntek.*` on the boot classpath.**
  `/system/framework/hct-framework.jar` (`4ddb63b30b70…`, built by the local model: the 33 classes from Android 10's
  `framework.jar` classes2.dex, hiddenapi flags stripped, 15 `HCTApi` stack/density method bodies stubbed;
  `tools/dex_api_check.py` reports nothing missing against Android 14; notes in
  `hct/hct-framework-NOTES.md`). `/system/etc/classpaths/bootclasspath.pb` gains one `BOOTCLASSPATH`-only
  entry after `core-icu4j.jar` (not `DEX2OATBOOTCLASSPATH`, so the boot image stays a valid prefix). Also
  in this image: the attempt-31 vendor fixes (`hu_insmod` oneshot without WiFi modules, weaver disabled).

  Super `bc4f6adb6ce5…`.
* **Attempt 31 - port step 1 works.** Boots; `hct-framework.jar` is entry 15 of `BOOTCLASSPATH` (right
  after `core-icu4j.jar`); `odrefresh` saw `BootClasspath components mismatch: Component count differs (40 != 39)`
  and recompiled the boot-classpath extension and system_server jars into `/data` (first boot slow:
  post-fs-data at 137 s instead of ~24 s). No `ClassNotFoundException: android.microntek` this boot;
  `android.rockchip.update.service` now fails one step later with a `NullPointerException` (no `carservice`
  behind `CarManager` yet). Stay-on applied on the first try.
* **Port step 2 inputs:** the serial service exists but its port list is empty (`service call serial 1` ->
  empty parcel), so `SerialManager.openSerialPort("/dev/ttyV2")` would be refused; `/dev/ttyV2` is
  `crwxrwxrwx system system`, so CarService will open it directly. `tools/hu_hctcar_jni.c` ->
  `libhctcar.so` (`215a5dbd6f30…`, freestanding, no `DT_NEEDED`, exports only `JNI_OnLoad`) registers
  `native_setParameters`/`native_getParameters` on `com/android/server/microntek/CarService` with the
  Android 10 ioctl semantics. The local model is moving CarService into HCTManagerService (ManageService runs in
  system_server as uid system), with the `clearLock` call removed and `carservice` registered from `onCreate`.
* **Attempt 32 written - port step 2: CarService hosted in HCTManagerService.** The local model's build (notes in
  `hct/hctmanager-step2-NOTES.md`): the 16 non-Mfi `com.android.server.microntek` classes from Android 10's
  `services.jar` merged into HCTManagerService's dex; CarService opens `/dev/ttyV2` with a
  `FileInputStream` (the serial service lists no ports) and its reader thread reads into a 4 KiB `byte[]`
  before the unchanged `DataProc`; `ManageService.onCreate` loads `/system/lib64/libhctcar.so` and
  `ServiceManager.addService("carservice", new CarService(this))` (in a `catch (Throwable)`, logged under the tag
  `HCTPort`), and its `clearLock` call is removed. Review fixes before use: the registration guard was
  inverted (`if-eqz` skipped registration exactly when `carservice` was absent; now `if-nez`), and the two
  remaining removed-API calls in `MicrontekServiceBase` (`INetworkManagementService.setDataUidRule(IZ)V`,
  `DisplayManager.setTemporaryBrightness(I)V`, each a `NoSuchMethodError` that `catch (Exception)` misses)
  are now `nop`. `tools/dex_api_check.py`: nothing missing. Only `classes.dex` in the APK changed (STORED,
  other 27 entries byte-identical, not re-signed); APK `08f7eea6da03…`. The other HCT system apps stay
  aside. First Android 14 test of an unsigned modified system APK.

  Super `64ae84cff222…`.
* **Attempt 32 - port step 2 works: `carservice` runs on Android 14.** The unsigned, modified HCTManagerService
  was accepted by the package manager; logcat `CarService: mtc >>> CarService start`, `HCTPort: carservice
  registered`; `service list`: `carservice: [android.microntek.ICarService]`; no system_server crash; boot
  completed at 82 s. system_server holds `/dev/ttyV2` open, and the reader thread waits in `wait_woken`. The
  `MicrontekServer.InitData` stack in logcat is only the "Sending non-protected broadcast
  com.microntek.report.event from system" warning.
* **Buttons, measured with the owner pressing:** the kernel logs `--mtc key 0111` (IR_VOLUP), `0119`
  (IR_VOLDOWN), `0128`, `0134`, `0136`. Nothing arrives on `/dev/ttyV2` (no CarService frames) and nothing on any
  input device, so on this kernel the keys do not travel over ttyV2. The 2024 kernel's mtc driver has
  `rpt_key_mode` (`swkey`/`cankey`) and `ctl_key`; HCTManagerService sends `ctl_key=13/257/800` and reads
  `sta_kmode=`. Traced next: what the driver does after `--mtc key`.

