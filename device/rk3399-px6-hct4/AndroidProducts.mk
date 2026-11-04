# LineageOS lunch targets for the PX6 HU. Android 14's product scanner reads PRODUCT_MAKEFILES from
# AndroidProducts.mk files (PRODUCT_LIST is the old Android 5-era name), and derives the lunch target
# from the .mk file name. Our product file is lineage_rk3399.mk, so the lunch target is
# `lineage_rk3399` while PRODUCT_DEVICE stays `rk3399` (see README.md).
PRODUCT_MAKEFILES := $(LOCAL_DIR)/lineage_rk3399.mk

COMMON_LUNCH_CHOICES := \
    lineage_rk3399-ap2a-userdebug \
    lineage_rk3399-ap2a-user \
    lineage_rk3399-ap2a-eng
