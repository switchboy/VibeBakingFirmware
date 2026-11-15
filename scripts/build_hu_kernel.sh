#!/usr/bin/env bash
# build_hu_kernel.sh - build a kernel we actually own (**W3**, decision **D48**).
#
# The public Rockchip BSP (`github.com/rockchip-linux/kernel`, branch `develop-4.19`) is what is
# available without the vendor's GPL release, so this builds shape C: our own kernel, configured from
# the config the live unit reports (`analysis/hu_kernel_config_live-20261113.txt`), with the one-line
# gt9xx `phys` fix applied (candidate 21, **D45**'s accepted-risk route (a)).
#
# Two limits of the public tree are stated by the script rather than discovered later:
#   * it has no MTC/CAN/AV-in/tuner support, so a shape-C kernel cannot serve the CANBUS criterion
#     (**D48**), and the vendor blobs that need those drivers would load but never talk to the hardware;
#   * its `.ko` files carry *this* build's vermagic, so shape C must ship the modules this script
#     produces, not the stock ones - kernel, `.ko` vermagic and manifest target-level move together (**D46**).
#
# Nothing here touches the head unit. A kernel built by this script is card-booted before it may go to
# eMMC (**D47**: shape C needs a card boot; shape A's raw dd gate does not apply to it).
#
#   SHAPE_C=1 OUT=/tmp/hu-kernel CONFIG=/path/to/live.config KERNEL_SRC=/tmp/kernel-4.19 \
#   CROSS=aarch64-linux-gnu- JOBS=8 scripts/build_hu_kernel.sh   [prepare | build | report]
#
# Needs bash, not ash: the report stage uses process substitutions, so this is a build-host
# script, unlike the unit-side busybox scripts. Run on the NAS (root, plenty of disk under /tmp -
# SSData is tight). Launch long phases as
# `setsid nohup … > log 2>&1 < /dev/null &`.
set -eu

STAGE=${1:-prepare}
OUT=${OUT:-/tmp/hu-kernel}
KERNEL_SRC=${KERNEL_SRC:-/tmp/kernel-4.19}
BRANCH=${BRANCH:-develop-4.19}
REMOTE=${REMOTE:-https://github.com/rockchip-linux/kernel.git}
REPO=$(cd "$(dirname "$0")/.." && pwd)
CONFIG=${CONFIG:-$REPO/analysis/hu_kernel_config_live-20261113.txt}
JOBS=${JOBS:-8}
CROSS=${CROSS:-aarch64-linux-gnu-}
INSMOD="$REPO/device/rk3399-px6-hct4/configs/hu_insmod.sh"
IMG="$OUT/Image"
REPORT="$OUT/build-report.txt"

say() { printf '%s\n' "$1"; }

# The toolchain: a Debian cross-gcc (BSP 4.19 is a gcc-era tree, and Debian 13 ships gcc-aarch64-linux-gnu).
# AOSP's prebuilt clang can also build arm64 kernels, but it needs LD/AR/OBJCOPY/NM/STRIP pointed at the
# llvm tools and BSP 4.19 is not clang-clean, so it is not attempted here; if apt is unavailable, that is
# the fallback to work out. Which compiler was used is recorded, because the banner's gcc string is part
# of the identity of the kernel and its modules (vermagic must stay consistent, D46).
pick_toolchain() {
    if command -v "${CROSS}gcc" >/dev/null 2>&1; then
        echo "gcc"
    else
        echo ""
    fi
}

mkdir -p "$OUT"

case "$STAGE" in
prepare)
    say "== 1. fetch the public BSP =="
    if [ -d "$KERNEL_SRC/.git" ]; then
        git -C "$KERNEL_SRC" fetch --depth 1 origin "$BRANCH" >> "$REPORT" 2>&1 || \
            git -C "$KERNEL_SRC" fetch origin "$BRANCH" >> "$REPORT" 2>&1
        git -C "$KERNEL_SRC" checkout -f FETCH_HEAD >> "$REPORT" 2>&1
    else
        git clone --depth 1 --branch "$BRANCH" "$REMOTE" "$KERNEL_SRC" >> "$REPORT" 2>&1
    fi
    say "  src $KERNEL_SRC at $(git -C "$KERNEL_SRC" rev-parse --short HEAD)"

    say "== 2. configure from the live unit's config =="
    [ -s "$CONFIG" ] || { say "ABORT: no config at $CONFIG"; exit 1; }
    cp "$CONFIG" "$KERNEL_SRC/.config"
    make -C "$KERNEL_SRC" ARCH=arm64 CROSS_COMPILE="$CROSS" olddefconfig >> "$REPORT" 2>&1
    grep -c '^CONFIG_' "$KERNEL_SRC/.config" | sed 's/^/  CONFIG_ lines: /'

    # IKCONFIG_PROC=y is how we compare a running kernel against the config we built it from; dropping
    # it would make /proc/config.gz unreadable on the unit and cost the audit trail (docs/build-host.md).
    if grep -q '^CONFIG_IKCONFIG_PROC=y' "$KERNEL_SRC/.config"; then
        say "  CONFIG_IKCONFIG_PROC=y - /proc/config.gz will work on the unit"
    else
        say "  ! CONFIG_IKCONFIG_PROC is not set - add it; the live-vs-built config comparison depends on it"
        exit 1
    fi

    say "== 3. the gt9xx phys fix (candidate 21, D45 route a) =="
    # The vendor driver points input_dev->phys at a stack string that is dead once the probe frame is
    # gone, which is what panicked on Nov 13 (analysis/panic-20261113-2003-ramoops.txt). Mainline's
    # goodix.c assigns a constant instead.
    tc=$(find "$KERNEL_SRC/drivers/input/touchscreen" -name 'gt9xx*.c' 2>/dev/null | head -3)
    if [ -n "$tc" ]; then
        grep -n 'input_dev->phys' $tc | sed 's/^/  before: /'
        sed -i 's/input_dev->phys *= *"[^"]*"/input_dev->phys = "input\/ts"/' $tc
        grep -n 'input_dev->phys' $tc | sed 's/^/  after:  /'
    else
        say "  ! no gt9xx source found in $KERNEL_SRC/drivers/input/touchscreen - the fix cannot be applied here"
        say "    (the BSP branch may carry the driver elsewhere; check before shipping a shape-C kernel)"
    fi
    say "prepare done: $KERNEL_SRC configured, report at $REPORT"
    ;;

build)
    say "== build Image + modules =="
    tc=$(pick_toolchain)
    [ -n "$tc" ] || { say "ABORT: ${CROSS}gcc not found - install gcc-aarch64-linux-gnu (apt) or point CROSS at another cross toolchain"; exit 1; }
    say "  compiler: ${CROSS}gcc ($(${CROSS}gcc --version 2>/dev/null | head -1))"
    {
        echo "=== kernel build at $(date) with ${CROSS}gcc ==="
        make -C "$KERNEL_SRC" ARCH=arm64 CROSS_COMPILE="$CROSS" -j"$JOBS" Image
        make -C "$KERNEL_SRC" ARCH=arm64 CROSS_COMPILE="$CROSS" -j"$JOBS" modules
        make -C "$KERNEL_SRC" ARCH=arm64 CROSS_COMPILE="$CROSS" modules_install INSTALL_MOD_PATH="$OUT/modules"
    } >> "$REPORT" 2>&1
    [ -s "$IMG" ] || { say "ABORT: no $IMG - see $REPORT"; exit 1; }
    cp "$KERNEL_SRC/.config" "$OUT/config-built.txt"
    sha256sum "$IMG" | sed 's/^/  Image sha: /'
    say "build done: $IMG ($(stat -c %s "$IMG") B), modules under $OUT/modules"
    ;;

report)
    [ -s "$IMG" ] || { say "nothing built yet ($IMG missing) - run the build stage first"; exit 1; }
    # The build stage's log stays untouched; the audit report is a separate file so the compiler output
    # and the coupling facts are never mixed.
    REP2="$OUT/kernel-report.txt"
    : > "$REP2"
    say "== kernel ==" >> "$REP2"
    strings "$IMG" | grep -m1 'Linux version ' >> "$REP2"
    sha256sum "$IMG" >> "$REP2"

    say "== modules this kernel produces, against the list hu_insmod.sh loads ==" >> "$REP2"
    found=$(find "$OUT/modules" -name '*.ko' 2>/dev/null | wc -l)
    echo "  $found .ko built; vermagic: $(find "$OUT/modules" -name '*.ko' -exec strings {} \; 2>/dev/null | sed -n 's/.*vermagic=\([^ ]*\).*/\1/p' | sort -u | tr '\n' ' ')" >> "$REP2"
    mods=$(sed -n '/^for m in /,/do/p' "$INSMOD" | tr '\n' ' ' | tr -d '\\')
    mods=${mods#*for m in }; mods=${mods%; do*}
    missing=""
    for m in $mods; do
        if ! find "$OUT/modules" -name "$m.ko" -print 2>/dev/null | head -1 | grep -q .; then
            missing="$missing $m"
        fi
    done
    echo "  hu_insmod.sh modules missing from this kernel:$missing" >> "$REP2"

    say "== config differences against the live unit's config ==" >> "$REP2"
    diff <(grep -o '^CONFIG[A-Z0-9_]*=[ymns]' "$CONFIG" | sort) \
         <(grep -o '^CONFIG[A-Z0-9_]*=[ymns]' "$OUT/config-built.txt" | sort) | head -60 >> "$REP2"
    echo "  $(diff <(grep -o '^CONFIG[A-Z0-9_]*=[ymns]' "$CONFIG" | sort) <(grep -o '^CONFIG[A-Z0-9_]*=[ymns]' "$OUT/config-built.txt" | sort) | grep -c '^[<>]') differing lines" >> "$REP2"

    cat "$REP2"
    say "-- shape-C rules --"
    say "A kernel built here is card-booted before eMMC (D47), ships the modules from $OUT/modules"
    say "(their vermagic is this build's, not the stock 4.19.111+ set), and cannot serve CANBUS until"
    say "the vendor GPL source adds MTC/CAN/AV-in/tuner (D48). Nothing was written to the unit."
    ;;

*) echo "unknown stage '$STAGE' (prepare | build | report)"; exit 1 ;;
esac
