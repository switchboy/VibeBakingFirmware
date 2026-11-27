package org.vibebaking.launcher.logic;

/**
 * Pure validation for the settings manual inputs (owner request 2026-11-27): valet PIN and
 * valet timeout. The activity shows an inline green "Saved" or a red error based on these;
 * nothing throws. Mirrors SettingsKeys.clampTimeoutS bounds (10..3600 s).
 */
public final class SettingsValidation {

    private SettingsValidation() {}

    public static final int PIN_MIN_DIGITS = 4;    // same floor ValetPin/Guard needs (SA16 history)
    public static final int PIN_MAX_DIGITS = 6;    // field length cap
    public static final int TIMEOUT_MAX_DIGITS = 4; // field length cap for seconds
    public static final int TIMEOUT_MIN_S = 10;    // = SettingsKeys.clampTimeoutS floor
    public static final int TIMEOUT_MAX_S = 3600;  // = SettingsKeys.clampTimeoutS ceiling

    /** PIN = digits only, PIN_MIN_DIGITS..PIN_MAX_DIGITS after trim; null/short/long/junk -> false. */
    public static boolean validPin(String pin) {
        if (pin == null) return false;
        String p = pin.trim();
        if (p.length() < PIN_MIN_DIGITS || p.length() > PIN_MAX_DIGITS) return false;
        for (int i = 0; i < p.length(); i++) {
            char ch = p.charAt(i);
            if (ch < '0' || ch > '9') return false;
        }
        return true;
    }

    /** Timeout seconds strictly inside the owner band 10..3600 (inclusive bounds). */
    public static boolean timeoutOk(int seconds) {
        return seconds >= TIMEOUT_MIN_S && seconds <= TIMEOUT_MAX_S;
    }

    /** Parse a timeout field; null on null/junk/overflow, never a throw. */
    public static Integer parseTimeout(String raw) {
        if (raw == null) return null;
        try {
            return Integer.valueOf(raw.trim());
        } catch (NumberFormatException e) {
            return null;
        }
    }
}
