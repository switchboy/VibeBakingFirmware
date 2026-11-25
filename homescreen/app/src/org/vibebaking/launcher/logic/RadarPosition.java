package org.vibebaking.launcher.logic;

import java.util.List;

/**
 * Home/radar position policy (spec S15/S30): which of several location fixes to use, and when the
 * radar must recentre. Pure Java (Fix mirrors android.location.Location); the live position is
 * kept in memory only — it is never written to SharedPreferences or logged (owner privacy rule).
 * The fallback is the owner default (De Bilt, NL: SettingsKeys.DEFAULT_LAT/LON).
 */
public final class RadarPosition {

    /** Re-centre the radar when the position moved more than this many metres (owner: 5 km). */
    public static final double RECENTRE_METERS = 5000.0;

    /** One position fix: coordinates + timestamp (unix ms). */
    public static final class Fix {
        public final double lat;
        public final double lon;
        public final long timeMs;

        public Fix(double lat, double lon, long timeMs) {
            this.lat = lat; this.lon = lon; this.timeMs = timeMs;
        }

        public boolean valid() {
            return !Double.isNaN(lat) && !Double.isInfinite(lat) && lat >= -90 && lat <= 90
                && !Double.isNaN(lon) && !Double.isInfinite(lon) && lon >= -180 && lon <= 180;
        }
    }

    private RadarPosition() {}

    /** Newest valid fix; fallback (the owner default) when no usable fix is present. Never throws. */
    public static double[] choose(List<Fix> fixes, double[] fallback) {
        Fix best = null;
        if (fixes != null) {
            for (Fix f : fixes) {
                if (f == null || !f.valid()) continue; // GPS junk / absurd coords: ignore
                if (best == null || f.timeMs > best.timeMs) best = f;
            }
        }
        if (best == null) return new double[] { fallback[0], fallback[1] };
        return new double[] { best.lat, best.lon };
    }

    /**
     * Great-circle distance (haversine), true when it exceeds `meters`. A NaN previous position
     * reads as "unknown", which must recentre (the first real fix wins).
     */
    public static boolean movedFar(double lat1, double lon1, double lat2, double lon2, double meters) {
        if (Double.isNaN(lat1) || Double.isNaN(lon1) || Double.isNaN(lat2) || Double.isNaN(lon2)) return true;
        double r = 6371000.0;
        double dLat = Math.toRadians(lat2 - lat1);
        double dLon = Math.toRadians(lon2 - lon1);
        double a = Math.sin(dLat / 2) * Math.sin(dLat / 2)
                 + Math.cos(Math.toRadians(lat1)) * Math.cos(Math.toRadians(lat2))
                 * Math.sin(dLon / 2) * Math.sin(dLon / 2);
        double c = 2 * Math.asin(Math.min(1.0, Math.sqrt(a)));
        return r * c > meters;
    }
}
