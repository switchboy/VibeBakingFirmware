# Product config for the PX6 HU head unit. Deployed as device/rockchip/rk3399/lineage_rk3399.mk.
# Paths are spelled out: $(LOCAL_DIR) inside an inherited product file points at the last
# AndroidProducts.mk directory that kati read, not at this file's directory.
# full_base.mk is base + product + generic_no_telephony - right for a head unit with no modem.
# 64-bit primary + 32-bit secondary zygote, and both abis. Must be inherited before core_minimal.mk
# in the chain, which is what full_base.mk pulls in.
$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/full_base.mk)

# LineageOS features: tablet-wifionly variant (no telephony stack, no SIM).
$(call inherit-product-if-exists, vendor/lineage/config/common_full_tablet_wifionly.mk)
$(call inherit-product-if-exists, vendor/lineage/config/auto_prebuilt_apks.mk)

$(call inherit-product, device/rockchip/rk3399/device.mk)

PRODUCT_NAME := lineage_rk3399
PRODUCT_DEVICE := rk3399
PRODUCT_BRAND := HCT
PRODUCT_MODEL := PX6
PRODUCT_MANUFACTURER := Microntek

# Keep the vendor OTA identity: the Daisaita packages assert ro.product.device == rk3399.
PRODUCT_PROPERTY_OVERRIDES += \
    ro.product.device=rk3399 \
    ro.product.model=PX6 \
    ro.product.device.rk30board=rk30board

PRODUCT_SHIPPING_API_LEVEL := 34
PRODUCT_USE_DYNAMIC_PARTITIONS := true
PRODUCT_ENFORCE_VINTF_MANIFEST := true
PRODUCT_CHARACTERISTICS := nosdcard
