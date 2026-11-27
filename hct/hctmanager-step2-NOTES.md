# step2 — HCTManagerService.apk ported to Android 14 (carservice registration + /dev/ttyV2 via FileInputStream)

Built 2026-11-24 in `/run/media/Daan/Opslagmonster/a14-work/hctport/step2/`. Everything below was written under
`step2/` only; nothing under `/run/media` was touched, `debugfs` ran read-only (`-R dump`), and no adb
was used. Read-only inputs: `super9/system-new14.img` (APK dump), `a10fw/s10svc/com/android/server/microntek`
(A10 service smali, copied), `/run/media/Daan/Opslagmonster/a14-work/scratch/fw/**` (A14 boot jars + framework/services),
`hctport/out/classes.dex` (the `android.microntek` classes shipped in `hct-framework.jar`).

Deliverable: **`step2/HCTManagerService.apk`** — 309483 bytes, 28 entries, only `classes.dex` replaced,
compression method of that entry still **Stored (0)**, all other entries byte-identical, **not re-signed**.

---

## 1. Exact commands

```sh
mkdir -p /run/media/Daan/Opslagmonster/a14-work/hctport/step2

# dump the renamed APK out of the A14 system image (debugfs -R is read-only)
debugfs -R "dump /system/priv-app/HCTManagerService/HCTManagerService.apk.disabled-attempt26 \
  /run/media/Daan/Opslagmonster/a14-work/hctport/step2/original.apk" \
  /run/media/Daan/Opslagmonster/a14-work/super9/system-new14.img
sha256sum original.apk            # 4df7d7f6b43ff2c5a4f91a859b24e90c9bc41bc2abf6e3b6ca7ae3cf816eec4c

# 1. baksmali the APK's classes.dex
unzip -o -q original.apk classes.dex
java -jar /run/media/Daan/Opslagmonster/a14-work/tools/smali/baksmali-2.5.2.jar d classes.dex -o mgr_smali   # 88 classes

# copy the A10 service classes in, EXCLUDING the Mfi ones (see §2)
mkdir -p mgr_smali/com/android/server/microntek
for f in /run/media/Daan/Opslagmonster/a14-work/a10fw/s10svc/com/android/server/microntek/*.smali; do
  b=$(basename "$f")
  case "$b" in MfiService*.smali|OnMfiServiceCallback.smali) ;; *) cp "$f" mgr_smali/com/android/server/microntek/ ;; esac
done
find mgr_smali -name '*.smali' | wc -l          # -> 104 (88 APK + 16 service)

# strip baksmali's hiddenapi access-flag tokens (same script as step 1)
python3 /run/media/Daan/Opslagmonster/a14-work/hctport/scripts/strip_hiddenapi.py \
  /run/media/Daan/Opslagmonster/a14-work/hctport/step2/mgr_smali
#   -> mgr_smali: 0 files rewritten, 0 hiddenapi tokens removed   (see §3)

# 2/3. smali edits: CarService.smali, CarService$3.smali, ManageService.smali  (diffs in §4)

# 4. assemble + verify
java -jar /run/media/Daan/Opslagmonster/a14-work/tools/smali/smali-2.5.2.jar a --api 34 mgr_smali -o classes.dex
python3 /run/media/Daan/Opslagmonster/VibeBakingFirmware/tools/dex_api_check.py \
  --framework /run/media/Daan/Opslagmonster/a14-work/scratch/fw/framework/*.dex /run/media/Daan/Opslagmonster/a14-work/scratch/fw/x/*/classes.dex \
  /run/media/Daan/Opslagmonster/a14-work/hctport/out/classes.dex --app classes.dex      # output in api_check.txt
python3 /run/media/Daan/Opslagmonster/a14-work/hctport/scripts/dex_field_check.py \
  --framework /run/media/Daan/Opslagmonster/a14-work/scratch/fw/framework/*.dex /run/media/Daan/Opslagmonster/a14-work/scratch/fw/x/*/classes.dex \
  /run/media/Daan/Opslagmonster/a14-work/hctport/out/classes.dex --app-dir mgr_smali    # output in field_check.txt
python3 /run/media/Daan/Opslagmonster/a14-work/hctport/scripts/dex_ref_summary.py classes.dex   # ref_summary.txt

# instruction-level proof: round-trip the assembled dex
rm -rf rt && java -jar /run/media/Daan/Opslagmonster/a14-work/tools/smali/baksmali-2.5.2.jar d classes.dex -o rt
find rt -name '*.smali' | wc -l                                                # -> 104
grep -rnE '^\s*\.(class|field|method).*\b(blacklist|greylist|whitelist|unsupported|core-platform-api)\b' rt | wc -l  # -> 0
grep -rn 'android/hardware/SerialPort\|SerialManager' rt                        # -> no output (exit 1)
grep -rn 'clearLock' rt | grep -v '#'                                           # -> no output (exit 1)

# 5. rebuild the APK: only classes.dex replaced, byte-faithfully, no re-signing
python3 scripts/rezip.py original.apk HCTManagerService.apk classes.dex classes.dex
unzip -v HCTManagerService.apk    # listing in §6
unzip -t  HCTManagerService.apk   # "No errors detected in compressed data"
sha256sum classes.dex HCTManagerService.apk
```

Scratch/reference copies kept in `step2/`: `original.apk`, `orig_classes.dex` (inside `orig_smali/`),
`orig_smali/mgr` (baksmali of the **original** dex, used as the diff baseline),
`orig_smali/svc/com/android/server/microntek` (pristine copies of the 16 copied service files),
`base_classes.dex` (baseline assembly **before** the edits, used to get the pre-existing MISSING list),
`rt/` (round-trip of the shipped dex), `diffs.txt`, `api_check.txt`, `field_check.txt`, `ref_summary.txt`,
`unzip_v.txt`, `smali_log.txt`, `scripts/rezip.py`, `scripts/symbol_check.py`.

## 2. Which service files were copied, and why MfiService was dropped

`a10fw/s10svc/com/android/server/microntek/` holds 22 files; **16 were copied**, 6 excluded:
`MfiService.smali`, `MfiService$1.smali`, `MfiService$PlayThread.smali`, `MfiService$PositionListener.smali`,
`MfiService$UsbReceiver.smali`, `OnMfiServiceCallback.smali`.

Decision evidence:
* `grep -rn 'MfiService\|OnMfiServiceCallback' a10fw/s10svc/com/android/server/microntek/` matches **only
  inside those 6 files** — `CarService` and the other copied classes never reference them.
* Nothing in the APK dex references `com/android/server/microntek` at all (`grep -rn 'com/android/server/microntek'
  mgr_smali` on the freshly baksmali'd APK → 0 hits); the APK's `Mfi` hits are all to the *framework* side
  (`android/microntek/mfi/MfiManager`, `MfiListener`, `IMfiService`), which lives in `hct-framework.jar`.
* Consequence of dropping them: `android.microntek.mfi.MfiManager` looks up the service **"mfiservice"**, gets
  `null`, and every call on `mMfiService` (`isConnected`, `registerListener`, `send`, …) is inside
  `try/catch Ljava/lang/Exception;`, so an NPE there is caught and logged — no crash, MFI functionality simply
  absent. Re-adding the Mfi classes later costs nothing except `libhctcar.so`'s Mfi symbols at call time.

Kept classes: `CarService` (+`$1,$2,$3,$4,$BootCompletedReceiver,$BootCompletedReceiver$1`), `HCT_CMD`
(+7 inner classes), `HctUtil` = 16 files.

## 3. Hiddenapi tokens

`strip_hiddenapi.py` removed **0** tokens here: the copied `s10svc` files were already stripped in step 1's
source tree, and the APK's own dex carries no hiddenapi data (its only `blacklist/greylist/whitelist` matches are
`const-string` settings keys — `hal_applications_whitelist`, `hal_screensaver_blacklist`, …). Proof on the
assembled dex: the round-trip `rt/` emits **0** hiddenapi modifier tokens over all 104 classes.

## 4. The three smali changes (full diffs, from `step2/diffs.txt`)

### 4.1 `android/microntek/service/ManageService.smali` — carservice registration + clearLock removal

```diff
@@ -647,6 +647,51 @@
     .line 212
     invoke-super {p0}, Landroid/app/Service;->onCreate()V
 
+    # --- HCT port (Android 14): the stock serial service exposes no ports, so CarService opens
+    #     /dev/ttyV2 itself. Register it here; the JNI lib is loaded first so
+    #     native_getParameters/native_setParameters are attached before CarService's constructor runs.
+    :try_start_cs
+    const-string v0, "carservice"
+
+    invoke-static {v0}, Landroid/os/ServiceManager;->getService(Ljava/lang/String;)Landroid/os/IBinder;
+
+    move-result-object v0
+
+    if-eqz v0, :goto_cs
+
+    const-string/jumbo v0, "/system/lib64/libhctcar.so"
+
+    invoke-static {v0}, Ljava/lang/System;->load(Ljava/lang/String;)V
+
+    new-instance v0, Lcom/android/server/microntek/CarService;
+
+    invoke-direct {v0, p0}, Lcom/android/server/microntek/CarService;-><init>(Landroid/content/Context;)V
+
+    const-string/jumbo v1, "carservice"
+
+    invoke-static {v1, v0}, Landroid/os/ServiceManager;->addService(Ljava/lang/String;Landroid/os/IBinder;)V
+
+    const-string/jumbo v0, "HCTPort"
+
+    const-string/jumbo v1, "carservice registered"
+
+    invoke-static {v0, v1}, Landroid/util/Log;->i(Ljava/lang/String;Ljava/lang/String;)I
+    :try_end_cs
+    .catch Ljava/lang/Throwable; {:try_start_cs .. :try_end_cs} :catch_cs
+
+    goto :goto_cs
+
+    :catch_cs
+    move-exception v0
+
+    const-string/jumbo v1, "HCTPort"
+
+    const-string/jumbo v2, "carservice failed"
+
+    invoke-static {v1, v2, v0}, Landroid/util/Log;->e(Ljava/lang/String;Ljava/lang/String;Ljava/lang/Throwable;)I
+
+    :goto_cs
+
     .line 214
     invoke-direct {p0}, Landroid/microntek/service/ManageService;->StartCarService()V
@@ -687,10 +732,8 @@
     new-instance v1, Lcom/android/internal/widget/LockPatternUtils;
 
     invoke-direct {v1, p0}, Lcom/android/internal/widget/LockPatternUtils;-><init>(Landroid/content/Context;)V
-
-    const/4 v2, 0x0
-
-    invoke-virtual {v1, v2, v0}, Lcom/android/internal/widget/LockPatternUtils;->clearLock([BI)Z
+    # removed: LockPatternUtils.clearLock([BI)Z is gone on Android 14 (NoSuchMethodError, not caught
+    # by the catch(Exception) below). Nothing else in this try block, so the block is inert.
     :try_end_2d
     .catch Ljava/lang/Exception; {:try_start_24 .. :try_end_2d} :catch_2e
```

Notes on this method:
* `.registers 6` is **unchanged**: for a no-param instance method that means locals `v0..v4` and `p0` in
  register 5. The inserted block uses only `v0`,`v1`,`v2`; `p0` is never written (`move-exception v0` targets
  `v0`, not `p0`), so nothing is clobbered.
* `catch Ljava/lang/Throwable;` (not `Exception`) so `UnsatisfiedLinkError` from `System.load` and
  `NoSuchMethodError` from the JNI registration are caught; the failure path logs
  `Log.e("HCTPort", "carservice failed", t)`.
* `System.load` is called from `ManageService.onCreate`, i.e. from a class in the APK dex — which is exactly
  what `libhctcar.so`'s `JNI_OnLoad` needs, since its `FindClass("com/android/server/microntek/CarService")`
  uses the classloader of the caller of `System.load` (the APK's loader, which contains that class).
* Load order is deliberate: `load()` **before** `new CarService(...)`, because `CarService.<init>` already calls
  `native_getParameters("sta_hub")`/`native_getParameters(...)` (round-trip lines 277, 312, 345, 378, 434) and
  then `initDsp()` / `initComm()`.
* `if-eqz v0, :goto_cs` skips registration when `getService("carservice")` already returned a binder (idempotent
  across `onCreate` re-entry). The jump target is outside the try range, so it never runs the catch handler.
* `LockPatternUtils.<init>(Landroid/content/Context;)V` **does** exist on A14, so keeping `new-instance` +
  `<init>` per "keep everything else" adds no missing reference; only the removed `clearLock([BI)Z` did.
* `android/microntek/service/ManageService.smali` is the **only** APK-side file that differs from the original
  APK's baksmali (`diff -rq -x 'com' orig_smali/mgr mgr_smali` → just this file).

### 4.2 `com/android/server/microntek/CarService.smali` — field, accessor, `initComm()`

```diff
@@ -158,9 +158,7 @@
 .field private mLock:Ljava/lang/Object;
 
-.field private mSerialManager:Landroid/hardware/SerialManager;
-
-.field private mSerialPort:Landroid/hardware/SerialPort;
+.field private mSerialPort:Ljava/io/FileInputStream;
 
@@ -1011,12 +1009,12 @@
-.method static synthetic access$700(Lcom/android/server/microntek/CarService;)Landroid/hardware/SerialPort;
+.method static synthetic access$700(Lcom/android/server/microntek/CarService;)Ljava/io/FileInputStream;
     .registers 2
     .param p0, "x0"    # Lcom/android/server/microntek/CarService;
     .line 61
-    iget-object v0, p0, ...->mSerialPort:Landroid/hardware/SerialPort;
+    iget-object v0, p0, ...->mSerialPort:Ljava/io/FileInputStream;
     return-object v0
 
@@ -4381,18 +4379,6 @@      (initComm, .registers 5 unchanged)
     .line 991
     const-string v0, "CarService"
 
-    iget-object v1, p0, ...->mContext:Landroid/content/Context;
-    const-string/jumbo v2, "serial"
-    invoke-virtual {v1, v2}, Landroid/content/Context;->getSystemService(Ljava/lang/String;)Ljava/lang/Object;
-    move-result-object v1
-    check-cast v1, Landroid/hardware/SerialManager;
-    iput-object v1, p0, ...->mSerialManager:Landroid/hardware/SerialManager;
-
     .line 992
     const/16 v1, 0x1000
     invoke-static {v1}, Ljava/nio/ByteBuffer;->allocate(I)Ljava/nio/ByteBuffer;
     move-result-object v1
     iput-object v1, p0, ...->mInputBuffer:Ljava/nio/ByteBuffer;
 
     .line 996
     :try_start_17
-    iget-object v1, p0, ...->mSerialManager:Landroid/hardware/SerialManager;
+    new-instance v1, Ljava/io/FileInputStream;
     const-string v2, "/dev/ttyV2"
-
-    const v3, 0x9600
-
-    invoke-virtual {v1, v2, v3}, Landroid/hardware/SerialManager;->openSerialPort(Ljava/lang/String;I)Landroid/hardware/SerialPort;
-
-    move-result-object v1
+    invoke-direct {v1, v2}, Ljava/io/FileInputStream;-><init>(Ljava/lang/String;)V
+
+    iput-object v1, p0, ...->mSerialPort:Ljava/io/FileInputStream;
 
     .line 997
-    iget-object v1, p0, ...->mSerialPort:Landroid/hardware/SerialPort;
+    iget-object v1, p0, ...->mSerialPort:Ljava/io/FileInputStream;
     if-eqz v1, :cond_36
```

Everything after that (`new-instance Thread` + `CarService$3` + `Thread.start()`, the `:cond_36` failure path
`Log.i("CarService", "mtc >>> open /dev/ttyV2 fail!")`, `:catch_3d` path
`Log.i("CarService", "mtc >>> open /dev/ttyV2 Exception !")`, the `.catch Ljava/io/IOException;` range, labels
`:cond_36/:goto_3c/:catch_3d/:goto_44`) is untouched — both original log strings are kept.
`FileInputStream(String)` throws `FileNotFoundException`, a subclass of `IOException`, so the existing catch still
covers the failure; the `if-eqz` "fail!" branch stays (it can now only fire if the field were nulled).

### 4.3 `com/android/server/microntek/CarService$3.smali` — reader thread

```diff
@@ -42,6 +42,11 @@
     .line 1000
     const/4 v0, 0x0
 
+    .line 1001
+    const/16 v1, 0x1000
+
+    new-array v2, v1, [B      # 4096-byte read buffer, allocated once outside the loop
+
     .line 1002
     .local v0, "ret":I
     :goto_1
     if-ltz v0, :cond_3a
@@ -51,29 +56,13 @@
     :try_start_3
     iget-object v1, p0, CarService$3;->this$0:CarService;
 
-    # getter for: ...->mInputBuffer:Ljava/nio/ByteBuffer;
-    invoke-static {v1}, CarService;->access$600(...)Ljava/nio/ByteBuffer;
-    move-result-object v1
-    invoke-virtual {v1}, Ljava/nio/ByteBuffer;->clear()Ljava/nio/Buffer;
-
     .line 1005
-    iget-object v1, p0, ...->this$0
-    # getter for: ...->mSerialPort:Landroid/hardware/SerialPort;
-    invoke-static {v1}, CarService;->access$700(...)Landroid/hardware/SerialPort;
-    move-result-object v1
-    iget-object v2, p0, ...->this$0
-    invoke-static {v2}, CarService;->access$600(...)Ljava/nio/ByteBuffer;
-    move-result-object v2
-    invoke-virtual {v1, v2}, Landroid/hardware/SerialPort;->read(Ljava/nio/ByteBuffer;)I
+    # getter for: ...->mSerialPort:Ljava/io/FileInputStream;
+    invoke-static {v1}, CarService;->access$700(...)Ljava/io/FileInputStream;
+    move-result-object v1
+    invoke-virtual {v1, v2}, Ljava/io/InputStream;->read([B)I
     move-result v1
     move v0, v1
     .line 1006
     if-lez v0, :cond_30
-    new-array v1, v0, [B
-    .local v1, "buffer":[B
-    invoke-static {v2}, CarService;->access$600(...)Ljava/nio/ByteBuffer;
-    move-result-object v2
-    const/4 v3, 0x0
-    invoke-virtual {v2, v1, v3, v0}, Ljava/nio/ByteBuffer;->get([BII)Ljava/nio/ByteBuffer;
     .line 1010
-    iget-object v2, p0, ...->this$0
-    invoke-static {v2, v1, v0}, CarService;->access$800(CarService;[BI)V
+    iget-object v1, p0, ...->this$0
+    invoke-static {v1, v2, v0}, CarService;->access$800(CarService;[BI)V   # same DataProc call as before
     :try_end_30
     .catch Ljava/io/IOException; {:try_start_3 .. :try_end_30} :catch_31
 
     .line 1015
-    .end local v1    # "buffer":[B
     :cond_30
     goto :goto_1
```

`read` is invoked as `Ljava/io/InputStream;->read([B)I` (declared on `InputStream`, inherited by
`FileInputStream`) — that is what ART resolves at runtime. `.registers 5` is unchanged (locals `v0..v3`, `p0` in
register 4); the catch path still uses `v2`/`v3` for the kept log strings
`Log.i("CarService", "mtc >>> read /dev/ttyV2 Exception !")`.
`DataProc([BI)` (via `access$800`) is byte-identical to before and is safe with a fixed 4096 buffer: it copies
`min(size, 0x1000)` bytes into the static `serialRevBuf:[B` (also `0x1000`) and never consults the array length.

### Serial-port usage audit (do we need a FileOutputStream?)

All `mSerialPort` / `SerialPort` uses in the copied service classes were `initComm` (open), `access$700`
(getter) and `access$700` inside `CarService$3.run` (the single `SerialPort.read(ByteBuffer)`), plus the
`mSerialManager` field/getter. **There is no write, no close, no flush, no `getDataOutputStream()` anywhere** —
`grep -rn 'OutputStream\|->write(\|->close('` over the service dir only hits the unrelated debug dump at
`CarService.smali:8295` (`FileOutputStream` + `PrintWriter` on some file, not the tty). So only a
`FileInputStream` is needed; the `mSerialPort` field type was changed rather than adding a second field, which
keeps `access$700` and the reader thread consistent.

## 5. Verification

**Assembled dex:** `dex\n039\0`, `header_size` 112, `file_size` 223436 (matches), **104 classes** (88 APK + 16
service), strings/types/fields/methods 3445/313/1328/1274, annotations dir 179996@43440 with nothing appended
after it (so no hiddenapi data block), ART sha1 signature at 0x0c = `e7a37b3aa173ccc5ec3892f9e846b5394017432c`.
For comparison the original APK dex was 182468 bytes, 039, 88 classes, 2963/281/999/1109.

`dex_api_check.py` (framework = A14 boot jars + framework dexes + `hctport/out/classes.dex`, 36918 classes):

```
framework classes: 36918; app invoke refs: 1016
MISSING:
  Landroid/hardware/display/DisplayManager;->setTemporaryBrightness(I)V
  Landroid/os/INetworkManagementService;->setDataUidRule(IZ)V
not resolvable here: 49   (java.*, android.net.wifi.*, ConnectivityManager, PackageHelper,
                            PackageManager$NameNotFoundException — core-library/wifi classes outside the extracted jars)
```

`LockPatternUtils->clearLock([BI)Z` is **gone** from MISSING (before the edit the baseline `base_classes.dex`
reported 3 entries: those two plus clearLock). The two remaining entries are **pre-existing APK code that this
step did not touch**, both in `android/microntek/service/MicrontekServiceBase.smali`:

| ref | call site | what A14 has instead | risk |
|---|---|---|---|
| `DisplayManager.setTemporaryBrightness(I)V` | `setBrightness(I)V` (`MicrontekServiceBase.smali:7769`), reached from `IRsetBrightness()` and the brightness/settings paths (lines 1130, 2943, 6036) — **not** inside any try/catch | A14 declares `setTemporaryBrightness(IF)V` (displayId, float) and `setBrightness(IF)V`; the 1-arg int overload is gone | `NoSuchMethodError` propagates → kills whatever thread runs the brightness update |
| `INetworkManagementService.setDataUidRule(IZ)V` | `setAppRule(Ljava/util/List;Z)V` (`:1822`, `:1888`), reached from `init()` at `:5874`/`:5991`; both calls are inside `try/catch Ljava/lang/Exception;` | A14's `INetworkManagementService` has no `setDataUidRule` at all (nearest equivalents: `setFirewallUidRule(I I Ljava/lang/String;)V`, `setUidOnMeteredNetworkAllowlist/Denylist`) | `NoSuchMethodError` is an `Error`, so the `catch(Exception)` does **not** catch it — same failure shape as the `clearLock` crash that motivated step 2 |

Both were left as-is because the instructions scope step 2 to the serial port + `onCreate`; they are the obvious
follow-up (redirect `setBrightness` to `setTemporaryBrightness(0, brightness/255f)`, and rewrite `setAppRule` onto
`setFirewallUidRule`, or stub both). `dex_field_check.py` (the field-level twin) reports **MISSING FIELDS empty**,
412 app field refs resolved, only `SupplicantState`, `File`, `Integer`, `System` not resolvable (outside the
extracted jars). `dex_ref_summary.py` confirms the new refs: `Ljava/io/FileInputStream;-><init>(Ljava/lang/String;)V`,
`Ljava/io/InputStream;->read([B)I`, `Ljava/lang/System;->load(Ljava/lang/String;)V`,
`Landroid/os/ServiceManager;->getService/addService`, and `access$700(...)Ljava/io/FileInputStream`;
`android/hardware/SerialPort` and `android/hardware/SerialManager` appear nowhere in the dex (also 0 hits in `rt/`).

Round-trip (`rt/`): 104 smali files, 0 hiddenapi tokens, no `SerialPort`/`SerialManager`/`openSerialPort`/`clearLock`
instruction anywhere; `ManageService.onCreate` shows the `getService` → `System.load` → `addService` →
`Log.i("HCTPort", "carservice registered")` sequence with the `Throwable` catch → `Log.e("HCTPort", "carservice failed", t)`.

## 6. APK rebuild and `unzip -v`

The original APK's `classes.dex` entry is **STORED** (`unzip -v`: `Stored`, 182468 = 182468 bytes), so the
replacement stays STORED. `scripts/rezip.py` patches only: the new dex bytes, its CRC-32/compressed/
uncompressed sizes in the local header and in the central-directory header, the central-directory *local-header
offset* fields of the entries after `classes.dex`, and the EOCD's CD offset. Everything else — local headers,
extra fields (`0xcafe` + `0xd935` zipalign padding), timestamps, flags, raw bytes of the 10 deflated entries,
their 16-byte data descriptors, the CD entries, and the pre-CD **APK Signing Block v2/v3** region (5787 bytes =
1691 zipalign padding + 4096 block, magic `APK Sig Block 42`) — is copied verbatim. No re-signing, no zipalign
run, no re-deflate.

```
original.apk: 268515 bytes, 28 entries -> HCTManagerService.apk: 309483 bytes
replaced classes.dex: 182468 -> 223436 bytes (delta 40968), method STORED(0), crc32 0xeca0b4fd -> 0x9e2b2edb
cd_size 2253 (unchanged), cd_offset 266240 -> 307208, EOCD 22 bytes
pre-CD region kept verbatim: 5787 bytes = 1691 padding + 4096 signing block (magic b'APK Sig Block 42')
STORED entries after classes.dex shift by 40968 bytes (0 mod 4); misaligned before: none; misaligned after: none
verified: 27 untouched entries byte-identical (local header, data, data descriptor, central header);
          only the local-header offset field moved, and classes.dex's content/CRC/sizes
```

The delta is a multiple of 4, so every STORED entry (incl. `resources.arsc`) stays 4-byte aligned as before.
`unzip -t HCTManagerService.apk` → *No errors detected in compressed data*. (`unzip -t` needs
`UNZIP_DISABLE_ZIPBOMB_DETECTION=TRUE` only if the CD local-header offsets are inconsistent — they are patched,
so plain `unzip -t` passes.)

`unzip -v HCTManagerService.apk`:

```
 Length   Method    Size  Cmpr    Date    Time   CRC-32   Name
--------  ------  ------- ---- ---------- ----- --------  ----
  223436  Stored   223436   0% 2009-01-01 00:00 9e2b2edb  classes.dex
    4429  Stored     4429   0% 2009-01-01 00:00 7ee71c83  res/drawable-nodpi-v4/heatover.png
     967  Stored      967   0% 2009-01-01 00:00 714beb79  res/drawable-nodpi-v4/heatover_bg.9.png
    5964  Stored     5964   0% 2009-01-01 00:00 f248df62  res/drawable-nodpi-v4/ic_launcher.png
     151  Stored      151   0% 2009-01-01 00:00 c367d50e  res/drawable-nodpi-v4/icon_down_vol_nor.png
     151  Stored      151   0% 2009-01-01 00:00 716b2c4e  res/drawable-nodpi-v4/icon_down_vol_pre.png
     173  Stored      173   0% 2009-01-01 00:00 c079a7be  res/drawable-nodpi-v4/icon_up_vol_nor.png
     173  Stored      173   0% 2009-01-01 00:00 a23447a3  res/drawable-nodpi-v4/icon_up_vol_pre.png
     155  Stored      155   0% 2009-01-01 00:00 31bee611  res/drawable-nodpi-v4/seekbar_bg.png
     187  Stored      187   0% 2009-01-01 00:00 68e27b7c  res/drawable-nodpi-v4/seekbar_fg.png
      97  Stored       97   0% 2009-01-01 00:00 20c37837  res/drawable-nodpi-v4/seekbar_handle_none.png
   22723  Stored   22723   0% 2009-01-01 00:00 5e79a2a9  res/drawable-nodpi-v4/yh_defaultlogo.png
   30568  Stored   30568   0% 2009-01-01 00:00 8df12229  resources.arsc
    9464  Defl:N    2181  77% 2009-01-01 00:00 a6a958a2  AndroidManifest.xml
     608  Defl:N     253  58% 2009-01-01 00:00 87cdf108  res/drawable-nodpi-v4/seekbar_progress.xml
     560  Defl:N     250  55% 2009-01-01 00:00 88955403  res/drawable/btn_down_vol.xml
     560  Defl:N     249  56% 2009-01-01 00:00 ea43e786  res/drawable/btn_up_vol.xml
     732  Defl:N     327  55% 2009-01-01 00:00 fd27cdb6  res/layout-mcc1/volume_dialog.xml
    1420  Defl:N     603  58% 2009-01-01 00:00 a0ca8045  res/layout-mcc1/volume_slider.xml
     760  Defl:N     388  49% 2009-01-01 00:00 c97f47f1  res/layout/asuka_volume_dialog.xml
    1748  Defl:N     639  63% 2009-01-01 00:00 0c1d5329  res/layout/asuka_volume_slider.xml
    1152  Defl:N     501  57% 2009-01-01 00:00 6a135a31  res/layout/heatover.xml
     756  Defl:N     383  49% 2009-01-01 00:00 fe81d082  res/layout/volume_dialog.xml
    1256  Defl:N     533  58% 2009-01-01 00:00 eaee1d30  res/layout/volume_slider.xml
     484  Defl:N     248  49% 2009-01-01 00:00 74f6a583  res/layout/yh_logo.xml
    2772  Defl:N    1273  54% 2009-01-01 00:00 93d03883  META-INF/CERT.SF
    1722  Defl:N    1163  33% 2009-01-01 00:00 4941e874  META-INF/CERT.RSA
    2673  Defl:N    1211  55% 2009-01-01 00:00 a3e8ff74  META-INF/MANIFEST.MF
--------          -------  ---                            -------
  315841          299376   5%                            28 files
```

## 7. sha256

```
c35ae1023f3a917051591aa746f5300cfe098c53bdc6e2619cdd685e025c158e  step2/classes.dex
5483b777ac641eb32d1b149e41281fd7d0f8689f24d22823ff101fae723e152b  step2/HCTManagerService.apk
4df7d7f6b43ff2c5a4f91a859b24e90c9bc41bc2abf6e3b6ca7ae3cf816eec4c  step2/original.apk (from the image)
```

`unzip -p HCTManagerService.apk classes.dex | sha256sum` reproduces the first line (entry is STORED).

Reproducibility caveat (same as step 1): smali 2.5.2 assembles concurrently, so re-running the assemble over the
same `mgr_smali` gives the same size/counts (039, 104 classes, 1274 method refs) but a different item order and
hence a different sha1/sha256. The hashes above pin the exact bytes shipped in this APK. `classes.dex` in this
directory is the one that was zipped in — do not re-assemble without re-zipping.

## 8. Runtime behaviour and residual risks

* **`/dev/ttyV2`**: `crwxrwxrwx system:system` — uid `system` (which is what ManageService/HCTManagerService runs
  as) can open it. Reading via `FileInputStream` is a blocking `read(byte[])`; the thread exits only when
  `read` returns `< 0`. **The baud/bit config (`0x9600` = 38400) is gone**: a file stream cannot set termios, so
  the line must already be configured by the kernel/init (or by `libhctcar.so`). If 38400 matters and is not the
  default, add an `init`/`sysinit` step doing `stty -f /dev/ttyV2 38400 raw`, or set it in the native lib.
* **Hidden-API policy**: `ServiceManager.getService/addService` are framework-internal APIs. `ManageService` is
  loaded by an *app* class loader, so ART's hidden-API check may reject those two calls even though the process is
  `system_server`; the inserted code catches `Throwable`, so the worst case is
  `Log.e("HCTPort", "carservice failed", …)` and no `carservice`. Check `logcat -s HCTPort` (and
  `service_manager` avc denials) after boot. If it is rejected, the fix is to register the service from the
  framework side (a hook in `SystemServer`, as report.md §5 proposes) rather than from the APK.
* **SELinux**: adding a service named `carservice` needs a matching entry in `service_contexts`
  (e.g. `carservice  u:object_r:system_server_service:s0`); otherwise `service_manager:add` is denied. `android.microntek`'s
  `CarManager` looks up exactly `"carservice"` (framework jar, line 44), so the name is right.
* **APK signature is now invalid**: `META-INF/MANIFEST.MF` still lists the old SHA-256 digest of `classes.dex`, and
  the v2/v3 signing block (kept verbatim) hashes the old entry contents. Any signature verification on this APK
  will fail; the parent flow presumably installs it disabled/unverified (the image has it as
  `.apk.disabled-attempt26`). Re-signing with the device test key would fix that.
* `CarService` still extends `android/microntek/ICarService$Stub` (from `hct-framework.jar`, on the boot
  classpath) and needs `libhctcar.so` present before `System.load`, otherwise the constructor's first
  `native_getParameters` throws `UnsatisfiedLinkError` — caught by the new `Throwable` handler, which logs
  `carservice failed` and leaves the rest of `onCreate` (StartCarService/StartBTService/RadioService/
  StartCanBusService, ASR retry, `show_touches`, StartAdbOn) to run as before.
* `CarService$BootCompletedReceiver` / `CarService$4` and the rest of `CarService` are unchanged; `mInputBuffer`
  is still allocated in `initComm` and `access$600` is now unused (no caller) — harmless.
* The two MISSING entries in §5 (`setTemporaryBrightness`, `setDataUidRule`) are untouched pre-existing APK code;
  they crash their call paths on A14 the same way `clearLock` did. Fix in a follow-up step, ideally inside
  `MicrontekServiceBase.smali`.
