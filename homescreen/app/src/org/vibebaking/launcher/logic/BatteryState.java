package org.vibebaking.launcher.logic;

import java.util.Locale;

/** Car battery chip (spec S19/S20). Raw = CarEvent "battery" int value. */
public final class BatteryState {

    /**
     * Unit assumption from the live bench frame `fa 16 c0 02 00 79 00` -> value 121: tenths of
     * volt (12.1 V). Device acceptance A06 measures against a multimeter; if the MCU sends
     * centivolts or plain volts, THIS is the only place to change.
     */
    public static final double RAW_SCALE = 10.0;

    public static final double DEFAULT_LOW_THRESHOLD_V = 11.5;

    /** Plausible lead-acid battery window: a 12 V head unit, 24 V trucks possible (spec S20). */
    public static final double MIN_PLAUSIBLE_V = 4.0;
    public static final double MAX_PLAUSIBLE_V = 32.0;

    private BatteryState() {}

    public static double volts(int raw) { return raw / RAW_SCALE; }

    /** A believable value for a car battery; junk frames (1210 = 121 V, overflow) are rejected. */
    public static boolean plausible(int raw) {
        if (raw <= 0) return false;
        double v = volts(raw);
        return !Double.isNaN(v) && v >= MIN_PLAUSIBLE_V && v <= MAX_PLAUSIBLE_V;
    }

    /** false = chip stays hidden (no believable value yet, spec S19). */
    public static boolean known(int raw) { return plausible(raw); }

    public static String label(int raw) {
        if (!plausible(raw)) return ""; // implausible value must never reach the panel
        return String.format(Locale.ROOT, "%.1f V", volts(raw));
    }

    public static boolean low(int raw, double thresholdV) {
        return plausible(raw) && volts(raw) < thresholdV;
    }
}
