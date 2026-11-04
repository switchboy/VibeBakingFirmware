# Phase 0 — firmware inventory

Source: `update.zip` (1 203 718 969 bytes, sha256 `dd3e2ac0610bb64f0715e520300e5ee2dd6652e80fc33bdb0f1a02ba87528013`)
and the extracted copy in `extracted update.zip/`. All derived artefacts live in `analysis/`.

## Package format

Rockchip/AOSP block-OTA zip. Payloads are **not** raw filesystem images: each partition is described
by a `<part>.transfer.list` (block size **4096**, commands `new/zero/erase`, each line prefixed with a
value count) plus `<part>.new.dat.br` (brotli), whose decompressed `<part>.new.dat` is the **sequential
concatenation of the `new` chunks in command order**. `<part>.patch.dat` is empty → full flash.
`tools/reassemble.py` rebuilds the ext4 images; rebuilt sizes match `dynamic_partitions_op_list` exactly:

| partition | resize | rebuilt image | ext4 fs |
|---|---|---|---|
| system | 1 442 840 576 | 1 442 840 576 | `ext4`, volume `system`, clean |
| vendor | 333 447 168 | 333 447 168 | `ext4`, volume `vendor`, clean |
| product | 925 892 608 | 925 892 608 | `ext4` |
| odm | 556 793 856 | 556 793 856 | `ext4` |
| super.img | 274 432 | — | metadata-only super image (logical partitions created via `dynamic_partitions_op_list`) |

`META-INF/com/google/android/updater-script` asserts `ro.product.device == "rk3399"`, patches the four
dynamic partitions, then writes `boot.img`, `trust.img`, `uboot.img`, `dtbo.img`, wipes
`/dev/block/by-name/security`, and calls the custom edify function `write_raw_loader_image()` using
`/tmp/RKLoader.bin`. The custom `update-binary` is a 3.1 MB statically-linked ARM aarch64 ELF
("for Android 29") that also implements `block_image_recover` / `block_image_verify` and
`do_rk_firmware_upgrade()` (Rockchip loader/upgrade mode).

## boot.img

```
Android bootimg, header version 2, page size 2048
kernel 25 557 000 B   load 0x10008000   second(bootloader stage2) 906 752 B  load 0x10f00000
ramdisk 1 574 356 B   load 0x11000000   dtb size 0 (DTB supplied by U-Boot; dtbo.img is a 803 B stub)
os version 10.0.0, os patch level 2020-05
cmdline: console=ttyFIQ0 androidboot.baseband=N/A androidboot.wificountrycode=US
         androidboot.veritymode=enforcing androidboot.hardware=rk30board androidboot.console=ttyFIQ0
         androidboot.verifiedbootstate=orange firmware_class.path=/vendor/etc/firmware init=/init
         rootwait ro dwc_otg.speed=0 loop.max_part=7 androidboot.selinux=permissive buildvariant=userdebug
```

Kernel: `Linux version 4.19.111+ (rocky@r940) (Linaro GCC 6.3-2017.05) #2929 SMP PREEMPT Tue Mar 2 2021`,
`4.19.111+ SMP preempt mod_unload modversions aarch64`. No IKCONFIG embedded → kernel config cannot be
read from the binary (must be read from the running unit or rebuilt).

Kernel-side capabilities visible in strings: Rockchip **ion** (`ion: failed to create debugfs heaps
directory`), **RGA** 2D accelerator, **IEP**, NTFS/exFAT support, overlayfs, dm-crypt, f2fs.

Out-of-tree head-unit driver (compiled into the kernel) — creates the device nodes the apps use:

```
mtc-init mtc-pre mtc-io mtc-key mtc-car mtc-av mtc-cvbs mtc-cvbs2 mtc-dab mtc-radio mtc-vs mtc-dvd
canbus_rsp cfg_canbus ctl_canbus_list ctl_canbus_menu_list  dMTC_KERNEL_VER  "--mtc adv7181 detected"
mtc,amp_en mtc,bl_en mtc,bl_en_ex   (AMP / backlight enable)
```

`/vendor/lib/modules` contains `mali_kbase.ko` (Mali-T620 Midgard DRM/Kbase, 18 MB) plus Realtek/
Broadcom/SPRD WiFi/BT `.ko` blobs (`bcmdhd.ko`, `8188eu`, `8189fs`, `8723bu`, `8821cs/cu`, `8822bu/cs`,
`sprdwl_ng`) — loaded by `/vendor/bin/init.insmod.sh` from `/vendor/etc/init.insmod.cfg`.

## Vendor partition (`analysis/vendor_files.txt`, 1387 files)

Treble vendor: `target-level 4`, `ro.vndk.version=29`, all HALs HIDL.

| HAL (fqname) | impl / service | notes |
|---|---|---|
| `android.hardware.audio@5.0` + `audio.effect@5.0` | `android.hardware.audio@2.0-service` + `lib/hw/android.hardware.audio@5.0-impl.so` | impl chain loads legacy `lib/hw/audio.primary.rk30board.so` via `libhardware_legacy.so`, `libtinyalsa`, `libaudioroute`, `libspeexresampler` |
| `graphics.composer@2.1` | `hwcomposer.rk30board.so` (400 KB blob) | needs `libhwc2on1adapter.so` + `libhwc2onfbadapter.so` |
| `graphics.allocator@2.0` / `mapper@2.0(+3.0)` | `gralloc.rk30board.so` (24 KB) | needs `libgralloc_drm.so` (DRM/KMS based allocator), `libGLESv1_CM` |
| `camera.provider@2.4/2.5` (+external/legacy) | `camera.rk30board.so` (1.4 MB) + huge `rkisp1` sensor profile XMLs | needs `librkisp`, `libvpu`, `librga`, `libjpeghwenc`, `libchrome`, `libsync_vendor`, `libnativewindow`, `libui` |
| `vulkan.rk30board.so` | 11 MB Mali blob | `ro.cpvulkan.version=4198400`, `ro.hardware.egl=mali`, `ro.hwui.use_vulkan=` (empty) |
| `wifi@1.0`, `wifi.supplicant`, `wifi.hostapd` | `android.hardware.wifi@1.0-service` (427 KB), wpa_supplicant, hostapd | `wifi.interface=wlan0`, Realtek/Broadcom blobs |
| `bluetooth@1.0` | `android.hardware.bluetooth@1.0-service` | UART BT: `vendor.bluetooth.channel=/dev/ttyS1`, `/dev/rtkbt_dev`, `/dev/rtk_btusb`, rfkill0 |
| `gnss@1.0` + `gps.default.so` | UART GPS `vendor.gps.channel=/dev/ttyS0`, `/system/bin/glgps` |
| `sensors@1.0` | `sensors.rk30board.so` |
| `keymaster@3.0`, `gatekeeper@1.0`, `weaver@1.0`, `health@2.0`, `power@1.0`, `light@2.0`, `memtrack@1.0`, `drm@1.0/1.2`, `cas@1.1`, `media.omx@1.0`, `rild` + `radio@1.0`/`radio.deprecated`, `usb@1.1` + `usb.gadget@1.0` | |
| custom: `android.hardware.mtc.mfi@1.0` (`mfi.default.so`), `rockchip.hardware.rockit.hw@1.0` (`IRockitHwService`) | Rockchip/HCT specific |

Vendor init/config: `fstab.rk30board` (dynamic partitions `logical,first_stage_mount`, `/data` F2FS
with `checkpoint=fs`, zram 50%, sdcard1/sdcard2 via `fe320000/fe310000.dwmmc`), `init.rk30board.rc`
(12 KB), `init.rockchip.rc`, `init.connectivity.rc`, `init.mount_all.rc`, `init.optee.rc`,
`vendor_sepolicy.cil` (177 KB) + `plat_sepolicy_vers.txt`.

## System partition (3195 files)

Android 10 `rockchip/rk3399/rk3399:10/QQ2A.200305.004.A1/hct203111747:userdebug/test-keys`,
security patch 2020-05-05, `min_supported_target_sdk=23`.

Root-level `/init.hct.rc` (HCT head-unit glue) declares the whole control plane:

- device nodes chmod `0666/0777`: `/dev/mtc-car`, `/dev/mtc-av`, `/dev/mtc-dab`, `/dev/mtc-cvbs`,
  `/dev/mtc-cvbs2`, `/dev/ttyS0..ttyS4`, `/dev/ttyV0..ttyV5`, `/dev/goc_serial`
- Bluetooth/CarPlay bridge daemons on UART (`bt.goc.type=…`): `gocsdk`, `gocsdk5/6/8`, `gocsdkrf210`,
  `sdsdk`, `sdsdk6/936/816/835/936/968`, `blueletd` (IVT), `brlinktd`, `fscsdkbw123` — all `user root`
  `group root`, `seclabel u:r:shell:s0`
- CarPlay/Android Auto: `z-link.sh`, `sd-link.sh`, `usbmuxd` (`start_usbmuxd.sh`), `adbec`
  (`adb-ec-server.sh`), all root/shell-labelled, started on `sys.boot_completed=1`
- CAN: `hctcanbusservice` (root, class core, started by `hct.canbus.service=1`)
- misc root scripts: `hctlog.sh`, `vendingpatch.sh`, `sd-reverse.sh`, `ethtether.sh` (NAT tethering),
  ADB-over-TCP via `sys.hct.wifi=adb`, world-writable `/mnt/oem`, `/etc/bluesoleil`, `/data/goc`
- HCT app set (`/system/app`): `HCT4Radio`, `HCT4Music`, `HCT4Movie`, `HCT4BlueTooth`, `HCT4BtMusic`,
  `HCT4FileBrowser`, `HCT4UsbIpod`, `HCT8AmpSetup`, `HCTAudioPreview`, `HCTAvin`, `HCTBackView`,
  `HCTFrontView`, `HCTCarCD`, `HCTCarRecoder`, `HCTCarTouch`, `HCTControlInfo`, `HCTControlSettings`,
  `HCTFactorySettings`, `HCTDVR_IR`, `HCTDvd`, `HCTNaviSettings`, `HCTExtMusic/ExtMovie`,
  `HCTCivicusbipod`, `HCTExactCalculator10`, `HCTApkInstall`, … plus launcher/settings replacements
- vendor build props of interest: `ro.product.dspmode=HCTDSP`, `ro.product.gpsmix=2`,
  `ro.product.drvingsafe=1`, `ro.target.product=tablet`, `ro.sf.lcd_density=240`,
  `sys.hwc.device.primary=DSI`, `sys.hwc.device.extend=HDMI-A,DP`, `ro.apex.updatable=true`,
  `persist.sys.zram_enabled=1`, `ro.product.sdcardswap=true`, `ro.product.ota.host=ota.hal9k.ru:2300`

## ROM identity

Base firmware = **HCT4 (HengChangTong H660000, PX6)**. The customisation is **Hal9k Mod** (build id
`eng.hct2…`, OTA host `ota.hal9k.ru`, Magisk installed at `/vendor/magisk`, `ro.product.version=5.0.0`
= "Hal9k Mod v5"). Hal9k ships Android 11 modules for PX6; Malaysk ships PX6 Android 11 ROMs too —
so Android 11 is already community-proven on this platform, Android 12+ is not.

## Security findings (see README for the list)

`androidboot.selinux=permissive`; userdebug/test-keys; Magisk in vendor; ~12 init services running as
root under `u:r:shell:s0`; world-writable UART and MTC device nodes; ADB over TCP enabled on boot;
NAT tethering service; OTA pulled from a third-party host.
