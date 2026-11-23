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
| Our packing step edits the boot header in ways the OEM image does not | a payload that dies before init starts any service, with no console output to explain it | measured Nov 18 (`docs/findings.md`): `scripts/rebuild_boot_with_fstab.sh` zeroes the OEM `dtb_load_address` and truncates the image, so the image carries only the small DTB variant inside `second` while partition 7 normally also holds the tail DTB variant that carries the `mmc0`/`mmc1`/`mmc2` aliases. **D60** keeps the header byte-verbatim except `ramdisk_size`, the content hash and our own cmdline tokens, and keeps the tail region inside the image |
| A diagnostic harness that runs init against the live kernel | framework restarts and kernel reboots on the one unit we have | **D59**: frozen. Mount/PID namespaces do not isolate device-mapper, block devices, binder, GPU, panel, sysctls or power state, `toybox unshare` does not fork so init is never PID 1 of its namespace, and the host already owns the logical dm names, so the harness cannot produce a clean result anyway. Any future live harness needs **D64**'s guard set |

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
| D46-D52 | decided Nov 15-17 | offline gate set becomes the safety net (D47); kernel build route = public BSP with vendor GPL pursued alongside (D48); shape A primary, shape B fallback (D52/D54/D55); shape A's criterion chain passes the coupling gate (D55) |
| D53-D57 | decided Nov 16-17 | kernel rebuild stays blocked on vendor GPL source (D53); shape B stays parked pending an owner review (D54); the gate list shape B needs is its own (D55); shape A's boot image keeps the OEM kernel (D56, now corrected in `docs/findings.md`: `libhwbinder.so` is present); partition 7's rollback image is the refreshed capture (D57) |
| D58 | decided Nov 17 (owner) | first-boot criteria shrink to boot + WiFi + screen; GPS and sound input become post-boot work |
| D59-D64 | decided Nov 18 | the namespace harness is frozen and cannot answer the logical-mount question (D59); the OEM boot header stays byte-verbatim except `ramdisk_size`, the content hash and our cmdline tokens, and the image keeps the tail DTB region (D60); the payload's vendor is our own rebuild with OEM blobs carried in, and D56's missing-library claim is corrected (D61); the next writes are boot-only, one variable at a time, `super` untouched (D62); UART needs the owner's consent before anything is opened (D63); a live harness may only run with the full guard set, designed not improvised (D64) |
| D65-D68 | D65/D66/D68 decided Nov 18-19 from measurement, D67 written Nov 19 | pstore console is the instrument and the two alternative channels are closed by kernel config (`# CONFIG_VT`, `# CONFIG_USER_NS`) (D65); partition 7 held payload padding mid-partition after the Nov 18 restore, so a rollback write must cover all 33,554,432 B - L0 did that on Nov 19 and the partition is now byte-equal to the capture (D66 amendment); an identity round-trip gate must pass before any image is proposed for writing, and `tools/identity_gate.py` passes offline and now holds live too (D67); the OEM partition tail - splash data plus a SHA1-verified Rockchip resource image with the DTB variant and the logo - is carried verbatim instead of zero-filled (D68) |
| D69-D71 | D69/D70 executed Nov 19 (owner's go), D71 answered Nov 19 (owner) | P0 proved the pstore console on the unit: the console and pmsg records survive a warm reset and the console record is whole-boot text including PID-1's messages, so a failed boot can be read (**D69**); L0's byte-identical repack was written as the whole partition and stock Android 10 booted from it with WiFi up and a rendering panel, so our packing pipeline is trusted by the unit (**D70**); the owner permitted `misc` for a Boot Control Block write as a recovery hand-off, while every other boot-chain partition stays forbidden (**D71**) |
| D72-D73 | decided Nov 19 from the ladder rungs | `printk.devkmsg=on` unblocks init's log lines (65 -> 819 console `init:` lines) and must be kept, and its console volume means records must be read immediately (**D72**); the validated logging set is devkmsg=on + loglevel=8 + panic=12, combined for L2 and payload boots, while `androidboot.init_fatal_reboot_target=bootloader` stays out because it removes the adb route (**D73**) |
| D74-D75 | decided Nov 19 after L2 left the unit silent | u-boot honours a recovery hand-off (`reboot-recovery`, `b.mode=recovery`) but the recovery ramdisk's `adbd` is USB-gadget-only and wireless adb needs `persist.internet_adb_enable` in `/data` recovery does not mount, so recovery is a landing zone for a human, not a rescue route for our transport (**D74**); after L2 an image may be written only if a boot running it can still answer over TCP adb long enough to read `/sys/fs/pstore/*`, and writes stop until the owner restores the unit (**D75**) |
| D76-D77 | decided Nov 20 from the restore | partition 7 now holds the OEM package image `b449aee98c01…`, so `a14-work/hu-stock-postflash-143452/boot.bin` is the rollback image (**D76**); a pstore console record carries the *previous* boot's text, so a failed boot's log survives only into the boot immediately after it and a rescue through recovery or another flash forfeits it (**D77**) |
| D78-D79 | decided Nov 20 | TCP adb while Android 10 runs is the only route we can reach, so only images already proven to boot may be written (**D78**); recovery starts `console /system/bin/sh` because ro.debuggable=1, which would make the UART an interactive shell able to read a failed boot's pstore record - the probe is still declined (**D79**) |
| D80 | decided Nov 20 by the owner | `recovery` (p8) writable while MTC/mainboard flashing stays intact; a patched partition 8 becomes the route that reads a dead boot's pstore record and restores partition 7, lifting D78's constraint (**D80**) |
| D81 | decided Nov 20 evening | the recovery evidence script may only use what the ramdisk holds (busybox has no `dd`/`wc`/`cp`/`rm`/`ls`/`tr`/`sha256sum`; `/system/bin` does, with `linker64`), mounts `/cache` before creating its directory, retires a restore request by a nonce-named done-marker, treats an unreadable digest as "write the rollback anyway", and reboots only when it did something because reboot-mode can land back in the menu |
| D82 | decided Nov 21 | partition 8 self-heals: `/system/bin/install-recovery.sh` (init `flash_recovery`) rewrites it from `/system/recovery-from-boot.p` on every Android 10 boot while partition 7 hashes `ecb5315f…`, so a patched recovery is transient on stock firmware and persists only with a payload whose digest differs; the script's dialect gate is the ramdisk's own mksh R40 (`hush -n` on the unit), not dash/busybox ash; digest reads are capped at 64 MiB because hashing the whole 96 MiB partition never returns |
| D83 | decided Nov 20 evening by the owner, recorded Nov 21 | all recovery restrictions released (**D80**'s condition superseded); recovery and `boot`/`super` are never altered in the same flash; "dig in to recovery, make it our own" is an open goal - reverse-engineering the stock recovery binary read-only, and until that lands "ours" stays the verified ramdisk splice |
| Bluetooth | pending | second pass after first boot: Lineage's `packages/services/Bluetooth` + HAL transport |

## Current state (items 1-24 through Nov 20 late afternoon; items 26-28 are Nov 21; item 25 is Nov 20 evening)

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
5. **What still needs the build host, and the build host is currently unreachable.** The vendor slice may have to
   be re-staged (**D44**), which runs on the NAS (`
   `scripts/prebuilt_vendor.sh`, a packaging pass). The patched recovery no longer needs it: the rebuild runs on
   the workstation and its dialect gate is the recovery ramdisk's own mksh, syntax-checked on the unit (**D82**),
   so `dash -n`/`busybox ash -n` are not applicable. The access wrapper lives outside the repo (`/tmp/opencode/omv.sh` reading
   `/tmp/opencode/build_host.env`) and is missing again - `/tmp` was cleared, so the NAS cannot be reached until
   the owner re-supplies the credential; `SSData` is nearly
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
11. Owner's success criteria, revised Nov 17 (**D58**): the write is gated on **not brick**, **boot**,
    **WiFi**, **screen**. Sound input (touch + physical buttons + CANBUS) is verified after the
    environment is up and adb is reachable, and **GPS is post-boot work, not a flash criterion** - the
    OEM GNSS blobs stay staged and declared (**D49**'s route), but no satellite fix gates the write.
    Bluetooth remains a deliberate second pass (`docs/decisions.md`). One agent at a time.
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


13. **Nov 16/17: the payload is staged and gated, and Nov 17's live session is recorded.** Shape A's
    `super.img` (2,400,917,568 B, sha `bb79874c…`), `vendor.img` (556,072,960 B, `7a5ce939…`),
    `boot.img` (28,012,544 B, `9605fb9f…`) and the flashable container `raw-super.img`
    (3,263,168,512 B, `d81f913a…`) plus `boot-a10k-a14rd.img` (`3cf40129…`) pass the whole offline
    gate set - closure 109 modules / 0 not installed, ABI, VINTF dropped-check (LOST empty), super byte
    verification `ALL LOGICAL PARTITIONS VERIFIED: True`, installer smoke 8/8 in both shapes, card-staging
    dry run rc=0 - and the coupling gate now demands the criterion chain itself (GPS, CANBUS, audio, the
    whole graphics chain, OMX, health, the protobuf/soft-OMX sonames) and **PASSes** on shape A. Shape B's
    Nov 11 container (sha `d4b49909…`) **FAILs** it on the two sonames D52 added, so
    it stays parked until a `SHAPE=a11` packaging pass (**D53**/**D54**/**D55** are engineering-declared,
    pending owner review). Nothing has been flashed (**D30**).
14. **Nov 17 live facts (read-only, no writes).** TCP adb is now permanent via
    `persist.internet_adb_enable` + `init.rk30board.rc:250-257`, proven by a reboot with no RSA dialog; a
    clean RAMoops record shows the `#190` banner and zero `gt9xx`/panic markers, so **D45**'s restart
    trigger has not recurred; `/dev/ion` exists while `/dev/dma_heap` does not and the running config has
    no `DMA_HEAP` at all - shape A's ION graphics chain is the only route this kernel can serve; the
    CANBUS `mtc.mfi` service is alive on stock; GPS reports **zero fixes** because the antenna is
    unplugged (owner confirmed), though UART0 still receives 55,755 bytes, so the module is powered and
    streaming - **D49 stays unverifiable until the antenna is fitted**; wireless Android Auto takes the
    single 2.4 GHz radio, so the LAN adb route drops while AA runs; the sensors HAL loops on a missing
    `/dev/mma8452_daemon`. All recorded in `docs/head-unit-findings.md` + `docs/findings.md`.
15. **Next moves.** The write itself is the next decision: route 2 (`install_a14_from_adb_root.sh` raw
    `dd` of `super` + `boot` over TCP adb) is ready - shape A's gate set is green, the refreshed stock
    capture is the rollback (`boot.bin` `4121b58f7759…`, **D57**), and the criterion chain for the first
    boot (**D58**) is graphics + WiFi, both measured offline. GPS/sound/CANBUS verification happens
    after boot. Shape B's rebuilt fallback passes its whole gate too (`a14-fixed.img` `55be70ab423c…`),
    so a fallback exists if shape A's screen or WiFi fails. Real card staging waits for a mounted card;
    shape C waits for the vendor GPL source (**D48**).
    arrives (**D48**); GPS criterion measurement after the antenna is fitted (**D49**).

16. **Nov 18: two writes happened, both failed, and the picture changed.** Route 2 ran twice over TCP adb
    and wrote only `super` + `boot`: the diagnostic pair produced a logo-only boot loop with an SD logger that
    wrote nothing, the minimal pair produced a black screen. Both payloads died **before init started a
    service**, and the two boot images differ by 9 header bytes (`" panic=12"`), so they are one failure seen
    through two reboot paths. Four things were corrected by offline re-measurement: the logo is drawn by
    u-boot/trust, so "reached SurfaceFlinger" was never true; the earlier `second_size` reading was a field
    mislabel; the earlier "no DTB in the images" came from a wrong DTB magic, and the payload's DTB is in fact
    byte-identical to the stock one; and the payload's vendor is our own rebuild, which also corrects **D56**'s
    missing-`libhwbinder.so` claim. Two defects of ours surfaced: our packing zeroes the OEM `dtb_load_address`
    and truncates the image so the tail DTB variant (the one with the mmc aliases) is absent from the image
    itself (**D60**). The namespace harness is frozen (**D59**) - it cannot answer the logical-mount question
    and it restarted the framework and rebooted the kernel. The route is now: finish offline analysis, rebuild
    a byte-faithful boot image, run the boot-only ladder (**D62**), and get UART (**D63**), which needs the
    owner's consent to open the unit. The unit is unreachable again (`192.168.1.120` does not answer), so the
    live checks that were queued - partition 7's tail sha, `/proc/device-tree/aliases`, a warm-reboot RAMoops
    test - are owed on the next reachable session. Nothing beyond `boot` + `super` was ever written (**D30**),
    and `/data` was never formatted.

17. **Nov 18 late session: the unit came back, partition 7's real state is measured, and three claims were
    corrected.** The unreachable-unit blocker was the workstation's own `adb` daemon, not the unit: restart the
    daemon and `adb connect 192.168.1.120:5555` gives root adb on the stock April 2025 Android 10. Read-only
    measurements: partition 7 hashes `0bd1cc806740…`, which is **not** the rollback capture `4121b58f7759…`,
    because the restore wrote only 27,406,336 B and left the payload's padding at 27,406,336..28,233,728, with
    untouched stock (both tail DTBs) beyond 28,233,728 (**D66**). Nine boot-chain partitions hash exactly as
    captured, so **D30** is now digest-verified and the patched recovery is not on the disk - the unit is state
    S0, not S2. Super's logical bytes are stock again; only the two metadata slots differ from the capture, by
    148 bytes. The live device tree has no mmc aliases, which lowers the DTB-variant suspect to ~10%: the small
    variant inside `second` is what the board actually uses, and our payload carries it byte-identically. Two of
    our own probes were wrong and are fixed: the "tail DTB is gone" reading came from `toybox dd`'s block-based
    `skip` (32,093,696/512 = 62,683, not 62,879), and the "RAMoops not registered" row was wrong - `dmesg` shows
    `ramoops: attached 0xf0000@0x110000` with `console [pstore-1] enabled`, so pstore console works (**D65**),
    while `# CONFIG_VT is not set` rules out screen console and `# CONFIG_USER_NS is not set` rules out any
    namespace route permanently. The owner also forwarded a "blind plan" (no UART, no USB debugging); its
    corrections are recorded in `docs/blind-plan-corrections.md`, and its questions are batched in
    `docs/head-unit-findings.md` items 8-12. `scripts/repo_update.sh` is fixed: its rsync targets lacked the
    `$HOST:` prefix, so the NAS mirror silently did nothing while the ssh-side checks still looked correct.
    Nothing was written, and the unit was not rebooted.
18. **Nov 19 (offline, no unit writes).** The identity gate **D67** is written - `tools/identity_gate.py` - and
    its first run failed check 1, which is exactly the defect class it was built for: `rebuild_boot_faithful.py`
    zero-filled the OEM partition's tail instead of carrying it, so feeding stock content through our own
    tooling did not reproduce the capture. Decoding that tail settled what is in it (**D68**): from 27,407,104
    there is 4,685,056 B of splash data, then a Rockchip resource image at 32,092,160 whose entries
    (`rk-kernel.dtb` 157,962 B, `logo.bmp` 384,572 B) carry 20-byte SHA1s that all verify, plus an unlisted
    second copy of the same DTB at 32,636,928; `second` is itself such a resource image with `rk-kernel.dtb`
    (152,425 B) and two identical logo bitmaps (384,788 B). The OEM recovery image carries the same three
    entries and hashes, so the format is the OEM convention. The live kernel's `/reserved-memory/drm-logo` reg
    is filled by u-boot (base `0xf5f00000`, size 1,148,928), which means the logo the boot path uses comes from
    `second` - the part our payload already carries verbatim - not from the tail. The tool now carries the tail
    byte-for-byte from its own content end, refuses if components reach the resource header, and re-verifies the
    carried entries; the corrected image is `e504655bd32c…` and the Nov 18 one (`807340652712…`) is superseded.
    The gate then passes all three checks: stock content round-trips to `4121b58f7759…` byte-for-byte; the
    payload image changes only `ramdisk_size`, the cmdline field, the ramdisk span and the padding span, keeps
    the kernel and `second` identical, and keeps the tail identical from 28,233,728 B; `super` metadata differs
    only in group name, attributes, the added `system_ext` and extents, with device size and first sector
    unchanged (**D18**). The diag variant passes the same gate (`9ed667e99c39…`, differing from the min variant
    by the 9-byte ` panic=12` cmdline tail). Step **P0** - `scripts/pstore_probe.sh`, gated on `HU_CONSENT=1`,
    dry-run tested Nov 19 - runs before the first flash, because it decides whether a failed boot can be read
    at all. Nothing was flashed; the ladder still awaits the owner (**D62**).
19. **Nov 19 (daytime): the ladder images are staged and one token proved fake.** `scripts/stage_ladder.sh`
    builds L0 (the capture repacked with no content change - byte-identical, so flashing it also clears
    partition 7's payload remnants, **D66**) and four L1 images, one cmdline token each, refusing to run if the
    capture digest is not `4121b58f7759…` and refusing any output whose bytes differ outside the header's
    512-byte cmdline field; the tail resource header and the three DTB copies must stay where they are. Both
    ramdisks were extracted and their `/init` checked by `strings`: `androidboot.init_fatal_panic` is **not** a
    token either init reads, so that rung was dropped and replaced by the verified
    `androidboot.init_fatal_reboot_target=bootloader` (the `recovery` value is avoided because it writes `misc`,
    **D30**). The extraction also showed stock Android 10 init already runs a first-stage logical-mount chain
    (`wait,logical,first_stage_mount`), so the dm-name clash that froze the harness (**D59**) is payload-side
    only. Digests: `docs/findings.md`, "Nov 19 (daytime)"; manifest `a14-work/ladder/MANIFEST.sha256`. Nothing is
    flashed; approvals are questions 8, 12 and 13 in `docs/head-unit-findings.md`.
20. **Nov 19 (evening): P0 and L0 ran on the unit with the owner's go, and stock Android 10 boots from our
    repack.** The owner approved "P0 then L0", declined UART ("Not yet", so **D63** stays parked), and permitted
    `misc` for a Boot Control Block write (**D71** - it still hashes `909bdd979111…`, untouched). **P0**
    (`HU_CONSENT=1 sh scripts/pstore_probe.sh`, one warm reboot, no write) proved the instrument: after the reset
    `/sys/fs/pstore` held `console-ramoops-0` 97,430 B (`88e35fe7aa66…`) and `pmsg-ramoops-0` 262,132 B
    (`2f4f26ae99db…`), no `dmesg-ramoops-0`, and the console record is plain uncompressed text covering the whole
    boot we left - 1,479 lines from `Booting Linux…` to `reboot: Restarting system with command 'adb'`, PID-1's
    own messages included (`init first stage started!`, the logical-partition creation lines, `init second stage
    started!`), which is the log a dying Android 14 init would be diagnosed from (**D69**). The record also
    printed the u-boot-assembled cmdline, 670 B: our header's 334-byte field sits inside it verbatim, with
    firmware tokens before (`storagemedia`, `androidboot.mode`, `dtbo_idx`, `serialno`, `board.sel`…) and after
    (`earlycon`, `swiotlb`, `coherent_pool`, `androidboot.boot_devices=fe330000.sdhci`), so the payload does not
    need to add `boot_devices` itself. **L0** pushed `L0-stock.img`, verified its digest on the device against
    `a14-work/ladder/MANIFEST.sha256`, then `dd bs=1M count=32 conv=fsync` wrote all 33,554,432 B: partition 7
    went `0bd1cc806740…` -> `4121b58f7759…`, clearing **D66**'s payload remnants. After reboot:
    `sys.boot_completed=1`, the OEM fingerprint unchanged, `wlan0` `up`, adb reachable, partition 7 still the
    capture, and `screencap` proves a rendering panel (`screencap-l0.png`, `fa5d5f66f9d3…`, 1024x600, 1,346
    distinct sampled colours) - the owner's criteria (**D58**) met (**D70**). Traps hit and recorded: `adb reboot`
    drops adbd root (partition read then yields `Permission denied` and an empty `dd` whose hash is the
    empty-input digest `e3b0c44298fc…`), `toybox getprop` does not exist, and stripping CR from a raw PNG corrupts
    it (`0x0D` is legal inside IDAT) - screenshots must go through `toybox base64`. Next: the four L1 rungs one at
    a time, each needing its own go, reading the pstore console before anything consumes it; then **L2**.
21. **Nov 19 (night): the whole boot-only ladder ran, and the unit is back on the stock capture.** Baseline first
    (one warm reboot, record pulled), then L1 rung 1 `printk.devkmsg=on` (`3a70fbf94444…`), rung 2 `panic=12`
    (`95e99c2188f8…`), rung 3 `loglevel=8` (`e8d352b3ce0a…`) and rung 4
    `androidboot.init_fatal_reboot_target=bootloader` (`3de9da9f7f8b…`), each written as the whole partition after
    verifying its digest on the device, each followed by a boot check (`sys.boot_completed`, OEM fingerprint,
    `wlan0` up, token present in `/proc/cmdline`, `misc` untouched). All four booted Android 10 unchanged, so the
    tokens are free. The records prove the diagnostics were real: with devkmsg=on the ratelimit notices vanish and
    `init:` console lines go 65 -> 819/824, without it they return; `loglevel=8` lifts the record from 1,085 to
    1,254 lines (**D72**, measurement in `docs/findings.md`, "Nov 19 (night, second half)"). The DT's
    `ramoops@110000` node declares `console-size` 524,288 B / `record-size` 131,072 B / `pmsg-size` 327,680 B, and
    live `/proc/config.gz` has no `CONFIG_PSTORE_RECORD`, so a panic cannot create `dmesg-ramoops-0` - panic text
    lands in the console record (**D69** amendment). Partition 7 was then restored to the capture
    `4121b58f7759…` and re-verified (boot + WiFi + panel render, `super` still `535dac26946d…` = the Nov 18 live
    digest, `misc` still `909bdd979111…`); `/data/local/tmp/stock.img` holds that capture on the unit as the
    in-place rollback. Next build combines `printk.devkmsg=on` + `loglevel=8` + `panic=12` and keeps the
    reboot-target token out of payload builds, because it hands a dying init to u-boot and removes the adb route
    (**D73**).
22. **Nov 19 (night, third half): L2 ran, and the unit went silent - the ladder is halted.** Two new tools built
    it offline: `scripts/build_l2_ramdisk.sh` unpacked the capture's own ramdisk (gzip 803,440 B at 25,675,776, cpio
    1,870,336 B), put Android 14's static first-stage `init` (`631f960cbb96…`, 3,644,288 B) at `/init`, and added
    `/first_stage_ramdisk/fstab.rk30board` from the **stock** fstab - our payload fstab lists `system_ext`, which the
    Android 10 `super` does not have - then verified the archive by unpacking it again
    (`L2-ramdisk.gz`, gzip 1,628,683 B, cpio 3,650,048 B, `6456104e82c0…`). `tools/build_l2_boot.py` assembled the
    partition with the OEM kernel (`a514a3ffb77e`) and OEM `second` (`fb80617e7c97`) verbatim, header changed only in
    `ramdisk_size` and the 512-byte cmdline field (418 B: stock cmdline + devkmsg=on + loglevel=8 + panic=12 +
    `androidboot.init_fatal_reboot_target=recovery`), `second` moving to 27,305,984 and the OEM tail carried verbatim
    from 28,231,680 with both resource entries still verifying their declared SHA1s - giving
    `L2-init14-in-a10rd.img`, 33,554,432 B, `eaf9b7de30f9…`. It was pushed, digest-checked on the device, written as
    all 33,554,432 B (partition 7 `4121b58f7759…` -> `eaf9b7de30f9…`, `misc` untouched) and `adb reboot` ran at
    23:34:56 CET. The unit never answered again: eight connection tries, then eight probes over ten minutes (last
    23:44:09), `ping` losing every packet. So **D74** records that a recovery hand-off lands in the stock recovery,
    whose `adbd` runs over the USB gadget only - wireless adb needs `persist.internet_adb_enable`, which lives in
    `/data` recovery does not mount - and **D75** records that a write is only allowed when a boot running the image
    can still answer over TCP adb, because a pstore record needs a shell to be read. The cause of the failure is
    therefore *not* recorded: the console record is in RAM, and a cold power cycle erases it. Nothing else was
    written; `super` stays `535dac26946d…`, `/data` and every boot-chain partition are untouched, and the rollback
    stays available at `a14-work/hu-stock-backup-refresh/boot.bin` and on the unit at `/data/local/tmp/stock.img`.
    Restore is owner-side (bootSD card **D39**, or USB adb inside recovery **D74**) - owner question 15. Re-probed
    Nov 20 00:06 CET: `adb connect` still says "No route to host" and `ping -c 3` loses every packet, so the unit
    has not come back by itself and the agent stops here until the owner restores it (**D75**).

23. **Nov 20 (afternoon): the owner restored the unit; it runs stock Android 10 again and TCP adb came back by
    itself.** They forced the recovery menu with their own grip and installed the OEM package from
    `/mnt/external_sd/update.zip`, no `/data` or `cache` wipe. Recovery's own log survived in `pmsg-ramoops-0`
    (`374e8080cbd6…`) and records the install: success flag `1`, `time_total: 333` s, `retry: 1`, target build
    `eng.hct2.20250401.152740`, 3,124,451,704 B written over `dm-0..dm-3`, plus `adbd` lines `opening control
    endpoint /dev/usb-ffs/adb/ep0` and `USB event: FUNCTIONFS_BIND` (**D74**'s USB-gadget adbd, confirmed live).
    adb was reachable at 14:32:17 CET on the first probe. Measured state: `boot_completed=1`, OEM fingerprint,
    `wlan0` up, `surfaceflinger` running, `bootanim` stopped, kernel `4.19.111+`, boot id
    `e227f00b-e8ef-4dd6-8599-a9b4f7c39ea7`, `/data` unwiped at 17 % used, panel rendering (screencap
    `4edfe7a4ec10…`, 1024x600, 9,033 distinct sampled colours, 488,446 pure black). Partition 7 is now the package's
    image `b449aee98c01a7da797be1c2aa8238ce4bef3e5ee3ae731afdcf3c53218c4384`, captured to
    `a14-work/hu-stock-postflash-143452/boot.bin`; against the Nov 17 capture it differs in 605,548 bytes in the span
    from 27,406,336 (splash pixel data there in the capture, a DTB head in the package image), while kernel, ramdisk,
    `second`, header fields, cmdline, both tail DTB copies and both resource SHA1s are identical (**D76**). `misc` is
    still `909bdd979111…` and `super` still `535dac26946d…`. **D77** is the lesson: `console-ramoops-0`
    (`2f8289fa9abf…`, 54,883 B, 916 lines, `storagemedia=sd`, `First stage mount skipped (recovery mode)`) holds the
    *flash* boot's text, so L2's own log was overwritten by the recovery/flash boots and its cause stays unknown - a
    failed boot's record is readable only from the boot immediately after it. `misc` never changing proves init never
    wrote a BCB, so the L2 boot hung instead of taking the recovery hand-off. Nothing has been written since; the next
    rung must keep TCP adb (**D75**), so an Android 14-init boot is not writable again until there is a design that
    answers over adb before anything else boots.
24. **Nov 20 (late afternoon): the diagnostic token set moved onto the new base image and the unit is back on the
    capture.** `tools/patch_boot_cmdline.py` added `printk.devkmsg=on`, `loglevel=8` and `panic=12` to the post-flash
    capture, producing `L5-diag-on-newbase.img` (`3de96f683b74…`) which differs from it by 38 bytes, all inside the
    cmdline field. It was written whole (partition 7 `b449aee98c01…` -> `3de96f683b74…`, rollback staged at
    `/data/local/tmp/stock2.img` first) and Android 10 booted unchanged with the tokens in `/proc/cmdline`; the warm
    reboot then gave its record - 183,405 B `7ffec7b1641d…`, 2,411 lines, no ratelimit notice, 832 `init:` lines,
    `console [pstore-1] enabled` at 0.054 s - and screencaps prove the panel rendered both before and after the
    restore (`665bfb3153cc…`, `408f53caf4d9…`). Partition 7 was restored to `b449aee98c01…` at 15:25 CET and verified
    (`boot_completed=1`, `wlan0` up, zero tokens, `misc` `909bdd979111…`, `super` `535dac26946d…`). **D78** now bounds
    the ladder: the owner reports none of the unit's USB ports drive adb (they are host-mode), so recovery is not
    reachable as a shell from this workstation and TCP adb in Android 10 is the only route - a write must be content
    already proven to boot on the unit. **D79** records the offline finding that raises the UART case: recovery's
    `init.recovery.rk30board.rc` starts `console /system/bin/sh` under `ro.debuggable=1` (this unit is userdebug,
    `console=ttyFIQ0`), so a UART probe would give an interactive shell that could mount pstore and read the failed
    boot's text; the probe stays declined (**D63**), so a second Android 14 attempt is not writable until either the
    UART opens or the owner agrees to pull the record in recovery themselves.
25. **Nov 20 (evening, offline): partition 8 holds the patched recovery, and the script that runs there was
    rebuilt and logic-tested.** The first patched image (`a4cf5533482e…`, 39,086,080 B) was written over the capture
    `1fdf5ea77fc6…` and read back byte-exact; partition 7 stayed `b449aee98c01…` and `misc` stayed
    `909bdd979111…`. The stock recovery UI is alive on it, so **D80**'s condition - MTC/mainboard flashing intact -
    is measured, not assumed. The automatic hand-back never happened and no evidence was copied: the script created
    `/cache/hu-evidence` before mounting `/cache`, so the directory vanished under the mount point and the run wrote
    nothing and logged nothing. `scripts/hu_recovery_evidence.sh` was rewritten against a measurement of the
    ramdisk's own tools (strings over `sbin/busybox`: no `dd wc cp rm ls tr sha256sum`; `/system/bin` carries them
    plus `linker64` and `lib64`), and `scripts/smoke_recovery_evidence.sh` now asserts nine scenarios against fake
    partitions, a fake `/proc/mounts`, a fake pstore and two fake bin trees - all pass (rc 0). Four defects came
    out of it: the vanished evidence directory; a digest that could not be read comparing equal to another empty
    digest, which would skip the restore and leave the risky image in partition 7 (now: write the rollback anyway,
    record `restore-unverified.txt`); a request that could re-arm the restore on every later recovery boot, retired
    by a nonce-named done-marker since busybox has no `rm`; and a reboot from recovery that can land back in the
    menu, because this unit enters recovery through the kernel's reboot-mode, not `misc` - so the reboot is only
    attempted when this boot did something, and the log names the cold-cycle fallback. The rebuilt candidate is
    `a14-work/recovery-evidence/recovery-evidence.img` (39,088,128 B, `d64ebd22d614…`), with kernel/`second`/dtbo
    blobs byte-identical to the capture and the stock rc kept verbatim (`analysis/recovery-evidence.txt`). Nothing
    was flashed in this pass. Next: the owner cold-cycles, then `/cache/hu-evidence.log` says whether the service
    ran; the rebuilt image goes on partition 8 only after `dash -n` and `busybox ash -n` pass on the build host.
26. **Nov 21 (offline, no unit writes): partition 8 is stock again on its own, the record we wanted is saved, and
    the script's gate moved onto the unit.** Partition 8 reads back as the capture `1fdf5ea77fc6…` (full 100,663,296 B,
    zero differing bytes over the first 39,104,512 B) because `/system/bin/install-recovery.sh` - init service
    `flash_recovery`, measured running at t=19.9 s in the boot's own console record - `applypatch`es recovery from
    `/system/recovery-from-boot.p` with source `boot:27,406,336:ecb5315f…` and target
    `recovery:39,122,944:f75bcfb4…`, and both digests verify against the images we hold. So a patched partition 8 is
    transient while partition 7 is an OEM Android 10 image, and persists only with a payload whose digest differs
    (**D82**); the Nov 20 note that "nothing re-flashes recovery" was wrong because it checked `/vendor`, and the
    patch lives in `/system`. The record the 22:06 run copied is the Android 10 boot's text (67,548 B, 1,093 lines,
    ending in `reboot: Restarting system with command 'recovery'` after `init: Received sys.powerctl=... from
    /system/bin/adbd`), so the parked-menu boot's text is preserved in `/cache`. That run never reached the restore
    step because hashing the whole 96 MiB partition never returned - `dig()` now caps reads at 64 MiB through
    `head -c`, and the gate asserts the line is reached and equals the capped read's sha256. The recovery ramdisk's
    `/sbin/sh` is MIRBSD KSH R40 and its busybox has no `ash` applet and no `--version`/`--list`, which is why
    `busybox-applets.txt` came back 0 bytes; pushing `/sbin/sh` to `/data/local/tmp/hush` and running `hush -n` on
    the candidate script returns rc 0 on the unit, so the dialect gate no longer needs the NAS. Rebuilt candidate
    `dfe61ba7b3d6…` (39,088,128 B) injecting script `646c0a709742…`, blobs byte-identical to the capture, gate
    `b83e36cdc8a6…` passing nine scenarios. Nothing was written; partition 7 stays `b449aee98c01…`, `misc` stays
    `909bdd979111…`.
27. **Nov 21 (late morning, live): the revert is isolated, partition 8 is staged patched again, and the owner's
    release is recorded as D83.** Partition 8 was written twice from `/cache/hu-patched-recovery.bin` (exact
    39,086,080 B span, `dd bs=512 count=76720`, span verified against the image digest both times) and reverted
    on a plain `adb reboot` before adbd answered - ~40 s after reboot, `init.svc.flash_recovery: stopped`,
    `ro.boottime.flash_recovery: 3759993000`: the revert fires at boot time 3.76 s, and its log lines roll out of
    logcat and kmsg before the first adb read, which is why earlier probes saw nothing. The service definition is
    `/init.rc:854` (`service flash_recovery /system/bin/install-recovery.sh`, class main, oneshot) - the root init
    rc, which the rc-dir greps never covered. Boot-stage copy ruled out: `backup` partition all zeros, partitions
    contiguous (8.4 MiB tail is the backup GPT), uboot flash code only runs in loader mode, boot.bin tail is
    pointer-table data, boot ramdisk and modules reference nothing recovery. Recovery boots do not run Android
    init, so a patched partition 8 survives the recovery boot itself: the rule is write partition 8, then enter
    recovery immediately, never boot Android in between. Rebuilds are not byte-reproducible (gzip timestamps):
    `dfe61ba7b3d6…` -> `f8a4a779b2fb…` -> `8201bde5021e…` (39,086,080 B) for identical content; the staged copy's
    digest is what gets registered. Offline gates re-run before staging: smoke 9/9 rc 0, sandbox harness A-F pass.
    The owner's Nov 20 evening release is recorded as **D83** (all recovery restrictions lifted; recovery and
    `boot`/`super` never altered in the same flash; "make recovery our own" is an open goal with a read-only
    reverse-engineering pass of the stock recovery binary running now). Partition 8 currently holds the staged
    patched build `8201bde5021e…`; the restore request (nonce `nov20-rung2-1795208096-27817`, unconsumed) and the
    rollback (`b449aee98c01…`) are staged in `/cache`. **Android must not boot before the owner enters recovery.**
28. **Nov 21 (afternoon, read-only reverse-engineering): the recovery binary is mapped, the made-ours boundary
    is measured, and route 1 is reopened.** The report is `a14-work/tmp/rec-re/RECOVERY-RE.md` (details in
    `docs/findings.md`, "Nov 21 (afternoon)"). Key outcomes: the partition tail beyond the dtbo is zeros and
    splash/resource live inside the `RSCE` second (per-entry SHA1 - any edit must rehash); the recovery kernel is
    build #190 (Jul 5 2024), not #2416, and it carries the flashing nodes and reboot-mode driver; recovery and
    fastboot share reboot-mode marker `0x5242c303` and the misc BCB stage discriminates them (**D71** reconciled);
    `verify_package()` reads the **ramdisk's** `otacerts.zip` (no `/system` mount in recovery), so adding our cert
    to that zip inside the patched ramdisk reopens route 1 (**D25** superseded offline) while HCT's cert keeps OEM
    installs working; the RKA flashing engine writes through `/dev/vendor_storage` below the Android partitions
    (IDB, `parameter`, `backup`, scratch `/tmp/flash.bin`), MCU images go over `/dev/mtc-car` IAP (`install_mcu`
    order `dmcu.ext` -> `dmcu.cfg` -> five `*.img`), UI is stock `ScreenRecoveryUI` titled
    `Android Recovery by HCT V10.3.1`. Made-ours boundary: replaceable = ramdisk only (init rc, `prop.default`,
    `recovery.fstab`, `res/`, scripts on either toolchain, `otacerts.zip`); byte-for-byte = kernel, second, dtbo,
    header page, `system/bin/recovery` (all RKA/MTC logic lives only there). Next offline step for "make it our
    own": build our cert, splice `otacerts.zip` with both certs into a candidate partition-8 image keeping
    `hu_evidence`, gate it (smoke + mksh `-n` on the unit), and write it only as a recovery-only flash (**D83**).
29. **Nov 21 (evening, live read-only + offline build): the owner's USB-Ethernet dongle works on the host port,
    and the recovery script gains a network phase - the rapid-fire route is Ethernet-first (**D84**).** The owner
    connected a USB-Ethernet adapter at 14:50; `eth0` bound on host controller `fe3c0000.usb` (device `1-1.2`) via
    `ax88179_178a` (ASIX AX88179_178A, MAC `00:0a:cd:27:a5:b2`), `carrier=1`, `operstate=up`, `speed=1000`. That
    driver is built into the kernel recovery boots (strings `ax88179_178a`/`asix_`/`cdc_ether`/`cdc_ncm`/`r8152`,
    nothing in `lsmod`), so recovery needs no module, firmware file or supplicant. Measured through it: ping
    `192.168.1.161` -> `192.168.1.120` at 1.0-3.3 ms, adb read 125,829,120 B in 1 s (~120 MB/s), `adb push` 100 MiB
    to `/cache` in 12 s (~8.3 MB/s, eMMC-bound), and a 200 MiB `dd` there failed ENOSPC - `/cache` is 356 MiB with
    185 MiB free, so payloads stream straight to the partition or come in over busybox `wget`. SELinux is
    permissive (`androidboot.selinux=permissive`, `getenforce` Permissive) and the recovery policy names
    `adbd`/`ctl_adbd_prop`/`net_bind_service`, so TCP adb (`service.adb.tcp.port 5555` + `ctl.start adbd`) and
    `busybox telnetd -l /sbin/sh` need no policy work; ssh is not available (busybox 1.11.1 has no ssh/dropbear),
    and WiFi stays the open-AP-only fallback (no wpa_supplicant in busybox; the vendor HAL needs binder;
    `firmware_class.path` points at an unmounted `/vendor/etc/firmware`, so cfg80211 falls back to the default
    regdomain). Partition map measured through `/dev/block/by-name`: `misc`=`mmcblk2p3` (p9 is the all-zero
    `backup`), `boot`=p7, `recovery`=p8, `cache`=p11, `super`=p14 - the earlier misc-as-p9 note was wrong.
    `scripts/hu_recovery_evidence.sh` now captures the `misc` BCB first 4 KiB on every recovery boot, brings the
    network up behind `/cache/hu-net.request` (nonce + done-marker, optional `/cache/hu-net.conf` iface/ip/gw/ssid),
    probes partition 7 with a zero-length `dd conv=notrunc` write, and suppresses the reboot-out while a session is
    armed; the card-package guard still exits first. Gates: `bash --posix -n` clean, repo smoke 13 scenarios rc 0
    (91 assertions), sandbox harness A-I pass (its shims now record `ifconfig`/`route`/`telnetd`/`insmod`/`setprop`
    instead of executing them). Rebuilt candidate `a14-work/recovery-evidence/recovery-evidence.img`
    39,088,128 B, `90923603efc1…`, script `5e663ff46bbe…`, kernel/`second`/dtbo blobs byte-identical
    (`a514a3ffb77e`, `fb80617e7c97`, `28a07d4946e9`). Nothing was written: partition 7 stays `b449aee98c01…`,
    `misc` stays `909bdd979111…`, partition 8 still holds the staged `8201bde5021e…` build. Next: the owner enters
    recovery (or the new build is written as a recovery-only flash under **D84**), then the four measurements -
    dongle enumeration in recovery, reboot-out parking from `misc-bcb.bin` across boots, whether a recovery-side
    partition write is allowed, and recovery's own cmdline selinux value.


**Nov 21 (late evening) - the Step-3 net module is built and gated; the p8 write awaits the owner's go.**
Step 2 ran in reduced scope (`/cache/state-android.txt`, 4,307 B: `eth0` up at 1000 Mbps full duplex on
`ax88179_178a`, MAC `00:0a:cd:27:a5:b2`, address `192.168.1.127/24`, route table only `eth0`), and Step 4
(the USB enabler) is **dropped**: the dongle enumerates inside a recovery boot by itself (`ax88179_178a …
eth0: register` at 1.698 s of the 16:28 recovery console), so only userspace bring-up is missing. The module
is **D85**: six linear scripts plus seven independent oneshot services, `scripts/hu_h_common.sh` and
`scripts/hu_net_module_append.rc` (stock 663 B verbatim + 1,224 B appended). Gates: offline sandbox
`scripts/smoke_recovery_netmodule.sh` 14 scenarios rc 0 (busybox shim refuses the applets v1.11.1 lacks -
`sha256sum` and `timeout` - and records the net applets instead of running them; the audit also catches the
`$SB <applet>` call-shape trap, since toybox needs `$SB/applet`); the dialect gate ran the recovery ramdisk's
own `/sbin/sh` (`@(#)MIRBSD KSH R40 2011-10-07`, pushed exec-only to `/data/local/tmp/hu-dialect/`) with
`-n` rc 0 on all seven files, plus a construct probe under R40 - Android's `/system/bin/sh` is
`@(#)MIRBSD KSH R57 2019-03-01 Android`, so parsing under it proves nothing. Build:
`a14-work/recovery-netmodule/recovery-netmodule.img` 39,090,176 B, sha256
`0ab64a039cdd8ea8f99f45a2c530076c6b8d4d99856448565fbe39e3c5b0adac`, ramdisk 12,519,199 B -> 12,484,781 B,
kernel `a514a3ffb77e…`/second `fb80617e7c97…`/dtbo `28a07d4946e9…` byte-identical, `prop.default` changed on
exactly three lines, seven services defined once and started once, retired `hu_evidence` absent. Still
unwritten: partition 7 stays `b449aee98c01…`, partition 8 stays stock `1fdf5ea77fc6…`, `misc` unchanged.
Next on the owner's go: stage the image to `/cache`, dd partition 8 (write span 0..39,090,176 of
100,663,296 B, host-side readback), stage a fresh `/cache/hu-net.request` nonce, cold power cycle with the
dongle plugged in **before** power-up, read `-HUPATCH` in the menu header and the activity LED, then
`adb connect` to the logged address and host-side verify partition 7 still hashes to `b449aee98c01…`. Step 5
(exit mechanics) and Step 6 (re-entry) follow only after adb-in-recovery is proven.

30. **Nov 22 (live + offline): the arming matrix is measured, the wrapper is built and gated, three
    injected images are staged - nothing flashed (**D90**-**D95**).** Phase A filled the arming matrix on
    the eMMC BCB: armed BCB + warm reboot, armed BCB + kernel panic and armed BCB + a 60 s power cut with
    **no reboot command issued** all land in recovery; unarmed BCB + normal reboot and unarmed BCB + panic
    boot Android; u-boot adds `b.mode=recovery` when `misc` carries `boot-recovery`, and a panic without an
    armed BCB leaves `b.mode=panic` and boots Android (**D90**). The reboot-mode register path is dropped -
    `/dev/mem` is absent and busybox 1.11.1 has no `devmem`, and every tested boot read
    `androidboot.mode=normal` (**D91**). A cold power cut is now an accepted last-resort recovery entry, and
    it destroys RAMoops (`/sys/fs/pstore` was `total 0`), so the live console plus card copies are the
    evidence. Partition 7 was written with its own first 4,096 B as a no-change write (`conv=notrunc`, rc 0)
    and hashed `b449aee98c01…` before **and** after, with partition 8 and `misc` untouched in the same
    operation (**D62** held). The owner installed the toolchain himself (`sudo pacman -S zig qemu-user`):
    zig 0.17.1, qemu-aarch64 11.1.3, llvm-strip from LLVM 23.1.5 (**D94**). `tools/hu_wrap.c` builds to a
    static stripped aarch64 ELF with no `NEEDED` and no `INTERP` (`99627bcec382…`, 13,968 B), and a second
    build in another directory gives the same digest byte-for-byte. HU_TEST passes on the workstation
    (native x86_64 plus `qemu-aarch64`, six scenarios and twelve source assertions, 0 failures) and on the
    unit from `/data/local/tmp/hu-wraptest` against loopback files (healthy arm, misc missing, passthrough,
    watchdog fires, disarmed before the tick); the write-fail leg cannot be enforced on the unit because
    root under permissive SELinux writes a `0444` regular file, so it stays host-only. Injection became an
    in-place cpio byte transform (**D95**): extract-and-repack is refused because `cpio -idm` cannot create
    the payload's `dev/console`/`dev/null`/`dev/urandom` nodes as a non-root user and the archive uses
    110-byte headers (13 eight-hex fields, namesize at 94, filesize at 54, devmajor/devminor at 78/86).
    Three images are staged, all 33,554,432 B: `hu-wrap-stock-a10.img` `b1378cd79497…`,
    `hu-wrap-a14rd.img` `8f287e8bfa98…`, and `hu-wrap-a14rd-diag.img` `02ac85b9aee4…` (header bytes
    16..19 plus the cmdline tokens at 397..440). `scripts/verify_hu_wrap_boot.sh` rc 0 on all three,
    `tools/identity_gate.py` PASS. The earlier claim that cmdline tokens need a boot-chain write was
    **wrong**: the header cmdline field is 512 B at 64..575, D60 permits it, `boot-min.img` `3cf40129…` and
    `boot-diag.img` `85dd1138…` differ by exactly 9 bytes at 397..405, and the stock header cmdline sits
    verbatim inside the live `/proc/cmdline`. Partition 7 still holds stock `b449aee98c01…`, partition 8
    stock `1fdf5ea77fc6…`, `misc` the baseline `909bdd979111…`; Phase B needs the owner's GO, the disarm rc
    service is designed (**D92**) but not yet written into an image, and the `netd`/Ethernet interaction
    with the static address is still unexamined. Evidence: a14-work/phaseA-nov22/ and
    a14-work/wraptest-nov22/ with manifests. Both evidence dirs, the staged images, the pulled vendor
    images and the tree's finished pass are now mirrored in cold storage on the NAS (**D96**): the copies are
    additive, nothing was moved or deleted, and the flash loop still reads its inputs locally
    (docs/housekeeping.md).
 31. **Nov 22 (late): iteration 1 closed - the wrapper's first boot never answered, and the owner restored
     the unit with an OEM `update.zip` without wiping `/data` (**D97**).** Partition 8 was written from
     Android (`b2821cce34ae…` read back ok) and partition 7 was written from recovery with partition 8 frozen
     (`b1378cd79497…` read back byte-exact on the workstation), with `misc` untouched by both writes. The
     reboot issued at epoch `1795375253` produced no answer at all: at 712 s ping lost, no neighbour entry,
     TCP 5555 and 2323 closed, `adb devices` empty, and the owner saw button backlighting with a black
     screen. So the wrapper's arm on the real `misc` and its watchdog reboot stay unmeasured, and the dead
     boot's console was never read. Measured during the leg: entering recovery clears the BCB, the v6
     recovery services do not mount `/cache` (markers land in RAM), a hand mount returns rc 0, and
     `hu-card.sh` mounted a card at `/mnt/hucard` which is not yet identified. The owner's install brought
     back Android 10 with `/data` intact; partition heads equal the pre-restore stock captures
     (`fac15a4b138e…`, `b06dc33648a3…`, `0f2ec43e7a5c…`) and `flash_recovery` ran at 3.76 s (**D82**).
     Nothing was cloned afterwards, on the owner's instruction. Awaiting the owner's instructions; the next
     write needs an explicit go.

31. **Nov 22 (late): the SD-boot card becomes the recovery carrier (**D98**); its module runs in card-boot
    mode (**D99**, pending owner approval).** STEP 0.1 measured the three block devices by size and type:
    `mmcblk1` SD 7,948,206,080 B is the boot card and is not mounted by Android, `mmcblk0` SD 31,266,439,168 B
    is mounted rw, `mmcblk2` MMC 62,813,896,704 B is the eMMC, and `/dev/block/by-name/*` still points only at
    mmcblk2 partitions. STEP 0.2 is a chunked base64 pull (`dd | base64` over exec-out, 33,554,432 B per chunk,
    237 chunks): the pull pass assembled 7,948,206,080 B digest `ca6d1f4d3384…` at 3.36-3.73 MB/s per chunk, and
    the verification pass re-reads every chunk before the image is trusted - it was still running when this item
    was written, so no card-side write is allowed yet. The card's partition table is vendor-written: `EFI PART`,
    header_size 92, entry_count claimed 0, entry_size claimed 15,523,839, entry CRC 0, no protective MBR, and the
    start/end LBA fields sit at record offset 32/40 rather than 8/16; read from there the records tile the disk and
    match the device-reported sizes for p1..p8. `tools/sd_card_layout.py` `41f60ea834e8…` and
    `tools/card_image_analysis.py` `aab15720a666…` read that layout. The card's own boot and recovery share one
    kernel blob (`a11c2667f843…`, Linux 4.19.111+, `ax88179_178a` strings present). STEP 0.3 runs on the verified
    image: card misc BCB bytes, p8 header/dtbo/ramdisk/recovery-binary digests, `recovery.fstab`, `init.rc`,
    `prop.default`. STEP 1 builds the card p8 patch with `HU_CARD_BUILD=1` from the card capture; the module's
    card-boot mode keeps markers in RAM, resolves misc by size and type, refuses the card copy, and arms without a
    nonce with a 30-minute window - that arm is the owner's decision to approve. STEP 2 needs a GO and writes only
    the card's p8 plus the re-armed card misc (`scripts/arm_card_misc.sh` `026f22a31da8…`). STEP 4's ladder stays
    as defined, with the eMMC resolved by size, never by-name.
32. **Nov 23: STEP 1 done offline - the card's own p8 image is built and reproducible (**D100**); STEP 2 needs
    the owner's GO.** `HU_CARD_BUILD=1 HU_PART_BYTES=100663296 HU_DTBO_SIZE=803 scripts/patch_recovery_netmodule.sh`
    ran on the verified capture and produced `card-p8/recovery-netmodule.img` (`03dcdad7af92…`), 100,663,296 B, and
    a second independent build gives that same digest. Only header bytes 16..17 change; the kernel, second
    bootloader, dtbo region and the 61,816,029 B vendor tail beyond the dtbo are byte-identical to the capture, and
    the ramdisk keeps the stock page span via `sbin/hu-pad.bin` so no offset moves. The header's declared dtbo size
    is 803 (64-byte DTB header + 739-byte payload), which is why `HU_DTBO_SIZE=803` is now the card parameter, and
    the repacker was made reproducible (mtime normalisation plus `cpio --reproducible`). The write STEP 2 would
    need is the header page 0..2,047 plus the ramdisk span 25,425,920..37,943,295 - 12,519,424 B of the partition,
    on the SD node resolved by size 7,948,206,080 B, followed separately by the card misc re-arm
    (`scripts/arm_card_misc.sh`). Nothing has been written to the card or the eMMC.
33. **Nov 23: STEP 2 done with the owner's GO - the SD-boot card is patched and re-armed.** The card was
    resolved by size (7,948,206,080 B, type SD), never by-name. Pre-state pull proved p8 equal to the capture
    (`04ed02a2713c…`); the header page and the ramdisk span were written with `conv=notrunc`; the whole-partition
    readback equals the record image `03dcdad7af92…` and every changed byte falls inside those two spans; the misc
    re-arm wrote 2,048 B (`ceaae1a6314a…`, no `--wipe_all`) and read back equal. The card's p7 head and all three
    eMMC heads are unchanged. Two Android-side bugs in `scripts/arm_card_misc.sh` were found and fixed on the way
    (`stat` is a toybox applet, not a bare Android binary, and Android's normal boot has no `/tmp`); the first run
    aborted safely. The next step is STEP 3: read-only measurement in Android with the card in (by-name links,
    eMMC by size 62,813,896,704 B, mounts, eMMC p7 hash), then the owner's deliberate card boot - the boot card
    must not be rebooted with it inserted until the owner chooses. The second SD card (31,266,439,168 B) is
    currently absent from the unit, so the approved evidence channel needs it re-inserted before a card boot can
    copy anything.
