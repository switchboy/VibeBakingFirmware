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
     * `phoneExitPath` = trusted phone connected now, OR paired so that connecting it later exits
     * valet (spec S25/S26). With the HCT BT stack live, a paired phone is a real exit path even
     * while the phone is away; with no phone signal at all (BT off, service gone) only a PIN counts,
     * and valet entry is refused - without an exit path it would lock the owner out permanently
     * (bootstrap guard, spec S26a).
     */
    public static boolean entryAllowed(boolean enabled, boolean pinSet, boolean phoneExitPath) {
        return enabled && (pinSet || phoneExitPath);
    }

    /** Whether the settings screen must warn "valet mode: no exit configured". */
    public static boolean warnNoExit(boolean enabled, boolean pinSet, boolean phoneExitPath) {
        return enabled && !entryAllowed(enabled, pinSet, phoneExitPath);
    }

    /** What to do with persisted valet state after a launcher restart (spec S22/S26a/S27a). */
    public enum Replay { NONE, APPLY, EXIT }

    /**
     * Crash-replay decision. APPLY re-suspends; EXIT unsuspends everything. The exit-path check is
     * here on purpose: if a PIN was cleared (prefs wiped) while valet was active and no phone signal
     * exists (BT off, mtcser service gone, phone unpaired), re-applying would lock the owner out of
     * the unit permanently (S26a) -> EXIT instead.
     */
    public static Replay replayAction(boolean persistedActive, boolean enabled,
                                      boolean pinSet, boolean phoneExitPath) {
        if (!persistedActive) return Replay.NONE;
        if (!enabled) return Replay.EXIT;                     // master switch turned off (S27a)
        if (!entryAllowed(true, pinSet, phoneExitPath)) return Replay.EXIT; // exit path lost
        return Replay.APPLY;
    }

    /** Parse the owner's extras CSV tolerantly (blank/space/duplicate entries are dropped). */
    public static Set<String> parseExtrasCsv(String csv) {
        Set<String> s = new HashSet<>();
        if (csv == null) return s;
        for (String t : csv.split(",")) {
            String v = t.trim();
            if (!v.isEmpty()) s.add(v);
        }
        return s;
    }

    /** Allowed set = defaults + launcher + owner opt-in extras. */
    public static Set<String> allowedSet(Set<String> extras) {
        Set<String> s = new HashSet<>(DEFAULT_ALLOWED);
        s.add(LAUNCHER_PACKAGE);
        if (extras != null) s.addAll(extras);
        return s;
    }

    /**
     * Extras plus the navigation app the map card is aiming at (spec S7/S21): if the owner picked
     * Waze, suspending Waze would blank the map card while in valet - so the chosen nav target is
     * always allowed. `null`/empty adds nothing.
     */
    public static Set<String> withMapTarget(Set<String> extras, String mapTargetPkg) {
        Set<String> s = new HashSet<>(extras == null ? java.util.Collections.<String>emptySet() : extras);
        if (mapTargetPkg != null && !mapTargetPkg.isEmpty()) s.add(mapTargetPkg);
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
}
