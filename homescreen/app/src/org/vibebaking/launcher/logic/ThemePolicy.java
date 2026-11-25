package org.vibebaking.launcher.logic;

/** Dark-mode decision (spec S29, S30). Pure; UiModeManager glue lives in ThemeApplier. */
public final class ThemePolicy {
    public static final String MODE_CYCLE = "cycle";
    public static final String MODE_ALWAYS_LIGHT = "always_light";
    public static final String MODE_ALWAYS_DARK = "always_dark";
    public static final String MODE_CAR_LIGHTS = "car_lights";
    public static final String LIGHTS_THEME_NOTHING = "nothing";
    public static final String LIGHTS_THEME_DARK = "dark";

    private ThemePolicy() {}

    /**
     * Should the app be night? `darkMode` is the owner's dark-mode setting; `headlightOn` is the
     * car-illumination edge state; `cycleNight` is DayNight.isNight(...).
     * "car lights -> theme dark" forces night while lights are on (default "nothing" never forces).
     */
    public static boolean night(String darkMode, boolean headlightOn, boolean cycleNight,
                                String lightsTheme) {
        boolean base;
        switch (darkMode) {
            case MODE_ALWAYS_LIGHT: base = false; break;
            case MODE_ALWAYS_DARK:  base = true;  break;
            case MODE_CAR_LIGHTS:   base = headlightOn; break;
            case MODE_CYCLE:
            default:                base = cycleNight; break;
        }
        if (LIGHTS_THEME_DARK.equals(lightsTheme) && headlightOn) return true;
        return base;
    }
}
