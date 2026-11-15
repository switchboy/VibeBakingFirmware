# Phase 1 — feasibility: how far can this vendor be dragged forward?

## Headline

**Android 14 (API 34) is the realistic ceiling, and it is achievable without touching the
hardware blobs.** Android 15 is not achievable without reimplementing the vendor HAL surface.

Why:

1. **Treble is designed for exactly this.** A device launched with Android 10 (`target-level 4`,
   VNDK 29) can receive a framework-only update: only `system`/`product`/`odm` (+ APEXes) are
   replaced, `vendor`/`boot` stay as shipped. Verified: `tools/hal_gap.py` shows **0 hard
   requirement gaps** between the shipped `vendor_manifest.xml` and the shipped framework matrix
   (FCM level 4), and `libvintf` at runtime always evaluates the framework matrix *at the vendor's
   shipping FCM level* (plus optional HALs from higher levels), so an Android 14 framework running
   against this vendor is a supported configuration.
2. **VNDK ceiling.** Android deprecates VNDK starting with **Android 15**; VNDK APEXes up to
   version 14 (Android 14) are kept precisely "to support existing vendor images". Our vendor needs
   `ro.vndk.version=29` libs (`libcutils`, `libutils`, `libhardware`, `libhardware_legacy`,
   `libhwc2on1adapter`, `libchrome`, …) to keep the blobs linkable. On Android 15 those snapshots are
   gone → every Rockchip blob breaks. So: **Android 14 = last version where the vendor can stay untouched.**
3. **HIDL ceiling.** HIDL is deprecated since Android 10 but still functional; graphics composer
   HIDL 2.1–2.4 are "deprecated" from Android 13 (still served), and HIDL support ends in
   Android 15/16. Android 14 keeps our composer 2.1 / audio 5.0 / camera 2.5 / mapper 2.0 chain.
4. **Kernel.** Android 14 does not require GKI for an *upgrade* device; GKI applies to devices
   launching with Android 12+. VINTF kernel matching for our 4.19 kernel resolves to branch
   `4.19-q` (FCM 4) — which exists (`kernel/configs/q/android-4.19`) and requires kernel ≥ 4.19.42;
   we have 4.19.111 ✓. **Caveat resolved Nov 15 (re-measured, offline):** the earlier claim that the
   shipped kernel has "no IKCONFIG embedded" was a bad method - `strings`/`grep -a` cannot see the
   embedded config because it is **gzip-compressed**. A tolerant gzip scan of the kernel payload inside
   the D40 stock backup's `boot.bin` (and inside the Nov 13 live `boot` dump) finds a gzip stream at
   offset **14,471,104** that inflates to exactly **154,656 B**, byte-identical to
   `analysis/daisaita_a10_kernel_config.txt` and to the live `/proc/config.gz` dump
   (`analysis/hu_kernel_config_live-20261113.txt`). The older `analysis/boot/kernel` payload carries its
   own blob at 14,403,520 inflating to 154,501 B (a third variant, differing from the Nov 4 dump by four
   lines: `CONFIG_AIC_WLAN_SUPPORT`, `CONFIG_AIC8800_WLAN_SUPPORT`, `CONFIG_SND_ALOOP`). So **both**
   vendor kernels ship their config, `/proc/config.gz` works on the kernel running today, and no
   `libvintf`/`assemble_vintf` workaround is needed for kernel-config matching. Still open: *which* kernel
   FCM branch the vendor manifest resolves to, and whether the pinned `kernel/configs` in our tree carries
   it (see the Nov 15 risk assessment in this file and in `docs/findings.md`).
5. **Boot image.** The shipped U-Boot reads Android boot header v2 with no DTB in `boot.img`.
   Android's `mkbootimg` can still emit header v2/v3 → keep the existing bootloader untouched.

## The Android-14 gap list (vendor surface we must add or wrap)

| HAL in vendor today | Android 14 need | Strategy |
|---|---|---|
| `keymaster@3.0` (`keystore.rk30board.so`) | KeyMint (`IKeyMintDevice`) required by keystore2 since Android 11 | **A** software KeyMint (AOSP `keymint-service`, test-only attestation) — simplest; **B** wrapper exposing KeyMint 4.x over the legacy blob (keeps HW-backed keys, more work) |
| `gatekeeper@1.0`, `weaver@1.0` | accepted as-is (HIDL still supported) | keep; software gatekeeper if blob misbehaves |
| `audio@5.0` + `audio.effect@5.0`, loaded through `libhardware_legacy.so` + `audio.primary.rk30board.so` | HIDL audio 5.0 still served in 14, but `libhardware_legacy` is not in the platform anymore | ship a vendor-local `libhardware_legacy.so` + `libtinyalsa`/`libaudioroute`/`libspeexresampler`/`libaudioutils` built from Android-10 sources (the "wrapper" approach) |
| `composer@2.1` needing `libhwc2on1adapter` + `libhwc2onfbadapter` | deprecated but functional in 14 | ship vendor-local copies of both adapters |
| `allocator@2.0`/`mapper@2.0` + `gralloc.rk30board.so`/`libgralloc_drm.so` | Android 12+ prefers dmabuf heaps (kernel ≥5.6); kernel 4.19 has Rockchip **ion** | keep HIDL 2.0 allocator/mapper; ship a vendor `libion.so` shim that talks to `/dev/ion` via ioctls (Android 12 removed `libion` from the platform) |
| `camera.provider@2.4/2.5` needing `libchrome`, `libui`, `libnativewindow`, `librkisp/libvpu/librga/libjpeghwenc`, `libsync_vendor` | HIDL camera 2.5 supported in 14 | ship vendor-local `libchrome` (Android-10 copy) + vendor variants of `libui`/`libnativewindow`; Rockchip libs already live in vendor |
| `sensors@1.0`, `gnss@1.0`, `power@1.0`, `light@2.0`, `memtrack@1.0`, `health@2.0`, `drm@1.0/1.2`, `cas@1.1`, `wifi@1.0`, `bluetooth@1.0`, `usb@1.1`, `rild`/`radio@1.0` | HIDL versions accepted by the FCM-4 matrix | keep; verify runtime behaviour (Android 14 may only request the declared version) |
| none | `android.hardware.broadcastradio` (FM/DAB tuner) — **the HU radio app currently uses `/dev/mtc-radio` / `/dev/mtc-dab` directly**, not the HAL | optional: wrap MTC tuner into `broadcastradio@2.0` later to get standard Android radio integration |
| none | `android.hardware.automotive.vehicle` / `audiocontrol` / `evs` | optional: needed only if we move to Android Automotive instead of the HCT app layer |

## Kernel strategy options

| Option | Effort | Security | Risk |
|---|---|---|---|
| **K1 keep the shipped 4.19.111 binary** | none | kernel CVEs unpatched (4.19 LTS is dead since 2022) | lowest — guaranteed blob/driver compatibility; no IKCONFIG → needs VINTF patch |
| **K2 rebuild Rockchip BSP 4.19 from source + LTS backports** | days–weeks (needs BSP source + the out-of-tree `mtc-*` driver, which is GPL and *should* be published by the HU vendor; GPL compliance is our leverage to obtain it) | much better: 4.19 stable fixes, plus config for IKCONFIG/dm-verity | medium — must reproduce vendor driver behaviour exactly |
| **K3 port to 5.10/6.x GKI** | weeks–months; port `mtc-*`, ADV7181, RGA/IEP, Mali kbase to newer DRM/KMI | best | high — blobs (gralloc_drm/ion, composer, vulkan, camera ISP) talk to kernel interfaces that changed; likely breaks the hardware |

Owner preference on record: willing to stay on an old kernel for blob compatibility, prefers wrappers
over reimplementations → **K1 to get a first boot, then K2 as the security upgrade**. K3 is out of scope.

## Storage constraint

The reference payload's `dynamic_partitions_op_list` creates group `rockchip_dynamic_partitions`
with max size **3 258 974 208 B** holding system 1.44 GB + product 0.93 GB + vendor 0.33 GB +
odm 0.56 GB - already at the limit.

**Measured on the unit** (`docs/head-unit-findings.md`): `super` = `mmcblk2p14` =
3,263,168,512 B with system 1.02 + product 0.90 + vendor 0.28 + odm 0.17 GiB inside it, i.e.
only ~730 MB free. `userdata` (`mmcblk2p15`) is 58,844,495,360 B with 5.4 GiB used; eMMC total
62,813,896,704 B.

An Android 14 build (LineageOS 21) needs roughly 3.0-3.2 GiB, which does not fit in 3.04 GiB with
room for an update snapshot. **Decision D8: grow `super` to 8 GiB and shrink `userdata` to
53,517,729,280 B (49.84 GiB)** - partitions p1-p13 keep their byte offsets, so bootloader, DTB,
vbmeta, boot, recovery and cache contents stay valid; only p14/p15 change. `/data` stays F2FS but
is reformatted, so its content must be backed up first (see `docs/plan.md` M2b). With ~4 GiB spare
after the Android 14 images, future updates keep using this layout (no repartition, **D19**)
again, and we no longer have to strip Google/preinstalled apps to squeeze in.
## Delivery/flash constraint

The unit installs firmware via `Update.zip` on FAT32 USB/SD using its built-in upgrade path, driven
by a custom 3 MB `update-binary` that implements Rockchip-specific edify functions
(`write_raw_loader_image()`, `do_rk_firmware_upgrade()`) and writes `uboot/trust/dtbo/boot` plus the
dynamic partitions. Alternatives considered and rejected for v1 (**D18**): fastboot in the ABL (this
board has no USB loader/Boot-ADB through its own ports, and fastboot bypasses the recovery's loader
step), or a custom recovery/TWRP - nobody can prove it boots or reads touch input on this board.
Rockchip's MASKROM mode does exist on the PX6 board, but reaching it means opening the case and making
a USB cable with soldered resistors, and flashing there writes the whole boot chain from an
`update.img`; it is a brick rescue, not a transport (docs/flash.md). The rollback path is keeping the
current zip and flashing it again
(owner decision Nov 6 - no partition dumps, no restore tooling).

## Candidate strategies (cost/risk)

| # | Strategy | Effort | Outcome |
|---|---|---|---|
| S1 | **Minimal security refresh**: keep Android 10 base, replace only kernel/boot + updatable APEXes (WebView, etc.) + harden SELinux/props | days | still Android 10 (EOL), but browser/TLS much better; low risk |
| S2 | **Framework-only Android 11/12** (vendor untouched, shims minimal) | weeks | Android 11 is community-proven on PX6 (Hal9k/Malaysk); Android 12 needs KeyMint + legacy-lib shims |
| S3 | **Framework-only Android 13/14** (recommended) | weeks–months | modern patched Android (14 = LTS), same vendor/kernel, shims for legacy libs, KeyMint service, sepolicy rewrite |
| S4 | **Full rebuild: AOSP/LineageOS device + vendor with open-source HALs** | months | cleanest, but reimplements audio/gralloc/composer/camera → head-unit features at risk |

## Bottom line

Feasible: **S3 (Android 14, framework-only, vendor + kernel as shipped, legacy-lib wrappers)**.
Hard prerequisites: KeyMint service, vendor-local legacy lib copies, sepolicy rebuild, super-partition
re-layout, and a VINTF/kernel-config workaround (or a rebuilt kernel). Unknowns that need the real unit:
partition sizes, kernel config, MCU firmware version, whether `/proc/config.gz` exists, DTB, and the
feature checklist (CAN/radio/AMP/AV-in/GPS/BT/CarPlay).

## Risk assessment Nov 15 - kernel/vendor coupling (two-agent adversarial pass)

Two agents argued the two positions in turn (one at a time, read-only). Agent 1 defended "keep the kernel
this unit has actually executed (`4.19.111+ #190`) and shim Android 14 on top"; agent 2 defended the
current plan ("ship the vendor A11 kernel `4.19.193 #24` with the staged A11-era vendor and its modules").
Every claim below is either a repo artifact re-measured this session or marked inference. The measurement
that decided it is in `docs/findings.md` ("Which kernel Android 14's VINTF actually accepts").

**Verdict: keep the current kernel choice.** The A10 kernel is not the conservative option - it is the
option that fails a contract the payload itself declares. Our staged vendor says
`<kernel target-level="5"/>`, and against the Android 14 FCM-5 kernel requirement list (`kernel/configs`
`android14-release/r/android-4.19`, base+conditional) `#190` is **19 unmet** while `#24` is **2** (both
missing options that do not exist as symbols in that kernel). `#190` passes the FCM-4 list cleanly, so the
A10 route is viable only by downgrading the vendor manifest to `target-level="4"`, which reopens the HAL
generations the vendor strategy (**D15**/**D16**) is built around. On top of that, the shipped super's
`.ko` files are `vermagic=4.19.193`; the stock `4.19.111+` set is a different 19 files. Kernel, modules
and manifest move together - flashing `boot-a10k-a14rd.img` against our super would refuse WiFi, USB HID
and the iAP gadget at load time.

**What agent 1 got right, and we adopted:** the shipped kernels *do* embed their config (gzip-compressed,
so `strings` never saw it) - VINTF kernel-config matching works and no `libvintf` patch is needed
(`docs/feasibility.md` item 4 is corrected); the A10 vendor blobs are the only ones proven on this board
and MCU, so **D44** should lean A10 for the criteria-coupled HALs (audio input, HWComposer, sensors,
`mtc.mfi`); `goodix.ko` must not be insmod'd because `CONFIG_TOUCHSCREEN_GT9XX=y` is built in on both
kernels (now removed from `configs/hu_insmod.sh`); and `mali_kbase.ko` is dead weight, the GPU is
`CONFIG_MALI_MIDGARD=y` built-in - so the Mali module worry was never real.

**What agent 2 overstated:** its "0 unmet of 250 / 14 unmet" numbers did not reproduce; the real counts are
395 requirements with 2 and 19 unmet (base-only). Its "manifest proves the shape is coherent" argument holds,
but coherence is not bootability: the A11 kernel on an A10 uboot/trust/dtbo chain, and the keymaster-4 OP-TEE
TA pairing against the A10 `trust` (`7f2c4e52`), remain unmeasured.

**Where both agreed (real, shared risk):** neither kernel fixes the Nov 13 `gt9xx` panic (**D45** accepted);
`CONFIG_CGROUP_PIDS` is unset on both, so Android 14 task profiles degrade silently; the sensors-HAL crash-loop
is a defect of the *stock* firmware and its cause is still unknown; no one has booted Android 14 userspace on
either kernel; and Android 14's functional needs (binderfs, BPF JIT, fs-verity) are soft on this unit because
AVB is inert and `/dev/binder` still works - the hard gate is VINTF, not runtime.

**Experiments that would change the verdict, cheapest first:**
1. Offline, build host: re-stage vendor from `analysis/daisaita_a10/vendor.img` and run
   `tools/vendor_link_closure.py` + `tools/vendor_abi_check.py` + `check_vintf_compatible` with a
   `target-level="4"` manifest. If the A10 blobs need materially fewer shims than the A11 tree *and* the
   FCM-4 manifest resolves, D44 flips to A10 - and then the kernel question reopens with the stock module set.
2. Offline, workstation: byte-diff the 75 differing vendor paths against the criteria (audio input,
   HWComposer, sensors, `mtc.mfi`/CANBUS, WiFi userspace) to see how much of D44 actually touches the owner's
   checklist.
3. Unit, read-only, next reachable session: `ls -lZ /dev/ion /dev/binder* /dev/dma_heap`, `lsmod`,
   `/proc/bus/input/devices`, `logcat -d` around a sensors-HAL exit, `/sys/fs/pstore` listing.
4. Unit, one boot attempt, **card only - no eMMC write** (`docs/reanimation.md` bootSD route, stock backup +
   patched recovery as rollback): boot the card with `a14-boot-fixed.img` + our super and read
   `/dev/console` for init's fstab line, DTB source, dtbo application, panel timing, then `hu_insmod` lines.
   That is the only experiment that answers "does Android 14 survive on the vendor kernel" without touching
   the partitions. If it fails on `#24` cleanly and survives on `#190`, the whole kernel argument inverts.

**Bottom line for the plan as it stands:** ship `a14-boot-fixed.img` + the A14 super as a coherent pair, keep
the manifest at `target-level="5"`, prefer software KeyMint over the OP-TEE blob until the TA pairing is
measured, keep the `gt9xx` risk accepted (**D45**), and settle **D44** with the vendor-closure run rather
than with preference. The next thing that must happen is not a flash - it is the offline closure run and the
card-only console boot.

## Shape A adopted Nov 15 - what Android 14 needs from the Android 10 vendor (supersedes the bottom line above)

The owner chose the proven-kernel shape (**D46**) and added GPS as a hard criterion (**D49**), so shape A is
primary and shape B (`a14-boot-fixed.img`, A11 kernel, `target-level="5"`) is the documented fallback. The
contract check is in `docs/findings.md` ("Shape A checked against Android 14's actual code"). In short,
Android 14 accepts this vendor surface because FCM-4 is all-optional, the manifest carries no `<kernel>` tag,
and the framework still links the HIDL clients this vendor ships (audio@5.0, composer@2.1, mapper@2.1,
power@1.0, sensors@1.0, drm@1.0/1.2, usb@1.1, bluetooth@1.0, gatekeeper@1.0, **gnss@1.0**).

What must be added to the restaged Android 10 vendor, all of it in our own partitions:

| Android 14 needs | Route | Why |
|---|---|---|
| `libion.so`, `libaudioroute.so`, `libaudioutils.so`, `libspeexresampler.so` | inject both arches from `analysis/daisaita_a10/system.img` into `prebuilt_vendor_libs/<arch>/` (closure option F), or rebuild them from upstream source in the device tree | Android 14 does not build them; `librga.so` (composer/camera/OMX) needs `libion`, `audio.primary.rk30board.so` needs the audio trio |
| `libtinyalsa.so`, `libhardware_legacy.so`, `libexpat.so`, `libdrm.so`, `libui.so`, `libcutils.so`, `libutils.so`, `libhidlbase.so`, `libhidltransport.so` vendor variants | add the `<name>.vendor` modules to `PRODUCT_PACKAGES` via `vendor_modules_extra.mk` (closure option D) | they exist in Android 14 with `vendor_available: true`; only the request makes them land in `/vendor` |
| the OEM custom HAL interface lib `android.hardware.mtc.mfi@1.0.so` (+ impl) | staged as blobs | Android 14 never defines that interface; this is the CANBUS/MFi surface |
| GPS stack: `gnss@1.0-service`, `gnss@1.0-impl.so`, `gps.default.so` | staged as blobs, `gnss@1.0` kept in the manifest | Android 14's GNSS JNI walks HIDL down to `IGnss@1.0`; the AIDL example service is a fixture player and must not be shipped |
| KeyMint | build Android 14's software KeyMint service from AOSP source | the vendor has `keymaster@3.0` and the A10 `trust` (`7f2c4e52`) has no keymaster@4 TAs; software keys avoid the OP-TEE pairing question (**D46**) |
| WiFi stack | already in tree (**D21**): AIDL wifi service + AIDL supplicant/hostapd + `libwifi-hal-rtk`, with the 32-bit `libwifi-hal` patch | the vendor's `wifi@1.0-service` blob cannot serve Android 14's AIDL framework alone |
| vendor sepolicy | built from AOSP/Lineage policy in our build (stock `<sepolicy>` block dropped) | Android 14 ships compat maps for vendor policy 29.0-33.0 anyway; bring-up stays permissive (**D5**) |

Dead ends that do not cost the criteria: `radio@1.1` (Android 14's RIL only speaks `V1_4`+), `health@2.0`
(healthd links 2.1), `soundtrigger@2.0`, `cas@1.1`, `weaver@1.0`, `rockit.hw@1.0`, camera provider (not a
criterion). `CONFIG_CGROUP_PIDS` is unset on the OEM kernel, so Android 14 task profiles degrade silently -
accepted, same as shape B.

**Gate change:** the owner chose raw `dd` of `super` + `boot` once the offline gates pass (**D47**), instead
of a card-only console boot. That makes the offline gates the only safety net, so they must cover everything
this table lists: link closure + ABI check clean on the restaged A10 tree, VINTF compatible at level 4, module
vermagics matching the kernel (`4.19.111+` set), the four injected libs present in both arches, boot image
carrying the first-stage fstab, installer logic test, and the rollback verified (stock backup **D40**, rescue
card **D39**/**D42**). A kernel we build ourselves (**shape C**) is never written to `boot` without a card
boot first, because our own kernel has never executed on this board.
