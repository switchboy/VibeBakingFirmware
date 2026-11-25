package org.vibebaking.launcher;

import android.content.Context;
import android.content.SharedPreferences;

import org.vibebaking.launcher.logic.SettingsKeys;

/** SharedPreferences facade; defaults are SettingsKeys (owner defaults, spec S28-S31). */
public class SettingsStore {
    public static final String PREFS = "vibe_launcher";

    private final SharedPreferences p;

    public SettingsStore(Context c) {
        p = c.getApplicationContext().getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    public String getString(String key, String def) { return p.getString(key, def); }
    public int getInt(String key, int def) { return p.getInt(key, def); }
    public boolean getBool(String key, boolean def) { return p.getBoolean(key, def); }
    /**
     * SharedPreferences has no double API, so doubles are stored as raw bits in a long: exact for
     * lat/lon, and garbage values round-trip unchanged (the policy side clamps them).
     */
    public double getDouble(String key, double def) {
        return Double.longBitsToDouble(p.getLong(key, Double.doubleToRawLongBits(def)));
    }
    public void put(String key, String v) { p.edit().putString(key, v).apply(); }
    public void put(String key, int v) { p.edit().putInt(key, v).apply(); }
    public void put(String key, boolean v) { p.edit().putBoolean(key, v).apply(); }
    public void putDouble(String key, double v) { p.edit().putLong(key, Double.doubleToRawLongBits(v)).apply(); }

    public String backlightMode() { return getString(SettingsKeys.KEY_BACKLIGHT_MODE, SettingsKeys.DEFAULT_BACKLIGHT_MODE); }
    public int backlightPercent() { return getInt(SettingsKeys.KEY_BACKLIGHT_PERCENT, SettingsKeys.DEFAULT_BACKLIGHT_PERCENT); }
    public String themeOnLights() { return getString(SettingsKeys.KEY_THEME_ON_LIGHTS, SettingsKeys.DEFAULT_THEME_ON_LIGHTS); }
    public String darkMode() { return getString(SettingsKeys.KEY_DARK_MODE, SettingsKeys.DEFAULT_DARK_MODE); }
    public String reverseVolume() { return getString(SettingsKeys.KEY_REVERSE_VOLUME, SettingsKeys.DEFAULT_REVERSE_VOLUME); }
    public int reversePercent() { return getInt(SettingsKeys.KEY_REVERSE_VOLUME_PERCENT, SettingsKeys.DEFAULT_REVERSE_VOLUME_PERCENT); }
    public boolean reverseMcu() { return getBool(SettingsKeys.KEY_REVERSE_MCU, SettingsKeys.DEFAULT_REVERSE_MCU); }
    public int valetTimeoutS() {
        return SettingsKeys.clampTimeoutS(getInt(SettingsKeys.KEY_VALET_TIMEOUT_S, SettingsKeys.DEFAULT_VALET_TIMEOUT_S));
    }
    public boolean valetAuto() { return getBool(SettingsKeys.KEY_VALET_AUTO, SettingsKeys.DEFAULT_VALET_AUTO); }
    public boolean valetEnabled() { return getBool(SettingsKeys.KEY_VALET_ENABLED, SettingsKeys.DEFAULT_VALET_ENABLED); }
    public String mapTarget() { return getString(SettingsKeys.KEY_MAP_TARGET, SettingsKeys.DEFAULT_MAP_TARGET); }
    public double radarLat() { return getDouble(SettingsKeys.KEY_LAT, SettingsKeys.DEFAULT_LAT); }
    public double radarLon() { return getDouble(SettingsKeys.KEY_LON, SettingsKeys.DEFAULT_LON); }
    public String valetPinHash() { return getString("valet_pin_hash", ""); }
    public void setValetPin(String pin) { put("valet_pin_hash", org.vibebaking.launcher.logic.ValetPin.hashPin(pin)); }
    /** Owner opt-in extra packages allowed in valet mode (spec S21). Garbage CSV is tolerated. */
    public java.util.Set<String> valetExtras() {
        return org.vibebaking.launcher.logic.ValetPolicy.parseExtrasCsv(getString("valet_extras", ""));
    }

    /** Bottom favourite row (spec S40): 4 slots; slot 0 ships preinstalled with the BT dialler. */
    public java.util.List<String> favSlots() {
        return org.vibebaking.launcher.logic.FavoritePolicy.slots(getString(SettingsKeys.KEY_FAV_SLOTS, ""));
    }
    public void setFavSlots(java.util.List<String> slots) {
        put(SettingsKeys.KEY_FAV_SLOTS, org.vibebaking.launcher.logic.FavoritePolicy.csv(slots));
    }
    /** Which tab of the BT app MainActivity to open (spec S40a); garbage clamped. */
    public int btDialTab() {
        return org.vibebaking.launcher.logic.FavoritePolicy.dialTab(
            getInt(SettingsKeys.KEY_BT_DIAL_TAB, SettingsKeys.DEFAULT_BT_DIAL_TAB));
    }
    public void setBtDialTab(int tab) { put(SettingsKeys.KEY_BT_DIAL_TAB, tab); }
}
