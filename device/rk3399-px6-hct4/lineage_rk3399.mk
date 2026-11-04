# Product config for the PX6 HU head unit. Deployed as device/rockchip/rk3399/lineage_rk3399.mk.
$(call inherit-product, $(SRC_TARGET_DIR)/product/base.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/base_product.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit.mk)

# LineageOS SDK pieces (present once vendor/lineage is in the tree).
$(call inherit-product-if-exists, vendor/lineage/config/common.mk)
$(call inherit-product-if-exists, vendor/lineage/config/auto_prebuilt_apks.mk)

$(call inherit-product, $(LOCAL_DIR)/device.mk)

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
