package org.vibebaking.launcher;

import android.app.Application;

/** Shared singletons for the launcher activities; dynamic accent via Material You if present. */
public class App extends Application {

    private static App instance;

    SettingsStore store;
    ThemeApplier theme;
    CarClient car;
    ValetController valet;

    @Override
    public void onCreate() {
        super.onCreate();
        instance = this;
        store = new SettingsStore(this);
        theme = new ThemeApplier(this);
        car = new CarClient();
        valet = new ValetController(this, store, new ValetController.NoBtStackProbe());
        applyDynamicColors();
    }

    public static App get() { return instance; }
    public static SettingsStore store() { return instance.store; }
    public static ThemeApplier theme() { return instance.theme; }
    public static CarClient car() { return instance.car; }
    public static ValetController valet() { return instance.valet; }

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
