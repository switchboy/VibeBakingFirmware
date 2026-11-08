#!/usr/bin/env bash
# Collects the facts we still need from the live PX6 unit. Run it ON the unit (root shell),
# ARCHIVED (Nov 9): superseded by scripts/probe.sh and the in-ROM /system/bin/hu_probe.sh
# (docs/decisions.md 'No terminal on the unit', docs/findings.md 'Post-boot probe').
# or from a PC:  adb shell "sh /sdcard/device_inspect.sh" > device-report.txt
#
# Safe: read-only, no writes outside /tmp.
set -u
OUT="${1:-/tmp/device_report.txt}"

say() { echo "== $*" >> "$OUT"; }
run() { say "$*"; ( $* ) >> "$OUT" 2>&1; echo >> "$OUT"; }

say "device report $(date -Iseconds)"
run getprop
run getprop ro.product.version
run getprop ro.build.fingerprint
run getprop ro.product.customer
run getprop ro.serialno
run uname -a
run cat /proc/cmdline
run cat /proc/version
run id
run getenforce
run su 0 id
run ls -l /dev/mtc* /dev/ttyS* /dev/ttyV* /dev/goc_serial 2>/dev/null
run df -h /data /system /vendor
run mount
run ls /proc/config.gz
run blockdev --getsize64 /dev/block/by-name/super
run ls -l /dev/block/by-name/
run cat /proc/partitions
run cat /sys/firmware/devicetree/base/model 2>/dev/null
run ls -d /vendor/magisk && ls -l /vendor/magisk
run ps -Z | grep -E "shell|root" | head -40
run lspd 2>/dev/null
run magisk -v 2>/dev/null
run service list
run dumpsys -l
run cat /vendor/etc/vintf/manifest.xml
run cat /system/etc/vintf/compatibility_matrix.xml
run dumpsys surfaceflinger | head -40
run cat /sys/class/net/*/address
run cat /data/misc/bluetooth/bdaddr
run cat /proc/bluetooth/sleep/btwrite
run cat /sys/devices/platform/*/dwmmc/mmc_host/mmc*/mmc*/mmc*/mcu_version 2>/dev/null
run getprop ro.product.model9
run getprop ro.product.manufacturer9
run ls /system/app /system/priv-app
run pm list packages -3rd 2>/dev/null || pm list packages | head -60
run logcat -d -b main -t 200
echo "report written to $OUT"
