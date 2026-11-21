# Step 1 - how stock Android brings the USB host up (Nov 21, offline + read-only harvest)

## Headline answer

**Nothing in Android userspace enables the USB host port. The kernel does it at boot.**
Measurements show a recovery boot enumerated the dongle on its own: in the recovery boot
of 16:28 the internal hub appeared at t=0.97 s, the dongle (`0b95:1790`) at t=1.36 s, and
`ax88179_178a` bound `eth0` at t=1.70 s - with no Android userspace running. The earlier
"USB does not enumerate in recovery" conclusion was wrong: `eth0` existed in that boot; the
script stalled before its network phase, so the interface never got an IP and no MAC
answered ARP. Evidence below.

## Controller map (live DTB, decompiled `a14-work/tmp/live.dts` from `/sys/firmware/fdt`, 155,776 B)

| Node | Address | Role | Status (live) | PHY | extcon | dr_mode / notes |
|---|---|---|---|---|---|---|
| `usb_host1_ehci` | fe3c0000 | host EHCI | **okay** | `u2phy1_host` (phandle 0x40) | - | `generic-ehci`, clocks `hclk_host1`/`arbiter`/`utmi` |
| `usb_host1_ohci` | fe3e0000 | host OHCI | **okay** | same `u2phy1_host` | - | - |
| `usb_host0_ehci/ohci` | fe380000/fe3a0000 | host | disabled (`mtc,for_board="1x,2x,3x"`) | `u2phy0_host` | - | unused on this board |
| `usbdrd3_0` / `dwc3@fe800000` | fe800000 | OTG (gadget) | okay | `u2phy0_otg` (0x41) | `<0x3d>` = whole `u2phy0` | `dr_mode="otg"`, **`force_mode="host"`** in DT; live runs as device: UDC bound, configfs `g1/UDC=fe800000.dwc3`, `sys.usb.config=mtp,adb` |
| `usbdrd3_1` / `dwc3@fe900000` | fe900000 | OTG | disabled (`mtc,for_board`) | `u2phy1_otg` | `<0x3f>` | unused |
| `u2phy0` (`usb2-phy@e450`) | syscon ff770000 | PHY + extcon0 | okay | - | extcon0 live: cable.1=1, cable.2=1 | otg port okay; **no `vbus-supply`** (kernel log: `phy ...e450.2: No vbus specified for otg port`) |
| `u2phy1` (`usb2-phy@e460`) | syscon ff770000 | PHY + extcon1 | okay | - | extcon1 live: all cables 0 | host-port okay, otg-port disabled |
| `tcphy0/1` | ff7c0000/ff800000 | Type-C PHY | disabled | - | - | unused |

There is **no VBUS regulator anywhere** in the DT (`grep vbus-supply` = 0 hits; regulators
present are `vcc_sys`, `vcc_phy`, `vdd_cpu_b`, `vdd_gpu`...). Port power is hardware/MCU, not
kernel regulator software. GPIO evidence: `debugfs gpio` shows `gpio-155 (otg_drv) out hi`,
defined as `mtc,otg_drv = <0x98 0x1b 0x00>` in the `mtc-init` node (gpiochip4 pin 27 = 155) -
set by the vendor `mtc-car` driver during board init (`mtc,pin8 = <0x98 0x1b 0x01>` = init high).

## Physical topology (live `/sys/bus/usb/devices`)

`fe3c0000.usb` (usb1, EHCI) -> `1-1` internal hub (0424:2514, 4 ports) -> port 2 = dongle
(0b95:1790 ASIX AX88179) -> `eth0`; port 4 = WiFi RTL8188EU (0bda:0179) -> `wlan0`.
Gadget adb lives on fe800000.dwc3 (usb3/usb4 xhci roots, no devices).

## Table: "write X to Y / command Z, at trigger T, before/after what"

| # | Action | Target | Trigger (stock Android) | Ordering | Needed for dongle in recovery? |
|---|---|---|---|---|---|
| 1 | kernel probe `ehci-platform fe3c0000.usb` | bus usb1 created | kernel boot (DT status okay) | before any userspace | **yes - and it already runs**: recovery console shows `new USB bus registered, bus 1` |
| 2 | kernel probe `usb2-phy` + extcon | `/sys/class/extcon/extcon0,extcon1`, phy ports | kernel boot | before controllers | yes, already runs |
| 3 | built-in `ax88179_178a` interface driver binds `1-1.2:1.0` | creates `eth0` | USB enumeration event | after hub + dongle detect | yes, already runs (t=1.70 s in recovery boot) |
| 4 | `setprop sys.usb.controller fe800000.dwc3`, `sys.usb.configfs 1`, configfs gadget + `UDC` write | gadget adb | init.rc / init.usb.configfs.rc `on fs` | gadget only, irrelevant to host | no |
| 5 | `/vendor/bin/usb_dongle` (oneshot, class main) | runs `usb_modeswitch -W -v -p -c /vendor/etc/usb_modeswitch.d/...` when a new VID/PID appears at `/sys/bus/usb/devices/1-1`; NetlinkManager watches USB events | `service usb_dongle` from `/vendor/etc/init/usb_dongle.rc` | after boot | **not needed for this dongle** - it enumerates and binds without mode switching |
| 6 | `setprop service.usbmuxd.enable 1` -> `start usbmuxd` (`/system/bin/start_usbmuxd.sh`) | MCU USB virtual device (iOS-style mux) | `on property:sys.boot_completed=1` (`init.hct.rc:129`) | after USB up | no |
| 7 | `chown system system` + `chmod 0222 /sys/bus/platform/drivers/mtc-car/usb_touch` | MCU touch-over-USB enable | `init.hct.rc` `on init` block (line 81-82) | before boot_completed | no |
| 8 | `hct.nat.state=1/2` -> `start hctnat` -> `/system/bin/ethtether.sh` | `busybox ifconfig eth0 up/down`, `ndc netd 6001 tether stop` (NAT tether) | property-gated (`init.hct.rc:323`), off by default | after eth0 exists | optional; shows the HCT idiom for eth0 handling |
| 9 | Android netd Ethernet manager (`ro.vendor.ethernet_settings=true`) | eth0 address/routes (DHCP via netd) | framework boot | after eth0 | in recovery this must be replaced by `ifconfig`/`udhcpc` |
| 10 | `mtc-car` driver board init writes GPIOs (`otg_drv` gpio-155 high, pins 0..13) | GPIO/pinctrl | kernel boot, board.sel-driven | before enumeration window | kernel does it in recovery too |
| 11 | `/sys/...usb2-phy@e450/otg_mode` currently reads `host`; file mode `-rw-r--r-- root root` | vendor PHY role attribute | unknown writer | - | **flag**: root-writable knob worth testing later, semantics unproven |

## Flagged `/dev/mtc-*` traffic before USB comes up

- `init.hct.rc on init` chmods `/dev/mtc-car`, `/dev/mtc-av`, `/dev/mtc-dab`, `/dev/mtc-cvbs`,
  `/dev/mtc-cvbs2` to 0666 at very early init (before any USB enumeration).
- kernel `mtc-car` driver announces enumerations (`--mtc ann 1-1 0424`, `--mtc ann 1-1.2 0b95`,
  `--mtc dis ...`) and owns board GPIOs - it runs in recovery too.
- recovery ramdisk ships `sbin/pcba_core` (uses `/dev/mtc-car` ioctls, `get_boot_mode`,
  `sta_test_usb2/usb3`) - not started by `init.recovery.rk30board.rc`, so inert unless started.
- `mtc,for_board` gating disables the fe380000 host pair and fe900000 DRD on this board
  (`board.sel=306,0,0,402` Android / `307,0,0,403` in an earlier boot record).

## DTB/DTBO corrections found this step

- partition p4 `dtb.bin` is **all zeros** - the DTB is NOT in p4. The runtime DTB came from the
  boot image's `second` blob region; the live kernel DT (`/sys/firmware/fdt`, 155,776 B) differs
  from both blobs found in `boot.bin` (152,425 B @ 26482688 and 157,962 B @ 32093696/32636928).
- p5 `dtbo.bin` is an HCT-format blob (magic `d7b7ab1e`, 802 B payload), not a standard DTBO -
  `dtc` refuses it. `androidboot.dtbo_idx=0` in both cmdlines.
- `reboot-mode` node: `/syscon@ff320000/reboot-mode`, offset 0x300, markers `mode-normal
  0x5242c300`, `mode-loader 0x5242c301`, `mode-panic 0x5242c307`, `mode-fastboot` and
  `mode-recovery` both `0x5242c303`, `mode-bootloader 0x5242c309`, `mode-charge 0x5242c30b`,
  `mode-ums 0x5242c30c`.
- Step 6 keys: `adc_keys` (`compatible="adc-keys"`, io-channel from `ff100000.saradc` channel 1,
  keyup-threshold 1.75 mV... poll 100 ms) and `gpio_keys` with a `power` key (GPIO chip0 pin5,
  code 0x74, wakeup-source). No dedicated recovery key node.

## Evidence: why USB DID enumerate in the 16:28 recovery boot

Live `/sys/fs/pstore/console-ramoops-0` (49,698 B, read 17:3x; pstore keeps accumulated
cross-boot text, its first cmdline carries `b.mode=recovery`, board 306):

```
[    0.504834] usbcore: registered new interface driver ax88179_178a
[    0.972792] --mtc ann 1-1 0424          # internal hub
[    1.358644] --mtc ann 1-1.2 0b95        # ASIX dongle detected
[    1.698310] ax88179_178a 1-1.2:1.0 eth0: register ... 00:0a:cd:27:a5:b2
[  481.441376] reboot: --mtc restart
[  481.588812] reboot: Restarting system with command ''   # owner's menu reboot -> Android
```

No `ADDRCONF`/link-ready lines for eth0 in the recovery session (no userspace configured it),
and no ARP answer from `00:0a:cd:27:a5:b2` while parked - consistent with "interface exists,
no IP", not "no interface".

Earlier morning recovery session (captured by the script into `/cache/hu-evidence/console-ramoops-0`,
mixed buffer, board 307 `b.mode=normal` Android text + dongle bind at t=41208 when the owner plugged
it in) enumerated hub t=5.23 and WiFi t=5.66 but the dongle only when plugged mid-session; the
difference between sessions (hub+WiFi at boot vs dongle later) is not yet explained - candidate
causes: plug-in timing, MCU port-power event (`--mtc dis/ann`), board.sel gating.

## What this does NOT prove

- Whether `otg_mode` (root-writable, currently "host") does anything useful; semantics unmeasured.
- Why the morning recovery session did not enumerate the dongle at boot while the 16:28 one did.
- That `udhcpc`/`ifconfig` in recovery yields a working lease (never attempted; script stalled before net phase).
- pstore buffer mechanics (accumulate vs rewrite) - records mix boots; treat `/cache` files as the primary channel.

## Proposed next step

Step 2 (read-only live snapshot into `/cache/state-android.txt` + workstation) then Step 3
probe-only recovery build. Given this finding, Step 3's state service should prove `eth0` presence
in recovery at t=3 s, and the net phase (nonce-gated) can be enabled in the SAME later build once
the linear stub replaces the stalled digest logic - the enumeration question is answered.
