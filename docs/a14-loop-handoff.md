# Handoff - the A14 flash-and-test loop on the PX6/RK3399 HCT4

Nov 22 (late evening). Phase A is done and accepted: the eMMC BCB decides the recovery landing, the
reboot-mode register path is dropped, and the wrapper arms the BCB only. The wrapper **build is blocked**
on this workstation by the toolchain rule (D93). Facts below are measurements; anything untested is
named as untested.

## Device state right now

* Android 10 running over ethernet: `adb -s 192.168.1.127:5555` (run `adb root` first - the session
  starts as `shell`), ARP `REACHABLE` for `00:0a:cd:27:a5:b2`, carrier=1, speed=1000, duplex=full,
  `sys.boot_completed=1`.
* Partition 7 = `b449aee98c01a7da797b…`, unchanged, and byte-identical to the D76 rollback capture.
* Partition 8 = stock `1fdf5ea77fc66f48977d…` (`cmp`-identical to the capture). Build v6
  (`b2821cce34ae352a…`) was flashed twice this cycle and reverted by Android's `flash_recovery` each time.
* `misc` = the recorded baseline `909bdd979111…`, head all zeros.
* Both MMC cards OUT: no FAT32 data card, no SD-boot rescue card. All evidence is on the workstation,
  archived in `a14-work/phaseA-nov22/` with `MANIFEST.sha256`.

## Arming matrix

| armed | warm reboot | cold power cycle | kernel panic | hang (watchdog) |
| --- | --- | --- | --- | --- |
| BCB only | recovery | **recovery** (Nov 22) | recovery | pending the wrapper |
| register only | recovery | power-on with nothing armed boots Android in everyday operation; no dedicated leg | Android | pending the wrapper |
| both | recovery | recovery (BCB present) | recovery | pending the wrapper |

* Every tested boot's kernel command line read `androidboot.mode=normal`, and u-boot added
  `b.mode=recovery` whenever `misc` carried `boot-recovery`. A panic reboot leaves `b.mode=panic` and
  still boots Android when nothing is armed.
* The register cannot be touched on this unit: `/dev/mem` is absent in the recovery ramdisk, busybox
  1.11.1 has no `devmem` applet, `toybox devmem` fails on the missing node. Register rows come from
  command-line evidence only.
* Cold leg measured: build v6 flashed to partition 8, `misc[0:2048]` armed, **no reboot command issued**,
  owner cut power for 60 s, unit returned to patched recovery with `-HUPATCH` visible and the activity LED
  active, adb reachable on 5555. Marker epochs `1795346793` (flash begin), `1795346798` (flash end),
  `1795346835` (arm) are in the marker log.

## Facts about evidence durability, learned the hard way

* **A hard power cut destroys RAMoops.** Inside the cold recovery boot `/sys/fs/pstore` was empty
  (`total 0`). After that boot ends in a reboot, its console appears in the next boot's
  `console-ramoops-0`. So after a cold cycle there is no previous-boot console: rely on the live
  `toybox dmesg` pull and card copies.
* **`dmesg-ramoops-0` exists only in Android** and appears when a boot panics; recovery's pstore listing
  never showed it. The Nov 22 panic boot left a 105,125 B record naming the `hu:` marker, the sysrq crash
  and `Kernel panic - not syncing: Fatal exception`.
* **`/tmp/recovery.log` does not exist** in this recovery ramdisk, and `/data/local/tmp` is not visible
  from recovery (both staged blobs were missing there). Android-written files in `/cache` survived both a
  recovery boot and a cold cycle, including the marker log (`hu-mark.log` 5,107 B this cycle).
* **Clocks do not line up across boots.** Android reported `android epoch=1795348010`
  (`Sun Nov 22 12:46:50 CET 2026`), while the recovery boot logged `1514808001`. Correlate markers by
  content, not by epoch.

## BCB write recipe (verified twice)

`boot-recovery\0` at offset 0 (`command[32]`), zero `status[32]` at 32, `recovery\n` at offset 64
(`recovery[768]`), zero-padded to 2048 B, no arguments. Written with `dd bs=2048 count=1 conv=notrunc`.
Exactly 22 bytes change; bytes 2048..4 MiB stay identical to the baseline. Full armed `misc` hashes
`a7c5eaf9cd0b62938af6d2cc427602cbbc4e43ca8fa68d2dbe5030c8564562ea`; recovery zeroes the head itself on
boot, so an armed BCB never survives a recovery boot.

## Partition 7 write path, calibrated

The first 4,096 B of `a14-work/hu-stock-postflash-143452/boot.bin` were written back verbatim with
`dd bs=4096 count=1 conv=notrunc` (rc 0), the head read back as `fac15a4b138e113f6e3dcf4b48dffdde3972dd13e74739fd5f1366be97034663`,
and the whole partition hashed `b449aee98c01a7da797b…` **before and after**: a no-change write. Partition 8
and `misc` were untouched in the same operation, so the D62 pairing rule held.

## Wrapper - design accepted, build blocked

The accepted design is recorded as D92: arm only when `getpid()==1 && argc==1 && basename(argv[0])=="init"`,
otherwise `execv("/init.real", argv)` immediately; find misc through sysfs `PARTNAME=misc` on the MMC
device sized 122,683,392 sectors; mknod in a private tmpfs; `pwrite` the 2048 B BCB; fsync; read back;
`HU-WRAP` lines to `/dev/kmsg`; on any failure log `ARM FAILED` and continue to `/init.real`; never block
or abort; a ~300 s watchdog child re-reads the BCB through the open fd and, if still armed, calls
`syscall(SYS_reboot, MAGIC1, MAGIC2, RESTART2, "recovery")`. The disarm rc service brings up eth0
(192.168.1.127/24, gw 192.168.1.1), restarts adbd on TCP 5555 with `ro.adb.secure=0`, verifies the
listener, then zeroes `misc[0:2048]` and logs `HU-DISARM`.

**Build status:** blocked. Inventory on this workstation: `clang 23.1.4`, `LLD 23.1.4`, `gcc 16.2.1`
(host `x86_64-pc-linux-gnu`), `GNU ld 2.47` with no aarch64 emulation, `/usr/bin/qemu-system-aarch64`.
Absent: `zig`, `aarch64-linux-musl-gcc`, `aarch64-linux-gnu-gcc`, `qemu-aarch64`, `qemu-aarch64-static`,
`/usr/aarch64*` sysroots, Android NDK. The owner directed to stop rather than improvise, so nothing was
installed and no wrapper source was committed. A freestanding clang+lld probe binary (1,072 B, static
non-PIE aarch64, no dynamic section, no `INTERP`, sha256 `b11327b88ba284c84d6160c43c7eb6201cc94b0cff1bc08bfb240551b8b9f1f8`)
is kept as evidence of capability only.

**HU_TEST plan when a toolchain exists:** scenarios run on the unit from `/data/local/tmp` against a
loopback file (qemu-user is absent), plus a host-side x86_64 build of the same source for scenario logic.
Scenarios: healthy, misc missing, write fails, passthrough for other argv, watchdog fires, disarmed before
the watchdog. Then the existing coupling, identity and closure gates on the injected boot image, with the
boot header byte-faithful except `ramdisk_size` and the ramdisk hash.

## Kernel tokens - what is actually reachable

The command line is produced by u-boot, and `uboot`, `trust`, `dtb`, `dtbo`, `vbmeta`, `security` and the
loader are forbidden writes, so `ignore_loglevel`, `panic=10` and `softlockup_panic=1` cannot be injected
as cmdline tokens without touching the boot chain. Measured runtime knobs in recovery:
`/proc/sys/kernel/panic=5`, `/proc/sys/kernel/softlockup_panic=0`, `/proc/sys/kernel/sysrq=1` (Android
boots with `sysrq=0`), and `/proc/sysrq-trigger` exists. A runtime `panic=10` plus `softlockup_panic=1`
can be written by an rc service; `ignore_loglevel` has no equivalent sysctl beyond the console level in
`/proc/sys/kernel/printk`. Note that the watchdog covers a hang or a panic regardless of `panic=N`,
because it is a separate process that reboots after ~300 s while the BCB is armed.

## Gate inventory before any candidate flash

* Coupling: `scripts/verify_artifacts.sh` runs `tools/payload_coupling_check.py`; the first-stage fstab
  is checked inside that gate (D34), there is no standalone fstab gate.
* Super: `scripts/check_super.py`. Partition 14 is never resized.
* Link closure: `tools/vendor_link_closure.py`; identity round-trip: `tools/identity_gate.py`.
* Recovery net-module logic: `scripts/smoke_recovery_netmodule.sh` (19 scenarios, 152 assertions);
  byte-level builder gates in `scripts/patch_recovery_netmodule.sh`.
* Dialect: `mksh R40 -n` with the ramdisk's own `/sbin/sh`, runnable inside recovery over adb.
* Offline vintf has no dedicated tool; it is indirect through dist `check_vintf` logs, skipped with
  `SKIP_DIST=1`.

## Phase B (needs GO, and needs a toolchain first)

Legs on the stock Android 10 ramdisk: healthy wrapper, broken `/init.real`, sleeping `/init.real`. Because
a healthy Android 10 boot reverts partition 8, before each failure leg re-flash partition 8 from Android,
enter recovery with `adb reboot recovery`, flash partition 7 from recovery with partition 8 frozen, then
reboot normally. Restore stock partition 7 from recovery after each leg. One variable per flash.

## Phase C - the loop

Each iteration: flash only partition 7 and/or changed super chunks from recovery with `dd`, host readback
hash; reboot normal with `setprop sys.powerctl reboot`; wait ~400 s for either A14
(`ro.build.version.sdk=34`, `sys.boot_completed=1`) or recovery on `192.168.1.127:5555`; on failure dump
the previous boot's console, `dmesg-ramoops-0` if present, pmsg, `HU-WRAP` lines and the `misc` head into
`a14-work/iter/<n>/` with digests; write one hypothesis line; make ONE change; run the gates; flash;
repeat. If neither address answers within ~10 min, stop and ask the owner to cold power cycle - and expect
RAMoops to be empty afterwards.

## Circuit breakers

Stop and report an iteration table when the same failure signature appears three times, when six
iterations produce no new finding, or when any write returns an error. Hard stop on a readback mismatch or
an unexpected partition digest: restore from the capture and stop.

## Forbidden writes

`uboot` (p1), `trust` (p2), `dtb` (p4), `dtbo` (p5), `vbmeta` (p6), `security` (p10), the loader, the GPT,
and any resize of `super` (p14). Partitions 7 and 8 are never written in the same flash. No flash of any
kind without the owner's explicit go.

## Open items

* **Wrapper source and build**: blocked by D93 until a preferred toolchain (zig, musl-gcc,
  aarch64-linux-gnu-gcc) is available.
* **`netd`/Ethernet interaction with the static address**: not yet examined; the disarm service must be
  checked against it rather than assumed.
* **`/data` on iteration 1**: agreed untouched - the BCB carries no arguments.
* **Cold legs for the register-only row**: not a dedicated leg; everyday power-on with nothing armed boots
  Android.
* **Cards**: put the FAT32 data card back for durable copies; keep the SD-boot rescue card imaged and out.
