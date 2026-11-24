# Digest — a14-attempt29 (LineageOS 21.0-20261116-UNOFFICIAL-rk3399, HCT/lineage_rk3399:14/AP2A.240905.003 userdebug/test-keys)
Capture window ends 11-24 20:01:46 (~2 min post-boot). Total E-level logcat lines: 1830.

## 1. Crashes
Java FATAL EXCEPTION ×2 — one process: `android.rockchip.update.service` (pid 2156 @20:01:43.969, pid 2271 @20:01:45.189; am_crash=2):
  `java.lang.NoClassDefFoundError: Failed resolution of: Landroid/microntek/CarManager;`
  first non-lib frame: `at android.rockchip.update.service.RKUpdateService.getProductSN(RKUpdateService.java:734)` ← getRemoteUri(:588) ← onCreate(:209); Caused by `ClassNotFoundException: android.microntek.CarManager`
  → `ActivityManager: Scheduling restart of crashed service android.rockchip.update.service/.RKUpdateService in 1000ms` — crash loop; crash dialog still shown when log ends. The microntek framework class does not exist on this ROM.
Native crash ×1: pid 494 `/vendor/bin/hw/android.hardware.memtrack@1.0-service`, `Fatal signal 6 (SIGABRT)` — `FORTIFY: readdir: null DIR*` (readdir(NULL)). init restarted it (pid 860, IMemtrack registered OK). Downstream: system_server `HIDL Memtrack::getMemory() failed: Status(EX_TRANSACTION_FAILED): 'DEAD_OBJECT:'` ×1; `memevent register failed` / `OomConnection: listener failed to register to OOM events` ×3.
ANRs: 0. Tombstones: current boot = 1 (pid 494). `NativeTombstoneManager: Tombstone's UID (…) not an app, ignoring` ×100 = leftover tombstones from earlier boots: UID(1002=radio)×82, UID(0)×14, UID(1000)×4 → native HAL/radio crashes recur every boot.

## 2. Restart loops (init, dmesg)
- hu_insmod: 15 starts, each `exited with status 0`, re-started every ~5s (never a real stop).
- vendor.weaver-hal-1-0: 14 starts, 14 × `exited with status 0` (~every 5s). Cause: `HidlServiceManagement: Service android.hardware.weaver@1.0::IWeaver/default must be in VINTF manifest in order to register/get.` ×14 + SELinux domain error ×14 (see §5).
- adbd: 3 starts (506@24s→sig9@34s; 626@34s→sig9@87.5s; 1622@88s). Killed on every usb-config switch.
- vendor.memtrack-hal-1-0: 2 starts; `received signal 6` ×1 (the crash above).
- idmap2d: 2 starts, 2 × `received signal 9` (idle-kill, benign); odsign sig9 ×1 (boot-complete, benign).
- exec `hu-mtc-param`: exits 0, killed sig9 — SELinux label error ×3.
logcat `Process … has died`: android.rockchip.update.service ×1, WebViewLoader-arm64-v8a ×1, WebViewLoader-armeabi-v7a ×1 (am_proc_died=3).

## 3. Missing HALs / VINTF (deduped, counts)
HIDL `getTransport: Cannot find entry … in either framework or device VINTF manifest`:
weaver@1.0::IWeaver ×28 | graphics.mapper@3.0::IMapper ×9 | mapper@4.0 ×8 | configstore@1.0::ISurfaceFlingerConfigs ×7 | audio@7.0 & @7.1::IDevicesFactory ×5+5 | audio.effect@7.0/@7.1::IEffectsFactory ×5+4 | keymaster@3.0/@4.0 ×3+3 | configstore@1.1 ×3 | usb.gadget@1.0 ×2 | thermal@1.0 ×2 | soundtrigger@2.0 ×2 | power.stats@1.0 ×2 | vendor.lineage.touch (ITouchscreenGesture/IStylusMode/IKeySwapper/IKeyDisabler/IHighTouchPollingRate) ×1 each.
AIDL `servicemanager: Could not find … in the VINTF manifest`: graphics.allocator.IAllocator ×8; radio.{voice,messaging,ims,data} ×4 each, radio.{sim,network,modem} ×3 each; audio.effect.IFactory ×4; audio.core.IModule ×4; health.IHealth ×3; usb.gadget.IUsbGadget, thermal.IThermal, power.IPower, input.processor.IInputProcessor ×2 each; memtrack, sensors, gnss, gatekeeper, boot, authsecret, oemlock, lights, composer3, vibrator(+manager), usb.IUs, soundtrigger3, secure_element×2, media.c2.software, nlinterceptor, power.stats, lineage.health ×1 each.
init `Control message: Could not find … for ctl.interface_start`: `android.hardware.wifi@1.0::IWifi/default` ×34, `aidl/activity` ×24, `android.hardware.drm@1.0::IDrmFactory/default` ×6, `aidl/sensor_privacy` ×1.
getService retry loops (still failing at log end): wifi@1.0 `Trying again` ×33 + `Waited one second` ×32; `activity` waited ×23; drm@1.0 ×5; graphics.allocator@2.0 ×2; composer@2.1 ×1; power@1.0 ×1.
Registered HALs (for contrast): audio@6.0/effect@6.0, memtrack@1.0, sensors@1.0, drm@1.2 (widevine/clearkey), hwcomposer@2.1, gralloc-2-0. Other missing binaries: `/system/bin/busybox` (up_eth0), `/system/bin/displayd`, `libjni_latinimegoogle.so`, `android.hardware.bluetooth.audio-impl.so`, `android.hardware.audio.sounddose-vendor-impl.so`.

## 4. Top 20 E tags (count — representative message, ×=exact-message hits)
464 ActivityThread — `Failed to find provider info for com.google.android.setupwizard.partner` (all 464)
139 ResilientAtomicFile — `Failed to verity-protect package manager settings` (2 events × ~70 stack lines)
104 init — 34× wifi ctl, 24× aidl/activity ctl, 14× weaver SELinux label, 6× drm ctl, 1× `Failed to read vbmeta partitions.`
100 NativeTombstoneManager — `Tombstone's UID (1002) not an app, ignoring` ×82 (+UID0 ×14, UID1000 ×4)
64 RuntimePermissionsPersistenceImpl — `Failed to verity-protect runtime-permissions` ×4 (+stack)
64 RILJ — `getCurrentCalls not supported on service VOICE < 1.4. [PHONE0]` ×61 (radio HAL too old/missing AIDL)
42 GRALLOC-MOD — `validateBufferSize failed, layer count is invaild` ×18, `fail to create bo.` ×12
39 AppWidgetManager — `Notify service of inheritance info` ×2 + `IllegalStateException: User 0 must be unlocked for widgets` stacks
37 configfs-gadget — `fe800000.dwc3: failed to start g1: -19` (all 37)
36 SystemServiceRegistry — `No service published for: fingerprint` ×3 (+`Manager wrapper not available` ×3, stacks)
36 AndroidRuntime — 2 FATAL EXCEPTION blocks (§1)
29 SafetyCenterManagerWrap — `IllegalArgumentException: Unexpected safety source: AndroidPrivateSpace` ×1 (+`Failed to send SafetySourceData`)
27 hwc-drm-plane — `Could not get AREA_ID property` ×15, `Could not get rotation property` ×12
24 GRALLOC-ROCKCHIP — `unexpected 'base_format' : 0x36` ×12 (+drm_gem_rockchip_alloc lines)
22 APM_AudioPolicyManager — `invalid volume index range` (all 22)
21 mtc-gps — `--mtc write_gps: could not send $PCAS06,6*1D` ×5, ` command: ret=14: Try again` ×4, `--mtc qemu_gps_init: called` ×2
21 UsbPortManager — `USB Gadget HAL AIDL/HIDL not present` + NoSuchElementException stacks
20 UsbDeviceManager — `connectToProxy: usb gadget hidl hal service not found.` + stacks
20 JniUtils — `Could not load native library jni_latinimegoogle` (LatinIME UnsatisfiedLinkError)
19 HealthConnectResContext — `Attempted to fetch resources before Health Connect resources APK is loaded!`

## 5. Subsystems
Ethernet/eth0: kernel OK — `ax88179_178a 1-1.2:1.0 eth0: register … ASIX AX88179 USB 3.0 Gigabit Ethernet, 00:0a:cd:27:a5:b2` @3.7s, `eth0: link becomes ready` @7.1s. Broken init bits: `Could not start service 'up_eth0' … Cannot find '/system/bin/busybox'`, `chmod 0777 /system/bin/dhcpcd failed: Read-only file system`, dhcpcd_* services `No user specified`. Framework OK: IpClient got DHCP (`192.168.1.127/24, DNS 192.168.1.1`), `Sending CONNECTED broadcast for type 9 [100 ETHERNET] isDefaultNetwork=true` @20:01:08.547. Ethernet works.
adbd/USB gadget: `configfs-gadget fe800000.dwc3: failed to start g1: -19` ×37; `write /config/usb_gadget/g1/UDC … No such device` (ENODEV); symlink `File exists`; adbd `timed out while waiting for FUNCTIONFS_BIND, trying again` ×36; adbd restarted 3× (§2). adb-over-USB never attaches (UDC/controller binding broken). `UsbPortManager/UsbDeviceManager`: gadget HAL not present (§4).
Display/SF/hwc: `hwc-drm-plane` E ×27 (§4); `hwc-drm-resources: is_hdr_panel_support_st2084:line=1393, blob is null` ×2, `BP: hwc get baseparameter err` ×2; `vop_bw: Error opening /sys/class/devfreq/dmc/vop_bandwidth` ×2; HWComposer `…failed for display 0: Unsupported (8)` ×~10 (SupportedContentTypes, ConnectionType, Decoration, HDR); `EventThread: Ignoring VSYNC request while display is disconnected` ×4; `/system/bin/displayd` missing; `Could not create socket 'pdx/system/vr/display/{client,manager,vsync}'` ×3; HWUI `Failed to initialize 101010-2 format` + configstore ISurfaceFlingerConfigs missing ×10; BufferQueueProducer `disconnect: not connected` ×6. Display finally OK @20:00:59 (`Built-in Screen 1024x600@60fps, state ON`).
Audio: AIDL audio missing from VINTF (§3); legacy vendor.audio-hal registers audio@6.0; `start vendor.audio-hal-aidl` / `vendor.audio-hal-4-0-msd` → `service … not found`; `AudioFlinger: loadHwModule() error -22 loading module a2dp` (BT audio impl libs missing, §3); primary/usb/r_submix modules loaded OK; `APM_AudioPolicyManager: invalid volume index range` ×22; soundtrigger/BT-audio/sounddose APIs unregistered.
Wifi: `vendor.wifi_hal_legacy` started but IWifi never registers → 34 ctl + 33 retries/32 1-second waits, still failing at log end. Kernel: `[WLAN_RFKILL]: get_wifi_addr_vendor: rk_vendor_read wifi mac address failed (-1)`; `DrmService: ------------open file failed,and try insmod wifi failed,SLOGE=File exists`. No wifi network at all.
Touch: EventHub sees `goodix-ts` (/dev/input/event1), `mtc-key` (event0), `gpio-keys`; `No input device configuration file found` ×2 (missing .idc); boot-time: `Touch device … could not query the properties of its associated display` ×4 and `Disabling goodix-ts/mtc-key … viewport is not active` ×4, recovered @20:00:47.9 (mode 1, 1024x600). Kernel mtc driver: `--mtc VTouch/KeyPwrMute/BlPwm/ScreenTiming 0` ×18 each (microntek reads 0). GPS via mtc: write_gps fails ×5, `ret=14: Try again` ×4, `--mtc qemu_gps_init: called` ×2 (emulated path on HW).
SELinux: 0 enforcing denials; 40 audit lines, ALL permissive=1 (18 unique combos). Top scontext/tcontext/tclass: tee→vendor_default_prop property_service{set} ×3; hal_graphics_composer_default→vendor_default_prop{set} ×3; hal_camera_default→vendor_default_prop{set} ×3; init→settings_service service_manager{find} ×3; vendor_init→{wifi,build,config,radio,timezone,system,default,bluetooth}_prop{set} ×2 each; init→hal_weaver/drm/default_android_hwservice hwservice_manager{find,add} ×2 each. Domain-transition errors (init E): `/vendor/bin/hw/android.hardware.weaver@1.0-service` ×14, `/system/bin/hu-mtc-param` ×3, `/system/bin/sh` ×3, `/system/bin/settings` ×2, `/vendor/bin/rockchip.drmservice`, `android.hardware.drm@1.2-service.clearkey/.widevine` ×1 each.

## Priorities (no speculation beyond these lines)
1. VINTF manifest coverage: weaver/wifi/audio-AIDL/radio-AIDL/mapper@3-4/configstore/composer3/memtrack etc.; weaver & wifi loops churn forever.
2. RKUpdateService hard-requires android.microntek.CarManager — crash loop + crash dialog blocks first-boot UI.
3. memtrack HAL null DIR* abort; USB gadget g1 ENODEV (adb dead); hu_insmod 5s loop; SELinux labels/domain transitions for weaver, hu-mtc-param, sh, settings, drm services.
