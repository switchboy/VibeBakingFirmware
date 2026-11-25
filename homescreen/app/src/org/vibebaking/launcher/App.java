package org.vibebaking.launcher;

import android.app.Application;

import org.vibebaking.launcher.logic.CombinedPhoneProbe;
import org.vibebaking.launcher.logic.PhonePresenceProbe;

/** Shared singletons for the launcher activities; dynamic accent via Material You if present. */
public class App extends Application {

    private static App instance;

    SettingsStore store;
    ThemeApplier theme;
    CarClient car;
    ValetController valet;
    CombinedPhoneProbe btProbe;

    @Override
    public void onCreate() {
        super.onCreate();
        instance = this;
        store = new SettingsStore(this);
        theme = new ThemeApplier(this);
        car = new CarClient();
        // Trusted phone: HCT/GOC Bluetooth stack first (the real BT here), Android's own stack as
        // the second source. Both sources are fault-tolerant: a missing service, a denied
        // permission or a dead profile proxy yields UNKNOWN, never an exception (S25/S26/S36).
        // Construction itself is guarded too: a broken BT service must not crash the app at start.
        PhonePresenceProbe hct;
        PhonePresenceProbe droid;
        try { hct = new HctBluetoothProbe(this); }
        catch (Throwable t) { hct = new CombinedPhoneProbe.Inert(); }
        try { droid = new BluetoothPhoneProbe(this); }
        catch (Throwable t) { droid = new CombinedPhoneProbe.Inert(); }
        btProbe = new CombinedPhoneProbe(hct, droid);
        valet = new ValetController(this, store, btProbe);
        applyDynamicColors();
    }

    public static App get() { return instance; }
    public static SettingsStore store() { return instance.store; }
    public static ThemeApplier theme() { return instance.theme; }
    public static CarClient car() { return instance.car; }
    public static ValetController valet() { return instance.valet; }
    public static CombinedPhoneProbe bt() { return instance.btProbe; }

    /**
     * Spec S34: accent from Material You when the material library is in the build. Reflection
     * so a build without the lib (or a different package path) never crashes; the static
     * accent in res/values/themes.xml is the fallback.
     */
    private void applyDynamicColors() {
        String[] candidates = {
            "com.google.android.material.dynamic.DynamicColors",
            "com.google.android.material.internal.DynamicColors",
            "com.google.android.material.colors.DynamicColors",
        };
        for (String name : candidates) {
            try {
                Class<?> cls = Class.forName(name);
                cls.getMethod("applyToActivitiesIfAvailable", Application.class).invoke(null, this);
                return;
            } catch (Throwable ignore) { }
        }
        android.util.Log.i("VibeLauncher", "material dynamic colors absent -> static accent");
    }
}
