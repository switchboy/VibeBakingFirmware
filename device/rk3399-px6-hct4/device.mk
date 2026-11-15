# HU device config. Deployed as device/rockchip/rk3399/device.mk.

# ---- vendor blobs -------------------------------------------------------------
# Android 14's OTA packer needs a *built* vendor image (it wants a VENDOR/ staging directory,
# vendor.map and a vendor build.prop), so the stock Android 11 blobs are staged through the build
# instead of being used as BOARD_PREBUILT_VENDORIMAGE (docs/decisions.md D9 updated, docs/ota.md).
# scripts/prebuilt_vendor.sh extracts a stock vendor partition into the build tree (SHAPE=a10 ->
# vendor/hct4/tree_a10/vendor, the Android 10 reference and shape A; SHAPE=a11 -> tree/vendor, the
# fallback) and tools/gen_vendor_staging.py turns it into the two generated includes below. The blobs
# are copied byte-for-byte; tools/vendor_diff.py checks the generated image against the stock reference.
include device/rockchip/rk3399/vendor_staging.mk
include device/rockchip/rk3399/vendor_props.mk

# Android 14 has no VNDK, so a vendor binary cannot link a library the framework builds for /system
# unless that library is a *public* library (system/etc/linker.config.pb lists what the vendor
# namespace may load). tools/vendor_link_closure.py walks the DT_NEEDED graph of the kept blobs and
# asks for Android 14's own vendor variant of whatever they link and is not public - e.g.
# `android.hardware.wifi@1.4.vendor`, which Soong installs as /vendor/lib64/android.hardware.wifi@1.4.so.
# Requesting the module also makes it an install dependency of vendor.img, which is what
# build_image.py's file filter is built from; a hand-written file in the staging dir is not.
# The file is generated on the build host after a packaging pass, so `-include` (absent = nothing).
-include device/rockchip/rk3399/vendor_modules_extra.mk

# What Android 14 does not build at all: libion (system/core/libion is gone), libaudioroute (legacy
# audio has no audio_route module anymore) and libspeexresampler (external/speexresampler is gone).
# Those are imported byte-for-byte from the Android 10 reference as Soong modules in
# prebuilt_vendor_libs/Android.bp, and libaudioutils is asked for as Android 14's own vendor variant
# (system/media/audio_utils builds it with vendor_available: true). Module requests, not staging-dir
# files, because shape A builds superimage/bootimage without `m dist` - only an install dependency is
# guaranteed to survive build_image.py's file filter (pack25 lost an injected libchrome.so exactly this
# way). See vendor_libs.mk for the measured dependency list.
include device/rockchip/rk3399/vendor_libs.mk

# The head-unit app layer (**D24**): the HCT/Microntek apks are Soong modules (apps/Android.bp) and the
# control binaries, OEM libraries, init fragment, OEM config files and privapp whitelist are copy rules
# - all in one include so the app layer is one reviewable unit.
include device/rockchip/rk3399/hu_apps.mk

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
    device/rockchip/rk3399/init/hu-adb.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/hu-adb.rc \
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

# Bring-up access, without weakening adb. The unit ships no terminal and no su, so the ways in are USB
# adb, the FIQ serial console (`console=ttyFIQ0` in the boot cmdline) and the auto-probe service
# (/system/etc/init/hu_probe.rc). `ro.adb.secure=1` is assigned by build/make/core/main.mk:399, so
# assigning it here is a duplicate sysprop error, and setting it to 0 would drop authorization entirely
# (and needs removing at P6). Instead hu_probe.sh appends the workstation's own adb public key
# (/system/etc/hu_adb_key.pub) to /data/adb/adb_keys on first boot, so USB adb connects without the
# auth prompt on the unit - authorized by key, not by turning security off. `adb root` works regardless
# because ro.debuggable=1.

# ---- recovery OTA installer ---------------------------------------------------
# Recovery installs OTAs through `update_engine_sideload`: the recovery binary only links the
# update_engine *client* (its strings reference chromeos_update_engine.* and
# /system/bin/update_engine_sideload), and LineageOS's Updater app ships no native code. The
# module is declared `recovery: true` in system/update_engine/Android.bp, so listing it in
# PRODUCT_PACKAGES puts it in the recovery ramdisk. Without it "Local update" / ADB sideload in
# recovery has nothing to run the payload with.
PRODUCT_PACKAGES += \
    update_engine_sideload

# ---- vendor HAL services this product must pull in ------------------------------
# The stock Android 11 vendor partition ships the HIDL HAL services (audio, bluetooth, camera
# provider, GNSS, sensors, composer, health, memtrack, CAS, OMX) and the HIDL machinery they need
# (vndservicemanager, vndservice, libhwbinder). Those paths are *not* in PRODUCT_COPY_FILES any
# more (tools/vendor_conflicts.py drops every destination whose module defines an install rule, or
# ckati aborts with "overriding commands for target"), but Android 14 only *defines* the rule - it
# does not install the module unless the product asks for it. Without these, /vendor would have no
# HAL service at all: no audio, no bluetooth, no camera, no GPS, no sensors, no display composer,
# no battery health, and no HIDL service manager to start any of them. pack20 proved that: 173
# destinations were dropped, 66 landed in the image, 107 did not.
#
# The names below are exactly the modules `tools/vendor_module_names.py` attributes the 107 missing
# paths to (read out of out/soong/installs-lineage_rk3399.mk, so every name really exists). The
# service modules install their own /vendor/etc/init/<service>.rc, which is why the .rc paths are not
# listed separately. tools/vendor_dropped_check.py re-checks the image after every build.
PRODUCT_PACKAGES += \
    vndservicemanager \
    vndservice \
    libhwbinder \
    applypatch \
    android.hardware.audio.service \
    android.hardware.audio@6.0-impl \
    android.hardware.audio.effect@6.0-impl \
    android.hardware.audio.common-util \
    android.hardware.audio.common@6.0-util \
    libalsautils \
    libnbaio_mono \
    libavservices_minijail \
    libavservices_minijail_vendor \
    audio.r_submix.default \
    audio.usb.default \
    android.hardware.bluetooth@1.0-service \
    android.hardware.bluetooth@1.0-impl \
    android.hardware.camera.provider@2.4-service \
    android.hardware.camera.provider@2.4-external-service \
    android.hardware.camera.provider@2.4-impl \
    android.hardware.camera.provider@2.4-external \
    android.hardware.camera.provider@2.4-legacy \
    camera.device@1.0-impl \
    camera.device@3.2-impl \
    camera.device@3.3-impl \
    camera.device@3.4-impl \
    camera.device@3.4-external-impl \
    camera.device@3.5-impl \
    camera.device@3.5-external-impl \
    camera.device@3.6-external-impl \
    android.hardware.gnss@1.0-service \
    android.hardware.gnss@1.0-impl \
    android.hardware.sensors@1.0-service \
    android.hardware.sensors@1.0-impl \
    android.hardware.graphics.composer@2.1-service \
    android.hardware.graphics.composer@2.1-resources \
    libhwc2on1adapter \
    libhwc2onfbadapter \
    android.hardware.health@2.1-service \
    android.hardware.health@2.1-impl \
    android.hardware.memtrack@1.0-service \
    android.hardware.memtrack@1.0-impl \
    android.hardware.cas@1.2-service \
    android.hardware.media.omx@1.0-service \
    libstagefright_softomx \
    libstagefright_softomx_plugin \
    libstagefright_amrnb_common \
    libstagefright_enc_common \
    libstagefright_flacdec \
    libopus \
    libvpx \
    libvorbisidec \
    libchrome \
    libdrm \
    libusb \
    libwifi-hal \
    android.hardware.wifi-service \
    wpa_supplicant \
    hostapd \
    libkeymaster4support \
    libkeystore-engine-wifi-hidl \
    libkeystore-wifi-hidl \
    libprotobuf-cpp-full-3.9.1-vendorcompat \
    libprotobuf-cpp-lite-3.9.1-vendorcompat \
    usb_modeswitch \
    usb_dongle \
    vulkan.pastel

# The OMX service is restored on purpose: the stock manifest declares android.hardware.media.omx@1.0
# (IOmx + IOmxStore), the staged blob carries the Rockchip VPU plugin (libomxvpu_enc/dec.so), and
# Android 14 still builds the OMX service and its soft-OMX/helper libraries. Whether the VPU plugin
# is actually reached is a device-test question, not a build one; leaving the HAL declared with no
# service would at least break software decode paths that go through OMX.
#
# WiFi is rebuilt, not carried over (**D21**): Android 14's wifi service has no HIDL support left
# (`grep -rl 'android.hardware.wifi@' frameworks/opt/net/wifi/service/java/ -> 0 files`), so the staged
# `android.hardware.wifi@1.0-service` blob has no consumer and cannot provide WiFi on this ROM. The
# three modules above are Android 14's own: `android.hardware.wifi-service` is the AIDL chip HAL
# (`hardware/interfaces/wifi/aidl/impl`), and `wpa_supplicant`/`hostapd` are the AIDL supplicant and
# hostapd services (`external/wpa_supplicant_8`, whose Make rules carry the
# `android.hardware.wifi.supplicant.xml` / `.hostapd.xml` manifest fragments and the service .rc files).
# `libwifi-hal` then selects `libwifi-hal-rtk` through BOARD_WLAN_DEVICE (see BoardConfig.mk). The
# kernel driver needs nothing: `8188eu.ko` is a cfg80211/nl80211 driver, loaded by hu_insmod.sh.
#
# Two Android 11-era vendor binaries are made loadable rather than swapped (**D23**):
#   * `bin/rockchip.drmservice` (kept blob, 32-bit ARM) needs `wifi_load_driver`, and the only
#     provider is libwifi-hal - which upstream compiles for the primary arch only. The patch in
#     patches/frameworks-opt-net-wifi-libwifi-hal-32bit.patch makes it `both`, so /vendor/lib gets a
#     32-bit copy too and the blob resolves. It loads the WiFi driver and hands the MAC in
#     /sys/class/net/wlan0/address to the MCU through /data/misc/wifi/wlan_mac + /dev/mtc-car.
#   * `bin/usb_dongle` (kept blob, 64-bit) needs five legacy libsysutils symbols that Android 14
#     does not export for /vendor/lib64. It is rebuilt from Rockchip's published BSP source as
#     `usb_dongle` (device/rockchip/rk3399-px6-hct4/usb_dongle), same uevent handling and the same
#     `/vendor/bin/usb_modeswitch -W -v ... -p ... -c /vendor/etc/usb_modeswitch.d/...` invocation,
#     against Android 14's own libsysutils. Its blob copies are dropped in vendor_dest_skip_extra.txt.
#
# One deviation is declared, not restored: the RIL daemon and its libraries, because this unit has no
# cellular modem. See device/rk3399-px6-hct4/vendor_dest_deviations.txt.
