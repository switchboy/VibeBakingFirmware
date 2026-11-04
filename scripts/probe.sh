#!/usr/bin/env sh
# Read-only probe for a PX6 head unit. Writes a Markdown report we can analyse offline.
#
# Copy this file to the SD card and run it there (Termux or any terminal app):
#   sh probe.sh                 -> writes probe.md in the same folder as the script
#   sh probe.sh report.txt      -> writes to an explicit path
# No absolute mount points are assumed: the report lands next to the script (or in the
# current directory if that is not writable).
#
# Nothing is written outside the chosen report file. No writes to /vendor, /system, /data.

# Output location: the directory the script lives in (the SD card wherever it is mounted),
# never a hard-coded global path. Override with: sh probe.sh <path/to/report.md>
OUT="${1:-}"
if [ -z "$OUT" ]; then
  here=$(dirname "$0")
  for cand in "$here/probe.md" ./probe.md; do
    d=$(dirname "$cand")
    if [ -d "$d" ] && [ -w "$d" ]; then OUT="$cand"; break; fi
  done
fi
[ -n "$OUT" ] || OUT=./probe.md
if ! : > "$OUT" 2>/dev/null; then
  echo "cannot write report to $OUT — run the script from a folder your shell can write to" >&2
  exit 1
fi

ROOT=0
[ "$(id -u)" = 0 ] && ROOT=1

sec() { printf '\n## %s\n\n' "$*" >> "$OUT"; }
cmd() {
  printf '```\n$ %s\n' "$*" >> "$OUT"
  # shellcheck disable=SC2068
  ($*) >> "$OUT" 2>&1 || printf '(failed: exit %s)\n' "$?" >> "$OUT"
  printf '```\n' >> "$OUT"
}
need_root() { printf '\n```\n(skipped: needs root)\n```\n' >> "$OUT"; }

{ echo "# PX6 head unit probe — $(date 2>/dev/null || echo unknown time)"; echo "root: $ROOT"; } >> "$OUT"

sec "Identity"
cmd getprop ro.build.fingerprint
cmd getprop ro.build.version.release
cmd getprop ro.build.version.sdk
cmd getprop ro.build.version.security_patch
cmd getprop ro.build.type
cmd getprop ro.build.tags
cmd getprop ro.hardware
cmd getprop ro.board.platform
cmd getprop ro.product.device
cmd getprop ro.product.model
cmd getprop ro.product.manufacturer
cmd getprop ro.product.vendor.model
cmd getprop ro.product.customer
cmd getprop ro.product.customer.sub
cmd getprop ro.product.model9
cmd getprop ro.product.manufacturer9
cmd getprop ro.product.version
cmd getprop ro.serialno
cmd getprop ro.boot.serialno
cmd getprop ro.target.product
cmd getprop ro.vndk.version
cmd getprop ro.product.ota.host

sec "Kernel"
cmd uname -a
cmd cat /proc/version
cmd cat /proc/cmdline
cmd lsmod
cmd ls -l /proc/config.gz
cmd cat /proc/config.gz
if [ "$ROOT" = 1 ]; then cmd dmesg | tail -n 120; else need_root; fi

sec "SELinux and privileges"
cmd getenforce
cmd id
cmd ps -Z
cmd ls -Z /dev/mtc* /dev/ttyS* /dev/ttyV* /dev/goc_serial /dev/rtkbt_dev /dev/rtk_btusb 2>/dev/null
cmd ls -d /vendor/magisk /sbin/su /system/bin/su /system/xbin/su 2>/dev/null
cmd which su
cmd su 0 id

sec "Storage layout (no root needed)"
cmd cat /proc/partitions
cmd ls -l /dev/block/by-name/
cmd df -h
cmd cat /proc/mounts
cmd ls -l /storage /mnt
cmd blockdev --getsize64 /dev/block/by-name/super
cmd blockdev --getsize64 /dev/block/by-name/userdata
if [ "$ROOT" != 1 ]; then need_root; fi

sec "VINTF / HAL surface"
cmd cat /vendor/etc/vintf/manifest.xml
cmd cat /system/etc/vintf/compatibility_matrix.xml
cmd ls -l /vendor/bin/hw
cmd ls /vendor/lib/hw /vendor/lib64/hw
cmd ls /vendor/lib/modules
cmd service list
cmd dumpsys -l | head -n 40

sec "Graphics / display"
cmd getprop ro.hardware.egl
cmd getprop ro.hwui.use_vulkan
cmd getprop ro.cpvulkan.version
cmd getprop ro.opengles.version
cmd getprop ro.sf.lcd_density
cmd dumpsys display | head -n 60
cmd dumpsys surfaceflinger | head -n 40

sec "Audio / DSP"
cmd getprop ro.product.dspmode
cmd getprop ro.product.dspconfig
cmd getprop ro.product.dspversion
cmd ls -l /vendor/etc/audio_policy_configuration.xml /vendor/etc/audio_effects.xml
cmd dumpsys audio | head -n 40

sec "Head-unit control plane"
cmd getprop ro.factory.hasGPS
cmd getprop vendor.gps.channel
cmd getprop vendor.bluetooth.channel
cmd getprop ro.rk.bt_enable
cmd getprop hct.canbus.service
cmd getprop bt.goc.type
cmd getprop bt.md725.type
cmd getprop carplay.type
cmd getprop sys.hctcarbox.enable
cmd getprop ro.product.sdcardswap
cmd ls -l /system/bin | grep -Ei 'mtc|canbus|goc|sdsdk|bluelet|brlink|hct|z-link|sd-link|usbmux|glgps|amp|dsp'
cmd cat /init.hct.rc
cmd cat /vendor/etc/init/hw/init.rk30board.rc | head -n 80

sec "WiFi / Bluetooth radio (CarPlay/AA needs 5 GHz)"
cmd ls -l /sys/class/net
cmd cat /proc/net/wireless
cmd cat /sys/class/net/wlan0/device/modalias 2>/dev/null
cmd cat /sys/class/net/wlan0/macaddress 2>/dev/null
cmd iw dev
cmd iw list | grep -A 30 'Frequencies' | head -n 60
cmd iw reg get
cmd getprop wifi.interface
cmd getprop persist.bluetooth.rtkcoex
cmd getprop ro.bt.bdaddr_path
cmd cat /data/misc/bluetooth/bdaddr
cmd cat /proc/bluetooth/sleep/btwrite

sec "Apps installed"
cmd pm list packages -f
cmd ls /system/app /system/priv-app /system_ext/app /product/app 2>/dev/null
cmd pm list packages -3

sec "Current firmware backup availability"
cmd ls -l /sdcard /storage/sdcard0 2>/dev/null | head -n 40
printf 'Question for the owner: do you have a copy of the firmware zip currently installed on this unit?\n' >> "$OUT"

sec "If root is available (extra detail)"
if [ "$ROOT" = 1 ]; then
  cmd ls -lZ /dev/block/by-name/
  cmd cat /sys/firmware/devicetree/base/model
  cmd cat /proc/mounts
  cmd magisk -v
  cmd cat /init.hct.rc
  cmd ls -lZ /dev/mtc*
else
  printf '\nMost partition sizes and kernel config above failed without root. Run as root if your firmware has a root terminal.\n' >> "$OUT"
fi

echo "report written to $OUT"
