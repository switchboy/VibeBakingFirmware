# What the head unit itself told us

Source: `incoming/probe-20261104-1353.md` — the unit running Termux (`com.termux`, GitHub arm64 build),
non-root, report uploaded over LAN. Kernel config recovered from the embedded gzip blob into
`analysis/hu_kernel_config.txt` (1686 config options), vendor manifest into
`analysis/hu_vendor_manifest.xml`.

## Identity of the firmware actually installed

| property | value |
|---|---|
| fingerprint | `rockchip/rk3399/rk3399:10/QQ2A.200305.004.A1/eng.hct2.20220412.155213:userdebug/test-keys` |
| Android | 10 (SDK 29), security patch **2020-05-05** |
| build type | **userdebug / test-keys** (an engineering build, dated 2022-04-12) |
| hardware | `rk30board`, platform `rk3399`, model `PX6` |
| kernel | `4.19.111+` #277, built 2022-03-31 by `chun@r930`, Linaro GCC 6.3-2017.05 |

This is the Daisaita/Daitsun build of the HCT4 base — same Android version and same vendor HAL
surface as the reference payload, but **not** the Hal9k Mod: no `/vendor/magisk`, no `eng.hct`
root-shell shortcuts, and it ships Google apps (Play Store, YouTube, Gmail, Search, Plexamp,
Firefox, Waze, Telenav launcher, Huawei HiCar, `com.andrerinas.headunitrevived`).

## Storage layout (measured without root, from sysfs)

eMMC `mmcblk2` = **62,813,896,704 bytes** (58.5 GiB):

| partition | block | bytes | note |
|---|---|---|---|
| uboot / trust / dtb / dtbo / misc / security | p1-p5, p10 | 4,194,304 each | bootloader + DT |
| vbmeta | p6 | 1,048,576 | AVB metadata |
| boot | p7 | 33,554,432 | kernel + ramdisk |
| recovery | p8 | 100,663,296 | recovery image |
| backup | p9 | 117,440,512 | spare |
| metadata | p12 | 16,777,216 | |
| frp | p13 | 524,288 | factory reset protection |
| **super** | p14 | **3,263,168,512** | dynamic group, 3.04 GiB |
| **userdata** | p15 | **58,844,495,360** | f2fs, 54.8 GiB — **only 5.4 GiB used** |

Inside `super` right now (`dm-*` sizes / `df`): system 1,075,912,704 + product 967,712,768 +
vendor 298,737,664 + odm 184,688,640 = **2,527,051,776 used**, leaving roughly **730 MB free**
(super metadata header eats ~4 MB). APEX images live inside the system image, not as extra group
space.

**Consequence for Android 14:** a LineageOS 21 build is roughly system 1.1-1.3 GiB +
system_ext 0.5-0.6 GiB + product 0.9-1.2 GiB + vendor 0.5-0.9 GiB + odm 0.18 GiB ≈ **3.0-3.2 GiB**.
That only fits in a 3.04 GiB `super` if we strip Google apps and preinstalled apps hard, and it
leaves no room for an OTA snapshot. So the partition layout is a real decision (see `agentPlan.md`
D8): either trim aggressively and flash through recovery (direct writes, no snapshot), or
repartition — shrinking `userdata` by a few GiB gives `super` 5-6 GiB and makes everything
comfortable. Repartitioning means flashing the GPT plus every partition, so a complete backup of
boot/uboot/trust/dtb/dtbo/vbmeta/recovery/super and the 5.4 GiB of userdata content is mandatory
first.

## Kernel configuration (`analysis/hu_kernel_config.txt`)

- `CONFIG_IKCONFIG=y` + `CONFIG_IKCONFIG_PROC=y` — `/proc/config.gz` exists, so the exact shipped
  config is known. This is the base for a rebuilt kernel.
- `CONFIG_SECURITY_SELINUX=y`, `CONFIG_SECURITY_SELINUX_DEVELOP=y`,
  **`# CONFIG_SECURITY_SELINUX_BOOTPARAM is not set`** — `androidboot.selinux=permissive` on the
  kernel command line does *not* work on this kernel. SELinux is enforcing (the app sandbox cannot
  even list `/system/bin`). With root you can still flip `/sys/fs/selinux/enforce` to 0 during
  bring-up, because `DEVELOP` is enabled — handy for debugging our sepolicy, never at release.
- `CONFIG_AUDITSYSCALL` off, `CONFIG_SECURITY_PERF_EVENTS_RESTRICT=y`, `LSM_MMAP_MIN_ADDR=4096`.
- WiFi: `CONFIG_CFG80211=y`, `CONFIG_MAC80211=y`, `# CONFIG_CFG80211_WEXT is not set` (wpa_supplicant
  must use nl80211), `# CONFIG_MAC80211_RC_MINSTREL_VHT is not set`,
  `CONFIG_CFG80211_REQUIRE_SIGNED_REGDB=y` + `USE_KERNEL_REGDB_KEYS=y` → channels are gated by the
  kernel regulatory database and country code.
- No `CONFIG_MTC*`/`MICRONTEK`/`ADV7181` options: the head-unit driver stack (CAN/MTC, AV-in,
  tuner) is out-of-tree and built into the vendor kernel tree, not selectable from this config —
  consistent with earlier payload analysis, so the kernel source is still the missing piece.
- `mali_kbase.ko` plus WiFi `.ko`s ship as modules in `/vendor/lib/modules`.

## VINTF on the live unit vs the reference payload

`analysis/hu_vendor_manifest.xml` is a strict subset of the reference manifest — same HALs,
same versions, `target-level="4"`, but **without** `android.hardware.cas@1.1`,
`android.hardware.weaver@1.0`, and `rockchip.hardware.rockit.hw@1.0` (their binaries are still
present in `/vendor/bin/hw`, just not declared). Everything else matches: audio 5.0, bluetooth 1.0,
camera.provider 2.5, drm 1.0/1.2, gatekeeper 1.0, gnss 1.0, allocator 2.0, composer 2.1, mapper 2.1,
health 2.0, **keymaster 3.0**, light 2.0, omx 1.0, memtrack 1.0, **mtc.mfi 1.0**, power 1.0,
radio 1.0 + deprecated, sensors 1.0, soundtrigger, usb 1.1 + gadget 1.0, wifi 1.0 + hostapd +
supplicant. So the Android-14 gap list from `docs/feasibility.md` (KeyMint service, vendor-local
`libhardware_legacy`, HWC2-on-1 adapters, `libchrome`, `libion` shim) holds for the unit as well.

The next report adds `sha256` for every vendor HAL binary/library/module, so we can prove the live
vendor equals the reference vendor blob-for-blob.

## Head-unit control plane

- `ro.factory.hasGPS=true`, GPS on `/dev/ttyS0`, BT on `/dev/ttyS1`, `ro.rk.bt_enable=true`.
- `bt.goc.type=11` and `/dev/goc_serial` exist → GOC Bluetooth bridge (no Realtek BT nodes:
  `/dev/rtkbt_dev` / `/dev/rtk_btusb` are absent, but `persist.bluetooth.rtkcoex=true` for the WiFi chip).
- `carplay.type=1`, `ro.product.sdcardswap=false`, DSP props `null` (no DSP amp fitted).
- Device nodes present: `/dev/mtc-av`, `/dev/mtc-car`, `/dev/mtc-cvbs`, `/dev/mtc-cvbs2`,
  `/dev/mtc-dab`, `/dev/ttyV0..7`, `/dev/ttyS0/1/4`. All labelled `u:object_r:device:s0` by the
  stock policy — our sepolicy needs to keep those readable/writable for the HCT apps.
- `/vendor/etc/init/hw/init.rk30board.rc` readable: imports `init.rockchip.rc`,
  `init.connectivity.rc`, `init.box.samba.rc`, `init.car.rc`, `init.optee.rc`; touches OPTEE/tee
  nodes, `glgps`, `/sys/class/display/HDMI/color`, and mentions **AP6476** as the GPS module.
- `/init.hct.rc` is not readable without root — the next report grabs it if `/system/xbin/su` works.

## WiFi: this is a USB Realtek dongle, and it is 2.4 GHz hardware

`wlan0` and `p2p0` are not SDIO/eMMC devices — they live under
`/sys/devices/platform/fe3c0000.usb/usb1/1-1/1-1.4/1-1.4:1.0/net/`, i.e. a **USB** WiFi adapter:

```
modalias: usb:v0BDAp0179d0000   → Realtek VID 0x0BDA, PID 0x0179 = RTL8188E family (2.4 GHz only)
```

The vendor ships drivers for `8188eu`, `8189fs`, `8723bu`, `8821cs`, `8821cu`, `8822bu`,
`8822cs`, `bcmdhd`, `aic8800`, `sprdwl_ng` — **`8821cu.ko` and `8822bu.ko` are dual-band (5 GHz)
USB drivers already in the shipped vendor**. So wireless CarPlay/AA (5 GHz is required on modern
phones) is a *hardware* limit, not a firmware one: swapping that USB WiFi module for a dual-band
Realtek module the kernel already supports (8821CU/8822BU) is the route, and it needs no kernel
rebuild — only `init.connectivity.rc`/module loading and a correct `iw reg` country code. `iw` was
not on PATH; the updated probe now uses `/system/bin/iw` and reports the bound driver name, so we
will confirm the chip exactly and see which frequencies the regdb allows.

## Privileges and root

- Non-root as delivered (`uid=10147`, `u:r:untrusted_app_27`). `dumpsys`, `toybox`, `lsmod`,
  `mount`, `service`, `getenforce`, `iw` were "not found" because Termux's PATH had no `/system/bin`
  — fixed in `scripts/probe.sh` (PATH now includes `/system/bin:/system/xbin:/vendor/bin`).
- **`/system/xbin/su` exists** on this ROM (Termux's stub shadows it). The probe now calls it by
  absolute path with a timeout guard; if it grants root, the report gains `/proc/cmdline`, `lsmod`,
  `dmesg`, `ls -lZ /dev/mtc*`, `/init.hct.rc` and exact `blockdev` sizes.
- `/system/bin` cannot be listed by the app sandbox → consistent with an **enforcing** policy
  (the reference firmware's permissive boot flag is not active on this build, and the kernel
  cannot honour it anyway).

## Open questions for the owner

1. Do you have a saved copy of the zip currently installed (Daisaita/Daitsun)? If not, the next
   report can dump the current images over LAN (`dd` of boot/recovery/super needs root).
2. Does `/system/xbin/su` prompt for a password, or does it give a root shell outright? The probe
   will show which.
3. Wireless CarPlay/AA: accept swapping the USB WiFi module for a dual-band one, or keep wired
   CarPlay/AA only?
