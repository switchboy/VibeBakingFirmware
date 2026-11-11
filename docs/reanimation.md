# Bench reanimation guide - PX6 head unit (HCT4 MTCE)

This is the standalone version: it works without me. Everything here is measured, not guessed. If a step
says "measure first", measure. Numbers in this guide were taken from the unit itself and the OEM packages.

**State of the unit right now:** it holds our Android 14 payload (`super` sha `2045af9c…`, `boot` sha
`83fd2a15…`). It boots to a black screen with no WiFi and no adb. The boot chain (`uboot`, `trust`, `dtb`,
`dtbo`, `vbmeta`, `security`, `recovery`, `backup`, the GPT, the loader) was **never** written, so it is
recoverable by a blind path. The defect we found (D34): our payload has **no first-stage fstab**, so init
never mounts `/system` - nothing starts. The fix images are built and verified (D34):
`a14-fixed.img` (32,796,672 B, `f378d4fd…`) and `boot-a10k-a14rd.img` (28,231,292 B, `455a9ac8…`).

## 0. The five rules

1. **Read before you write.** No write without a serial reading first. If the serial log is not captured,
   do not flash.
2. **Never write these partitions:** `uboot`, `trust`, `dtb`, `dtbo`, `vbmeta`, `security`, `misc`,
   `recovery`, `backup`, `frp`, `cache`, `metadata`, the GPT/`parameter`. Only `boot` and `super` (and
   `userdata` if you want to wipe it).
3. **Never run a full-image write.** `upgrade_tool UF`, `EF`, `GPT`, `WS` are forbidden here. Partition
   writes only, with the sector ranges in §4.
4. **One unit, no spares.** Every write gets a sha check before and after. If anything looks wrong, stop.
5. **Power stability beats everything.** A brownout in the middle of a write is the worst failure there is.
   Fuse the supply, keep the load low, watch the voltage while writing.

## 1. Materials

* Head unit + its harness (yellow, red, black).
* **12 V supply rated 10 A or more.** Measured Nov 11: the unit's nameplate says 10 A and the rear of the
  unit is fused at 10 A. A 1 A brick does not power it on at all, and a 2.5 A brick is marginal at best -
  the amplifier bank and its capacitor charging pull several amps of inrush at power-on, so a small
  current-limited supply just trips its own protection. Options, best first:
  * an old **ATX PC power supply**: its +12 V rail on the 24-pin connector is usually 8-12 A. Short
    **green (PS_ON) to any black (GND)** to start it without a motherboard; use **yellow wires for
    +12 V** and **black for GND**. Some PSUs need a minimum load on the 5 V or 3.3 V rail - if it refuses
    to start or the 12 V sags, hang a 12 V fan or an automotive bulb between +12 V and GND.
  * a **12 V / 10 A (120 W) wall adapter**, or a bench/lab supply with current limit set to ~12 A.
  * a **car battery** with a charger attached (real 12 V, enormous surge capacity, no protection to trip).
* Inline fuse on the + lead: **10 A**, matching the unit's own rear fuse. Do not put a 5 A fuse on this
  unit - it will blow at inrush. Use proper crimped terminals, not twisted strands, and leads of at least
  **1.5 mm^2** copper; keep the leads short.
* Multimeter (V and ohms/continuity).
* USB-to-UART fob with **3.3 V** logic. 5 V TTL bridges (some CH341/CP2102 boards) can damage the SoC pad
  - check the bridge's IO voltage before connecting.
* Jumper wires, a small female header or crocodile clips.
* Laptop, Linux. Tools already on it: `python3`, `sha256sum`, `dd`, `stty`, `debugfs`, `cpio`,
  `/tmp/opencode/rktools/upgrade_tool` (verified working, currently reports 0 Rockchip USB devices),
  `dtc`, `lpdump`/`unpack_bootimg` on the NAS build host (192.168.1.29).
* Payload files, copied to a **Linux/ext4** drive (the NTFS HDD corrupts sparse writes):
  * OEM restore: NAS `/srv/50911774-19fb-46b6-bc9e-8cf81623d044/aospbuild-archive/vibe-rescue/`
    -> `super-a10.img` (3,263,168,512 B, `30da961c…`), `boot-a10.img` (27,406,336 B, `04a43ea9…`),
    `rescue.sha256`.
  * Our fixed images: NAS `…/aospbuild-archive/vibe-fix/` -> `a14-fixed.img` (`f378d4fd…`),
    `boot-a10k-a14rd.img` (`455a9ac8…`), `fstab.rk30board` (`0682e0fc…`).
  * OEM loader: `RKLoader.bin` (465,230 B) inside both OEM packages (`diatsia fw/update.zip`,
    `diatsia fw/update(1).zip`). Extracted on the laptop to `/tmp/opencode/bench/RKLoader.bin` (from
    `update.zip`, sha `4e6646c1…`) and `/tmp/opencode/bench/a10/RKLoader.bin` (from `update(1).zip`, sha
    `847ebf39…`). The two are different builds. **Use the `a10` one** - this unit's boot chain is the
    Android 10 generation it last installed, so that loader's DDR/PMIC init matches what the board boots
    today. Keep the other as a fallback if the first is rejected.
* Paper and pen. Photograph the harness and the board connectors **before** opening anything.

## 2. Bench power

1. Set the supply to 12 V (12.0-13.0 V is fine; anything above 13.5 V is not; never 24 V).
2. **Yellow and red both to +12 V**, through the 10 A inline fuse. Automotive harnesses usually carry
   constant (+, memory) and switched (ACC, logic). Feeding both from the same supply is the usual bench
   hack; feeding only one often leaves the unit dead or half-alive. Twist them together only if both leads
   are heavy enough for 10 A - otherwise use two crimped terminals into one supply post.
3. **Black to the supply's GND.** Nothing else in the harness gets connected: CAN lines, speakers, power
   antenna, mute, brake, parking brake - leave them open and tape them so they cannot touch each other.
4. Meter before energising: continuity yellow->+, red->+, black->-; resistance between + and - must not be
   near 0 ohms; check the unit's own 10 A rear fuse is intact.
5. **Keep the speaker leads open for the first boots.** The amplifier bank is the heavy part of the load
   and its capacitors draw inrush at power-on. Sound-input testing comes later, once the unit boots, and
   then the supply must genuinely hold 10 A.
6. Expect a brief voltage dip at power-on - that is normal inrush. It must recover to >= 12 V. If the
   supply shuts down or stays below ~11 V, it is too weak: do not retry with a smaller one, get a heavier
   supply.
7. Connect the UART first (§3), then power. You want the log from the very first line of the bootloader.
8. Watch the supply voltage during writes. If it drops below ~11 V, abort and fix the supply.

## 3. Serial console

The console is `console=ttyFIQ0`, **115200 8N1**, **3.3 V**. On RK3399 that maps to uart2
(`0xff1a0000`), which is usually a small header or pad row near the SoC - look for a 3 or 4 pin row, or
pads labelled `GND/TX/RX`/`UART`. If nothing is labelled, probe candidates: an idle UART TX pad reads
about 3.3 V and pulses during boot.

Wiring:

| fob | unit |
|---|---|
| RX | unit TX |
| TX | unit RX |
| GND | unit GND (harness black, or a board GND pad) |

If you get garbage or one strange character, you have TX/RX swapped - swap them and try again. GND must be
shared; without it the log is noise.

Start the capture **before** power-on:

```sh
scripts/serial_capture.sh bench-$(date +%Y%m%d-%H%M)
```

It sets the port raw, tees to a file, and timestamps every line. Ctrl-C stops it. The fob shows up as
`/dev/ttyUSB0`; if it does not, check `dmesg | tail` (the kernel needs a driver for the bridge chip).

Put the fob on a USB port that is **not** the one you use for Rockchip USB writes, so you can watch the
log while writing.

## 4. Partition sector map (whole-disk LBA, 512-byte sectors)

Measured from the working firmware's `/dev/block/by-name/` symlinks plus `/proc/partitions`:

| partition | device | start sector | end sector | size |
|---|---|---|---|---|
| uboot | mmcblk2p1 | 16384 | 24575 | 4 MiB |
| trust | mmcblk2p2 | 24576 | 32767 | 4 MiB |
| misc | mmcblk2p3 | 32768 | 40959 | 4 MiB |
| dtb | mmcblk2p4 | 40960 | 49151 | 4 MiB |
| dtbo | mmcblk2p5 | 49152 | 57343 | 4 MiB |
| vbmeta | mmcblk2p6 | 57344 | 59391 | 1 MiB |
| **boot** | mmcblk2p7 | **59392** | 124927 | 32 MiB |
| recovery | mmcblk2p8 | 124928 | 321535 | 96 MiB |
| backup | mmcblk2p9 | 321536 | 550911 | 112 MiB |
| security | mmcblk2p10 | 550912 | 559103 | 4 MiB |
| cache | mmcblk2p11 | 559104 | 1345535 | 384 MiB |
| metadata | mmcblk2p12 | 1345536 | 1378303 | 16 MiB |
| frp | mmcblk2p13 | 1378304 | 1379327 | 512 KiB |
| **super** | mmcblk2p14 | **1378328** | 7752703 | 3.26 GB |
| userdata | mmcblk2p15 | 7752704 | 122683358 | 57 GB |

Sizes to write, in sectors: `boot-a10k-a14rd.img` 55,237 (round up), `boot-a10.img` 53,528,
`super-a10.img` 6,374,161, our `super.img`/`boot.img` sizes are on the NAS build host. Cross-check with
`upgrade_tool PL` before writing anything: the numbers must match the table.

## 5. First power-on: read the log in this order

Look for these, in order. Write down what you see.

1. **Bootloader.** `Rockchip U-Boot`, boot mode, and which DTB it used: `Found DTB in <partition>` or the
   boot-image `dtb size`/`dtb addr` line. Also `android_get_dtbo` / `failed to read dtbo`.
2. **Kernel version line** - this tells you which boot image is in the partition:
   * `Linux version 4.19.111+ ... #190` = the OEM Android 10 boot is in place.
   * `Linux version 4.19.193 ... #24` = our payload's boot is in place (the vendor A11 build).
   If neither appears, the kernel never started: check power and UART.
3. **init stage 1.** Our payload's failure signature is here. Any of:
   `First stage mount skipped (missing/incompatible/empty fstab in device tree)`,
   `failed to read default fstab for first stage mount`, `Cannot read default fstab`,
   `failed to load fstab from kernel:`. Seeing them = D34 confirmed, nothing else needs to be diagnosed.
   A good run instead prints `Created logical partition` lines for system/vendor/product/system_ext/odm.
4. **init stage 2.** `init: starting service ...`, SurfaceFlinger, HAL start/crash-loop messages. If you
   get here, the fstab problem is behind you and the graphics/blob question is the next one.
5. **Anything else:** panic/oops (copy the exact block), watchdog reset, crash loop.

## 6. Decision tree

| what the serial shows | what it means | what to do |
|---|---|---|
| our kernel (`4.19.193 #24`) + fstab messages | D34 confirmed | write the fixed boot (§7 route W1, boot only), then power-cycle and read again |
| our kernel, logical partitions mount, init stage 2, services crash-loop | graphics/blob problem | do not re-flash; collect the crash list first |
| OEM kernel (`4.19.111+ #190`) | boot partition holds OEM A10 boot, so `super` is the odd one out | restore OEM super (W1/W2) to get Android 10 back |
| kernel panic / oops | kernel or DTB problem | copy the block verbatim, do not write anything |
| no serial output at all, unit draws current | UART wiring or wrong port | swap TX/RX, check baud, check 3.3 V bridge, find the other UART |
| no serial output, no current draw | power problem | the supply is too weak - this unit wants 10 A (§2): check the rear 10 A fuse, polarity, and that yellow *and* red are both live |
| unit boots Android 10 normally | payload gone/rolled back | get TCP adb back (§8), then decide from there |

## 7. Write routes, safest first

### W1 - Maskrom / loader over USB (needs an OTG port; with the case open this is the best route)

Test it before trusting it. With the board open, look for pads labelled `MASKROM`/`MODE` (often near the
SoC or PMIC); short to GND while powering on. Try **both** USB connectors - the stick port is host-only,
only the OTG port shows up as a Rockchip device.

```sh
cd /tmp/opencode/rktools
sudo ./upgrade_tool LD        # expect 1 device (0 means maskrom was not reached)
sudo ./upgrade_tool RCI       # chip id must read RK3399
sudo ./upgrade_tool DB /tmp/opencode/bench/a10/RKLoader.bin   # OEM A10 loader; device becomes "Loader"
sudo ./upgrade_tool PL        # partition list: boot must be at sector 59392, super at 1378328
```

Then partition writes only:

```sh
# Android 14 coherent boot, boot partition only (our super stays in place)
sudo ./upgrade_tool WL 59392 55237 boot-a10k-a14rd.img

# OEM Android 10 restore (this overwrites our logical partitions)
sudo ./upgrade_tool WL 1378328 6374161 super-a10.img
sudo ./upgrade_tool WL 59392 53528 boot-a10.img
```

Read back and compare before resetting:

```sh
sudo ./upgrade_tool RL 59392 128 boot-readback.bin && sha256sum boot-readback.bin
sudo ./upgrade_tool RL 1378328 64 super-readback.bin && sha256sum super-readback.bin
sudo ./upgrade_tool RD
```

Forbidden with this tool: `UF`, `EF`, `GPT`, `WS`, and any `WL` whose start sector is below 59392 or in
another partition's range.

### W2 - TCP adb on the old firmware (only after Android 10 is alive again)

Power on with the OEM payload in place; on the factory-settings dialog type **`adbon`**; that sets
`persist.internet_adb_enable=1` and opens port 5555:

```sh
adb connect 192.168.1.120:5555
adb root
adb shell 'ls -l /dev/block/by-name/'
scripts/restore_oem_android10.sh          # writes ONLY super + boot, with sha checks
scripts/flash_from_android.sh             # writes our payload; read its safety checks first
```

Remember Android's mksh does 32-bit arithmetic and `dd skip=/count=` are counted in units of `bs=`.

### W3 - SD boot card

Blocked until the IDB layout is known (u-boot probes for an IDB header; our `update.img` is RKFW with
`-storage:SD` and round-trips fine, but the card layout u-boot wants is unmeasured). To measure it: dump
the first sectors of a card that is known to boot a Rockchip device
(`dd if=/dev/sdX bs=512 count=256 of=idb-sample.bin`). Until then, do not burn a card and expect it to
work.

### W4 - dd from a serial shell

Only if init actually gives you a root shell on the console (needs `/dev/block/by-name/` to exist). With
the current payload it will not.

## 8. Getting Android 10 back (the "reanimate" step)

1. Write `super-a10.img` + `boot-a10.img` (W1 or W2). Verify shas before writing, read back after.
2. Power cycle, watch serial. Expected: OEM kernel `4.19.111+ #190`, logical partitions created, init
   stage 2, boot animation, WiFi.
3. Type `adbon` in the factory-settings dialog -> `adb connect 192.168.1.120:5555` -> `adb root`. Now you
   have uid 0 and a real terminal again.
4. Copy anything you still want from the unit (`/data/local/tmp/hu14-backup/` if it survived, `/dev/kmsg`
   dumps, build logs) before touching it again.
5. From here the Android 14 attempt is a **boot-only** write: `boot-a10k-a14rd.img` (28,231,292 B) into
   the boot partition, our `super.img` into super. Nothing else.

## 9. The Android 14 attempt, step by step

1. Serial capture running, supply metered.
2. Write our `super.img` (NAS build host `/srv/.../aospbuild-archive/` or `out-hu/`) to super, then
   `boot-a10k-a14rd.img` to boot. Verify shas.
3. Power cycle. Read the log: expect kernel `4.19.111+` (the A10 kernel our coherent boot carries), then
   `Created logical partition` for all five partitions. If it stops at the fstab messages, the fix did not
   land - do not flash again, re-measure.
4. If init reaches stage 2, watch which services crash-loop and take `logcat`/`dmesg` over adb if adb is
   alive.
5. If the screen stays black but init stage 2 runs, that is the display/composer question - collect the
   SurfaceFlinger lines, do not flash again.

## 10. Troubleshooting

* Garbled characters: baud wrong (115200), TX/RX swapped, or the bridge is 5 V not 3.3 V.
* Only the bootloader prints, then silence: kernel did not start, or the console switch to
  `ttyFIQ0` failed - the log ends at the last u-boot line, which is itself a useful reading.
* Unit restarts every ~10 s: watchdog because init never completes - that is exactly what D34 produces.
* Unit gets hot, smells, or sparks: disconnect immediately, find the short before trying again.
* Unit stays dead with a heavy supply: check the unit's rear 10 A fuse, supply polarity, and that both
  yellow and red are energised. If all three are good, it is not a power problem - and then the next thing
  to suspect is that the supply's 12 V post is not actually the same node you metered.
* Supply starts but dies as soon as the unit is connected: that is over-current protection tripping on
  inrush - the supply is undersized for a 10 A unit, or the amp capacitors are charging. Use an ATX PSU or
  a battery; do not cycle a small brick repeatedly, each attempt is a partial write risk if init is half-up.
* `upgrade_tool LD` shows 0 devices: maskrom not reached (no OTG access, or the short is on the wrong
  pad), or the cable/port is host-only.
* `lpmake`/libsparse "Disk quota exceeded" on the NTFS HDD: build and copy on ext4 or the NAS instead.
* NAS ssh commands over ~60 s return nothing: launch with `setsid nohup ... > log 2>&1 < /dev/null &`
  and read the log.

## 11. What to write down

For every power-on: date/time, kernel version line, whether the fstab messages appeared, whether logical
partitions were created, what crashed. For every write: which image, its sha, partition, start sector,
sector count, and the sha of the read-back. Keep the log file name next to the entry. That record is what
makes the next decision obvious without me.
