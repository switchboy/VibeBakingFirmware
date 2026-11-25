package org.vibebaking.launcher.logic;

/** Pure HSV <-> ARGB helpers (no Android Color dependency). */
public final class ColorTools {

    private ColorTools() {}

    /** Returns [hue 0..360, saturation 0..1, value 0..1]. */
    public static double[] rgbToHsv(int argb) {
        int r = (argb >> 16) & 0xFF, g = (argb >> 8) & 0xFF, b = argb & 0xFF;
        double rd = r / 255.0, gd = g / 255.0, bd = b / 255.0;
        double max = Math.max(rd, Math.max(gd, bd));
        double min = Math.min(rd, Math.min(gd, bd));
        double delta = max - min;
        double h;
        if (delta == 0) h = 0;
        else if (max == rd) h = 60 * ((gd - bd) / delta % 6);
        else if (max == gd) h = 60 * ((bd - rd) / delta + 2);
        else h = 60 * ((rd - gd) / delta + 4);
        if (h < 0) h += 360;
        double s = max == 0 ? 0 : delta / max;
        return new double[] { h, s, max };
    }

    public static int hsvToRgb(double h, double s, double v) {
        double c = v * s;
        double x = c * (1 - Math.abs((h / 60.0) % 2 - 1));
        double m = v - c;
        double r, g, b;
        if (h < 60) { r = c; g = x; b = 0; }
        else if (h < 120) { r = x; g = c; b = 0; }
        else if (h < 180) { r = 0; g = c; b = x; }
        else if (h < 240) { r = 0; g = x; b = c; }
        else if (h < 300) { r = x; g = 0; b = c; }
        else { r = c; g = 0; b = x; }
        int ri = (int) Math.round((r + m) * 255), gi = (int) Math.round((g + m) * 255), bi = (int) Math.round((b + m) * 255);
        return (0xFF << 24) | (ri << 16) | (gi << 8) | bi;
    }

    /** Relative luminance 0..1 (Rec.709-ish), for the "no glare / no pure white" checks. */
    public static double luminance(int argb) {
        double r = ((argb >> 16) & 0xFF) / 255.0;
        double g = ((argb >> 8) & 0xFF) / 255.0;
        double b = (argb & 0xFF) / 255.0;
        return 0.2126 * r + 0.7152 * g + 0.0722 * b;
    }

    public static boolean isPureWhite(int argb) { return (argb & 0x00FFFFFF) == 0x00FFFFFF; }
}
