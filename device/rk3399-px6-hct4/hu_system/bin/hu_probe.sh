#!/bin/sh
# hu_probe.sh - post-boot diagnostics for the PX6 HU running LineageOS 21 (docs/flash.md, D24).
#
# Baked into the ROM at /system/bin/hu_probe.sh (hu_apps.mk), so it survives every flash.
# Same shape as the Nov 5 probe (incoming/probe-20261105-1914.md): one markdown report with the
# owner's five success criteria as headings, errors/warnings where they exist, and honest
# "missing" markers where they do not. Read-only: never writes /system, /vendor, /data or
# anything partition-shaped; the only write is the report file.
#
# Usage (needs a shell with root or permissive-shell access; this ROM ships no su):
#   sh /system/bin/hu_probe.sh                  -> report printed, saved, copied to /mnt/udisk if mounted
#   sh /system/bin/hu_probe.sh http://HOST:PORT -> additionally uploads with curl -T (PUT), so a
#     workstation receiver like `nc -l 9000 > hu-probe.md` or a small http server works.
# If neither stick nor network is reachable the report is on stdout (serial console / ttyS ports).
set -u

URL=${1:-}
TS=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo unknown)
REPORT=/tmp/hu-probe-$TS.md
STICK=/mnt/udisk

# every line goes to stdout AND the report file (no `local`: /system/bin/sh is mksh)
sec()  { printf '\n## %s\n\n' "$1" | tee -a "$REPORT"; }
raw()  { printf '%s\n' "$1" | tee -a "$REPORT"; }
code() { printf '```\n%s\n```\n' "$1" | tee -a "$REPORT"; }
run() {  # run a command; its output (truncated) or an honest marker
  out=$(command -v "$1" >/dev/null 2>&1 && "$@" 2>&1 | head -60)
  if [ -n "${out:-}" ]; then code "$out"; else raw "missing or empty: $1"; fi
}

sec "header"
raw "hu_probe $TS ; uid=$(id -u) ; kernel=$(cut -s -d' ' -f1-3 /proc/version 2>/dev/null)"
raw "product: $(getprop ro.product.device) ; android $(getprop ro.build.version.release) ; $(getprop ro.build.display.id)"
raw "selinux: $(getenforce 2>/dev/null || echo unavailable) ; uptime: $(cat /proc/uptime 2>/dev/null)"
raw "cmdline: $(tr '\0' ' ' < /proc/cmdline 2>/dev/null)"

sec "init failures (kmsg)"
code "$(grep -iE "cannot|failed|denied|permission" /dev/kmsg 2>/dev/null | tail -40)"

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

sec "end"
raw "report: $REPORT"

if [ -d "$STICK" ]; then
  cp "$REPORT" "$STICK/hu-probe-$TS.md" 2>/dev/null && raw "report copied to stick: $STICK/hu-probe-$TS.md"
else
  raw "no /mnt/udisk mounted - stick fallback unavailable (mount the stick in Settings/Storage first, or rely on the LAN upload)"
fi
if [ -n "$URL" ]; then
  curl -T "$REPORT" "$URL" 2>/dev/null && raw "report uploaded to $URL" || raw "upload failed; report stays at $REPORT"
fi
