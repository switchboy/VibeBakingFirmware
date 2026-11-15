#!/bin/sh
# Kernel module loader for the PX6 HU (replaces Rockchip's patched-init insmod step).
# Best-effort: a module that fails to load is reported and skipped, never fatal.
MODS=/vendor/lib/modules
INSMOD=/vendor/bin/insmod
[ -x "$INSMOD" ] || INSMOD=/vendor/bin/toybox_vendor
for m in aic8800_bsp aic8800_fdrv 8188eu 8188fu 8189fs 8723bu 8733bs \
         8821cs 8821cu 8822cs 8822bu usb_f_iap usb_f_iap2 sd_user_hid; do
    "$INSMOD" "$MODS/$m.ko" 2>/dev/null || echo "hu_insmod: $m not loaded"
done
# goodix is NOT attempted: CONFIG_TOUCHSCREEN_GT9XX=y is built into both vendor kernels
# (measured Nov 15 in analysis/hu_kernel_config_live-20261113.txt:2032 and
# analysis/daisaita_a11_kernel_config.txt:2070), so the touch driver is already registered and
# the goodix.ko the Android 11 dump ships would collide with it. Its absence changes nothing about
# the Nov 13 panic (docs/findings.md), which lives in the built-in driver.
# mali_kbase/bifrost/midgard .ko files in the vendor tree have vermagic 4.4.167 and cannot
# load against our 4.19 kernel; the GPU driver is built in (CONFIG_MALI_MIDGARD=y), so they
# are deliberately not attempted.
