#!/bin/sh
# hu_probe.sh - post-boot diagnostics for the PX6 HU running LineageOS 21 (docs/flash.md, D24).
#
# Baked into the ROM at /system/bin/hu_probe.sh (hu_apps.mk), so it survives every flash. Two ways in:
#   * automatically at boot, through /system/etc/init/hu_probe.rc (root, no terminal needed);
#   * by hand from any shell: adb - `ro.adb.secure` stays 1 (build/make/core/main.mk assigns it), so this
#     script injects the workstation's adb PUBLIC key into /data/adb/adb_keys, and ro.debuggable=1 then
#     allows `adb root`. Or the FIQ serial console (console=ttyFIQ0 in the boot cmdline).
# Same shape as the Nov 5 probe (incoming/probe-20261105-1914.md): one markdown report with the owner's
# success criteria as headings, errors/warnings where they exist, honest "missing" markers where they do
# not. Writes only three things: its report files (/tmp, /data/local/tmp, the stick copy) and, once, the
# workstation's adb public key into /data/adb/adb_keys. Nothing in /system, /vendor or anything
# partition-shaped is touched.
#
# Delivery, in order of reliability:
#   1. /data/local/tmp/hu-probe-<ts>.md          - pullable with adb, no root needed to read it
#   2. /mnt/udisk/hu-probe-<ts>.md               - the same stick that carried update.zip
#   3. stdout -> /dev/kmsg for the boot service   - readable later via adb/serial `dmesg`
#   4. `curl -T` upload, if a URL is available: first argument, else the property persist.hu.probe.url
#      (set it from adb: setprop persist.hu.probe.url http://<workstation>:9000/ ; workstation side:
#       nc -l 9000 > hu-probe.md).
set -u

URL=${1:-}
[ -z "$URL" ] && URL=$(getprop persist.hu.probe.url 2>/dev/null)
TS=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo unknown)
REPORT=/tmp/hu-probe-$TS.md
STICK=/mnt/udisk
PUBLIC=/data/local/tmp/hu-probe-$TS.md

# every line goes to stdout AND the report file (no `local`: /system/bin/sh is mksh)
sec()  { printf '\n## %s\n\n' "$1" | tee -a "$REPORT"; }
raw()  { printf '%s\n' "$1" | tee -a "$REPORT"; }
code() { printf '```\n%s\n```\n' "$1" | tee -a "$REPORT"; }
run() {  # run a command; its output (truncated) or an honest marker
  out=$(command -v "$1" >/dev/null 2>&1 && "$@" 2>&1 | head -60)
  if [ -n "${out:-}" ]; then code "$out"; else raw "missing or empty: $1"; fi
}

# When run by init at boot_completed the dexopt of the 37 shipped apks is still going and WiFi may not
# have associated yet; wait, then also wait for the stick to be mounted.
if [ "$(id -u)" = 0 ]; then
  sleep 60
  n=0
  while [ ! -d "$STICK" ] && [ "$n" -lt 6 ]; do sleep 20; n=$((n + 1)); done
fi

sec "header"
raw "hu_probe $TS ; uid=$(id -u) ; kernel=$(cut -s -d' ' -f1-3 /proc/version 2>/dev/null)"
raw "product: $(getprop ro.product.device) ; android $(getprop ro.build.version.release) ; $(getprop ro.build.display.id)"
raw "selinux: $(getenforce 2>/dev/null || echo unavailable) ; uptime: $(cat /proc/uptime 2>/dev/null)"
raw "cmdline: $(tr '\0' ' ' < /proc/cmdline 2>/dev/null)"
# AVB state, readable without root (init turns androidboot.* into ro.boot.* props). This decides
# whether a replaced boot.img is allowed at all: uboot here carries AVB plus a bootloader lock state
# (at-lock-vboot / avb_write_lock_state / "The device is locked, can not flash!"), and there is a
# vbmeta partition (mmcblk2p6). If device_state is "locked", Lineage's boot.img fails AVB verification
# ("Android avb boot failed") and no transport - recovery, adb dd, SD-burn - can boot Android 14.
raw "avb: device_state=$(getprop ro.boot.vbmeta.device_state) ; avb_version=$(getprop ro.boot.avb_version) ; vbmeta_digest=$(getprop ro.boot.vbmeta.digest | cut -c1-16)"

sec "init failures (kmsg)"
code "$(grep -iE "cannot|failed|denied|permission" /dev/kmsg 2>/dev/null | tail -40)"

sec "adb authorization (bring-up)"
# This build ships no terminal/su, and ro.adb.secure=1 comes from build/make/core/main.mk, so USB adb
# would ask for authorization on the unit's screen. Appending our own key to /data/adb/adb_keys lets the
# workstation connect without the prompt - authorization by key, not by turning security off. One key per
# line; only added once.
if [ "$(id -u)" = 0 ] && [ -f /system/etc/hu_adb_key.pub ]; then
  mkdir -p /data/adb 2>/dev/null
  if [ -f /data/adb/adb_keys ] && grep -qFf /system/etc/hu_adb_key.pub /data/adb/adb_keys 2>/dev/null; then
    raw "adb key already authorized in /data/adb/adb_keys"
  else
    printf '%s\n' "$(cat /system/etc/hu_adb_key.pub)" >> /data/adb/adb_keys 2>/dev/null &&
      chown root:root /data/adb /data/adb/adb_keys 2>/dev/null; chmod 0700 /data/adb 2>/dev/null;
      chmod 0600 /data/adb/adb_keys 2>/dev/null
    raw "adb key appended to /data/adb/adb_keys (sha256 $(sha256sum /data/adb/adb_keys 2>/dev/null | cut -c1-12))"
  fi
else
  raw "adb key injection skipped (uid $(id -u), key file $(ls /system/etc/hu_adb_key.pub 2>/dev/null || echo absent))"
fi

sec "wifi (criterion 3)"
run ip link show wlan0
raw "driver: $(readlink /sys/class/net/wlan0/device/driver 2>/dev/null || echo none) ; modalias: $(cat /sys/class/net/wlan0/device/device/modalias 2>/dev/null || echo none)"
raw "rtl modules present: $(ls /vendor/lib/modules 2>/dev/null | grep -ci rtl) ; 8188eu loaded: $(grep -c '^8188eu' /proc/modules 2>/dev/null || echo 0)"
run iw dev wlan0 info
run iw reg get
raw "wifi daemons: $(ps -A -o comm 2>/dev/null | grep -E 'wifi-service|wpa_supplicant|hostapd' | tr '\n' ' ')"
sec "wifi errors/warnings (logcat)"
code "$(logcat -d -v brief 2>/dev/null | grep -iE 'wifi|wpa|supplicant|rtk|8188' | grep -E ' E /| W /|error|fail' | head -30)"

sec "bluetooth (expected broken: no com.android.bluetooth in v1, D24)"
raw "framework app installed: $(pm list packages 2>/dev/null | grep -c '^package:com.android.bluetooth$')"
raw "hal binary: $(ls /vendor/bin/hw/*bluetooth* 2>/dev/null || echo none)"
raw "bt props: $(getprop | grep -iE 'bt\.|bluetooth' | head -8 | tr '\n' ';')"
sec "bluetooth/controller errors/warnings (logcat)"
code "$(logcat -d -v brief 2>/dev/null | grep -iE 'bluetooth|bluelet|brlink|gocsdk|sdsdk' | grep -E ' E /| W /|error|fail|CANNOT LINK' | head -30)"

sec "screen, touch, buttons (criteria 4+5)"
raw "input devices: $(ls /dev/input 2>/dev/null | tr '\n' ' ')"
run getevent -L
raw "mtc nodes: $(ls /dev/mtc-* 2>/dev/null | tr '\n' ' ')"
sec "input errors/warnings (logcat)"
code "$(logcat -d -v brief 2>/dev/null | grep -iE 'input|EventInjector|HCTCarTouch|mtc-key|uinput' | grep -E ' E /| W /|error|fail|denied' | head -30)"

sec "canbus (criterion 6)"
raw "/dev/mtc-car: $(ls -l /dev/mtc-car 2>/dev/null || echo missing)"
raw "canbus prop: $(getprop hct.canbus.service) ; java route: HCTCanBus talks to /dev/mtc-car directly"
raw "canbus daemons: $(ps -A -o comm 2>/dev/null | grep -iE 'canbus' | tr '\n' ' ')"
sec "canbus errors/warnings (logcat)"
code "$(logcat -d -v brief 2>/dev/null | grep -iE 'canbus|microntek' | grep -E ' E /| W /|error|fail|denied' | head -30)"

sec "audio output and sound input (criterion 7)"
raw "audio hal: $(ls /vendor/bin/hw/*audio* 2>/dev/null | tr '\n' ' ')"
raw "audioserver: $(ps -A -o comm 2>/dev/null | grep -c '^audioserver$' || echo 0)"
raw "asound cards: $(cat /proc/asound/cards 2>/dev/null | head -6 | tr '\n' ';')"
sec "audio errors/warnings (logcat)"
code "$(logcat -d -v brief 2>/dev/null | grep -iE 'audio|AudioFlinger|audioserver|tinyalsa|AudioTrack|AudioRecord|audio.primary' | grep -E ' E /| W /|error|fail' | head -30)"

sec "hct.rc daemons: alive counts"
for d in gocsdk gocsdk5 gocsdk6 gocsdk8 gocsdkrf210 sdsdk6 sdsdk816 blueletd brlinktd usb_dongle dhcpcd; do
  raw "$d: $(ps -A -o comm 2>/dev/null | grep -c "^$d$")"
done
code "$(dmesg 2>/dev/null | grep -iE 'usb_modeswitch|rtl8188|usb:v0BDA|CANNOT LINK' | tail -12)"

sec "packages installed (kept HCT set)"
code "$(pm list packages 2>/dev/null | grep -iE 'microntek|hct|extscreen|externshow|\.music' | head -45)"

sec "storage and mounts"
code "$(mount 2>/dev/null | head -25)"
raw "udisk contents: $(ls "$STICK" 2>/dev/null | head -10 | tr '\n' ' ')"

sec "one-line verdict"
raw "wifi: $(ip link show wlan0 2>/dev/null | grep -c 'state up') ; screen-input: $(ls /dev/input 2>/dev/null | grep -c event) ; mtc nodes: $(ls /dev/mtc-* 2>/dev/null | wc -l) ; audio hal: $(ls /vendor/bin/hw/*audio* 2>/dev/null | wc -l) ; bt app: $(pm list packages 2>/dev/null | grep -c '^package:com.android.bluetooth$')"

sec "end"
raw "report: $REPORT"

cp "$REPORT" "$PUBLIC" 2>/dev/null && raw "public copy: $PUBLIC (pullable with adb, no root needed)"
if [ -d "$STICK" ]; then
  cp "$REPORT" "$STICK/hu-probe-$TS.md" 2>/dev/null && raw "report copied to stick: $STICK/hu-probe-$TS.md"
else
  raw "no /mnt/udisk mounted after ~2 min - stick fallback unavailable; rely on $PUBLIC or the upload"
fi
if [ -n "$URL" ]; then
  curl -T "$REPORT" "$URL" 2>/dev/null && raw "report uploaded to $URL" || raw "upload failed; report stays at $REPORT"
fi
