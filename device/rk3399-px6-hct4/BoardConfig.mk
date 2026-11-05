# Board config for the PX6 HU (RK3399, 4 GB RAM, Mali-T860). Deployed as
# device/rockchip/rk3399/BoardConfig.mk.

# ---- architecture -------------------------------------------------------------
# The HCT apps are partly 32-bit, so keep a compat ABI on arm64: arm64-v8a primary, armeabi-v7a
# secondary plus legacy armeabi. Soong's device config takes the abis from TARGET_CPU_ABI /
# TARGET_2ND_CPU_ABI (build/make/core/soong_config.mk:67,72) - leaving TARGET_2ND_CPU_ABI unset gives
# the arm arch an empty Abi list and the NDK prebuilt STL module panics in getNdkStlLibDir.
TARGET_ARCH := arm64
TARGET_ARCH_VARIANT := armv8-a
TARGET_CPU_ABI := arm64-v8a
TARGET_CPU_VARIANT := generic
TARGET_2ND_ARCH := arm
TARGET_2ND_ARCH_VARIANT := armv8-a
TARGET_2ND_CPU_VARIANT := generic
# Soong's device config takes the abi lists from TARGET_CPU_ABI/TARGET_2ND_CPU_ABI
# (build/make/core/soong_config.mk:67,72). Without TARGET_2ND_CPU_ABI the arm arch gets an empty Abi
# list and the NDK prebuilt STL module panics in getNdkStlLibDir.
TARGET_2ND_CPU_ABI := armeabi-v7a
TARGET_2ND_CPU_ABI2 := armeabi

# ---- vendor image -------------------------------------------------------------
# The vendor image is prebuilt (Daisaita Android 11 blobs + our HU overlays, see
# scripts/prebuilt_vendor.sh). system / product / system_ext / odm come from source.
# No VNDK snapshots: Android 14 builds against the framework and talks to the vendor
# through the HALs declared in the vendor manifest (target-level 5).
BOARD_PREBUILT_VENDORIMAGE := vendor/hct4/vendor.img

# board_config.mk refuses a vendor image unless the copy-out names are explicit.
TARGET_COPY_OUT_VENDOR := vendor
TARGET_COPY_OUT_SYSTEM_EXT := system_ext
TARGET_COPY_OUT_PRODUCT := product
TARGET_COPY_OUT_ODM := odm

# ---- platform -----------------------------------------------------------------
TARGET_NO_BOOTLOADER := true
TARGET_BOARD_PLATFORM := rk3399
TARGET_BOARD_PLATFORM_GPU := mali-t860mp2
TARGET_BOOTLOADER_BOARD_NAME := rk3399
# main.mk turns these into vendor props (ro.hwui.use_vulkan / ro.sf.lcd_density); setting them here
# avoids the duplicate-assignment error that assigning them in device.mk causes.
TARGET_USES_VULKAN := false      # Mali-T860 has no Vulkan driver; the HCT apps use GLES
TARGET_SCREEN_DENSITY := 240
# gralloc/allocator/mapper 4.0 from the A11 vendor tree hand out dmabuf fds, so no ION path
# and no libion shim (docs/decisions.md D4/D9).
TARGET_USES_ION := false

# ---- kernel -------------------------------------------------------------------
# 4.19.193 #24 from the Daisaita Android 11 package: binderfs, ION CMA heap, POSIX ACL, and
# CONFIG_MALI_MIDGARD=y built-in (so /dev/mali needs no .ko). Its vermagic also matches the
# vendor module set (WiFi 5 GHz chips + usb_f_iap.ko for CarPlay).
TARGET_PREBUILT_KERNEL := vendor/hct4/prebuilt/kernel_a11
BOARD_KERNEL_PAGESIZE := 2048
BOARD_KERNEL_BASE := 0x00000000
BOARD_KERNEL_CMDLINE := console=ttyFIQ0 androidboot.baseband=N/A androidboot.wificountrycode=NL androidboot.veritymode=disabled androidboot.hardware=rk30board androidboot.console=ttyFIQ0 androidboot.verifiedbootstate=orange firmware_class.path=/vendor/etc/firmware init=/init rootwait ro loop.max_part=7 androidboot.selinux=permissive buildvariant=userdebug
# wificountrycode=NL, not the vendor default CN: CN marks channels 12/13 "no IR" and 14
# disabled, which is exactly the 2.4 GHz-only behaviour we measured on the unit.

# ---- boot / recovery ----------------------------------------------------------
# Partition sizes taken from the live unit's /proc/partitions: boot = 32768 KiB (mmcblk2p7),
# recovery = 98304 KiB (mmcblk2p8). Without these the build emits no boot.img/recovery.img at all
# (build/make/core/Makefile:1282 gates the boot image on BOARD_BOOTIMAGE_PARTITION_SIZE).
BOARD_BOOTIMAGE_PARTITION_SIZE := 33554432
BOARD_RECOVERYIMAGE_PARTITION_SIZE := 100663296
BOARD_FLASH_BLOCK_SIZE := 512
BOARD_BOOT_HEADER_VERSION := 2
BOARD_USES_RECOVERY_AS_BOOT := false      # the HU has its own recovery partition (mmcblk2p8)
# Do NOT declare BOARD_INCLUDE_RECOVERY_DTBO at all: the Makefile tests it with `ifdef`, so setting
# it to `false` still emits `--recovery_dtbo` with an empty value and mkbootimg aborts.

# Load addresses are read straight from the vendor's working boot.img (unpack_bootimg on
# analysis/daisaita_a11/boot/boot.img), so the vendor u-boot loads our image the same way:
#   kernel 0x10008000  ramdisk 0x11000000  second 0x10f00000  tags 0x10000100  dtb 0x11f00000
# The Makefile only passes --base/--pagesize/--cmdline; every offset has to come from here. It also
# never passes --header_version, so BOARD_BOOT_HEADER_VERSION alone gives header v0 - which cannot
# carry a DTB at all (our first boot.img came out header_version 0 with no dtb). Pass it explicitly.
BOARD_MKBOOTIMG_ARGS := --header_version 2 \
                        --kernel_offset 0x10008000 \
                        --ramdisk_offset 0x11000000 \
                        --second_offset 0x10f00000 \
                        --tags_offset 0x10000100 \
                        --dtb_offset 0x0000000011f00000 \
                        --second device/rockchip/rk3399/prebuilt/boot_second_logo.bin

# The vendor u-boot expects the DTB inside boot.img (the A11 boot.img embeds it; there is no
# separate dtb load step on this board's boot path). `second` is the Rockchip RSCE boot logo,
# which is what the vendor boot.img carries in the second-stage field - no `logo` partition exists
# on this unit, so keeping it preserves the boot animation.
BOARD_INCLUDE_DTB_IN_BOOTIMG := true
BOARD_PREBUILT_DTBIMAGE_DIR := device/rockchip/rk3399/prebuilt/dtb

# ---- dynamic partitions (decision D8: super 8 GiB, userdata 49.84 GiB) --------
BOARD_USE_DYNAMIC_PARTITIONS := true
BOARD_BUILD_SUPER_IMAGE_BY_DEFAULT := true
# ---- dynamic partitions (super) -----------------------------------------------
# p14's size must match BOARD_SUPER_PARTITION_SIZE exactly, or super's metadata disagrees with the
# partition and Android refuses to boot. Two sets are possible:
#
#   B. GPT untouched - CHOSEN for the first flash (D11): p14 stays 3186688 KiB = 3,263,168,512 B.
#      Our images total ~2.056 GB (system 922.4 + vendor 292.3 + product 456.1 + system_ext 384.7 +
#      odm 0.8 MB), so they fit with ~1.2 GB spare, and that is exactly the group the stock Android
#      10 rollback zip uses. The first flash writes super/boot/recovery only - no GPT rewrite.
#   A. Repartitioned (D8, needs a root/Boot-ADB shell): super = 8 GiB, userdata shrunk to ~49.84 GiB.
#      scripts/repartition_gpt.sh prints the exact numbers sgdisk wrote; paste them here once the
#      repartition has actually been applied and the ROM is proven to boot.
#
# Whichever is active, re-run `m superimage` (cheap: only re-stages logical partitions, no full
# build) and re-flash super.img.
BOARD_SUPER_PARTITION_SIZE := 3263168512
BOARD_SUPER_PARTITION_GROUPS := hct_dynamic_partitions
BOARD_HCT_DYNAMIC_PARTITIONS_SIZE := 3258974208    # super minus 4 MiB metadata overhead
# After the repartition (D8): BOARD_SUPER_PARTITION_SIZE := 8589934592
#                            BOARD_HCT_DYNAMIC_PARTITIONS_SIZE := 8585710080
BOARD_HCT_DYNAMIC_PARTITIONS_PARTITION_LIST := system vendor product system_ext odm

# ---- filesystem ---------------------------------------------------------------
# The HU has a 16 MiB `metadata` partition (mmcblk2p12, mounted at /metadata on the stock
# firmware). update_engine and vold use it (OTA metadata + /metadata/vold/metadata_encryption),
# and the OTA's wipe step erases it, so declare it.
BOARD_USES_METADATA_PARTITION := true
BOARD_SYSTEMIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_SYSTEM_EXTIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_PRODUCTIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_ODMIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_VENDORIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_USERDATAIMAGE_FILE_SYSTEM_TYPE := f2fs
TARGET_USERIMAGES_USE_EXT4 := true
TARGET_USERIMAGES_USE_F2FS := true

# ---- trust / SELinux ----------------------------------------------------------
# The stock firmware boots verifiedbootstate=orange and SELinux permissive; we keep
# permissive for the framework-only boot test (M3) and tighten sepolicy afterwards.
BOARD_AVB_ENABLE := false
WITH_PERMISSIVE_SELINUX := true
