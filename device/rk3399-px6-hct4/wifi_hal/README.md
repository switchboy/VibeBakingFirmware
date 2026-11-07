# wifi_hal - Realtek WiFi HAL glue for Android 14 (**D21**)

`libwifi-hal-rtk`, a static library that Android 14's `libwifi-hal` pulls in when
`BOARD_WLAN_DEVICE := realtek` (`frameworks/opt/net/wifi/libwifi_hal/Android.bp`,
`build/make/core/board_config_wifi.mk`). Without a vendor implementation the build installs
`libwifi-hal-fallback`, whose `wifi_initialize` says "unsupported" - Android 14 then has no wifi at all,
because its framework dropped HIDL wifi entirely (`android.hardware.wifi@1.0-service` from the old
vendor is an orphan here).

**Provenance:** the `.cpp`/`.h` files are the published Realtek/Rockchip HAL glue from
`github.com/kimocoder/android_wifi_hal` (`hardware/realtek/wlan/wifi_hal`, commit `076d460`, each file
carries the Apache-2.0 AOSP header). `github.com/gugugaga-rockchip/android_hardware_rockchip_wifi`
branch `lineage-21.0` wires the same code for Android 14, and Rockchip's
`libwifi_hal/rk_wifi_ctrl.cpp` maps `0bda:0179` (this unit's RTL8188ETV) to `libwifi-hal-rtk.so`.

**Layout:** mirrors `hardware/broadcom/wlan/bcmdhd/wifi_hal/` in AOSP - the same era of code, the same
header libs (`libnetlink_iface_headers`, `libhardware_legacy_headers`), the same shared libs, which
`libwifi-hal` itself links.

**Known limits on this driver** (`8188eu.ko`, Realtek `v5.7.6_33076.20190419`, cfg80211/nl80211, no
vendor HAL hooks, `CONFIG_CFG80211_WEXT` off): gscan, RTM/RTT, offload and link-layer stats depend on
private driver commands that this driver does not implement, so those paths return errors. Scan,
connect and softap run over nl80211. That is enough for v1.
