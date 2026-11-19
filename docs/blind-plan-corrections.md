# Corrections to the proposed blind plan (Nov 18)

Status: the owner forwarded a plan written by a frontier model from the public `README.md` and `agentPlan.md`
only, with the note that the author had not read `docs/`, `scripts/`, `tools/` or `facts.tsv`. This file is
WP0 of that plan: every statement in the forwarded plan that the repo contradicts, with the path that settles
it. Where the two disagree, `docs/findings.md` wins, as the plan itself says.

Two of the plan's central premises are wrong against measurements taken on Nov 18, and several are right. Both
halves are listed, because the plan is worth adopting with these edits.

## Premises that are wrong

| forwarded claim | measured reality | evidence |
|---|---|---|
| "Today the unit is probably not reachable (`192.168.1.120` silent)" | It is reachable. The failure was the workstation's own `adb` daemon: `adb kill-server`, `adb start-server`, `adb connect 192.168.1.120:5555` returns `connected`, and `adb root` returns `restarting adbd as root` | `docs/findings.md`, "Nov 18 (late session)" |
| "Channel A pstore/ramoops: Proven - biggest lever" | Correct that it is proven, but the repo row that said "RAMoops is not registered" was wrong and is now fixed. `dmesg` shows `ramoops: attached 0xf0000@0x110000`, `pstore: Registered ramoops as persistent store backend`, `console [pstore-1] enabled`. `/proc/iomem` not listing it is normal for reserved memory, not a failure | `docs/findings.md`, "pstore works" and "Kernel config answers" |
| "Channel C: kernel messages on screen (`console=tty0`, fbcon) - Unknown, needs an R0 config check" | Impossible, not unknown: `# CONFIG_VT is not set` and `# CONFIG_TTY_PRINTK is not set` on the OEM 4.19.111 kernel, so nothing can print to a console device even though `CONFIG_FB` and `CONFIG_DRM_FBDEV_EMULATION` are `y` | `incoming/probe-20261113-2016.md`, `docs/findings.md` config table |
| H1's super side: "our `super` (LP metadata, geometry, alignment) differs from stock in a way the OEM boot path rejects" | The payload's super differs from stock only in the metadata slots: group name `hct_dynamic_partitions` vs `rockchip_dynamic_partitions`, attributes none vs readonly, plus `system_ext`. The live super after the restore differs from the stock capture by only 148 bytes in those slots, and its logical partition bytes hash exactly like stock's | `docs/findings.md`, "Payload super metadata against stock super" and "Super: logical content identical" |
| H2: "DT alias / mmc numbering mismatch, so first-stage init cannot find `super`" | The running stock kernel's device tree has **no** mmc aliases (`/proc/device-tree/aliases/mmc0`, `mmc1`, `mmc2` read empty) and storage works, because u-boot brings up storage and appends `androidboot.boot_devices=fe330000.sdhci` plus `storagemedia`/`board.sel`/`b.mode`/`dtbo_idx` to the cmdline. Our payload's DTB is byte-identical to the variant the kernel actually receives (`cd4eeb3daece`) | `docs/findings.md`, "The live device tree has no mmc aliases" |
| D60's tail DTB: "our image loses the tail DTB variant that carries the `mmc0/mmc1/mmc2` aliases" | Fidelity work, not a fix candidate. Both tail DTBs are still on partition 7 (region sha `bfbf7e1c58cedf…`), the kernel never used them, and the risk row's confidence is lowered to ~10%. Nov 19 adds the real structure: those copies sit inside a Rockchip resource image (`rk-kernel.dtb` + `logo.bmp`, SHA1-verified), the logo the boot path uses comes from `second`, and the OEM keeps 4.6 MB of splash data in front of that header - which our rebuild used to zero-fill (**D68**) | `docs/findings.md`, "DTB re-measured" and "Nov 19" |
| H7: "vfat/NLS or USB storage not built in - the old SD logger could never have worked" | Both `NLS_CODEPAGE_437` and `NLS_ISO8859_1` are `y`, `/proc/filesystems` lists `vfat`, and `CONFIG_USB_STORAGE` is `y`. The logger's silence means init never reached its service stage, not that the filesystem was unavailable | `docs/findings.md`, "Kernel config answers" |
| "the stock rollback exists: bootSD card route + the byte-exact stock backup" | True, but partition 7 today is **not** the byte-exact backup: it hashes `0bd1cc806740…`, because the restore wrote only 27,406,336 B and left payload padding at 27,406,336..28,233,728 | `docs/flash.md` "Rollback", `docs/findings.md` "partition 7 is not the rollback capture" |
| "the recorded recovery image still has the old buggy script" | The recovery on disk hashes exactly like the stock capture (`1fdf5ea77fc6…`), so **no** patched recovery is flashed. The unit is state S0, not S2 | `docs/findings.md`, boot-chain digest table |
| H5: "OEM 4.19.111 lacks a config option Android 14 init needs" | The options Android 14 init needs are present: `CONFIG_CGROUPS`, `CONFIG_CGROUP_BPF`, `CONFIG_BPF_SYSCALL`, `CONFIG_MEMCG`, `CONFIG_PSI`, `CONFIG_SECCOMP_FILTER` are all `y` | `incoming/probe-20261113-2016.md` |
| WP2 T2.1 should repack `hu-stock-backup/boot.bin` | Use the refreshed capture `hu-stock-backup-refresh/boot.bin` (`4121b58f7759…`) - it is what boots today (**D57**), and the Nov 11 file differs from the live partition by 2,231,447 bytes | `docs/flash.md` "Rollback" |
| WP2 T2.3 "write the identity gate tool" | Done Nov 19: `tools/identity_gate.py` repacks stock content through `tools/rebuild_boot_faithful.py` and demands byte-identity, then checks what a payload-fed image may change, then diffs `lpdump` on both supers. Its **first run failed** and found the zero-filled tail (**D68**), which is the defect class the gate exists to catch. The Nov 18 builder output `807340652712…` is superseded by `e504655bd32c…` | `docs/findings.md`, "Nov 19 - the identity gate ran" |
| WP3 T2 layout assumptions | The loader layout is measured: `kernel @ 2048`, `ramdisk @ roundup(2048 + kernel_size)`, `second @ roundup(ramdisk_offset + ramdisk_size)` - rounding **after** adding the header page, confirmed by the RSCE and DTB magics on stock boot, payload boot and stock recovery | `docs/findings.md`, "The byte-faithful boot rebuild" |
| WP5 `rdinit=/hu-stage0` as a namespace-free harness | Acceptable, and better than the harness we froze, but note the reason the harness route is dead forever: `# CONFIG_USER_NS is not set` (**D65**) | `docs/findings.md` config table, `docs/decisions.md` D59/D65 |
| WP7 Q5 asks for a `misc` write | `misc` hashes `909bdd979111…` exactly as captured, i.e. untouched (**D30**). Any BCB write is a new write surface and needs the owner's explicit go | `docs/findings.md` boot-chain digest table |
| The plan's NAS note assumes build-host access is reachable | The credential wrappers do exist (`/tmp/opencode/omv.sh`, `askpass.sh`, `build_host.env`, mode 600, outside the repo); `docs/plan.md` said they were gone and is corrected. SSData is 99% full, so the super gate needs `WORK` on the cold archive | `docs/plan.md` "NAS access", `docs/housekeeping.md` |

## Premises that are right, and worth adopting

* The core thesis - make a failed boot explain itself before changing more Android 14 content - matches what
  the Nov 18 measurements say: both writes died before init started a service, and neither panel told us where.
* Risk classes with R3 gated on an explicit owner "go" for each step match **D38**/**D40**/**D42**/**D43**/**D62**.
* "Never restate numbers from memory; quote `docs/findings.md` or re-measure" is the same rule `facts.tsv` and
  `tools/facts.py check` enforce.
* Boot-only ladder, one variable per flash, `super` untouched, rollback by whole-partition write: exactly **D62**
  and **D66**.
* The `panic=` reasoning is confirmed: the two Nov 18 boot images differ by exactly 9 header bytes, `" panic=12"`,
  and produced a logo loop versus a black panel. Note the tree default in `device/rk3399-px6-hct4/BoardConfig.mk`
  also carries a duplicated `androidboot.selinux=permissive`, so each rung edits the header field with
  `tools/patch_boot_cmdline.py` rather than trusting the tree default (**D62**).
* Keeping the header byte-verbatim except `ramdisk_size`, the content hash and our own cmdline tokens is **D60**,
  already implemented in `tools/rebuild_boot_faithful.py`.
* L0 as "no write at all, just `adb reboot` and read pstore" is the right first rung and costs nothing.

## Two arithmetic traps that would have broken the plan's own measurements

* `toybox dd`'s `skip` counts input **blocks**: 32,093,696 / 512 = 62,683. Using `skip=62879` lands on
  32,194,048 and reads unrelated bytes - this is exactly what produced a false "the tail DTB is gone" reading
  earlier today.
* Android's mksh does 32-bit arithmetic: `sz=$(( sectors * 512 ))` over super's 6,373,376 sectors wraps to
  -1,031,798,784, and `dd count=` then copies nothing (the digest of empty input is `e3b0c44298fc…`). Use the
  exact count: super is 3112 MiB, so `dd bs=1M count=3112`.
* `adb exec-out dd` inserts CR bytes into binary output (88 here), so a pulled image hashes differently. Pull as
  `dd | toybox base64`, strip `\r`, then decode - that reproduces the device-side digest exactly.

## What the ladder becomes, after these corrections

| rung | change | why it is still the right order |
|---|---|---|
| P0 | no write; one warm `reboot` via `scripts/pstore_probe.sh` (gated on `HU_CONSENT=1`), read `/sys/fs/pstore/*` on the next boot | decides whether a failed boot can be read afterwards at all; costs one boot cycle and nothing else |
| L0 | identity round-trip: repack stock boot content with our tooling, byte-identical to the capture (**D67** gate already proves this offline) | eliminates a pipeline defect before any Android 14 claim can be interpreted |
| L1 | stock content + our diagnostic cmdline tokens, one variable per flash | separates cmdline effects from payload effects (**D62**) |
| L2 | Android 14's own static first-stage init inside the stock Android 10 ramdisk | tests the real chain without the dm-name clash that froze the harness (**D59**) |
| L3+ | only then a payload write, and never one that can mount or format `/data` | **D42**/**D43** limits unchanged |

UART stays parked (**D63**) and needs the owner's consent to open the unit. The owner questions the plan batches
are recorded in `docs/head-unit-findings.md`.
