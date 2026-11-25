> **CORRECTION (2026-11-25, verified on the unit):** this report's root cause is wrong. The kernel writes the frame length **little-endian**, which is what `HctUtil.getInt2` reads, so `getFramePos` parses kernel frames correctly (measured 2026-11-25 on `/dev/ttyV2` (raw mode): status frames `fa 16 c0 02 00 79 00`, key frames `fa 16 4e 02 00 11 01` (key 0x0111) - the length `02 00` is **little-endian** and frames arrive on **ttyV2**). Do NOT apply the proposed `getInt` change: it would break every frame. The real cause was the tty mode: CarService's `FileInputStream` left `/dev/ttyV2` canonical with echo; with the port raw, keys work end to end (vol+ shows the volume slider). The dispatch chain in sections 2-4 below is correct. See `docs/findings.md`.

# HCT key-frame trace (Android 14 port) — read-only smali analysis

Paths abbreviated:
- `mgr` = /home/Daan/vbf-work/a14-work/hctport/step2/mgr_smali (running APK)
- `fw`  = /home/Daan/vbf-work/a14-work/hctport/s10fw2/android/microntek (framework android.microntek.*)

## 1. Frame parsing: HctUtil.getFramePos + CarService.DataProc/cmdProc

### getFramePos (mgr/com/android/server/microntek/HctUtil.smali:439)
```
439: .method public static getFramePos([BII)I
456: aget-byte v2, p0, v0        ; buf[i]
458: const/4 v3, -0x6          ; 0xFA as signed byte
460: if-ne v2, v3, :cond_24    ; sync byte must be 0xFA
467: sub-int v3, p2, v0        ; remaining = size - framestart
469: const/4 v4, 0x5 ; 471: if-lt v3, v4 -> return -1  (needs >= 5 bytes left)
474: add-int/lit8 v3, v0, 0x3  ; length field at framestart+3
478: invoke-static {p0, v3, v5}, HctUtil->getInt2([BII)I   ; v5=2
482: add-int/2addr v3, v4      ; len = value + 5
486: add-int v4, v3, v2 ; 488: -1 -> frameend = framestart + len - 1
492: sub-int v5, p2, v0 ; 494: if-lt v5, v3 -> return -1 (frame not complete yet)
497: shl-int/lit8 v1, v4, 0x10 ; 499: or -> return (frameend<<16)|framestart
```

### getInt2 is **little-endian** (mgr/com/android/server/microntek/HctUtil.smali:560)
```
578: shl-int/lit8 v2, v0, 0x8          ; dat <<= 8
580: add-int v3, p1, p2                ; index = start + size
582: add-int/lit8 v3, v3, -0x1
584: sub-int/2addr v3, v1              ; index = start + size-1-i  (last byte FIRST)
586: aget-byte v3, p0, v3
```
For size=2 this yields `dat = buf[start+1]<<8 | buf[start]` = **little-endian u16**.
(HctUtil.getInt at :521 is the big-endian variant, and it is NOT the one getFramePos uses.)

### ~~MISMATCH — the kernel's length field is big-endian, getFramePos reads little-endian~~ (WRONG: the wire is little-endian, see the correction at the top)
Kernel frame: `FA 16 4E <len u16 BE> payload`. getFramePos reads buf[framestart+3], buf[framestart+4].
For payload_len < 256 the kernel writes `0x00 <len>`, so getInt2 returns `len<<8 | 0x00` = len*256.
`len_computed = len*256 + 5`, then the completeness check at HctUtil.smali:494 (`remaining < len`) is
always true for any real frame (remaining is ~len+3), so getFramePos **returns -1**.

CarService.DataProc (mgr/com/android/server/microntek/CarService.smali:585) → :651 getFramePos,
:659 `if-ne v2, -1` → :662 `goto :goto_3d` — i.e. it leaves the bytes in serialRevBuf and never calls
cmdProc. The tail is then compacted (:693-712), and on the *next* read `DataProc` resets
`bufRevCount` to 0 whenever `bufRevCount + size < 0x1000` (:591-602, serialRevBuf is 0x1000 bytes, :181-185),
so the unparsed frame is simply discarded — the key frame disappears instead of accumulating.

**Consequence: cmdProc is never reached for kernel key frames at all.**
Once the length is parsed correctly, cmdProc reads cmd1 = buf[framestart+1], cmd2 = buf[framestart+2],
and the key code as `getInt2(buf, framestart+5, 2)` = `buf[framestart+6]<<8 | buf[framestart+5]`
(CarService.smali:2521-2523) — i.e. a little-endian u16 at payload offset framestart+5
(3-byte header + 2-byte length). That matches the kernel's LE code semantics; if the kernel's payload
really starts at buf[4] (as stated: code = `buf[4] | buf[5]<<8`) then cmdProc is one byte late —
worth verifying against a real capture (§5).

### CarService.DataProc → cmdProc dispatch (mgr/com/android/server/microntek/CarService.smali)
```
585: .method private DataProc([BI)V
651: getFramePos(serialRevBuf, startpos, p2)
659: if-ne v2, -1 → :goto_3d   ; no frame → bytes stay buffered, nothing dispatched
683: cmdProc(serialRevBuf, framestart, frameend)
```
cmdProc (CarService.smali:1034): cmd1 = buf[start+1] (:1045-1049), cmd2 = buf[start+2] (:1053-1057),
new Bundle (:1065). Top-level cmd1 switch (:1126 cmd1==0x15 → cond_75a; :1136 cmd1==0x16 → cond_42c;
:1144 cmd1==0x1f → cond_376; :1146 packed-switch cmd1 0x10..0x13).

cmd1 == 0x16 handler = **:cond_42c, CarService.smali:2288**. cmd2 values tested there:
explicit `if-eq` 0x6e(:2289), 0x83(:2293), 0x8f(:2297), 0x98(:2301), 0xa2(:2305), 0xa8(:2309),
0xbb(:2313), 0xc4(:2319), 0xc5(:2321), then packed-switches (:3453 starts 0x40, **:3470 starts 0x4e**,
:3478 starts 0x60, :3487 starts 0xc0). If none match → plain `return-void` (:2334).

**cmd2 == 0x4E IS handled** → pswitch_data_852 (CarService.smali:3470-3476, first entry) →
`:pswitch_4fd` (CarService.smali:2520):
```
2521: add-int/lit8 v0, p2, 0x5          ; payload at framestart+5
2523: HctUtil.getInt2(buf, start+5, 2)  ; dat = buf[start+5]<<8 | buf[start+4]  (LE = kernel key code)
2530: bundle.putString("type", "key")
2535: bundle.putInt("value", dat)
2538: const-string v0, "KeyDown"
2540: dispatchCallback("KeyDown", bundle)
```
So a kernel key frame becomes callback type **"KeyDown"** with Bundle keys
`type="key"`, `value=<u16 code>` (0x111/0x119/0x102/0x128/0x131/0x136...).
Sibling: cmd2 0x4f→"start_dvd", 0x50→"start_ipod", 0x51→"start_app" (CarApp); cmd2 0x60/0x61→
"PanelStudyKey", 0x62/0x63→"SwStudyKey" (CarService.smali:2419-2465).

dispatchCallback (CarService.smali:3578) walks `mCallbacks:Landroid/os/RemoteCallbackList` (:141,
typed for `Landroid/microntek/ICarManageCallback;`, :145) and calls
`ICarManageCallback.onStatusChanged(type, bundle)` (:3618). If mCallbacks is empty nothing happens.

## 2. Who listens for "KeyDown", and what it does

Registration (running code, mgr_smali):
- `ManageService.onCreate` (android/microntek/service/ManageService.smali:646-673) creates
  `new com.android.server.microntek.CarService(context)` (:667) and `ServiceManager.addService("carservice", binder)` (:673);
  `StartCarService()` (:367-384) starts `android.microntek.service.MicrontekServer` via `startServiceAsUser`.
- `MicrontekServer.onCreate` (MicrontekServer.smali:7418; attach at :7438-7440):
  `mCarManager.attach(new MicrontekServer$3(this), "CarEvent,CarPower,KeyDown,CarApp")`.
  `CarManager` ctor does `ServiceManager.getService("carservice")` + `ICarService$Stub.asInterface`
  (s10fw2/android/microntek/CarManager.smali:44-54); `attach(Handler,String)` calls
  `ICarService.registerCallback(mCarManageCallback)` (CarManager.smali:170) → CarService.registerCallback
  adds it to `mCallbacks` (CarService.smali:9599). Note attach only registers if BOTH mHandler and
  mListener are null (CarManager.smali:140-170) — a second attach on the same CarManager is silently ignored.
- Callback lands in `CarManager$1.onStatusChanged` (s10fw2/android/microntek/CarManager$1.smali:29):
  `mType.contains(type)` then posts `Message.what = -1 (MSG_ON_STATUS)` to the handler →
  `MicrontekServer$3.handleMessage` (MicrontekServer$3.smali:36-57) → `s_onStatusChanged`.

Handler chain for type "KeyDown":
- `MicrontekServer.s_onStatusChanged` (MicrontekServer.smali:5930, "KeyDown" test at :5983) → `DoCarKeyDown(bundle)` (:5992)
- `DoCarKeyDown` (MicrontekServer.smali:873): requires bundle `type=="key"` (:886), reads `value` (:897),
  calls `ReportEvent("key", keycode)` (:903 → broadcast `com.microntek.report.event`, extra type/value,
  `sendBroadcastAsUser(UserHandle.ALL)`, MicrontekServiceBase.smali:4775-4803), clears music clock for
  0x111/0x119 (:906-916), then `DoPressKeyTask(keycode)` (:920), `ChangeKeyTab(keycode)` (:923),
  optional Toast when `Settings.System "hal_key_replacement_show"` != 0 (:929-965).
- `DoPressKeyTask` sparse-switch (MicrontekServer.smali:1274, table at :2040):

| code | smali | action |
|---|---|---|
| 0x100 | :sswitch_278 (:2016) | `mHandler.sendEmptyMessage(14)` (MicrontekServer$1 `pswitch_df`) |
| 0x102 mute | :sswitch_274 (:2009) | `MuteSwitch()` → `getParameters("av_mute=")` → `setParameters("av_mute=true|false")` + `SendVolStatus` (MicrontekServiceBase.smali:4350) |
| 0x111 vol+ | :sswitch_26c (:1998) | `mHandler.sendEmptyMessage(11)` → MicrontekServer$1 `pswitch_f3` (:337) → `MTCAdjVolume(1)` |
| 0x115 | :sswitch_262 (:1985) | `startGFsel()` |
| 0x119 vol- | :sswitch_25a (:1974) | `mHandler.sendEmptyMessage(10)` → MicrontekServer$1 `pswitch_fa` (:346) → `MTCAdjVolume(0)` |
| 0x128 | :sswitch_244 (:1948) | `hal_application_replacement_dvd` → `RunApp(pkg)` else `startDVD(1)` (launches `com.microntek.dvd.MainActivity`, MicrontekServiceBase.smali:9197+) |
| 0x129 / 0x12a / 0x12f | :sswitch_22e (:1922) / :22a (:1915) / :226 (:1908) | startRadio / LoudSwitch / EQSwitch |
| 0x131 | :sswitch_20e (:1878) | `startGPS()` |
| 0x134 back | :sswitch_209 (:1869) | `SystemKey(4 /*KEYCODE_BACK*/, 0)` |
| 0x135 | :sswitch_202 (:1860) | `SystemKey(0x52 /*KEYCODE_POWER*/, 0)` |
| 0x136 home | :sswitch_1ec (:1834) | `mDualHomeMode==1` → `sendEmptyMessage(17)` else `sendEmptyMessage(16)` |
| 0x13c / 0x13f / 0x140 / 0x141 / 0x147 | :1812 / :1782 / :1756 / :1749 / :1727 | startBT / startAux / startDTV / startSettings etc. |

- `MicrontekServer$1` (the `mHandler` set in the ctor, MicrontekServer.smali:215) handles those messages:
  msg 10 → `MTCAdjVolume(0)` (:346), msg 11 → `MTCAdjVolume(1)` (:337), msg 17 → `pswitch_6c` (:169) →
  `SystemKey(3 /*KEYCODE_HOME*/, 0)`, msg 16 → `pswitch_79` (:186) → double-click logic
  (`mHomeDoulbe++`, if <3 `sendEmptyMessageDelayed(17, 600ms)` (:235), else `HCTApi.switchDualScreen()` (:221)).
- `MTCAdjVolume` (MicrontekServiceBase.smali:3069) does **not** call AudioManager.adjustStreamVolume: it reads
  `Settings.System "av_volume="` / `"av_phone_volume="` (:3124) and calls `setVolume(vol±1, true)` (:3151 / :3168),
  which writes `Settings$System.putInt` (:7843) and `setParameters("av_volume=<realVol>")` (:7865) — the actual
  volume change happens in the MCU/amplifier through CarService's native `setParameters`; `ShowVolumeDalog(vol)` (:3178)
  draws the HCT VolumeDialog. `AudioManager.setStreamVolume(III)` is used only elsewhere (MicrontekServiceBase.smali:5129).
- `SystemKey` (MicrontekServiceBase.smali:5270) builds a `KeyEvent(..., flags|=8|64, device=-1, source=0x101)` and
  injects it with `InputManager.getInstance().injectInputEvent(ev, 0)` (:5332 / :5336), then the UP event (:5373/:5377);
  the framework twin `android.microntek.HCTApi.SystemKey` does the same (s10fw2/android/microntek/HCTApi.smali:634/638, 675/679).
- Alternative entry point in CarService: `CarService$2` BroadcastReceiver for action
  `com.microntek.irkeyDown` (CarService$2.smali:48, extra `keyCode` :57) →
  `dispatchCallback("KeyDown", {type="key", value})` (:96) — i.e. IR-remote apps can drive the same path (VolumeController.smali:198/234/263 sends that broadcast).
- Other HCT apps in /system/app also register CarManager listeners (dex strings `android/microntek/CarManager` +
  `KeyDown`): HCT4Radio, HCT4Music, HCT4Movie, HCT4UsbIpod, HCT4BtMusic, HCT4BlueTooth, HCTDvd, HCTExtMovie,
  HCTExtMusic, HCTCarCD, HCTCivicusbipod, HCT8AmpSetup, HCTSync, HCTTv, HCTUpdateService — they consume app-specific
  keys, not vol+/vol-/mute/home; HCTFactorySettings is `HCTFactorySettings.apk.disabled-attempt28` (disabled).
  HCTExtAppDocker / HCTExtScreenClock / HCTBlueToothManager / HCTCanBus dirs in system-new16.img are empty.

## 3. A10 code that we do NOT run (and would also have handled keys)

- `a10fw/s10svc/com/android/server/policy/PhoneWindowManager.smali`: patched-in hooks
  `sendHctKeyCode(I)` (:8503) and `sendBoxKeyCode(I)` (:8457) — build `Bundle{type="key", value}` and call
  `CarManager.dispatchMessage("KeyDown"/"BoxKeyDown", bundle)`. Call sites at :15430 (BoxKeyDown) and
  :15485/:15494/:15508/:15514, inside the intercept/dispatch path keyed on Android keycodes
  0x55 (VOL_UP), 0x57 (VOL_DOWN), 0x58 (VOL_MUTE), 0x79, 0x7e → HCT codes 0x101/0x12b/0x12c (:15465-15514).
  Also `mKeyMouseHandler.sendEmptyMessage(code)` for codes 0x118/0x119/0x11a/0x11b/0x120 (:4193-4216) and
  `mCarManager` field (:287, initialised :900).
- `a10fw/s10svc/com/android/server/SystemServer.smali:3586` created `com.android.server.microntek.CarService`
  in system_server (and :2300-2302 started `android.microntek.service` / `ManageService`).
- The A14 services.jar/framework.jar copies in /tmp/opencode/fw contain **no** `microntek` classes and no
  `sendHctKeyCode` (byte-search of framework/classes.dex..5, services/classes.dex..3 = False), so none of the
  PhoneWindowManager hooks exist in the running A14 build; CarService now lives in the APK and is published by
  ManageService instead (see §2).
- A10 `com/android/server/microntek/HctUtil.smali:560-601` (getInt2) is byte-identical to the A14 copy
  (`diff` rc=0), i.e. the app-side protocol always expected a little-endian length field.

## 4. API availability on Android 14 (`tools/dex_api_check.py`)

- `step2/classes32.dex` vs A14 framework+x+services dexes: `app invoke refs: 1014`, **no missing methods**;
  the only "not resolvable here" entries are classes outside those dexes (`android/microntek/CarManager`,
  `HCTApi`, `ICarService$Stub`, `ICarManageCallback`, `mfi/MfiManager` — defined in `out/hct-framework.jar`,
  33 classes, installed at `/system/framework/hct-framework.jar` and listed in `/system/etc/classpaths/bootclasspath.pb`;
  plus WifiManager/ConnectivityManager/PackageHelper/java.io/java.lang).
- `out/hct-framework.jar/classes.dex` vs A14 framework: also **no missing methods** (242 refs).
- Symbols that exist but are @hide / restricted on A14 (runtime risk, not link failure):
  - `InputManager.getInstance()Landroid/hardware/input/InputManager;` and
    `InputManager.injectInputEvent(Landroid/view/InputEvent;I)Z` — present in the A14 dexes
    (services/classes2.dex defines both, framework/classes2.dex the rest of InputManager), used by
    `MicrontekServiceBase.SystemKey` (:5332) and `HCTApi.SystemKey` (:634). `injectInputEvent` needs
    `android.permission.INJECT_EVENTS` (uid system ⇒ ok).
  - `AudioManager.setStreamVolume(III)`/`adjustStreamVolume(III)` exist (framework/classes3.dex), unused by this path.
  - `Settings$System.getInt/putInt` exist (framework/classes3.dex) — writing custom keys `av_volume=`/`av_mute=`
    needs WRITE_SETTINGS, fine for uid system.
  - `Context.sendBroadcastAsUser(Intent, UserHandle.ALL/CURRENT_OR_SELF)` and `startServiceAsUser` are used
    (MicrontekServiceBase.smali:4803, ManageService.smali:384) — allowed for uid system.

## 5. Conclusion + minimal fix

~~Root cause~~ (WRONG, see the correction at the top): the length field of a kernel frame is read little-endian by `HctUtil.getInt2`
(mgr/com/android/server/microntek/HctUtil.smali:578-590) while the kernel writes it big-endian at
framestart+3 (:474-478). `len = value + 5` therefore becomes `payload_len*256 + 5`, the completeness test
at :494 fails, `getFramePos` returns -1, and `CarService.DataProc` (:659) drops the bytes without ever
calling `cmdProc` (:683). Nothing else in the chain is broken: cmd2=0x4E *is* handled (:3470 → :2520) and
MicrontekServer is attached ("CarEvent,CarPower,KeyDown,CarApp", MicrontekServer.smali:7438-7440).

Minimal change: make the length read byte-order match the kernel — one instruction pair.
~~Either (a) patch `HctUtil.getFramePos` to use the big-endian helper~~ (DO NOT; it would break parsing): replace
`getInt2(buf, framestart+3, 2)` (HctUtil.smali:478) with `getInt(buf, framestart+3, 2)` (defined at :521),
or (b) change the kernel to write the length little-endian (then payload must also start at framestart+5,
matching cmdProc's code read at CarService.smali:2521-2523: `code = buf[start+5] | buf[start+6]<<8`).
With that single change vol+/vol-/mute/home reach `DoPressKeyTask` → `MTCAdjVolume` / `MuteSwitch` /
`SystemKey(KEYCODE_HOME)`.
Secondary thing to verify after that: the kernel's stated code location (`buf[4]|buf[5]<<8`) vs cmdProc's
payload offset (`framestart+5` = buf[5] and buf[6]); if the kernel's payload really begins at buf[4] the code
is read one byte late. And `SystemKey` depends on `InputManager.getInstance()` (hidden API from APK-loaded
code; `HCTApi.SystemKey` is exempt because hct-framework.jar is on the boot classpath).
