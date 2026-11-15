# Libraries the kept vendor blobs need and Android 14 does not build - requested as real modules so
# they become install dependencies and land in vendor.img (device.mk includes this file).
#
# Shape A's dependency list, measured Nov 15 with readelf -d on the reference firmware (docs/findings.md):
#   librga.so            -> libion.so            (composer/camera/OMX - the screen criterion)
#   audio.primary.rk30board.so -> libtinyalsa, libaudioutils, libaudioroute,
#                                 libhardware_legacy, libspeexresampler (the sound-input criterion)
#   mtc.mfi@1.0-service  -> libhardware_legacy   (the CANBUS criterion)
#
# Android 14 builds libtinyalsa, libhardware_legacy, libexpat, libdrm, libui, libhidlbase,
# libhidltransport and libaudioutils as vendor variants (vendor_available: true) - the closure requests
# those as <name>.vendor / <name>.vendor_32 in vendor_modules_extra.mk. What Android 14 does not build
# is libion, libaudioroute and libspeexresampler; those are the prebuilt modules in
# prebuilt_vendor_libs/Android.bp, byte-exact copies from the Android 10 reference system image.
#
# libaudioutils is listed here because it is a vendor variant of an AOSP module, not an import:
# system/media/audio_utils/Android.bp:35-36 declares it with vendor_available: true. Requesting the
# variant is what puts /vendor/lib64/libaudioutils.so and /vendor/lib/libaudioutils.so in the image.

PRODUCT_PACKAGES += \
    libion \
    libaudioroute \
    libspeexresampler \
    libaudioutils.vendor \
    libaudioutils.vendor_32
