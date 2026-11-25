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

    /** Solar noon in hours UTC for the given date. */
    static double solarNoonUtcHours(double lonDeg, LocalDate date) {
        return 12.0 - lonDeg / 15.0;
    }

    /** Hour angle H (hours) at latitude for the date; null when the sun never rises/sets. */
    static Double hourAngleHours(double latDeg, LocalDate date) {
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
        double cosH = (cosDeg(ZENITH) - sinDeg(latDeg) * sinDec) / (cosDeg(latDeg) * cosDec);
        if (cosH > 1.0 || cosH < -1.0) return null;
        return Math.toDegrees(Math.acos(cosH)) / 15.0;
    }

    /** UTC minutes-of-day of sunrise, or null. */
    public static Double sunriseUtcMinutes(double latDeg, double lonDeg, LocalDate date) {
        Double h = hourAngleHours(latDeg, date);
        return h == null ? null : (solarNoonUtcHours(lonDeg, date) - h) * 60.0;
    }

    public static Double sunsetUtcMinutes(double latDeg, double lonDeg, LocalDate date) {
        Double h = hourAngleHours(latDeg, date);
        return h == null ? null : (solarNoonUtcHours(lonDeg, date) + h) * 60.0;
    }

    /**
     * Is it night right now? Polar fallback: night during local 00-05h when the sun never
     * rises/sets that day.
     */
    public static boolean isNight(double latDeg, double lonDeg, long epochMillis, int tzOffsetHours) {
        LocalDate date = LocalDate.ofEpochDay(epochMillis / 86_400_000L);
        Double rise = sunriseUtcMinutes(latDeg, lonDeg, date);
        Double set = sunsetUtcMinutes(latDeg, lonDeg, date);
        double utcMin = (epochMillis / 60_000L) % 1440;
        if (rise == null || set == null) {
            double localHour = (utcMin / 60.0 + tzOffsetHours) % 24.0;
            return localHour < 5.0 || localHour >= 22.0;
        }
        return utcMin < rise || utcMin >= set;
    }

    private static double sinDeg(double d) { return Math.sin(Math.toRadians(d)); }
    private static double cosDeg(double d) { return Math.cos(Math.toRadians(d)); }

    public static int tzOffsetHours(long epochMillis, ZoneOffset zone) {
        return zone.getTotalSeconds() / 3600;
    }
}
