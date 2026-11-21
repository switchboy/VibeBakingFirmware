# STEP 0 handoff brief - PX6/RK3399 HCT4, Android 10 stock (Nov 21, ~16:55 local)

Legend: **VERIFIED-NOW** = measured this step, read-only. **FROM-NOTES** = carried from earlier
records, not re-measured today.

## Reachability
- **VERIFIED-NOW** adb over TCP at `192.168.1.127:5555`, `adb devices` shows `device`, `get-state` =
  `device`, `adb root` works. Unit up 17 min (booted ~16:36 after the recovery-menu reboot).
- **VERIFIED-NOW** `eth0` is the *only* address: `/proc/net/fib_trie` has one host-LOCAL entry
  `192.168.1.127`. `wlan0` is down (`carrier=0`, `operstate=down`) - WiFi is not connected right now,
  so all traffic rides Ethernet.
- **VERIFIED-NOW** dongle MAC for the router's DHCP reservation: **`00:0a:cd:27:a5:b2`**
  (`/sys/class/net/eth0/address`), driver symlink `.../bus/usb/drivers/ax88179_178a`,
  `carrier=1 operstate=up speed=1000 mtu=1500`.
- **VERIFIED-NOW** `ro.adb.secure=1` on Android, `ro.debuggable=1`, `ro.build.type=userdebug`,
  display id `rk3399-userdebug 10 QQ2A.200305.004.A1 eng.hct2.20250401.152740 release-keys`.
  Consequence for Step 4b: TCP adb is authenticated against Android's key; the recovery ramdisk has no
  adb keys, so a recovery TCP shell needs `ro.adb.secure=0` in the ramdisk `prop.default` (ramdisk is
  replaceable, allowed by D82/RE boundary), or telnetd is the shell.

## Partition hashes (host-side readback, `exec-out dd | base64`, hashed on workstation)
- **VERIFIED-NOW** p7: 33,554,432 B read back, sha256 `b449aee98c01a7da797be1c2aa8238ce4bef3e5ee3ae731afdcf3c53218c4384`
  = byte-identical to `a14-work/hu-stock-postflash-143452/boot.bin` (the rollback image). Workstation
  copy: `a14-work/tmp/p7-now.bin`.
- **VERIFIED-NOW** p8: full partition 100,663,296 B read back, sha256
  `1fdf5ea77fc66f48977d7846c468959a5845d0222dc73c3fe07a1b96b6cb023b` = byte-identical to the stock
  capture `a14-work/hu-stock-backup-refresh/recovery.bin`. So `flash_recovery` reverted partition 8
  on this Android boot, exactly as **D82** predicts; the patched build now exists only as the staged
  file `/cache/hu-patched-recovery.bin` (39,088,128 B, sha256 `90923603efc1cf081102653070e6c30726dece83a512534d34e62ea4bafe00ce`).
  Workstation copy: `a14-work/tmp/p8-now-full.bin`.
- **VERIFIED-NOW** all partitions are writable at the block layer: `/sys/block/mmcblk2/ro=0`, and
  `ro=0` for `mmcblk2p1..p15`. Nothing is locked read-only.
- **VERIFIED-NOW** partition map: p1 uboot, p2 trust, p3 misc, p4 dtb, p5 dtbo, p6 vbmeta, p7 boot,
  p8 recovery, p9 backup, p10 security, p11 cache, p12 metadata, p13 frp, p14 super, p15 userdata
  (`/dev/block/by-name`, ueventd rules).
- **FROM-NOTES** `super` is 3,263,168,512 B, never resized (D19); p1/p2/p4/p5/p6/p10/loader/GPT
  forbidden (D18/D19); p8 and p7/p14 never written in the same flash (D62/D83).

## Kernel / boot identity
- **VERIFIED-NOW** kernel banner `Linux localhost 4.19.111+ #190 SMP PREEMPT Fri Jul 5 14:39:56 CST 2024 aarch64`
  - the same build the recovery image carries (kernel blob digest `a514a3ffb77e…`).
- **VERIFIED-NOW** live cmdline contains `androidboot.selinux=permissive`, `androidboot.mode=normal`,
  `b.mode=normal`, `console=ttyFIQ0`, `firmware_class.path=/vendor/etc/firmware`,
  `androidboot.boot_devices=fe330000.sdhci`, `loop.max_part=7`.
- **FROM-NOTES** the recovery boot's cmdline (captured Nov 21 into `/cache/hu-evidence/recovery-cmdline.txt`)
  is identical except `androidboot.mode=normal ... b.mode=recovery`, and also carries
  `androidboot.selinux=permissive`.

## misc / recovery-entry mechanics
- **VERIFIED-NOW** misc is unchanged across the recovery episode: first 4096 B read back before the
  reboot (`a14-work/tmp/misc-before-nov21.bin`) and now (`a14-work/tmp/misc-now.bin`) are byte-identical,
  md5 `a0280196c9d0e1b61ba0a5be5ca63cb5`, and **neither contains the string `boot-recovery`**.
  So `adb reboot recovery` entered recovery **without** writing a BCB command: entry is driven by the
  kernel's reboot-mode dtbo marker (shared fastboot/recovery marker `0x5242c303`), not by misc.
- **VERIFIED-NOW (partial, one-shot question)**: `adb reboot recovery` entered recovery; while in
  recovery the script's own plain `reboot` re-parked the menu (menu still visible minutes later);
  the owner's menu choice "Reboot system now" booted Android normally. So the exit that works is the
  recovery UI's own reboot, and a shell-side `reboot` parks. **NOT proven** what clears the reboot-mode
  register (no `/sys/class/reboot-mode` node seen), and `adb reboot recovery` from Android has only been
  exercised once. Step 5 needs a per-boot exit test with `misc-head.bin` plus a marker.

## /cache contents (VERIFIED-NOW, sizes from `ls -l`)
`hu-evidence/` (11 files, newest run 16:28), `hu-evidence.log` (1,351 B), `hu-net.request` (29 B,
nonce `nov21-rung3-1795274880-12304`, unconsumed - no `net-done-*` marker exists),
`hu-restore.request` (29 B, nonce `nov20-rung2-1795208096-27817`, unconsumed),
`hu-rollback-boot.bin` (33,554,432 B, `b449aee9…`), `hu-patched-recovery.bin` (39,088,128 B,
`90923603efc1…`), plus OEM dirs `backup`, `backup_stage`, `logo`, `recovery`, `lost+found`.
`df`: 356 MiB total, 71 MiB used, **285 MiB free** (the 100 MiB test file was removed earlier today).
No `misc-bcb.bin` in `hu-evidence/` - the run died before that step.

## What the newest recovery boot proved (VERIFIED-NOW from `/cache/hu-evidence/*` + log)
- The patched ramdisk booted: `/cache/hu-evidence/list-sbin.txt` lists `hu-evidence.sh` 18,693 B.
- init loaded the appended rc and started the service: the log line
  `1795274906 tool listing: sbin=624 systembin=1290 by-name=1355` is emitted by our script, and
  `recovery-cmdline.txt`, `recovery-boot-id.txt`, `when.txt` (`uptime=2.00`) were written.
- ueventd ran and `/cache` was mounted by the script (`mounts.txt` shows `/dev/block/by-name/cache`
  ext4 rw; `/dev` is tmpfs).
- Recovery-side `/sbin` content: `busybox`(1,807,056), `e2fsck`, `eio`, `hu-evidence.sh`,
  **`insmod`(178,860) and `rmmod` as standalone binaries**, `iwlist`(682,733), `mkdosfs`, `pcba_core`,
  `resize2fs`, `sh`(206,684 = mksh R40). No `iw` in the ramdisk.
- The run **stalled at the `p8 digest` line** and never reached the BCB capture, restore, card scan or
  net phase. busybox `head -c 67108864 /dev/block/by-name/recovery` returns exactly 67,108,864 B when
  run from Android as `/data/local/tmp/busybox` (VERIFIED-NOW; a copy named `hu-busybox` fails with
  "applet not found" because multi-call dispatch reads argv[0]). So the stall is not the read; it is
  whatever `dig()` does after it (toybox digest exec / pipe / console write). Per plan rule 4 the digest
  section is being retired.

## Correction to an earlier assumption (VERIFIED-NOW)
`/sys/fs/pstore/console-ramoops-0` right now is 49,698 B, timestamped 16:36, starting
`[0.000000] Booting Linux ...` - i.e. it holds **this Android boot's own** console, not the recovery
boot's. The ramoops buffer is rewritten from offset 0 by each boot, so pstore is NOT a reliable
previous-boot channel; the Nov 20 "recovery copied Android's console" happened because recovery read
the buffer before its own text filled it. Consequence for Step 3/5: recovery-side feedback must be
written to **/cache files** (and optionally a FAT32 card), not read from pstore after the fact.

## Network reality
- **VERIFIED-NOW** Ethernet works in Android through the dongle: gigabit link, adb read
  125,829,120 B in 1 s (~120 MB/s), ping workstation `192.168.1.161` ~0.8 ms; `/cache` writes ~8 MB/s.
- **FROM-NOTES** in the recovery boot the dongle's power LED was lit but its activity LED never blinked
  and no MAC answered on the LAN (neither `00:0a:cd:27:a5:b2` nor WiFi `44:ef:bf:37:a3:e0`) - so no USB
  enumeration happened in recovery. This is the central unknown Step 1-3 must answer.
- **FROM-NOTES** ssh is not available on this hardware (busybox 1.11.1 has no ssh/dropbear); recovery
  remote shell = TCP adb + `busybox telnetd -l /sbin/sh`. WiFi would need an open AP (no supplicant in
  busybox; the vendor HAL needs binder; cfg80211 cannot load `regulatory.db` in recovery).

## Repo / gate state (FROM-NOTES unless marked)
- GitHub pushed: commit `4949893` (D84 Ethernet-first module, net phase, BCB capture, dongle
  measurements). NAS mirror auth fails this session; GitHub is canonical.
- Gates green: `bash --posix -n`; `scripts/smoke_recovery_evidence.sh` 13 scenarios rc 0; sandbox
  `a14-work/tmp/rec-smoke/run-scenarios.sh` A-I pass; pytest 19 passed; `tools/doc_lint.py` 0 findings;
  `python3 tools/facts.py check` 278 facts clean. Unit-side dialect gate = mksh `-n`/`hush -n` with the
  ramdisk's `/sbin/sh` (workstation has no dash/busybox-ash).
- Docs: `docs/findings.md` "Nov 21 (evening)", `docs/decisions.md` D82/D83/D84, `agentPlan.md` item 29.
- RE report: `a14-work/tmp/rec-re/RECOVERY-RE.md`. Stock captures: `a14-work/hu-stock-backup-refresh/`.

## Owner actions pending
None outstanding. Next physical action will be a **cold power cycle** (unplug mains ~10 s, restore) at
the end of a recovery cycle - what you should see: Android boot animation, then the unit answering at
its Ethernet address. Also: pin `00:0a:cd:27:a5:b2` to a fixed IP in the router (Step 4a) and watch the
dongle's activity LED during a recovery boot (Step 4 success signal).

## Proposed next step
Step 1 (offline, zero risk): harvest how stock Android brings the USB host up - grep the stock ramdisk,
`/vendor/etc/init`, `init.rk30board.rc`, `init.hct.rc`, `usb*.rc`, vendor scripts for
usb/otg/vbus/typec/extcon/gpio/regulator/mtc/dwc3/xhci/phy, and decode the DTB nodes for `fe3c0000.usb`
(`dr_mode`, `phy`, `vbus-supply`, `extcon`, regulator-gpios). Output the write/command table and flag any
`/dev/mtc-*` traffic that happens before USB is up.
