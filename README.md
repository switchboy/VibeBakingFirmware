# VibeBaking Firmware — PX6 (RK3399) head-unit upgrade project

Goal: take a **Rockchip PX6 Android head unit** (HCT4 platform, currently Android 10/11 with a 2020
security patch level) and bring it to **Android 14 / LineageOS 21** while keeping the head-unit hardware
(CAN bus / MCU "MTC", radio tuner, AMP, AV-in, GPS, Bluetooth-on-UART, CarPlay bridges) working, and
without bricking the single unit we have.

## Hardware / firmware as found

| Item | Value |
|---|---|
| SoC | Rockchip PX6 = RK3399 (2×A72 + 4×A53), Mali-T620 MP4 (Midgard) GPU |
| Vendor HAL hardware name | `rk30board` (`ro.hardware`), board `rk30sdk`, platform `rk3399` |
| Device / customer | `ro.product.vendor.model=PX6`, `ro.product.customer=HCT4`, `ro.product.manufacturer9=HengChangTong`, `ro.product.model9=H660000` |
| Current OS | Android 10 (`QQ2A.200305.004.A1`), SDK 29, userdebug **test-keys**, security patch **2020-05-05** |
| Custom ROM base | **Hal9k Mod v5** (build fingerprint `eng.hct2…`, `ro.product.ota.host=ota.hal9k.ru:2300`, Magisk present in `/vendor/magisk`) |
| Kernel | Linux **4.19.111+**, Rockchip BSP, built Mar 2021, boot image header v2, `androidboot.selinux=permissive` |
| Partitions | dynamic partitions in `super` (group max 3258974208 = 3.1 GB): system 1.44 GB, product 0.93 GB, vendor 0.33 GB, odm 0.56 GB |
| Data | `/data` = F2FS with `quota`, `checkpoint=fs` |
| Flashing | Rockchip `update.zip` on FAT32 USB/SD → unit's built-in upgrade flow (`RKLoader.bin` loader + custom `update-binary` with `do_rk_firmware_upgrade()`), plus `uboot.img` / `trust.img` / `dtbo.img` written directly |

The current firmware's concrete security problems are listed in `docs/firmware-analysis.md`
(permissive SELinux, Magisk in the vendor image, world-writable `/dev/mtc-*`/`ttyS*`/`ttyV*`, adb over
TCP, 2020-05 vendor patch level, third-party OTA server).

What runs **today** is not the Hal9k build: the owner restored the unit's own firmware through the bootSD
recovery card (**D39**), and the Nov 13 probe reports
`rockchip/rk3399/rk3399:10/QQ2A.200305.004.A1/eng.hct2.20250401.152740:userdebug/release-keys` - the April
2025 OEM rebuild (`diatsia fw/update(1).zip`, `31bb492a…`) - with SELinux still Permissive and root
available through `su`. Its hashed vendor/system/product/odm surface is 126/126 identical to the Android 10
reference image (`tools/vendor_blob_check.py`), which is what makes **D44** a live question.

## Where things live

| path | what it is |
|---|---|
| `device/rk3399-px6-hct4/` | the device tree, copied into the synced Lineage tree by `scripts/deploy_device.sh` |
| `patches/` | tree patches, applied by `scripts/apply_tree_patches.sh` |
| `scripts/`, `tools/` | build / verify / flash plumbing; usage is in each file's own header |
| `scripts/archive/`, `tools/archive/` | historical one-shots whose results are recorded in `docs/decisions.md` / `docs/findings.md` - do not run blindly |
| `docs/` | see `docs/index.md` for which file is canonical |
| `analysis/` | generated dumps + tracked evidence (`*.txt`, kernel configs, partition offsets, app-layer inventory, `gpt/gpt_head.bin` + `gpt_tail.bin`) |
| `incoming/` | owner's probe reports from the live unit (tracked `*.md`) |
| `out-hu/` | workstation copies of the payload artefacts (ignored, reproducible): `update.zip` (signed payload), `super.img`, `boot.img` |
| `update.zip`, `extracted update.zip/`, `diatsia fw/` | the OEM reference packages on disk (ignored; originals also live on the NAS). Identify by sha, not name: repo-root `update.zip` = Android 10 2021 test-keys (`dd3e2ac0…`), `diatsia fw/update.zip` = Android 11 (`50775dba…`) - the OS running today - `diatsia fw/update(1).zip` = Android 10 2025 release-keys (`31bb492a…`) - the preferred rollback. All three are signed by HCT's cert `cf2ab3…`. Never confuse them with `out-hu/update.zip`, which is OUR payload (`b81c50cc…`) |
| `hal/`, `rom/` | parked shim/hardening stubs, superseded in practice by D21/D22/D23 |

Build host paths (NAS): build tree `/srv/dev-disk-by-label-SSData/aospbuild/lineage21s`, scratch
`/srv/dev-disk-by-label-SSData/aospbuild/tmp`, OEM archive
`/srv/50911774-19fb-46b6-bc9e-8cf81623d044/aospbuild-archive`.

## Workflow today

1. `scripts/package.sh <tree>` — vendor closure, deploy, dist, superimage, bootimage (`docs/build-host.md`).
2. `scripts/verify_artifacts.sh <tree>` + `scripts/verify_hu_apps.sh <tree>` — offline gates.
3. `scripts/build_hu_package.sh <tree> "extracted update.zip" <out>` — payload zip; then
   `scripts/sign_hu_package.sh <in> <out>` adds the SignApk comment signature the OEM packages use, and
   `tools/zip_comment_sig.py <zip>` reads back whatever signature a package carries.
4. Stick: route 1 = signed `update.zip` at the root (recovery install); route 2 =
   `scripts/make_flash_stick.sh <mountpoint>` for the raw-image install (`docs/flash.md`).
5. First boot: the ROM's own `/system/bin/hu_probe.sh` writes the report to the stick - no terminal needed.

## Status (Nov 13/14)

* The Android 14 build is in the tree and verified offline: apps, WiFi HAL, patched libdrm, drmservice
  and the vendor module set (D21-D24). Packaging pass and payload audit: `docs/findings.md`.
* Nov 13 probe (`incoming/probe-20261113-2016.md`, root via `su`): the firmware running today is the April
  2025 OEM rebuild, and its hashed vendor/system/product/odm surface is **byte-for-byte the Android 10
  reference** (`tools/vendor_blob_check.py`, 126/126 identical, `analysis/vendor_blob_live_vs_oem_a10.tsv`).
  The tree we stage, however, comes from the Android 11 dump and differs from the live unit in **75** paths
  (audio/composer/sensors/gps/power/vibrator/mtc/bluetooth/wifi/rild/hostapd and the vendor manifest). Which
  vendor base to ship is now **D44** and is the owner's call, because it trades proven hardware against the
  cleaner Android 14 HAL interface D9 chose.
* Route 1 (signed zip through recovery) was **rejected** on Nov 9: recovery trusts only HCT's own cert
  (`cf2ab3…`), which we do not hold (**D25**). Route 2 ran the same day and the write itself succeeded
  over TCP adb (`adbon` in the factory-settings dialog -> port 5555 -> `adb root`, **D28**), but the unit
  came up black-screen with no WiFi and no adb. The cause is measured (**D34**): the payload had **no
  first-stage fstab anywhere**, so Android 14 init never mounted `/system`. Nothing in the boot chain was
  touched, so the unit is not bricked (**D30**). Flash-attempt log, and the two `flash_from_android.sh`
  bugs that were found in it, are in `docs/findings.md`.
* Nov 11: the unit is back on **stock Android 10** through the owner's bootSD recovery card (**D39**) and
  the OEM `diatsia fw/update(1).zip`, and the working stock eMMC was pulled partition-by-partition into a
  byte-exact backup with a verified manifest (**D40**). That backup - not the factory card - is the
  rollback for the next Android 14 attempt, which writes only `boot` + `super`.
* Recovery is becoming the install tool instead of a menu nobody can drive (**D42**/**D43**): partition 8
  is patched (it is not boot chain, and `vbmeta` carries zero descriptors, so AVB cannot reject the patch)
  to run a card-driven installer that writes only `super`, `boot` and `userdata` and is inert without
  `hu-install.flag` on a card. `scripts/patch_recovery_autorun.sh` builds the image,
  `scripts/stage_hu_card.sh` stages the card, `scripts/hu_recovery_install.sh` is the installer.
* Nov 13: the installer was logic-tested offline (`scripts/smoke_recovery_installer.sh`) and **two bugs
  were fixed** - the payload-size check divided by 1000 where it meant 1024 and therefore refused every
  write, and the digest check compared manifest spellings (`sha1`) against the applet name it probed
  (`sha1sum`), so it verified nothing while reporting success. Payload sizes and digests now come from the
  card manifest. The patched recovery image on record (`a0cd9de3…`) still holds the buggy script, so
  `scripts/patch_recovery_autorun.sh` must run again before partition 8 is flashed - that splice runs on
  the build host, whose access wrapper lives outside the repo (`/tmp/opencode/omv.sh`, `askpass.sh`,
  `build_host.env`; re-checked Nov 18, they are present). Nothing was flashed today.
* Two fixed boot images are **built and verified but not flashed** (**D33**/**D34**): `a14-fixed.img`
  (our payload + `/first_stage_ramdisk/fstab.rk30board`) and the generation-coherent
  `boot-a10k-a14rd.img` (OEM A10 kernel + OEM A10 `second` with the A10 DTB + our A14 ramdisk + fstab).
  Flashing the OEM `boot-a10.img` unchanged would **not** work - its ramdisk fstab lists only
  `system/vendor/odm/product`, no `system_ext`.
* Other measured differences (**D32**) are cleanup, not the cause: `mali_kbase.ko` reports
  `vermagic=4.4.167` (the OEM vendor ships the same bad module and Mali is built into both kernels), and
  the DTB panel-timing changes are a *vendor* A10->A11 difference, not our edit. AVB/vbmeta, uboot/trust
  mismatch, partition layout and ext4-vs-fstab are ruled out.
* The bench route is written up standalone in `docs/reanimation.md` (harness yellow+red to a **12 V /
  10 A** supply fused at 10 A, black to supply GND, a 3.3 V serial fob on `console=ttyFIQ0` at
  115200 8N1, partition sector map, serial reading order, decision tree, write routes); capture with
  `scripts/serial_console.sh log <name>`.
* Rollback payload rebuilt from `diatsia fw/update(1).zip` (**D31**) and checked with `lpdump` +
  `debugfs`. Restore by `dd` from the recovery environment or from the stock backup. Nothing has been
  burned to a physical rescue card; the bootSD archive in the NAS cold storage turns out to be Rockchip's
  SD-boot tooling only, with no Android or recovery image in it, so the patched partition 8 is what runs
  on that route (**D39**, findings Nov 12).
* The Nov 5 "62.8 GB full-eMMC snapshot" is **not** insurance: measured Nov 10 `analysis/gpt/disk.img`
  is zero except a protective-MBR remnant and the backup GPT, and `gpt_head.bin` is all zeros. The layout
  reference is `gpt_tail.bin` + the Nov 4 probe's LBA table; the content reference is the OEM packages.
* `docs/upstream.md` is the candidate register for upstream contributions - **nothing submitted yet**, and
  the verified Lineage/AOSP review and licensing rules are recorded there.
* Bluetooth is a deliberate second pass after first boot (`docs/decisions.md`, "Bluetooth route").
* No partition is ever resized, and uboot/trust/dtb/dtbo/vbmeta/RKLoader/security are never written by our
  tooling. Recovery is writable from Nov 20 under the owner's condition that MTC/mainboard flashing stays intact
  (**D80**), so it is written only as the D42-style patch and always rolled back to the byte-exact capture
  `1fdf5ea77fc6…` (**D11**/**D18**/**D19**). Restoring the unit's own firmware still means the OEM package or the
  stock backup (**D39**/**D40**).

## Status (Nov 18/19)

* Route 2 ran twice over TCP adb on Nov 18, both times writing only `boot` + `super` (**D62**), and both
  boots died before init started any service - one came up in a logo loop, one black. The owner restored
  stock Android 10 with their own OEM package, and `/data` survived. Measurement: `docs/findings.md`,
  "Nov 18 (late session)".
* The unit is reachable again (the blocker was the workstation's own `adb` daemon, not the unit), and the
  whole boot chain now verifies byte-exact against the Nov 17 capture: nine partitions hash as captured, so
  nothing beyond `boot` + `super` has ever been written (**D30** is measured, not assumed) and the patched
  recovery is not on the disk. Partition 7 *is* now the capture: L0 wrote the whole 33,554,432 B on Nov 19 and
  the payload padding mid-partition is gone (**D66** amendment, **D70**).
* The instrument for a failed boot is pstore console, not a serial port and not the panel, and it is now
  **proved on the unit**: step P0 ran Nov 19 and the warm reset left `console-ramoops-0` (97,430 B) and
  `pmsg-ramoops-0` (262,132 B) readable, the console record being whole-boot plain text that includes PID-1's
  own messages (**D69**). `# CONFIG_VT` and `# CONFIG_USER_NS` still close the screen-console and namespace
  routes (**D65**), and a record dies on a cold power cycle or on being read, so the reader must go first.
* The boot-only ladder (**D62**) ran in full on Nov 19: P0 proved the pstore console (**D69**), **L0**'s
  byte-identical repack booted stock Android 10 so our packing pipeline is trusted by the unit (**D70**), and all
  four L1 tokens booted unchanged with WiFi up (**D72**/**D73**). Partition 7 was then restored to the capture
  `4121b58f7759…` and verified again. The three validated logging tokens (`printk.devkmsg=on`, `loglevel=8`,
  `panic=12`) are combined for L2 and payload boots; the fatal-reboot-target token is excluded because it hands a
  dying init to u-boot and removes the adb route (**D73**). UART (**D63**) was declined again on Nov 19 ("Not
  yet"), so the case stays closed and u-boot's own stage remains unreadable. The owner's forwarded "blind plan"
  is checked line by line in `docs/blind-plan-corrections.md`.
* **L2 ran Nov 19 23:35 CET and left the unit silent; the owner restored it Nov 20 14:32 CET.** **L2** - Android
  14's static first-stage `init` inside the stock Android 10 ramdisk, built by `scripts/build_l2_ramdisk.sh`
  (`L2-ramdisk.gz` `6456104e82c0…`) and `tools/build_l2_boot.py` (`L2-init14-in-a10rd.img` `eaf9b7de30f9…`) - was
  written to `boot` as the whole partition, and after `adb reboot` the unit never answered: no TCP adb over ten
  minutes of probes, no ping reply. The owner forced the recovery menu and installed the OEM package from the
  external SD card with no `/data` wipe; recovery logged the install in `pmsg-ramoops-0` (success flag `1`,
  `time_total: 333` s, 3,124,451,704 B written). The unit boots stock Android 10 again with WiFi up and a
  rendering panel, and TCP adb came back by itself. Partition 7 now holds the package's image `b449aee98c01…`, so
  **that** capture is the rollback image from now on (**D76**); `misc` is still `909bdd979111…` and `super` still
  `535dac26946d…`. L2's failure has **no recorded cause**: the console record carries the *previous* boot's text
  and the recovery/flash boots overwrote it (**D77**), and `misc` never changed, so init never wrote a Boot
  Control Block - that boot hung instead of taking the recovery hand-off (**D74**). No further Android 14 image
  goes on the unit until a boot that keeps TCP adb is designed (**D75**).
* **Nov 20 late afternoon: one safe rung ran on the new base image.** `L5-diag-on-newbase.img` (`3de96f683b74…`)
  is the post-flash capture plus the three proven cmdline tokens (`printk.devkmsg=on`, `loglevel=8`, `panic=12`);
  it differs from the capture by 38 bytes, all in the cmdline field, booted Android 10 unchanged, and its record
  came back on a warm reboot - 183,405 B, 2,411 lines, no ratelimit notice, 832 `init:` lines. Partition 7 was
  restored to `b449aee98c01…` and re-verified. **D78** bounds what may be written next: none of the unit's USB
  ports drive adb, so recovery is not reachable as a shell from this workstation and TCP adb while Android 10
  runs is our only route - only content already proven to boot goes on the unit. **D79** raises the UART case:
  recovery starts `console /system/bin/sh` under `ro.debuggable=1`, so a UART probe would give an interactive
  shell that could read a failed boot's pstore record; the probe is still declined (**D63**), so Android 14 does
  not go back on the unit until either that channel opens or the owner pulls the record themselves (**D75**).
* `misc` is now permitted for a Boot Control Block write as a recovery hand-off (**D71**); it still hashes
  `909bdd979111…` exactly as captured, because nothing has been written there, and every other boot-chain
  partition stays forbidden.
* `tools/identity_gate.py` (**D67**) passes offline: stock content round-trips through our own tooling
  byte-for-byte, and a payload-fed image changes only `ramdisk_size`, the cmdline field, its own
  ramdisk and padding. Its **first run failed** and found a real defect - the byte-faithful rebuild used to
  zero-fill the OEM partition's tail. That tail is now decoded (**D68**): splash data, then a Rockchip
  resource image whose entries (`rk-kernel.dtb`, `logo.bmp`) declare SHA1 hashes that all verify, plus a
  second DTB copy; `second` is itself such a resource image, and the logo the boot path uses comes from it.
* The only writes since Nov 18 are L0's byte-identical repack of `boot`, the four L1 token images and **L2**'s
  image; each was the whole partition, nothing beyond `boot` + `super` has
  ever been touched, and `super` is never resized (**D18**/**D42**/**D43**/**D57**/**D62**/**D66**/**D70**/**D75**).

## Status (Nov 20 evening)

* **Partition 8 is patched and the unit is parked in the recovery menu.** The first patched recovery
  (`a4cf5533482e…`, 39,086,080 B) was written over the capture `1fdf5ea77fc6…` and read back byte-exact; partition 7
  stayed `b449aee98c01…` and `misc` stayed `909bdd979111…`. The stock recovery UI is alive on the patched image,
  which is the proof **D80**'s condition holds: the mainboard/MTC flashing path is intact. The automatic
  hand-back did not happen and no evidence was copied, because the script created `/cache/hu-evidence` *before*
  mounting `/cache`, so the directory vanished under the mount point - the first run wrote nothing and logged
  nothing (**D81**).
* **The rebuilt candidate is ready and verified offline**: `a14-work/recovery-evidence/recovery-evidence.img`
  39,088,128 B, sha256 `d64ebd22d6142554d0b788373889059e88d66c7b1eddb8453ccadbb3fb76094a` (superseded Nov 21 by
  `dfe61ba7b3d6…`, see "Status (Nov 21)"). Kernel, `second` and
  `recovery_dtbo` blobs are byte-identical to the capture, the header changes only `ramdisk_size` and the stored
  dtbo offset, the stock `init.recovery.rk30board.rc` content stays verbatim with one appended service, and the
  injected script hashes equal the repo file. Evidence: `analysis/recovery-evidence.txt`. Nothing was flashed in
  this pass.
* **The script is logic-tested offline before it goes on the unit again** (`scripts/smoke_recovery_evidence.sh`,
  9 scenarios, rc 0). Four defects came out of it: the evidence directory vanishing under the mount (above); a
  digest that could not be read comparing *equal* to another empty digest, so a restore was skipped and the risky
  image stayed in partition 7 - now an unreadable digest means "write the rollback anyway" with
  `restore-unverified.txt`; a restore request that could re-arm on every later recovery boot, retired now by a
  nonce-named done-marker because this busybox has no `rm`; and a reboot from recovery that can land back in the
  menu, since this unit enters recovery through the kernel's reboot-mode rather than `misc`.
* **The tool set is measured, not assumed.** The recovery ramdisk's busybox carries `awk cat cut date echo expr
  grep head md5sum mkdir mount reboot sed sha1sum sleep stat sync tail touch umount` and has **no** `dd`, `wc`,
  `cp`, `rm`, `ls`, `tr` or `sha256sum`. The same ramdisk ships `/system/bin` (toybox, plus `linker64` and `lib64`),
  so `sha256sum dd tr rm wc cp ls` are available there; the script resolves each tool to whichever exists and never
  asks busybox for something it lacks. Earlier versions asked for `dd`/`wc`/`tr`/`rm`/`sha256sum` and, worse, one
  ended with a bare `reboot` that reached the workstation's own `/usr/sbin/reboot` during an offline dry-run and
  rebooted the workstation (**D81**, findings "Nov 20 (evening)").
* **What is owed next, in order.** The owner cold-cycles the unit (that erases the RAM records - the record we
  want is the Android 10 boot's text, which would already be copied if the script ran); read
  `/cache/hu-evidence.log` and `/cache/hu-evidence/` over adb; decide from that log whether the service ran at all.
  Then the rebuilt image goes on partition 8 only after `dash -n` and `busybox ash -n` pass on the build host,
  since this workstation has no busybox ash. Partition 8 always rolls back to the capture `1fdf5ea77fc6…`.
  (Nov 21: the unit is back on Android 10 and the records are readable; the `dash`/`busybox ash` gate turned out
  to be the wrong dialect - recovery's shell is mksh, and the gate now runs on the unit. See "Status (Nov 21)".)

## Status (Nov 21)

* **Partition 8 is stock again, by itself.** A full read hashes `1fdf5ea77fc6…`, byte-identical to
  `a14-work/hu-stock-backup-refresh/recovery.bin`, zero differing bytes over the first 39,104,512 B. The reason is
  `/system/bin/install-recovery.sh`, init service `flash_recovery`, measured running at t=19.9 s in the boot's own
  console record: it `applypatch`es recovery from `/system/recovery-from-boot.p` with source
  `boot:27,406,336:ecb5315f…` and target `recovery:39,122,944:f75bcfb4…`, and both digests verify against the
  images we hold. So **while partition 7 holds an OEM Android 10 boot image, every Android 10 boot rewrites
  partition 8 back to stock** - the patched recovery is transient by design, and needs no manual rollback after a
  restore to stock Android 10. With an Android 14 payload on partition 7 the source digest mismatches, `applypatch`
  refuses, and the patched recovery persists: exactly when its console reader is needed (**D82**).
* **The record we wanted is saved and identified.** `/cache/hu-evidence/console-ramoops-0` (67,548 B) is the
  Android 10 boot's own console text - 1,093 lines, its last line `reboot: Restarting system with command
  'recovery'`, preceded by `init: Received sys.powerctl='reboot,recovery' from pid: 8684 (/system/bin/adbd)`, so
  the recovery entry was our adb-triggered reboot. `pmsg-ramoops-0` is 262,132 B. The 22:06 run stalled hashing
  the whole 96 MiB recovery partition and never reached the restore step, which is why the staged request was not
  acted on; partition 7 needed no restore anyway (`b449aee98c01…`, already equal to the rollback).
* **Digests are bounded reads now.** `dig()` pipes through `head -c` with a 64 MiB cap, so partition 7's digest
  stays exact and partition 8's is a first-64-MiB digest; the offline gate asserts the `p8 digest` line is reached
  and equals the capped read's sha256.
* **The dialect gate runs on the unit, not on the NAS.** The recovery ramdisk's `/sbin/sh` is MIRBSD KSH R40
  (static 32-bit ARM), and its busybox has no `ash` applet and no `--version`/`--list` handling - that is why
  `busybox-applets.txt` came back 0 bytes. Pushing `/sbin/sh` to `/data/local/tmp/hush` and running `hush -n` on
  the candidate script gives rc 0 on the unit. So `dash -n`/`busybox ash -n` were the wrong gate, and the blocked
  build host is no longer needed for this step.
* **Current candidate, nothing flashed**: `a14-work/recovery-evidence/recovery-evidence.img` 39,088,128 B, sha256
  `dfe61ba7b3d6e0344dc5831c49e219fb157baaac73ad4812655cbdac761fb199`, injecting `scripts/hu_recovery_evidence.sh`
  (`646c0a709742a53116bdaa7de1bbf3ef7c5a96e063adcb20548371c398ed3747`, byte-identical). Kernel, `second` and
  `recovery_dtbo` blobs byte-identical to the capture; stock rc verbatim plus one appended service; offline gate
  `scripts/smoke_recovery_evidence.sh` (`b83e36cdc8a6…`) passes nine scenarios. Evidence:
  `analysis/recovery-evidence.txt`.
