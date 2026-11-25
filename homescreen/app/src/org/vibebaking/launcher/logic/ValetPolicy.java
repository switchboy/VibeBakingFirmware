package org.vibebaking.launcher.logic;

import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * Valet-mode suspend policy (spec S21-S22). Pure logic: takes package metadata, returns the
 * list to suspend. Android glue lives in ValetController.
 */
public final class ValetPolicy {

    public static final String LAUNCHER_PACKAGE = "org.vibebaking.launcher";
    public static final String SETTINGS_PACKAGE = "com.android.settings";

    /** The owner's allowed list (homescreen.md, 2026-11-24), exactly these user-facing apps. */
    public static final Set<String> DEFAULT_ALLOWED = Collections.unmodifiableSet(new HashSet<>(
        java.util.Arrays.asList(
            "com.google.android.apps.maps",
            "com.microntek.radio",
            "com.microntek.bluetooth",
            "com.microntek.frontview",
            "com.microntek.backview")));

    /** Never suspended: framework, SystemUI, the HCT services, the launcher, rear camera. */
    public static final Set<String> PROTECTED = Collections.unmodifiableSet(new HashSet<>(
        java.util.Arrays.asList(
            "android",
            "com.android.systemui",
            "android.microntek.service",     // HCTManagerService (carservice registration)
            "android.microntek.canbus",      // HCTCanBus (MCU/CAN bridge)
            "android.microntek.mtcser",      // HCTBlueToothManager
            LAUNCHER_PACKAGE,
            "com.microntek.backview")));     // started by CarService on reverse, must stay alive

    public static class App {
        public final String pkg;
        public final boolean system;
        public App(String pkg, boolean system) { this.pkg = pkg; this.system = system; }
    }

    private ValetPolicy() {}

    /**
     * Bootstrap guard (spec S26a): entry is refused unless the master switch is on AND an exit
     * path exists (PIN set, or a trusted phone connected). Without an exit path - BT stack dead
     * and no PIN - valet mode would lock the owner out of the unit permanently; never suspend.
     */
    public static boolean entryAllowed(boolean enabled, boolean pinSet, boolean trustedPhonePresent) {
        return enabled && (pinSet || trustedPhonePresent);
    }

    /** Whether the settings screen must warn "valet mode: no exit configured". */
    public static boolean warnNoExit(boolean enabled, boolean pinSet, boolean trustedPhonePresent) {
        return enabled && !entryAllowed(enabled, pinSet, trustedPhonePresent);
    }

    /** Allowed set = defaults + launcher + owner opt-in extras. */
    public static Set<String> allowedSet(Set<String> extras) {
        Set<String> s = new HashSet<>(DEFAULT_ALLOWED);
        s.add(LAUNCHER_PACKAGE);
        if (extras != null) s.addAll(extras);
        return s;
    }

    /**
     * Packages to suspend on valet entry: every installed NON-system package outside the allowed
     * set, plus com.android.settings (owner decision), minus everything protected.
     */
    public static List<String> computeSuspend(List<App> installed, Set<String> extras) {
        Set<String> allowed = allowedSet(extras);
        List<String> out = new ArrayList<>();
        for (App a : installed) {
            if (PROTECTED.contains(a.pkg)) continue;
            if (allowed.contains(a.pkg)) continue;
            if (a.system) continue;             // system packages are never suspended...
            out.add(a.pkg);
        }
        // ... except Settings itself, which the owner wants gone while in valet.
        boolean settingsInstalled = false;
        for (App a : installed) if (a.pkg.equals(SETTINGS_PACKAGE)) settingsInstalled = true;
        if (settingsInstalled) out.add(SETTINGS_PACKAGE);
        Collections.sort(out);
        return out;
    }

    /** Tiles shown on the valet home screen: installed allowed apps, allowed order stable. */
    public static List<String> homeTiles(List<App> installed, Set<String> extras) {
        Set<String> allowed = allowedSet(extras);
        List<String> out = new ArrayList<>();
        for (App a : installed) if (allowed.contains(a.pkg) && !a.system) out.add(a.pkg);
        Collections.sort(out);
        return out;
    }
}
