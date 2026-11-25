package org.vibebaking.launcher.logic;

import java.util.Set;

/** Navigation-app choice for the map card (spec S7/S8). Pure; TaskView glue in MapCardController. */
public final class MapTargetPolicy {

    public static final String MAPS = "com.google.android.apps.maps";
    public static final String WAZE = "com.waze";
    public static final String TARGET_AUTO = "auto";
    public static final String TARGET_MAPS = "maps";
    public static final String TARGET_WAZE = "waze";

    private MapTargetPolicy() {}

    /** Target package for the embedded task, or null -> placeholder card (S8). */
    public static String target(String setting, Set<String> installed) {
        if (installed == null) return null;
        switch (setting == null ? TARGET_AUTO : setting) {
            case TARGET_MAPS: return installed.contains(MAPS) ? MAPS : null;
            case TARGET_WAZE: return installed.contains(WAZE) ? WAZE : null;
            case TARGET_AUTO:
            default:
                if (installed.contains(MAPS)) return MAPS;
                if (installed.contains(WAZE)) return WAZE;
                return null;
        }
    }
}
