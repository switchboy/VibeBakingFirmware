# Agent plan — PX6 firmware modernisation

Mission: ship a flashable firmware image for a PX6 (RK3399 / HCT4) head unit that runs a
modern Android build (current security patches) while keeping the head-unit-specific hardware
working. Owner accepts an old kernel if that is what the vendor blobs need, accepts wrappers where
Android 14 changed the interface, and accepts losing apps and settings - but the unit must never be
bricked, because there is exactly one unit.


Canonical detail lives elsewhere: decisions in `docs/decisions.md`, measurements in `docs/findings.md`,
operator procedure in `docs/flash.md`, build-host ops in `docs/build-host.md`, doc map in `docs/index.md`.
This file is the index plus the risk register, and it must not restate numbers - if this file and
`docs/findings.md` disagree, findings.md is right.

## Phases

| # | Phase | Exit criteria | Notes |
|---|---|---|---|
| P0 | Firmware inventory | ✅ done | Images reassembled (`tools/reassemble.py`), kernel/boot/HAL/props/driver inventory in `docs/firmware-analysis.md` |
| P1 | Device data collection from the real unit | **mostly done**: partition sizes, full kernel config, vendor HAL surface, control-plane props, SELinux behaviour, WiFi chip (see `docs/head-unit-findings.md`); still missing: MCU/MTCD firmware version, DTB dump, feature checklist, vendor blob hash comparison | done via Termux + `allinone.sh` over LAN, no adb needed |
| P2 | Version ceiling + HAL gap analysis | generated `system_matrix.xml` of the chosen Android base diffed against `vendor_manifest.xml`; gap list per HAL with strategy (keep / wrap / replace / software) | `tools/hal_gap.py` |
| P3 | Baseline boot test | chosen Android build boots on the unit as a **system-only** image (vendor untouched) — proof that framework-only upgrade works on this vendor/kernel | cheapest proof: flash new system/product/odm onto current firmware |
| P4 | Vendor shim layer | `libhardware_legacy`, hwc2 adapters, libchrome, ion/gralloc shims shipped in vendor; KeyMint service; SELinux labels for new services | `hal/` |
| P5 | Device tree + full build | AOSP/Lineage `device/` + `vendor/` tree builds a bootable `update.zip` | `device/`, `rom/` |
| P6 | Security harden | enforcing SELinux (no `androidboot.selinux=permissive`), no Magisk, no root init services, tight device-node permissions, signed payload, own OTA/offline update path | `rom/sepolicy`, `scripts/` |
| P7 | Head-unit feature parity | CAN/MCU, radio, AMP/EQ, AV-in, GPS, BT phone, CarPlay/AA verified; regression list vs current firmware | owner testing on the car |
| P8 | Packaging + docs | reproducible build, flashable zip + SD/USB image, recovery/rollback procedure, release notes | `scripts/`, `docs/` |

## Risk register

| Risk | Impact | Mitigation |
|---|---|---|
| MTC driver source unavailable → kernel frozen | kernel CVEs unpatched | keep kernel; mitigate by hardening userspace/SELinux, network-facing services disabled; later rebuild kernel from Rockchip BSP + vendor's driver source if obtainable |
| VNDK/legacy lib drift in Android 14 build | blobs fail to link | ship vendor-local copies of Android-10 era libs; test each HAL with VTS-ish smoke tests |
| Ion vs dmabuf allocator path | graphics breakage | keep HIDL allocator/mapper 2.0 + vendor `libion` shim talking to `/dev/ion` (kernel 4.19 has Rockchip ion) |
| Super partition too small for Android 14 | install fails | no longer a risk: Android 14 needs 2.18 GB of logical content and the group is 3.26 GB (1.07 GB spare). If it ever stops fitting, that is a fresh layout decision (**D19**), not a scripted GPT rewrite |
| HCT apps depend on framework internals | features break | keep app layer from current firmware initially; test early on real car |
| Bricking the unit | hardware loss | **only one unit**: backup GPT head/tail, p1-p13, boot/recovery and the current logical images before any flash; never flash without a verified restore path. Losing accounts/apps/settings is acceptable per the owner, so backup only needs to be firmware-level |
| Installed firmware is a Daisaita build, not the reference ROM | vendor assumptions could be wrong | measured Nov 13 (`tools/vendor_blob_check.py`): the live firmware's hashed surface is byte-for-byte the **Android 10** reference (126/126 identical), while our staged tree comes from the **Android 11** dump, which differs in 75 paths incl. audio/composer/sensors/gps/mtc/wifi. Re-staging from the A10 firmware revises D9/D15 - pending the owner's decision |
| No root on the unit | boot cmdline, lsmod, dmesg, `/init.hct.rc` unavailable | probe degraded fine (sysfs sizes + `/proc/config.gz` worked); **`/system/xbin/su` exists on this ROM** - the probe now calls it directly, so root may be available without Magisk |
| Wireless CarPlay/AA needs 5 GHz, unit's WiFi is a USB **Realtek RTL8188E** dongle (2.4 GHz hardware) | feature cannot be used wirelessly | hardware fix: swap that USB module for a dual-band RTL8821CU/8822BU - the shipped vendor already carries `8821cu.ko`/`8822bu.ko`, so no kernel rebuild; needs module loading in `init.connectivity.rc` and a correct `iw reg` country code. Wired CarPlay/AA unaffected |
| Payload signing / upgrade app rejects our zip | cannot install | resolved for the recovery path (**D25**): HCT's own cert is not ours, so the payload is flashed as raw images; the patched recovery (**D42**) removes the menu problem |
| An installer bug discovered only at the bench | the flash silently refuses, or a corrupt payload is written | the installer is logic-tested offline first (`scripts/smoke_recovery_installer.sh`); its payload sizes and digests come from the card manifest (**D43**), not from arithmetic the recovery busybox cannot do |
| Kernel / modules / manifest must move together | flashing the wrong boot image makes every `.ko` refuse at load time (WiFi, USB HID, iAP, virtual touchpad), or the vendor manifest rejects the kernel | measured Nov 15 (`docs/findings.md`, "Which kernel Android 14's VINTF actually accepts"): the payload declares `<kernel target-level="5"/>`; `4.19.193 #24` meets the FCM-5 list (2 unmet), `4.19.111+ #190` does not (19 unmet). Our super ships `vermagic=4.19.193` modules, so `boot-a10k-a14rd.img` + our super is not a legal pair. `docs/flash.md` and the staging scripts/comments said "A10 kernel" - corrected Nov 15 |
| Shape A's criteria depend on libraries Android 14 no longer builds | screen, audio input, CANBUS or GPS silently fail at HAL load time (`ldnvdl` in the log) with no visible cause | measured Nov 15 by `readelf -d` + `nm -D` on the reference blobs: `librga.so` → `libion.so`, `audio.primary.rk30board.so` → `libtinyalsa`/`libaudioutils`/`libaudioroute`/`libhardware_legacy`/`libspeexresampler`, `mtc.mfi@1.0-service` → `libhardware_legacy` + the OEM `android.hardware.mtc.mfi@1.0.so`. Android 14 ships vendor variants for tinyalsa/hardware_legacy/expat/drm/ui/hidltransport **and libaudioutils** (`system/media/audio_utils`, `vendor_available: true`); it builds **no** libion/audioroute/speexresampler, so those three are imported for both arches from `analysis/daisaita_a10/system.img` as vendor modules (`prebuilt_vendor_libs/Android.bp` + `vendor_libs.mk`) - modules, not staging-dir files, because shape A builds without `m dist`. The real symbol needs are `create_resampler`/`release_resampler`, the tinyalsa `pcm_*` set and `property_get`/`str_parms_*`; GPS stays working because Android 14's GNSS JNI still fetches HIDL `IGnss@1.0` |
| Kernel/modules/manifest coupling is now a checked gate, not a rule of thumb | a payload that pairs the wrong kernel with the wrong module set boots to a black screen or loses WiFi/HID/iAP | `tools/payload_coupling_check.py` reads boot.img's page-aligned layout, the kernel banner, the first-stage fstab, the DTB inside `second`, `/lib/modules` vermagics, the injected libraries for both arches, the GPS HAL files and the manifest's target-level. Measured Nov 15: shape A (A10 vendor + `boot-a10k-a14rd.img`) and shape B (A11 vendor + `a14-boot-fixed.img`) both PASS; the stale `455a9ac8…` image FAILS on two counts. Stock vendor partitions carry older-kernel leftovers (`4.4.167` GPU `.ko`, some `4.19.101+`), so the rule is per-module: the 14 modules `hu_insmod.sh` loads must match the kernel, and they do in both shapes |
| Vendor `gt9xx` driver leaves `input_dev->phys` pointing at a dead stack frame | fatal kernel panic whenever an input device is re-opened after that page is unmapped (observed Nov 13 20:03, on a framework restart) | **Accepted as-is (D45, Nov 15)** - the OEM kernel stays unpatched: the driver is built into the kernel and the vendor kernel source is not in hand, so the 1-line literal fix would need a rebuild that cuts against **D9**. Touch/buttons/CANBUS work in a normal boot, so the criteria survive; it only fires on a framework restart. Reopens if restarts prove routine - then rebuild from vendor source, or remove the trigger. Bug report drafted in `docs/upstream.md`, not posted |

## D-status (one line each; reasoning in `docs/decisions.md`)

| ID | Status | One line |
|---|---|---|
| D1-D7 | decided | Android 14 / LineageOS 21 / keep shipped 4.19 kernel / blobs untouched + wrappers / permissive during bring-up / keep HCT apps in the first flash / keep the update.zip-on-USB transport |
| D8 | superseded by D19 | no layout change; the 8 GiB proposal is recorded in `docs/decisions.md` only |
| D9-D12 | decided | Android 11 vendor tree as base; `/data` wiped on flash; flash current layout first; keep the built-in RTL8188E (2.4 GHz only) |
| D13-D14 | decided | staging-first vendor build; no reachable loader/Boot-ADB, fastboot unused |
| D15-D16 | decided | vendor built from staged Android 11 blobs; dropped HAL services come back as Android 14 modules |
| D18-D19 | decided | stock-package transport (now superseded by D25 for the transport itself); never resize, never write the GPT |
| D20-D23 | decided | vendor libs via Android 14's own `<name>.vendor` modules; WiFi HAL rebuilt in-tree (`libwifi-hal-rtk`); libdrm patched to export `drmModeAddFB2_ext`; `usb_dongle` rebuilt from published source, `libomxvpu` stays a declared gap |
| D24 | implemented | HCT app layer staged from the reference payload, re-signed with our platform key |
| D25 | decided | recovery cannot install our package (trusted cert `cf2ab3…` is HCT's own); route 1 = testkey-signed zip attempt, route 2 = raw image |
| D28-D31 | decided / implemented | bring-up access through the factory-settings password `adbon`; the Nov 9 write is recorded; rollback is blind and the stock rescue payload is rebuilt from the OEM package |
| D32-D37 | decided | measured defect list (Mali vermagic is cleanup, DTB panel-table trimming is a vendor A10->A11 delta); our boot image is the vendor **A11** kernel+DTB on an **A10** chain; our payload had **no first-stage fstab** - fixed images built (`a14-fixed.img`, `boot-a10k-a14rd.img`), neither flashed; the bench procedure and debug access are measured; the rescue card is a sector mirror with a card-local GPT |
| D38-D41 | decided | the unit's own board DTB lives in `boot`'s second stage, so flashing the OEM `boot.img` restores the display description without touching the chain; recovery is reachable through the owner's bootSD card; a byte-exact stock backup is taken before any further write; the recovery fallback zip carries no payload and dd's the images straight off the card |
| D42-D43 | decided, then fixed Nov 13 | partition 8 is patched so recovery becomes the tool (it is not boot chain and AVB carries no descriptors); the card-driven installer runs only out of the ramdisk and reads payload size + digests from the card manifest. Nov 13's offline logic test found two bugs: a size check that divided by 1000 instead of 1024 and refused every write, and a digest check that matched manifest spellings no applet matched, so it verified nothing while reporting success |
| D44 | open, Nov 14 - owner decision | vendor staging source: the firmware the unit runs today is byte-for-byte the **Android 10** reference (126/126 identical), while `vendor/hct4/tree/vendor` is staged from the **Android 11** dump (75 hashed paths differ, incl. audio/composer/sensors/gps/mtc/wifi). Re-staging from A10 revises D9/D15 |
| D45 | decided Nov 15 (owner) | the Nov 13 kernel panic is **inherited, not fixed**: OEM kernel stays as shipped (the 1-line vendor `gt9xx` fix needs a kernel rebuild and the vendor kernel source is not in hand); upstream candidates 21/22 stay draft-only and are not posted; `iw reg` country stays `00` |
| Bluetooth | pending | second pass after first boot: Lineage's `packages/services/Bluetooth` + HAL transport |

## Current state (Nov 13/14)

1. **The unit runs stock Android 10 again and is backed up byte-for-byte (D39/D40).** The bootSD card
   reaches a real recovery environment, `diatsia fw/update(1).zip` restores the unit's own firmware, and
   the working stock eMMC was pulled partition-by-partition into `a14-work/hu-stock-backup/` with a
   verified `MANIFEST.sha256` before anything else is written. That backup - not the factory card - is the
   rollback for the next Android 14 attempt, which writes only `boot` + `super` (**D18**/**D19**).
2. **Recovery became the tool instead of a menu nobody can drive (D42/D43).** Partition 8 is not part of
   the boot chain and `vbmeta` carries zero descriptors, so a patched recovery cannot be rejected by AVB.
   `scripts/patch_recovery_autorun.sh` splices the card-driven installer, the stock Android 10 `make_f2fs`
   and an appended `init.recovery.rk30board.rc` into the stock ramdisk; the installer runs when a card
   carries `hu-install.flag` and is inert without it. uboot/trust/dtb/dtbo/vbmeta/security/GPT stay
   untouched.
3. **The installer was logic-tested offline today and two bugs were fixed** (`docs/findings.md`,
   "The recovery installer logic-tested offline"). Its payload-size math divided by 1000 where it meant
   1024, so it refused every write before touching anything; its digest check compared manifest spellings
   (`sha1`) against the applet name it probed (`sha1sum`), so zero files were ever verified while the
   script still reported success. Payload sizes now come from the card as `size <bytes> <blocks> <name>`
   lines written by `scripts/stage_hu_card.sh`, digest lines are named exactly as busybox applets, and
   `scripts/smoke_recovery_installer.sh` asserts eight scenarios against a fake card and fake partitions.
   **Consequence: the recorded patched recovery image still holds the old script, so
   `scripts/patch_recovery_autorun.sh` has to run again and `analysis/recovery-patched.txt` has to be
   rewritten before partition 8 is flashed.**
4. **The Nov 13 probe answers the blob question and opens D44.** The unit is powered, root works through
   `su` (uid 0, context `u:r:su:s0`), and the firmware it runs is the April 2025 OEM rebuild. Its hashed
   vendor/system/product/odm surface is **126/126 identical** to the Android 10 reference, while the tree
   our payload stages comes from the Android 11 dump and differs from the live unit in **75** paths
   (audio/composer/sensors/gps/power/vibrator/mtc/bluetooth/wifi/rild/hostapd and the vendor manifest).
   Re-staging from the A10 firmware revises **D9**/**D15**, so it is the owner's decision (**D44**), not a
   change to make silently.
5. **Two things need the build host, and the build host is currently unreachable.** The patched recovery has
   to be rebuilt, and the vendor slice may have to be re-staged - both run on the NAS (`
   `scripts/patch_recovery_autorun.sh`, `scripts/prebuilt_vendor.sh`, a packaging pass, the `dash -n` /
   `busybox ash -n` checks). The access wrapper lives outside the repo (`/tmp/opencode/omv.sh` reading
   `/tmp/opencode/build_host.env`) and was restored Nov 15, so the NAS is reachable again; `SSData` is nearly
   full (9.5 GB free after moving the Nov 8 pass to cold storage), which is why the shape-A build skips
   `m dist` and logs go to the NAS's `/tmp`. Nothing was flashed.
6. **The route once those are done:** flash the rebuilt patched recovery over TCP adb (**D28**), stage the
   roomy card with `scripts/stage_hu_card.sh`, then - per **D47** - write `super` + `boot` with raw `dd` once the
   offline gates pass, and check the owner criteria: boot, WiFi, screen, sound input (touch, physical buttons,
   CANBUS) and **GPS** (**D49**). The rescue card stays staged because it is the recovery route, not a test:
   watch `/dev/console` for the `hu-install:` banner (that line is the proof partition 8 is ours), read
   `/tmp/hu-install.log`, deep power-cycle afterwards. Partition 8 alone rolls back by dd'ing
   `hu-stock-backup/recovery.bin` `1fdf5ea77fc6…` back; the whole firmware rolls back with the stock backup or
   the OEM zip.
7. **Still open before Android 14 can be believed:** whether Android 14 userspace survives on the OEM A10 kernel
   (never booted yet), the two Android 10 kernel defects we accept (**D45**), and a serial console reading
   (`console=ttyFIQ0`, 115200 8N1, 3.3 V) which `docs/reanimation.md` drives from the bench. The old composer
   worry is settled: Android 14 keeps HIDL `composer@2.1`/`mapper@2.1` clients (`libui/Gralloc2.cpp` uses
   `mapper::V2_1::IMapper`), so no AIDL composer wrapper is needed - what shape A needs instead is the four
   injected libraries and the vendor variants listed in `docs/feasibility.md`.
8. **The Nov 13 20:03 kernel panic is root-caused, offline, from the RAMoops record.**
   `analysis/panic-20261113-2003-ramoops.txt` shows a fatal `strlen()` inside `evdev_ioctl_handler` from
   the `InputReader` thread (`pc __pi_strlen+0x60`, fault address 4.7 MB past the kernel image, `pte=0`).
   Cause: the vendor `drivers/input/touchscreen/gt9xx/gt9xx.c` keeps `input_dev->phys` in a **stack array**
   (`s8 phys[32]`), so the pointer dies with the probe function; it is present in
   `develop-4.4`/`4.19`/`6.1`/`master`, and the driver is built into the kernel, so no module swap fixes it.
   It only fires when an input device is *re-opened*: the framework restarted that boot (system_server died,
   zygote killed), the new EventHub asked for `EVIOCGPHYS`, and by then the stack page was unmapped.
   Touch works fine after a reboot, which is why earlier sessions never saw it. The kernel-side taint came
   from the Rockchip `rtl8188eu` fork's `rtw_warn_on(1)`. Full write-up: `docs/findings.md`; live-unit
   facts: `docs/head-unit-findings.md`.
9. **Unit offline again (`192.168.1.120` unreachable), and the owner answered Nov 15: nothing posted, risk accepted.**
   `docs/upstream.md` carries candidates 21 (gt9xx dangling `phys`, home = `rockchip-linux/kernel` GitHub
   issue) and 22 (the fork's power-save `warn_on`) with issue text written and scrubbed of OEM identity -
   kept **draft-only**, not posted (**D45**), and still nothing anywhere has been submitted. The panic route
   chosen is **accept the inherited risk**: OEM kernel unpatched, because the fix needs a kernel rebuild and
   the vendor kernel source is not in hand. `iw reg` country stays `00`. The measurement that keeps D45
   tolerable is still owed on the next reachable session: `logcat -d` around a `vendor.sensors-hal-1-0`
   exit, to see what kills the framework (the crash-loop is what re-opens the input devices).
10. **Nov 15 kernel/vendor coupling assessment: the current plan stands, and one trap is fixed.** Two agents
    argued both sides in turn (`docs/feasibility.md`, "Risk assessment Nov 15"); the deciding measurement is
    in `docs/findings.md`: the payload declares `<kernel target-level="5"/>`, `4.19.193 #24` meets the
    Android 14 FCM-5 kernel list (2 unmet) and `4.19.111+ #190` fails it (19 unmet), and our super's modules
    are `vermagic=4.19.193` - so kernel, modules and manifest must move together, and
    `boot-a10k-a14rd.img` + our super is not a legal pair. `docs/flash.md` and four staging comments said
    "A10 kernel" for an image carrying the A11 kernel; corrected, and `goodix.ko` was dropped from
    `configs/hu_insmod.sh` (GT9XX is built in on both kernels). Adopted from agent 1: the vendor kernels do
    embed their config (gzip), so no `libvintf` patch is needed, and **D44** should lean Android 10 for the
    criteria-coupled HALs. Next real step is not a flash: the offline vendor-closure run on the build host,
    then a **card-only** console boot of `a14-boot-fixed.img` + our super (`docs/reanimation.md`), with the
    stock backup and patched recovery as the rollback.
11. Owner's success criteria: **not brick**, **boot**, **WIFI**, **screen**, **sound input**
    (touch + physical buttons + CANBUS), and **GPS added Nov 15** (**D49**). Bluetooth is a deliberate second
    pass (`docs/decisions.md`). One agent at a time.
12. **Nov 15 owner answers: shape A is primary and M11 is started.** `docs/plan.md` M11 now records the
    answers: vendor staging flips to the Android 10 reference (**D44**), manifest stays `target-level="4"` with
    **no `<kernel>` tag** (libvintf only checks kernel compatibility when the manifest declares one), KeyMint is
    Android 14's software service, kernel build = public BSP `develop-4.19` now with vendor GPL source pursued
    alongside (**D48**), and the validation gate is **raw `dd` once the offline gates pass** (**D47**) rather
    than a card boot - which makes the offline gate set the only safety net, so closure/ABI/VINTF/vermagic/fstab
    checks must all pass before the first eMMC write, with the rescue card and stock backup staged. GPS is
    satisfied by keeping the OEM GNSS blobs (Android 14's GNSS JNI fetches `IGnss@1.0`), not by Android 14's AIDL
    example service. Three libraries Android 14 does not build are imported for both arches from the Android 10
    reference as vendor modules - `libion`, `libaudioroute`, `libspeexresampler` (`prebuilt_vendor_libs/Android.bp`
    + `vendor_libs.mk`) - and `libaudioutils` is Android 14's own vendor variant, a correction to the earlier
    "four libraries are missing" claim. The NAS credential
    wrappers are restored and the host is reachable, but `SSData` is nearly full (9.5 GB free after moving the Nov
    8 pass to cold storage), so the shape-A build skips `m dist` and logs go to the NAS's `/tmp`.
