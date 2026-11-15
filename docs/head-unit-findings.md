# What the head unit itself told us

Source: `incoming/probe-20261104-1353.md` — the unit running Termux (`com.termux`, GitHub arm64 build),
non-root, report uploaded over LAN. Kernel config recovered from the embedded gzip blob into
`analysis/hu_kernel_config.txt` (1686 config options), vendor manifest into
`analysis/hu_vendor_manifest.xml`. Later facts come from the root probe `incoming/probe-20261113-2016.md`
and the RAMoops record `analysis/panic-20261113-2003-ramoops.txt`.

## Identity of the firmware actually installed

Measured Nov 13 20:16 CET as root (`adb root`, `uid=0` / `u:r:su:s0`, SELinux **Permissive**), serial
`D5362B7F96DAB676` (`incoming/probe-20261113-2016.md`). It differs from what the Nov 4/5 probes reported,
because the owner re-flashed the OEM package via the bootSD card (**D39**):

| property | value now | value on Nov 4/5 (before the re-flash) |
|---|---|---|
| fingerprint | `rockchip/rk3399/rk3399:10/QQ2A.200305.004.A1/eng.hct2.20250401.152740:userdebug/release-keys` | `...eng.hct2.20220412.155213:userdebug/test-keys` |
| Android | 10 (SDK 29), patch 2020-05-05 | same |
| kernel | `4.19.111+` **#190**, built Fri Jul 5 2024 by `root@meng_book2`, machine `Rockchip RK3399 HCT Board` | `4.19.111+` **#277**, built 2022-03-31 by `chun@r930` |
| root | `adb root` gives uid 0 with `u:r:su:s0`; `/system/xbin/su` present, no magisk | su present, app sandbox could not list `/system/bin` |
| boot reason | `kernel_panic,fatal_exception` (see below) | - |

That kernel build is the one inside `diatsia fw/update(1).zip` (the Daisaita/Daitsun Android 10 package,
`docs/decisions.md` D39/D40), so the unit runs the OEM Android 10 firmware, not our payload. The vendor
surface is byte-for-byte that reference - `analysis/vendor_blob_live_vs_oem_a10.tsv`, 126/126 identical.
Hardware identity is unchanged across both builds: `rk30board`, platform `rk3399`, model `PX6`.

## Input devices, and the defect that panicked the unit on Nov 13

Four input devices register at boot: `mtc-key` (`/devices/platform/mtc-car/input/input0`), `goodix-ts`
(`ff3d0000.i2c/i2c-4/4-0014/input/input1`), `gpio-keys`, plus the HID/virtual ones loaded later
(`sd_user_hid.ko`, `virtual_tp.ko`). The full `/proc/bus/input/devices` dump is not in the probe report -
it was read live over `adb root` on Nov 13 and needs re-reading when the unit is reachable.

What that read showed for the touchscreen is the signature of a driver that stores its identity strings in
memory it has already thrown away:

```
P: Phys=<raw non-string bytes>     U: Uniq= (empty)
S: Vendor=dead Product=beef Version=28bb
```

`dead/beef/28bb` = `0xDEAD/0xBEEF/10427`, hardcoded in Rockchip's `drivers/input/touchscreen/gt9xx/gt9xx.c`;
the garbage `Phys` is the same buffer. The driver declares `s8 phys[32];` **on the stack**, `sprintf`s
`"input/ts"` into it and assigns `ts->input_dev->phys = phys` - the `devm`-allocated `input_dev` outlives
the function, so `phys` is a dangling pointer into a dead kernel stack frame. Mainline's
`drivers/input/touchscreen/goodix.c` uses string literals instead (`input->phys = "input/ts"`), so this is
vendor-only; it is present in `rockchip-linux/kernel` `develop-4.4`, `develop-4.19`, `develop-6.1` and
`master`. The driver is built into the kernel (no `gt9xx.ko`), so it cannot be fixed by swapping a module.

That bug is what killed the unit at **20:03 CET on Nov 13**: `ro.boot.bootreason =
kernel_panic,fatal_exception`. The framework restarted (system_server pid 466 died, zygote killed, new
system_server pid 3989), its new `InputReader` thread re-opened `/dev/input/event1`, the `EVIOCGPHYS`
ioctl ran `strlen()` on the freed stack page, and the kernel died with
`Unable to handle kernel paging request at ffffff8009d73c70`, `pc __pi_strlen+0x60`, trace
`evdev_ioctl_handler+0x1174`. The record is committed as `analysis/panic-20261113-2003-ramoops.txt`; the
full decoding is `docs/findings.md` ("The Nov 13 20:03 kernel panic"). Touch works normally after the
reboot - the fault only fires when an input device is *re-opened* after that page is unmapped, which is why
it survived the Nov 11/12 sessions.

**`vendor.sensors-hal-1-0` exits with status 255 and init loops on it.** In the panic record it exits twice
in one boot (pid 290 at t=3325.637752, pid 3818 at t=3333.865666, uid 1000), each time followed by
`init: starting service 'vendor.sensors-hal-1-0'...` and a `healthd: battery none chg=` line. Whether that
is *why* system_server died is unproven - logcat is not in pstore. It is on the owner's criteria path
(sensors/GPS behaviour), so the next reachable session should grab `logcat -d` around a crash and the
HAL's own stderr.

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

The Nov 13 root probe read `/proc/config.gz` from the kernel actually running now (`4.19.111+ #190`) and
that dump is committed as `analysis/hu_kernel_config_live-20261113.txt` — 5774 lines, **byte-identical** to
`analysis/daisaita_a10_kernel_config.txt` (the config shipped in the OEM Android 10 package). The Nov 4
config (`analysis/hu_kernel_config.txt`, from the #277 build) differs from it: `CONFIG_FW_LOADER_USER_HELPER
_FALLBACK=y` instead of unset, and `CONFIG_RTL8188FU=m` + `CONFIG_RTL8733BS=m` present there but absent in
the build the unit runs today. So the reference config for the current kernel is the Daisaita A10 one, and
everything below holds for both builds.

- `CONFIG_IKCONFIG=y` + `CONFIG_IKCONFIG_PROC=y` — `/proc/config.gz` exists, so the exact shipped
  config is known. This is the base for a rebuilt kernel.
- `CONFIG_SECURITY_SELINUX=y`, `CONFIG_SECURITY_SELINUX_DEVELOP=y`,
  **`# CONFIG_SECURITY_SELINUX_BOOTPARAM is not set`** — `androidboot.selinux=permissive` on the
  kernel command line does *not* work on this kernel. But the running state is **Permissive** (the
  latest probe's `getenforce` says so; the BSP init flips it after boot). The app sandbox still
  cannot list `/system/bin`, and with root you can toggle `/sys/fs/selinux/enforce` during bring-up,
  because `DEVELOP` is enabled — handy for debugging our sepolicy, never at release.
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
rebuild — only `init.connectivity.rc`/module loading and a correct `iw reg` country code.

Measured Nov 13 with root (`iw` at `/system/bin/iw`, dongle on USB port `1-1.4`, driver `rtl8188eu`,
`wifi_chip_type = rtl8188eu` parsed from the DT at boot):

* `iw dev` — `wlan0` joined `ssid hoefijzer`, `p2p0` on a second wiphy; `iw list` offers **Band 1 only**
  (channels 1-13 at 20.0 dBm, ch 14 disabled, HT20/HT40, max RX 150 Mbps). No 5 GHz band exists on this
  chip, which confirms the hardware limit above rather than contradicting it.
* `iw reg get` — **`country 00: DFS-UNSET`**. The country code has never been set, so the 2.4 GHz channels
  run under the world-regulatory default, and the kernel gates them via
  `CONFIG_CFG80211_REQUIRE_SIGNED_REGDB=y` + `CONFIG_CFG80211_USE_KERNEL_REGDB_KEYS=y` (see the
  kernel-configuration section). Setting a real country code was considered Nov 15 and **declined for the stock firmware** (**D45**):
  the world default already allows ch 1-13 at 20 dBm, and this chip has no 5 GHz band to unlock. Our
  Android 14 vendor tree does set one - `device/rk3399-px6-hct4/configs/init.hu.rc` reacts to
  `ro.boot.wificountrycode=NL` with `iw reg set NL`, because the vendor CN map marks ch 12/13 "no IR"
  (visible in the Nov 13 `iw list` output).
* Live-only, read over `adb root` Nov 13 and **not** captured in the probe report: link quality ~99/99 at
  −44 dBm. Re-measure with `iw dev wlan0 link` on the next reachable session.
* The loaded driver is Rockchip's fork and it taints the kernel: a `WARNING` at
  `drivers/net/wireless/rockchip_wlan/rtl8188eu/hal/hal_com.c:12050 rtw_lps_state_chk+0x58/0x70 [8188eu]`
  fires when power-save leave times out (`rtw_warn_on(1)` after `PS_MODE_ACTIVE check failed`). Harmless,
  but it is why the Nov 13 panic record says `Tainted: G W` — details in `docs/findings.md`.

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

1. ~~Do you have a saved copy of the zip currently installed?~~ Answered Nov 13: yes —
   `diatsia fw/update(1).zip`, and the running fingerprint/kernel match it
   (`eng.hct2.20250401.152740`, `#190`). A fresh `scripts/pull_stock_backup.sh` refresh (**D40**) is still
   owed once the unit is reachable, since the Nov 11 manifest's `boot.bin`/`super.bin` hashes are now stale.
2. ~~Does `/system/xbin/su` prompt for a password?~~ Answered Nov 13: root works over TCP adb
   (`adb root` → `uid=0`, `u:r:su:s0`), so `su` is not needed for our probing (**D28**).
3. Wireless CarPlay/AA: accept swapping the USB WiFi module for a dual-band one, or keep wired
   CarPlay/AA only? (`iw list` confirms the present chip has no 5 GHz band at all.)
4. ~~The kernel panic: which route?~~ Answered Nov 15 (**D45**): **accept the risk** - the OEM kernel stays
   as shipped, no rebuild. The bug is one line in vendor `gt9xx.c` but the driver is built into the kernel,
   and the vendor kernel source is not in hand. It only bites on a framework restart, so the criteria
   (touch/buttons/CANBUS) survive normal use. Reopens if restarts prove routine; then the routes are
   vendor-source rebuild with the literal fix, or removing the trigger.
5. `vendor.sensors-hal-1-0` exits with status 255 and init loops on it. It is the nearest candidate for
   the framework restart that triggered the Nov 13 panic, and sensors are part of the criteria path. Next
   reachable session: capture `logcat -d` plus the HAL's stderr around a crash. This is the measurement
   D45 depends on staying acceptable.
6. Posting upstream: **declined Nov 15** - candidates 21/22 stay draft-only in `docs/upstream.md`, nothing
   posted. If you ever want it public, the draft is written to be pasted as-is.


## Reference firmware set (Daisaita, downloaded by the owner 2026-11-04)

`diatsia fw/update(1).zip` = Android 10 full package (build `eng.hct2.20250401.152740`, patch 2020-05-05,
ships boot/uboot/trust/logo + compatibility.zip). `diatsia fw/update.zip` = Android 11 full package
(`RQ3A.210705.001`, patch 2021-07-05). Both are BLOCK-type packages that only patch the dynamic
partitions through update_engine (`update_dynamic_partitions` + `map_partition`), so they cannot
rewrite the GPT - that matters for M2b (see docs/plan.md).

| | unit right now | Daisaita A10 zip | Daisaita A11 zip |
|---|---|---|---|
| kernel | 4.19.111+ **#277** | 4.19.111+ **#190** (2024-07-05) | 4.19.193 **#24** |
| vendor HALs matching the unit | - | **99 identical / 15 differ / 0 extra** | 1 identical / 68 differ |
| graphics allocator/mapper | 2.0 / 2.1 (ION, needs libion) | 2.0 / 2.1 (ION) | **4.0 / 4.0-midgard (dmabuf)** |
| audio | 5.0 | 5.0 | **6.0** |
| keymaster | 3.0 | 3.0 | **4.0 (optee service)** + gatekeeper optee |
| health / drm / cas | 1.2 / 1.0 / undeclared | 1.2 / 1.0 / 1.1 fragment | **2.1 / 1.3 / 1.2**, wifi+hostapd, power via **AIDL** |
| manifest format / target-level | 1.0 / **4** | 1.0 / 4 | 2.0 / **5** |
| dynamic group max | super is 3,263,168,512 B | 3,258,974,208 B (fits) | **4,890,558,464 B (does not fit - owner's flash warning)** |

So the installed firmware is a Daisaita Android 10 build, and the Android 11 package proves a >3 GiB
super group works on this SoC family - it just needs the GPT grown first (D8/M2b).
