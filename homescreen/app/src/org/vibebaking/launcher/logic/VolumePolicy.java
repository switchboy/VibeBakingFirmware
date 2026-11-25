package org.vibebaking.launcher.logic;

/** Reverse-gear volume attenuation decision (spec S31). Pure; AudioManager glue in ValetController-independent AudioAttenuator. */
public final class VolumePolicy {
    public static final String MODE_UNCHANGED = "unchanged";
    public static final String MODE_LOWER = "lower";
    public static final String MODE_MUTE = "mute";

    private VolumePolicy() {}

    /**
     * Target stream volume while reversing, or null = leave unchanged.
     * percent = attenuation level as % of max volume (owner default 30%).
     */
    public static Integer targetVolume(String mode, int percent, int maxVolume, int currentVolume) {
        if (maxVolume <= 0) return null; // stream max unknown: don't touch anything (no accidental mute)
        int p = Math.max(0, Math.min(100, percent));
        switch (mode) {
            case MODE_UNCHANGED: return null;
            case MODE_MUTE: return 0;
            case MODE_LOWER: {
                int t = (int) Math.round(maxVolume * p / 100.0);
                return Math.max(0, Math.min(t, maxVolume));
            }
            default: return null;
        }
    }

    /**
     * Volume to restore when reverse ends. Captured once when attenuation starts; later start
     * events (repeat frames, mode already active) must not overwrite it, otherwise the attenuated
     * value would become the "original".
     */
    public static Integer restoreVolume(boolean attenuating, Integer captured) {
        if (!attenuating) return null;
        return captured;
    }

    /** Capture point: only capture if nothing captured yet. */
    public static Integer capture(Integer alreadyCaptured, int currentVolume) {
        return alreadyCaptured == null ? currentVolume : alreadyCaptured;
    }

    /** MCU delegation: when enabled, the launcher does not touch the stream itself. */
    public static boolean delegateToMcu(boolean mcuEnabled) { return mcuEnabled; }

    /** The MCU command to send instead (facts: ctl_backview_vol exists in the MCU driver). */
    public static String mcuVolumeCommand(int percent) {
        return SettingsKeys.MCU_BACKVIEW_VOL_CMD + "=" + Math.max(0, Math.min(100, percent));
    }
}
