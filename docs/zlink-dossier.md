> **Parent review (Nov 28), read this first.** The dossier's section 6 compared against the stock files, not our ROM.
> Checked on the unit (attempt 45): `carplay.type=1` is set; `usb_f_iap` is loaded and `usb_f_iap(2).ko` are in the vendor
> modules; the configfs gadget already has `iap.gs0` and `ncm.gs1`; `/dev/zjinnova_iap`, `/dev/mtc-av` and `carservice`
> (our HCTManagerService port) exist; the HCT apps are installed. Real gaps, in port order:
> 1. **The ZLink app** `com.zjinnova.zlink` (with `libzjL10001.so`, `libzmdnsd.so`): not recoverable from the unit (stock
>    /data is file-based encrypted); needs the owner's APK. Nothing can be tested without it.
> 2. **`z-link` loader + `z-link.sh` + the rc service** (`on property:carplay.type=1 start z-link`): stock binaries are
>    32-bit ARM, fine on this ROM (the GOC daemon is 32-bit too); SELinux: stock ran them as `u:r:shell:s0`.
> 3. **`mfiservice`**: stock `services.jar` `com.android.server.microntek.MfiService` (+ `IMfiService`/`MfiManager` in
>    framework.jar, JNI natives). Port like `carservice`: classes into `hct-framework.jar`, hosted in the patched
>    HCTManagerService, JNI from the stock native library behind a shim if its ABI needs it.
> 4. **Framework exceptions**: default permission grants (storage/mic/phone/location: `pm grant` at first boot), AppOps
>    record-audio (appops), Wi-Fi config override for wireless CarPlay (WifiPermissionsUtil hook - check whether it is
>    needed at all), foreground-service exemptions (probably not needed on A14).
> 5. **Audio**: `av_focus_carplay` / `av_phone_carplay` keys go through carservice `setParameters` (works today); the
>    AudioFlinger mirror to `/dev/mtc-av` needs checking once audio plays. SurfaceFlinger's crop is for dual-screen
>    `display_mode` (not used here); the libstagefright check's purpose is UNKNOWN.

# ZLink porting dossier (Android 10 stock firmware -> Android 14 plan)

Read-only investigation of `/run/media/Daan/Opslagmonster/a14-work/scratch/zlink/` (`files/`, `smali/`)
plus `analysis/system_init.hct.rc`. Tools used: `strings`, `readelf`, `nm`, `grep`, baksmali output as text.
No adb, no network, no git, no writes outside this file. Evidence format: file + smali class/method + line,
or `strings`/`nm`/`readelf` output. `UNKNOWN` = the inputs do not answer it; `GUESS` = interpretation.

Known facts supplied by the parent engineer (not re-derived here): `carplay.type=1` triggers `z-link.sh`
from stock init (insmod `usb_f_iap2.ko`, configfs functions `iap.gs0` + `ncm.gs1`, then loops
`z-link -c hengchangtong` with `LD_LIBRARY_PATH=/data/data/com.zjinnova.zlink/lib`); the real implementation
is the app `com.zjinnova.zlink` (encrypted /data, not in the stock system image). On the A14 ROM:
`/dev/zjinnova_iap` + `/dev/usb_accessory` exist, `mtc_mfi_service` runs, `persist.sys.zlink.*` /
`rw.zlink.*` are set, `carplay.type=1`, ZLink app NOT installed.

## 1. Framework hooks (framework.jar / services.jar / wifi-service.jar)

Case-insensitive scan (`grep -rilE 'zlink|zjinnova|carplay|iap2|mtc_mfi'`) over each baksmali tree:
framework.jar -> 2 files, services.jar -> 5 files, wifi-service.jar -> 1 file.
File counts of the trees: framework 16711, services 6159, wifi-service 2032 smali files.

### 1.1 framework.jar `android/content/pm/PackageParser.smali`

**a) Constructor `<init>()` line 446-480: package whitelist `mAppFilterPackages`.**
`com.zjinnova.zlink` is one of 8 packages that are exempted from the forced rotation below.

```smali
459:     .line 4788
460:     const-string v1, "com.android.calculator2"
461:     const-string v2, "net.easyconn"
462:     const-string v3, "com.zjinnova.zlink"
463:     const-string v4, "com.suding.speedplay"
464:     const-string v5, "com.microntek.controlinfo"
465:     const-string v6, "com.microntek.controlsettings"
466:     const-string v7, "com.microntek.dvd"
467:     const-string v8, "com.microntek.air"
468:     filled-new-array/range {v1 .. v8}, [Ljava/lang/String;
470:     iput-object v0, p0, Landroid/content/pm/PackageParser;->mAppFilterPackages:[Ljava/lang/String;
```

**b) `parseActivity(...)` (method starts line 5145), lines 6014-6118: orientation override.**
`ro.product.project == "BOX"` and `ro.product.rotate == "true"` force `screenOrientation = 2`
(`SCREEN_ORIENTATION_USER`, GUESS on the constant name) on *every* activity, then reset to 0
(`SCREEN_ORIENTATION_UNSPECIFIED`) for the `mAppFilterPackages` list - i.e. ZLink activities keep the
manifest/ unspecified orientation while the rest of the device is rotated.

```smali
6036:     :cond_2b3
6037:     const-string v0, "ro.product.rotate"
6038:     invoke-static {v0}, Landroid/os/SystemProperties;->get(Ljava/lang/String;)Ljava/lang/String;
6040:     const-string/jumbo v2, "true"
6041:     invoke-virtual {v2, v0}, Ljava/lang/String;->equals(Ljava/lang/Object;)Z
6043:     if-eqz v0, :cond_305
6046:     iget-object v0, v9, Landroid/content/pm/PackageParser$Activity;->info:Landroid/content/pm/ActivityInfo;
6048:     const/4 v2, 0x2
6049:     iput v2, v0, Landroid/content/pm/ActivityInfo;->screenOrientation:I
```
then the exemption loop:
```smali
6064:     iget-object v0, v7, Landroid/content/pm/PackageParser;->mAppFilterPackages:[Ljava/lang/String;
6073:     aget-object v13, v0, v10
6079:     invoke-virtual {v13, v0}, Ljava/lang/String;->equals(Ljava/lang/Object;)Z
6081:     if-eqz v0, :cond_2fc
6084:     iget-object v0, v9, ...ActivityInfo;->info:...ActivityInfo;
6086:     const/4 v2, 0x0
6087:     iput v2, v0, Landroid/content/pm/ActivityInfo;->screenOrientation:I
```
Also in the same method, line 5999: `HCTApi.getHctwmPloy()` gates the orientation write (window policy, GUESS).

**c) `parseActivity` lines 6444-6480: HCT packages forced direct-boot-aware.**
Activities whose package starts with `com.microntek.` / `com.hct.` or equals `android.microntek.` get
`directBootAware = true` + `encryptionAware = true`; note `com.zjinnova.zlink` is *not* in this list.

```smali
6444:     const-string v2, "com.microntek."
6445:     invoke-virtual {v0, v2}, Ljava/lang/String;->startsWith(Ljava/lang/String;)Z
6453:     const-string v2, "com.hct."
6454:     invoke-virtual {v0, v2}, Ljava/lang/String;->startsWith(Ljava/lang/String;)Z
6462:     const-string v2, "android.microntek."
6463:     invoke-virtual {v0, v2}, Ljava/lang/String;->equals(Ljava/lang/Object;)Z
6474:     const/4 v10, 0x1
6477:     iput-boolean v10, v2, Landroid/content/pm/ActivityInfo;->directBootAware:Z
6478:     iput-boolean v10, v0, Landroid/content/pm/ActivityInfo;->encryptionAware:Z
```
Consequence at line 6544-6557: `ApplicationInfo.privateFlags |= 0x100` (`FLAG_DIRECT_BOOT_AWARE`, GUESS).

**d) `parseActivity` lines 6487-6508: launcher label swap for the "OneConnect" customer build.**
`ro.product.customer.sub == "HXD2"` -> `ActivityInfo.nonLocalizedLabel = "OneConnect"` for
`com.zjinnova.zlink` (and "Software Updates" for `in.newdevpoint.onenavupdate`).

```smali
6487:     const-string v0, "ro.product.customer.sub"
6488:     invoke-static {v0}, Landroid/os/SystemProperties;->get(Ljava/lang/String;)Ljava/lang/String;
6491:     const-string v2, "HXD2"
6492:     invoke-virtual {v2, v0}, Ljava/lang/String;->equals(Ljava/lang/Object;)Z
6501:     iget-object v0, v0, Landroid/content/pm/ActivityInfo;->packageName:Ljava/lang/String;
6503:     const-string v2, "com.zjinnova.zlink"
6504:     invoke-virtual {v2, v0}, Ljava/lang/String;->equals(Ljava/lang/Object;)Z
6508:     const-string v2, "OneConnect"
6509:     iput-object v2, v0, Landroid/content/pm/ActivityInfo;->nonLocalizedLabel:Ljava/lang/CharSequence;
```

### 1.2 framework.jar `android/microntek/IRTable.smali` line 307 (+ duplicate in HCTCanBus)

```smali
307: .field public static final blacklist IR_ZLINK:I = 0x313
296: .field public static final blacklist IR_ANDROID_AUTO:I = 0x322
288: .field public static final blacklist IR_AMAZON:I = 0x317
```
Duplicate copy in `smali/HCTCanBus/com/microntek/IRTable.smali:399`. The key code 0x313 is used by
`HCTCarTouch/com/hct/screenbutton/view/HFloatLayout.smali:2941` (`startCarPlay()` -> `sendKey(0x313)`)
and by `HCTManagerService/android/microntek/service/MicrontekServer.smali:3524` (`DoPressKeyTask` sparse-switch -> `startZlink()`), see 4.x.
Key *names* are resolved reflectively from the class string `"android.mtc.IRTable"` in
`HCTFactorySettings/com/hct/factory/PannelKeyStudy.smali:1486 getIRTableKeyName(I)`.
Consumers of `IR_ZLINK` inside framework.jar itself: none found -> **UNKNOWN** (framework only declares it).

### 1.3 services.jar `com/android/server/am/ActiveServices.smali` line 16322 (`startServiceLocked`, overload starting line 15628)

Package whitelist that makes a background service start *not* require foreground conversion
(`fgRequired = false`):

```smali
16310:     const-string v1, "android.microntek."
16311:     invoke-virtual {v0, v1}, Ljava/lang/String;->startsWith(Ljava/lang/String;)Z
16322:     const-string v1, "com.zjinnova.zlink"
16323:     invoke-virtual {v0, v1}, Ljava/lang/String;->startsWith(Ljava/lang/String;)Z
16332:     const-string v1, "android.rockchip.update.service"
16333:     invoke-virtual {v0, v1}, Ljava/lang/String;->equals(Ljava/lang/Object;)Z
16340:     :cond_23c
16341:     const/4 v2, 0x0
16342:     move v12, v2            # fgRequired = false
```
(The `com.microntek.` / `com.hct.` prefixes are checked just above, lines ~16290-16300.)

### 1.4 services.jar `com/android/server/am/ActivityManagerService.smali` line 39925 (`broadcastIntentLocked`, overload starting line 39778)

HCT fork: every broadcast gets `Intent.FLAG_RECEIVER_FOREGROUND` (`0x10000000`, GUESS on the flag constant)
*except* a list of actions - and the ZLink action strings are on the exception list, so ZLink broadcasts
keep the default (background) receiver dispatch.

```smali
39915:     const-string v1, "android.appwidget."
39925:     const-string v1, "com.zjinnova.zlink"      -> startsWith, exempt
39934:     const-string/jumbo v1, "zjinnova.android."  -> startsWith, exempt
39943:     const-string v1, "android.hardware.usb.action.USB_DEVICE_DETACHED" -> equals, exempt
39952:     const-string v1, "android.os.storage.action.VOLUME_STATE_CHANGED" -> equals, exempt
39961:     const-string v1, "android.intent.action." (and not USB_CAMERA) -> exempt
39976:     :cond_99
39977:     const/high16 v1, 0x10000000
39978:     invoke-virtual {v5, v1}, Landroid/content/Intent;->addFlags(I)Landroid/content/Intent;
```

### 1.5 services.jar `com/android/server/wm/ActivityStackSupervisor.smali` line 11423 (`switchDualScreen()`, method line 11242)

Rear-screen (dual display) switch is skipped when the shipped/foreground package is one of the phone-projection
apps. Uses `sys.ship.package` plus `android.microntek.CarManager.getParameters("sta_rear_version=")` and
`MediaRouter.getSelectedRoute(2)` (type 2 GUESS = Bluetooth route).

```smali
11380:     const-string v11, "sys.ship.package"
11381:     invoke-static {v11}, Landroid/os/SystemProperties;->get(...)
11413:     const-string v12, "com.android.settings"
11423:     const-string v12, "com.zjinnova.zlink"    -> equals -> skip switch
11432:     const-string v12, "com.suding.speedplay"
11441:     ... com.microntek.bluetooth / btmusic / FileBrowser / travel / com.android.systemui
```

### 1.6 services.jar `com/android/server/pm/permission/DefaultPermissionGrantPolicy.smali` line 4626 (`grantDefaultSystemHandlerPermissions(int)`)

ZLink gets STORAGE + MICROPHONE + PHONE + (always-)LOCATION runtime permissions granted at boot, with
`allowImplicit = true` - so the app never asks for them.

```smali
4626:     const-string v1, "com.zjinnova.zlink"
4627:     invoke-direct {v7, v1}, ...DefaultPermissionGrantPolicy;->getPackageInfo(...)
4632:     if-eqz v1, :cond_7f9
4635:     invoke-static {v1}, ...->doesPackageSupportRuntimePermissions(...)Z
4638:     sget-object v10, ...->STORAGE_PERMISSIONS:Ljava/util/Set;
4644:     invoke-direct {v7, v1, v10, v0 /*allowImplicit*/, v8 /*userId}
4646:     sget-object v10, ...->MICROPHONE_PERMISSIONS:Ljava/util/Set;
4648:     sget-object v10, ...->PHONE_PERMISSIONS:Ljava/util/Set;
4652:     sget-object v10, ...->ALWAYS_LOCATION_PERMISSIONS:Ljava/util/Set;
```

### 1.7 wifi-service.jar `com/android/server/wifi/util/WifiPermissionsUtil.smali` - permission bypass by uid

Three methods return `true` when `PackageManager.getNameForUid(uid)` equals `com.zjinnova.zlink`
(or `com.suding.speedplay`), bypassing `WifiPermissionsWrapper.getChangeWifiConfigPermission(uid)`:

```smali
614:  const-string v1, "com.zjinnova.zlink"     # checkChangePermission(int uid)
624:  invoke-virtual {v2, p1}, PackageManager->getNameForUid(I)
716:  const-string v1, "com.zjinnova.zlink"     # checkConfigOverridePermission(int uid)
1104: const-string v1, "com.zjinnova.zlink"     # checkWifiAccessPermission(int uid)
```
Meaning: ZLink may change/override Wi-Fi config without holding the Wi-Fi permission - needed for
wireless CarPlay / mDNS / hotspot. GUESS on the "why", evidence solid on the "what".

### 1.8 services.jar `com/android/server/SystemServer.smali` - the HCT service family is started here

```smali
3619: const-string/jumbo v0, "mfiservice"
3621: new-instance v6, Lcom/android/server/microntek/MfiService;
3623: invoke-direct {v6, v4}, ...MfiService;<init>(Context)V
3638: const-string/jumbo v6, "mtc >>>> starting mfiservice"
```
`MfiService` extends `android.microntek.mfi.IMfiService$Stub` (framework.jar), so the ZLink app talks to it
through `android.microntek.mfi.MfiManager` (`MfiManager.smali:60 const-string "mfiservice"` -> `ServiceManager.getService`).
The companion `com/android/server/microntek/CarService.smali` is published as `"carservice"`
(`framework/android/microntek/CarManager.smali:44`), which is how `av_*` / `cfg_factory_*` / `sta_*`
parameters reach the MCU (see 4.x). `CarService.initComm()` opens `/dev/ttyV2`
(`CarService.smali:4440 const-string "mtc >>> open /dev/ttyV2 fail!"`).

### 1.9 services.jar `com/android/server/microntek/MfiService.smali` (+ `$UsbReceiver`, `$PlayThread`, `$PositionListener`)

- `MfiService` JNI surface: `native_class_init`, `native_init(OnMfiServiceCallback,int)`, `native_attach(String)`,
  `native_detach`, `native_send(byte[])`, `native_start`, `native_stop` (lines 844-859). Debug logging gated by
  `sys.hct.debug` (line 300).
- `$UsbReceiver.onReceive` (line 44-) handles `android.hardware.usb.action.USB_DEVICE_ATTACHED` / `_DETACHED`
  (registered in `MfiService.<init>` lines 266/271):

```smali
75:  const-string/jumbo v3, "persist.sys.zlink.mode.registed"   -> carplayRegMode
83:  const-string/jumbo v4, "persist.sys.easyconn.registed"     -> easyconnRegMode
96:  mCarManager.getParameters("cfg_factory_part=100,1")        -> mCarPlayType
109: mCarManager.getParameters("cfg_factory_ext_part=1,1")       -> mEasyConnection
117: const-string/jumbo v7, "persist.sys.phone.auto.connection"
155: const-string/jumbo v8, "zlink"   / 163 "speedplay" / 191 "easyconn"  (top-package filter)
183: const/16 v8, 0x5ac                -> Apple USB vendor id
252: invoke-static {v7, v8}, MfiService->attach(String)
```
So: on an Apple USB device, unless the projection app is already registered (`persist.sys.zlink.mode.registed`
contains `w`, or carplay type is 1/2), `MfiService.attach(deviceName)` runs.
- Audio path: `stream_open`/`stream_close` (lines 917/878) drive an `AudioTrack` + `PlayThread`
  (`BUFF_COUNT=8`, `STREAM_MAX_SIZE=0x1800`, `audioEncoding=2` -> PCM_16_BIT, GUESS, `channelConfiguration=0xc`),
  with `audioFocus`/`ipodConnected` state, silence/stream drop counters, and callback/listener fan-out
  (`IMfiCallback`, `IMfiListener` via `RemoteCallbackList`).

**UNKNOWN:** what the native side of these `native_*` methods does (the `.so` behind them is not in the inputs).

## 2. Native library hooks (libsurfaceflinger.so / libaudioflinger.so / libstagefright.so)

All three are arm64 and **stripped** (`.symtab` absent; only `.dynsym`), so a string reference can only be
attributed to the nearest *dynamic* symbol. Method used: `strings -a -t x`, `nm -D`, `readelf -d`, `readelf -Ws`,
`llvm-objdump -d` + pairing `adrp xN,#page` / `add xN,xN,#off` to recover the referenced string address
(`/tmp/opencode/soscan.py`, `/tmp/opencode/fnattribution.py`). `objdump -d` cannot disassemble arm64 here.

### 2.1 libaudioflinger.so - audio routing / ducking for CarPlay

Strings containing zlink/carplay/mtc (offsets are file offset == vaddr here):

| string | offset | referenced from |
|---|---|---|
| `/dev/mtc-av` | 0x10167 | 0x39374 |
| `av_focus_carplay` | 0x11c54 | 0x310c4 |
| `av_phone_carplay` | 0x123bc | 0x30f98 |
| `ro.product.zlink3` | 0x123e7 | 0x2c1a0 |
| `com.zjinnova.zlink` | 0x15e2d | 0x2c1d4, 0x2d6bc, 0x397c0, 0x45590, 0x51fa0 |
| `--mtc carplay gps  enter` | 0x14c0b | 0x39a2c |
| `--mtc carplay gps  exit` | 0x12eb2 | 0x39800 |
| `--mtc mtcGetActiveStream carplay gps run1  %d` | 0x13881 | 0x8e8e0 |
| `--mtc mtcGetActiveStream carplay gps run2  %d` | 0x1103e | 0x8eac4 |

Full HCT-specific key set found in `.rodata` (no `zlink`/`carplay` in the name, but same `av_*` protocol as
`CarService.setParameters`): `av_channel_enter`, `av_channel_exit`, `av_focus_gain`, `av_focus_loss`,
`av_focus_carplay`, `av_phone`, `av_phone_carplay`, `av_phone_sim`, `av_gps_phone`, `av_gps_gain`,
`av_gps_monitor`, `av_gps_ontop`, `av_gps_package`, `av_gps_switch`, `av_gps_backvol`, `av_active`,
`av_volume`, `av_refresh`, `av_stream_voice_call_mute`, `av_voiceprompt_on`, `av_voiceprompt_package`.
Other MTC log strings: `--mtc createTrack() Caller %d`, `---mtc  keyvalue %s`, `--mtc mtcSetActive(): ...`,
`--mtc mtcRecordActiveTrack creatorPid=%d %d %d %s`, `--mtc sessionId: exist/not exist`,
`--mtc mActiveHctBox b=%d v=%d g=%d m=%d back=%d sessionId=%d`, `--mtc path %s %d`.

Record-audio monitoring (relevant because ZLink streams/records the phone's audio):
`AF::OpRecordAudioMonitor`, `OP_RECORD_AUDIO missing, %ssilencing record uid%d pack:%s`,
`Silence is golden`, and imported AppOps symbols:

```
U _ZN7android13AppOpsManagerC1Ev
U _ZN7android13AppOpsManager7checkOpEiiRKNS_8String16E
U _ZN7android13AppOpsManager19checkAudioOpNoThrowEiiiRKNS_8String16E
U _ZN7android13AppOpsManager17startWatchingModeEiRKNS_8String16ERKNS_2spINS_15IAppOpsCallbackEEE
U _ZN7android13AppOpsManager16stopWatchingModeERKNS_2spINS_15IAppOpsCallbackEEE
U _ZN7android16BnAppOpsCallback10onTransactEjRKNS_6ParcelEPS1_j
```
PLT call sites: 0xc29b8 (ctor), 0xc313c (startWatchingMode), 0xc33e4 (checkAudioOpNoThrow),
0xc29b8/0xc2ce8, 0xcbfe8/0xcc11c (ctor), 0xcc620 (checkOp), 0xcc780 (startWatchingMode),
0xccb78 (checkOp), 0xcc390 (stopWatchingMode).
Property access: `U property_get`, `property_get_bool`, `property_get_int32`, `property_get_int64`.
`DT_NEEDED`: libaudiohal, libaudioprocessing, libaudiospdif, libaudioutils, libcutils, libutils, liblog,
libbinder, libaudioclient, libmedialogservice, libmediametrics, libnbaio, ...

Purpose (GUESS, evidence = the strings themselves): AudioFlinger has an HCT "mtc-av" layer that (a) writes
the `av_*` focus/volume/channel commands to `/dev/mtc-av` (the MCU audio mixer device) when tracks are
created/activated, (b) tracks the *active* recording track and caller package (so CarPlay/GPS audio can be
ducked or silenced), (c) watches `OP_RECORD_AUDIO` per package and silences recording for packages outside
a whitelist (`com.zjinnova.zlink` is in that package table, together with map/TTS packages such as
`com.autonavi.amapauto`, `com.google.android.tts`), (d) `ro.product.zlink3` selects ZLink-3 behaviour.
Enclosing function for each ref: **UNKNOWN** (stripped; `llvm-objdump` labels put them "inside
`_ZN7android12AudioFlingerC1Ev` +0x1e90..+0x27c90", which cannot be a real constructor body - the labels
are only the nearest preceding dynamic symbol).

### 2.2 libsurfaceflinger.so - display/layer special-casing for projection packages

Strings:
```
com.zjinnova.zlink   sys.ship.package   net.easyconn   com.huawei.hicar   com.suding.speedplay
cn.manstep.phonemirrorBox   com.baidu.BaiduMap   com.waze   com.tencent.wecarnavi   com.youku.phone
.igo.   autonavi.   cld.navi.   SurfaceView   outCropCoords;   in protected context: %d
hct >>>>>> SurfaceFlinger is CarBox   persist.carbox.density
/sys/bus/platform/drivers/mtc-car/display_mode   >>>>>> display_mode open fail!!   ro.product.project
```
Reference evidence (adrp/add pairing):
- `/sys/bus/platform/drivers/mtc-car/display_mode` 0x474a4 -> refs 0xd0910, 0xd1148 (inside
  `SurfaceFlinger::SurfaceFlinger(Factory&)`, +0x208): `__open_2` then `__read_chk`, `atoi`, on failure the
  string `>>>>>> display_mode open fail!!` (0x474d3, refs 0xd097c / 0xd11b4). So SF reads the kernel
  `mtc-car` driver's `display_mode` at construction.
- `hct >>>>>> SurfaceFlinger is CarBox` 0x46b23 -> refs 0xd0bf4 / 0xd142c (both constructors, +0x4ec),
  preceded by `property_get` of `ro.product.project`; `persist.carbox.density` 0x46b48 -> ref 0x54b00-ish
  region attributed to `SurfaceFlinger::init()` (+0x20d8).
- The projection-package block, refs 0xf1d38..0xf1db4 (labelled inside `SurfaceFlinger::run()` +0x19exx,
  unreliable): `memcmp("com.tencent.wecarnavi",21)` then `strstr` chain over `com.waze`,
  `com.baidu.BaiduMap`, `com.zjinnova.zlink`, `com.huawei.hicar`, `com.suding.speedplay`,
  `cn.manstep.phonemirrorBox`; earlier in the same block (0xf1834..0xf1890) `strstr` over
  `net.easyconn`, `.igo.`, `autonavi.`, `cld.navi.`, and `property_get("sys.ship.package")` compared against
  a table of 11 strings (`add x27,x27,#8` loop, 0x58 bytes) - if a hit occurs and the layer metadata string
  does **not** contain `SurfaceView`, the code goes to a `ui::Transform::transform(Region)` +
  `Region::andSelf(Rect)` path (0xf1934/0xf1940).

Purpose (GUESS): SurfaceFlinger crops/rescales hardware layers for the phone-projection and navigation apps
when they are not rendering through a `SurfaceView`, and picks up the panel mode/density from the
`mtc-car` platform driver and `ro.product.project`/`persist.carbox.density`.
`com.zjinnova.zlink` here is a *package-name* string, not an API - the ZLink app itself never links SF.

### 2.3 libstagefright.so - one zlink string

```
STRING fileoff=0x5dd81 vaddr=0x5dd81 'com.zjinnova.zlink'
   ref at 0x8eb1c -> inside _ZN7android6ACodec9BaseState21onOutputBufferDrainedERKNS_2spINS_8AMessageEEE (+0xff4, size 5748)
   ref at 0x8f324 -> inside the same symbol (+0x17fc)
```
Both references fall inside `ACodec::BaseState::onOutputBufferDrained()` (this symbol has a real dynsym size,
so this attribution is credible). Only other MTC-ish string in the lib is `sys.usbcam.status.forvideo`
(stock AOSP file path strings otherwise). Purpose: **UNKNOWN** - the inputs do not show *what* is done with
the package name here; GUESS: a special case for output-buffer handling when the codec client is ZLink
(e.g. skipping/forcing something for the mirrored video path). No exported/imported symbol near it matches
zlink/carplay/mtc (`nm -D` on libstagefright.so shows only ordinary android:: symbols).

## 3. The loader: `z-link`, `z-mdnsd`, `z-link.sh`, `mdnsd.rc`

### 3.1 `/system/bin/z-link` (11 KB) - format and imports

```
readelf -h z-link: Class ELF32, Type DYN (Shared object), Machine ARM   <-- 32-bit arm, not arm64
.interp   /system/bin/linker
readelf -d: NEEDED = libc.so, libdl.so   (+ PLTGOT/PLTRELSZ, no other libs)
```
`.symtab` **is present** in both binaries, so function names are known:
```
38: 0000111c  496 FUNC GLOBAL main
40: 000009f4  696 FUNC GLOBAL find_pid_by_name
52: 00000ce8  204 FUNC GLOBAL run_process   (plus check_process_by_name, copy_file, log_dup_init)
```
`nm -D` imports: access, atoi, closedir, dlclose, dlerror, dlsym, dup2, fprintf, fopen, fclose, fread, fwrite,
getopt, optarg, mkdir, open, opendir, readdir, readlink, remove, setvbuf, stat, strdup, strlen, strncmp,
strrchr, snprintf, puts, printf, system, memset, memcpy, strcat, `__sF`, `__libc_init`, `__cxa_atexit`.

`.rodata` strings (offset == vaddr):
```
0x1324 /proc            0x132c cannot open /proc     0x1340 /proc/%s/exe   0x1354 process_channel = 1
0x136c fopen error      0x137c /data/local/tmp/zlink_log
0x1398 mkdir zlink error   0x13ac mkdir zlink_log error
0x13c4 /data/local/tmp/zlink_log/zlink.log   0x13e8 /data/local/tmp/zlink_log/zlink.old
0x140c rm zlink.log error
0x1420 open /data/local/zlink/tmp/zlink_log/zlink.log error   <- note: message path differs from the path actually used
0x1458 c:l:             (getopt optstring)
0x1460 *************************is_debug  %d*****************
0x1498 z-link           0x14a0 z-link is running
0x14b4 setprop rw.zlink.channel
0x14d0 cmd = %s
0x14dc libzjL10001.so   0x14ec process_start
```

Behaviour, from the disassembly (`main` 0x111c, `run_process` 0xce8; pc-relative pool resolved as
`(add-instruction addr + 8) + pool word`):

```
main:
 0x115c getopt("c:l:")          0x1458
   'c' (99) -> strdup(optarg) stored as "channel"   (0x1198)
   'l' (108) -> is_debug = 1                        (0x11a8)
 0x11d0 printf("...is_debug %d...", is_debug)       0x1460
 0x11e0 if is_debug -> log_dup_init()               (0xed0)
 0x11f0 check_process_by_name("z-link")             0x1498
 0x120c if already running -> puts("z-link is running"); main returns -1   0x14a0
 0x123c memset(buf,0,256); 0x1278 memcpy(buf+strlen(buf), "setprop rw.zlink.channel ", 26)
 0x1288 strcat(buf, channel); 0x12a0 printf("cmd = %s\n", buf); 0x12ac system(buf)
 0x12b4 system(channel)          <- second system() on the raw optarg (GUESS: dead/leftover code;
                                    with -c hengchangtong this tries to exec "hengchangtong")
 0x12d0 run_process("libzjL10001.so", "process_start")   0x14dc / 0x14ec
run_process(lib, sym):
  dlopen(lib, 1) -> NULL: fprintf(<stderr stream>, "%s\n", dlerror())  (0xd14/0xd28/0xd48)
  else puts("process_channel = 1") (0xd5c) -> dlsym(sym) -> blx (0xd88) -> dlclose (0xd90)
log_dup_init():
  stat/mkdir "/data/local/tmp/zlink_log" -> mkdir -> access/stat "/data/local/tmp/zlink_log/zlink.log"
  -> copy_file(zlink.log -> zlink.old) -> remove(zlink.log) -> open(zlink.log) -> setvbuf x2
  -> dup2(fd, stdout/stderr)          (so the loader and its children log to that file)
find_pid_by_name(name): scans /proc/*/exe via readlink + strncmp; used by check_process_by_name.
```

So `z-link` = a supervisor that (a) prevents a second instance, (b) publishes the platform/channel property
`rw.zlink.channel <optarg>` (stock passes `-c hengchangtong`), (c) `dlopen`s **`libzjL10001.so`** and calls
its exported symbol **`process_start`**. The library is resolved through the `LD_LIBRARY_PATH` that
`z-link.sh` exports, i.e. `/data/data/com.zjinnova.zlink/lib/libzjL10001.so` (the real ZLink/iAP implementation,
not present in the stock system image). `libzjL10001.so` is *only* referenced here - nothing in the inputs
shows its contents -> **UNKNOWN** beyond the symbol name `process_start`.

### 3.2 `/system/bin/z-mdnsd`

```
readelf -h: ELF32 / DYN / ARM   ; NEEDED = libc.so, libdl.so ; .interp /system/bin/linker
rodata: /proc  /proc/%s/exe  z-mdnsd  libzmdnsd.so  start_zlink_mdnsd
main (0x9d8): check_process_by_name("z-mdnsd") -> if running return -1
              else run_process("libzmdnsd.so", "start_zlink_mdnsd")
run_process: dlopen(lib,1) -> on failure fprintf(dlerror) + exit(0); dlsym(sym) -> blx -> dlclose
```
Same pattern as `z-link`: dlopen **`libzmdnsd.so`** (again from `/data/data/com.zjinnova.zlink/lib`) and call
`start_zlink_mdnsd` - the mDNS/DNS-SD advertisement needed for wireless CarPlay/Android Auto (GUESS on the
purpose, solid evidence on the symbol). In `z-link.sh` the `z-mdnsd` start is **commented out**, so the stock
unit relies on the app itself to start mDNS (UNKNOWN which).

### 3.3 `z-link.sh` (the thing init actually runs, verbatim, minus the comment banners)

```sh
#!/system/bin/sh
EXE_PATH=/system/bin/
PLATFORM=hengchangtong
box=`getprop ro.product.project CAR`
if [ "$box" != "BOX" ]; then
	if [ -z "`lsmod | grep usb_f_iap2`" ]; then
	insmod /vendor/lib/modules/usb_f_iap2.ko
	fi
fi
process_mdnsd="z-mdnsd" ; process_link="z-link"
check_process_exist(){ pid=`ps -ef|grep -v grep|grep -v "z-link.sh"|grep $1|sed -n '1P'| awk '{print $2}'`
        if [ -z $pid ]; then echo "no $1 this process"; return 2; else return 1; fi; }
echo "86364000">/proc/sys/net/core/rmem_max
echo '1' > /config/usb_gadget/g1/configs/b.1/MaxPower
mkdir /config/usb_gadget/g1/functions/iap.gs0
mkdir /config/usb_gadget/g1/functions/ncm.gs1
sleep 10
while true;do
	export LD_LIBRARY_PATH=/data/data/com.zjinnova.zlink/lib
	# check_process_exist $process_mdnsd ... (commented out)
	check_process_exist $process_link
	if [ $? == 2 ]; then echo "$process_link start"; $EXE_PATH/z-link -c $PLATFORM&; fi
	sleep 1
done
```
Notes: `ro.product.project` must not be `BOX` for the iAP2 gadget module (BOX builds presumably have it built-in);
`rmem_max` is raised for the NCM/audio socket buffers; gadget config `b.1` MaxPower=1 mA; the loop restarts
`z-link` every second if it died. `z-mdnsd` is disabled here.

### 3.4 `mdnsd.rc` - stock AOSP mDNS daemon, unrelated to z-mdnsd

```
service mdnsd /system/bin/mdnsd
    class main
    user mdnsr
    group inet
    socket mdnsd stream 0660 mdnsr inet
    disabled
    oneshot
```
It is the normal Android `mdnsd` (socket `/dev/socket/mdnsd`, uid `mdnsr`, gid `inet`). The ZLink-specific
`z-mdnsd` is a *separate* binary with no rc entry - it can only be started from `z-link.sh` (currently
commented out) or by the app. **UNKNOWN** who starts it on the stock unit.

## 4. HCT app trees (per APK: what it does with zlink/zjinnova/carplay)

Match counts per tree: HCTBlueToothManager 62 files, HCTCarTouch 55, HCTFactorySettings 58,
HCTManagerService 9, HCTCanBus 1, HCTExtAppDocker 1. Many of the 55/58 hits are generated `R$` resource
classes; the real code is listed below.

### 4.1 HCTManagerService (the HCT "car service" client; the main ZLink orchestrator)

`android/microntek/app/AppManager.smali`
```smali
277: const-string v0, "com.zjinnova.zlink"   ; 279: com.suding.speedplay
285: sput-object v0, AppManager->packageNameCARPLAY:[Ljava/lang/String;
288-298: classNameZlink5 = {CarPlayActivity, AutoActivity, MirrorActivity, DlnaActivity, HiCarActivity, CarPlayAutoActivity}
       (all "com.zjinnova.android.zlink.features.launcher.*")
```
`initMfiDeviceApp()` (method line 2466) is the decision engine. It reads
`persist.sys.zlink.mode.registed`, `persist.sys.easyconn.registed`, and MCU parameters through
`CarManager.getParameters`: `sta_kmode=`, `sta_mfi=`, `cfg_factory_part=100,1` (**CarPlay type**),
`cfg_factory_ext_part=0,1` (HiCar), `5,1` (mirroring), `6,1` (DLNA), `1,1` (EasyConnection);
`usbipod` is enabled/disabled via `HctUtil.setApplicationEnabled(...)`.
Then, per CarPlay type (lines 2744-3135): type "1" -> enable `com.zjinnova.zlink`, disable
`com.suding.speedplay`; type "2" -> enable speedplay, disable zlink; otherwise disable both; individual
ZLink-5 launcher components are enabled/disabled from `rw.zlink.disable.features` + `ro.product.zlink3`
(`classNameZlink5[2]`=Mirror, `[3]`=Dlna, `[4]`=HiCar), and finally:
```smali
2749: const-string v5, "carplay.type"
3068: invoke-static {v5, v1}, SystemProperties->set   (v1 = "1")   <- the ONLY writer of carplay.type found
3123: invoke-static {v5, v0}, SystemProperties->set   (v0 = "2")
```
That is the property stock init watches (`on property:carplay.type=1 -> start z-link`).
`checkZlink5SameEntry_CarPlay_AndroidAuto()` (445) uses `ro.product.project`=="BOX", `ro.product.cpaa`,
`persist.zj.cp_aa_fusion`, `cfg_factory_ext_part=5,1` and MCU version `sta_mcu_ver=` >= "V4.50" to decide
whether CarPlay and Android Auto share one entry point.

`android/microntek/Constant.smali`: `com.zjinnova.zlink` appears in `pknameBoxList` (line 565, 17 packages)
and twice in `ModeAppList` (642/644).

`android/microntek/service/MicrontekServiceBase.smali`
```smali
450: const-string "ro.product.zlink3" -> mbZlink3
17033 startZlink():  if top activity startsWith "com.zjinnova.zlink" -> sendBroadcastAsUser("hct.asr.req.phone.siri")
                    else Intent(MAIN) + ComponentName("com.zjinnova.zlink",
                          mbZlink3 ? "com.zjinnova.zlink.main.view.SplashActivity"
                                   : "com.zjinnova.android.zlink.features.launcher.CarPlayActivity")
                    + addFlags(0x30230000) + startActivityAsUser(CURRENT_OR_SELF)   (wrapped in try/catch)
17121 startZlink(String className): same, with the caller-supplied class; empty class -> startZlink()
13133 startCarLife / 13460 startDlna / 14781 startHiCar / 14852 startHiCar2 / 15234 startMirror
      -> same pattern with CarLifeActivity / DlnaActivity / HiCarActivity / MirrorActivity
10766 isCarPlayConnect(): CarManager.getStringState("mobile_interent_phonemode").contains("carplay")
9317  checkCarPlayCall(pkname,key): pkname in {zlink, speedplay, hicar} and key in {0x13c,0x13d,0x180,0x147}
      -> call keys for the phone-projection apps (GUESS on the key semantics)
      fields: bCarPlayShow, mCarPlayType, carplayPhoneLock
```
`MicrontekServiceBase$8` (169/207/213): reads property-style state `zlink.lastClassName` and calls
`startZlink(className)` - i.e. resume the last ZLink screen.

`android/microntek/service/MicrontekServer.smali`
- `DoPressKeyTask(int)` (method 2040), sparse-switch line 3524: IR key `0x313` (`IR_ZLINK`) ->
  `checkLastSwitchTime()` + `!btLock` -> `startZlink()` (2406). Neighbouring keys: `0x312` ->
  `startEasyconected()` (EasyCar/EasyConn), `0x314` -> `startBtMusic()` (gated by `btLock`,
  `simPhoneLock`, `carplayPhoneLock`), `0x322` = `IR_ANDROID_AUTO`, `0x317` = `IR_AMAZON`.
- `PowerOffAction()` (4356): if CarPlay type "1": if `mbZlink3` -> `SystemProperties.set(packageNameCARPLAY[0], "disable")`
  else `SystemProperties.set("rw.zlink.hu.acc", "true")`; then `Intent("com.zjinnova.zlink")` with extra
  `command` = `"ACTION_EXIT"`, broadcast to `CURRENT_OR_SELF`, then the same Intent gets
  `setPackage(packageNameCARPLAY[0])` and is broadcast again (4425-4452, i.e. one implicit + one packaged send).
- `powerOn()` (8050): line 8542 `SystemProperties.set("rw.zlink.hu.acc","false")`, then
  Intent("zjinnova.android.intent.action.ZLINK_SERVICE") with `setPackage(com.zjinnova.zlink)`
  `sendBroadcastAsUser(..., UserHandle.ALL)` (8551-8570).
- 9018 / 9909: `zlink.lastClassName` state handling; `bCarPlayShow` gates app switching (3160/3219).
- `isConnectWirelessCarPlay()` (7781): `sys.reverse.type == "1"` **and** `hct.wlan.airmode != "0"` -> wireless CarPlay.
- `MicrontekServer$23` (BT/call receiver): `av_phone_carplay=out|in|answer|hangup` -> `setParameters(...)`,
  sets `carplayPhoneLock`, log tag `"carplay"` with `Status:`/`command:`/`regmode:` extras
  (receiver actions include `com.microntek.bt.report`, `com.microntek.active`,
  `com.microntek.STATUS_BAR_CHANGED`); `MicrontekServer$22` uses the string `carplay.apk.close` (1130).

### 4.2 HCTBlueToothManager (`android/microntek/mtcser/`)

`BlueToothService` registers `CarPlayRecev` (= `$13`) on these actions (lines 1516-1522):
`com.zjinnova.zlink`, `com.huawei.hicar`, `com.suding.speedplay`,
`com.suding.speedplay.intent.action.CarPlayPhone`, `com.microntek.carplay.switch`,
`com.microntek.mobile.internet.report`.
`$13.onReceive` reads extras `PhoneStatus`, `status` (`CONNECTED` -> `CarManager.putState("carplay_status", true)`),
`phoneMode` (`auto`/`carlife`...), `type` (`on`/`off` -> `setCarPlayEnable(bool)`), and drives the MCU audio
channel with `CarManager.setParameters`: `av_focus_carplay=music` (1778/1987), `av_focus_carplay=gps` (1963),
plus `av_channel_enter/exit=<channel>`, `av_focus_gain/loss=easyconn` (`$1`, `$2`, `BlueToothService:6879-6956`).
It also writes `carplay_`-prefixed state keys (469) and `carplay_status` (574/777).
Other ZLink touchpoints in `BlueToothService.smali`:
- `ZLINK_ENABLE_HD` (4138), `ZLINK_CONN_BG` (4263), `ZLINK_ENTER_STATE` (`$13:1180`,
  `FSCBW123Model:11623`, `FSCBW123_3Model:12362`), `Reverse_CarPlay` (10665 / models 11642 & 12381) -
  CarManager state names for the wireless/"reverse" CarPlay path.
- audio tuning properties: `persist.sys.zlink.mic.vol`, `persist.zlink.agc.tts`, `persist.zj.agc.phone.spk`,
  `persist.zj.apm.outputvol`, `persist.zj.cp.buffercnt`, `persist.zj.cp.ttsdelay`, `persist.zj.show.started`,
  `rw.zlink.audiostream.tts|phonecall|phonering`, `ro.zlink.disable_aec`, `sys.zlink.cp.oemiconlabel`.
- `rw.zlink.disable.features` (789, 3885), `persist.sys.zlink.disable.features` (get 7800 / set 10020),
  `persist.speedplay.customer.disable` (7832 get, 10073 set), `persist.sys.xcarplay.wireless` (getInt 3802),
  `persist.zj.cp_aa_fusion` (5354), `ro.product.cpaa` (5371), `persist.zj.mirror.device_hotspot` (3944),
  `zj.hct.aa.force.res` (3877 set), `vendor.blueware.iap.mode` (5837 & 10333 set),
  `persist.sys.phone.auto.connection` (5884 set).
- Broadcasts *to* ZLink: `com.zjinnova.zlink.action.BACKCAR_START`/`BACKCAR_STOP` (2839/2864) and
  `com.zjinnova.zlink.action.OUT_DARK_START`/`OUT_DARK_STOP` (3042/3063) - rear-camera and dark-screen
  hand-off to the projection app (GUESS on semantics; action names are the evidence).
- `ReverseBox` (wireless CarPlay over the BT module): opens the serial device **`/dev/carplaySvc_bt`**
  (`ReverseBox.smali:615`), reads/writes MCU frames (`rCarPlay read` 208, `WriteCommand` 867),
  `ZLINK_ENTER_STATE` / `Reverse_CarPlay` state names.

### 4.3 HCTCarTouch (button panel / UI)

`com/hct/screenbutton/TheApplication.smali:668 isCarPlayEnable()`:
`CarManager.getParameters("cfg_factory_part=100,1")` -> "1" = ZLink enabled unless
`persist.sys.zlink.disable.features == "wlab"`; "2" = speedplay enabled unless
`persist.speedplay.customer.disable == "1"`; anything else = disabled.
`com/hct/screenbutton/view/HFloatLayout.smali`: `ACTION_CARPLAY = 0x10`, `ACTION_CHECK_CARPLAY_ENABLE = 0xa1`;
`startCarPlay()` (2934) = `animRemove()` + `sendKey(0x313)` (= `IR_ZLINK`, feeds `DoPressKeyTask`);
line 3341 sends the broadcast `com.microntek.carplay.switch`; drawables `ic_carplay`,
`ic_carplay_pressed`, `btn_carplay`, `btn_carplay_sychbox3`, `ic_carplay_sychbox3_sel`, string `carplay`
(only in the generated `R$` classes).

### 4.4 HCTFactorySettings (the factory settings UI - carplay type values)

`com/hct/factory/Factory_Util.smali` `clinit` line 336-348:
```smali
340: const-string v2, "ZLink"
342: const-string v3, "MultiPlay"
344: filled-new-array {v1, v2, v3}, [Ljava/lang/String;    # v1 = "NO"
348: sput-object v2, Factory_Util->carplaytype:[Ljava/lang/String;
```
=> `carplaytype` = `{"NO", "ZLink", "MultiPlay"}` = spinner index / MCU byte **0 = no CarPlay,
1 = ZLink, 2 = MultiPlay (Speedplay/MultiPlay)**. This matches the MCU parameter `cfg_factory_part=100,1`
read by `AppManager.initMfiDeviceApp()` and the values written into `carplay.type` (1 / 2).
`AppBookFragment` (49 `mCarplayGroup` Spinner, 1047/1059/1077 adapter on `carplaytype`, 1086
`iput-byte -> Hct_Config$ST_FACTORY_CONFIG.mCarPlay`) is the UI; `AppBookFragment$7:65` writes the byte.
`Hct_Config` serialises `mCarPlay` (ST_FACTORY_CONFIG, 50/710/1248) and `mCarPlayAAuto`
(ST_FACTORY_EXT_CONFIG, 38/231/425) to/from the MCU config blob (Hct_Config 1662/2082 write, 3667/4123 read).
`PannelKeyStudy.getIRTableKeyName(int)` (1486) resolves IR key names by reflecting on the class string
`"android.mtc.IRTable"` (so `IR_ZLINK=0x313` gets a display name).
Resources: `mtc_icon_zlink` (drawable), `carplaylayout` (id).
Other settings exposed in `Factory_Util` alongside CarPlay: `hicartype` {NO,YES}, `dvrtype`, `avintype`,
`hdmitype`, `rearpaneltype`, `ipodtype`, `dvdtype`, `radiotype`, `bluetoothtype` (18 BT module names) -
the same spinner pattern, i.e. factory config = one byte per feature in the MCU blob.

### 4.5 HCTCanBus

Only one match: `com/microntek/IRTable.smali:399 .field IR_ZLINK:I = 0x313` (a duplicate of the
framework's `android/microntek/IRTable`). Functionally, CAN/steering-wheel commands translate to that key:
`Canbus161.CmdProc` line 1325 and `Canbus162.CmdProc` line 1980 both `SendKeyCode(0x313)`.

### 4.6 HCTExtAppDocker

`com/microntek/externshow/utils/Utils.smali` `clinit`: `mFliteApp` static list contains
`com.microntek.externshow`, `net.easyconn`, `com.zjinnova.zlink` (line 56), `com.hct.wheelstudy`,
`com.percherry.roundadas`, ... (11 packages). No consumer of `mFliteApp` inside this APK -> **UNKNOWN**
which app reads the list (GUESS: apps allowed to appear in the external/floating docker window).

## 5. Property inventory (`carplay.*`, `*.zlink.*`, `sys.usb.*`, plus the ZJinnova/EasyConn ones)

Scan method: every `const-string` whose value looks like a property name, paired with the nearest
`SystemProperties.get/set/getInt/getBoolean` in the same block, across all smali trees; the loader's
`setprop` was read from its `.rodata` + `system()` call site.

| property | seen value(s) | readers (file:line) | writers (file:line) |
|---|---|---|---|
| `carplay.type` | "1", "2" | init trigger (`analysis/system_init.hct.rc:291,300`), `HCTManagerService AppManager.smali:2749` | `AppManager.initMfiDeviceApp` `:3068` (set "1"), `:3123` (set "2"); **no write for the "no CarPlay" branch** (3130-3135 only disables both packages) |
| `rw.zlink.channel` | platform string, e.g. `hengchangtong` | none in smali -> **UNKNOWN** | `/system/bin/z-link`: builds `setprop rw.zlink.channel <optarg>` (rodata 0x14b4) and runs it via `system()` at 0x12ac |
| `persist.sys.zlink.mode.registed` | contains `w`, `l`, `r` chars (mode flags) | `AppManager:2478`, `services MfiService$UsbReceiver:75` | no writer in inputs -> **UNKNOWN** (GUESS: the ZLink app writes it when it registers the accessory) |
| `persist.sys.zlink.disable.features` | `wlab`, others | `HCTCarTouch TheApplication:708`, `BlueToothService:7800` | `BlueToothService:10020` |
| `rw.zlink.disable.features` | contains `y` | `BlueToothService:789`, `:3885`, `AppManager:2794` | none -> **UNKNOWN** |
| `rw.zlink.hu.acc` | "true"/"false" | none -> **UNKNOWN** (GUESS: read by the ZLink app) | `MicrontekServer:4415` (true), `:8542` (false) |
| `rw.zlink.audiostream.tts` / `.phonecall` / `.phonering` | channel names | none -> **UNKNOWN** (GUESS: audio HAL / ZLink) | `BlueToothService:8850`, `8866`, `8871` |
| `persist.sys.zlink.mic.vol` | number | none -> **UNKNOWN** | `BlueToothService:4156` |
| `persist.zlink.agc.tts` | number | none -> **UNKNOWN** | `BlueToothService:4201` |
| `ro.zlink.disable_aec` | "true"/"false" | `BlueToothService:8895` | none -> **UNKNOWN** (build.prop) |
| `sys.zlink.cp.oemiconlabel` | label | none -> **UNKNOWN** | `BlueToothService:8918` |
| `ro.product.zlink3` | "true"/"false" | `AppManager:2776`, `MicrontekServiceBase:450`, and in `libaudioflinger.so` (string 0x123e7, ref 0x2c1a0) | none -> **UNKNOWN** (build.prop) |
| `ro.product.cpaa` | "1" | `AppManager:473`, `BlueToothService:5371` | none -> **UNKNOWN** |
| `persist.zj.cp_aa_fusion` | "true"/... | `AppManager:475`, `BlueToothService:5354` | none -> **UNKNOWN** |
| `persist.zj.apm.outputvol` / `.agc.phone.spk` / `.cp.buffercnt` / `.cp.ttsdelay` / `.show.started` | numbers / flags | none -> **UNKNOWN** | `BlueToothService:4151`, `4194`, `4204`, `4240`, `4221` |
| `persist.zj.mirror.device_hotspot` | flag | `BlueToothService:3944` | none -> **UNKNOWN** |
| `zj.hct.aa.force.res` | value | none -> **UNKNOWN** | `BlueToothService:3877` |
| `persist.sys.xcarplay.wireless` | int | `BlueToothService:3802` (`getInt`) | none -> **UNKNOWN** |
| `persist.speedplay.customer.disable` | "1" | `HCTCarTouch TheApplication:743`, `BlueToothService:7832` | `BlueToothService:10073` |
| `persist.sys.easyconn.registed` | "true"/... | `AppManager:2486`, `MfiService$UsbReceiver:83` | `BlueToothService$11:59` |
| `persist.sys.phone.auto.connection` | "true"/"1" | `MfiService$UsbReceiver:117`, `services UsbProfileGroupSettingsManager:2907` | `BlueToothService:5884` |
| `sys.reverse.type` | "1" | `MicrontekServer:7787` (`isConnectWirelessCarPlay`) | none -> **UNKNOWN** |
| `hct.wlan.airmode` | "0"/other | `MicrontekServer:7801` | none -> **UNKNOWN** |
| `sys.car.reverse` | value | none -> **UNKNOWN** | `MicrontekServiceBase$1:92` |
| `sys.suding.reverse.connect` | value | `MicrontekServiceBase:10368` | none -> **UNKNOWN** |
| `vendor.blueware.iap.mode` | BT-module iAP mode | none -> **UNKNOWN** | `BlueToothService:5837`, `:10333` |
| `sys.ship.package` | shipped/launcher package | `ActivityStackSupervisor:11383` (`switchDualScreen`), `MicrontekServer:725`, `11500`, `$1:411`, `libsurfaceflinger.so` (0x42d0e, refs 0xf1834/0xf18ac) | `services ActivityStack:6945` |
| `sys.hct.debug` | "true"/"false" | `services MfiService:300` (LOG gate) | none -> **UNKNOWN** |
| `com.zjinnova.zlink` **used as a property name** | "disable" | none -> **UNKNOWN** | `MicrontekServer PowerOffAction:4405-4410` (`set(packageNameCARPLAY[0], "disable")`) - an unusual property literally named after the package |
| `sys.usb.config` / `sys.usb.state` / `persist.sys.usb.config` | stock AOSP values | `UsbDeviceManager$UsbHandler:593`, `$UsbHandlerLegacy:84/86`, `AdbService$AdbHandler:34` | `UsbDeviceManager$UsbHandler:2403`, `$UsbHandlerLegacy:630/649/1046/1328` |
| `sys.usb.mtp.device_type` | int | `framework MtpDatabase:378` | none |
| `sys.usbcam.status.forvideo`, `persist.sys.usbcamera.status` | stock camera hack | `UsbDeviceManager:960/962` | same lines (`set`) - not ZLink-related |

**Note:** nothing in the inputs writes `sys.usb.config` to an iAP/CarPlay configuration. The USB gadget for
CarPlay is built outside Android's USB stack, directly in configfs by `z-link.sh`
(`/config/usb_gadget/g1/functions/iap.gs0`, `ncm.gs1`, `configs/b.1/MaxPower`). Also `ro.product.rotate`,
`ro.product.project`, `ro.product.customer.sub` drive the framework hooks (section 1.1) and are read-only
(build props); `carplay.type` is the only dynamic CarPlay switch, and `AppManager.initMfiDeviceApp()` is its
only writer found.

## 6. Gap list for the Android 14 port (one line each, with evidence)

1. Framework package hooks missing in the A14 `framework.jar` (orientation override + `mAppFilterPackages`
   exemption incl. `com.zjinnova.zlink`, `OneConnect` label for `ro.product.customer.sub=HXD2`) - evidence 1.1a/b/d.
2. `ActiveServices.startServiceLocked` package exemption (background service start without foreground
   conversion) not present in A14 `services.jar`; A14 additionally enforces foreground-service start rules -
   evidence 1.3; A14 equivalent lives in `ActiveServices`/`ForegroundService` type code.
3. `broadcastIntentLocked` receiver-dispatch exemptions for `com.zjinnova.zlink` / `zjinnova.android.` are
   absent (A14 keeps the stock `FLAG_RECEIVER_FOREGROUND` behaviour) - evidence 1.4; A14 also needs
   `RECEIVER_EXPORTED`/`RECEIVER_NOT_EXPORTED` at `registerReceiver` (targetSdk 34), which the stock HCT
   receivers do not pass (evidence 4.2).
4. `switchDualScreen()` rear-screen exemption for ZLink/speedplay/easyconn: the class
   `ActivityStackSupervisor` no longer exists on A14 (replaced by `ActivityTaskManager`/`TaskSupervisor`),
   so the hook must be re-implemented there - evidence 1.5.
5. No runtime-permission grant for `com.zjinnova.zlink` in A14 `DefaultPermissionGrantPolicy`
   (storage/mic/phone/location) - evidence 1.6; on A14 the list should also cover
   `BLUETOOTH_CONNECT`/`NEARBY_WIFI_DEVICES` if the app needs them (no evidence either way -> UNKNOWN).
6. Wi-Fi permission bypass by uid (`com.zjinnova.zlink`) missing; A14 moved Wi-Fi into the mainline
   `WifiService` module, so the bypass must go into that module's `WifiPermissionsUtil` - evidence 1.7.
7. The two HCT binder services are not started on A14: `"mfiservice"`
   (`com/android/server/microntek/MfiService`, JNI `native_attach/detach/send/start/stop`, stream buffer +
   `AudioTrack`) and `"carservice"` (`CarService`, `/dev/ttyV2`, `av_*`/`cfg_factory_*` parameters), and the
   AIDL classes `android.microntek.ICarService`, `android.microntek.CarManager`,
   `android.microntek.mfi.{IMfiService,IMfiCallback,IMfiListener,MfiManager}` are missing from A14
   `framework.jar` - evidence 1.8/1.9 (SystemServer 3619-3638) and 4.x (`MfiManager:60`, `CarManager:44`).
8. No init entry for CarPlay on A14: stock has `on property:carplay.type=1 -> start z-link` +
   `service z-link /system/bin/z-link.sh` (and `carplay.type=2 -> sd-link`) - evidence
   `analysis/system_init.hct.rc:291-307`.
9. SELinux: the stock service runs as `u:r:shell:s0` (rc line 298); A14 needs a dedicated domain that can
   dlopen `/data/data/com.zjinnova.zlink/lib/*.so`, write `rw.zlink.channel`, open `/dev/mtc-av`,
   `/dev/ttyV2`, `/dev/carplaySvc_bt`, `/config/usb_gadget/g1/*` and `/proc/sys/net/core/rmem_max`
   - evidence 3.1/3.2/3.3 (paths in `.rodata` and `z-link.sh`).
10. The USB gadget functions `iap.gs0` + `ncm.gs1` and the kernel module
    `/vendor/lib/modules/usb_f_iap2.ko` are outside AOSP's USB stack (no `iap` function in
    `UsbDeviceManager`/Usb HAL) - evidence 3.3; A14 must ship the module and keep the gadget config
    (`configs/b.1/MaxPower`).
11. `z-link` and `z-mdnsd` are **ELF32 / Machine ARM** (`readelf -h`) - they cannot run on an arm64-only
    Android 14 build; they need arm64 rebuilds or 32-bit ABI support.
12. The implementation itself is absent: `libzjL10001.so` (symbol `process_start`) and `libzmdnsd.so`
    (symbol `start_zlink_mdnsd`) live in `/data/data/com.zjinnova.zlink/lib`, and the app
    `com.zjinnova.zlink` is not installed - evidence 3.1/3.2 + the parent's stated fact.
13. Nobody writes `carplay.type` on A14 (its only writer is `AppManager.initMfiDeviceApp()` in
    HCTManagerService), so `carplay.type=1` alone never starts anything - evidence 5 + 4.1.
14. The whole HCT app set (HCTManagerService, HCTBlueToothManager, HCTCarTouch, HCTFactorySettings,
    HCTCanBus, HCTExtAppDocker) is what talks to ZLink (IR key `0x313`, `com.zjinnova.zlink` broadcasts,
    `av_phone_carplay=*`, `carplay_status`, `/dev/carplaySvc_bt`) - none installed on A14 - evidence 4.1-4.6.
15. A14's stock `libaudioflinger.so` / `libsurfaceflinger.so` / `libstagefright.so` lack the HCT patches
    (`/dev/mtc-av` + `av_*` routing, AppOps `OP_RECORD_AUDIO` package whitelist, `mtc-car/display_mode`,
    projection-package layer cropping, the `ACodec` zlink case) - evidence 2.1/2.2/2.3; `/dev/mtc-av` is not
    among the nodes the parent reports on A14.
16. mDNS for wireless CarPlay/Android Auto: `z-mdnsd` has no rc entry and its start is commented out in
    `z-link.sh`; `mdnsd.rc` only describes AOSP `mdnsd` (`user mdnsr`, `socket mdnsd`) - evidence 3.2/3.4;
    UNKNOWN who starts mDNS on the stock unit, so the A14 plan must decide (enable `z-mdnsd` or let the app).
17. `rw.zlink.channel` is only written by the loader (`setprop rw.zlink.channel hengchangtong`) and no smali
    reads it - evidence 5; if the loader is not ported, the platform/channel property stays empty.
18. Direct-boot awareness: stock forces `directBootAware`/`encryptionAware` for `com.microntek.`/`com.hct.`
    activities; if the HCT apps are installed on an encrypted A14 unit they must declare it themselves,
    otherwise `carservice`/`mfiservice`-backed UI won't run before unlock - evidence 1.1c.

## Summary (10 lines)

1. ZLink integration in the stock firmware is 5 layers: framework hooks, HCT binder services
   (`mfiservice`/`carservice`), patched native libs, the `z-link`/`z-mdnsd` loaders + configfs gadget, and the
   HCT apps that orchestrate it; the protocol itself lives in the app's private `libzjL10001.so`.
2. The single switch is `carplay.type`, written only by `AppManager.initMfiDeviceApp()` from the MCU
   parameter `cfg_factory_part=100,1` (0=NO, 1=ZLink, 2=MultiPlay) - init maps 1->`z-link`, 2->`sd-link`.
3. Framework.jar special-cases `com.zjinnova.zlink`: rotation exemption (`ro.product.rotate`/`project=BOX`),
   `OneConnect` label for customer sub `HXD2`, `IR_ZLINK=0x313`.
4. services.jar exempts it from foreground service conversion (`ActiveServices`) and from the HCT
   `FLAG_RECEIVER_FOREGROUND` broadcast patch (`ActivityManagerService`), and skips the rear-screen switch
   (`ActivityStackSupervisor.switchDualScreen`).
5. `DefaultPermissionGrantPolicy` grants ZLink storage/mic/phone/location at boot; `wifi-service`
   `WifiPermissionsUtil` lets its uid change/override Wi-Fi config without permissions.
6. `MfiService` (JNI: attach/detach/send/start/stop + an `AudioTrack`/`PlayThread` stream) is the iAP
   accessory bridge, triggered by `USB_DEVICE_ATTACHED` with Apple vendor id 0x5ac, filtered by
   `persist.sys.zlink.mode.registed` / `cfg_factory_part=100,1`; apps reach it via `MfiManager`/"mfiservice".
7. `CarService`/"carservice" is the MCU bridge (`/dev/ttyV2`, `setParameters("av_...=...")`,
   `cfg_factory_part`/`ext_part`, `sta_*` states); HCT apps send `av_focus_carplay=music|gps` and
   `av_phone_carplay=in|out|answer|hangup`; AudioFlinger mirrors the same keys to `/dev/mtc-av`.
8. `z-link` dlopens `/data/data/com.zjinnova.zlink/lib/libzjL10001.so` and calls `process_start`, publishes
   `rw.zlink.channel`, single-instance-checks itself and redirects its log to `/data/local/tmp/zlink_log`;
   `z-mdnsd` dlopens `libzmdnsd.so` and calls `start_zlink_mdnsd` (not started by `z-link.sh`).
9. Native libs are arm64 and stripped: AudioFlinger adds `av_*` routing + AppOps record-audio whitelisting,
   SurfaceFlinger reads `mtc-car/display_mode` and crops layers for the projection/nav packages, libstagefright
   has one `com.zjinnova.zlink` check inside `ACodec::BaseState::onOutputBufferDrained` (purpose UNKNOWN).
10. Biggest A14 gaps: no init/rc entry + `shell` SELinux domain, no `iap.gs0`/`ncm.gs1` gadget or
    `usb_f_iap2.ko`, both loaders are 32-bit ARM, no `mfiservice`/`carservice` + AIDL classes, no framework/
    services/wifi hooks, no HCT apps (so nothing writes `carplay.type` or talks to ZLink), no app or its libs,
    and unpatched audio/surfaceflinger/stagefright (`/dev/mtc-av` missing too).
