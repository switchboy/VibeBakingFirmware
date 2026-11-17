# Installing Android 14 with the unit's own `update.zip` flow

The install path is the one the head unit already has: an `update.zip` at the root of a USB/SD stick,
installed by the **stock** recovery using the **stock** `update-binary`. We build the payload files
that binary understands and reuse its own script vocabulary - nothing is invented, no partition is
resized, and the recovery, bootloader and mainboard firmware are never written (**D18**).

## Why we do not touch recovery or the bootloader

The PX6 sits as a card on a mainboard with its own MCU firmware. The community reports that this unit
has no custom recovery, and the most likely reason is that the stock recovery is the only thing able
to flash that mainboard firmware: the stock package's own `write_raw_loader_image()` step runs in it,
with `/tmp/RKLoader.bin` as the loader image. We cannot verify that a *custom* recovery would boot,
show a prompt, and read touch or button input on this board - and if it does not, the unit is a brick.
So our recovery image is built and verified but **not flashed**; it is for later, once Android 14
boots and we know the unit is alive.

Consequently the payload's updater-script omits everything the stock script does to the boot chain:
no `uboot.img`, no `trust.img`, no `dtbo.img`, no `RKLoader.bin`, no `write_raw_loader_image()`, and
no wipe of `/dev/block/by-name/security`. Those files are copied into the zip byte-identical from the
stock package so a diff of the package stays honest, but the script never writes them.

## What the payload is

`scripts/build_hu_package.sh <lineage-tree> "extracted update.zip" <out-zip>` produces a zip with
the stock layout:

```
META-INF/com/google/android/updater-script   ours, stock vocabulary only
META-INF/com/google/android/update-binary    the stock binary, unmodified
dynamic_partitions_op_list                   our Android 14 layout, same super size and group size
<part>.transfer.list / <part>.new.dat.br / <part>.patch.dat   system vendor product system_ext odm
boot.img                                     Android 14 kernel + ramdisk + vendor DTB + RSCE logo
uboot.img trust.img dtbo.img RKLoader.bin    stock bytes, present but never written
```

* `dynamic_partitions_op_list` recreates the logical partitions inside `/dev/block/by-name/super`.
  The GPT is untouched (**D11**): p14 stays 3,263,168,512 B, the group stays 3,258,974,208 B. Only
  the partition list and sizes change, and Android 14 adds `system_ext`, which stock did not have.
* `.patch.dat` is empty and each transfer list is one `flash` command: an unconditional full write,
  exactly like the stock package.
* Logical content is 2,299,031,552 B inside a 3,258,974,208 B group, so there is ~915 MiB of spare
  (Nov 8 rebuilt pass: system 1,012,834,304 / vendor 444,424,192 / product 456,159,232 / system_ext
  384,802,816 / odm 811,008 B, block-multiple resizes, no partition resize - **D19**/**D11**).
 * **The payload to try first is the signed zip**: store zip 945,046,226 B, sha256
   `b81c50cc3eb07b8b0ba5a3ab7f518d8ba2a0339801608c892bbd640e52d04407`, with
   SignApk's PKCS#7 signature in the EOCD comment (prefix `signed by SignApk\0`, cert `a40da80a…` = the
   AOSP testkey) added by `scripts/sign_hu_package.sh` using the tree's own `signapk.jar -w` and its
   prebuilt JDK. Recovery verifies that comment *before* running anything in the package, so a rejected
   zip writes no partition at all - the attempt is free. The caveat we measured (**D25**): both OEM
   packages are signed with HCT's own cert `cf2ab3…`, and `/system/etc/security/otacerts.zip` in both
   stock system images contains only that cert. If this recovery bundle is only that cert, our testkey
   signature is rejected again and the fallback below is the route.
 * **Fallback images**, for `scripts/flash_from_android.sh` from the Android 10 root shell. Measured on
   the Nov 16 23:42 pass (shape A staging, `SHAPE=a10 SKIP_DIST=1`), NAS
   `lineage21s/out/target/product/rk3399/`: `super.img` (Android sparse) 2,400,917,568 B sha256
   `bb79874ce476f33ac9c7afa1934a3719b861685c04b0f253711e8c27d6a674bc`, `vendor.img` 556,072,960 B
   `7a5ce939be0f893c0cf00ca0c55ded5ecfc9f27fca43348fe7ae4a705ff4e8c2`, `boot.img` 28,012,544 B
   `9605fb9fe63e815fa7fb71f41f3f9ef33b4c1672f6240fe5b3ebc75df0788f26` (unchanged since Nov 15),
   `recovery.img` 39,905,280 B `728d72ef1cae1353a47c7008b515b9861be8e5c6b2de6872d7ecbbf4646ead1a`, and
   the stale Nov 8 `lineage_rk3399-ota.zip` 1,012,957,295 B `931bbb45cff126ccc91b9133dcf3d4a27c0b208edeea9af02c29db748e4ab7ac`
   (`m dist` stays skipped, SSData is tight, so the OTA zip is NOT this pass's output). Logical content
   is system 1,012,871,168 + vendor 556,072,960 + product 456,159,232 + system_ext 384,802,816 +
   odm 811,008 = **2,410,717,184 B** inside the unchanged `hct_dynamic_partitions` group of
   3,258,974,208 B, so **848,257,024 B (~809 MiB) spare** - no partition resize (**D19**/**D11**),
   super device size still 3,263,168,512 B (**D18**). `lpdump` on the flattened container confirms the
   extents (unit = 512 B sectors): system 1,978,264 / vendor 1,086,080 / product 890,936 /
   system_ext 751,568 / odm 1,584 sectors = 4,708,432 sectors, i.e. exactly the five image sizes above,
   and the group name and maximum are still `hct_dynamic_partitions` / 3,258,974,208 B.
   `scripts/check_super.py` (run Nov 17, scratch pointed at the roomy archive volume because SSData is
   tight) verifies each partition byte-for-byte inside the container and reads its ext4 super block:
   `embedded_matches=True`, `size_matches_extent=True`, `ext4_magic_offset=1080`,
   `debugfs_parses=True` for all five, `ALL LOGICAL PARTITIONS VERIFIED: True`. Its own bookkeeping is
   one region larger, because the first partition starts after the super metadata header (system is at
   offset 1,048,576 = sector 2048): it reports `used inside super: 2,413,584,384 ; spare 849,584,128
   (810 MiB)` and a group spare of 845,389,824 B - the same headroom counted with the metadata region.
 * **The shape-A payload pair actually staged** (Nov 17, `a14-work/a14chk-shapeA/`):
   `boot-a10k-a14rd.img` 28,233,728 B sha256 `3cf40129…` plus `raw-super.img` 3,263,168,512 B sha256
   `d81f913aee9162d7cb948db63528200b94ba6e6c6a50f78795174ce5bf19fdb8` - the flattened container
   (`out/host/linux-x86/bin/simg2img` on `super.img`; the file is exactly the partition size, never
   larger). `tools/payload_coupling_check.py` on that pair: kernel banner `4.19.111+`, layout
   kernel 25,671,688 B @2048 / ramdisk 1,631,866 B @25,675,776 / `second` 924,672 B @27,308,032 with the
   DTB at +2048 (size 152,425), header `dtb_size 0`, 21 `.ko` in `vendor.img` at vermagic
   `4.19.101+`/`4.19.111+`/`4.4.167`, the 14 `hu_insmod.sh` modules all present with correct vermagic,
   and the restored chain present (`libion.so`, `libaudioroute.so`, `libaudioutils.so`,
   `libspeexresampler.so`, `libprotobuf-cpp-lite.so`, `libstagefright_softomx_plugin.so`, the
   allocator/mapper impls, `gps.default.so`, `audio.primary.rk30board.so`, `gralloc.rk30board.so`) in
   both arches - PASS, "boot image and vendor partition in this payload agree". Recovery stays untouched
   in both routes, which is what keeps the stock package installable as the rollback.

## Pre-flight

1. `scripts/verify_artifacts.sh <tree>` must pass: `VENDOR/` + `vendor.map`, the injected vendor
   libraries, super layout, VINTF parsing, boot header, the kernel/module/manifest coupling gate, the
   recovery installer and the OTA zip. **The Nov 17 run exits 1 with exactly two `!` lines, and both
   are about the *raw* `boot.img` the build produces, not about the payload we flash**: its ramdisk has
   no `/first_stage_ramdisk/fstab.rk30board` (**D34**), and `payload_coupling_check.py` exiting
   non-zero on that is what prints the second line ("boot image and vendor partition disagree"). The
   flashed payload is the repacked pair in `a14-work/a14chk-shapeA/` - `boot-a10k-a14rd.img` carries
   the fstab plus the OEM Android 10 kernel and DTB-bearing `second` stage, and the same gate PASSes on
   it ("boot image and vendor partition in this payload agree"). Everything else in the Nov 16 pass is
   green: dropped-destination check, link closure, ABI check, the 14 `hu_insmod.sh` modules, the
   injected libs in both arches, the GPS/audio/gralloc criterion files, manifest `target-level=4` with
   no `<kernel>` tag, the three check_vintf logs, and recovery's `update_engine_sideload`. Two things
   worth knowing: the super-layout section only runs after `scripts/check_super.py` stopped opening the
   dist zip eagerly (`SKIP_DIST=1` means there is no `out/dist`, so the whole comparison used to crash
   silently), and the stale Nov 8 `lineage_rk3399-ota.zip` in the OTA section is not this pass's output.
   `docs/findings.md` records the numbers for each section.
2. Check the payload, then re-verify the same sha on the stick copy - a corrupt stick copy is the one
   thing a pre-flash check catches: `unzip -tqq out-hu/update.zip` is clean, `unzip -l` shows the payload
   entries plus SignApk's `META-INF/com/android/otacert`, and
   `python3 tools/zip_comment_sig.py out-hu/update.zip` reports a comment signed by cert `a40da80a…`.
   The updater-script still has zero uboot/trust/dtbo/RKLoader/loader/security/recovery writes.
3. Format the stick FAT32 and put our signed zip at the root as `update.zip`. Keep the stock packages in
   `backup/`, named by Android version so they cannot be mislabelled: `backup/a10-update.zip` (Android 10,
   1,203,718,969 B, sha256 `dd3e2ac0…`, Android 10 test-keys 2021) and `backup/a11-update.zip`
   (Android 11, 1,477,122,869 B, sha256 `50775dba…`, build.prop `RQ3A.210705.001`). Rollback = copy
   `backup/a10-update.zip` to the root as `update.zip` and install it; recovery still accepts it because
   it is signed with the cert recovery trusts.

## Install, route 1: the signed zip through recovery

1. Stick in before boot (or the power-button sequence - see "Getting into the recovery"), enter recovery,
   read the version line it prints, then install `update.zip`.
2. Watch the verification line: `E:footer is wrong` / `E:Signature verification failed` / `E:error: 21`
   means the signature check rejected the package - nothing is written, and route 2 applies. `E3004` is
   the device assert, `E2001` is a partition write failure.
3. If it installs, reboot and read the probe report off the stick (see "First boot"). The script recreates
   the logical partitions, writes system / vendor / product / system_ext / odm and `boot.img`, and wipes the
   first 8 MiB of `userdata` and `cache` so Android 14 formats `/data` fresh (**D10**).

## Install, route 2: raw images from Android 11 (**D25**)

Use this if recovery rejects the signed zip. The unit still runs its own firmware with a root shell over
TCP adb (**D28**; measured Nov 9: Android 10 `QQ2A.200305.004.A1`, not Android 11 as earlier docs assumed),
and recovery is deliberately left untouched so it keeps working as the rollback. `/data` is mounted
read-write by the running firmware, so it is not wiped here - recovery's own wipe data/factory reset does
that cleanly afterwards (**D10**).

1. Put `hu14/super.img`, `hu14/boot.img`, `hu14/flash.sh` (a copy of `scripts/flash_from_android.sh`) and
   `hu14/sha256.txt` (plain file names) on the stick; re-verify the manifest on the stick. On this unit
   `/mnt/udisk` is not mounted at all, so the equivalent is to stage the same four files on the
   workstation (`/tmp/hu/stage/hu14/`) and `adb push` them into `/data/local/tmp/hu14/`, then re-verify
   `sha256sum -c` **on the unit** before writing.
2. Get a root shell. The ROM's own su is blocked (`/system/xbin/su` exists but returns "Permission
   denied", no Magisk), so use adb - and on this unit adb only comes over the LAN (**D28**), not over a
   cable: every HU socket is host-mode, nothing enumerates, and the firmware has no developer options.
   Enter **`adbon`** in the HU's factory-settings dialog (instead of `126`) - that sets
   `persist.internet_adb_enable=1`, and the OEM init then opens TCP adb on port 5555. From the workstation:

   ```
   adb connect 192.168.1.120:5555
   adb root                                   # uid 0, context u:r:su:s0, no auth prompt
   adb -s 192.168.1.120:5555 shell id
   adb -s 192.168.1.120:5555 push hu14 /data/local/tmp/   # or push the four files individually
   adb -s 192.168.1.120:5555 shell "sync; STICK=/data/local/tmp sh /data/local/tmp/hu14/flash.sh"
   ```

   With no stick mounted, `STICK=/data/local/tmp` is what the script expects (`SRC=$STICK/hu14`,
   `BACKUP=$STICK/hu14-backup`) - backups then land in userdata, which survives a `super` rewrite. Pull
   them back to the workstation with `adb pull` **before** writing anything; `super.img` is 2.27 GB and
   pushes at ~3.2 MB/s over TCP, so budget ~11 minutes each way. The script verifies the images against
   `sha256.txt`, backs up the head and tail of `super` plus the current `boot` partition, then `dd`s
   `super.img` to `/dev/block/by-name/super` (Android 14's system/vendor/product/system_ext/odm plus its
   dynamic-partition metadata, all inside super) and `boot.img` to `/dev/block/by-name/boot`. Two
   partitions only: no recovery, uboot, trust, dtbo, RKLoader, logo, security or GPT write, no resize
   (**D11**/**D19**). Log: `$SRC/hu14-flash.log`.
   Two script bugs were found by running it on Nov 9 and both are fixed in
   `scripts/flash_from_android.sh`: Android's mksh does 32-bit arithmetic, so a partition size above
   2 GiB wraps negative and the size guard aborted a valid image (now compared in awk); and the tail
   backup used a byte value as `dd skip=` with `bs=4096`, which is a *block* count (`Can't skip`) - the
   correct skip is `792576` blocks. Read `docs/findings.md`, "Flash attempt Nov 9/10", before flashing.
3. Reboot into recovery, run **wipe data/factory reset**, reboot with the stick still in; the auto-probe
   writes `hu-probe-<ts>.md` to the stick (`/data/local/tmp/hu-probe-<ts>.md` and `/dev/kmsg` fallbacks).
4. If it does not boot, and the recovery menu cannot be reached (Nov 9: no button combo the owner tried
   reaches it), the rollback must be **blind** (**D29**): either a serial console (`console=ttyFIQ0`,
   115200 8N1, 3.3 V) with a root shell that `dd`s the OEM `super`/`boot` back, or a bootable SD card that
   the untouched u-boot flashes (`rkimg_bootdev=if mmc dev 1 && rkimgtest mmc 1`, `sdfwupdate`) - which
   touches the loader/IDB, so it stays gated on verifying that `fw_update=2` skips that write. The card
   goes in the **sdmmc** slot: `dwmmc@fe320000` = Android `sdcard1` = u-boot `mmc 1`, not the recovery
   slot `dwmmc@fe310000` = `sdcard2`.

## Install, route 3: the card installer, size + digest manifest (**D43**)

This is the route the owner made the safety net (**D47**). The patched recovery starts
`scripts/hu_recovery_install.sh` (via `scripts/hu_recovery_init_append.rc`); without a flag on a card it
prints one line and exits 0, so it behaves exactly like the stock recovery. With the flag it refuses to
write unless the card's `hu-checksums.txt` declares a size that matches the file **and** a digest line for
an applet this busybox actually has, writes only `boot` + `super` (**D18**/**D19**), wipes `/data` with the
stock Android 10 `make_f2fs.oem` (**D10**), and hashes what it read back before declaring success.

1. `SHAPE=a10 scripts/stage_hu_card.sh <mounted-card-dir>` puts in the card root: `super-a14.img`,
   `boot-a14.img`, `hu-install.sh` (a readable copy of the installer), `update.zip` (route 1's package, so
   recovery can be driven by hand too), `hu-install.flag` and `hu-checksums.txt`. The card needs ~3.3 GiB
   free. Measured Nov 17 as a **dry run into a plain directory** - `a14-work/hucheck-card-dryrun/`, no card
   mounted, nothing connected to the unit - rc=0 with every line verified by its own read-back.
2. Shape A's manifest as staged, `size <bytes> <4096 B blocks> <name>` then one line per digest the
   staging host can compute:
   * `size 3263168512 796672 super-a14.img`; sha256
     `d81f913aee9162d7cb948db63528200b94ba6e6c6a50f78795174ce5bf19fdb8`, sha1
     `ae20fb2cfe8178793bed370b6f148ddca9d588ce`, md5 `dc81744b66d70f31d0468c63adc670c2`
   * `size 28233728 6893 boot-a14.img`; sha256
     `3cf4012980d0a824c37ed3f24982a9c7e50d2c8c8497030be139e1184a647375`, sha1
     `9dc876e69528ba4f563c626f518e6e75dde72a1a`, md5 `679a750ef09f38628e02bd2d7f16bb9c`
   Both are multiples of 4096, so `dd bs=4096` leaves no tail unwritten; both fit their partitions
   (`super` 3,263,168,512 B, `boot` 33,554,432 B).
3. The installer's logic is proven offline first: `scripts/smoke_recovery_installer.sh` now runs per shape
   (`SHAPE=a10` default = shape A's 28,233,728 B boot, `SHAPE=a11` = shape B's 32,796,672 B boot) and
   passes 8/8 scenarios in both, with the ~7 GiB `TMPDIR` the harness needs. Route 1's `update.zip` remains
   the fallback: its `updater-script` dd's the same two files from `/external_sd` **without** checking
   digests, which is why this route, not that one, is preferred now.

## Nov 9 attempt: route 2 ran, the write succeeded, Android 14 did not bring up the panel

The full log with timestamps and every captured command is in `docs/findings.md`, "Flash attempt Nov 9/10".
The operator-relevant consequences:

* `adbon` in the factory-settings dialog opened TCP adb and `adb root` gave uid 0 - route 2 works exactly
  as written above, and the images were verified on the unit before writing.
* The write itself completed: `super` 2,275,747,780 B at 64 MB/s, `boot` 32,796,672 B at 33 MB/s. Only
  those two partitions.
* After it: **black screen, no boot animation, no OEM logo**, WiFi gone (`No route to host`), TCP adb dead,
  no recovery menu. So the transport died with the old OS - Android 14 cannot recover Android 10's Wi-Fi
  credentials and `persist.internet_adb_enable=1` lives in `/data`, which Android 14 formats fresh (**D10**).
  A shell on first boot therefore cannot be assumed; if one appears it comes from the stick copy or
  `/dev/kmsg`, not from TCP adb.
* Nothing that could brick the unit was written (`uboot`, `trust`, `dtb`, `dtbo`, `recovery`, `vbmeta`,
  loader, GPT all untouched), so the boot chain is intact and the unit is recoverable by a blind path.
* Do not flash a second payload without a serial console reading first (**D30**; defect list **D32**,
  generation mismatch **D33**, missing first-stage fstab **D34**). Primary cause, measured: our payload has
  **no fstab source** for first-stage mount - Android 14 init wants `/proc/device-tree/firmware/android/fstab`
  or `/first_stage_ramdisk/fstab.rk30board` (it matches `androidboot.hardware=rk30board`), our DTB has no
  `fstab` node, the untouched A10 `dtbo` overlay (803 B, `28a07d49…`) adds `vbmeta`/`fstab` children marked
  `status = "disabled"`, and our ramdisk contains no `first_stage_ramdisk/` and no `fstab*` file. So
  `failed to read default fstab for first stage mount` -> `/system` never mounted -> no display, no WiFi, no
  adbd. Second-order: our kernel/DTB are the vendor **A11** pair (`ec3b6631…` / `530b8412…`) on the unit's
  **A10**-era chain (the vendor's A11 script also writes `boot`, `trust`, `uboot`, `logo`, `dtbo` and the
  loader; the A11 overlay `607 B` `ec0ae97c…` lacks the disable-`vbmeta`/`fstab` fragment). `mali_kbase.ko`
  (`vermagic=4.4.167`) is cleanup, not the cause; AVB/vbmeta, uboot/trust mismatch, partition layout and
  ext4-vs-fstab are ruled out. Console reading order: init's fstab messages first
  (`First stage mount skipped (missing/incompatible/empty fstab in device tree)`,
  `failed to read default fstab for first stage mount`), then which DTB u-boot used (`Found DTB in <part>` vs
  `dtb size`/`dtb addr`), whether the `dtbo` overlay applied, then kernel panel/timing messages, then init
  stage 2 and SurfaceFlinger. Which boot image the card/recovery flow actually writes is measured Nov 15:
  `scripts/stage_hu_card.sh:36`, `scripts/stage_a14_payload.sh:21`,
  `scripts/build_recovery_fallback_zip.sh:72` and the recovery installer all take
  **`a14chk/a14-boot-fixed.img`** (kernel payload 30,455,816 B = the vendor **Android 11** kernel
  `4.19.193 #24`, sha `933e2ecc…`). Its partner is `a14chk/raw-super.img` (3,263,168,512 B, sha
  `d4b4990931cc…`), and the coupling gate was re-measured Nov 17 against the vendor partition carved
  out of *that* container (extents 0..840847 in 512 B sectors = 430,514,176 B at byte offset
  1,013,972,992, `dd bs=4096 skip=247552 count=105106`): kernel `4.19.193`, 17 `.ko` at vermagic `4.19.193` + `4.4.167`, all 14
  `hu_insmod.sh` modules present at the kernel's own version, the four injected libraries in both
  arches, the GPS HAL files present, manifest `version=8.0 target-level=5` **with**
  `<kernel target-level="5">` - PASS. That is **shape B**, the fallback (**D46**). One caveat, stated
  plainly: that container is the Nov 11 build, so it does not carry what Nov 16 restored (**D52**) -
  it has no `lib*/libprotobuf-cpp-lite.so` (only the versioned `-3.9.1`/`-21.12` sonames), no
  `lib*/libstagefright_softomx_plugin.so` and no `android.hardware.power@1.0-service`. Its graphics
  path is self-contained and differs from shape A's: Android 14's own `allocator@4.0-impl-midgard` +
  `mapper@4.0-impl-midgard` + `allocator@4.0-service` (+ rc), so libui resolves at Gralloc4 instead of
  through the passthrough wrappers over the staged `gralloc.rk30board.so`, and it does carry
  `lib*/libgatekeeper.so`, which shape A declares away. Shape B is coherent as kernel + modules +
  manifest, but it is not D52-current: it is offered only after a `SHAPE=a11` packaging pass rebuilds
  its super. Measured Nov 17 with shape B's own criterion list (`scripts/verify_artifacts.sh` passes
  `lib*/hw/gralloc.default.so` + the midgard 4.0 mapper/allocator impls + `allocator@4.0-service` for
  that shape, since the Android 11 vendor tree ships those as staged blobs and Android 14 defines no
  install rule for the `-impl-midgard` names): every criterion file is present and the only two failures
  are `lib*/libprotobuf-cpp-lite.so` and `lib*/libstagefright_softomx_plugin.so` - the sonames D52 added
  after Nov 11. A `SHAPE=a11` pass carries the same shape-independent `PRODUCT_PACKAGES` blocks, so it
closes both and the whole gate passes - and that pass ran on Nov 17. Shape B's current artifacts on the
NAS: `super.img` 2,277,550,048 B sha `2a1246aaf055acacf4cddb8e7ce46e4064e29af59c214d831acfc470c4edcc51`,
`vendor.img` 432,275,456 B sha `90ed4009ce960e1f344b05a3e20e1413d6af90e5091d629c09ee4282dd8cb8cd`,
`system.img` 1,012,871,168 B, `product.img` 456,159,232 B, raw `boot.img` 32,796,672 B sha
`cf05255148b85a76d6a8f4caa235555adf029828c70593b344bca000341237c1`, `recovery.img` 44,689,408 B sha
`eb0f86b37bf731f3d8d7439fdb67b68f67b6564ed6bc5af2ac9f85363924b758`. The raw `boot.img` still lacks the
first-stage fstab (**D34**), so shape B's flashable boot is the repacked image
`/srv/dev-disk-by-label-SSData/aospbuild/hu-a11-repack/a14-fixed.img`, 32,796,672 B sha
`55be70ab423c66c6c4d33abaf3628d59eebf0f39d4c884ec4253abcd85921bc0` - kernel `4.19.193 #24`, the DTB
(157,962 B) inside `second`, and `first_stage_ramdisk/fstab.rk30board` (4,190 B, five logical
`first_stage_mount` rows). Gating it: `SHAPE=a11 BOOT=<that image> scripts/verify_artifacts.sh` says
**`PASS: boot image and vendor partition in this payload agree`** and **`VERDICT: flashable build =
yes`** (`lib64/libhwbinder.so` is declared absent, **D56**; the stale Nov 8 OTA zip and
`vendor_diff.py`'s "only the intended changes = False" line about build-owned `usb_modeswitch.d` paths
are informational, not gates). Shape B is therefore a real fallback now, but shape A stays primary
(**D46**), and neither is flashed until the owner's gate (**D47**).

  **Shape A** (the primary, Nov 15) ships `a14-work/a14chk-shapeA/boot-a10k-a14rd.img`: 28,233,728 B,
  sha `3cf4012980d0a824c37ed3f24982a9c7e50d2c8c8497030be139e1184a647375`, kernel payload 25,671,688 B = the
  OEM **Android 10** kernel `4.19.111+ #190`, our Android 14 first-stage ramdisk with
  `first_stage_ramdisk/fstab.rk30board` (4,190 B), the OEM `second` stage 924,672 B carrying the HCT DTB
  (`d0 0d fe ed` at 27,310,080, size 152,425), header v2 with `dtb_size 0`. It pairs with the stock
  `4.19.111+` module set (the 19 `.ko` in `a14-work/hu-stock-backup/vendor-modules/`) and with a vendor
  manifest at `target-level="4"` - and **no `<kernel>` tag** is added, because libvintf only checks kernel
  compatibility when the manifest declares one (**D46**).

  The earlier `a14chk/boot-a10k-a14rd.img` (sha head `455a9ac8…`, 28,231,292 B) is **malformed and unusable**:
  `rebuild_boot_with_fstab.sh` sliced the components at the 1660-byte header size instead of at the page
  boundary, so its `second` stage landed at 27,309,144 while a boot loader computes 27,308,032 and would read
  padding instead of the DTB (**D38**). It is kept as `a14chk/boot-a10k-a14rd.img.stale-misplaced-second` for
  the record; regenerate with the fixed script rather than reusing it. Do **not** flash the OEM `boot-a10.img`
  unchanged: its ramdisk fstab has no `system_ext`, which Android 14 needs. Writing either chain is gated on
  the offline gate set (**D47**), with the stock backup and rescue card staged first.

## Getting into the recovery

Three routes are reported for PX6/RK3399 head units; they are not guesses, they are what owners did:

* **Stick in before boot.** `update.zip` at the root of a FAT32 USB stick or SD card, inserted before
  powering on: the unit offers the update, and on units that no longer show the menu the recovery menu
  comes back with the card inserted. Iker Gomez (Dasaita forum, 7 Jul 2022) lists it as the recovery
  recovery method: "on a FAT32 formatted SDcard just copy the A10 OTA file (update.zip) and reboot with
  the Sdcard inserted... Some guys reported that after inserting the SDCARD and booting... the recovery
  menu was again accessible". This is the owner's route and the one our payload is built for.
* **Power-button sequence.** Long press the power key, wait for the unit to flash about five times,
  release and press again - that reached a recovery with an "install update" entry on a PX6 Android 10
  unit (alfondehesa, XDA, 22 Jul 2020). Units with no hardware buttons only have the reset key: holding
  it ~10 s did *not* bring the menu back on the unit that went black-screen in the Dasaita thread.
* **The menu tells its own version.** The third line of the recovery menu prints the build, so before
  flashing anything, read that line and check the package is something that recovery can apply.

**Measured on our unit (Nov 9):** none of these reached the menu. With the payload already written, the
owner power-cycled the unit and tried button combos including the reset pinhole - no recovery menu, no
logo, no animation, screen fully black. So treat recovery as **unreachable** here and plan the blind
rollback (**D29**) instead of counting on it; the SD-card-before-boot trick could not be evaluated because
there was no display to read an offer on.

The stock `update-binary` is not a plain AOSP updater: it carries Rockchip's USB OTA module
(`CRKUsbComm`, `emmc_point`, `/mnt/scratch`, `drmboot.ko`) and the loader step ("Start to update loader
from update.zip"), which is why a stick at the root of a card is picked up at all. That is also the
reason it must stay byte-for-byte the stock binary (**D18**).

**The known hazard on this platform.** Dasaita's own rule is that an OTA file must match the Android
major version already installed - "you can NEVER upgrade the Android 10 to Android 11 by means of OTA
files.... you can corrupt your boot system". In that thread a unit that was flashed with an Android 11
package ended stuck at the logo, and a further package left it black-screen with no recovery. Those
packages write `uboot.img`, `trust.img`, `dtbo.img` and the loader (`write_raw_loader_image()`), i.e. a
boot chain from a different variant. Our payload deliberately never writes those (see above), so the
observed brick is not our path - but we are still crossing a major version through a recovery built for
Android 10, which no offline check can prove. Before the first flash: read the recovery menu's version
line, and confirm the route on XDA/Dasaita for this exact unit.

Then: select the update package, let it run, and reboot. The script asserts
`ro.product.device == "rk3399"`, recreates the logical partitions, writes system / vendor / product /
system_ext / odm, writes `boot.img`, and wipes the first 8 MiB of `userdata` and `cache` so Android 14
formats `/data` fresh (Android 10's data, vold metadata and app data are not readable by Android 14 -
factory settings, accepted for v1 per **D10**).

Watch for `E2001`/`E3004` in the recovery output: `E3004` means the device assert failed, `E2001`
means a partition write failed. `dynamic_partitions_op_list` does not rename anything: it is the stock
vocabulary - `remove scratch`, `remove_all_groups`, then `add_group hct_dynamic_partitions 3258974208`,
`add` and `resize` per partition, with `system_ext` as a fifth partition. If `update_dynamic_partitions`
refuses that op list, the updater aborts before any image is written - a safe failure that tells us the
stock updater cannot carry Android 14's layout, which is then a decision point, not a brick.

## First boot

1. Boot Android 14. The build ships **no terminal and no su**, so the report comes to you without a
   shell: `/system/etc/init/hu_probe.rc` runs `/system/bin/hu_probe.sh` as root when boot completes and
   waits ~2 min for the stick to mount. The dump then lands in three places - `/mnt/udisk/hu-probe-<ts>.md`
   (the stick that carried `update.zip`, read it on the workstation), `/data/local/tmp/hu-probe-<ts>.md`
   (pullable with `adb pull`, no root needed), and stdout into `/dev/kmsg` (`dmesg` over adb or the FIQ
   serial console, `console=ttyFIQ0`). USB adb needs no auth prompt once our key is in `/data/adb/adb_keys`
   (the probe injects `/system/etc/hu_adb_key.pub` at boot; `ro.adb.secure` stays 1), and `adb root` works
   because `ro.debuggable=1`. If you get a shell and WiFi is up, run
   `sh /system/bin/hu_probe.sh http://<workstation>:9000` (workstation side `nc -l 9000 > report.md`) or
   `setprop persist.hu.probe.url http://<workstation>:9000/` before a reboot. The report covers boot, WiFi
   (`wlan0` under `fe3c0000.usb`, `iw reg`), Bluetooth (expected empty in v1 - D24), touch/buttons
   (`getevent -L`, `/dev/mtc-*`), CANBUS (`/dev/mtc-car`, `HCTCanBus`), audio (`audio.primary.rk30board.so`,
   `/proc/asound/cards`) and the error/warning logcat lines per subsystem, plus `CANNOT LINK` lines from
   `dmesg` (the gocsdk/sdsdk ABI gap, D24).
2. Judge the hardware before anything else: display, audio/AMP, tuner, CAN/MTC, AV-in, GPS, Bluetooth,
   wired CarPlay/AA. If the unit boots, the recovery/bootloader were never touched and everything
   below is reversible.
3. Only after that: consider writing our own recovery (a separate decision, needing proof the board
   can drive it), and later updates go through `docs/ota.md`.

## Rollback

Rollback package choice (Nov 9): the vendor's 2025 Android 10 rebuild -
`diatsia fw/update(1).zip`, 1,285,817,036 B, sha256 `31bb492ab6036dd10a9dc9c33be900af23499eef049a260bf267b166f239db4c`,
release-keys, signed by the same cert the recovery trusts - is newer than the 2021 package and installs
through the untouched stock recovery. Prefer it if a rollback is ever needed; put it on the stick as
`backup/a10-2025-update.zip`. Identity of every package on disk: `docs/findings.md`, "OEM reference
packages on disk".

Owner's decision (Nov 6): no rollback tooling. Flash the **stock Android 10 `update.zip`** the same
way - root of the stick, stock recovery - and it recreates the stock logical partitions
(`rockchip_dynamic_partitions`, no `system_ext`), writes the stock boot/trust/uboot/dtbo and re-runs its
own loader step. The unit returns to Android 10 at factory settings. Nothing in this repo rebuilds an
Android 10 super or dumps partitions; `tools/reassemble.py` stays only because it is how the stock
payload was decoded in `docs/firmware-analysis.md`.

**Nov 10 revision.** That plan needs the recovery menu, and the menu is unreachable on this unit, so the
rollback is now blind (**D29**). The payload to write is rebuilt from the vendor's April 2025 Android 10
package (**D31**), not from a dump: `super-a10.img` 3,263,168,512 B sha `30da961c…` and `boot-a10.img`
27,406,336 B sha `04a43ea9…`, both in the NAS archive
`/srv/50911774-19fb-46b6-bc9e-8cf81623d044/aospbuild-archive/vibe-rescue/`. Serial-console `dd` of those
two files restores Android 10; the bootable SD card (**D31**) carries the same two files plus a rescue
initramfs that `dd`s them, so the restore also works with no shell at all. The stock packages stay on the
stick in `backup/` for the day a menu does appear. **The 62.8 GB "full-eMMC snapshot" is not insurance** -
measured Nov 10 it is zero except the backup GPT (`docs/findings.md`), which is why the payload had to be
rebuilt; `analysis/gpt/gpt_tail.bin` plus the Nov 4 probe's LBA table remain the layout reference. The
extraction work is done: `brotli` on the `.new.dat.br` payloads, `tools/reassemble.py` for the transfer
lists, `lpmake` for the super, verified with `lpdump` + `debugfs`.

**Nov 17 refresh - partition 7's rollback image is now the refreshed capture.** The live unit's boot
partition changed when the owner re-flashed the OEM package on Nov 13 (**D39**): the refreshed
`hu-stock-backup-refresh/boot.bin` is 33,554,432 B sha256 `4121b58f77598d73b1b7958c36d1c5a81c8b82ba176cce9f6863b67992ce5b3d`, and it differs from the Nov 11 `3d2741f0…` capture by 1,625,326 bytes that all
sit in boot's `second` stage - the kernel bytes, the first-stage ramdisk and the DTB inside `second`
(157,962 B, sha `530b84129eb0`) are identical, only the blob before the DTB differs (**D38** names that
stage as the board's display description). Roll back partition 7 with the **refreshed** file, because
that is what boots today with a working screen. Everything else in the chain is unchanged: `uboot.bin`
`a28fd6a0e6c6`, `trust.bin` `7f2c4e52e595`, `dtb.bin` `bb9f8df61474`, `dtbo.bin` `e5c1d28c4b6f`,
`vbmeta.bin` `76ff77959f24`, `security.bin` `6ff044d01c2b`, `recovery.bin` `1fdf5ea77fc6` (the stock
recovery the D42 patch works on), `frp.bin` `07854d2fef29`, and the backup GPT `f423cdce2c87`. The
refreshed super capture is `11e91ea677e1` and it differs from Nov 11 only in its first 2 MiB - all
logical partition bytes beyond that are identical - so the dynamic content is the same and only the
metadata region moved. Full measurement: `docs/findings.md`, "Stock backup refresh on Nov 17".

## Fastboot is not used

Owner confirmed there is no Rockchip loader/Boot-ADB entry, so fastboot in the ABL was the only other
transport. It is not used (**D18**): it writes `recovery` and `boot` while bypassing the stock
recovery's loader step, which may be the sole route to the mainboard MCU firmware. Its scripts were
removed on Nov 6 - if the update.zip route ever proves impossible that is a fresh decision, not a
fallback to reach for.

## If the unit ever stops booting

The last resort on this SoC is MASKROM, and it does exist on the PX6 - it is just not reachable through
the unit's own ports, which is what the owner checked (**D14**). The community route is: open the case,
get at the PX6 board, connect it over USB with a made cable (XDA's PX3/PX5 thread, and the PX6 pinout on
page 2 of the PX6 MASKROM thread, t3989407), short two pins to enter MASKROM, then flash a full
`update.img` with AndroidTool. Shorting pins on some boards instead enters the *recovery* menu
(skipraider, XDA, 22 Jul 2020). Dasaita's support answer for a unit that will not boot is the same
escalation: card-with-`update.zip` first, then a full image, then "a complete flashing (you will need a
USBA to USBA cable)".

A MASKROM flash writes the whole boot chain (uboot, trust, dtbo, loader) from whatever `update.img` is
chosen, so it is outside **D18** and outside this repo's tooling: it is a rescue operation for a
bricked unit, not an install transport, and it needs the board opened and soldering. Nothing here
shorts pins or writes loader images.
