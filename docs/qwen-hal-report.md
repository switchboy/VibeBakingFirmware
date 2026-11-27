# A14 (LineageOS 21) HAL bring-up report — RK3399 head unit

Analysis is read-only. Nothing under `VibeBakingFirmware/.git` was read. No adb, no block
device writes, no network. `debugfs` was used read-only on image files.

Evidence used:
- `/home/Daan/vbf-work/a14-work/a14-attempt10/{pmsg.txt, console-ramoops-0, state.txt, tombstones/tombstone_00..02}`
- `/home/Daan/vbf-work/a14-work/super9/vendor-new3.img` (vendor, ext4)
- `/home/Daan/vbf-work/a14-work/super9/system-new2.img` → **disappeared mid-analysis** (the parent
  session rebuilt images: `system-new3/new4.img`, `vendor-new4.img`, `super-new5/6.img` appeared at
  00:50–00:58). Re-checked the newest images where relevant: `vendor-new4.img` and `system-new4.img`
  are identical to `vendor-new3.img`/`system-new2.img` for every item in this report (verified below).
- Stock Android 10 trees: `analysis/vendor_tree/vendor`, `analysis/daisaita_a10/vendor_tree/vendor`,
  plus `analysis/daisaita_a11/vendor_tree/vendor` (Android 11 OEM) and `analysis/vendor_files.txt`,
  `analysis/system_files.txt`.

---

## 1. `vendor.audio-hal` — "Could not register Audio Core API"

### MEASURED

**rc file** — `/vendor/etc/init/android.hardware.audio.service.rc` (vendor-new3.img, inode 564, 524 bytes):
```
service vendor.audio-hal /vendor/bin/hw/android.hardware.audio.service
    class hal
    user audioserver
    group audio camera drmrpc inet media mediadrm net_bt net_bt_admin net_bw_acct wakelock context_hub system
    capabilities BLOCK_SUSPEND SYS_NICE
    rlimit rtprio 10 10
    ioprio rt 4
    task_profiles ProcessCapacityHigh HighPerformance
    onrestart restart audioserver
```
No `interface` lines at all. There is also `/vendor/etc/init/android.hardware.audio@2.0-service.rc`
(inode 565) which declares `interface android.hardware.audio@4.0::IDevicesFactory default` and
`@2.0`, with `oneshot`.

**Service binary** — `/vendor/bin/hw/android.hardware.audio.service` (11032 bytes):
```
file: ELF 32-bit LSB pie executable, ARM, EABI5 ... for Android 34, BuildID= f8dc59104d82e743268fd90fc1860122
```
Build ID matches the aborting process in `pmsg.txt:596` / `tombstone_02`.
Strings in the binary (exact, from `strings -a`):
```
registerPassthroughServiceImplementation / dlopen / dlsym
ABinderProcess_setThreadPoolMaxThreadCount, ABinderProcess_startThreadPool, libbinder_ndk.so
Could not register %s            audiohalservice
Audio Core API / Audio Effect API / Soundtrigger API / Bluetooth Audio API / Bluetooth Audio Offload API
android.hardware.audio@4.0::IDevicesFactory      android.hardware.audio@5.0::IDevicesFactory
android.hardware.audio@6.0::IDevicesFactory      android.hardware.audio@7.0::IDevicesFactory
android.hardware.audio@7.1::IDevicesFactory
android.hardware.audio.effect@4.0/5.0/6.0/7.0::IEffectsFactory
android.hardware.soundtrigger@2.0/2.1/2.2/2.3::ISoundTriggerHw
android.hardware.bluetooth.audio@2.0/2.1/2.2::IBluetoothAudioProvidersFactory
android.hardware.bluetooth.a2dp@1.0::IBluetoothAudioOffload
Factory function %s not found in libName %s: %s
createIBluetoothAudioProviderFactory / android.hardware.bluetooth.audio-impl
createISoundDoseFactory             / android.hardware.audio.sounddose-vendor-impl
```
It is an **Android-14 passthrough-registration wrapper**: it dlopen's impl libraries and registers
each interface version, grouping them into API families; when a whole family fails it calls
`__android_log_assert("Could not register %s", ...)` — exactly the tombstone_02 stack:
```
Abort message: 'Could not register Audio Core API'
  #02 /system/lib/liblog.so (__android_log_assert+160)
  #03 /vendor/bin/hw/android.hardware.audio.service (main+2488) (BuildId: f8dc59104d82e743268fd90fc1860122)
```
Note: the binary contains **no** AIDL audio interface name (`android.hardware.audio.core.*`); it only
tries AIDL factories for bluetooth-audio and sounddose. So the "Audio Core API" it fails on is the
HIDL `IDevicesFactory` family.

**Log evidence (pmsg.txt, tag line then message line)**
```
510 hwservicemanager: getTransport: Cannot find entry android.hardware.audio@7.1::IDevicesFactory/default ...
518 ...@6.0::IDevicesFactory/default ...
522 HidlServiceManagement: Service android.hardware.audio@6.0::IDevicesFactory/default must be in VINTF manifest in order to register/get.
524 LegacySupport: Could not register service android.hardware.audio@6.0::IDevicesFactory/default (-2147483648).
526 LegacySupport: Could not get passthrough implementation for android.hardware.audio@5.0::IDevicesFactory/default.
528 ...@4.0::IDevicesFactory/default ...
532 audiohalservice: Could not register Audio Core API
550 FactoryHal: hasAidlHalService android.hardware.audio.core.IModule/default: false
566/568 hwservicemanager: Since android.hardware.audio@5.0::IDevicesFactory/default is not registered,
        trying to start it as a lazy HAL ... but was unable to
```
Counts per boot cycle (pmsg): audio abort 2/cycle × 2 captured cycles; `console-ramoops-0` shows
`Service 'vendor.audio-hal' ... received signal 6` **14 times**, `audioserver` killed 14 times.

`console-ramoops-0` also proves the AIDL audio core is not declared (4 occurrences):
```
234: servicemanager: Could not find android.hardware.audio.core.IModule/default in the VINTF manifest. No alternative instances declared in VINTF.
236: servicemanager: Could not find android.hardware.audio.effect.IFactory/default in the VINTF manifest. ...
```

**VINTF manifest** — `/vendor/etc/vintf/manifest.xml` (4442 bytes, `target-level="4"`):
```xml
<hal format="hidl"><name>android.hardware.audio</name><transport>hwbinder</transport>
    <fqname>@5.0::IDevicesFactory/default</fqname></hal>
<hal format="hidl"><name>android.hardware.audio.effect</name><transport>hwbinder</transport>
    <fqname>@5.0::IEffectsFactory/default</fqname></hal>
<hal format="hidl"><name>android.hardware.soundtrigger</name><transport>hwbinder</transport>
    <fqname>@2.0::ISoundTriggerHw/default</fqname></hal>
```
`/vendor/etc/vintf/manifest/` contains only cas@1.2, health@2.1, keymint/secureclock/sharedsecret,
wifi/hostapd/supplicant xml — **no audio xml, no rockit xml, no weaver xml**.
`/vendor/etc/vintf/compatibility_matrix.xml` (`type="device"`): hidl frameworks/sensorservice/
hidl.allocator/manager/memory/token/wifi.keystore + `system-sdk 29, 34`. No audio entry.

**Impl libraries present** (`debugfs ls -l /lib/hw`, `/lib64/hw`):
```
/lib /lib64:  android.hardware.audio.effect@6.0-impl.so   android.hardware.audio@6.0-impl.so
              audio.primary.rk30board.so  audio.primary.default.so  audio.r_submix.default.so  audio.usb.default.so
```
Missing: `android.hardware.audio@5.0-impl.so`, `android.hardware.audio.effect@5.0-impl.so`,
`android.hardware.soundtrigger@2.x-impl.so`, any bluetooth-audio impl, any AIDL audio impl/ndk lib
(`/lib64` has only keymint/keystore2 AIDL ndk libs).

Stock Android 10 vendor (`analysis/vendor_files.txt`, both stock trees have them):
```
/lib/hw/android.hardware.audio@5.0-impl.so            196720   (lib64 260496)
/lib/hw/android.hardware.audio.effect@5.0-impl.so    219080   (lib64 302160)
/lib/hw/android.hardware.soundtrigger@2.0-impl.so     24832   (32-bit only)
/bin/hw/android.hardware.audio@2.0-service            15592
```
The A14 vendor-new3.img **does** still ship `/bin/hw/android.hardware.audio@2.0-service` (15592 bytes,
`file` → "for Android 29") and the interface libs it needs (`android.hardware.audio@2.0/4.0/5.0.so`,
`common@5.0.so`, `effect@5.0.so`, `soundtrigger@2.0/2.1/2.2.so`) plus compat shims
`libhidltransport.so` and `libhwbinder.so` (2420 B in `/lib`, 133384 B in `/lib64`), so that binary
can actually link on this vendor image (verified via `readelf -d` NEEDED vs `debugfs ls`).

### KNOWLEDGE
Android 14 audioflinger prefers AIDL `android.hardware.audio.core.IModule/default`; when absent it
falls back through HIDL 7.1 → 7.0 → 6.0 → 5.0 → 4.0 (this is what the log shows). hwservicemanager
refuses any registration whose interface is not in the VINTF manifest (device or framework), hence
`must be in VINTF manifest ... (-2147483648)`. A passthrough registration additionally needs
`android.hardware.audio@<ver>-impl.so`. With `target-level="4"` libvintf normally ignores framework
matrices newer than the manifest target level, so AIDL audio is not *mandated* here — that is
knowledge, not measured.

### The mismatch, stated plainly
The manifest declares **audio@5.0 / effect@5.0**, but the vendor ships only **@6.0 impl libs**, and
the service binary registers 4.0/5.0/6.0/7.0/7.1. Every candidate fails: 7.1/7.0/6.0 are not in the
manifest (registration refused), 5.0/4.0 are in the manifest but have no impl lib. So the "Audio
Core API" family registers nothing → `LOG_ALWAYS_FATAL` → SIGABRT → init restart loop → audioserver
killed → `sys.init.updatable_crashing=1` (console lines 172/256/436) → feeds RescueParty.

### Minimal fix (pick one)
**A. Manifest-only (smallest change, nothing copied):** edit `/vendor/etc/vintf/manifest.xml` to
```xml
<name>android.hardware.audio</name> ... <fqname>@6.0::IDevicesFactory/default</fqname>
<name>android.hardware.audio.effect</name> ... <fqname>@6.0::IEffectsFactory/default</fqname>
```
The @6.0 impl libs are already in `/lib/hw` and `/lib64/hw`. Also **drop the
`android.hardware.soundtrigger` @2.0 entry** (no impl lib exists).
Risk, honest: the binary's other families ("Soundtrigger API", "Bluetooth Audio API",
"Bluetooth Audio Offload API") may also be assert-fatal. I could not determine that: the binary is
stripped Thumb code and `llvm-objdump` does not decode the call targets; `readelf -r` only shows one
`R_ARM_JUMP_SLOT` for `__android_log_assert`. In stock Android 10 the legacy service printed the
same bluetooth/soundtrigger messages and still booted, so those messages are likely non-fatal.
**B. Closest to stock behaviour:** restore the stock @5.0 impl libs from
`analysis/vendor_tree/vendor/lib{64}/hw/android.hardware.audio@5.0-impl.so` and
`android.hardware.audio.effect@5.0-impl.so`, keep manifest at @5.0, and switch
`/etc/init/android.hardware.audio.service.rc` to point at
`/vendor/bin/hw/android.hardware.audio@2.0-service` (already present), or delete that rc so only
`vendor.audio-hal-2-0` runs. Also restore `android.hardware.soundtrigger@2.0-impl.so` (32-bit,
stock) if the soundtrigger family is fatal.
**C.** Keep the AIDL service and build/ship real AIDL audio impl libs — not minimal, nothing local.

`vendor-new4.img` (00:38) has exactly the same audio state as `vendor-new3.img` — same manifest, same
@6.0-only impls, no @5.0 impl. So neither image is fixed yet.

---

## 2. `vendor.rockit-hal-1-0` — missing seccomp policy

### MEASURED
`tombstone_01` (32-bit, uid 1013):
```
Abort message: 'Could not read base policy file '/vendor/etc/seccomp_policy/rockit.vendor.base-arm.policy''
 #02 /vendor/lib/libbinder.so (android::base::LogMessage::~LogMessage()+322)
 #03 /vendor/lib/libavservices_minijail.so (android::SetUpMinijailList(...)+660)
 #04 /vendor/lib/libavservices_minijail.so (android::SetUpMinijail(...)+52)
 #05 /vendor/bin/hw/rockchip.hardware.rockit.hw@1.0-service (main+188) (BuildId: 0f0d496df9f5fabee8bcf2dd14dc8e71)
```
`console-ramoops-0`: `Service 'vendor.rockit-hal-1-0' ... received signal 6` **15 times**.

`/vendor/etc/seccomp_policy` in **vendor-new3.img** and **vendor-new4.img**:
```
655  mediacodec.policy   119 bytes      ← the only file
```
Stock A10 trees:
```
analysis/vendor_tree/vendor/etc/seccomp_policy/          → mediacodec.policy (119)
analysis/daisaita_a10/vendor_tree/vendor/etc/seccomp_policy/ → mediacodec.policy (119)
analysis/vendor_files.txt:584  /etc/seccomp_policy/mediacodec.policy   119
```
→ **Neither Android 10 OEM vendor has a rockit policy.** The only policy file found anywhere in
`analysis/` is from the Android **11** tree:
```
analysis/daisaita_a11/vendor_tree/vendor/etc/seccomp_policy/rockit.vendor.base.policy  (1872 bytes)
```
Its content is arm-32-bit (`mmap2`, `getuid32`, `fstat64`, `mremap: arg3 == 3`, ...
`@include /system/etc/seccomp_policy/crash_dump.arm.policy`).

Binary identity / requested paths:
```
md5 /tmp/opencode/vbf/rockit-svc (from vendor-new3)          4e1e62e900765573dbd020118c852aae
md5 analysis/vendor_tree/vendor/bin/hw/rockchip...@1.0-service 4e1e62e900765573dbd020118c852aae   ← identical
strings: /vendor/etc/seccomp_policy/rockit.vendor.base-arm.policy
         /vendor/etc/seccomp_policy/rockit.vendor.ext.policy
```
The A11 blob asks instead for `rockit.vendor.base.policy` (no `-arm` suffix) — the naming changed
between the A10 and A11 vendor builds, so the A11 file cannot be dropped in un-renamed.
The A14 system image **does** have the include target:
`/system/etc/seccomp_policy/crash_dump.arm.policy` (559 bytes, `system-new4.img`).

### Does anything depend on rockit? (MEASURED)
- Dumped all 176 libs of `/vendor/lib` and all 33 libs of `/vendor/lib/hw` + `/vendor/lib64/hw`:
  the only files whose `DT_NEEDED` or strings mention rockit are `librockit_hw_hidl@1.0.so` and
  `rockchip.hardware.rockit.hw@1.0.so` themselves. No client.
- `/vendor/etc/init/*` (all 26 rc files dumped): rockit appears **only** in its own rc.
- `/vendor/etc/vintf/manifest.xml` does **not** declare `rockchip.hardware.rockit.hw` (the stock
  `manifest/rockchip.hardware.rockit.hw@1.0-service.xml` was dropped). So its HIDL registration would
  be refused anyway; it dies before registering.
- `/system/etc/vintf/compatibility_matrix.device.xml` declares
  `rockchip.hardware.rockit.hw 1.0 optional="true"`.
- The Android 14 system image has **no** rockit clients
  (`debugfs ls /system/lib`, `/system/lib64` → no `librockit*`, no `rockchip.*`), whereas the stock
  A10 system did: `system_files.txt:1709 /system/lib/librockit.so`, `:1710 librockit_hw_client@1.0.so`,
  `:1711 librockit_interface.so`, `:1779 rockchip.hardware.rockit.hw@1.0.so`. `analysis/app_layer_system_abi.txt:31`
  already records `librockit_interface.so` as UNRESOLVED on Android 14.

### Fix
**Minimal and safe: disable the service.** Remove `/vendor/etc/init/rockchip.hardware.rockit.hw@1.0-service.rc`
(or add `disabled` + no `on start` trigger). Nothing on Android 14 can call it; nothing in the logs
waits for it; it only generates crash-loop noise and `sys.init.updatable_crashing=1`.

**Alternative if you want rockit alive:** create both files the binary reads —
`/vendor/etc/seccomp_policy/rockit.vendor.base-arm.policy` (content = the A11
`rockit.vendor.base.policy`, arm32 syscall names are correct for this 32-bit binary) and
`/vendor/etc/seccomp_policy/rockit.vendor.ext.policy` (the binary also asks for it; nothing local
supplies it — an empty/comment-only policy file should parse, unverified). Then re-check SELinux: the
service runs as `user media`, and init already complains about unlabeled vendor services (see §4).

Honest caveat: whether stock Android 10 rockit crash-looped too cannot be determined (its vendor also
lacks the policy); I did not boot stock.

---

## 3. gatekeeper

### MEASURED
Manifest declares it (`/vendor/etc/vintf/manifest.xml`):
```xml
<hal format="hidl"><name>android.hardware.gatekeeper</name><transport>hwbinder</transport>
    <fqname>@1.0::IGatekeeper/default</fqname></hal>
```
Vendor image `vendor-new3.img` / `vendor-new4.img` contain **no gatekeeper anything**:
- `/bin/hw` listing (25 entries): no `android.hardware.gatekeeper*`
- `/lib/hw`, `/lib64/hw`: no `android.hardware.gatekeeper@1.0-impl.so`, no `gatekeeper.rk30board.so`
- `/lib`, `/lib64`: no `librkgatekeeper.so`, no `libRkTeeGatekeeper.so` (weaver's `libRkTeeWeaver.v1.so` is present)
- `/etc/init`: no gatekeeper rc

Stock trees (both `vendor_tree` and `daisaita_a10/vendor_tree`, identical file list):
```
vendor/bin/hw/android.hardware.gatekeeper@1.0-service            11600
vendor/etc/init/android.hardware.gatekeeper@1.0-service.rc         132
vendor/lib/hw/android.hardware.gatekeeper@1.0-impl.so            19948   (lib64 20600)
vendor/lib/hw/gatekeeper.rk30board.so                            20444   (lib64 68424)
vendor/lib/librkgatekeeper.so                                    24496   (lib64 68240)
vendor/lib/libRkTeeGatekeeper.so                                 ...     (lib64 too)
```
System side (`system-new4.img`): `/system/bin/gatekeeperd` exists; `/system/etc/init/gatekeeperd.rc`:
```
service gatekeeperd /system/bin/gatekeeperd /data/misc/gatekeeper
    class late_start
    user system
    task_profiles ServiceCapacityLow
```
Log: `pmsg.txt:303/791/858/900/1347/2343` "Waited one second for
android.hardware.gatekeeper@1.0::IGatekeeper/default" + "Tried to start ... as a lazy service, but was
unable to" (11 occurrences across the captured cycles); `console-ramoops-0` has **75**
`init: Control message: Could not find 'android.hardware.gatekeeper@1.0::IGatekeeper/default' for
ctl.interface_start from pid: 209 (/system/system_ext/bin/hwservicemanager)`.
`gatekeeperd` appears in init's shutdown kill list (`signal 15`) → it was running, stuck in `getService()`.

### Consequence (MEASURED part + KNOWLEDGE)
Measured: the gatekeeper waits do **not** stall system_server — in both captured cycles system_server
progressed past them (`StartAccessCheckingService took to complete: 3ms`, `StartActivityManager
took to complete: 99ms`); the stall is later (§4). The waste is ~1 s per retry × 75 ctl messages per
cycle plus a permanently blocked `gatekeeperd` thread.
Knowledge (not verified on this device): Android 14 credential storage goes through
`credstore` + `keystore2`/KeyMint (`/vendor/bin/hw/android.hardware.security.keymint-service` is
installed and declared in `/etc/vintf/manifest/android.hardware.security.keymint-service.xml`). A
missing gatekeeper removes the hardware rate-limiter for lock-screen credential verification, i.e.
screen-lock verification is degraded, but boot does not depend on it. A declared-but-absent HIDL HAL
is worse than simply not declaring it: every consumer spins forever.

### Minimal fix
**A. Remove the gatekeeper `<hal>` block from `/vendor/etc/vintf/manifest.xml`** — no binaries, no
sepolicy work, stops the 75 ctl messages and the spinning clients. (Consider removing
`android.hardware.light` and `android.hardware.soundtrigger` in the same edit.)
**B. Restore the stock service** — copy `bin/hw/android.hardware.gatekeeper@1.0-service`,
`etc/init/android.hardware.gatekeeper@1.0-service.rc`, `lib{,64}/hw/android.hardware.gatekeeper@1.0-impl.so`,
`lib{,64}/hw/gatekeeper.rk30board.so`, `lib{,64}/librkgatekeeper.so`, `lib{,64}/libRkTeeGatekeeper.so`.
Needs vendor sepolicy for a `hal_gatekeeper_default` domain: init already logs the generic complaint for
a vendor service without a domain transition (measured for weaver, `console-ramoops-0:102`):
```
init: File /vendor/bin/hw/android.hardware.weaver@1.0-service (labeled "u:object_r:vendor_file:s0")
has incorrect label or no domain transition from u:r:init:s0 to another SELinux domain defined.
```
Gatekeeper is TEE-backed (`tee-supplicant` is running), so B may also need tee policy allowances.
A is the minimal change; B is the "real gatekeeper" change.

---

## 4. Other failures, ranked by likelihood of blocking `sys.boot_completed`

### MEASURED, per boot cycle
`console-ramoops-0` covers 15 boot cycles; `pmsg.txt` captures 2 full system_server runs
(4 `ZygoteInit` lines). In both captured runs system_server ends at:
```
SystemServerTiming / Starting com.android.server.display.DisplayManagerService     ← never "took to complete"
```
last completed timing: `StartDisplayOffloadService took to complete: 0ms`.
Signal-death counts in console (15 cycles): `vendor.hwcomposer-2-1` SIGSEGV ×15, and init then kills
`surfaceflinger` ×15, `zygote` ×15, `cameraserver` ×15, `media` ×15, `netd` ×15, `wificond` ×15,
`zygote_secondary` ×15. Console ends with:
```
201.976676 init: Reboot ending, jumping to kernel
202.128867 reboot: Restarting system with command 'RescueParty'
```
pmsg: `RescueParty: Attempting rescue level WARM_REBOOT` → `Finished rescue level WARM_REBOOT`.
`state.txt` shows `boot_completed:` empty, uptime 27.35 s.

**1. `vendor.hwcomposer-2-1` crash loop — the actual boot blocker.**
`tombstone_00` / pmsg lines 805–832 (`tombstone_24`) and 3005–3032 (`tombstone_27`):
```
signal 11 (SIGSEGV), SEGV_MAPERR, fault addr 0x0 — Cause: null pointer dereference
 #00 pc 0 (<unknown>)  #01 libhwc2on1adapter.so (HWC2On1Adapter::populateCapabilities()+64) (BuildId d504edcc...)
 #03 composer@2.1-service (passthrough::HwcLoader::openDeviceWithAdapter+532) (BuildId 334ac14a...)
```
Measured cause (disassembly, `llvm-objdump -d --arch-name=aarch64`):
- Android 14 adapter `hwc/adapter-a14.so` (Build ID `d504edcca100b686fefe24646d190f8c`) in `populateCapabilities`:
  `ldr x0,[x19,#0xb8]; ldr x8,[x0,#0x98]; blr x8` → x8 = 0 → jump to pc 0x0.
- Android 10 adapter `hwc/adapter-a10.so` (Build ID `27bf64dafcfd54665af22be3fcbf2b2f`) in the same function:
  `ldr x0,[x19,#0xb8]; ldr x8,[x0,#0xb8]; blr x8`.
So the A14 adapter reads a *different* slot of `hwc_composer_device_1` than the A10 header the stock
Rockchip `hwcomposer.rk30board.so` was built against → that slot is NULL. SurfaceFlinger dies, init
kills SF+zygote, DisplayManagerService waits for `SurfaceFlingerAIDL` (95 `init: Control message:
Could not find 'aidl/SurfaceFlingerAIDL'` lines), RescueParty warm-reboots. **This is what stops
`sys.boot_completed`.**
Status of the fix in the images: `vendor-new3.img` and `vendor-new4.img` both already contain the
A10-built adapter (`Build ID 27bf64da…`, dated 24-Nov 00:25) and the A10-built composer service
(`Build ID cce8425f…`, md5 `6598c7ec…`, identical to `hwc/svc-a10`), plus
`lib64/hw/android.hardware.graphics.composer@2.1-impl.so` md5 identical to the stock A10 impl. Its
undefined symbols are satisfiable by the vendor's libs (`libbinder.so`, `libhidlbase.so`,
`libhidltransport.so`, `android.hardware.graphics.composer@2.1.so`, all present). **I cannot boot, so
whether this actually fixes the crash is unverified.**

**2. `vendor.audio-hal` abort loop** (§1) — 14 SIGABRT deaths/cycle set, `audioserver` killed,
`flags_health_check: ServerConfigurableFlagsReset updatable crashing detected, resetting flags`,
`sys.init.updatable_crashing=1` triggers `exec /system/bin/flags_health_check UPDATABLE_CRASHING`
(console 172/256/436…). No audio, and it contributes to RescueParty, but it is not the display stall.

**3. `android.hardware.light@2.0::ILight/default` declared but not installed.** Manifest declares it;
`/bin/hw` has no light service, `/lib/hw` + `/lib64/hw` have only the legacy `lights.rk3399.so`
(no `android.hardware.light@2.0-impl.so`). Stock trees have service+rc+impl. Evidence:
```
pmsg: Since android.hardware.light@2.0::ILight/default is not registered, trying to start it as a lazy HAL … unable to   (4×, last cycle)
console:214 servicemanager: Could not find android.hardware.light.ILights/default in the VINTF manifest.
```
`StartLightsService took to complete: 4ms` (so the fetch is off the main start sequence) — the log
*tail* is stuck in light-wait retries while the rescue reboot runs. Not proven boot-blocking, but it
spins forever and is a declared-but-absent HAL lie. Fix: restore stock light service+impl, or remove
the manifest entry.

**4. gatekeeper declared but absent** (§3) — client spinning + stuck `gatekeeperd`; degrades
lock-screen credential verification; measured not boot-blocking.

**5. `vendor.rockit-hal-1-0` crash loop** (§2) — 15 deaths/cycle, pure noise + updatable-crashing
flag; disable it.

**6. `vendor.weaver-hal-1-0` installed but undeclared.** Registration refused:
```
pmsg:880 Service android.hardware.weaver@1.0::IWeaver/default must be in VINTF manifest in order to register/get.
pmsg:882 Could not register service android.hardware.weaver@1.0::IWeaver/default (-2147483648).
console:102 init: File /vendor/bin/hw/android.hardware.weaver@1.0-service … has incorrect label or no domain transition …
```
The stock `manifest/android.hardware.weaver@1.0-service.xml` was dropped. Harmless (optional), but
it restart-loops and prints SELinux complaints. Fix: add the xml back, or remove the service/rc.

**7. `android.hardware.power.stats@1.0::IPowerStats/default` missing** (6× in pmsg;
`PowerStatsService: Unable to get power.stats HAL service.` / `nativeInit failed to connect …`):
service still completes (`StartPowerStatsService took to complete: 5ms`). Harmless.

**8. `android.hardware.configstore@1.0::ISurfaceFlingerConfigs/default` missing** (2×): SurfaceFlinger
logs it and continues. Harmless.

**9. Android-14 AIDL lookups that simply have no vendor implementation** (console 28/135/208/211/213/214):
`graphics.composer3.IComposer`, `net.nlinterceptor.IInterceptor`, `power.stats.IPowerStats`,
`memtrack.IMemtrack`, `power.IPower`, `light.ILights` — all "Could not find … No alternative instances
declared in VINTF". These are optional fallbacks; harmless (the legacy HIDL counterparts are installed
for power/memtrack/sensors/health/composer).

**10. Declared-but-absent radio.** Manifest declares `android.hardware.radio@1.1::IRadio/slot1`,
`ISap/slot1`, `android.hardware.radio.deprecated@1.0::IOemHook/slot1`, but `/vendor/bin` has no `rild`
(stock A10 has `rild`). No radio/RIL lines appear anywhere in pmsg or console → no measured wait
(head unit has no telephony stack running). Fix: drop those entries.

**11. adb gadget failure — blocks debugging, not boot.**
```
console:7 configfs-gadget fe800000.dwc3: failed to start g1: -19
console:8 init: Command 'write /config/usb_gadget/g1/UDC ${sys.usb.controller}' … failed: No such device
```
plus `symlink() failed: File exists` repeats. Not boot-blocking; it explains why you cannot get adb.

**12. Minor, non-blocking:**
- `PackageWatchdog: Could not save metadata to file: /metadata/watchdog/mitigation_count.txt: ENOENT` → `/metadata` partition not mounted.
- `__bionic_open_tzdata: couldn't find any tzdata when looking for Asia/Shanghai!` (state.txt) → no tzdata.
- `failed waiting for OOM events: RuntimeException: listener failed to register to OOM events` (×2).
- `BatteryNotifier: batterystats service unavailable!` — consequence of system_server never finishing.
- `SurfaceFlinger: Failed to set SurfaceFlinger binder threadpool priority to SCHED_FIFO` / `RenderEngine: Couldn't set SCHED_FIFO` — cosmetic.
- `hwcomposer-drm`/`hwc_rk`: `BP: baseparamter file cann't be find.` / `Could not get hdr … property` — vendor HWC1 noise; also `is_hdr_panel_support_st2084: blob is null`.
- `init: Could not create socket 'pdx/system/vr/display/*'` ×15 — normal on non-GKI configs.

### Not blocked / healthy (measured, no errors)
`vendor.keymint-default` + `keystore2` + `credstore` started; `health-hal-2-1`, `vendor.power-hal-1-0`,
`vendor.sensors-hal-1-0`, `vendor.memtrack-hal-1-0`, `vendor.gralloc-2-0`, `vendor.media.omx`,
`vendor.drm-*`, `vendor.cas-hal-1-2`, `vendor.gnss_service`, `vendor.wifi_hal_legacy`, `tee-supplicant`
appear only in the shutdown kill list, never as crash deaths. `android.frameworks.stats@1.0::IStats/default`
registered (`pmsg: Registered android.frameworks.stats@1.0::IStats/default`). Allocator/mapper:
`allocator@2.0-service` + `mapper@2.0-impl-2.1.so` present and declared (`passthrough arch="32+64"`).
Thermal: `StartThermalManager took to complete: 1ms` (no thermal HAL needed).

---

## Ranked action list (minimal, in order)

1. **Composer**: keep the A10-built `libhwc2on1adapter.so` + A10-built composer service already in
   vendor-new3/new4 (verified Build IDs/md5). If attempt 11 still crashes, the next suspect is
   `hwcomposer.rk30board.so` vs the A10 header layout — measure again from a new tombstone.
2. **Audio**: manifest `audio`/`audio.effect` → `@6.0::IDevicesFactory/default` / `@6.0::IEffectsFactory/default`
   (impl libs already present), and drop the `soundtrigger@2.0` entry. Fallback plan B: restore stock
   `@5.0-impl.so` pair + run `android.hardware.audio@2.0-service`.
3. **Light**: restore stock light service+impl, **or** remove the `android.hardware.light` manifest entry.
4. **Gatekeeper**: remove the manifest entry (minimal), or restore stock gatekeeper service+impl+rc+sepolicy.
5. **Rockit**: delete/disable `/vendor/etc/init/rockchip.hardware.rockit.hw@1.0-service.rc`.
6. **Weaver/radio**: delete the rc (weaver) or declare it (xml), and drop the radio entries — they are
   declared-but-absent lies that only generate noise.

## Things I could NOT determine
- Whether the composer fix in vendor-new3/new4 actually boots (no boot available).
- Whether the A14 audio service asserts fatally for the Soundtrigger / Bluetooth-audio families too
  (stripped Thumb code; `llvm-objdump` cannot resolve those `bl` targets; relocs show only one
  `__android_log_assert` jump slot).
- Whether libvintf really ignores framework matrices > target-level 4 for this manifest (knowledge
  about libvintf filtering; not measured here — no vintf mismatch is logged in init, which is
  consistent with it).
- Whether stock Android 10 rockit crash-looped (stock vendor lacks the policy too).
- The exact `hwc_composer_device_1` field name at offset 0x98 vs 0xb8 (measured offsets, not names).
- `system-new2.img` vanished mid-analysis; all system-side checks were re-run on `system-new4.img`
  and gave the same results.
