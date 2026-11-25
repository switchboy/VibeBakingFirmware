package org.vibebaking.launcher.logic;

/**
 * Map card compact mode (owner request 2026-11-25): Google Maps' bottom tab bar (Explore / Saved / Contribute) takes
 * too much of the small card. The app offers no way to hide it, so the card renders the nav app's display taller than
 * the card and clips the bottom strip. That strip also holds Maps' own controls in other states (the route preview's
 * Start button, the navigation ETA bar), so the card is compact only while nobody uses the map and no navigation runs.
 * Pure: the clock and the navigation state come from the caller.
 */
public final class MapCardPolicy {

    /** No touch for this long -> the card may go compact. */
    public static final long IDLE_MS = 15_000L;
    /** Height of the bottom strip that compact mode hides, in dp (Maps' tab bar measured at ~67 dp on the unit). */
    public static final int CROP_DP = 68;

    private MapCardPolicy() {}

    /**
     * @param navigating   the nav app shows an ongoing notification (turn-by-turn guidance)
     * @param sinceTouchMs ms since the last touch on the card (Long.MAX_VALUE if never touched)
     */
    public static boolean compact(boolean navigating, long sinceTouchMs) {
        return !navigating && sinceTouchMs >= IDLE_MS;
    }

    /** Pixels hidden in compact mode for a display density (dpi). */
    public static int cropPx(int densityDpi) {
        return Math.round(CROP_DP * densityDpi / 160f);
    }
}
