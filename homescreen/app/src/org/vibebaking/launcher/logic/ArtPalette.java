package org.vibebaking.launcher.logic;

/** Album-art tinting (spec S35): backdrop tinted from the art's palette, day light / night dark. Pure. */
public final class ArtPalette {

    /** Night album art is dimmed so it cannot glare (S35). */
    public static final double NIGHT_ART_DIM = 0.62;

    private ArtPalette() {}

    /**
     * Dominant hue (degrees 0..360) over saturated pixels, circular mean; returns -1 for grey art.
     * `pixels` = sampled ARGB ints of the album art.
     */
    public static double dominantHue(int[] pixels) {
        double sx = 0, sy = 0, weight = 0;
        for (int p : pixels) {
            if ((p >>> 24) < 200) continue;         // ignore transparent
            double[] hsv = ColorTools.rgbToHsv(p);
            if (hsv[1] < 0.15) continue;            // ignore greys
            double rad = Math.toRadians(hsv[0]);
            sx += Math.cos(rad) * hsv[1];
            sy += Math.sin(rad) * hsv[1];
            weight += hsv[1];
        }
        if (weight <= 0) return -1;
        double deg = Math.toDegrees(Math.atan2(sy, sx));
        if (deg < 0) deg += 360;
        return deg;
    }

    /** Day backdrop: light tint of the art hue (spec: light tinted backdrop). */
    public static int dayTint(int[] pixels) {
        double h = dominantHue(pixels);
        if (h < 0) return ColorTools.hsvToRgb(0, 0.0, 0.88);   // grey art -> neutral light
        return ColorTools.hsvToRgb(h, 0.30, 0.92);
    }

    /** Night backdrop: tinted from the art's DARK palette; never pure white (spec S33). */
    public static int nightTint(int[] pixels) {
        double h = dominantHue(pixels);
        if (h < 0) return ColorTools.hsvToRgb(0, 0.0, 0.16);
        return ColorTools.hsvToRgb(h, 0.45, 0.16);
    }

    /** Night dim multiplier for the art bitmap itself (caller applies via ColorMatrix). */
    public static double nightArtDim() { return NIGHT_ART_DIM; }
}
