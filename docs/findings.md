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
itself (`device/rk3399-px6-hct4/vendor_build_wins.txt`), among them `bin/hw/android.hardware.gnss@1.0-service`,
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

`android.hardware.media.omx@1.0-service` (kept and requested) **dlopen`s**
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
  fields, never the boot chain's payload. Our routes never write that area (**D18**/****D19**), and the
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
