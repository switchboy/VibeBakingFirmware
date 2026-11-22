# Handoff - the A14 flash-and-test loop on the PX6/RK3399 HCT4

Nov 22 (late evening). Phase A is done and accepted: the eMMC BCB decides the recovery landing, the
reboot-mode register path is dropped (**D90**, **D91**), and the wrapper arms the BCB only (**D92**).
The wrapper is now **built and tested** (**D94**), and three injected boot images are **staged offline**
(**D95**). Nothing has been flashed today. Facts below are measurements; anything untested is named as
untested.

## Device state right now

* Android 10 running over ethernet: `adb -s 192.168.1.127:5555` (run `adb root` first - the session
  starts as `shell`), ARP `REACHABLE` for `00:0a:cd:27:a5:b2`, carrier=1, speed=1000, duplex=full,
  `sys.boot_completed=1`.
* Partition 7 = `b449aee98c01a7da797b…`, unchanged, byte-identical to the D76 rollback capture.
* Partition 8 = stock `1fdf5ea77fc66f48977d…`, `cmp`-identical to the capture. Build v6
  (`b2821cce34ae352a…`) was flashed twice this cycle and reverted by Android's `flash_recovery` each time.
* `misc` = the recorded baseline `909bdd979111…`, head all zeros.
* Both MMC cards OUT: no FAT32 data card, no SD-boot rescue card. Evidence is on the workstation:
  a14-work/phaseA-nov22/ and a14-work/wraptest-nov22/, each with `MANIFEST.sha256`.
* `/data/local/tmp/hu-wraptest/` on the unit holds the wrapper copies (`init`, `notinit`), the loopback
  files and the scenario logs from today's HU_TEST run.

## Arming matrix

| armed | warm reboot | cold power cycle | kernel panic | hang (watchdog) |
| --- | --- | --- | --- | --- |
| BCB only | recovery | **recovery** (Nov 22) | recovery | pending the wrapper's first flash |
| register only | recovery | power-on with nothing armed boots Android in everyday operation; no dedicated leg | Android | not testable: `/dev/mem` absent |
| both | recovery | recovery (BCB present) | recovery | pending the wrapper's first flash |

* Every tested boot's kernel command line read `androidboot.mode=normal`, and u-boot added
  `b.mode=recovery` whenever `misc` carried `boot-recovery`. A panic reboot leaves `b.mode=panic` and
  still boots Android when nothing is armed.
* The register cannot be touched on this unit: `/dev/mem` is absent in the recovery ramdisk, busybox
  1.11.1 has no `devmem` applet, `toybox devmem` fails on the missing node. Register rows come from
  command-line evidence only.
* Cold leg measured: build v6 flashed to partition 8, `misc[0:2048]` armed, **no reboot command issued**,
  owner cut power for 60 s, unit returned to patched recovery with `-HUPATCH` visible and the activity LED
  active, adb reachable on 5555. Marker epochs `1795346793`, `1795346798`, `1795346835` are in the marker log.

## Wrapper - built, reproducible, tested

* Source `tools/hu_wrap.c`, sha256 `fa0eedb6bf62ce0bd94a053084e73a90f3a6c219dcc791b989ac660b76bc3647`.
  Build `scripts/build_hu_wrap.sh`: `zig cc -target aarch64-linux-musl -static -Os -Wl,--build-id=none`
  then `llvm-strip`, `SOURCE_DATE_EPOCH=1760000000`. Toolchain the owner installed (`sudo pacman -S zig
  qemu-user`): zig 0.17.1, qemu-aarch64 11.1.3, llvm-strip from LLVM 23.1.5.
* `hu-wrap-aarch64` 13,968 B sha256 `99627bcec382241b15c97b140fba4bfbbc70e68fc6460843d81d54c372477051`:
  static, stripped, no `NEEDED`, no `INTERP`. `hu-wrap-x86_64` 13,264 B sha256 `d141941a…`, same gates.
  Rebuilding into a second directory gives the same digest byte-for-byte.
* Arm condition as accepted: `getpid()==1 && argc==1 && basename(argv[0])=="init"`; otherwise exec
  `/init.real` with the original argv. Misc is found through sysfs `PARTNAME=misc` on the MMC device
  sized 122,683,392 sectors, mknod'd in a private tmpfs, the 2048 B BCB is `pwrite`d, fsynced, read back,
  and every step logs `HU-WRAP` lines; any failure logs `ARM FAILED` and still execs `/init.real`. The
  watchdog child (~300 s) re-reads the BCB through the open fd and calls
  `syscall(SYS_reboot, MAGIC1, MAGIC2, RESTART2, "recovery")` while it is still armed.
* HU_TEST, host (`scripts/smoke_hu_wrap.sh`): x86_64 native and the aarch64 build under `qemu-aarch64`,
  six scenarios plus twelve source assertions, **0 failures**.
* HU_TEST, unit (`/data/local/tmp/hu-wraptest`, loopback files): healthy arm, misc missing, passthrough
  (argv0 basename not `init`), watchdog fires, disarmed before the watchdog - all pass. **The write-fail
  scenario cannot be enforced on the unit**: root under permissive SELinux writes a `0444` regular file,
  so that leg is host-only.
* Not yet tested on the unit: the real arm path through sysfs and mknod on the actual `misc` partition,
  and the watchdog reboot. Both are the first flash's job.

## Staged images (built offline, nothing flashed)

| image | sha256 | base | header diff | ramdisk gz | content end |
|---|---|---|---|---|---|
| hu-wrap-stock-a10.img | `b1378cd794979f97fd0715087b2191f2bcc89ad4204361922d88e44542b45467` | stock p7 capture `b449aee98c01a7da797b…` | bytes 16..19 | 810,786 B | 27,412,480 B |
| hu-wrap-a14rd.img | `8f287e8bfa98b3fc2e7286f9bc914ceff06a34ee4d4337929a15d4ac0cca074a` | faithful A14 base `e504655bd32c…` | bytes 16..19 | 1,637,631 B | 28,239,872 B |
| hu-wrap-a14rd-diag.img | `02ac85b9aee47174786ef758db0255dfec20a21e2196d6248589832d77a2cd7a` | same base | bytes 16..19 and 397..440 | 1,637,631 B | 28,239,872 B |

* All three are 33,554,432 B and carry the base's tail verbatim from their own content end, so the splash
  region and the tail resource header at 32,092,160 B keep their positions. The tail resource entries
  (`rk-kernel.dtb`, `logo.bmp`, `logo_kernel.bmp`) verify against their declared SHA1s.
* The base is `tools/rebuild_boot_faithful.py` output from the Nov 20 stock capture and the shape A
  payload; its digest equals the Nov 19 faithful image, and `tools/identity_gate.py` passes.
* Injection is an in-place cpio transform (`scripts/inject_hu_wrap_boot.py`): untouched entries are
  copied verbatim, `init` is renamed to `init.real`, the wrapper is added as `init` (mode 0755), the
  payload's device nodes (`dev/console` 5:1, `dev/null` 1:3, `dev/urandom` 1:9) survive, and the stream is
  recompressed with gzip `mtime=0`. Extract-and-repack is refused: `cpio -idm` cannot create those nodes
  as a non-root user, and the archive's headers are the 110-byte 13-field layout.
* `scripts/verify_hu_wrap_boot.sh` gates each image: deterministic rebuild, header diff confined to the
  allowed fields, `7z x` extracts `/init` byte-identical to the wrapper and `/init.real` byte-identical to
  the base's original `/init`, fstab unchanged, the extracted wrapper passes the arm and passthrough
  scenarios, device nodes keep their devmajor:devminor, resource entries verify. rc 0 on all three.

## Kernel tokens - what is reachable

The earlier claim that tokens need a boot-chain write was **wrong**: the header cmdline field is 512 B at
bytes 64..575 and D60 permits it. Measured: `boot-min.img` `3cf40129…` and `boot-diag.img` `85dd1138…`
differ by exactly 9 bytes at 397..405 (`" panic=12"`), everything else identical; the stock header cmdline
(334 B) appears verbatim inside the live `/proc/cmdline` (670 B). So tokens can ride in partition 7 alone -
`hu-wrap-a14rd-diag.img` carries ` ignore_loglevel panic=10 softlockup_panic=1` at 397..440 (377 B total).
Whether this vendor kernel honours them is not measured. Runtime knobs measured in recovery:
`/proc/sys/kernel/panic=5`, `/proc/sys/kernel/softlockup_panic=0`, `/proc/sys/kernel/sysrq=1` (Android
boots with `sysrq=0`), `/proc/sysrq-trigger` exists. The watchdog covers a hang or a panic regardless of
`panic=N`, because it is a separate process that reboots while the BCB is armed.

## Disarm service (not yet built or injected)

The Android 14 rc service must bring up eth0 (192.168.1.127/24, gateway 192.168.1.1), restart adbd on TCP
5555 with `ro.adb.secure=0`, verify the listener, and only then zero `misc[0:2048]` and log `HU-DISARM`.
The `netd`/Ethernet interaction with that static address has to be examined on the unit, not assumed;
that has not been done yet.

## Gate inventory before any candidate flash

* Run and passing today: `scripts/smoke_hu_wrap.sh` (rc 0), `scripts/build_hu_wrap.sh` build gate (no
  NEEDED, no INTERP), `scripts/verify_hu_wrap_boot.sh` on all three images (rc 0),
  `tools/identity_gate.py` (PASS), `scripts/check_super.py`-equivalent rule that partition 14 is never
  resized.
* Cannot run here: `tools/payload_coupling_check.py` and `scripts/verify_artifacts.sh` need the Lineage
  tree at /srv/dev-disk-by-label-SSData/aospbuild/lineage21s (build host, not mounted), and
  `tools/vendor_link_closure.py` needs the same tree. Offline vintf stays indirect through the dist
  `check_vintf` logs, skipped with `SKIP_DIST=1`. There is no standalone fstab gate; the first-stage
  fstab is read inside the coupling gate.

## Phase B (needs GO)

Legs on the stock Android 10 image (`hu-wrap-stock-a10.img`): healthy wrapper, broken `/init.real`,
sleeping `/init.real`. Because a healthy Android 10 boot reverts partition 8, before each failure leg
re-flash partition 8 from Android, enter recovery with `adb reboot recovery`, flash partition 7 from
recovery with partition 8 frozen, reboot normally, then restore stock partition 7 from recovery. One
variable per flash; partitions 7 and 8 are never written in the same flash (**D62**).

## Phase C - the loop

Each iteration: flash only partition 7 and/or changed super chunks from recovery with `dd`, host readback
hash; reboot normal with `setprop sys.powerctl reboot`; wait ~400 s for either A14
(`ro.build.version.sdk=34`, `sys.boot_completed=1`) or recovery on `192.168.1.127:5555`; on failure dump
the previous boot's console, `dmesg-ramoops-0` if present, pmsg, `HU-WRAP` lines and the `misc` head into
a14-work/iter/<n>/ with digests; write one hypothesis line; make ONE change; run the gates; flash; repeat.

## Circuit breakers

Stop and report an iteration table when the same failure signature appears three times, when six
iterations produce no new finding, or when any write returns an error. Hard stop on a readback mismatch or
an unexpected partition digest: restore from the capture and stop. If neither address answers within ~10
min, stop and ask the owner to **cold power cycle** - a power cut is an accepted last-resort recovery
entry (**D91**), and RAMoops is empty afterwards, so pull the live console and copy to the card before
the boot ends.

## Forbidden writes

`uboot` (p1), `trust` (p2), `dtb` (p4), `dtbo` (p5), `vbmeta` (p6), `security` (p10), the loader, the GPT,
and any resize of `super` (p14). Partitions 7 and 8 are never written in the same flash. No flash of any
kind without the owner's explicit go.

## Open items

* **First wrapper flash**: needs GO; sysfs/mknod arming on the real `misc` and the watchdog reboot are
  untested on the unit until then.
* **`netd`/Ethernet interaction with the static address**: not yet examined; the disarm service must be
  checked against it rather than assumed.
* **Disarm rc service**: designed (D92), not yet written into an image.
* **`/data` on iteration 1**: agreed untouched - the BCB carries no arguments.
* **Coupling and closure gates**: need the build host's Lineage tree.
* **Cards**: put the FAT32 data card back for durable copies; keep the SD-boot rescue card imaged and out.
