# App-layer staging record (**D24**) — what was taken from the reference payload, and what proves it

Everything here was extracted from the **reference payload** (`extracted update.zip`), not from the live
unit: the owner's decision (Nov 7/8) is that the payload's images are the drop-in set for this MCU.
Provenance rules and consequences are in `docs/decisions.md` **D24**; this file is the evidence.

## How the payload was read

`debugfs` cannot read a `.new.dat` payload, so the images were reassembled first (`tools/reassemble.py`,
brotli-decompressed `*.new.dat` + symlinked `*.transfer.list`), into
`/srv/dev-disk-by-label-SSData/aospbuild/tmp/ref-a10/`:

| image | size | source |
|---|---|---|
| `system.img` | 1,442,840,576 B | `system.new.dat.br` + `system.transfer.list` |
| `product.img` | 925,892,608 B | `product.new.dat.br` + `product.transfer.list` (this pass) |
| `vendor.img` | 333,447,168 B | reassembled earlier |

`system_ext` is **not in the payload at all** — the Android 10 package ships system/product/vendor/odm
only, and `dynamic_partitions_op_list` adds exactly those four to the group
`rockchip_dynamic_partitions 3258974208`. There is nothing to reassemble for it.

Files were read with `tools/ext4_ls.py` (walk/dump_file) and `debugfs -R dump`, never mounted. Note the
payload's `system.img` is a **system-as-root** image: `/bin`, `/etc`, `/app`, `/priv-app` at the root are
symlinks, so the real content is under `/system/...`, while `/init.hct.rc` really does live at the root.
`product.img` has no such prefix: its root *is* `/product`.

## Package names, sharedUserId and permissions

`tools/hct_apk_inventory.py` reads each `AndroidManifest.xml` with AAPT2 (`dump xmltree`) and records
package, `android:sharedUserId`, target SDK, size, sha256 and the permission list. Full table:
`analysis/app_layer_inventory.tsv` (48 candidates, one line per apk).

Seven candidates declare a shared uid:

| apk | package | sharedUserId |
|---|---|---|
| `priv-app/HCTBlueToothManager` | `android.microntek.mtcser` | `android.uid.system` |
| `priv-app/HCTCanBus` | `android.microntek.canbus` | `android.uid.system` |
| `priv-app/HCTExtAppDocker` | `com.microntek.externshow` | `android.uid.system` |
| `priv-app/HCTExtScreenClock` | `com.microntek.extscreenclock` | `android.uid.system` |
| `priv-app/HCTManagerService` | `android.microntek.service` | `android.uid.system` |
| `system/HCTAudioPreview` | `com.android.music` | `android.uid.system` |
| `system/HCTFactorySettings` | `com.hct.factory` | `android.uid.system` |

The excluded ones declare `android.uid.systemui` (`HCTSystemUI10`) and `android.uid.bluetooth`
(`ExtAospBluetooth10`).

## Package collisions with what Lineage 21 installs

`tools/hct_apk_inventory.py --collision <candidates> <our roots>` compared the candidates against the
packages in `out/target/product/rk3399/{system,system_ext,product}/{app,priv-app}` + `vendor/overlay`
(90 packages). Output kept in `analysis/app_layer_package_collisions.txt`: 7 collisions.

| candidate | package | already installed by Lineage 21 |
|---|---|---|
| `system/HCTExactCalculator10` | `com.android.calculator2` | `product/app/ExactCalculator` |
| `product/app/HCTDeskClock10` | `com.android.deskclock` | `product/app/DeskClock` |
| `product/app/HCTGallery10` | `com.android.gallery3d` | `product/app/Gallery2` |
| `product/priv-app/HCT4Launcher3` | `com.android.launcher3` | `system_ext/priv-app/TrebuchetQuickStep` |
| `product/priv-app/HCTSettings10` | `com.android.settings` | `system_ext/priv-app/Settings` |
| `product/priv-app/HCTSystemUI10` | `com.android.systemui` | `system_ext/priv-app/SystemUI` |
| `priv-app/HCTPackageInstaller10` | `com.android.packageinstaller` | `system/priv-app/PackageInstaller` |

Non-collisions worth naming, because they look like collisions from the directory name alone:

* `HCTAudioPreview` is package `com.android.music`; Lineage 21's music player is **Jelly**
  (`org.lineageos.jelly`) → no collision, so it stays.
* `HCTCalendar10` is `com.android.calendar`; our build installs only `CalendarProvider`
  (`com.android.providers.calendar`) → no collision, but it is still excluded (see below).
* `ExtAospBluetooth10` is `com.android.bluetooth` and there is **no** `com.android.bluetooth` in our
  build at all: no install rule for `Bluetooth/Bluetooth.apk` in `out/soong/installs-lineage_rk3399.mk`,
  and no product config asks for it. That is a real gap, not a collision — see "Bluetooth" under risks.

## Include / exclude

**Included (32 into `/system/app`, 5 into `/system/priv-app`)** — the head-unit feature set: radio and
tuner (`HCT4Radio`, `HCTTpms`, `HCTSync`, `HCTNaviSettings`, `HCT8AmpSetup`), media and AV-in
(`HCT4Music`, `HCT4Movie`, `HCTExtMusic`, `HCTExtMovie`, `HCTAudioPreview`, `HCTAvin`, `HCTBackView`,
`HCTFrontView`, `HCTDvd`, `HCTTv`, `HCTCarCD`, `HCTCarRecoder`, `HCTDVR_IR`), Bluetooth controllers
(`HCT4BlueTooth`, `HCT4BtMusic`, `HCTBlueToothManager`, `HCT4UsbIpod`, `HCTCivicusbipod`), the control
plane (`HCTCanBus`, `HCTManagerService`, `HCTCarTouch`, `HCTControlInfo`, `HCTControlSettings`,
`HCTFactorySettings`), the overlay/clock/UI pieces (`HCTExtAppDocker`, `HCTScreenClock`,
`HCTExtScreenClock`, `HCTWidget`), and the service/install helpers (`HCTUpdateService`, `HCTApkInstall`,
`HCTWheelStudy`).

**Excluded, with the reason:**

| candidate | reason |
|---|---|
| `HCTSystemUI10`, `HCTSettings10`, `HCT4Launcher3`, `HCTProvision10`, `HCTPackageInstaller10` | framework-coupled forks of SystemUI/Settings/Launcher/Provision/PackageInstaller; they compile against Android 10 framework internals (`android.uid.systemui`, `com.android.settings` resource tables, SystemUI's dependency on Android 10 `IStatusBar`/`SystemUI` internals) and Lineage 21 installs its own — every one of them collides by package name except Provision |
| `HCTExactCalculator10`, `HCTDeskClock10`, `HCTGallery10` | package collisions (table above): Lineage's ExactCalculator/DeskClock/Gallery2 win, the HCT fork would never be installed |
| `HCTCalendar10` | not a head-unit feature; it is an Android 10 fork of AOSP Calendar (targetSdk 28). Lineage 21 ships no Calendar app, so it would be a *new* app with Android 10 UI code on API 34 rather than a drop-in — the owner can add it later |
| `HCT4Launcher` | 4,606 B stub declaring package `com.android.launcher`; the home screen here is Trebuchet (`com.android.launcher3`) |
| `ExtAospBluetooth10` | package `com.android.bluetooth` declaring `android.uid.bluetooth`: it is the Android 10 **Bluetooth stack implementation** (BluetoothService/BluetoothManagerService + `libbluetooth_jni`), which Android 14 replaced with an AIDL stack. Installing it would not give Bluetooth; it would crash against Android 14's framework |
| Google apps (`Chrome`, `WebViewGoogle`, `TrichromeLibrary`, `GmsCore`, `Gsf`, `Velvet`, `Phonesky`, `LatinImeGoogle`, `Google*SyncAdapter`, `ConfigUpdater`, `GoogleOneTimeInitializer`, `GooglePartnerSetup`, `ModuleMetadataGooglePrebuilt`, `SettingsIntelligence` in product) | Google proprietary packages, not head-unit features; this ROM ships no GMS (~330 MB of the payload's /product) |
| stock AOSP apps in `/system` and `/product` (`Bluetooth`, `NfcNci`, `PrintSpooler`, `MusicFX`, `TeleService`, `DocumentsUI`, `DeskClock`, `Gallery2`, …) | Android 14 builds its own versions of these |
| `oat/**` directories in every app dir | Android 14 dexopts at boot; Android 10's prebuilt odex/vdex cannot be used by Android 14's runtime |

## Binaries, libraries and data files

`tools/hu_system_abi_check.py` checks each staged ELF against Android 14's own `/system`,
`/system_ext`, `/odm` and APEX libraries, per architecture (ELF class, not directory). Report kept in
`analysis/app_layer_system_abi.txt`.

**Copied into `/system/bin`** (32-bit ARM, all of them started by `/system/etc/init/hct.rc`):
`gocsdk`, `gocsdk5`, `gocsdk6`, `gocsdk8`, `gocsdkrf210`, `sdsdk6`, `sdsdk816`, `sdsdk835`, `sdsdk936`,
`sdsdk968`, `blueletd`, `brlinktd`, `sd_carplay`, `dhcpcd`, `ec_usb_filter` (46-byte JSON of USB vendor
ids), `sd-link.sh`, `z-link.sh`, `hctlog.sh`, `ethtether.sh`.

Not copied: `lsusb` (payload copy is a 6-byte symlink to `toybox`, Android 14 installs that symlink →
collision), `vendingpatch.sh` (Google Play property patcher; no Play here), and the binaries
`/system/etc/init/hct.rc` names but the payload does not contain: `sdsdk`, `hctcanbusservice`,
`sd-reverse.sh`, `adb-ec-server.sh`, `start_usbmuxd.sh`, plus `/system/lib/wb.ko`, `/system/lib/wlan.ko`
and `/system/lib/sd_wb.ko` (only `chmod` lines exist for them, no files).

**Copied into `/system/lib` / `/system/lib64`** — only libraries a kept binary or a kept apk names:

| library | who needs it |
|---|---|
| `lib/libbt_platform.so` → `lib/libbluelet.so` | `blueletd` (DT_NEEDED `libbt_platform.so`, which needs `libbluelet.so`) |
| `lib/libbt_platform_brlinktd.so` → `lib/libbrlinktd.so` | `brlinktd` |
| `lib/libGbtsTask.so` (3,767,784 B) | `gocsdkrf210` (DT_NEEDED, the BCM/CSR HCI + Goc command stack) |
| `lib/libgocdfu.so` | `HCTBlueToothManager` calls `System.loadLibrary("gocdfu")` |
| `lib/librockchip_update_jni.so`, `lib64/librockchip_update_jni.so` | `HCTUpdateService` calls `System.loadLibrary("rockchip_update_jni")` |

Which apk names which library was checked by decompressing each apk's `classes*.dex` and scanning the
strings (`tools/hu_apk_native_libs.py`) — a plain grep on the apk finds nothing because the dex is
deflated. It also found that `HCTBlueToothManager`, `HCTExtAppDocker`, `HCTManagerService` and
`HCTFactorySettings` reference `com.suding.speedplay` / `com.zjinnova.zlink`, i.e. CarPlay/Android-Auto
apps that the payload does not ship.

Not copied, and why:

* `lib/librga.so`, `lib/libvibrator.so`(32), `lib64/libvibrator.so`, `lib/libmdnssd.so`,
  `lib64/libmdnssd.so`, `lib/libradio_metadata.so`, `lib64/libradio_metadata.so` — Android 14 installs
  its own copies of these names, so a copy would collide with a module install rule. `/vendor` already
  carries Rockchip's own `librga.so` for the vendor blobs (vendor namespace), so the `/system` copy is
  not what the HALs use anyway.
* the Rockchip media stack `lib/librockit.so`, `lib/librockit_interface.so`, `lib/librockit_hw_client@1.0.so`,
  `lib/libffmpeg_58.so`, `rockchip.hardware.rockit.hw@1.0.so`, `rockchip.hardware.outputmanager@1.0.so`,
  `android.hardware.mtc.mfi@1.0.so`, `lib/libgralloc_priv.so`, `lib/libhidltransport.so` — no kept binary or
  apk names them, they are framework-side HIDL/graphics plumbing for HALs that `/vendor` talks to through
  its own vendor-namespace copies (`lib/librockit_hw_hidl@1.0.so`, `rockchip.hardware.rockit.hw@1.0.so`
  in `/vendor/lib`), and `lib/librockit_interface.so` does **not** resolve on Android 14 anyway: 11
  libgui/libui symbols are gone (`SurfaceComposerClient::createSurface(..., LayerMetadata)`,
  `Transaction::apply(bool)`, `getDisplayInfo`, `getInternalDisplayToken`, `Surface` ctor, `LayerMetadata`).
* `lib/librockcv_java.so` (9,973,908 B) and `lib/librockchipxxx.so`, `lib/librksoundsetting.so` +
  `librttinyxml.so`, `lib/librtmem.so`, `lib/librtopus.so` — no kept consumer found in the dex scan or in
  the vendor blobs' DT_NEEDED. `librksoundsetting.so` needs `librttinyxml.so`, which Android 14 does not
  build, so shipping it would mean shipping that too; if owner testing shows the AMP/EQ path needs it, it
  can be added in one copy rule.

**Copied into `/system/etc`**: the init fragment, the OEM config files the payload's apps read, and our
privapp whitelist.

| destination | note |
|---|---|
| `/system/etc/init/hct.rc` | from the payload's root `/init.hct.rc` (6,638 B). Android 14's init reads the directory (`system/core/init/init.cpp:344`), not a root-level OEM file. One deliberate edit: line 1 `import /init.hct.camera.rc` is dropped - that file does not exist in the payload (debugfs: `File not found by ext2_lookup`) and init logs a failed import every boot if it is left in. Result 6,611 B, and `diff <(tail -n +2 analysis/system_init.hct.rc) .../hct.rc` says identical, so everything else is byte-for-byte |
| `/system/etc/car_filter.xml`, `/system/etc/alarm_filter.xml`, `/system/etc/ec.conf`, `/system/etc/ec_conn_type`, `/system/etc/operator_table`, `/system/etc/bluesoleil/TL.INI` | OEM data, none of it installed by Android 14 |
| `/system/etc/permissions/privapp-permissions-hct.xml` | ours, written from the manifests (`--perms`); the payload has no HCT whitelist |

Not copied: `/system/etc/gps_debug.conf` (Android 14 installs its own), `/system/etc/init.d/00init_magisk`
and `01init` (Magisk boot scripts — forbidden by D5/P6), `/system/etc/bluetooth/*` (Android 10 Bluetooth
stack config + RTL firmware blobs — see the Bluetooth gap), `audio_effects.conf`,
`media_profiles_V1_0.dtd`, `apns-conf.xml`, `mixer_paths.xml`, `hosts` (Android 14 builds or vendors its
own equivalents).

## Signing

| certificate | sha256 of the cert DER | who carries it |
|---|---|---|
| `build/make/target/product/security/platform.x509.pem` | `c8a2e9bccf597c2fb6dc66bee293fc13f2fc47ec77bc6b2b0d52c11f51192ab8` | our `framework-res.apk`, `SystemUI.apk`, `Settings.apk` — i.e. **this build's platform key** |
| payload's own Android key | `2d370c21f5dfd553d2a796314b70925fb38adeef90864c920bbbbb12887d3522` | every HCT/Microntek apk in the payload (same subject DN `CN=Android`, different key) |
| `build/make/target/product/security/testkey.x509.pem` | `a40da80a59d170caa950cf15c18c454d47a39b26989d8b640ecd745ba71bf5dc` | `default_system_dev_certificate` (misc_info.txt) — not what platform modules get |
| `vendor/lineage/build/target/product/security/lineage.x509.pem` | `518325ef7f96c0d1194c2e856b040d636166ffb846717d72fa87f4fae5be7bbb` | recovery keys (`extra_recovery_keys`) only |

So the payload's apps do **not** carry our platform key, and the seven `android.uid.system` apps would be
refused by PackageManager as-is. They are re-signed by Soong: `certificate: "platform"` in
`device/rk3399-px6-hct4/apps/Android.bp` resolves to
`build/make/target/product/security/platform.{pk8,x509.pem}` (Soong's `processMainCert`, app.go:664) and
signs with the build's own `signapk`. `apksigner` cannot be run on the build host directly
(`out/host/linux-x86/bin/apksigner` is a wrapper that needs `java`, which is not installed there), so the
verification is done on the *installed* apks: certificate digest via `tools/hu_apk_cert.py` (openssl
PKCS7) and `sharedUserId`/package via `tools/hct_apk_inventory.py`.

Before/after of two representative apks (the apk bytes change; the cert digest does not):

| apk | sha256 before (payload copy) | sha256 after (installed) |
|---|---|---|
| `system/HCT4Radio/HCT4Radio.apk` | `b7322b3dfea178f74a297774b491251c5fac7cbb39c4313fd7d563ad5355a6ac` | see D24 table (filled after the build) |
| `priv-app/HCTCanBus/HCTCanBus.apk` | `90c587fcf3657d8f4a67f8033bcadc9f3159d469d89890cb699cbd871af15857` | see D24 table (filled after the build) |

## Sizes

See `docs/decisions.md` D24 for the before/after numbers and the super-group fit (misc_info.txt: group
`super_hct_dynamic_partitions_group_size=3258974208`, partitions `system vendor product system_ext odm`).

## Gate results

Same in D24: `scripts/deploy_device.sh ../lineage21s` exit 0, `tools/vendor_conflicts.py` "no collisions",
`m -j4 systemimage productimage` exit code and the resulting image sizes.
