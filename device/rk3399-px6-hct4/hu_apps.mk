# Head-unit app layer, staged from the reference Android 10 payload (**D24**).
# Included from device.mk. Paths are literal: a product-config .mk is included from AndroidProducts.mk,
# where $(LOCAL_DIR)/$(LOCAL_PATH) are whatever kati last set, so scripts/deploy_device.sh rejects them.
#
# Provenance: everything here was extracted from the reference payload (`extracted update.zip`,
# reassembled with tools/reassemble.py into tmp/ref-a10/{system,product}.img) and read out of the ext4
# images with tools/ext4_ls.py / debugfs - not off the live unit, because the owner's decision (Nov 7/8)
# is that the reference payload's images are the drop-in set for this MCU architecture. The blobs under
# hu_system/ are byte-for-byte copies of the payload (sha256 recorded in analysis/app_layer_stage.md);
# the apks under apps/ are re-signed by Soong, which changes their bytes on purpose - see apps/Android.bp.
#
# The apks are modules (apps/Android.bp), the binaries, libraries, init fragment, OEM data files and the
# privapp whitelist below are plain copies: none of them collides with a module Android 14 installs
# (tools/vendor_conflicts.py must say "no collisions").

PRODUCT_PACKAGES += \
    HCT4Radio \
    HCT4Music \
    HCT4Movie \
    HCT4FileBrowser \
    HCT4BlueTooth \
    HCT4BtMusic \
    HCT4UsbIpod \
    HCT8AmpSetup \
    HCTApkInstall \
    HCTAudioPreview \
    HCTAvin \
    HCTBackView \
    HCTCarCD \
    HCTCarRecoder \
    HCTCarTouch \
    HCTCivicusbipod \
    HCTControlInfo \
    HCTControlSettings \
    HCTDvd \
    HCTDVR_IR \
    HCTExtMovie \
    HCTExtMusic \
    HCTFactorySettings \
    HCTFrontView \
    HCTNaviSettings \
    HCTScreenClock \
    HCTSync \
    HCTTpms \
    HCTTv \
    HCTUpdateService \
    HCTWheelStudy \
    HCTWidget \
    HCTBlueToothManager \
    HCTCanBus \
    HCTExtAppDocker \
    HCTExtScreenClock \
    HCTManagerService

# ---- control binaries -----------------------------------------------------------
# `/system/bin` daemons that /system/etc/init/hct.rc starts when the BT chip type property is set
# (bt.goc.type / bt.md725.type): gocsdk*/sdsdk* are the Bluetooth-controller bridges on /dev/ttyS1,
# blueletd/brlinktd the IVT and BR-Link ones, sd_carplay the wired CarPlay helper. dhcpcd is the DHCP
# client for the eth tether path; Android 14's netd does not ship one, and nothing installs this name.
#
# Deliberately not copied:
#   * lsusb - the payload's `/system/bin/lsusb` is a symlink to `toybox` (6 bytes), and Android 14
#     installs that symlink itself, so a copy would collide with the toybox install rule.
#   * hctcanbusservice, sdsdk, fscsdkbw123's lib, sd-reverse.sh, adb-ec-server.sh, start_usbmuxd.sh -
#     /system/etc/init/hct.rc names them, but the reference payload does not contain them, so there is
#     nothing to copy. D24 records which services stay dead.
#   * vendingpatch.sh - a Google Play property patcher; this ROM ships no Play, so it is dead code.
#   * adbd, sh, busybox - Android 14 builds its own.
PRODUCT_COPY_FILES += \
    device/rockchip/rk3399/hu_system/bin/gocsdk:$(TARGET_COPY_OUT_SYSTEM)/bin/gocsdk \
    device/rockchip/rk3399/hu_system/bin/gocsdk5:$(TARGET_COPY_OUT_SYSTEM)/bin/gocsdk5 \
    device/rockchip/rk3399/hu_system/bin/gocsdk6:$(TARGET_COPY_OUT_SYSTEM)/bin/gocsdk6 \
    device/rockchip/rk3399/hu_system/bin/gocsdk8:$(TARGET_COPY_OUT_SYSTEM)/bin/gocsdk8 \
    device/rockchip/rk3399/hu_system/bin/gocsdkrf210:$(TARGET_COPY_OUT_SYSTEM)/bin/gocsdkrf210 \
    device/rockchip/rk3399/hu_system/bin/sdsdk6:$(TARGET_COPY_OUT_SYSTEM)/bin/sdsdk6 \
    device/rockchip/rk3399/hu_system/bin/sdsdk816:$(TARGET_COPY_OUT_SYSTEM)/bin/sdsdk816 \
    device/rockchip/rk3399/hu_system/bin/sdsdk835:$(TARGET_COPY_OUT_SYSTEM)/bin/sdsdk835 \
    device/rockchip/rk3399/hu_system/bin/sdsdk936:$(TARGET_COPY_OUT_SYSTEM)/bin/sdsdk936 \
    device/rockchip/rk3399/hu_system/bin/sdsdk968:$(TARGET_COPY_OUT_SYSTEM)/bin/sdsdk968 \
    device/rockchip/rk3399/hu_system/bin/blueletd:$(TARGET_COPY_OUT_SYSTEM)/bin/blueletd \
    device/rockchip/rk3399/hu_system/bin/brlinktd:$(TARGET_COPY_OUT_SYSTEM)/bin/brlinktd \
    device/rockchip/rk3399/hu_system/bin/sd_carplay:$(TARGET_COPY_OUT_SYSTEM)/bin/sd_carplay \
    device/rockchip/rk3399/hu_system/bin/dhcpcd:$(TARGET_COPY_OUT_SYSTEM)/bin/dhcpcd \
    device/rockchip/rk3399/hu_system/bin/ec_usb_filter:$(TARGET_COPY_OUT_SYSTEM)/bin/ec_usb_filter \
    device/rockchip/rk3399/hu_system/bin/sd-link.sh:$(TARGET_COPY_OUT_SYSTEM)/bin/sd-link.sh \
    device/rockchip/rk3399/hu_system/bin/z-link.sh:$(TARGET_COPY_OUT_SYSTEM)/bin/z-link.sh \
    device/rockchip/rk3399/hu_system/bin/hctlog.sh:$(TARGET_COPY_OUT_SYSTEM)/bin/hctlog.sh \
    device/rockchip/rk3399/hu_system/bin/ethtether.sh:$(TARGET_COPY_OUT_SYSTEM)/bin/ethtether.sh

# `ec_usb_filter` is not a binary: it is a 46-byte JSON list of USB vendor ids (3034, 1133, 7531) that
# the IVT/CarPlay side reads to decide which sticks are its own. Same destination as the payload had.

# ---- OEM libraries --------------------------------------------------------------
# Only the ones a kept binary or a kept apk actually names, checked with
# tools/hu_system_abi_check.py (DT_NEEDED + undefined symbols against Android 14's own /system libs):
#   blueletd -> libbt_platform.so -> libbluelet.so
#   brlinktd -> libbt_platform_brlinktd.so -> libbrlinktd.so
#   gocsdkrf210 -> libGbtsTask.so (BCM/CSR HCI stack)
#   HCTBlueToothManager -> System.loadLibrary("gocdfu") -> libgocdfu.so
#   HCTUpdateService -> System.loadLibrary("rockchip_update_jni") -> librockchip_update_jni.so (both arches)
# Not copied, with the reason recorded in analysis/app_layer_stage.md and **D24**: librga, libvibrator, libmdnssd,
# libradio_metadata (Android 14 installs its own copies of those names, so a copy would collide), and
# the Rockchip media/Rockit/OpenCV set (librockit*, libffmpeg_58.so, librockcv_java.so,
# libgralloc_priv.so, rockchip.hardware.*@1.0.so, android.hardware.mtc.mfi@1.0.so, librksoundsetting.so
# + librttinyxml.so) - no kept binary or apk names them, and lib/librockit_interface.so does not resolve
# on Android 14 anyway (11 libgui/libui symbols gone).
PRODUCT_COPY_FILES += \
    device/rockchip/rk3399/hu_system/lib/libGbtsTask.so:$(TARGET_COPY_OUT_SYSTEM)/lib/libGbtsTask.so \
    device/rockchip/rk3399/hu_system/lib/libbluelet.so:$(TARGET_COPY_OUT_SYSTEM)/lib/libbluelet.so \
    device/rockchip/rk3399/hu_system/lib/libbt_platform.so:$(TARGET_COPY_OUT_SYSTEM)/lib/libbt_platform.so \
    device/rockchip/rk3399/hu_system/lib/libbrlinktd.so:$(TARGET_COPY_OUT_SYSTEM)/lib/libbrlinktd.so \
    device/rockchip/rk3399/hu_system/lib/libbt_platform_brlinktd.so:$(TARGET_COPY_OUT_SYSTEM)/lib/libbt_platform_brlinktd.so \
    device/rockchip/rk3399/hu_system/lib/libgocdfu.so:$(TARGET_COPY_OUT_SYSTEM)/lib/libgocdfu.so \
    device/rockchip/rk3399/hu_system/lib/librockchip_update_jni.so:$(TARGET_COPY_OUT_SYSTEM)/lib/librockchip_update_jni.so \
    device/rockchip/rk3399/hu_system/lib64/librockchip_update_jni.so:$(TARGET_COPY_OUT_SYSTEM)/lib64/librockchip_update_jni.so

# ---- init fragment ------------------------------------------------------------
# `/init.hct.rc` in the payload is a root-of-system init file, which is where Android 10 kept its OEM
# init scripts. Android 14's init reads the directory instead (system/core/init/init.cpp:344
# `parser.ParseConfig("/system/etc/init")`), so it is deployed as /system/etc/init/hct.rc.
# The one deliberate edit: line 1 `import /init.hct.camera.rc` is dropped - that file does not exist in
# the payload (debugfs: "File not found by ext2_lookup"), and init logs a failed import for every boot
# if it is left in. Everything else is byte-for-byte: the /mnt/oem + /etc/bluesoleil setup, the
# chmod/chown of /dev/mtc-*, /dev/ttyS*, /dev/ttyV*, /dev/goc_serial, and the service definitions for
# the gocsdk*/sdsdk*/blueletd/brlinktd/carplay/nat/CANBUS daemons.
PRODUCT_COPY_FILES += \
    device/rockchip/rk3399/hu_system/etc/init/hct.rc:$(TARGET_COPY_OUT_SYSTEM)/etc/init/hct.rc

# ---- OEM data files -------------------------------------------------------------
# The payload's /system/etc holds config the apps and the BT controllers read. Android 14 installs none
# of these names (`gps_debug.conf` does, so it is not copied), so there is no collision.
# Not copied: /system/etc/init.d/00init_magisk + 01init (Magisk boot scripts - **D5/P6** forbids them),
# /system/etc/bluetooth/*.conf and the rtl8761/8821/8822 firmware blobs (the Android 10 Bluetooth stack
# reads them; Lineage 21's own Bluetooth stack reads its own config - see D24 for the Bluetooth gap),
# audio_effects.conf / media_profiles_V1_0.dtd / apns-conf.xml / mixer_paths.xml (Android 14 builds or
# vendors its own equivalents).
PRODUCT_COPY_FILES += \
    device/rockchip/rk3399/hu_system/etc/car_filter.xml:$(TARGET_COPY_OUT_SYSTEM)/etc/car_filter.xml \
    device/rockchip/rk3399/hu_system/etc/alarm_filter.xml:$(TARGET_COPY_OUT_SYSTEM)/etc/alarm_filter.xml \
    device/rockchip/rk3399/hu_system/etc/ec.conf:$(TARGET_COPY_OUT_SYSTEM)/etc/ec.conf \
    device/rockchip/rk3399/hu_system/etc/ec_conn_type:$(TARGET_COPY_OUT_SYSTEM)/etc/ec_conn_type \
    device/rockchip/rk3399/hu_system/etc/operator_table:$(TARGET_COPY_OUT_SYSTEM)/etc/operator_table \
    device/rockchip/rk3399/hu_system/etc/bluesoleil/TL.INI:$(TARGET_COPY_OUT_SYSTEM)/etc/bluesoleil/TL.INI

# ---- privileged permission whitelist --------------------------------------------
# Written from the apk manifests (tools/hct_apk_inventory.py --perms); best effort for v1, see the XML's
# own comment. The name is unique, so it collides with nothing.
PRODUCT_COPY_FILES += \
    device/rockchip/rk3399/apps/privapp-permissions-hct.xml:$(TARGET_COPY_OUT_SYSTEM)/etc/permissions/privapp-permissions-hct.xml
