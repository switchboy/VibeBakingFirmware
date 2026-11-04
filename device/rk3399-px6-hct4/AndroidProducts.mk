# LineageOS lunch targets for the PX6 HU.
# The tree scanner derives the target name from the .mk file name; LOCAL_PRODUCT_NAME makes
# the lunch target `lineage_rk3399` while PRODUCT_DEVICE stays `rk3399` (see README.md).
PRODUCT_LIST := $(wildcard $(LOCAL_DIR)/lineage_rk3399*.mk)
