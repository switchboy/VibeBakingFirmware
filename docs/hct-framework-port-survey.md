# HCT / Microntek framework layer — A10 → A14 (LineageOS 21) port survey

Survey date: 2026-11-24. Inputs read read-only; all new files written under `/home/Daan/vbf-work/a14-work/hctport/`. No adb, no writes to `/run/media`.

## 0. Artifacts produced

| artifact | how produced | notes |
|---|---|---|
| `s10fw2/` | `java -jar baksmali-2.5.2.jar d a10fw/fw10/classes2.dex -o s10fw2` | whole dex = 7169 smali files, of which **33** are `android/microntek/*` |
| `s10fw1/` | baksmali `fw10/classes.dex` (5083 files) | framework.jar part 1 |
| `s10fw3/` | baksmali `fw10/classes3.dex` (4459 files) | framework.jar part 3 |
| `s10svc2/` | baksmali `svc10/classes2.dex` (726 files) | services.jar part 2 |
| `build/hct_svc.dex` | `smali a a10fw/s10svc/com/android/server/microntek -o build/hct_svc.dex` | 22 classes, 67 KB |
| `build/hct_fw.dex` | `smali a --api 29 s10fw2/android/microntek -o build/hct_fw.dex` | 33 classes, 63 KB (needs `--api 29`, hiddenapi flags) |
| `api_svc_vs_fw.txt`, `api_svc_vs_fwsvc.txt`, `api_fw_vs_fw.txt`, `api_both_vs_fwsvc.txt` | `dex_api_check.py` runs (§4) | |
| `hooks/hook_summary.txt`, `hooks/hook_summary2.txt`, `hooks/*_hooks.txt` | scripts below | hook inventory (§5) |
| `scripts/jni_tables.py`, `scripts/jni_table_dump.py`, `scripts/adrp_strings.py`, `scripts/hooks.sh`, `scripts/hook_aggregate.py`, `scripts/hook_aggregate2.py`, `scripts/a14_api{2,3}.py` | analysis helpers | |

baksmali 2.5.2 syntax is `d`/`disassemble`, not `dex`. smali needs `--api 29` because baksmali emits hiddenapi modifiers (`blacklist`/`greylist`) on every microntek member — these classes are **hidden API** in A10, so an app cannot call them through the normal SDK (relevant when porting: keep the same hiddenapi flags or expose them).

---

## 1. `fw10/classes2.dex`: HCT classes (baksmali → `s10fw2/`)

Only **one** HCT package exists: `android/microntek` (+ `android/microntek/mfi`). There are **no** `com/hct` or `android/hct` classes in any of the three framework dexes (`grep -rn 'Lcom/hct\|Landroid/hct'` over `s10fw1 s10fw2 s10fw3` → 0 hits); `com.hct.*` appears only as **package-name string literals** (permission exemptions, see §5).

### 1.1 `android/microntek` — 15 classes (33 files incl. inner classes)

| class | `.super` | kind | native methods | notes (evidence) |
|---|---|---|---|---|
| `CarListener` | `Object` | app callback **interface** (`onStatusChanged(String,Bundle)` throws RemoteException) | none | `CarListener.smali:1,12` |
| `CarManageCallback` | `ICarManageCallback$Stub` | concrete AIDL stub base for apps | none | `CarManageCallback.smali:2,11` |
| `CarManager` | `Object` | client proxy (framework-side manager) | none | fields `mCarService:Landroid/microntek/ICarService;`, `mCarManageCallback`, `mListener:CarListener`, `mHandler` (`CarManager.smali:13-19`); `const-string "carservice"` + `ServiceManager;->getService` at **lines 44-46**; `ICarService$Stub.asInterface`; `registerCallback` at 123/170 |
| `CarManager$1` | `CarManageCallback` | inner callback → forwards to `Handler` + `CarListener.onStatusChanged` | none | `CarManager$1.smali:2,132` |
| `HCTApi` | `Object` | **static utility** (52 methods), hidden-API `blacklist` | none (`grep -c 'native '` = 0) | `HCTApi.smali:572 SystemKey(II)V`, `939 getAllStackInfos`, `2102 getFocusedStackInfo`, `2722 getStackInfo(II)`, `2974 hasSecondScreenActivityStack`, `3641 moveStackToDisplay(II)`, `3682 removeStack(I)`, `3744 setFocusedStack(I)`, `3880 switchDualScreen`, plus `getHCTResource`, `getHctwmPloy`, `isHCTMediaApp`, `getHCTAppWhiteProcessAdj`, `isFulltAppLists`, `IsSupportBleBluetooth`, `ActivityIsRun`, `TopActivityPackageName`, `NaviBarHeight`, `StatusBarHeight`, `Density160DpiPackagesLists` … |
| `ICarManageCallback` | `Object`, `implements android/os/IInterface` | AIDL interface | none | DESCRIPTOR `android.microntek.ICarManageCallback` (`ICarManageCallback$Stub.smali:27`); method `onStatusChanged(String,Bundle)V` |
| `ICarManageCallback$Stub` | `android/os/Binder` | AIDL stub | none | + `$Stub$Proxy`, `$Default` |
| `ICarManageCallback$Stub$Proxy` / `$Default` | `Object` | AIDL proxy / default | none | |
| `ICarService` | `Object`, `implements IInterface` | AIDL interface, 26 methods | none | DESCRIPTOR `android.microntek.ICarService` (`ICarService$Stub.smali:27`); methods: `dispatchMessage(String,Bundle)`, `getBooleanState`, `getByteArrayState`, `getByteState`, `getEqIdx`, `getIntArrayState`, `getIntState`, `getLud`, `getParameters(String)String`, `getStringArrayState`, `getStringState`, `getVideoEnable`, `putBooleanState`, `putByteArraryState`, `putByteState`, `putDataChanage`, `putIntArraryState`, `putIntState`, `putStringArraryState`, `putStringState`, `registerCallback(ICarManageCallback)`, `setEqIdx(I)`, `setLud(Z)`, `setParameters(String)I`, `setVideoOverSpeed(Z)`, `unregisterCallback` |
| `ICarService$Stub` | `android/os/Binder` | AIDL stub | none | + `$Stub$Proxy` (2910 lines), `$Default` |
| `IRTable` | `Object` | static IR-code table, **152 constants** | none | e.g. `IR_AB=0x16b`, `IR_AF=0x14e`, `IR_AJX_ENTER=0x139`, `IR_MUTE=0x102`, `IR_VOLUP=0x111`, `IR_VOLDOWN=0x119`, `IR_VOL_SLIDE=0xe`, `IR_KEY_SCREEN_CLOCK=0x321` |
| `MTCData` | `Object` | static key/DSP state data, **52 fields** | none | `MAX_BALANCE=0x1c` etc.; uses `DisplayMetrics.setToDefaultsDensity` (§4 MISSING) |
| `mfi/MfiListener` | `Object` | interface `onConnected()V`, `onDisconnected()V` | none | |
| `mfi/MfiReport` | `Object` | interface `onReceive([B)V` | none | |
| `mfi/MfiManager` | `Object` | client proxy | none | `const-string "mfiservice"` + `getService` **lines 60-62**; `IMfiService$Stub.asInterface` line 66; `register(MfiReport)` line 222 |
| `mfi/MfiManager$1` | `Object` | inner | none | |
| `mfi/MfiManager$ICallback` | `IMfiCallback$Stub` | inner AIDL stub | none | `MfiManager$ICallback.smali` |
| `mfi/MfiManager$IListener` | `IMfiListener$Stub` | inner AIDL stub | none | |
| `mfi/IMfiCallback` (+Stub/Stub$Proxy/Default) | Stub→`Binder` | AIDL, DESCRIPTOR `android.microntek.mfi.IMfiCallback`, `onReceive([B)V` | none | |
| `mfi/IMfiListener` (+Stub/Stub$Proxy/Default) | Stub→`Binder` | AIDL, DESCRIPTOR `android.microntek.mfi.IMfiListener`, `onConnected()/onDisconnected()` | none | |
| `mfi/IMfiService` (+Stub/Stub$Proxy/Default) | Stub→`Binder` | AIDL, DESCRIPTOR `android.microntek.mfi.IMfiService`, methods `focusGain()V`, `focusLoss()V`, `isConnected()Z`, `register(IMfiCallback)`, `registerListener(IMfiListener)`, `send([B)`, `start()`, `stop()`, `unregister()`, `unregisterListener(IMfiListener)` | none | Stub$Proxy 925 lines |

**Zero native methods in the whole framework-side microntek package.** All JNI lives on the services side (§3).

### 1.2 Other vendor packages in the same dex (Rockchip, not HCT)

| class | super | kind | service name |
|---|---|---|---|
| `android/os/audio/RkAudioSettingManager` | `Object` | manager (7 methods) | `ServiceManager.getService("rockchip_audio_setting")` (`RkAudioSettingManager.smali:33`) |
| `android/os/audio/IRkAudioSettingService` (+Stub/Proxy/Default) | Stub→`Binder` | AIDL | — |
| `android/os/RkDisplayOutputManager` | `Object` | manager (33 methods) | `getService("drm_device_management")` (`RkDisplayOutputManager.smali:383`) |
| `android/os/IRkDisplayDeviceManagementService` (+Stub/Proxy/Default) | Stub→`Binder` | AIDL | — |

None of these exist in A14 (`grep -al 'RkAudioSetting\|IRkDisplayDeviceManagementService' /tmp/opencode/fw/framework/*.dex /tmp/opencode/fw/x/*/classes.dex` → 0 hits). They are separate from the HCT work but live in the same dex, so if you rebuild framework.jar's microntek classes you must decide about them too.

### 1.3 A14 baseline is clean

`grep -c microntek` over `/tmp/opencode/fw/framework/*.dex` = 0 for all five dexes; the only `hct` hits in `/tmp/opencode/fw/fwsmali` are unrelated (`com/android/internal/graphics/cam/HctSolver.smali`, lambda names). So none of the A10 hooks below exist in A14 — they all have to be re-applied.

---

## 2. How CarService / MfiService are created and registered in A10

Both are instantiated in **`SystemServer.startOtherServices()`** (method starts at `s10svc/com/android/server/SystemServer.smali:2330`) — i.e. *after* SerialService, before the media/telephony services. No other file instantiates them.

| service | smali evidence (`a10fw/s10svc/com/android/server/SystemServer.smali`) | Java line (from `.line`) |
|---|---|---|
| **CarService** | `3579 const-string v0,"Car Service"` → `traceBeginAndSlog`; **`3584 const-string v0,"carservice"`**; `3586 new-instance v6,Lcom/android/server/microntek/CarService;`; **`3588 invoke-direct {v6,v4},CarService;-><init>(Landroid/content/Context;)V`**; **`3590 ServiceManager;->addService(String,IBinder)`**; failure path `3603 const "mtc >>>> Failure starting CarService"` → `reportWtf` | 1196-1202 |
| **MfiService** | `3614 const "Car Mfi Service"` → trace; **`3619 const "mfiservice"`**; `3621 new-instance …MfiService`; **`3623 invoke-direct …MfiService;-><init>(Context)V`**; **`3625 ServiceManager.addService`**; failure path `3638 const "mtc >>>> starting mfiservice"` | 1204-1208 |

Service names as seen by clients: `"carservice"` (CarManager, AudioManager, AudioService, MediaFocusControl via `getStringState`) and `"mfiservice"` (MfiManager). Both take only `Context` in the constructor (no `SystemService` base, both are plain `Binder`s: `CarService extends android.microntek.ICarService$Stub`, `MfiService extends android.microntek.mfi.IMfiService$Stub`).

Extra HCT hook in the same class — an **APK** service, not a framework service:

```
.method static final startMtcManage(Landroid/content/Context;)V   # SystemServer.smali:2286
  2300 const-string v2, "android.microntek.service"
  2302 const-string v3, "android.microntek.service.ManageService"
  ... Intent.setComponent(...) ; Context.startServiceAsUser(intent, UserHandle.OWNER)
```
called from `lambda$startOtherServices$4$SystemServer` (`SystemServer.smali:8242 const "startMtcManage"`, `8248 invoke-static {p1}, startMtcManage`), i.e. the "critical services ready / servicesReady" runnable. Package `android.microntek.service` (the HCT ManageService APK) is **not** present in framework.jar/services.jar — it ships as a system app, so the port needs that APK plus the component start.

---

## 3. CarService natives, JNI registration, and the MCU event path

### 3.1 Every `.method ... native` in the microntek services package

`com/android/server/microntek/CarService.smali` (248 KB, `extends android.microntek.ICarService$Stub`):

| method | smali line | signature |
|---|---|---|
| `native_getParameters` | `CarService.smali:9113` | `(Ljava/lang/String;)Ljava/lang/String;` |
| `native_setParameters` | `CarService.smali:9116` | `(Ljava/lang/String;)I` |

`com/android/server/microntek/MfiService.smali` (7 static natives):

| method | line | signature |
|---|---|---|
| `native_attach` | 844 | `(Ljava/lang/String;)Z` |
| `native_class_init` | 847 | `()V` |
| `native_detach` | 850 | `()Z` |
| `native_init` | 853 | `(Lcom/android/server/microntek/OnMfiServiceCallback;I)Z` |
| `native_send` | 856 | `([B)Z` |
| `native_start` | 859 | `()Z` |
| `native_stop` | 862 | `()Z` |

`HctUtil`, `HCT_CMD*`, `OnMfiServiceCallback`: no natives. `OnMfiServiceCallback` (`OnMfiServiceCallback.smali`) declares `connected()V`, `disconnected()V`, `receive([BI)V`, `stream([BI)V`, `stream_off()V`, `stream_on(II)V` — implemented by `MfiService$1` (methods at `MfiService$1.smali:39,224,447,526,853,967`).

### 3.2 JNI registration in `libandroid_servers10.so` (aarch64, 651 KB)

Symbols (§ all addresses are file offset == vaddr for `.rodata`/`.data` in this file):

| symbol | addr | size |
|---|---|---|
| `android::register_android_server_microntek_CarService(JNIEnv*)` | `0x87f28` | 116 |
| `android::register_android_server_microntek_MfiService(JNIEnv*)` | `0x88a38` | 116 |
| `android::MfiCallback::receiveCb(const hidl_string&)` | `0x881d8` | 316 |
| `android::MfiCallback::streamCb(int)` | `0x884e0` | 352 |
| `android::MfiCallback::streamOnCb(int,int)` | `0x88768` | 188 |
| `android::MfiCallback::streamOffCb()` | `0x88828` | 172 |
| `android::MfiCallback::connectedCb()` | `0x888d8` | 172 |
| `android::MfiCallback::disconnectedCb()` | `0x88988` | 172 |
| `android::NativeCallbackThread` (ctor/enqueue/threadLoop) | `0x43120`/`0x43740`/… | — |
| `JNI_OnLoad` | `0x89f00` | 460 |

Both registrations are the **last two calls of `JNI_OnLoad`**:

```
8a094: bl <register_android_server_microntek_CarService@plt>
8a09c: bl <register_android_server_microntek_MfiService@plt>
```

Registration bodies (`llvm-objdump -d --start-address=0x87f28 --stop-address=0x87f9c`):

```
87f38: adrp x1,0x30000 ; add x1,#0x7fc   -> 0x307fc "com/android/server/microntek/CarService"   ; JNIEnv->FindClass (slot 0x30)
87f4c: cbz x0 -> failure branch
87f54: adrp x1,0x30000 ; add x1,#0x7fc   -> same class name
87f58: adrp x2,0x90000 ; add x2,#0x160   -> JNINativeMethod table @0x90160
87f68: orr w3,wzr,#0x2                    -> count = 2
87f70: b <jniRegisterNativeMethods@plt>
87f74/87f80 (failure): log tag "CarServiceJNI" (0x3171f),
                       "Can't find com/android/server/microntek/CarService" (0x2db9d), returns -1
```

Mfi registration (`0x88a38`): FindClass `"com/android/server/microntek/MfiService"` (string `0x30824`), table `0x90000+0x190 = 0x90190`, **count = 7** (`orr w3,wzr,#0x7`), failure log `"MfiJni: Can't find com/android/server/microntek/MfiService"` (string `0x2dfdd`, tag `"Mfi"` @0x2e940).

**JNINativeMethod tables (24-byte entries `{name*,sig*,fn*}`)** — dumped with `scripts/jni_table_dump.py`:

| table | offset | entries | content |
|---|---|---|---|
| SerialPort | `0x90140` | 1 shown | `nativeClose` `([Ljava/io/FileDescriptor;)V` fn `0x81688`, then `0xffffffff` sentinel |
| **CarService** | **`0x90160`** | **2** | `native_setParameters` `(Ljava/lang/String;)I` → fn **0x87fa0**; `native_getParameters` `(Ljava/lang/String;)Ljava/lang/String;` → fn **0x88060** |
| **MfiService** | **`0x90190`** | **7** | `native_class_init ()V`→0x88ab0; `native_init (Lcom/android/server/microntek/OnMfiServiceCallback;I)Z`→0x88d60; `native_send ([B)Z`→0x89110; `native_start ()Z`→0x892b8; `native_stop ()Z`→0x89340; `native_attach (Ljava/lang/String;)Z`→0x893c8; `native_detach ()Z`→0x894b8 |
| GNssLocationProvider | `0x944d0`…`0x949f8` | ~37 | `native_get_batch_size`, `native_inject_time`, … (AOSP, unrelated) |
| UsbDeviceManager/alsa | `0x97780`…`0x977c8` | 5 | `native_open`, `native_new`, `native_delete`, `native_start_loop`, `native_add_bridge` (AOSP) |

A pointer scan (`scripts/jni_tables.py`, scanning `.rodata/.data/.data.rel.ro/.got/.got.plt/.init_array` for 8-byte pointers to any `native_*`/microntek string) finds **no other table referencing microntek strings** — i.e. CarService really has exactly 2 registered natives, MfiService exactly 7. `.data.rel.ro` (0x91010-0x98be0) contains no HCT tables.

Native implementations:

```
native_setParameters @0x87fa0:
  87fb8 adrp/add -> 0x2f80c "/dev/mtc-car" ; 87fc0 orr w1,#0x2 ; bl __open_2@plt   (O_RDWR)
  87fe4 ldr x8,[x8,#0x548] ; blr -> JNIEnv->GetStringUTFChars
  87ff0 bl strlen@plt ; 87ff8 ioctl(fd, strlen(str), str) ; 8800c close(fd)
  88020 ldr x8,[x8,#0x550] ; blr -> ReleaseStringUTFChars ; returns ioctl result
  failure branch: log "CarServiceJNI" + "could not open mtc-car" (0x35c55), returns -1
native_getParameters @0x88060:
  __open_2("/dev/mtc-car", O_RDWR) ; GetStringUTFChars ; strlen
  880b4 adrp x24,0x99000 ; ldr x24,[x24,#0x840]  -> static response buffer pointer in .got
  880d0 __memcpy_chk(buf, str, len) ; 880d4 orr w1,w23,#0x10000 -> ioctl(fd, len|0x10000, buf)
  close ; ReleaseStringUTFChars ; tail branch to JNIEnv+0x538 (NewStringUTF(buf)) -> returns MCU answer
```

So the CarService JNI is a **request/response ioctl channel on `/dev/mtc-car`** (write: ioctl request = strlen, read: ioctl request = strlen|0x10000 into a static buffer). It has **no callback thread, no reader, no event fd** — nothing in libandroid_servers pushes events into CarService. `android::NativeCallbackThread` is used only by the **Mfi** HAL callbacks.

Mfi side uses a vendor HIDL HAL: `.dynsym` has 11 UND symbols of `android::hardware::mtc::mfi::V1_0::IMfi/IMfiCallback`, and `DT_NEEDED` includes **`android.hardware.mtc.mfi@1.0.so`**. `native_class_init` calls `IMfi::getService()` + `linkToDeath` (logs `"MfiJni: class_init"`, `"MfiJni: Transaction error in linking to MfiHAL death: %s"`, `"MfiJni: Link to death notification successful"`, `"MfiJni: Unable to link to MfiHal death notifications"`), and `native_init` (0x88d60) does `GetMethodID` on the `OnMfiServiceCallback` object with strings:

```
0x88e0c "receive"    sig 0x2ce6b "([BI)V"
0x88e28 "stream"     (+ "stream_on" 0x2f819 / "(II)V" 0x2e860, "stream_off" 0x2d5ad / "()V")
0x88eac "connected"  0x88ed4 "disconnected" (both "()V")
```
Each HAL callback (`receiveCb`, `streamCb`, `streamOnCb`, `streamOffCb`, `connectedCb`, `disconnectedCb`) marshals onto a `NativeCallbackThread` (`"MfiJni: Thread env"`, `"Unable to attach thread. Error %d"`, `"data message queue read failed for \"read\""`) and calls the Java method, logging `"MfiJni: An exception was thrown by callback '%s'"` on failure; on HAL death it logs `"MfiJni: Abort due to IMFI hidl service failure, restarting system server"` (0x89550/0x351e2).

### 3.3 How CarService receives MCU events — four distinct paths

There is **no `UEventObserver`, no `FileObserver`, no inotify, no `InputManager` reader inside CarService** (`grep -rn 'UEventObserver\|FileObserver\|Inotify' a10fw/s10svc` → hits only in `BatteryService$1`, `ThermalManagerService$1`, `DockObserver`, `ExtconUEventObserver`, and unrelated FileObservers in storage/firewall/wallpaper).

**Path A — serial frames from the MCU (`/dev/ttyV2`), read by a Java thread:**

```
CarService.initComm()  (CarService.smali:4378)
  4386 const "serial" ; getSystemService -> android/hardware/SerialManager  (field mSerialManager, :161)
  4399 ByteBuffer.allocate(0x1000) -> mInputBuffer (:157)
  4409 const "/dev/ttyV2" ; 4411 const 0x9600 (=38400 baud)
  4413 SerialManager.openSerialPort(String,I)Landroid/hardware/SerialPort; -> mSerialPort (:163)
  4425-4434 new Thread(new CarService$3(this$0)); Thread.start()
  4440 log "mtc >>> open /dev/ttyV2 fail!" ; 4456 "mtc >>> open /dev/ttyV2 Exception !"
CarService$3.run()  (CarService$3.smali:39, enclosing method CarService->initComm)
  59  mInputBuffer.clear()
  76  SerialPort.read(mInputBuffer) -> ret
  83-99 if ret>0: new byte[ret]; buffer.get(...)
  105 CarService.access$800(this$0, buffer, ret) -> private DataProc([BI)V
  122 log "mtc >>> read /dev/ttyV2 Exception !"
CarService.DataProc([BI)V  (CarService.smali:587)
  accumulates into static serialRevBuf:[B (:123) / bufRevCount (:121), cap SERIALBUFSIZE=0x1000 (:117)
  653 HctUtil.getFramePos(buf,pos,size) -> packed (framestart:frameend)
  685 CarService.cmdProc(buf, framestart, frameend)
frame format (HctUtil.getFramePos, HctUtil.smali:439): byte 0xFA (signed -6) starts a frame;
  2-byte BE length at framestart+3; len = value + 5; frameend = framestart + len - 1.
cmdProc([BII)V (CarService.smali:1036): cmd1 = buf[start+1], cmd2 = buf[start+2] (:1047-1061);
  debug gate sysprop "sys.hct.debug" (:1075) -> log "CarService  cmdProc >>> cmd1:" …;
  dispatch: cmd1==0x15 (:1128), cmd1==0x16 (:1138, type string "CarEvent", "backview", "value"),
  cmd1==0x1f (:1140), packed-switch 0x10..0x13 (:3407 pswitch_data_7e6: DVD_A_RSP/DVD_A_RPT_DVD_TYPE/
  DVD_A_INT_MSG/DVD_A_CMD_MUTE), packed-switch 0x0f..0x15 (:3415), and sub-switches 0x20-0x29 (:3426),
  0x31-0x35 (:3440), 0x40-0x42 (:3449), 0x40-0x4c (:3456), 0x4e-0x51 (:3473), 0x60-0x64 (:3481), 0xc0-0xc2 (:3490)
  -> dispatchCallback(type, bundle) at lines 1179,1195,1335,1367,1428,1501,1936,1995,…,3317,3378
  command constants: HCT_CMD$CarCmd CAR_A_CMD_KEY_PRESS=0x6, CAR_A_CMD_KEY_MODE=0x7, CAR_A_RPT_*
  (BOOTCOMPLETE=0x5, ON=0x8, OFF=0x9, ACC_ON=0xa, ACC_OFF=0xb, BACKVIEW_START=0xc, ANDROID=0x3, …),
  CAR_A_CFG_* 0x20..0x2e (incl. CAR_A_CFG_KEY=0x22, CAR_A_CFG_SWKEY=0x23), DVD_Key DVD_A_INT_MSG=0x12,
  INT_Cmd INT_A_TOUCH_KEY=0x1, INT_A_TOUCH_XY=0x0, INT_A_TOUCHDOWN=0x3, INT_A_TOUCHUP=0x4
key-ish handling in cmdProc (lines 1153-1195): cmd1 0x13/cmd2 0x12 -> bundle{type:"key", value:HctUtil.getInt2(buf,start+5)}
  -> dispatchCallback("Dvd", bundle); cmd2==0x3 -> {type:"eject"} -> dispatchCallback("Dvd")
dispatchCallback(String,Bundle) (:3580) iterates mCallbacks:Landroid/os/RemoteCallbackList (:141),
  check-cast ICarManageCallback (:3606) -> ICarManageCallback.onStatusChanged(type,bundle) (:3617)
Outbound (Android -> MCU) is NOT the serial port: it is native_setParameters/native_getParameters
  (ioctl /dev/mtc-car). ctor: 522 native_setParameters("rpt_service_ready=true");
  BootCompletedReceiver$1.run (:73) native_setParameters("rpt_boot_complete=true");
  ctor reads MCU state: native_getParameters("sta_ill=","sta_orientation=","sta_driving=","cfg_advchip=",…)
  (:277,312,345,378,434) -> sysprops "hct.hub.sta"=1/0 (:447/457), "cvbs_available", "av_channel",
  "handbrake", "headlight", "orientation", "cfg_advchip=", "sta_hub=", "sta_driving=", "sys"
Extra inbound channel: CarService.onTransact override (:9119) handles custom code **0x484354**
  (= ASCII "HCT") -> Parcel.readInt() "audio", bundle{type:"audio", value:audio},
  dispatchCallback("CarBox", …), log "mtc >>> onTransact CarBox Audio:"
```

**Path B — broadcast from the framework (`com.microntek.irkeyDown`):**

```
CarService ctor (:495-511): IntentFilter "com.microntek.irkeyDown" (:502),
  registerReceiver(CarkeyProc, filter) (:511); field CarkeyProc:Landroid/content/BroadcastReceiver (:129),
  constant MSG_MTC_IRKEY_DOWN = "com.microntek.irkeyDown" (:113)
CarService$2.onReceive (:36): action equals "com.microntek.irkeyDown" (:48/50) ->
  getIntExtra("keyCode") (:68) -> bundle{type:"key" (:82), value:keyCode (:87)} ->
  dispatchCallback("KeyDown"/"Dvd" …) (:97), constant "KeyDown" (:94)
Sender: framework.jar classes3.dex PhoneWindow.onKeyDown (:7322) calls
  SendVolUP/SendVolDOWN/SendVolMute (:7398/7391/7405 -> methods :552/:494/:523) which sendBroadcast
  Intent "com.microntek.irkeyDown" with extra keyCode = IR_VOLUP 0x111 / IR_VOLDOWN 0x119 / IR_MUTE 0x102
  (values from android.microntek.IRTable)
```

**Path C — hardware key presses (the `--mtc key 0111` kernel log).** The MCU key driver logs in the kernel and delivers the press as an ordinary **input event** into `InputManagerService`/`InputDispatcher`; Java sees a real `KeyEvent`. The HCT hook that consumes it is in **services.jar `PhoneWindowManager.interceptKeyBeforeQueueing(KeyEvent,int)`** (`a10fw/s10svc/com/android/server/policy/PhoneWindowManager.smali:15068`):

```
15392/15423/15434 sget-boolean isCarBox   (set in <clinit> :707 from ro.product.project == "BOX"; field :185)
15403 log "----------hct car box keyCode=" + keycode + " down="   (tag "WindowManager")
15430 invoke-direct sendBoxKeyCode(keycode)          -> CarManager.dispatchMessage("BoxKeyDown", {type:"key", value:keycode})  (:8457, calls :8493-8497)
15462 checkHctAuioApp() (:1867); keycodes tested: 0x55('U'), 0x57('V'), 0x58('X'), 0x7e('~'), 0x79('y')
15485/15508/15514 invoke-direct sendHctKeyCode(...)  -> CarManager.dispatchMessage("KeyDown", {type:"key", value:...}) (:8503, :8539-8543)
        remapped IR values: 0x12b (:15485 branch), 0x12c (:15494/15508 branch), passthrough when isMusicActive() (:15501 -> :6934)
15525 sysprop "hct.media.focus" consulted; 15533/15546 packages "com.microntek.btmusic" / "com.microntek.widget.btplay"
```
`CarManager.dispatchMessage` (:231/:257) forwards to `ICarService.dispatchMessage` → `CarService.dispatchMessage(String,Bundle)` (:8342) → `dispatchCallback` (:8359) → registered `ICarManageCallback`s, i.e. HCT apps receive `{type:"key", value:<IR/key code>}` and act on it.

`CarService.SystemKey(II)V` (:836) builds two `KeyEvent`s (`:868`/`:894` `KeyEvent.<init>(JJIIIIIIII)` with `source=0x101`, flags `code|0x8|0x40`) and injects them with `InputManager.getInstance().injectInputEvent(ev, mode)` (:898/902 and :939/943) — but **it is never called anywhere in services.jar** (`grep -rn 'SystemKey'` finds only the definition), so it is dead code in CarService. The live injector is the framework-side twin:

```
android/microntek/HCTApi.SystemKey(II)V   (s10fw2/android/microntek/HCTApi.smali:572)
  identical body: KeyEvent.<init> (:630, :671), InputManager.getInstance() (:634/:675),
  injectInputEvent (:638, :679)
callers (services.jar): com/android/server/audio/MediaFocusControl.requestAudioFocus(...)
  3197 HCTApi.SystemKey(0x7f /*KEYCODE_MEDIA_PLAY*/, flags) when sendKey (pkg starts with "com.microntek."
          or "com.hct." (:2947/:2956) and focus result == 3)
  3329 HCTApi.SystemKey(0x56 /*KEYCODE_MEDIA_PLAY_PAUSE*/, flags)
  2986-2994 new CarManager().getStringState("navi_package") -> "hctploy", sysprop "hct.media.focus" (:3202)
also services.jar classes2.dex: com/android/server/wm/ActivityStackSupervisor$ActivityStackSupervisorHandler.handleMessage
  152 HCTApi.SystemKey(...) (:152) after CarManager.getIntState (:128)
A14 keeps both APIs needed for this path: InputManager.getInstance() and injectInputEvent(InputEvent;I)Z exist
  (also injectInputEvent(InputEvent;II)Z), KeyEvent.<init>(JJIIIIIIII) exists.
```

**Path D — Mfi/MFI accessory events:** vendor HIDL HAL `android.hardware.mtc.mfi@1.0` → JNI `android::MfiCallback::{connectedCb,disconnectedCb,receiveCb,streamCb,streamOnCb,streamOffCb}` → `NativeCallbackThread` → Java `OnMfiServiceCallback` (implemented by `MfiService$1`) → `IMfiCallback.onReceive([B)` / `IMfiListener.onConnected/onDisconnected` to apps via `MfiManager` (`mfiservice`). No file/uevent watching here either (`/dev/usb_accessory` string in the .so belongs to AOSP UsbDeviceManager JNI).

---

## 4. Dependency check against A14 (`dex_api_check.py`)

Assembled app dexes: `build/hct_svc.dex` (only `com/android/server/microntek`, 22 classes — **the only `com/android/server/*` types it references are its own package**):

```
grep -rho 'Lcom/android/server/[A-Za-z0-9/_$]*;' a10fw/s10svc/com/android/server/microntek/ | sort -u
  -> CarService, CarService$1..$4, CarService$BootCompletedReceiver(+1), HCT_CMD(+5 inner), HctUtil,
     MfiService(+4 inner), OnMfiServiceCallback  — all microntek, no stock com/android/server deps
```
So **nothing extra had to be added** to the dex; the stock `com/android/server` classes referenced are absent (only `SystemServer` instantiates them, §2).

Framework dex set used for `--framework`: `/tmp/opencode/fw/framework/*.dex` (5) + `/tmp/opencode/fw/x/*/classes.dex` (8) = 36885 classes; the `+services` variant adds `/tmp/opencode/fw/services/*.dex` (3) = 52810 classes.

| run | app | framework | result |
|---|---|---|---|
| `api_svc_vs_fw.txt` | `build/hct_svc.dex` | A14 framework + x | **MISSING: (none)**, 276 invoke refs, 27 unresolved classes |
| `api_svc_vs_fwsvc.txt` | `build/hct_svc.dex` | + A14 services | **MISSING: (none)**, 276 refs, 27 unresolved |
| `api_fw_vs_fw.txt` | `build/hct_fw.dex` | A14 framework + x | **9 MISSING** (below), 260 refs, 12 unresolved |
| `api_both_vs_fwsvc.txt` | `hct_fw.dex` + `hct_svc.dex` | + A14 services | same **9 MISSING**, 493 refs, 24 unresolved |

MISSING list (from `android.microntek`, all inside `HCTApi`/`MTCData`; verified independently by raw string search — none of these strings exist in any A14 framework/services dex):

| missing API | caller evidence (`build/fw/android/microntek/…`) | A14 replacement (confirmed present in A14 dexes) |
|---|---|---|
| `android/app/IActivityManager->getAllStackInfos()Ljava/util/List;` | `HCTApi.smali:939/956` | `IActivityManager.getAllRootTaskInfos()Ljava/util/List;` / `IActivityTaskManager.getAllRootTaskInfos()` |
| `android/app/IActivityManager->getFocusedStackInfo()Landroid/app/ActivityManager$StackInfo;` | `HCTApi.smali:2102/2111` | `getFocusedRootTaskInfo()Landroid/app/ActivityTaskManager$RootTaskInfo;` |
| `android/app/IActivityManager->removeStack(I)V` | `HCTApi.smali:3682/3692` | `removeTask(I)Z` / `IActivityTaskManager.removeTask(I)Z` |
| `android/app/IActivityManager->setFocusedStack(I)V` | `HCTApi.smali:3744/3754` | `setFocusedRootTask(I)V` / `setFocusedTask(I)V` |
| `android/app/IActivityTaskManager->getStackInfo(II)Landroid/app/ActivityManager$StackInfo;` | `HCTApi.smali:3537/3602` | `getRootTaskInfo(II)Landroid/app/ActivityTaskManager$RootTaskInfo;` / `getRootTaskInfoOnDisplay(III)` |
| `android/app/IActivityTaskManager->hasSecondScreenActivityStack()Z` | `HCTApi.smali:2974/2983` | **no equivalent** — HCT-added AIDL method; must be implemented in A14 `ActivityTaskManagerService` |
| `android/app/IActivityTaskManager->moveStackToDisplay(II)V` | `HCTApi.smali:3641/3652` | `moveRootTaskToDisplay(II)V` (A14 ATMS also has `RootActivityContainer.moveStackToDisplay` gone) |
| `android/app/IActivityTaskManager->switchDualScreen()V` | `HCTApi.smali:3880/3889` | **no equivalent** — HCT-added; needs A14 ATMS/WM implementation |
| `android/util/DisplayMetrics->setToDefaultsDensity(IF)V` | `HCTApi.smali:2422/2564` (also `MTCData`) | `setToDefaults()V` exists; `getDeviceDensity()I` exists; HCT's `setToDefaultsDensity(IF)` was an added member → re-add or compute density via `persist.hctbox.density`/`persist.carbox.density` |

Classes `android/app/ActivityManager$StackInfo` and `android/app/ActivityManager$TaskInfo` are **not defined** in any A14 dex (`StackInfo`/`TaskInfo` as descriptors: `RootTaskInfo` replaced them) — so every `StackInfo`-typed API in HCTApi has to be rewritten onto `ActivityTaskManager$RootTaskInfo`.

Unresolved-but-fine entries (boot classpath outside these dexes / app-internal): `Ljava/lang/*`, `Ljava/util/*`, `Ljava/io/*`, `java/nio/ByteBuffer`, `java/lang/reflect/Method`, `Lorg/xmlpull/v1/XmlPullParser`, plus the microntek classes when the two dexes are checked separately (`android/microntek/CarManager`, `ICarManageCallback`, `ICarService$Stub`, `mfi/IMfiCallback`, `mfi/IMfiListener`, `mfi/IMfiService$Stub`) and `Landroid/net/wifi/WifiManager;` (lives in a wifi jar not extracted — used by `HCTApi.SoftApBAND`). `android/hardware/SerialManager.openSerialPort(String,I)` and `android/hardware/SerialPort.read(ByteBuffer)`, `android/os/UEventObserver.startObserving(String)` and `android/os/ServiceManager.addService/getService` all still exist in A14.

Tool caveat: `dex_api_check.py` compares descriptor-form class names (`Landroid/app/IActivityManager;`) and reads its header fields at `0x38`; results matched reality here (raw `grep -a` over the A14 dexes confirms each missing symbol is genuinely absent).

---

## 5. HCT hooks inside stock AOSP code (must be reproduced)

Method = enclosing `.method` in the baksmali tree; line numbers are smali lines. Trees: `s10fw1` = fw10/classes.dex, `s10fw2` = fw10/classes2.dex, `s10fw3` = fw10/classes3.dex, `a10fw/s10svc` = svc10/classes.dex, `s10svc2` = svc10/classes2.dex. Files under `android/microntek` / `com/android/server/microntek` excluded. Full dumps: `hooks/hook_summary.txt` (microntek-symbol hits, 60 class::method sites) and `hooks/hook_summary2.txt` (adds sysprop/`hct*` name hits, 103 sites).

### framework.jar classes.dex (`s10fw1`)

| class | method | hook |
|---|---|---|
| `android/app/ActivityManager` | `static checkComponentPermission(String,IIZ)I` (513,522,531) | bypass permission check for prefixes `com.microntek.`, `com.hct.`, `android.microntek.` |
| `android/app/ContextImpl` | `setResources(Resources)V` (10683) | `HCTApi.getHCTResource(context, res, name)` wrap |
| `android/bluetooth/BluetoothSocket` | `<init>(IIZZBluetoothDevice,IParcelUuid,ZZ)`, `<init>(BluetoothSocket)`, `connect()`, `connectRfcom()`, `read`, `write` (221,241,259,344,351,548,566,584,2580,3156,3445,3488,3555,4138) | `HCTApi.IsSupportBleBluetooth()` gate + sysprop `hct.bt.org` |
| `android/content/pm/PackageParser` | `<init>()` (468-474: `com.microntek.controlinfo/controlsettings/dvd/air`), `parseActivity(...)` (5999,6436,6449,6462), `parseBaseApplication(...)` (15627,15634) | `HCTApi.getHctwmPloy()I`, `HCTApi.isFulltAppLists(String)`, prefix whitelist `com.microntek.`/`com.hct.`/`android.microntek.` |

### framework.jar classes2.dex (`s10fw2`)

| class | method | hook |
|---|---|---|
| `android/media/AudioManager` | `playSoundEffect(I)V` (6904-6933), `playSoundEffect(II)V` (7014-7043) | `ServiceManager.getService("carservice")` → `ICarService$Stub.asInterface` → `setParameters("ctl_beep=1")` (MCU beep) |
| `android/os/StrictMode` | `initVmDefaults(ApplicationInfo)V` (1902) | skip StrictMode for `com.microntek.FileBrowser` |
| `android/os/storage/StorageManager` | `getBestVolumeDescription(VolumeInfo)String` (3434) | `HCTApi` call |
| `android/telephony/TelephonyManager` | `<init>()` (748,860), `<init>(Context,int)` (902), `getDeviceId()String` (6586-6597) | `new CarManager()` and MCU-provided IMEI/state lookups |
| `android/util/DisplayMetrics` | `static getDeviceDensity()I` (140,149) | sysprop `persist.hctbox.density` → local `hctbox`; uses removed `setToDefaultsDensity(IF)` (§4) |
| `android/net/NetworkFactory` | `evalRequest(NetworkRequestInfo)V` (126) | sysprop `hct.nat.state` |

### framework.jar classes3.dex (`s10fw3`)

| class | method | hook |
|---|---|---|
| `com/android/internal/policy/PhoneWindow` | `SendVolUP/SendVolDOWN/SendVolMute` (494,523,552), called from `onKeyDown(int,KeyEvent)` (7391,7398,7405) | `sendBroadcast(Intent("com.microntek.irkeyDown"), extra keyCode = IR_VOLUP 0x111 / IR_VOLDOWN 0x119 / IR_MUTE 0x102)` |
| `com/android/internal/telephony/RILConstants` | `<clinit>()V` (796,798) | sysprop `hct.dangle.type` default `"HCT"` |

### services.jar classes.dex (`a10fw/s10svc`)

| class | method | hook |
|---|---|---|
| `com/android/server/SystemServer` | `startOtherServices()V`, `startMtcManage(Context)V`, `lambda$startOtherServices$4` | service instantiation/registration (§2) |
| `com/android/server/policy/PhoneWindowManager` | `<clinit>()` (707 `ro.product.project=="BOX"` → `isCarBox`; 710-714 `pkAudioList` = `com.microntek.media/music/btmusic`), `<init>()` (900 `mCarManager`), field `mCarManager` (287), `checkHctAuioApp()Z` (1867), `sendHctKeyCode(I)V` (8503), `sendBoxKeyCode(I)V` (8457), `interceptKeyBeforeQueueing(KeyEvent,I)I` (15392-15546) | hardware-key forwarding to CarService (`KeyDown`/`BoxKeyDown`, IR remap 0x12b/0x12c), btplay/btmusic special-casing, `hct.media.focus` sysprop |
| `com/android/server/audio/AudioService` | `<init>(Context)V` (1248-1294) | `getService("carservice")` → `ICarService.getParameters("cfg_maxvolume=")` (MCU max volume), log `mtc ICarService  fial !!!` |
| `com/android/server/audio/MediaFocusControl` | `requestAudioFocus(AudioAttributes,I,IBinder,IAudioFocusDispatcher,String,String,IIZ)I` (2947-3022, 3197, 3202, 3329) | prefix test `com.microntek.`/`com.hct.` → `sendKey`; `CarManager.getStringState("navi_package")` → `hctploy`; sysprop `hct.media.focus`; `HCTApi.SystemKey(0x7f/0x56, flags)` injection |
| `com/android/server/am/ActivityManagerService` | `broadcastIntentLocked(...)` (39871,39880,39889), `checkBroadcastFromSystem(...)` (6836,6845,6854), `finishBooting()` (56544-56556 → `CarManager.attach(Handler,String)`), `getAppStartModeLocked(...)` (58440-58458), `forceStopPackage(String,I)` (57452 `HCTApi.isHCTMediaApp`), `killBackgroundProcesses(String,I)` (69407 `isHCTMediaApp`), `isUidActive(I,String)` (68316-68325), `sendHCTRemoveTask(String)V` (80935 broadcast `"com.microntek.removetask"`) | broadcast/permission exemptions for microntek/hct prefixes; MCU attach at boot; HCT-media app protection |
| `com/android/server/am/ActivityManagerService$12` | `handleMessage(Message)V` (236,311) | broadcasts `com.microntek.STATUS_BAR_CHANGED` / `com.microntek.ext.STATUS_BAR_CHANGED` |
| `com/android/server/am/ActiveServices` | `startServiceLocked(...)` (16289,16300,16311) | prefix exemption `com.microntek.`/`com.hct.`/`android.microntek.` |
| `com/android/server/am/OomAdjuster` | `applyOomAdjLocked(ProcessRecord,Z,J,J)Z` (468) | `HCTApi.getHCTAppWhiteProcessAdj(String)` (keep HCT apps at low adj) |
| `com/android/server/pm/PackageManagerService` | `reportDexoptState(I)V` (68122-68146) | `getService("carservice")` → `ICarService.setParameters(...)` |
| `com/android/server/pm/permission/BasePermission` | `enforceDeclaredUsedAndRuntimeOrDevelopment(Package)V` (1793,1804,1815) | prefix exemption |
| `com/android/server/pm/permission/PermissionManagerService` | `checkPermission(String,String,II)I` (1999,2008,2017), `checkUidPermission(String,Package,II)I` (2289,2300,2311) | prefix exemption |
| `com/android/server/pm/permission/DefaultPermissionGrantPolicy` | `grantDefaultSystemHandlerPermissions(I)V` (3626,3676,3731,3781,3846,3896,3946,3996,4046,4156,4206,4261,4311,4361,4466,4516) | grants to `com.microntek.FileBrowser/music/media/travel/avin/dvd/tv/ampsetup/tpms/instructions/frontview/dab/btmusic` and `com.hct.apkinstall`, `com.hct.screenbutton` |
| `com/android/server/usb/UsbUserSettingsManager` | `isCameraPermissionGranted(String,II)Z` (750), also `com.hct.` at 1742 | prefix exemption |
| `com/android/server/power/PowerManagerService` | `goToSleepNoUpdateLocked(J,I,I,I)Z` (6710-6745, 6992) | `new CarManager().getStringState(...)` (MCU sleep/acc state coordination) |
| `com/android/server/StorageManagerService` | `unmount(String)V` (13075) | special volId `"hctall"` → `resetExDevice()` |
| `com/android/server/UiModeManagerService` | `updateNightModeFromSettings(Context,Resources,I)Z` (1898) | `defaultHctNightMode` from `ro.product.brightnessmode` |
| `com/android/server/ConnectivityService` | `teardownUnneededNetwork(NetworkAgentInfo)V` (16360), `updateRoutes(LinkProperties,LinkProperties,I)Z` (18617) | sysprops `hct.nat.state`, `hct.dangle.type` |
| `com/android/server/connectivity/NetworkAgentInfo` | `getCurrentScore(Z)I` (300) | sysprop `hct.nat.state` |
| `com/android/server/usb/descriptors/UsbDescriptorParser` | `allocDescriptor(ByteStream)UsbDescriptor` (139) | sysprop `ro.product.customer.sub` default `"HCT"` |
| `com/android/server/am/ActivityManagerShellCommand` | `moveStackToDisplay/getStackInfo/getAllStackInfos/removeStack` (6533, 10065, 10091, 10318) | shell commands on HCT stack APIs (gone in A14, §4) |

### services.jar classes2.dex (`s10svc2`, WindowManager)

| class | method | hook |
|---|---|---|
| `com/android/server/wm/ActivityStack` | `public HctSendAppinfo(ActivityRecord,Z)V` (6949-7019) | `new CarManager().dispatchMessage(<appinfo type>, bundle)` |
| `com/android/server/wm/ActivityStack$ActivityStackHandler` | `handleMessage(Message)V` (498) | calls `HctSendAppinfo` |
| `com/android/server/wm/ActivityStackSupervisor` | `switchDualScreen()V` (11248-11450), `removeTaskByIdLocked(I,Z,Z,Z,String)Z` (7782-7826), `handleForcedResizableTaskIfNeeded(TaskRecord,I)V` (1484-1502) | dual-screen switching (packages `com.microntek.FileBrowser/bluetooth/btmusic/difference.display/travel`), HCT-media app handling, prefix exemptions |
| `com/android/server/wm/ActivityStackSupervisor$ActivityStackSupervisorHandler` | `handleMessage(Message)V` (117-157) | `CarManager.getIntState(...)` then `HCTApi.SystemKey(...)` injection |
| `com/android/server/wm/ActivityStarter` | `shouldAbortBackgroundActivityStart(...)` (12492,12500,12508) | prefix exemption (`com.microntek.`/`com.hct.`/`android.microntek.`) |
| `com/android/server/wm/ActivityRecord` | `shouldRelaunchLocked(I,Configuration)Z` (3811) | skip relaunch for `com.microntek.media` |
| `com/android/server/wm/DisplayContent` | `getOrientation()I` (9696) | `HCTApi.getHctwmPloy()I` |
| `com/android/server/wm/DisplayPolicy` | `navigationBarPosition(I,I,I)I` (12953-12961) | `CarManager` state → nav-bar position |
| `com/android/server/wm/PointerEventDispatcher` | field `mCarManager` (19), `<init>(InputChannel)` (91), `hctTouchAppStudy()V` (146-180, `CarManager.attach(Handler,String)`), `sendHctTouchStudy(MotionEvent)V` (299-394, `dispatchMessage`), inner `$1.handleMessage` (155 `"com.microntek"`) | touch-calibration ("TouchKeyStudy") forwarding to MCU |
| `com/android/server/wm/AppWarnings` | field `HctAppLists:[Ljava/lang/String;` (24,91), `isHctAppLists(String)Z` (397, used 1381) | suppress AOSP warnings for HCT apps |
| `com/android/server/wm/LaunchParamsController` | (370) `ActivityTaskManagerService.moveStackToDisplay` — HCT-added ATMS method |
| `com/android/server/wm/RootActivityContainer` / `ActivityTaskManagerService` | `getStackInfo(ActivityStack)`, `getAllStackInfos()`, `getStackInfo(I)`, `getStackInfo(II)`, `moveStackToDisplay(I,I,Z)`, `getAllStackInfos()/getStackInfo()` (ATMS 9234, 10140) | the HCT-added stack machinery that `HCTApi` calls; **absent in A14** |

False positives excluded from the hook list: `HctSolver` (camera), lambda names containing `HCt`, `MetricsProto`, `R$bool`, `UsbDescriptorParser`'s `HCT` is real (listed above), `ImsService` lambdas.

### sysprops / vendor props the hooks depend on

sysprops read or written by HCT code: `sys.hct.debug`, `hct.media.focus`, `hct.media.focus.may.duck`, `hct.hub.sta`, `hct.appwm.ploy`, `hctwmploy`, `hctploy`, `hct.disable.mask`, `hct.nat.state`, `hct.dangle.type`, `hct.bt.org`, `hctall`, `persist.hctbox.density`, `persist.carbox.density`, `persist.carbox.display`, `persist.car.box.install.app.dpi`, `ro.product.project` (`BOX`), `ro.product.customer(.sub)` (`HCT`), `ro.product.brightnessmode`, `ro.product.dspconfig`, `ro.product.dspmode`, `ro.product.dspversion`, `ro.product.keycustomeq9`, `ro.product.rotate`, `ro.product.board`.
CarService protocol strings (passed through `native_setParameters`/`native_getParameters`): `rpt_service_ready=true`, `rpt_boot_complete=true`, `sta_ill=`, `sta_orientation=`, `sta_driving=`, `sta_hub=`, `cfg_advchip=`, `cfg_maxvolume=` (AudioService), `ctl_beep=1` (AudioManager), `av_channel`, `cvbs_available`, `handbrake`, `headlight`, `orientation`.

---

## 6. Port checklist implied by the above

1. **framework.jar side (A14)**: re-add `android/microntek/*` (15 classes, 33 descriptors) into one of the A14 framework dexes; they compile clean against A14 except `HCTApi`'s stack API (`getAllStackInfos`, `getFocusedStackInfo`, `getStackInfo(II)`, `removeStack`, `setFocusedStack`, `switchDualScreen`, `hasSecondScreenActivityStack`, `moveStackToDisplay`) and `DisplayMetrics.setToDefaultsDensity(IF)` — rewrite onto `getAllRootTaskInfos` / `getFocusedRootTaskInfo` / `getRootTaskInfo(II)` / `removeTask` / `setFocusedRootTask` / `moveRootTaskToDisplay` and `setToDefaults()`; implement `switchDualScreen`/`hasSecondScreenActivityStack` as new A14 ATMS AIDL methods (A10 impl lived in `ActivityTaskManagerService`/`RootActivityContainer`, which A14 replaces with `TaskContinuation`/`ActivityRestarter` + root-task containers).
2. **services.jar side**: port `com/android/server/microntek` (CarService, MfiService, HctUtil, HCT_CMD, OnMfiServiceCallback) — it compiles clean against A14 (0 MISSING), but `SystemServer.startOtherServices` must be patched to `addService("carservice")`/`addService("mfiservice")`, plus `startMtcManage()` (needs the `android.microntek.service` APK).
3. **native**: rebuild the two JNI tables (2 + 7 entries) into A14's `libandroid_servers.so` (`JNI_OnLoad` tail), keep `/dev/mtc-car` ioctl semantics and the vendor HAL `android.hardware.mtc.mfi@1.0` (A14 needs the HAL re-implemented as an AIDL Stable HAL or replaced by a direct char-device callback thread — HIDL 1.0 vendor HALs are dropped in A14).
4. **hooks**: re-apply the ~40 hook sites listed in §5 into A14 equivalents (A14 has no `ActivityStack`/`ActivityStackSupervisor`/`StackInfo`, they are `Task`/`RootTask`/`ActivityTaskManagerService`; `PointerEventDispatcher` still exists in `com.android.server.wm`; `PhoneWindowManager.interceptKeyBeforeQueueing` still exists; `PhoneWindow.onKeyDown` still exists; `MediaFocusControl.requestAudioFocus` still exists in `com.android.server.audio`).
5. **key-event path**: nothing to port for the MCU→Android key ingress except the `PhoneWindowManager` forwarding (input events arrive through the stock input pipeline; the `--mtc key 0111` kernel log comes from the MCU key driver, which must exist in the A14 kernel and register a normal input device with the same keycodes 0x55/0x57/0x58/0x79/0x7e used by `interceptKeyBeforeQueueing`) — plus `HCTApi.SystemKey` injection (works unchanged: `InputManager.getInstance()` + `injectInputEvent` are present in A14).
