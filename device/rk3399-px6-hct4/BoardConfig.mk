# Board config for the PX6 HU (RK3399, 4 GB RAM, Mali-T860). Deployed as
# device/rockchip/rk3399/BoardConfig.mk.

# ---- architecture -------------------------------------------------------------
# The HCT apps are partly 32-bit, so keep the compat ABI set alive on arm64.
TARGET_ARCH := arm64
TARGET_ARCH_VARIANT := armv8-a
TARGET_CPU_ABI := arm64-v8a
TARGET_CPU_VARIANT := generic
TARGET_2ND_ARCH := arm
TARGET_2ND_ARCH_VARIANT := armv8-a
TARGET_2ND_CPU_VARIANT := generic
TARGET_CPU_ABI_LIST_64_BIT := arm64-v8a
TARGET_CPU_ABI_LIST_32_BIT := armeabi-v7a armeabi

# ---- vendor image -------------------------------------------------------------
# The vendor image is prebuilt (Daisaita Android 11 blobs + our HU overlays, see
# scripts/prebuilt_vendor.sh). system / product / system_ext / odm come from source.
# No VNDK snapshots: Android 14 builds against the framework and talks to the vendor
# through the HALs declared in the vendor manifest (target-level 5).
BOARD_PREBUILT_VENDORIMAGE := vendor/hct4/vendor.img

# ---- platform -----------------------------------------------------------------
TARGET_NO_BOOTLOADER := true
TARGET_BOARD_PLATFORM := rk3399
TARGET_BOARD_PLATFORM_GPU := mali-t860mp2
# gralloc/allocator/mapper 4.0 from the A11 vendor tree hand out dmabuf fds, so no ION path
# and no libion shim (docs/decisions.md D4/D9).
TARGET_USES_ION := false

# ---- kernel -------------------------------------------------------------------
# 4.19.193 #24 from the Daisaita Android 11 package: binderfs, ION CMA heap, POSIX ACL, and
# CONFIG_MALI_MIDGARD=y built-in (so /dev/mali needs no .ko). Its vermagic also matches the
# vendor module set (WiFi 5 GHz chips + usb_f_iap.ko for CarPlay).
TARGET_PREBUILT_KERNEL := vendor/hct4/prebuilt/kernel_a11
BOARD_KERNEL_BASE := 0x10000000
BOARD_KERNEL_PAGESIZE := 2048
BOARD_KERNEL_OFFSET := 0x00008000
BOARD_RAMDISK_OFFSET := 0x01000000
BOARD_SECOND_OFFSET := 0x00f00000
BOARD_TAGS_OFFSET := 0x00000100
BOARD_KERNEL_CMDLINE := console=ttyFIQ0 androidboot.baseband=N/A androidboot.wificountrycode=NL androidboot.veritymode=disabled androidboot.hardware=rk30board androidboot.console=ttyFIQ0 androidboot.verifiedbootstate=orange firmware_class.path=/vendor/etc/firmware init=/init rootwait ro loop.max_part=7 androidboot.selinux=permissive buildvariant=userdebug
# wificountrycode=NL, not the vendor default CN: CN marks channels 12/13 "no IR" and 14
# disabled, which is exactly the 2.4 GHz-only behaviour we measured on the unit.

# ---- boot / recovery ----------------------------------------------------------
BOARD_BOOT_HEADER_VERSION := 2
BOARD_INCLUDE_DTB_IN_BOOTIMG := false     # the vendor uboot supplies the DTB itself
BOARD_USES_RECOVERY_AS_BOOT := false      # the HU has its own recovery partition (mmcblk2p8)
BOARD_INCLUDE_RECOVERY_DTBO := false

# ---- dynamic partitions (decision D8: super 8 GiB, userdata 49.84 GiB) --------
BOARD_USE_DYNAMIC_PARTITIONS := true
BOARD_BUILD_SUPER_IMAGE_BY_DEFAULT := true
# Must be exactly the size sgdisk wrote for p14 - alignment can shave a few hundred KiB off the
# requested 8 GiB, and super's metadata then disagrees with the partition and Android refuses to
# boot. scripts/repartition_gpt.sh prints both numbers; paste them here and re-run
# `make superimage` (cheap, only re-stages the logical partitions) - no full rebuild needed.
BOARD_SUPER_PARTITION_SIZE := 8589934592
BOARD_SUPER_PARTITION_GROUPS := hct_dynamic_partitions
BOARD_HCT_DYNAMIC_PARTITIONS_SIZE := 8585710080    # 8 GiB minus 4 MiB metadata overhead
BOARD_HCT_DYNAMIC_PARTITIONS_PARTITION_LIST := system vendor product system_ext odm
BOARD_USES_METADATA_PARTITION := false

# ---- filesystem ---------------------------------------------------------------
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
