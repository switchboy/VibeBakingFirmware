package org.vibebaking.launcher;

import android.content.Context;
import android.app.UiModeManager;
import android.provider.Settings;
import android.text.TextUtils;

import org.vibebaking.launcher.logic.ThemePolicy;

/**
 * Applies night mode (spec S30/S29). setNightMode is @hide but platform-signed apps are exempt
 * from hidden-API restrictions; if the platform rejects it we fall back to the public app-level
 * night mode, and worst case the theme simply stays light (no crash).
 */
public class ThemeApplier {

    private final Context ctx;
    private final UiModeManager uim;

    public ThemeApplier(Context c) {
        ctx = c.getApplicationContext();
        UiModeManager m = null;
        try { m = (UiModeManager) ctx.getSystemService(Context.UI_MODE_SERVICE); } catch (Throwable ignore) { }
        uim = m;
    }

    /** night = ThemePolicy.night(...). Returns whether night is now in effect. */
    public boolean apply(boolean night) {
        int mode = night ? android.content.res.Configuration.UI_MODE_NIGHT_YES
                         : android.content.res.Configuration.UI_MODE_NIGHT_NO;
        try {
            uim.setNightMode(mode);           // @hide, system-wide: also flips the embedded map task
            return true;
        } catch (Throwable t) {
            try {
                uim.setApplicationNightMode(mode); // app-level fallback (Android 12+)
                return true;
            } catch (Throwable t2) { return false; }
        }
    }

    /** System's current night flag (drives our resource qualifiers). */
    public boolean systemNight() {
        try {
            return (ctx.getResources().getConfiguration().uiMode
                    & android.content.res.Configuration.UI_MODE_NIGHT_MASK)
                    == android.content.res.Configuration.UI_MODE_NIGHT_YES;
        } catch (Throwable t) { return false; }
    }

    /** Backlight behaviour on car lights (spec S28): default "nothing" applies nothing. */
    public void applyBacklight(Double fraction, Double restore) {
        // Deprecated-but-working system brightness via Settings.System; requires WRITE_SETTINGS.
        if (fraction == null && restore == null) return;
        try {
            float v = fraction != null ? (float) (fraction * 255.0) : (float) (restore * 255.0);
            Settings.System.putFloat(ctx.getContentResolver(), Settings.System.SCREEN_BRIGHTNESS, v);
        } catch (Throwable t) { /* SecurityException / no permission: quietly skip, default is "nothing" */ }
    }

    /** Capture current brightness before dimming (returns null when unreadable). */
    public Double captureBrightness() {
        try {
            float v = Settings.System.getFloat(ctx.getContentResolver(), Settings.System.SCREEN_BRIGHTNESS, -1f);
            return v < 0 ? null : v / 255.0;
        } catch (Throwable t) { return null; }
    }

    /** Notification-listener access check (spec S14). */
    public boolean listenerEnabled() {
        String enabled = Settings.Secure.getString(
            ctx.getContentResolver(), "enabled_notification_listeners");
        if (TextUtils.isEmpty(enabled)) return false;
        String ours = ctx.getPackageName() + "/" + MediaListenerService.class.getName();
        return enabled.contains(ours);
    }
}
