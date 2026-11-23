# Handoff - the PX6/RK3399 HCT4 A14 loop, state after the card recovery boot (Nov 23)

Everything below is a measurement or an owner report. Anything not measured is named as unmeasured.
The SD-boot card is now the recovery carrier (**D98**) and it carries the patched recovery with the net
module (**D99**, **D100**); the eMMC has not been written since the owner's restore (**D97**).

## Right now

* **The unit is in a card recovery boot and answers over the network.** `/proc/cmdline` carries
  `storagemedia=sd` and `b.mode=recovery` while `androidboot.mode=normal` (true of every boot, **D90**);
  `ro.bootimage.build.fingerprint` ends `-HUPATCH`; `sys.boot_completed` is empty; `ps -A` shows `init` plus
  one `recovery` process and no framework services. TCP 5555 (adbd) and TCP 2323 (telnetd) open about 24 s
  after the boot and stay open; `eth0` comes up with driver `ax88179_178a`, HWaddr `00:0a:cd:27:a5:b2`,
  address `192.168.1.127/24`, alias `eth0:1=192.168.77.2`, carrier up from t=0, address unchanged after dhcp.
* **Both cards are in the unit.** `mmcblk1` SD 7,948,206,080 B is the boot card; `mmcblk0` SD 31,266,439,168 B
  is the evidence card, mounted by stock recovery at `/mnt/external_sd`; `mmcblk2` MMC 62,813,896,704 B is the
  eMMC. `/dev/block/by-name/*` points only at eMMC nodes in Android and in recovery, so no by-name path is ever
  used for the card (**D76**).
* **Nothing is pending on the card and nothing is pending on the eMMC.** The card's p8 equals the record image
  `b32bff398f3b…`; its misc holds the armed BCB `ceaae1a6314a…`; the eMMC heads equal their heads of record
  (p7 `fac15a4b138e…`, p8 `b06dc33648a3…`, misc `0f2ec43e7a5c…`). The next write is the STEP 4 ladder on eMMC
  p7, and every level needs the owner's explicit go.

## The card, exactly

| thing | digest of record | size |
|---|---|---|
| whole card image (workstation pull, verified by re-read) | `ca6d1f4d3384…` | 7,948,206,080 B |
| card p8 as captured | `04ed02a2713c…` | 100,663,296 B |
| card p8 image of record, on the card now | `b32bff398f3b…` | 100,663,296 B |
| card p8 header page 0..2,047 as written | `3ac2688c63c7…` | 2,048 B |
| card p8 ramdisk span 25,425,920..37,943,295 as written | `a3cd88ee6d5c…` | 12,517,376 B |
| card misc first 2048 B (armed, no arguments) | `ceaae1a6314a…` | 2,048 B |
| card misc 4 KiB head after two card boots | `a91c9b257401…` | bytes past 2048 match the capture |
| card p7 4 KiB head | `5f1d9939bb0d…` | matches the capture head |
| vendor tail beyond the dtbo, carried verbatim | `beca4ef242e1…` | 61,816,029 B |

The only bytes that differ from the capture are inside the header page (bytes 16..17, the declared ramdisk
size 12,515,795 -> 12,515,437) and inside the ramdisk span. Kernel blob `a11c2667f843…` (Linux 4.19.111+),
second bootloader `948d678b9b9e…` at 37,943,296 and the dtbo region at 38,846,464 are byte-identical, so the
stock menu and its `update.zip` path keep the vendor's own recovery binary (`3aff97ce31d4…`) and `init.rc`
(`c57d847660c8…`). Whether the stock menu itself still runs the OEM `update.zip` after the patch is
unmeasured; nothing in this build changes that binary.

Two builder facts that cost iterations, both measured: the card's boot header declares
`recovery_dtbo_size` = 803 at byte 1632 (a 64-byte DTB header plus the 739-byte OEM payload, region digest
`28a07d4946e9…`, payload `e48134ad0ec7…`), so `HU_DTBO_SIZE=803` is the card parameter (**D100**); and the
loader derives every offset from the declared sizes, so the patched ramdisk must land in the stock page span
(12,515,328, 12,517,376] - it does, via the unused filler `sbin/hu-pad.bin`, and the dtbo is NOT page-padded
because the vendor's tail begins right after the 739-byte payload.

## What the card boot proved

* **The net module works in card-boot mode.** `net: card-boot mode - arming without a nonce; window 30 min`,
  `net begin nonce=card-boot`, snapshots and log in RAM (`/tmp`), `/sys/fs/pstore` empty after a cold power
  cut (**D90**), heartbeat logging `window complete (240 ticks)`.
* **The evidence channel is the second card and it works.** The module waits up to `CARD_WAIT_TICKS`
  (default 12 x 10 s) because the second card is enumerated after the ramdisk services start; once stock
  recovery mounts `/mnt/external_sd` the destination is accepted through the partition node's parent device,
  and `hu-mark.log`, `misc-head.bin` and all three state snapshots land there, additive. Pulled back into
  `a14-work/card-boot-nov23-second-card/`: log `97ec7de41076…` (7,961 B, the snapshot at copy time; the RAM
  log had grown to 12,018 B by the pull), misc head `ceaae1a6314a…`, 5 s `45b054512f7b…`, 30 s
  `2f2916d592ca…`, 120 s `13a440266799…`.
* **The recovery boot does not touch its own partition or the eMMC.** A whole-partition pull after the boot
  (100,663,296 B, 33 s) equals the record image; bytes past 2048 of the card's misc are byte-identical to the
  capture; the eMMC heads are unchanged.
* **The card's BCB is not cleared by these recovery boots.** The misc head still reads `ceaae1a6314a…` after
  both boots. **D90**'s "entering recovery clears the BCB" was measured on an eMMC recovery boot. Candidate
  difference: the cleared BCB is written by the menu path rather than by recovery startup; the discriminating
  measurement is a misc read after a menu action versus after recovery exits without one. Until that is
  measured, treat the card as self-arming and re-arm it anyway before a use you care about.

## Two card boots, in order

1. **First boot** (owner performed it after re-inserting the second card): ping dropped at watcher tick 1,
   adb back at tick 3 (~24 s). Log base epoch `1795430134`. Evidence copies stayed in RAM:
   `evidence: /mnt/external_sd is mounted from /dev/block/mmcblk0p1, which is not the second card`, then
   `no second SD card of 30533764 blocks present`.
2. **Write of the corrected module** (owner GO, mirroring first): header page + ramdisk span written with
   `conv=notrunc` on the size-resolved SD node; whole-partition readback equals `b32bff398f3b…`.
3. **Second boot** (owner): adb and telnet open from tick 3; log base epoch `1514808001`, tick deltas match
   `/proc/uptime`; `card begin (card-boot mode, destination /mnt/external_sd)` at t=10 s and
   `state copied to card rc=0`. Clock base differs between boots - candidate is RTC population, the
   discriminating measurement is the log's epoch base against `/proc/uptime` at the same ticks.

## The three defects that boot 1 exposed, and the fixes

* `EVID_CARD_BLOCKS` was 30,533,764; `/proc/partitions` reports the second card as 30,533,632 blocks
  (31,266,439,168 B / 1024). Arithmetic slip, so nothing ever matched. Fixed in `scripts/hu_h_common.sh`
  `ec3fb6582c9c…`.
* `is_evidence_card()` read sysfs `device/type` on the mount's node name. A partition node (`mmcblk0p1`) has
  no sysfs directory, so the type came back empty and the approved channel was refused; it now resolves the
  parent device first. Gate scenarios 4d and 4e cover both cases.
* `hu-card.sh` ran once at up=1.5 s, before the second card existed, and gave up. It now waits
  (`scripts/hu_card.sh` `b74b147295d0…`) and writes nothing while waiting.
* Android-side surprises in `scripts/arm_card_misc.sh` (`d05786794c87…`): `stat` is only a toybox applet, and
  Android's normal boot has no `/tmp` (recovery does). Both now go through its `tool()` resolver; the first
  run aborted with an empty blob size and wrote nothing, which is the safe outcome.

## Bench, access, and tool limits

* Unit MAC `00:0a:cd:27:a5:b2`; workstation `192.168.1.161`; unit `192.168.1.127/24`, gateway `192.168.1.1`;
  adbd TCP 5555, telnetd TCP 2323. Android sessions start as `shell`, so `adb -s 192.168.1.127:5555 root` first.
* Readback recipe, hashing on the workstation:
  `adb exec-out 'toybox dd if=… bs=… count=… | toybox base64' | tr -d '\r\n' | base64 -d`. A whole card p8
  (100,663,296 B) in 24 chunks of 4,194,304 B takes 32-33 s. `blockdev --getsize64` works in Android and in
  recovery; `--getsize` is sectors, not bytes.
* Recovery's busybox is 1.11.1 (`awk`, `cp`, `rm`, `ls`, `wc`, `head`, `mount`; no `sha256sum`, no `timeout`);
  toybox has no `awk`. Android's normal boot has no `/tmp`; recovery does. Resolve device nodes by size and
  type: eMMC is 62,813,896,704 B type MMC, boot card 7,948,206,080 B type SD, evidence card 31,266,439,168 B
  type SD = 30,533,632 blocks.
* The owner inserts the card into the running unit and performs the boot (reset button, or 10 s home + press
  on the volume knob). The unit is not rebooted or power-cycled with the card in until the card patch is
  verified read-only. Ask before card-dependent work; no flash or write without the owner's explicit GO.
* Build host `apollo` at `192.168.1.29` through `/tmp/opencode/omv.sh`; the credential lives only in
  `/tmp/opencode/build_host.env` (mode 600) and never appears in argv, docs or the repo. NAS logs go to
  `/tmp` on the NAS root; SSData is tight. Cold storage is the DataPool path
  `/srv/50911774-19fb-46b6-bc9e-8cf81623d044/cold/vibe-baking/` (`fuse.mergerfs`, not ZFS, **D96**), copies
  are additive and verified with `sha256sum -c` on the NAS side.

## Artifacts of record

* Card image of record: `a14-work/card-p8-fixed/recovery-netmodule.img` `b32bff398f3b…`, reproducible across
  two independent builds (`SOURCE_DATE_EPOCH` mtime normalisation plus `cpio --reproducible`, **D100**).
  Superseded builds kept for traceability: `3af09dfaad04…` (`HU_DTBO_SIZE=739`) and `03dcdad7af92…`.
* NAS cold mirrors, additive: `cold/vibe-baking/hu-card-p8-nov23/` (`MIRROR.sha256` `c523dc48008a…`, 16/16
  verified) and `cold/vibe-baking/hu-card-p8-nov23-fixed/` (`MIRROR.sha256` `751ad7c46659…`, 15/15 verified).
  The 7.9 GB whole-card capture stays on the workstation and is the rollback for the card.
* Boot evidence: `a14-work/card-boot-nov23/` (first boot), `a14-work/card-boot-nov23-boot2/` (measurement
  report), `a14-work/card-boot-nov23-second-card/` (copies pulled off the second card), each with a manifest.
* Offline gates: `smoke_recovery_netmodule.sh`, `smoke_recovery_evidence.sh`, `smoke_recovery_installer.sh`,
  `smoke_card_rearm.sh`, `smoke_hu_wrap.sh`, `smoke_card_module.sh` - all exit 0 with failures=0, pytest 19
  passed, `tools/doc_lint.py` 0 findings, `tools/facts.py check` clean (471 facts).
* The three staged eMMC wrapper candidates still match their recorded digests (`b1378cd79497…`,
  `8f287e8bfa98…`, `02ac85b9aee4…`); they are built by `scripts/inject_hu_wrap_boot.py`, an in-place cpio byte
  transform (**D95**), so the repacker change did not affect them.

## Forbidden, still forbidden

`uboot` (p1), `trust` (p2), `dtb` (p4), `dtbo` (p5), `vbmeta` (p6), `security` (p10), the RKLoader, the GPT,
and any resize of `super` (p14). Partitions 7 and 8 are never written in the same flash (**D62**), one
variable per flash, and no flash without the owner's explicit GO. The module never writes the boot card or
the eMMC; `hu_install` is absent from the card build; the net module's only writable filesystem in a card
boot is a vfat mount of the second card. No on-device hashing of anything larger than 4 KiB; no re-cloning of
the unit's current state (**D97**).

## Unmeasured

* The wrapper's arm on the real eMMC `misc` and its watchdog reboot (**D97**).
* Whether the stock recovery menu still runs the OEM `update.zip` after the card patch.
* Whether a menu action clears the card's BCB (see the candidate above).
* The STEP 4 ladder on eMMC p7 (L0 -> L1 -> L2 -> L3, one level per flash, console read from
  `console-ramoops` on warm paths, eMMC resolved by size and never by-name) - not started.
* The register/`/dev/mem` path stays dropped: `/dev/mem` is absent, busybox has no `devmem`, and every boot
  reads `androidboot.mode=normal` (**D90**).

## Next moves

1. Ask the owner for the GO on ladder level L0 against eMMC p7, run through the card recovery boot: enter
   recovery from the card, use the module's console over adb/telnet, write one level only, read back on the
   workstation, and keep the circuit breakers (abort on any unexpected digest, restore from the verified card
   or eMMC capture and stop).
2. Re-arm the card's misc before each card use you care about (`scripts/arm_card_misc.sh` `d05786794c87…`),
   asking the owner each time (**D99**: a card boot consumes the arm).
3. Keep the second card in the unit whenever a card boot should produce evidence; without it the copies stay
   in RAM only.
