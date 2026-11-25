package org.vibebaking.launcher.logic;

/**
 * Settings keys and owner defaults for the launcher's car settings (spec S28-S31, S7, S25).
 * Defaults are exactly the owner's preferences from docs/homescreen.md (2026-11-24).
 * Pure Java: mirrored by tests/unit and grepped by tests/conformance.py.
 */
public final class SettingsKeys {
    private SettingsKeys() {}

    public static final String KEY_BACKLIGHT_MODE = "car_lights_backlight";   // nothing | dim
    public static final String KEY_BACKLIGHT_PERCENT = "car_lights_backlight_pct";
    public static final String KEY_THEME_ON_LIGHTS = "car_lights_theme";      // nothing | dark
    public static final String KEY_DARK_MODE = "dark_mode";                   // cycle | always_light | always_dark | car_lights
    public static final String KEY_REVERSE_VOLUME = "reverse_volume";         // unchanged | lower | mute
    public static final String KEY_REVERSE_VOLUME_PERCENT = "reverse_volume_pct";
    public static final String KEY_REVERSE_MCU = "reverse_volume_mcu";        // let MCU attenuate via ctl_backview_vol
    public static final String KEY_VALET_TIMEOUT_S = "valet_timeout_s";
    public static final String KEY_FAV_SLOTS = "fav_slots";      // bottom favourite row, 4 slots (S40)
    public static final String KEY_BT_DIAL_TAB = "bt_dial_tab";  // BT MainActivity tab index (S40a)
    public static final String KEY_VALET_AUTO = "valet_auto";                 // needs the HCT BT stack
    public static final String KEY_VALET_ENABLED = "valet_enabled";           // master switch (S27a)
    public static final String KEY_MAP_TARGET = "map_target";                 // auto | maps | waze
    public static final String KEY_LAT = "radar_lat";
    public static final String KEY_LON = "radar_lon";

    // Owner defaults (homescreen.md). Do not change without the owner.
    public static final String DEFAULT_BACKLIGHT_MODE = "nothing";
    public static final int DEFAULT_BACKLIGHT_PERCENT = 40;
    public static final String DEFAULT_THEME_ON_LIGHTS = "nothing";
    public static final String DEFAULT_DARK_MODE = "cycle";
    public static final String DEFAULT_REVERSE_VOLUME = "lower";
    public static final int DEFAULT_REVERSE_VOLUME_PERCENT = 30;
    public static final boolean DEFAULT_REVERSE_MCU = false;
    public static final int DEFAULT_VALET_TIMEOUT_S = 60;
    // Auto-entry is the owner's spec intent (homescreen.md: enter automatically when no trusted
    // phone connects within the timeout). The master switch (valet_enabled) stays off by default,
    // so nothing happens until the owner configures an exit path (S26a/S27a).
    public static final boolean DEFAULT_VALET_AUTO = true;
    public static final boolean DEFAULT_VALET_ENABLED = false;   // inert until configured (S27a)
    public static final String DEFAULT_MAP_TARGET = "auto";
    public static final double DEFAULT_LAT = 52.10;   // De Bilt, NL — owner default position
    public static final double DEFAULT_LON = 5.18;    // (live GPS fixes are read in memory by LauncherActivity, never persisted)
    public static final int DEFAULT_BT_DIAL_TAB = 0;  // BT MainActivity tab index (verified on unit, A13)

    public static final String MCU_BACKVIEW_VOL_CMD = "ctl_backview_vol";

    /** Timeout pref clamp: garbage values must never fire the auto-entry timer immediately. */
    public static int clampTimeoutS(int v) {
        if (v < 10) return 10;
        if (v > 3600) return 3600;
        return v;
    }
}
