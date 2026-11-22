# Handoff - the PX6/RK3399 HCT4 A14 loop, state after iteration 1 (Nov 22, late)

Everything below is a measurement or an owner report. Anything not measured is named as unmeasured.
No flash has happened since the reboot was issued at epoch `1795375253`, and nothing may be written from
the workstation while the owner's `update.zip` install runs (**D97**).

## Right now

* **The unit is back on stock Android 10 with its userdata intact.** The owner's `update.zip` install
  succeeded (**D97**). Measured read-only from the workstation: ping OK, ARP `REACHABLE` for
  `00:0a:cd:27:a5:b2`, TCP 5555 open, `adb devices` state `device`, `adb root` works,
  `rk3399-userdebug 10 QQ2A.200305.004.A1 eng.hct2.20250401.152740 release-keys`, `sys.boot_completed=1`,
  `androidboot.mode=normal`.
* **Partition heads equal the pre-restore stock captures**, checked with bounded 4 KiB head digests rather
  than re-cloning partitions (owner instruction: do not waste space or time re-cloning the HU's current
  state): partition 7 `fac15a4b138e…`, partition 8 `b06dc33648a3…`, `misc` `0f2ec43e7a5c…` with its first
  64 B all zeros. Head equality over 4 KiB is not full-partition equality. Sizes unchanged: boot
  33,554,432 B, recovery 100,663,296 B, misc 4,194,304 B, cache 402,653,184 B, super 3,263,168,512 B.
  `ro.boottime.flash_recovery` read 3754681376 ns, so partition 8's self-heal ran (**D82**).
* **`/data` survived:** `/dev/block/mmcblk2p15 54G 10G 44G 19% /data`.
* **Iteration 1 is closed and nothing is written without instructions.** Partition 7 no longer holds the
  wrapper candidate `b1378cd79497…` and partition 8 no longer holds the v6 recovery `b2821cce34ae…`; both
  remain staged offline and mirrored in cold storage (**D96**). The wrapper's arm path on the real `misc`
  and its watchdog reboot are still unmeasured. The next write needs the owner's explicit go.

## Bench, access, and tool limits

* Unit MAC `00:0a:cd:27:a5:b2`; workstation `192.168.1.161`; unit address `192.168.1.127/24`, gateway
  `192.168.1.1`; adb over TCP 5555. Android sessions start as `shell`, so `adb -s 192.168.1.127:5555 root`
  first.
* Read-only readback recipe, hashing on the workstation:
  `adb exec-out 'toybox dd if=… bs=4096 count=… | toybox base64' | tr -d '\r\n' | base64 -d`.
  `blockdev --getsize64` works in Android and in recovery; `--getsize` is sectors, not bytes.
* Recovery's busybox is 1.11.1: no `sha256sum`, no `wc`/`cp`/`rm`/`ls`/`tr`, and its `od` has no `-A` option.
  The ramdisk's `/system/bin` (toybox) has `dd`, `base64`, `sha256sum`, `cat`, `ls`, `head`. Android's
  busybox copy at `/data/local/tmp/busybox` is the same 1.11.1.
* Build host `apollo` at `192.168.1.29` through `/tmp/opencode/omv.sh`; the credential lives only in
  `/tmp/opencode/build_host.env` (mode 600) and never appears in argv, docs or the repo. Gate scratch goes to
  NAS `/tmp`; SSData has 2.7 G free. `simg2img`/`lpdump` are not on PATH there - they live in
  `lineage21s/out/host/linux-x86/bin`.
* The NAS DataPool is `fuse.mergerfs` over four ext4 branches (`category.create=mfs,minfreespace=4G`), 784G
  free, not ZFS (**D96**). Cold copies verified with `sha256sum -c` on the NAS side.

## Partition state recorded at the stop of iteration 1

| partition | digest of record | size |
|---|---|---|
| 7 `boot` | `b1378cd79497…` (the injected wrapper candidate) | 33,554,432 B |
| 8 `recovery` | `b2821cce34ae…` (v6 net module image, 39,092,224 B of it) | 100,663,296 B |
| 3 `misc` | full-partition digest unknown after the dead boot; the 2048 B head read inside the earlier recovery boot was all zeros `e5a00aa9991a…` | 4,194,304 B |
| 11 `cache` | holds the staged candidate, the rollback, the nonce and the recovery image | 402,653,184 B |
| 14 `super` | untouched in this attempt | 3,263,168,512 B |
| 1, 2, 4, 5, 6, 10 | untouched, as required | - |

Forbidden writes stay forbidden: `uboot` (p1), `trust` (p2), `dtb` (p4), `dtbo` (p5), `vbmeta` (p6),
`security` (p10), the RKLoader, the GPT, and any resize of `super` (p14). Partitions 7 and 8 are never
written in the same flash (**D62**), one variable per flash, and no flash of any kind without the owner's
explicit go.

## Iteration 1 - what was done, in order, with epochs

1. **Baseline, read-only.** Partition 7 `b449aee98c01…`, partition 8 `1fdf5ea77fc6…`, `misc`
   `909bdd979111…` with its head all zeros, `androidboot.mode=normal`, `sys.boot_completed=1`, Android 10
   over TCP 5555. Captured into `a14-work/iter1-base/`.
2. **Staged in `/cache` from Android**, each verified on-device with `toybox sha256sum`: candidate
   `hu-candidate-boot.bin` `b1378cd79497…`, rollback `hu-rollback-boot.bin` `b449aee98c01…`, nonce
   `iter1-nonce-a` in `hu-net.request`. `hu-restore.request` was deliberately not created, so the recovery
   service's auto-restore path stayed dormant.
3. **Flash 1 - partition 8 only, from Android** with `scripts/flash_recovery_from_adb_root.sh`: staged
   `b2821cce34ae…`, wrote 39,092,224 B, script readback ok. Recovery entered immediately after
   (`setprop sys.powerctl reboot,recovery`, epoch `1795374906`); Android was never booted in between (the
   staging rule from D82).
4. **Recovery answered within seconds**, `adb devices` state `recovery`. `/proc/cmdline` carried
   `b.mode=recovery` alongside `androidboot.mode=normal` (**D90** holds). The v6 net module armed on the
   nonce: marker `net-done-iter1-nonce-a.txt`, `eth0` at `192.168.1.127` carrier=1, adbd listener
   `0x15B3` state `0A` in `/proc/net/tcp6`, telnetd `0x0913` (2323).
5. **Flash 2 - partition 7 only, from recovery with partition 8 frozen**:
   `/system/bin/dd if=/cache/hu-candidate-boot.bin of=/dev/block/by-name/boot bs=4096 conv=fsync` returned
   `8192+0 records out`, rc 0. Workstation readback of the whole 33,554,432 B partition: `b1378cd79497…`.
   Partition 8 read back over its image span (39,092,224 B): `b2821cce34ae…`, unchanged. Misc head still all
   zeros after the write.
6. **Reboot to Android issued** at epoch `1795375253`. Monitor from 130 s to 390 s saw only a stale
   `offline` adb entry until it disappeared; at 712 s ping lost, no neighbour entry, 5555 and 2323 closed,
   `adb devices` empty. Owner: button backlighting, black screen.
7. **Owner took physical control** and is installing an OEM `update.zip` (**D97**).

**Proven by this iteration:** partition writes and readbacks are byte-exact; the patched recovery boots and
answers over TCP with its net module armed; u-boot adds `b.mode=recovery` when `misc` carried the message.
**Not proven:** the wrapper's arm path on the real `misc` and its watchdog reboot - neither ever answered.
The dead boot's console was never read, because no networked recovery boot happened after the reboot.

## Findings that change the design

* **Recovery clears the BCB.** `misc head all zeros` inside the recovery boot that carried
  `b.mode=recovery`: the armed message is consumed by that boot itself. A reboot out of recovery therefore
  needs `misc` re-armed by hand, or nothing armed boots partition 7 normally. The only automatic re-armer is
  the wrapper in partition 7 - and it did not answer in iteration 1.
* **The v6 recovery services do not mount `/cache`.** `/proc/mounts` had no `/cache` entry while
  `hu-net.sh`, `hu-state.sh` and `hu-card.sh` ran and wrote their markers: `cache_ready` passes on the
  ramdisk directory, so those files live in RAM and die with the boot. Durable evidence needs workstation
  pulls, and `/sbin/busybox mount -t ext4 /dev/block/by-name/cache /cache` returns rc 0 and makes the staged
  files readable.
* **The net module arms once per nonce**, and its done marker is a file. Because `/cache` is not mounted, the
  marker is in RAM, so a later recovery boot re-arms - unmeasured, since no second recovery boot answered.
* **A card is mounted at `/mnt/hucard` by `hu-card.sh`.** It received the snapshots
  `state-recovery-5.txt` 6438 B, `state-recovery-30.txt` 6291 B and `state-recovery-120.txt` 6213 B. The
  handoff previously said both MMC cards were out, so which card is in the slot is unknown and must be
  identified; the SD-boot rescue card must stay imaged and out.
* **Partition 8 self-heals while Android boots (**D82**).** `/system/bin/install-recovery.sh` applies a patch
  with source `boot:27,406,336:ecb5315f…`, so an Android boot whose partition 7 hashes to that source
  rewrites partition 8 back to stock. The wrapper image does not hash to that source, so partition 8 stays
  patched while it boots - measured for the stock image, not observed in iteration 1 because Android never
  answered.
* **Kernel tokens ride in partition 7 alone.** The header cmdline field is 512 B at bytes 64..575 and D60
  permits it: `boot-min.img` `3cf40129…` and `boot-diag.img` `85dd1138…` differ by exactly 9 bytes at
  397..405, and the stock header cmdline appears verbatim inside the live `/proc/cmdline` (334 B inside
  670 B). Whether this vendor kernel honours `ignore_loglevel`, `panic=10` and `softlockup_panic=1` is
  unmeasured. Runtime knobs measured in recovery: `panic=5`, `softlockup_panic=0`, `sysrq=1`.
* **A cold power cycle enters recovery when `misc` is armed** (**D91**, measured) and destroys RAMoops
  (`/sys/fs/pstore` was `total 0`). A power cut is an accepted last-resort recovery entry; pull the live
  console and copy to the card before the boot ends.

## Evidence inventory (workstation, digest manifest)

`a14-work/iter1-base/` 244,613,120 B and `a14-work/iter1/` 111,788,032 B, covered by
`a14-work/iter1/MANIFEST.sha256` (17 files, the manifest itself `c5264273316a…`):

* `iter1-base/p7-before.bin` 33,554,432 B `b449aee98c01…`, `p8-before.bin` 100,663,296 B
  `1fdf5ea77fc6…`, `misc-before.bin` 4,194,304 B `909bdd979111…`
* `iter1-base/rec/recovery-patched.img` 39,092,224 B `b2821cce34ae…` (v6, the image actually written)
* `iter1/stage/hu-candidate-boot.bin` 33,554,432 B `b1378cd79497…`, `hu-rollback-boot.bin`
  33,554,432 B `b449aee98c01…`
* `iter1/p7-after/p7-candidate-readback.bin` 33,554,432 B `b1378cd79497…` (the readback of partition 7 after
  the write), `p8-image-span.bin` 39,092,224 B `b2821cce34ae…` (partition 8 unchanged)
* `iter1/recovery-pre/` pulled while recovery ran: `hu-mark.log` 7053 B `dc3769d21127…`,
  `state-recovery-5.txt` 6438 B `4a6c2ce2f5ae…`, `state-recovery-30.txt` 6291 B `64cb0e563381…`,
  `misc-head.bin` 2048 B `e5a00aa9991a…`, `net-done-iter1-nonce-a.txt` 0 B

Evidence of record is workstation pulls plus card copies, never `/cache` alone. No on-device sha of
anything larger than 4 KiB.

## Offline work that is staged and mirrored (nothing of it flashed since Nov 22)

* Wrapper source `tools/hu_wrap.c` `fa0eedb6bf62…`; binaries `hu-wrap-aarch64` 13,968 B `99627bcec382…`
  (static, stripped, no `NEEDED`, no `INTERP`) and `hu-wrap-x86_64` 13,264 B `d141941a…`; build gate
  `scripts/build_hu_wrap.sh` (`zig cc -target aarch64-linux-musl -static -Os -Wl,--build-id=none`, then
  `llvm-strip`, `SOURCE_DATE_EPOCH=1760000000`) reproduces the same digest in a second directory (**D94**).
* HU_TEST host `scripts/smoke_hu_wrap.sh`: six scenarios plus twelve source assertions, 0 failures, native
  x86_64 and under `qemu-aarch64`. Unit legs from `/data/local/tmp`: healthy arm, misc missing, passthrough,
  watchdog fires, disarmed before the tick; the write-fail leg is host-only (root under permissive SELinux
  writes a `0444` file).
* Three injected images, all 33,554,432 B, gated by `scripts/verify_hu_wrap_boot.sh` rc 0 and
  `tools/identity_gate.py` PASS: `hu-wrap-stock-a10.img` `b1378cd79497…`, `hu-wrap-a14rd.img`
  `8f287e8bfa98…`, `hu-wrap-a14rd-diag.img` `02ac85b9aee4…` (tokens at header 397..440), built on
  `base-a14rd-faithful.img` `e504655bd32c…` by the in-place cpio transform (**D95**).
* Coupling gate PASS for the shape A pair: the vendor carved from `a14-work/a14chk-shapeA/raw-super.img`
  (extent `0 .. 1086079 linear super 1980416`) is 556,072,960 B `7a5ce939be0f…`; kernel banner 4.19.111+,
  DTB inside `second` at +2048 size 152,425, 21 `.ko` vermagic 4.19.101+/4.19.111+/4.4.167, `hu_insmod` list
  14 of 14 present, the injected libraries in `/lib` and `/lib64`, criterion HALs present, manifest version
  8.0 target-level 4 with no `<kernel>`.
* The NAS tree's current pass is shape-B-flavored: `VERDICT: flashable build = NO` (kernel 4.19.193,
  manifest target-level 5 declaring `<kernel>`, no `first_stage_ramdisk/fstab.rk30board`, no
  `lib/hw/gralloc.rk30board.so`, 12 audio/bluetooth libs not installed yet, one kept blob needing symbols
  Android 14 does not export). Its images were copied, not moved, into cold storage (**D96**).
* Cold storage mirrors: `cold/vibe-baking/hu-wrap-nov22/` (82 files, 1,611,079,910 B, manifest
  `997e954e4dccc3…`, verified 82 OK 0 FAILED on the NAS) and
  `cold/vibe-baking/nas-tree-images-nov22/` (ten images, 5,656,537,632 B, manifest `4bcc90a6cc15…`, verified
  10 OK 0 FAILED). The pool's older `aospbuild-archive/hu-stock-backup/` is a Nov 11 backup, not the
  rollback: its `boot.bin` is `3d2741f04f31…` (not partition 7's stock `b449aee98c01…`, D76) and its
  `super.bin` is `74bd32f94331…` (not the refreshed `11e91ea677e1…`).

## Open items, in the order they need doing

1. **Done:** the unit was re-measured read-only after the install and now carries stock heads for partition 7,
   partition 8 and `misc`, with `/data` intact. No fresh full capture was cloned, on the owner's instruction
   not to re-clone the HU's current state; the rollback bases of record stay the pre-restore stock captures in
   `a14-work/iter1-base/` (partition 7 `b449aee98c01…`, partition 8 `1fdf5ea77fc6…`, `misc`
   `909bdd979111…`), whose 4 KiB heads equal what the unit carries now.
2. **Identify the card in the slot.** If it is the SD-boot rescue card, put it back out and keep the image.
3. **The wrapper's arm path is still unmeasured on the real `misc`** - sysfs `PARTNAME=misc` lookup, mknod in
   a private tmpfs, `pwrite` of the 2048 B BCB, and the ~300 s watchdog reboot. Iteration 1 wrote the image
   but never observed either. One change per flash.
4. **The disarm rc service (D92) is designed but exists in no image.** It must bring up eth0
   `192.168.1.127/24` gw `192.168.1.1`, restart adbd on TCP 5555 with `ro.adb.secure=0`, verify the listener,
   and only then zero `misc[0:2048]` and log `HU-DISARM`. The `netd`/Ethernet interaction with that static
   address has to be measured on a live Android boot, not assumed.
5. **`/data` on the first A14 attempt stays untouched** - the BCB carries no arguments.
6. **Gates that cannot run on the workstation** need the NAS tree: `tools/payload_coupling_check.py`,
   `scripts/verify_artifacts.sh`, `tools/vendor_link_closure.py`. Run them on `apollo` with
   `WORK=/tmp/<dir>`, never on SSData.

## Circuit breakers (unchanged)

Stop and report an iteration table when the same failure signature appears three times, when six iterations
produce no new finding, or when any write returns an error. Hard stop on a readback mismatch or an unexpected
partition digest: restore from the capture and stop. If neither address answers within ~10 min, stop and ask
the owner to cold power cycle (**D91**) - RAMoops is empty afterwards, so pull the live console and copy to
the card before the boot ends.

## Repo state

`docs/findings.md` carries the iteration-1 measurements and the cold-storage section; `docs/decisions.md`
carries **D90**-**D97**; `docs/housekeeping.md` carries the cold paths and the DataPool correction;
`agentPlan.md` item 30 carries the current state. Gates at the time of writing: `python3 tools/doc_lint.py`
0 findings in 19 files, `python3 tools/facts.py check` clean (367 facts), `python3 -m pytest -q` 19 passed.
