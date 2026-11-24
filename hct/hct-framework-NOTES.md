# hct-framework.jar — A10 `android/microntek` classes rebuilt to load/verify on Android 14

Built 2026-11-24 in `/home/Daan/vbf-work/a14-work/hctport/`. Read-only inputs: `hctport/s10fw2/`
(baksmali of A10 `fw10/classes2.dex`) and `/tmp/opencode/fw/**` (A14 LineageOS 21 boot jars).
Nothing was written under `/run/media`, no adb was used, and `s10fw2/` was never modified.

Deliverable: `hctport/out/hct-framework.jar` — one entry, `classes.dex`, STORED (`zip -X -0`),
59888 bytes, 33 classes, dex version **039**.

---

## 1. Exact commands (all run from `/home/Daan/vbf-work/a14-work`)

```sh
# 1. copy the 33 microntek smali files out of s10fw2 (s10fw2 itself untouched)
rm -rf hctport/fwsrc && mkdir -p hctport/fwsrc/android
cp -a hctport/s10fw2/android/microntek hctport/fwsrc/android/
find hctport/fwsrc -name '*.smali' | wc -l          # -> 33

# 2. drop baksmali's hiddenapi access-flag tokens (blacklist/greylist/... on .class/.field/.method)
python3 hctport/scripts/strip_hiddenapi.py hctport/fwsrc
#   -> fwsrc: 32 files rewritten, 594 hiddenapi tokens removed   (574 blacklist, 20 whitelist)

# 3. stub the bodies of the methods that call APIs missing on A14
python3 hctport/scripts/stub_methods.py hctport/fwsrc/android/microntek/HCTApi.smali
#   -> 15 method bodies stubbed (list in §3)

# 4. assemble + jar
java -jar /home/Daan/vbf-work/tools-dl/smali/smali-2.5.2.jar a --api 34 hctport/fwsrc -o hctport/out/classes.dex
cd hctport/out && rm -f hct-framework.jar && zip -X -0 hct-framework.jar classes.dex

# 5. verify
python3 /home/Daan/vbf-work/VibeBakingFirmware/tools/dex_api_check.py \
  --framework /tmp/opencode/fw/framework/*.dex /tmp/opencode/fw/x/*/classes.dex \
  --app hctport/out/classes.dex
python3 hctport/scripts/dex_field_check.py \
  --framework /tmp/opencode/fw/framework/*.dex /tmp/opencode/fw/x/*/classes.dex \
  --app-dir hctport/fwsrc
python3 hctport/scripts/dex_ref_summary.py hctport/out/classes.dex
# instruction-level proof: round-trip the assembled dex and grep the disassembly
rm -rf /tmp/opencode/rt && java -jar /home/Daan/vbf-work/tools-dl/smali/baksmali-2.5.2.jar d \
  hctport/out/classes.dex -o /tmp/opencode/rt
grep -rnE '^\s+[a-z0-9/-]+ .*(StackInfo|ActivityManager\$TaskInfo|getAllStackInfos|IActivityManager;->getFocusedStackInfo|IActivityTaskManager;->getStackInfo|IActivityManager;->removeStack|IActivityManager;->setFocusedStack|switchDualScreen|hasSecondScreenActivityStack|moveStackToDisplay|setToDefaultsDensity)' /tmp/opencode/rt   # -> no output, exit 1
grep -rn 'blacklist\|greylist\|whitelist' /tmp/opencode/rt | wc -l                                # -> 0
find /tmp/opencode/rt -name '*.smali' | wc -l                                                    # -> 33
```

## 2. Which `--api` was used, and why

**`--api 34`.** Not a compromise: smali 2.5.2 accepts the hiddenapi tokens at *any* api level. As a
control, assembling the unmodified `s10fw2/android/microntek` gave byte-identical output at
`--api 29` and `--api 34` (both 63132 bytes, same sha1 signature at header offset 0x0c), so the api
flag was never the blocker the earlier survey assumed — the blocker was the hiddenapi data itself.

Why the flags had to go: dexlib2 appends a hiddenapi member-data block after the annotations
directory. Same sources, flags stripped, nothing else changed:

| dex | size | annotations dir (size@off) | tail after annotations |
|---|---|---|---|
| A10 sources with hiddenapi flags | 63132 | 50280 @ 12852 | 63132 → **740 bytes of hiddenapi data appended** |
| same sources, flags stripped | 62392 | 49540 @ 12852 | 62392 → **nothing appended** |
| final jar dex (stripped + stubbed) | 59888 | 47460 @ 12428 | 59888 → **nothing appended** |

Confirmed independently: baksmali re-disassembling `out/classes.dex` emits **zero** hiddenapi
modifier tokens (it prints them whenever the dex carries hiddenapi data — it prints
`greylist-max-o`/`whitelist`/`blacklist` for A10 and A14 stock classes).

Dex version is **039** at every api level, which is what the A14 framework/services dexes use.
The header is dexlib2's ART-style 112-byte header (sha1 signature at 0x0c, ids table at 0x38:
strings/types/protos/fields/methods/classes/annotations at 0x38/0x40/0x48/0x50/0x58/0x60/0x68),
identical in layout to `/tmp/opencode/fw/framework/*.dex`, which is why `dex_api_check.py` reads it.
Consequence of dropping the flags: these classes are no longer marked hidden-API, so they behave as
ordinary public framework members on A14 (see report.md §0 note).

## 3. Stubbed method bodies (`android/microntek/HCTApi`, signatures untouched)

All were `static`; 13 are `public static`, the two split-screen helpers are `private static`. The
`blacklist` token was removed from their directive lines. `.registers` adjusted to the stub body.
No logging, no framework call.

| method signature | stub body | registers | why |
|---|---|---|---|
| `HCTApi.getAllStackInfos()Ljava/util/List;` | `new-instance v0, Ljava/util/ArrayList; invoke-direct {v0}, ArrayList-><init>()V; return-object v0` | 1 | `IActivityManager.getAllStackInfos()` gone in A14; empty list keeps iterating callers alive instead of NPE |
| `HCTApi.getFocusedStackInfo()Landroid/app/ActivityManager$StackInfo;` | `const/4 v0, 0x0; return-object v0` | 1 | `IActivityManager.getFocusedStackInfo()` gone |
| `HCTApi.getFocusedStackId()I` | `const/4 v0, -0x1; return v0` | 1 | read `StackInfo->stackId`; -1 = "no stack", same as the old catch path |
| `HCTApi.getFocusedStackpackage()Ljava/lang/String;` | `const/4 v0, 0x0; return-object v0` | 1 | read `StackInfo->topActivity` |
| `HCTApi.getStackComponentName(I)Landroid/content/ComponentName;` | `const/4 v0, 0x0; return-object v0` | 2 | read `StackInfo->topActivity` |
| `HCTApi.getStackTopPackage(I)Ljava/lang/String;` | `const/4 v0, 0x0; return-object v0` | 2 | read `StackInfo->topActivity` |
| `HCTApi.isVisibleFreeForm()Z` | `const/4 v0, 0x0; return v0` | 1 | read `StackInfo->visible`/`stackId` |
| `HCTApi.isWindowAppInSplitScreenPrimary(Landroid/content/Context;)Z` | `const/4 v0, 0x0; return v0` | 2 | called `IActivityTaskManager.getStackInfo(II)` |
| `HCTApi.isWindowAppInSplitScreenSecondary(Landroid/content/Context;)Z` | `const/4 v0, 0x0; return v0` | 2 | called `IActivityTaskManager.getStackInfo(II)` |
| `HCTApi.moveStackToDisplay(II)V` | `return-void` | 2 | `IActivityTaskManager.moveStackToDisplay(II)` gone (A14: `moveRootTaskToDisplay`) |
| `HCTApi.removeStack(I)V` | `return-void` | 1 | `IActivityManager.removeStack(I)` gone (A14: `removeTask(I)Z`, still used by `HCTApi.removeTask`) |
| `HCTApi.setFocusedStack(I)V` | `return-void` | 1 | `IActivityManager.setFocusedStack(I)` gone (A14: `setFocusedRootTask/setFocusedTask`) |
| `HCTApi.switchDualScreen()V` | `return-void` | 1 | HCT-added AIDL, no A14 equivalent |
| `HCTApi.hasSecondScreenActivityStack()Z` | `const/4 v0, 0x0; return v0` | 1 | HCT-added AIDL, no A14 equivalent |
| `HCTApi.getHCTResource(Landroid/content/Context;Landroid/content/res/Resources;Ljava/lang/String;)Landroid/content/res/Resources;` | `return-object p1` | 3 | called `DisplayMetrics.setToDefaultsDensity(IF)` twice (lines 2422, 2564 of the A10 source). Passthrough rather than null: the `ContextImpl.setResources` hook must still get a real `Resources` object |

Not stubbed but worth stating:
* `HCTApi.getStackInfo(II)Landroid/app/ActivityManager$StackInfo;` — its A10 body was *already*
  `const/4 v0, 0x0; return-object v0`, so it needed no change and contains no `StackInfo` instruction.
* `MTCData` — unaffected: no `DisplayMetrics`/`StackInfo` reference anywhere in it
  (`grep -n 'DisplayMetrics\|StackInfo' fwsrc/android/microntek/MTCData.smali` → 0 hits). The
  `setToDefaultsDensity` calls lived only in `HCTApi.getHCTResource`.
* One generic signature annotation (`@Signature "()Ljava/util/List<Landroid/app/ActivityManager$StackInfo;>;"`)
  disappeared with the `getAllStackInfos` body. It is debug metadata, not the method descriptor.
* `.param`/`.local`/`.line` debug directives inside the replaced bodies are gone with them.
* `HCTApi` still has 52 methods and every descriptor is unchanged; `getFocusedStackInfo`/`getStackInfo`
  still *return* `android/app/ActivityManager$StackInfo` (that is their signature), but no instruction in
  the dex mentions it — see §5.

## 4. Verification output

`dex_api_check.py` (framework = 5 framework dexes + 8 boot-jar dexes = 36885 classes):

```
framework classes: 36885; app invoke refs: 242
MISSING:
not resolvable here: 12
  Landroid/net/wifi/WifiManager;
  Ljava/io/File;
  Ljava/io/FileInputStream;
  Ljava/lang/Exception;
  Ljava/lang/Integer;
  Ljava/lang/Object;
  Ljava/lang/String;
  Ljava/lang/StringBuilder;
  Ljava/util/ArrayList;
  Ljava/util/Iterator;
  Ljava/util/List;
  Lorg/xmlpull/v1/XmlPullParser;
```
MISSING is empty (exit 0). Adding `/tmp/opencode/fw/services/*.dex` to `--framework` (52810 classes)
also gives an empty MISSING list — same 12 not-resolvable entries, which are core-library classes
(`java.*`, ART APEX `java.lang.Object`) plus `WifiManager`/`WifiConfiguration` that live in a wifi jar
that was never extracted. Saved copies: `out/api_check_framework.txt`,
`out/api_check_framework_services.txt`.

`scripts/dex_field_check.py` (the field-level twin — `dex_api_check.py` only resolves methods;
field_ids live at header 0x50 and class_data restarts the index accumulator per static/instance group):

```
framework classes: 36885; app field refs (from smali): 47
MISSING FIELDS:
not resolvable here: 1
  Landroid/net/wifi/WifiConfiguration;
```
So every field read/write resolves on A14, including `ActivityManager$RunningTaskInfo->topActivity`
and `->baseActivity` (declared on `android/app/TaskInfo`, which A14 defines and RunningTaskInfo
extends) and `DisplayMetrics->widthPixels/heightPixels`. Only `WifiConfiguration->apBand` is outside
the extracted jar set (it also was before the port).

`scripts/dex_ref_summary.py` — the framework classes this dex still invokes, and the missing stack APIs
are simply absent from it:

```
out/classes.dex: dex version 039, header_size 112, 33 classes, 446 method refs
  Landroid/app/ActivityManager;      forceStopPackage(String)V, getRunningAppProcesses()List, getRunningTasks(I)List
  Landroid/app/ActivityManagerNative; getDefault()IActivityManager
  Landroid/app/IActivityManager;     removeTask(I)Z
  Landroid/util/DisplayMetrics;      <init>()V
  Landroid/app/IActivityTaskManager;  (no references left)
  Landroid/util/DisplayMetrics->setToDefaultsDensity  (gone)
```

Instruction-level proof (round-trip disassembly of the assembled dex, `/tmp/opencode/rt`):
`grep -rnE '^\s+[a-z0-9/-]+ .*(StackInfo|ActivityManager\$TaskInfo|getAllStackInfos|
IActivityManager;->getFocusedStackInfo|IActivityTaskManager;->getStackInfo|IActivityManager;->removeStack|
IActivityManager;->setFocusedStack|switchDualScreen|hasSecondScreenActivityStack|moveStackToDisplay|
setToDefaultsDensity)'` → **no matches (exit 1)**, so no instruction anywhere in the 33 classes touches
`android/app/ActivityManager$StackInfo`, `ActivityManager$TaskInfo` or a removed stack API. The only
remaining occurrences of `StackInfo` in the whole build tree are two `.method` directive lines
(`getFocusedStackInfo`, `getStackInfo`) plus the jar's own string/type table entries for those
descriptors — i.e. signatures, never code. Round-trip also shows 0 hiddenapi tokens and 33 classes.

## 5. Dex facts

| item | value |
|---|---|
| magic / version bytes 4-6 | `dex\n039\0` → **039** |
| header_size (offset 0x24) | 112 |
| file_size (offset 0x20) | 59888 (matches actual file) |
| class_defs_size (offset 0x60) | **33** classes (all `android/microntek/*`, 15 packages + inner/AIDL classes) |
| strings / types / fields / methods | 835 / 102 / 301 / 446 |
| sha1 signature (0x0c..0x20) | `80dcaa1ca9a4203ec46e6abb50ff922673e43584` |
| jar | 60008 bytes, 1 entry `classes.dex`, compression method 0 (STORED), no extra field, 59888 bytes both sizes |

## 6. sha256

```
25b6d7a173f0414f5d0b0e9613f2cd60232fbb398b6b84a9449697c00dc2ebb7  hctport/out/classes.dex
4ddb63b30b70fa4a9b43ab408ab9c3464381a95f676ced61d6c9488472f568be  hctport/out/hct-framework.jar
```

`classes.dex` inside the jar hashes to the same value as the standalone file (the entry is STORED,
so `unzip -p hct-framework.jar classes.dex | sha256sum` reproduces the first line).

Reproducibility caveat: smali 2.5.2 assembles concurrently, so re-running step 4 over the same
`fwsrc` is not byte-reproducible. A second run gave a 59888-byte dex with identical counts (039,
33 classes, 446 method refs, 301 fields, 835 strings) but a different item order, hence a different
ART sha1 signature (`f60d32af...` vs the shipped `80dcaa1c...`) and sha256 `049b4e73...`; that build
also yields an empty MISSING list. The hashes above pin the exact bytes shipped in this jar -
re-hash after any rebuild.

## 7. Known residual risk for the next step (this jar alone is not the whole port)

* Two descriptors still mention `android/app/ActivityManager$StackInfo` because signatures were kept
  per instruction. Nothing inside this jar resolves them, but **external** callers (the §5 hooks in
  report.md: `ActivityManagerShellCommand`, `ActivityTaskManagerService`/`RootActivityContainer`,
  `LaunchParamsController`) must be ported onto `ActivityTaskManager$RootTaskInfo` before calling
  `HCTApi.getFocusedStackInfo`/`getStackInfo`, otherwise ART would fail to resolve that type in them.
* Stubbed behaviour is deliberately inert: focus/stack queries return null/-1, split-screen and
  dual-screen helpers return false, and stack control is a no-op. Re-implementing them on A14 root
  tasks (`getAllRootTaskInfos`, `getFocusedRootTaskInfo`, `getRootTaskInfo(II)`,
  `moveRootTaskToDisplay`, `setFocusedRootTask`, `removeTask`) is the follow-up, plus
  `DisplayMetrics.setToDefaultsDensity(IF)` re-added as a framework member if the DPI override
  (`persist.hctbox.density` / `persist.carbox.density`) is wanted.
* The Rockchip classes that shared `fw10/classes2.dex` (`android/os/RkDisplayOutputManager`,
  `android/os/audio/RkAudioSettingManager`, §1.2 of report.md) were **not** included — this jar is
  exactly the 33 `android/microntek/*` classes.
