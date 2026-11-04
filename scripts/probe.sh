#!/usr/bin/env sh
# Read-only probe for a PX6 head unit. Writes a Markdown report we can analyse offline.
#
# Copy this file to the SD card and run it there (Termux or any terminal app):
#   sh probe.sh                 -> writes probe.md in the same folder as the script
#   sh probe.sh report.txt      -> writes to an explicit path
# Do NOT use ./probe.sh: Android mounts removable/shared storage as noexec (and copies lose the
# +x bit), so the interpreter must read the file. If your shell cannot read the card at all:
#   cp /sdcard/probe.sh ~/ ; sh ~/probe.sh ; cp ~/probe.md /sdcard/
# No absolute mount points are assumed: the report lands next to the script (or in the
# current directory if that is not writable).
#
# Nothing is written outside the chosen report file. No writes to /vendor, /system, /data.

# Output location: explicit argument wins; else Termux's visible shared-storage Downloads
# (~/storage/downloads == /sdcard/Download) if it exists; else the folder the script lives in
# (the SD card on the head unit). Never a hard-coded global path. Override: sh probe.sh <path>
OUT="${1:-}"
if [ -z "$OUT" ]; then
  here=$(dirname "$0")
  for cand in "$HOME/storage/downloads/probe.md" "$here/probe.md" ./probe.md; do
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

sec "Tool availability (explains later failures)"
printf '```\n' >> "$OUT"
for t in getprop dumpsys pm ps lsmod iw blockdev df mount ls grep awk sed toybox su magisk; do
  printf '%-10s %s\n' "$t" "$(command -v "$t" || echo missing)" >> "$OUT"
done
printf '%-10s %s\n' "ls -Z" "$(ls -Z /dev/null >/dev/null 2>&1 && echo supported || echo unsupported)" >> "$OUT"
printf '```\n' >> "$OUT"

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

sec "Partition sizes via sysfs (works without root)"
printf '```\n' >> "$OUT"
# sysfs sizes are world-readable: every gendisk (/sys/block/<disk>/size) and every partition
# directory (/sys/block/<disk>/<part>/size) reports 512-byte sector counts.
sizes=$(
  for d in /sys/block/*/; do
    [ -d "$d" ] || continue
    if [ -f "$d/size" ]; then
      printf '%s %s\n' "$(basename "$d")" "$(( $(cat "$d/size" 2>/dev/null || echo 0) * 512 ))"
    fi
    for sub in "$d"*/; do
      [ -f "$sub/size" ] || continue
      printf '%s %s\n' "$(basename "$sub")" "$(( $(cat "$sub/size" 2>/dev/null || echo 0) * 512 ))"
    done
  done
)
printf 'sysfs block devices (name -> bytes):\n' >> "$OUT"
printf '%s\n' "$sizes" >> "$OUT"
printf '\n/dev/block/by-name mapping:\n' >> "$OUT"
for p in /dev/block/by-name/*; do
  [ -L "$p" ] || continue
  tgt=$(readlink "$p")
  bytes=$(printf '%s\n' "$sizes" | grep -m1 "^$(basename "$tgt") " | awk '{print $2}')
  printf '%-14s -> %-22s %s bytes\n' "$(basename "$p")" "$tgt" "${bytes:-unknown}" >> "$OUT"
done
printf '```\n' >> "$OUT"

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

sec "Reading this report"
cat >> "$OUT" <<'EOF'
- Sections that fail are expected on a phone or a non-rooted unit: `/dev/mtc*`, `/dev/ttyV*`,
  `/dev/goc_serial`, `/init.hct.rc`, `/proc/bluetooth/sleep/btwrite`, `blockdev --getsize64
  /dev/block/by-name/*`, `iw`, `dmesg`, `magisk` do not exist there.
- The sections that matter most on the head unit: Kernel, Storage layout, VINTF / HAL surface,
  Head-unit control plane, WiFi / Bluetooth radio.
- On a phone this report still tells us: Android version, SELinux mode, whether `ls -Z`/toybox
  features work, and which commands are missing in the unit's shell environment.
EOF

echo "report written to $OUT"
