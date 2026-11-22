# Handoff - the A14 flash-and-test loop on the PX6/RK3399 HCT4

State at Nov 22 (evening). Phase A is finished except two cells; nothing is blocked except the
`/data` decision and the wrapper build. Everything below is measured, not inferred, unless a line
says otherwise.

## Device state right now

* Android 10 is running over ethernet: `adb -s 192.168.1.127:5555`, ARP `REACHABLE` for MAC
  `00:0a:cd:27:a5:b2`, carrier=1, speed=1000, duplex=full, `sys.boot_completed=1`.
  The adb session drops to `shell` first, so run `adb root` before anything privileged.
* Partition 7 = stock Android 10 boot, `b449aee98c01…`, untouched this cycle.
* Partition 8 = stock recovery, `1fdf5ea77fc6…`, `cmp`-identical to the rollback capture. Build v6
  (`b2821cce34ae352a…`) was flashed and then reverted by Android's own `flash_recovery`, which is the
  expected behaviour while partition 7 still holds the A10 boot image.
* `misc` = the recorded baseline `909bdd979111…`, head all zeros. Recovery clears the BCB early in its
  own boot, so an armed BCB never survives a recovery boot.
* Both MMC cards are OUT: no FAT32 data card, no SD-boot rescue card. No card copies exist for this
  cycle; the workstation holds the evidence.
* Rollback sources: `a14-work/hu-stock-backup-refresh/recovery.bin`, `.../misc.bin`,
  `a14-work/hu-stock-postflash-143452/boot.bin`. The p7 rollback image is D76 (the post-flash capture).

## Arming matrix

Four columns describe how the unit was sent into recovery; three rows describe what was armed.
Filled cells are boots whose command line was read back over adb.

| armed | warm reboot | cold power cycle | kernel panic | hang (watchdog) |
| --- | --- | --- | --- | --- |
| BCB only | recovery | deferred by owner | recovery | pending the wrapper |
| register only | recovery | deferred by owner | Android | pending the wrapper |
| both | recovery | deferred by owner | recovery | pending the wrapper |

* **BCB is honoured on both the warm path and the panic path.** In every examined boot the kernel
  command line says `androidboot.mode=normal`, and u-boot adds `b.mode=recovery` when `misc` carries
  `boot-recovery`. So the eMMC BCB, not the reboot-mode register, decides the landing.
* **A panic alone does not enter recovery.** Crash with an unarmed `misc` came back as Android, and
  the boot after a panic carries `b.mode=panic` in its command line while booting Android normally.
* **The register cannot be read or written on this unit.** `/dev/mem` is missing in the recovery
  ramdisk, busybox 1.11.1 has no `devmem` applet, and `toybox devmem` fails on the missing node. The
  register rows are filled from command-line evidence (`adb reboot recovery` with an unarmed `misc`
  reaches recovery; a panic with an unarmed `misc` does not), not from `0xff320300`.
* Cold columns stay empty by the owner's instruction. The hang column needs Phase B's wrapper.

## What the design now has to do

* **W1 wrapper as `/init` in the boot ramdisk**, real init moved to `/init.real`: mount devtmpfs
  somewhere private, resolve the eMMC by size `62,813,896,704` and type MMC (never by number), write
  the BCB into `misc[0:2048]`, log `HU-WRAP` lines to `/dev/kmsg`, fork a watchdog that after ~240 s
  re-reads the BCB through the open fd and reboots if it is still armed, umount, then exec
  `/init.real` with `argv[0]="/init"`. Arming is what makes a panic or a hang land in recovery.
* **W2 disarm**: an A14 init service on `sys.boot_completed=1` zeroes `misc[0:2048]`, brings up
  eth0 `192.168.1.127/24` with gateway `192.168.1.1`, restarts adbd on TCP 5555 with
  `ro.adb.secure=0`. The A10 idea at `init.rk30board.rc:250-257` is the template.
* **W3 kernel tokens**: `ignore_loglevel panic=10 softlockup_panic=1`. `panic=10` alone reboots with
  no command, which is why W1 must arm `misc` before anything can fail.
* **BCB blob recipe**: `boot-recovery\0` at offset 0 (`command[32]`), zero `status[32]` at 32,
  `recovery\n` at offset 64 (`recovery[768]`), zero-padded to 2048 B, no arguments. Written with
  `dd bs=2048 count=1 conv=notrunc`; exactly 22 bytes change and bytes 2048..4 MiB stay untouched.
  Staging for Android-side writes goes in `/data/local/tmp`, not `/cache`.
* **The A14 payload cannot rewrite partition 8.** Its vendor ships a disabled
  `vendor_flash_recovery` service whose executable is absent and whose property is unset, and its
  `init.rc` and `/system/bin` carry no `flash_recovery` or `install-recovery.sh`. Once partition 7 holds
  the A14 boot image, the A10 rewriter is out of the boot chain, so a patched partition 8 survives.

## Evidence of record

`docs/findings.md` section "Phase A arming tests (Nov 22, afternoon)" carries the digests, and
`python3 tools/facts.py add` registered them. The pull recipe for binaries is
`adb exec-out 'toybox dd ... | toybox base64' | tr -d '\r\n' | base64 -d`, and hashes are computed on
the workstation, never on the unit.

* Recovery consoles are pulled **live** with `toybox dmesg`: a boot only writes its console to pstore
  when it reboots, so `console-ramoops-0` inside a boot holds the *previous* boot.
* In Android, `/sys/fs/pstore` also holds `dmesg-ramoops-0`, which recovery never listed. That is the
  crash-record backend: the panic boot left a 105,125 B record naming the `hu:` marker, the sysrq
  crash, and `Kernel panic - not syncing: Fatal exception`.
* `/tmp/recovery.log` does not exist in this recovery ramdisk, and `/cache` writes made inside
  recovery are unreliable (the staged BCB blob vanished after a recovery boot). Android-written
  `/cache` files did survive. Treat the workstation copies plus `/data/local/tmp` as the record.
* The marker log keeps a full timeline across boots, including the line
  `card: no mountable FAT32 card found - channel unused` from both patched recovery boots.

## Gates before any candidate flash

* Coupling: `scripts/verify_artifacts.sh` runs `tools/payload_coupling_check.py` (D34 also checks the
  first-stage fstab inside that gate - there is no standalone fstab gate).
* Super consistency: `scripts/check_super.py`. Partition 14 is never resized.
* Link closure: `tools/vendor_link_closure.py`. Identity round-trip: `tools/identity_gate.py`.
* Net-module logic: `scripts/smoke_recovery_netmodule.sh` (19 scenarios, 152 assertions), builder byte
  gates in `scripts/patch_recovery_netmodule.sh`.
* Dialect: `mksh R40 -n` using the ramdisk's own `/sbin/sh`; this runs **inside recovery** over adb, so
  a failed A14 boot can still syntax-check a candidate script.
* Offline vintf has no dedicated tool - it is indirect through the dist `check_vintf` logs, and those
  are skipped when `SKIP_DIST=1`. State that honestly in any iteration report.

## Phase B - wrapper calibration on stock partition 7

One variable per flash, and restore stock p7 from recovery after each leg. Three legs: healthy wrapper
(real init runs, BCB armed then disarmed by the boot), broken `/init.real` (panic path must land in
recovery), sleeping `/init.real` (watchdog must reboot into recovery). Also verify how Android 14 init
dispatches on argv and first stage from the build tree at `/srv/dev-disk-by-label-SSData/aospbuild/lineage21s`
on the build host - that tree is not mounted on this workstation, so the extracted `init` binary
(3,644,288 B, stripped static aarch64) cannot answer it; the three legs are the empirical check.

## Phase C - the loop

Each iteration: flash only partition 7 and/or changed super chunks from recovery with `dd`, host
readback hash; reboot normal with `setprop sys.powerctl reboot`; wait ~400 s for either A14
(`ro.build.version.sdk=34`, `sys.boot_completed=1`) or recovery on `192.168.1.127:5555`; on failure
dump the previous boot's console, `dmesg-ramoops-0`, pmsg, `HU-WRAP` lines and the `misc` head into
`a14-work/iter/<n>/` with digests; write one hypothesis line and make ONE change; run the gates; flash;
repeat. Partition 8 stays frozen once partition 7 holds A14 (D62 pairing means partitions 7 and 8 are
never written in the same flash). If neither address answers within ~10 min, stop and ask the owner to
cold power cycle.

## Circuit breakers

Stop and report an iteration table when the same failure signature appears three times, when six
iterations produce no new finding, or when any write returns an error. Hard stop on a readback mismatch
or an unexpected partition digest: restore from the capture and stop.

## Forbidden writes

`uboot` (p1), `trust` (p2), `dtb` (p4), `dtbo` (p5), `vbmeta` (p6), `security` (p10), the loader, the
GPT, and any resize of `super` (p14). Partitions 7 and 8 are never written in the same flash. No flash
of any kind without the owner's explicit go.

## Open items

* **`/data` on the first A14 boot is undecided.** Proposal: iteration 1 leaves `/data` alone, since the
  BCB carries no arguments. If fs_mgr or vold refuses the Android 10 f2fs, a later iteration formats
  `userdata` fresh with the injected `make_f2fs.oem` as its own separately GO'd step (D10 accepts a
  factory reset). Do not fold the wipe into every iteration.
* **The idempotent partition 7 write was never run** (first 4 KiB written back verbatim, readback hash
  unchanged). It calibrates the Phase C write path and proves identical bytes neither change p7 nor break
  D62.
* **Cold columns are deferred** by the owner.
* **The wrapper is not built**, so the hang column is empty.
* Cards: put the FAT32 data card back for durable copies; keep the SD-boot rescue card imaged and out.
