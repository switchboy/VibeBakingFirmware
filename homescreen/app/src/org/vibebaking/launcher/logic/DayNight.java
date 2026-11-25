package org.vibebaking.launcher.logic;

import java.time.LocalDate;
import java.time.ZoneOffset;

/**
 * Day/night cycle from a position (spec S30): NOAA-style sunrise/sunset approximation.
 * Accuracy ~ a few minutes, good enough for a theme switch; the switch itself is animated.
 * Longitude east-positive.
 */
public final class DayNight {
    private DayNight() {}

    /** Official zenith incl. refraction, degrees. */
    private static final double ZENITH = 90.833;

    /** Sun never rises / never sets that day (polar day or polar night). */
    public enum Polar { NORMAL, NEVER_RISES, NEVER_SETS }

    /** Solar noon in hours UTC for the given date. */
    static double solarNoonUtcHours(double lonDeg, LocalDate date) {
        return 12.0 - lonDeg / 15.0;
    }

    /** cos(hour angle): < -1 = midnight sun, > 1 = polar night, NaN = unusable input. */
    static double cosHourAngle(double latDeg, LocalDate date) {
        double julianDay = date.toEpochDay() + 2440588.5; // epoch 1970-01-01 = JD 2440588.5
        double jc = (julianDay - 2451545.0) / 36525.0;
        double d = jc * 36525.0 + 0.181219;
        double meanLong = (280.459 + 0.9856476 * d) % 360.0;
        double meanAnom = (356.897 + 0.9856003 * d) % 360.0;
        double eqCenter = 1.917 * sinDeg(meanAnom) + 0.078 * sinDeg(2 * meanAnom)
                        + 0.017 * sinDeg(3 * meanAnom);
        double trueLong = meanLong + eqCenter;
        double sinDec = 0.3978263 * sinDeg(trueLong);
        double cosDec = Math.cos(Math.asin(sinDec));
        double cosLat = cosDeg(latDeg);
        if (cosLat == 0.0 || cosDec == 0.0) return Double.NaN; // poles: division by zero
        return (cosDeg(ZENITH) - sinDeg(latDeg) * sinDec) / (cosLat * cosDec);
    }

    /** Hour angle H (hours) at latitude for the date; null when the sun never rises/sets. */
    static Double hourAngleHours(double latDeg, LocalDate date) {
        double cosH = cosHourAngle(latDeg, date);
        if (Double.isNaN(cosH) || cosH > 1.0 || cosH < -1.0) return null;
        return Math.toDegrees(Math.acos(cosH)) / 15.0;
    }

    static Polar polarState(double latDeg, LocalDate date) {
        double cosH = cosHourAngle(latDeg, date);
        if (Double.isNaN(cosH)) return Polar.NORMAL;
        if (cosH < -1.0) return Polar.NEVER_SETS;  // midnight sun
        if (cosH > 1.0) return Polar.NEVER_RISES;  // polar night
        return Polar.NORMAL;
    }

    /** UTC minutes-of-day of sunrise (wrapped into a day), or null at the poles. */
    public static Double sunriseUtcMinutes(double latDeg, double lonDeg, LocalDate date) {
        Double h = hourAngleHours(clampLat(latDeg), date);
        return h == null ? null : wrapMinutes((solarNoonUtcHours(lonDeg, date) - h) * 60.0);
    }

    public static Double sunsetUtcMinutes(double latDeg, double lonDeg, LocalDate date) {
        Double h = hourAngleHours(clampLat(latDeg), date);
        return h == null ? null : wrapMinutes((solarNoonUtcHours(lonDeg, date) + h) * 60.0);
    }

    static double wrapMinutes(double m) { return ((m % 1440.0) + 1440.0) % 1440.0; }

    /**
     * Is it night right now? The comparison is done around solar noon with a wrapped hour
     * difference, so east/west longitudes that roll past UTC midnight classify correctly (a plain
     * "utcMin < rise || utcMin >= set" comparison gets Tokyo evenings wrong). Polar days are
     * decided outright: midnight sun = always day, polar night = always night.
     */
    public static boolean isNight(double latDeg, double lonDeg, long epochMillis, int tzOffsetHours) {
        double lat = clampLat(latDeg);
        double lon = clampLon(lonDeg);
        LocalDate date = LocalDate.ofEpochDay(Math.floorDiv(epochMillis, 86_400_000L));
        Polar p = polarState(lat, date);
        if (p == Polar.NEVER_RISES) return true;
        if (p == Polar.NEVER_SETS) return false;
        Double h = hourAngleHours(lat, date);
        double utcHour = (((epochMillis / 3_600_000.0) % 24.0) + 24.0) % 24.0;
        if (h == null || Double.isNaN(h)) {
            double localHour = ((utcHour + tzOffsetHours) % 24.0 + 24.0) % 24.0;
            return localHour < 5.0 || localHour >= 22.0; // last-resort fallback
        }
        double diff = utcHour - solarNoonUtcHours(lon, date);
        while (diff > 12.0) diff -= 24.0;
        while (diff < -12.0) diff += 24.0;
        return Math.abs(diff) > h;
    }

    /** Pref garbage (NaN / absurd coords) falls back to the owner's default position. */
    static double clampLat(double v) {
        if (Double.isNaN(v) || Double.isInfinite(v)) return SettingsKeys.DEFAULT_LAT;
        return Math.max(-85.0, Math.min(85.0, v));
    }

    static double clampLon(double v) {
        if (Double.isNaN(v) || Double.isInfinite(v)) return SettingsKeys.DEFAULT_LON;
        return Math.max(-180.0, Math.min(180.0, v));
    }

    private static double sinDeg(double d) { return Math.sin(Math.toRadians(d)); }
    private static double cosDeg(double d) { return Math.cos(Math.toRadians(d)); }

    public static int tzOffsetHours(long epochMillis, ZoneOffset zone) {
        return zone.getTotalSeconds() / 3600;
    }
}
