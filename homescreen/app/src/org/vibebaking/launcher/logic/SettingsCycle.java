package org.vibebaking.launcher.logic;

/**
 * Pure cycle + band helpers for the settings screen (owner request 2026-11-27). The old
 * addCycle rows captured the value the screen opened with, so every tap after the first wrote
 * the same value again; the UI now reads the store fresh at click time. The cycle walk lives
 * here so it is unit-tested: repeated application walks through all values and wraps, an
 * unknown current value returns the first value. Java 8, no throw.
 */
public final class SettingsCycle {

    private SettingsCycle() {}

    /** Index of v in values, or -1 when absent / values is null. */
    public static int indexOf(String[] values, String v) {
        if (values == null) return -1;
        for (int i = 0; i < values.length; i++) if (values[i].equals(v)) return i;
        return -1;
    }

    /** Index of v in values, or -1 when absent / values is null. */
    public static int indexOf(int[] values, int v) {
        if (values == null) return -1;
        for (int i = 0; i < values.length; i++) if (values[i] == v) return i;
        return -1;
    }

    /** Next value after current; unknown/null current -> values[0]; empty/null values -> null. */
    public static String next(String[] values, String current) {
        if (values == null || values.length == 0) return null;
        int i = indexOf(values, current);
        if (i < 0) return values[0]; // unknown pref value: show the first option
        return values[(i + 1) % values.length];
    }

    /** Next value after current; unknown current -> values[0]; empty/null values -> current (stay). */
    public static int next(int[] values, int current) {
        if (values == null || values.length == 0) return current; // nothing to cycle to
        int i = indexOf(values, current);
        if (i < 0) return values[0];
        return values[(i + 1) % values.length];
    }

    /**
     * Index of the value closest to v (a garbage stored percent must still land the SeekBar
     * on a legal band value). Empty/null band -> 0 (the first bar position). Long math so
     * Integer.MIN/MAX_VALUE inputs cannot overflow.
     */
    public static int nearest(int[] values, int v) {
        if (values == null || values.length == 0) return 0;
        int best = 0;
        long bestDiff = Math.abs((long) values[0] - (long) v);
        for (int i = 1; i < values.length; i++) {
            long diff = Math.abs((long) values[i] - (long) v);
            if (diff < bestDiff) { bestDiff = diff; best = i; }
        }
        return best;
    }
}
