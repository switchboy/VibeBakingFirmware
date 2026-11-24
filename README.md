# VibeBaking Firmware — Android 14 on MTC-family car head units

A worked recipe and toolkit for booting **Android 14 (LineageOS 21)** on a Rockchip **MTC / HCT car head
unit** that ships with Android 10, **from an SD card**, without ever writing the unit's eMMC. It was
developed on one PX6 (RK3399) "HCT4" unit, remotely and without a UART, so every step leaves logs you can
read after a crash.

If you own a similar unit (Rockchip PX5/PX6/PX30, MCU firmware `MTCE_*`, kernel messages starting
with `--mtc`, `/dev/mtc-car`, HCT/Microntek apps such as `com.microntek.radio`), most of this applies to
you. The device-specific numbers (partition sizes, GPIOs, board selection) will differ; the method and
the failure modes should not.

> **Status (Nov 2026):** Android 14 boots from the card to the launcher and stays up. Touch works.
> Ethernet (USB dongle) and **root adb over the network** work once the MCU is told that Android
> booted. In progress: porting HCT's framework layer (`android.microntek.*`, `CarService`),
> which the radio, CAN bus, Bluetooth and the hardware buttons need, and the WiFi HAL. The lab notebook,
> attempt by attempt, is [`docs/findings.md`](docs/findings.md).

## Safety model

* **The eMMC is never written.** The unit boots the card because the card carries its own GPT and boot
  chain; the stock Android 10 on the eMMC stays intact, and pulling the card restores it.
* Every write to the card is digest-checked before and after (`scripts/write_card_chunked.sh`,
  `scripts/flash_card_a14.sh`), and every eMMC partition head is re-hashed around each write.
* Every boot ends in a **networked recovery on the card** unless you disarm it (below), so a hung or
  crash-looping Android 14 always comes back to a shell, with that boot's logs preserved.

## The recipe

### 1. Capture the unit
Make a byte-exact backup of the eMMC and the stock firmware package before anything else. Identify
images by sha256, never by file name (see `docs/flash.md` for the procedure used here and
`docs/head-unit-findings.md` for what to measure: partition map, kernel config, input devices, chips).

### 2. Build the SD boot card
* Card layout and GPT: `tools/sd_card_layout.py`, `scripts/parse_sd_layout.py`, `scripts/inspect_sd.sh`.
* **Rename the card's `super` and `metadata` partitions** (`tools/gpt_rename.py`,
  `scripts/write_card_gpt.sh`) to `sd_super` / `sd_metadata` and pass
  `androidboot.super_partition=sd_super` on the kernel command line. First-stage init matches partitions
  **by name**, and the eMMC's own `super`/`metadata` otherwise shadow the card's; the symptom is a first
  stage that dies in ~70 ms with "by-name/super missing" and a silent unit.
* Put a first-stage fstab in the boot ramdisk whose `/metadata` line points at `by-name/sd_metadata`, and
  format that partition as ext4 (`-O ^orphan_file,^metadata_csum_seed,^64bit` for a 4.19 kernel).
* Boot image surgery: `scripts/inject_hu_wrap_boot.py` (replace ramdisk entries, append to the command
  line, self-checks that untouched entries and DTBs stay byte-identical).

### 3. Make every boot observable (no UART needed)
`tools/hu_card_arm.c` runs as PID 1 in front of Android's init (injected by step 2's tool). It:
* arms the card's **BCB** (bootloader control block), so the next reset lands in the card's recovery,
  which has networking and adb;
* records `/dev/kmsg` to a raw region of the card (2–6 MiB) and copies the previous boot's pstore
  records (6–7 MiB): readable after any reset, even a cold one;
* **dead-man crasher** (`-DHU_DEADMAN -DHU_CRASH_SECS=600`): dumps all task stacks and panics at the
  deadline, warm-rebooting into recovery with pstore intact, unless disarmed with
  `adb shell pkill -x hu-crasher`. Smoke gate: `scripts/smoke_hu_card_arm.sh`.

`scripts/watch_live_a14.sh` reboots into the card, waits for adb, tells Android 14's adbd apart from the
recovery's (same address), disarms, and captures `dmesg` + `logcat`; if recovery answers instead it pulls
the pstore records and the card log. `tools/digest_recorder.py` condenses a capture into a short event list.

### 4. Iterate on the system/vendor images
* Edit ext4 images with `debugfs` (keep mode, owner and the `security.selinux` xattr, including its
  trailing NUL); check with `e2fsck -fn`.
* `tools/splice_super.py` splices changed partitions into `super.img` in place and verifies every byte
  outside the replaced extents; `diffchunks` lists the 4 MiB chunks that differ, and
  `scripts/write_card_chunked.sh` (`ONLY_CHUNKS=...`) writes just those over adb, verifying the result.
* Read crash records from the card's `/data` from recovery (mount f2fs `ro,norecovery`):
  `/data/tombstones`, and `/data/system/dropbox` for Java crashes (they survive cold resets).

### 5. Fixes an Android 10 vendor needed under Android 14
Each of these was a boot blocker on the reference unit; details and evidence in `docs/findings.md`.

| Symptom | Cause | Fix |
|---|---|---|
| keystore2 / SurfaceFlinger abort loops | a stale `health@2.0` (and `keymaster@3.0`) entry in the vendor manifest breaks VINTF | remove the conflicting `<hal>` entries; audio/effect `@5.0` → `@6.0` |
| `bpfloader` fails, init reboots | kernel has eBPF but no `CONFIG_BPF_JIT`; no bpffs path labelling | `tools/hu_netbpfload.c`: load with private JIT knobs, re-pin under a labelled bpffs |
| composer crash | Rockchip HWC1 struct is 32 bytes larger than AOSP's | stock Android 10 `composer@2.1-service` + `libhwc2on1adapter` |
| SurfaceFlinger dies at start | Mali (Midgard) FP16 shader cache | `service.sf.prime_shader_cache=0` |
| `/dev/ion`, GPU, sensors root-only | Android 14 ignores the legacy `/vendor/ueventd.rc` | merge its rules into `/vendor/etc/ueventd.rc`; GPU nodes 0666 |
| RT threads (audio, BT) fail | `CONFIG_RT_GROUP_SCHED=y` with no RT budget per cgroup | init rc giving each cpuctl child an RT runtime |
| RescueParty factory-resets | Bluetooth stack crash-loops: the unit's BT is a separate module (GOC) on its own UART | drop Android's Bluetooth feature and HAL (until the HCT BT path is ported) |
| no `/metadata` | the partition was never ext4 | format it (step 2) |

### 6. The MTC car MCU
The MCU (talked to through the kernel's `mtc-car` driver) controls USB power, audio routing, the radio,
CAN bus and the hardware keys. Android 10's HCT framework drove it; Android 14 has none of that.
* **Transport:** `open("/dev/mtc-car", O_RDWR); ioctl(fd, strlen(cmd), cmd)` with text commands
  (disassembled from Android 10's `libandroid_servers.so`). `tools/hu_mtc_param.c` sends them.
* **USB power (and with it USB ethernet/WiFi):** on warm boots the MCU only switches USB on after it hears
  `rpt_boot_android=true` (plus `rpt_logo_complete=true`, `rpt_boot_complete=true`), which Android 10's
  boot animation used to send. Symptom without it: `otg_drv` GPIO low, no `usb 1-1`, dark dongle.
* **Hardware keys** arrive as MCU key codes (`--mtc key 0111` in the kernel log), not as input events;
  HCT's `CarService` translated them. They work again only with the framework port.
* **HCT apps** that run as system (HCTManagerService, HCTBlueToothManager, HCTCanBus, …) crash
  system_server on Android 14 (`NoClassDefFoundError: android.microntek.CarManager`, removed hidden APIs).
  `tools/dex_api_check.py` lists which framework methods an APK calls that a target framework lacks.

### 7. adb over ethernet, with root
* `ro.adb.secure=0` and `service.adb.tcp.port=5555` (userdebug build, card only).
* LineageOS refuses `adb root`; on a userdebug build with SELinux permissive this works instead:
  `adb shell 'setprop service.adb.root 1; setprop ctl.restart adbd'`.
* Keep the unit awake: without HCT's services it deep-suspends after the screen timeout
  (`settings put global stay_on_while_plugged_in 7`).

## Not working yet
HCT framework layer (radio, CAN bus, buttons, HCT Bluetooth), WiFi HAL, GPS/sensor HALs not checked,
`/cache` not formatted, SELinux permissive throughout. See the latest entries in `docs/findings.md`.

## Repository map

| path | what |
|---|---|
| `tools/` | analysis and image tools (Python, C); usage in each file's header |
| `scripts/` | device-side and workflow scripts; `scripts/archive/` and `tools/archive/` are historical one-shots |
| `docs/findings.md` | the lab notebook: every attempt, measurement and sha |
| `docs/decisions.md` | design decisions (D-numbers) and their reasoning |
| `docs/index.md` | which document is canonical for what |
| `docs/flash.md`, `docs/reanimation.md` | operator and bench procedures, rollback |
| `docs/feasibility.md`, `docs/plan.md` | why Android 14 is the ceiling; milestone history |
| `device/`, `patches/` | the LineageOS 21 device tree and tree patches for the source build |
| `facts.tsv` + `tools/facts.py` | every sha/number cited in the docs, checked against them |
| `tests/` | pytest suite for the tools (`python3 -m pytest -q`) |

Consistency checks: `python3 tools/facts.py check`, `python3 tools/doc_lint.py`, `python3 -m pytest -q`.

## Credits and caution
This is a hobby reverse-engineering project on one unit. Nothing here is endorsed by Rockchip, HCT or
Microntek; proprietary blobs are not redistributed. Test on a card first, keep your backup, and expect
your unit to differ in details.
