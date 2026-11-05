# HU device config. Deployed as device/rockchip/rk3399/device.mk.

# ---- vendor blobs -------------------------------------------------------------
# The vendor image is prebuilt from the Daisaita Android 11 package (docs/decisions.md D9)
# and set in BoardConfig.mk via BOARD_PREBUILT_VENDORIMAGE. Because the image is prebuilt,
# PRODUCT_COPY_FILES into $(TARGET_COPY_OUT_VENDOR) below are ignored by the build - they are
# listed here as documentation of what scripts/prebuilt_vendor.sh overlays into the image.
PRODUCT_COPY_FILES += \
    $(LOCAL_DIR)/fstab.rk30board:$(TARGET_COPY_OUT_VENDOR)/etc/fstab.rk30board \
    $(LOCAL_DIR)/configs/ueventd.rk30board.rc:$(TARGET_COPY_OUT_VENDOR)/etc/ueventd.rc \
    $(LOCAL_DIR)/configs/init.hu.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/hu.rc \
    $(LOCAL_DIR)/configs/hu_insmod.sh:$(TARGET_COPY_OUT_VENDOR)/etc/hu_insmod.sh

# ---- recovery -----------------------------------------------------------------
# Recovery mounts the same partition set as init, so it uses the same fstab. The path is spelled
# out: kati's LOCAL_DIR inside an inherited .mk is the AndroidProducts.mk directory, not this file's.
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
