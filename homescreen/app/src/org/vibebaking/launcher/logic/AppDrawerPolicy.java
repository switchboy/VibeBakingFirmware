package org.vibebaking.launcher.logic;

import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * App drawer arrangement (spec S39): alphabetical list of launchable apps, shown as a 4x3 grid.
 * Pure: the Android side supplies labels/icons/launch-intents, this decides what is visible and
 * in what order. While valet mode is active only the allowed set is visible (spec S21/S27), so the
 * drawer can never become an escape hatch around the suspension.
 */
public final class AppDrawerPolicy {

    /** 4 columns x 3 rows fits the 1024x600 panel with one icon per ~128dp cell. */
    public static final int GRID_COLUMNS = 4;
    public static final int GRID_ROWS = 3;
    public static final int PAGE_SIZE = GRID_COLUMNS * GRID_ROWS;

    private AppDrawerPolicy() {}

    /** One drawer entry, mirrored from PackageManager into pure data. */
    public static final class Entry {
        public final String pkg;
        public final String label;
        public final boolean launchable; // has a launch intent
        public Entry(String pkg, String label, boolean launchable) {
            this.pkg = pkg; this.label = label; this.launchable = launchable;
        }
    }

    /**
     * One entry per package: queryIntentActivities(ACTION_MAIN+CATEGORY_LAUNCHER) can return
     * several launcher activities for the same app; the drawer shows one cell per package
     * (first occurrence wins, so the enumeration order decides which label is kept).
     */
    public static List<Entry> dedupe(List<Entry> all) {
        List<Entry> out = new ArrayList<>();
        if (all == null) return out;
        Set<String> seen = new HashSet<>();
        for (Entry e : all) {
            if (e == null || e.pkg == null) continue;
            if (seen.add(e.pkg)) out.add(e);
        }
        return out;
    }

    /**
     * Visible entries, sorted by label (case-insensitive, package name as tie-breaker).
     * `homeApps` = packages that resolve as HOME (the launcher itself, Launcher3 if still present):
     * launching one of those from the drawer would restart the home screen, so they are hidden.
     * Services without a launch intent are hidden too - the drawer shows apps, not components.
     */
    public static List<Entry> visible(List<Entry> all, boolean valetActive,
                                      Set<String> extras, Set<String> homeApps) {
        List<Entry> out = new ArrayList<>();
        if (all == null) return out;
        Set<String> allowed = valetActive ? ValetPolicy.allowedSet(extras) : null;
        for (Entry e : all) {
            if (e == null || !e.launchable) continue;
            if (homeApps != null && homeApps.contains(e.pkg)) continue;
            if (ValetPolicy.PROTECTED.contains(e.pkg)) continue;
            if (allowed != null && !allowed.contains(e.pkg)) continue;
            out.add(e);
        }
        Collections.sort(out, (a, b) -> {
            String la = String.valueOf(a.label).toLowerCase(java.util.Locale.ROOT);
            String lb = String.valueOf(b.label).toLowerCase(java.util.Locale.ROOT);
            int c = la.compareTo(lb);
            return c != 0 ? c : a.pkg.compareTo(b.pkg);
        });
        return out;
    }

    /** Pages of PAGE_SIZE icons (the grid scrolls vertically; paging is the fallback math). */
    public static int pageCount(int n) {
        if (n <= 0) return 0;
        return (n + PAGE_SIZE - 1) / PAGE_SIZE;
    }

    public static int rowCount(int n) {
        if (n <= 0) return 0;
        return (n + GRID_COLUMNS - 1) / GRID_COLUMNS;
    }
}
