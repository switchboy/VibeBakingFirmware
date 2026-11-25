package org.vibebaking.launcher.logic;

/** Car-lights -> backlight behaviour (spec S28). Pure; brightness glue in BacklightApplier. */
public final class BacklightPolicy {
    public static final String MODE_NOTHING = "nothing";
    public static final String MODE_DIM = "dim";

    private BacklightPolicy() {}

    /**
     * Screen brightness fraction (0..1) to apply while car lights are on, or null = "nothing".
     * When lights go off, the caller restores the pre-lights brightness it captured.
     */
    public static Double dimFraction(String mode, int percent, boolean lightsOn) {
        if (!lightsOn || MODE_NOTHING.equals(mode)) return null;
        return Math.max(0.0, Math.min(1.0, percent / 100.0));
    }
}
