package org.vibebaking.launcher.logic;

/**
 * Gauge colour policy for the right-column engine gauges (owner 2026-11-27): battery volts,
 * coolant/oil temperature and engine rpm. Pure and unit-tested; the activity only maps
 * Level -> colour (res/values/colors.xml gauge_cold/gauge_ok/gauge_warn/gauge_bad).
 * Threshold source: VAG EA111 1.2 TSI 105 hp, owner 2026-11-27.
 */
public final class EngineGauges {

    public enum Level { COLD, OK, WARN, BAD }

    // Battery: 12 V lead-acid; engine off rests 12.4-12.7 V, charging 13.8-14.7 V.
    // Source: VAG EA111 1.2 TSI 105 hp, owner 2026-11-27.
    public static final double BATTERY_BAD_LOW_V = 11.5;    // < 11.5: collapsed battery
    public static final double BATTERY_WARN_LOW_V = 12.0;   // 11.5 .. < 12.0: discharged while parked
    public static final double BATTERY_OK_HIGH_V = 14.8;    // 12.0 .. 14.8: resting/charging band
    public static final double BATTERY_WARN_HIGH_V = 15.2;  // > 14.8 .. 15.2: regulator running hot
    public static final double BATTERY_BAD_HIGH_V = 15.2;   // > 15.2: overcharge

    // Coolant: thermostat opens ~87 C, fan from ~95 C, cluster warning ~120 C.
    // Source: VAG EA111 1.2 TSI 105 hp, owner 2026-11-27.
    public static final int COOLANT_COLD_MAX_C = 70;    // < 70: still cold after a cold start
    public static final int COOLANT_OK_MAX_C = 104;     // 70 .. 104: normal operating band
    public static final int COOLANT_WARN_MAX_C = 114;   // 105 .. 114: overheating watch band
    public static final int COOLANT_BAD_MIN_C = 115;    // >= 115: cluster-warning territory

    // Oil: normal 90-110 C, short spikes to ~125 C under load are fine.
    // Source: VAG EA111 1.2 TSI 105 hp, owner 2026-11-27.
    public static final int OIL_COLD_MAX_C = 70;        // < 70: still cold
    public static final int OIL_OK_MAX_C = 124;         // 70 .. 124: includes load spikes
    public static final int OIL_WARN_MAX_C = 134;       // 125 .. 134: watch band
    public static final int OIL_BAD_MIN_C = 135;        // >= 135: too hot, back off the throttle

    // RPM: HCTCanBus broadcast com.microntek.canbus.rpm, String extra "rpm" (decimal).
    // Source: VAG EA111 1.2 TSI 105 hp, owner 2026-11-27 — revs ~6500; anything else is junk.
    public static final int RPM_MIN = 0;                // negatives ignored (junk frame)
    public static final int RPM_MAX = 9000;             // > 9000 ignored (impossible for this engine)

    private EngineGauges() {}

    /** Battery level from volts; NaN/absurd reads BAD so the chip never looks healthy on junk. */
    public static Level batteryLevel(double volts) {
        if (Double.isNaN(volts)) return Level.BAD;
        if (volts < BATTERY_BAD_LOW_V) return Level.BAD;
        if (volts < BATTERY_WARN_LOW_V) return Level.WARN;
        if (volts <= BATTERY_OK_HIGH_V) return Level.OK;
        if (volts <= BATTERY_WARN_HIGH_V) return Level.WARN;
        return Level.BAD;
    }

    /** Coolant level in C (thermostat ~87 C, fan ~95 C, cluster warning ~120 C). */
    public static Level coolantLevel(int celsius) {
        if (celsius < COOLANT_COLD_MAX_C) return Level.COLD;
        if (celsius <= COOLANT_OK_MAX_C) return Level.OK;
        if (celsius <= COOLANT_WARN_MAX_C) return Level.WARN;
        return Level.BAD;
    }

    /** Oil temperature level in C (normal 90-110, load spikes to ~125 fine). */
    public static Level oilLevel(int celsius) {
        if (celsius < OIL_COLD_MAX_C) return Level.COLD;
        if (celsius <= OIL_OK_MAX_C) return Level.OK;
        if (celsius <= OIL_WARN_MAX_C) return Level.WARN;
        return Level.BAD;
    }

    /**
     * Parse the rpm broadcast extra ("2150", " 800 "). null = unusable: negative, > RPM_MAX,
     * non-numeric or overflow. Callers hide the gauge on null; it never throws.
     */
    public static Integer parseRpm(String raw) {
        if (raw == null) return null;
        try {
            int v = Integer.parseInt(raw.trim());
            if (v < RPM_MIN || v > RPM_MAX) return null;
            return Integer.valueOf(v);
        } catch (NumberFormatException e) {
            return null; // junk frame: never crash the receiver
        }
    }
}
