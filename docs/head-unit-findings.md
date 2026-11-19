# What the head unit itself told us

Source: `incoming/probe-20261104-1353.md` — the unit running Termux (`com.termux`, GitHub arm64 build),
non-root, report uploaded over LAN. Kernel config recovered from the embedded gzip blob into
`analysis/hu_kernel_config.txt` (1686 config options), vendor manifest into
`analysis/hu_vendor_manifest.xml`. Later facts come from the root probe `incoming/probe-20261113-2016.md`
and the RAMoops record `analysis/panic-20261113-2003-ramoops.txt`.

## Current state: unreachable since Nov 19 23:35 CET (re-probed Nov 20 00:06 CET, still silent)

L2 (**D62**) was written to `boot` at 23:32-23:34 CET and the unit stopped answering after the reboot: TCP adb on
`192.168.1.120:5555` fails with "No route to host", `ping` loses every packet, and eight further probes over ten
minutes found nothing. Partition 7 holds `eaf9b7de30f9…` (the L2 image), not the stock capture; `misc` still
hashes `909bdd979111…` exactly as captured, `super` still `535dac26946d…`, `/data` untouched, and the boot chain
partitions untouched. The likely physical state is the stock recovery partition, reached by
`androidboot.init_fatal_reboot_target=recovery` (**D74**) - which runs `adbd` over USB only, so our TCP route is
gone. The console record of the failed boot is still in RAM until a cold power cycle erases it. Restoring is
owner-side: the bootSD card (**D39**) or USB adb inside recovery, per `docs/flash.md`, "L2 ran Nov 19 23:35 CET
and the unit went silent". Nothing more may be written until the unit answers again (**D75**).

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
it was read live over `adb root` on Nov 13, and re-read live on Nov 17 19:21 CET: the three platform
devices are still there - `mtc-key` -> `event0`, `goodix-ts` -> `event1`, `gpio-keys` -> `event2`, each
with handlers `eventN cpufreq` - and the HID/virtual ones (`sd_user_hid.ko`, `virtual_tp.ko`) are absent
that boot because those modules are not loaded (`lsmod` = `usb_f_iap2`, `8188eu`, `aic8800_bsp` only).
Touch is `event1`.

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
is *why* system_server died is unproven - logcat is not in pstore. Cause measured Nov 17 instead: the
HAL is alive (pid 292) and loops every ~27 s with `Couldn't open /dev/mma8452_daemon (No such file or
directory)` followed by `fail to perform GSENSOR_IOCTL_APP_SET_RATE, result = -1, error is 'Bad file
descriptor'`. `/dev/mma8452_daemon` is absent even though the kernel has the driver built in
(`CONFIG_SENSOR_DEVICE=y`, `CONFIG_GSENSOR_DEVICE=y`, `CONFIG_GS_MMA8452=y`), so the accelerometer
driver never created its node. Sensors are not an owner criterion, and in that session's window the HAL
did not exit - which weakens the "sensors HAL dies and cascades the restart" hypothesis behind D45.

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
- Serial identity disagrees (Nov 17): `ro.serialno` = `D5362B7F96DAB676`, `ro.boot.serialno` =
  `c3bc6b060ec025bb`. The OEM init chain overrides `ro.serialno` after boot; our payload keeps the same
  source, so serial-keyed apps still see `D5362B7F96DAB676`.

## TCP adb is permanent (Nov 17, owner directive)

`persist.internet_adb_enable=1` now lives in `/data/property/persistent_properties`, and
`/vendor/etc/init/hw/init.rk30board.rc:250-257` reacts to it with `setprop service.adb.tcp.port 5555` +
`restart adbd`. Measured by rebooting the unit: 1 min later `persist.internet_adb_enable=1`,
`service.adb.tcp.port=5555`, `adbd` listening, and `adb root` worked with **no RSA dialog** - so TCP adb
is available on every boot while `/data` survives. The prop lives in `/data`, so a factory reset (or our
own install route, which wipes `/data` per D10) kills it and `adbon` is needed again; the off switch is
`setprop persist.internet_adb_enable 0`.

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
* Live link quality, measured Nov 17 19:21 with `iw dev wlan0 link`: connected to `4c:ed:fb:a5:08:01`,
   SSID `hoefijzer`, `freq 2417`, `signal -56 dBm`, `tx bitrate 150.0 MBit/s`. The Nov 13 "~99/99 at
   -44 dBm" reading was never captured in a report, so the Nov 17 figure is the one on record.
* **Wireless Android Auto takes the radio.** The owner started Android Auto mid-session and WiFi dropped
   (`ping` -> Destination Host Unreachable), with **no kernel panic**. The RTL8188EU is a single 2.4 GHz
   radio, so wireless AA and the LAN adb route cannot coexist - probing pauses while AA runs.
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

1. ~~Do you have a saved copy of the zip currently installed?~~ Answered Nov 13: yes -
   `diatsia fw/update(1).zip`, and the running fingerprint/kernel match it
   (`eng.hct2.20250401.152740`, `#190`). The refresh (**D40**) ran Nov 17: `a14-work/hu-stock-backup-refresh/`
   holds a byte-exact capture with a 13-file `MANIFEST.sha256`, and the Nov 11 `hu-stock-backup/` is
   untouched (its manifest still checks clean). What changed on the disk since Nov 11 is measured in
   `docs/findings.md`: boot's `second` stage blob, super's first 2 MiB metadata region, the update_engine
   `metadata` partition, and 20 bytes of version fields in the loader area - the boot chain's payloads
   and the backup GPT are identical. Partition 7's rollback image is now the refreshed `boot.bin`
   (`4121b58f7759`), see `docs/flash.md` "Rollback".
2. ~~Does `/system/xbin/su` prompt for a password?~~ Answered Nov 13: root works over TCP adb
   (`adb root` → `uid=0`, `u:r:su:s0`), so `su` is not needed for our probing (**D28**).
3. Wireless CarPlay/AA: accept swapping the USB WiFi module for a dual-band one, or keep wired
   CarPlay/AA only? (`iw list` confirms the present chip has no 5 GHz band at all.)
4. ~~The kernel panic: which route?~~ Answered Nov 15 (**D45**): **accept the risk** - the OEM kernel stays
   as shipped, no rebuild. The bug is one line in vendor `gt9xx.c` but the driver is built into the kernel,
   and the vendor kernel source is not in hand. It only bites on a framework restart, so the criteria
   (touch/buttons/CANBUS) survive normal use. Reopens if restarts prove routine; then the routes are
   vendor-source rebuild with the literal fix, or removing the trigger.
5. `vendor.sensors-hal-1-0` exits with status 255 and init loops on it. Measured Nov 17: the HAL stays
   running and loops on a missing `/dev/mma8452_daemon` (the built-in `CONFIG_GS_MMA8452` driver never
   created its node), and wireless Android Auto dropped WiFi with no panic at all. So the restart
   trigger behind D45 has not recurred. Sensors are not an owner criterion; if you ever want
   accelerometer data on our payload, that node is the thing to chase.
6. Posting upstream: **declined Nov 15** - candidates 21/22 stay draft-only in `docs/upstream.md`, nothing
   posted. If you ever want it public, the draft is written to be pasted as-is.
7. ~~GPS antenna~~ Answered Nov 17 (**D58**): GPS is post-boot work, not a flash criterion, so no
   antenna is needed to gate the write. The measurement to take once the unit runs our payload is a
   real fix plus a satellite list, and `tx` on `/dev/ttyS0` is the thing to watch (the stock HAL sent
   70 bytes in three minutes while the module streamed ~225 B/s).

8. ~~Warm-reset pstore probe (step P0, no write): may I run `scripts/pstore_probe.sh` with `HU_CONSENT=1` on the
   stock Android 10 unit?~~ Answered and executed Nov 19 19:32: **yes, P0 then L0** were approved together. The
   probe survived the warm reset - `console-ramoops-0` 97,430 B and `pmsg-ramoops-0` 262,132 B were there on the
   next boot, and the console record carried the entire previous boot including PID-1's own messages (**D69**).
   So a failed boot can be read, provided nothing else reads the record first and the reset is warm.
9. How did you enter the bootSD recovery last time - card inserted before power, or a button held? Is there any
   button or pin that reaches recovery at power-on without the card? That decides whether a dead boot can reach a
   reader at all.
10. Is the bootSD route always a cold power cycle (RAM lost), or can it be done from a warm reset?
11. Is a second SD card available for logging? Your 32 GB media card is never used as a log target. A FAT32 USB
    stick would also work (`CONFIG_USB_STORAGE=y`), though the ports are host-side.
12. ~~Permission for one new write surface: the `misc` partition (boot control block) so a failed boot can be
    sent into recovery instead of needing a card.~~ Answered Nov 19: **"Yes, misc allowed"** (**D71**). It still
    hashes `909bdd979111…` exactly as captured, because nothing has been written to it; the permission is held in
    reserve, since the ladder's reboot-target token uses `bootloader` and never writes the BCB. Every other
    boot-chain partition stays forbidden (**D18**/**D19**).
13. ~~Tonight's approvals: may I run **P0** ... and after that, **L0**?~~ Answered Nov 19: **P0 then L0**, both
    executed. P0 proved the console route (**D69**); L0 wrote `L0-stock.img` (33,554,432 B) as the whole
    partition, partition 7 went `0bd1cc806740…` -> `4121b58f7759…`, and Android 10 rebooted from our repack with
    WiFi up and a rendering panel (**D70**). The unit is adb-reachable and its boot partition is now byte-equal
    to your capture, so the rollback for any later rung is content it already boots from.
14. ~~UART listen-only probe: may I open the unit for a listen-only probe?~~ Answered Nov 19: **"Not yet"**, so
    **D63** stays parked, the case stays closed, and nothing is soldered. What that still costs us is u-boot's own
    stage - a boot that never reaches the kernel has no evidence at all, since the pstore console only starts at
    `console [pstore-1] enabled`.
15. **The unit is unreachable (Nov 19 23:35 CET onward). Please restore it, and tell me which route you used.**
    Partition 7 holds the L2 image `eaf9b7de30f9…`, so it will not boot Android 10 by itself. Either put your
    bootSD card in before power and install your own Android 10 package (**D39**), or, if it is sitting in
    recovery, connect a USB host directly and `dd` the stock `boot.bin` (`4121b58f7759…`, 33,554,432 B) onto
    partition 7 (**D74**). Tell me afterwards which happened, because a **cold power cycle erases the RAM
    records** - if you power-cycle, the console log of the failed boot is gone and L2's cause stays unknown.
    Also: after it boots again, is TCP adb still reachable without re-setting the property?


## Reference firmware set (Daisaita, downloaded by the owner 2026-11-04)

`diatsia fw/update(1).zip` = Android 10 full package (build `eng.hct2.20250401.152740`, patch 2020-05-05,
ships boot/uboot/trust/logo + compatibility.zip). `diatsia fw/update.zip` = Android 11 full package
(`RQ3A.210705.001`, patch 2021-07-05). Both are BLOCK-type packages that only patch the dynamic
partitions through update_engine (`update_dynamic_partitions` + `map_partition`), so they cannot
rewrite the GPT - that matters for M2b (see docs/plan.md).

| | unit right now | Daisaita A10 zip | Daisaita A11 zip |
|---|---|---|---|
| kernel | 4.19.111+ **#190** (the restored stock `boot.bin`, built Fri Jul 5 2024 by `root@meng_book2`) | 4.19.111+ **#190** (2024-07-05) | 4.19.193 **#24** |
| vendor HALs matching the unit | - | **99 identical / 15 differ / 0 extra** | 1 identical / 68 differ |
| graphics allocator/mapper | 2.0 / 2.1 (ION, needs libion) | 2.0 / 2.1 (ION) | **4.0 / 4.0-midgard (dmabuf)** |
| audio | 5.0 | 5.0 | **6.0** |
| keymaster | 3.0 | 3.0 | **4.0 (optee service)** + gatekeeper optee |
| health / drm / cas | 1.2 / 1.0 / undeclared | 1.2 / 1.0 / 1.1 fragment | **2.1 / 1.3 / 1.2**, wifi+hostapd, power via **AIDL** |
| manifest format / target-level | 1.0 / **4** | 1.0 / 4 | 2.0 / **5** |
| dynamic group max | super is 3,263,168,512 B | 3,258,974,208 B (fits) | **4,890,558,464 B (does not fit - owner's flash warning)** |

So the installed firmware is a Daisaita Android 10 build, and the Android 11 package proves a >3 GiB
super group works on this SoC family - it just needs the GPT grown first (D8/M2b).

**Three 4.19.111+ kernel builds have been seen on this board, and only one is running now.** Re-measured Nov
15 by reading the `Linux version …` string out of each artifact: the stock backup's `boot.bin` (pulled from the
unit on Nov 11 after the restore) and therefore `a14chk/boot-a10k-a14rd.img` and `a14chk/oem-kernel.bin` are
`#190`, built Fri Jul 5 2024 by `root@meng_book2`; the firmware captured on Nov 4 before the restore was
`#277` (built 2022-03-31 by `chun@r930`), whose config dump is `analysis/hu_kernel_config.txt`; and the older
extracted `analysis/boot/kernel` blob is `#2929` (built Tue Mar 2 2021 by `rocky@r940`). Shape A therefore
ships the **#190** kernel, which is also the kernel the stock `4.19.111+` modules were built for.

**GPS is now a hard criterion (**D49**), so its measurement is owed.** Known facts from the Nov 13 probe
(`docs/head-unit-findings.md`, control-plane props): `ro.factory.hasGPS=true`, GPS on `/dev/ttyS0`, Bluetooth on
`/dev/ttyS1`, `ro.rk.bt_enable=true`, and the vendor tree names **AP6476** as the GPS module with a `glgps`
process. The HAL chain is Android 14-legal as measured in `docs/findings.md` (Android 14's GNSS JNI fetches HIDL
`IGnss@1.0`).
Measured Nov 17 19:22-19:26: `android.hardware.gnss@1.0-service` runs (pid 282, uid `gps`) and **holds
`/dev/ttyS0`** (fd 8), `/vendor/lib64/hw/gps.default.so` is 32,440 B, `/dev/ttyUSB*` is absent,
`/dev/mtc-car` exists. But `dumpsys location` reports a completely empty GNSS_KPI window - **0 location
reports, 0 TTFF, 0 CN0, 0 sv-status messages** - with `mTopHalCapabilities=0x1 ( SCHEDULING )` only,
`mGnssMeasurementsProvider.isRegistered()=false` and `native internal state: null`, while
`android.microntek.service`, `com.telenav.launcher` and `com.google.android.apps.maps` all hold
`ACCURACY_FINE` requests. `/proc/tty/driver/serial` shows port 0 (`mmio:0xFF180000 irq:36`)
`tx:70 rx:55755 RTS|DTR`. So the module is powered and streaming on UART0 even with the antenna
**unplugged** (owner confirmed), and zero fixes is expected on this bench: **D49 stays unverifiable
until the antenna is fitted**, and the next antenna-connected session should watch `tx` too - 70 writes
in three minutes means the HAL sends almost nothing, so a module needing an init command sequence would
still report nothing. The HAL leg itself is the shape-A-relevant part and it is coherent.
`lshal` on the same session lists `gnss@1.0::IGnss/default` (pid 282), `allocator@2.0::IAllocator` (283),
`health@2.0::IHealth` (285), the audio 5.0 factories (273), and `mtc.mfi@1.0::IMfi/default` (290) marked
`N` - CANBUS runs but is not declared in the manifest, the gap D50/D51 close. There is **no `glgps`
process** on this firmware, so the vendor tree's `glgps` mention is inert and the GNSS path is the HIDL
service alone. UART0 streams continuously: port 0 `rx` went 445,768 -> 448,018 in a 10 s window (+2,250 B,
~225 B/s) while `tx` stayed 70 - the HAL sends no NMEA/init sequence, so with the antenna fitted watch
`tx` too.
