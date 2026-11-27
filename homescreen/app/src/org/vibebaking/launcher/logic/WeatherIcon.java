package org.vibebaking.launcher.logic;

import java.util.Locale;
import java.util.Map;

/**
 * Pure weather policy (owner request 2026-11-27): WMO weather code + is_day -> icon, temperature
 * formatting, Open-Meteo `current` JSON parsing, the HCTCanBus outside-air string parser, the
 * car-sensor preference rule and privacy coordinate rounding. Open-Meteo (CC BY 4.0, see
 * homescreen/CREDITS.md), no API key: `current=temperature_2m,weather_code,is_day`.
 * Java 8; every entry point is total - nothing throws, junk yields null/"".
 */
public final class WeatherIcon {

    public enum Icon { SUN, MOON, SUN_CLOUD, MOON_CLOUD, CLOUD, FOG, RAIN, POURING, SNOW, THUNDER }

    public static final String BASE_URL = "https://api.open-meteo.com/v1/forecast";
    public static final String CURRENT_FIELDS = "temperature_2m,weather_code,is_day";
    public static final long REFRESH_MS = 15 * 60_000L;          // refresh while the home screen is visible
    public static final long CAR_TEMP_FRESH_MS = 10 * 60_000L;   // the car's sensor beats Open-Meteo for 10 min
    public static final int MAX_BODY_BYTES = 64_000;             // `current` is ~1 KB; cap hostile bodies

    private WeatherIcon() {}

    /** WMO code + day flag -> icon (owner table 2026-11-27); anything unknown falls back to CLOUD. */
    public static Icon iconFor(int code, boolean day) {
        switch (code) {
            case 0: case 1: return day ? Icon.SUN : Icon.MOON;
            case 2: return day ? Icon.SUN_CLOUD : Icon.MOON_CLOUD;
            case 3: return Icon.CLOUD;
            case 45: case 48: return Icon.FOG;          // fog + glaze fog (VAG regions get these a lot)
            case 51: case 53: case 55: case 56: case 57: case 61: case 80: return Icon.RAIN;
            case 63: case 65: case 66: case 67: case 81: case 82: return Icon.POURING;
            case 71: case 73: case 75: case 77: case 85: case 86: return Icon.SNOW;
            case 95: case 96: case 99: return Icon.THUNDER;
            default: return Icon.CLOUD; // anything else: stay neutral
        }
    }

    /** Drawable resource name for an icon; the activity maps these names to R.drawable.* ids. */
    public static String drawableName(Icon icon) {
        switch (icon) {
            case SUN: return "ic_wx_sun";
            case MOON: return "ic_wx_moon";
            case SUN_CLOUD: return "ic_wx_sun_cloud";
            case MOON_CLOUD: return "ic_wx_moon_cloud";
            case CLOUD: return "ic_wx_cloud";
            case FOG: return "ic_wx_fog";
            case RAIN: return "ic_wx_rain";
            case POURING: return "ic_wx_pouring";
            case SNOW: return "ic_wx_snow";
            case THUNDER:
            default: return "ic_wx_thunder";
        }
    }

    /**
     * Celsius -> rounded whole degrees with a degree sign, decimals never shown:
     * 8.3 -> "8°", -0.4 -> "0°" (never "-0°"), -3.6 -> "-4°". NaN/infinite -> "" (stay hidden).
     */
    public static String formatTemp(double celsius) {
        if (Double.isNaN(celsius) || Double.isInfinite(celsius)) return "";
        int r = (int) Math.round(celsius);
        if (r == 0) return "0\u00B0"; // -0.4 rounds to 0: print "0°", the sign must not appear
        return r + "\u00B0";
    }

    /** The Open-Meteo `current` block; fields stay null when missing or garbled. */
    public static final class Reading {
        public final Double tempC;
        public final Integer wmoCode;
        public final Boolean day;
        public Reading(Double tempC, Integer wmoCode, Boolean day) {
            this.tempC = tempC; this.wmoCode = wmoCode; this.day = day;
        }
    }

    /** Parse the Open-Meteo forecast body. Garbled/HTML/empty body or a missing `current` -> null. */
    public static Reading parseCurrent(String body) {
        try {
            Map<String, Object> root = Json.object(Json.parse(body));
            Object cur = root.get("current");
            if (cur == null) return null; // no current block: treat as offline
            Map<String, Object> c = Json.object(cur);
            Double t = Json.num(c.get("temperature_2m"));
            Double cd = Json.num(c.get("weather_code"));
            Integer code = cd == null ? null : Integer.valueOf((int) cd.doubleValue());
            Boolean day = null;
            Object flag = c.get("is_day");
            if (flag instanceof Boolean) day = (Boolean) flag;
            else {
                Double isDay = Json.num(flag);
                if (isDay != null) day = Boolean.valueOf(isDay.doubleValue() >= 1.0);
            }
            return new Reading(t, code, day);
        } catch (RuntimeException garbled) {
            return null; // truncated body or an HTML rate-limit page: offline, never a crash
        }
    }

    /**
     * HCTCanBus broadcast com.canbus.temperature, String extra "temperature": the format has
     * not been seen on a car yet (UNKNOWN until the first real frame), so parse the first
     * signed decimal anywhere in the string: "12.5", " -3 ", "12.5°C" -> value; "abc"/null -> null.
     */
    public static Double parseCanTemp(String raw) {
        if (raw == null) return null;
        int n = raw.length();
        for (int i = 0; i < n; i++) {
            char ch = raw.charAt(i);
            if (ch != '-' && ch != '+' && (ch < '0' || ch > '9')) continue;
            if (i > 0) {
                char prev = raw.charAt(i - 1);
                // A sign or digit right before this one belongs to an earlier (failed) attempt:
                // "--3" is junk, not a positive 3; "-3" itself is read at index 0.
                if (prev == '-' || prev == '+') continue;
            }
            int j = i;
            if (j < n && (raw.charAt(j) == '-' || raw.charAt(j) == '+')) j++;
            int digitsStart = j;
            while (j < n && raw.charAt(j) >= '0' && raw.charAt(j) <= '9') j++;
            if (j < n && raw.charAt(j) == '.') {
                j++;
                while (j < n && raw.charAt(j) >= '0' && raw.charAt(j) <= '9') j++;
            }
            if (j <= digitsStart) continue; // a lone sign or no digit after the dot: not a number
            try {
                return Double.valueOf(raw.substring(i, j));
            } catch (NumberFormatException bad) {
                return null;
            }
        }
        return null;
    }

    /** Show the car sensor instead of Open-Meteo while its frame is younger than CAR_TEMP_FRESH_MS. */
    public static boolean preferCarTemp(long arrivedAt, long now) {
        long age = now - arrivedAt;
        if (age < 0) return true; // clock jumped backwards (boot/NTP): treat the frame as fresh
        return age <= CAR_TEMP_FRESH_MS;
    }

    /** Privacy rounding (owner rule): 1 decimal (~10 km) before any URL is built. */
    public static double round1(double v) { return Math.round(v * 10.0) / 10.0; }

    /**
     * Open-Meteo forecast URL. Coordinates are rounded to 1 decimal first, so full-precision
     * positions never leave the device; NaN falls back to the owner default (De Bilt).
     */
    public static String urlFor(double lat, double lon) {
        if (Double.isNaN(lat) || Double.isNaN(lon)) {
            lat = SettingsKeys.DEFAULT_LAT;
            lon = SettingsKeys.DEFAULT_LON;
        }
        return BASE_URL + "?latitude=" + fmt1(round1(lat)) + "&longitude=" + fmt1(round1(lon))
            + "&current=" + CURRENT_FIELDS;
    }

    private static String fmt1(double v) { return String.format(Locale.ROOT, "%.1f", v); }
}
