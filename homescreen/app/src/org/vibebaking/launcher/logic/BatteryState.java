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

    private BatteryState() {}

    public static double volts(int raw) { return raw / RAW_SCALE; }

    /** false = chip stays hidden (no believable value yet). */
    public static boolean known(int raw) { return raw > 0; }

    public static String label(int raw) {
        return String.format(Locale.ROOT, "%.1f V", volts(raw));
    }

    public static boolean low(int raw, double thresholdV) {
        return known(raw) && volts(raw) < thresholdV;
    }
}
