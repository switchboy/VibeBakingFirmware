# HU device config. Deployed as device/rockchip/rk3399/device.mk.

# ---- vendor blobs -------------------------------------------------------------
# Android 14's OTA packer needs a *built* vendor image (it wants a VENDOR/ staging directory,
# vendor.map and a vendor build.prop), so the stock Android 11 blobs are staged through the build
# instead of being used as BOARD_PREBUILT_VENDORIMAGE (docs/decisions.md D9 updated, docs/ota.md).
# scripts/prebuilt_vendor.sh extracts the vendor partition into vendor/hct4/tree/vendor and
# tools/gen_vendor_staging.py turns it into the two generated includes below. The blobs are copied
# byte-for-byte; tools/vendor_diff.py checks the generated image against the stock reference.
include device/rockchip/rk3399/vendor_staging.mk
include device/rockchip/rk3399/vendor_props.mk

# The Android 14 framework matrices do not know the Rockchip/MTC HALs, so they need our own
# framework matrix entries; see device/rk3399-px6-hct4/vintf/device_framework_matrix.xml.
DEVICE_FRAMEWORK_COMPATIBILITY_MATRIX_FILE += \
    device/rockchip/rk3399/vintf/device_framework_matrix.xml

# ---- our HU files -------------------------------------------------------------
# These four override the stock equivalents (the generator leaves those paths out of the copy list).
# The paths are spelled out literally, not as $(LOCAL_DIR)/$(LOCAL_PATH): a product config .mk is
# included from AndroidProducts.mk, so inside this file those variables are whatever kati last set -
# here `build/make/target/product/`. With $(LOCAL_DIR) ninja asked for
# 'build/make/target/product/fstab.rk30board' and failed: "missing and no known rule to make it".
PRODUCT_COPY_FILES += \
    device/rockchip/rk3399/fstab.rk30board:$(TARGET_COPY_OUT_VENDOR)/etc/fstab.rk30board \
    device/rockchip/rk3399/configs/ueventd.rk30board.rc:$(TARGET_COPY_OUT_VENDOR)/etc/ueventd.rc \
    device/rockchip/rk3399/configs/init.hu.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/hu.rc \
    device/rockchip/rk3399/configs/hu_insmod.sh:$(TARGET_COPY_OUT_VENDOR)/etc/hu_insmod.sh

# ---- recovery -----------------------------------------------------------------
# Recovery mounts the same partition set as init, so it uses the same fstab.
TARGET_RECOVERY_FSTAB := device/rockchip/rk3399/fstab.rk30board

# ---- framework-facing features ------------------------------------------------
# Without these the HCT apps refuse to run (GPS, tuner, AV-in, USB sticks). Each path is checked
# against the checkout by scripts/deploy_device.sh: `android.hardware.camera.any.xml` and
# `android.hardware.microphone.xml` do not exist in this AOSP revision, so they are not copied.
PRODUCT_COPY_FILES += \
    frameworks/native/data/etc/android.hardware.wifi.xml:$(TARGET_COPY_OUT_SYSTEM)/etc/permissions/android.hardware.wifi.xml \
    frameworks/native/data/etc/android.hardware.wifi.direct.xml:$(TARGET_COPY_OUT_SYSTEM)/etc/permissions/android.hardware.wifi.direct.xml \
    frameworks/native/data/etc/android.hardware.bluetooth.xml:$(TARGET_COPY_OUT_SYSTEM)/etc/permissions/android.hardware.bluetooth.xml \
    frameworks/native/data/etc/android.hardware.bluetooth_le.xml:$(TARGET_COPY_OUT_SYSTEM)/etc/permissions/android.hardware.bluetooth_le.xml \
    frameworks/native/data/etc/android.hardware.location.gps.xml:$(TARGET_COPY_OUT_SYSTEM)/etc/permissions/android.hardware.location.gps.xml \
    frameworks/native/data/etc/android.hardware.camera.xml:$(TARGET_COPY_OUT_SYSTEM)/etc/permissions/android.hardware.camera.xml \
    frameworks/native/data/etc/android.hardware.camera.front.xml:$(TARGET_COPY_OUT_SYSTEM)/etc/permissions/android.hardware.camera.front.xml \
    frameworks/native/data/etc/android.hardware.usb.host.xml:$(TARGET_COPY_OUT_SYSTEM)/etc/permissions/android.hardware.usb.host.xml \
    frameworks/native/data/etc/android.hardware.sensor.accelerometer.xml:$(TARGET_COPY_OUT_SYSTEM)/etc/permissions/android.hardware.sensor.accelerometer.xml \
    frameworks/native/data/etc/android.hardware.sensor.gyroscope.xml:$(TARGET_COPY_OUT_SYSTEM)/etc/permissions/android.hardware.sensor.gyroscope.xml \
    frameworks/native/data/etc/android.hardware.audio.output.xml:$(TARGET_COPY_OUT_SYSTEM)/etc/permissions/android.hardware.audio.output.xml \
    frameworks/native/data/etc/android.hardware.touchscreen.xml:$(TARGET_COPY_OUT_SYSTEM)/etc/permissions/android.hardware.touchscreen.xml \
    frameworks/native/data/etc/android.hardware.screen.landscape.xml:$(TARGET_COPY_OUT_SYSTEM)/etc/permissions/android.hardware.screen.landscape.xml \
    frameworks/native/data/etc/android.hardware.screen.portrait.xml:$(TARGET_COPY_OUT_SYSTEM)/etc/permissions/android.hardware.screen.portrait.xml \
    frameworks/native/data/etc/android.hardware.touchscreen.multitouch.jazzhand.xml:$(TARGET_COPY_OUT_SYSTEM)/etc/permissions/android.hardware.touchscreen.multitouch.jazzhand.xml \
    frameworks/native/data/etc/android.software.device_admin.xml:$(TARGET_COPY_OUT_SYSTEM)/etc/permissions/android.software.device_admin.xml

# ---- properties ---------------------------------------------------------------
# ro.hardware comes from the bootloader cmdline (androidboot.hardware=rk30board),
# which is what names the prebuilt HAL modules (hwcomposer.rk30board.so, gps.default.so).
#
# ro.hwui.use_vulkan and ro.sf.lcd_density are NOT set here: build/make/core/main.mk:337 puts
# `ro.hwui.use_vulkan=$(TARGET_USES_VULKAN)` and `ro.sf.lcd_density=$(TARGET_SCREEN_DENSITY)` into
# ADDITIONAL_VENDOR_PROPERTIES, so assigning them in device.mk makes post_process_props abort with
# "found duplicate sysprop assignments". Use the TARGET_* variables in BoardConfig.mk instead.
PRODUCT_PROPERTY_OVERRIDES += \
    ro.hardware.egl=mali \
    ro.opengles.version=196610 \
    dalvik.vm.heapsize=256m \
    dalvik.vm.heapgrowthlimit=192m \
    config.disable_rtt=true \
    media.stagefright.audio.deep=false

# The HU has no internal SD slot for /sdcard; USB sticks and the app-specific
# storage paths are what the HCT apps use.
PRODUCT_PROPERTY_OVERRIDES += \
    persist.sys.storage_manager.usb_storage=true \
    ro.storage_manager.enable_sdcard=false

# ---- recovery OTA installer ---------------------------------------------------
# Recovery installs OTAs through `update_engine_sideload`: the recovery binary only links the
# update_engine *client* (its strings reference chromeos_update_engine.* and
# /system/bin/update_engine_sideload), and LineageOS's Updater app ships no native code. The
# module is declared `recovery: true` in system/update_engine/Android.bp, so listing it in
# PRODUCT_PACKAGES puts it in the recovery ramdisk. Without it "Local update" / ADB sideload in
# recovery has nothing to run the payload with.
PRODUCT_PACKAGES += \
    update_engine_sideload
