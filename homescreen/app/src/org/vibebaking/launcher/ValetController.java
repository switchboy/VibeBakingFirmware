package org.vibebaking.launcher;

import android.app.NotificationManager;
import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.os.Handler;
import android.text.TextUtils;

import org.vibebaking.launcher.logic.ValetPolicy;

import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;

/**
 * Valet mode (spec S22-S26): suspend everything outside the allowed list, total-silence DND,
 * no shade/quick-settings/recents. Pending state is persisted BEFORE suspending so a launcher
 * crash re-applies the same state on restart (spec S22).
 */
public class ValetController {

    /** Trusted-phone presence (spec S25/S26). The HCT BT stack (gocsdkrf210) is dead on attempt 35. */
    public enum PhonePresence { UNKNOWN, NONE, PRESENT }
    public interface PhonePresenceProbe { PhonePresence probe(); }
    public static class NoBtStackProbe implements PhonePresenceProbe {
        public PhonePresence probe() { return PhonePresence.UNKNOWN; }
    }

    private final Context ctx;
    private final SettingsStore store;
    private final Handler main;
    private final PackageManager pm;
    private final NotificationManager nm;
    private final PhonePresenceProbe probe;
    private boolean active;
    private int savedFilter = -1; // read via reflection; -1 = unknown -> restore "all" on exit

    public ValetController(Context c, SettingsStore s, PhonePresenceProbe probe) {
        ctx = c.getApplicationContext();
        store = s;
        main = new Handler(ctx.getMainLooper());
        pm = ctx.getPackageManager();
        nm = (NotificationManager) ctx.getSystemService(Context.NOTIFICATION_SERVICE);
        this.probe = probe;
    }

    public boolean isActive() { return active; }

    /** Trusted-phone presence for the settings warning (spec S26a). */
    public boolean trustedPhonePresent() { return probe.probe() == PhonePresence.PRESENT; }

    public void scheduleAutoEnter() {
        if (!store.valetEnabled() || !store.valetAuto()) return; // master off or auto off: inert (S27a)
        main.postDelayed(() -> {
            // Auto-entry only with an exit path: with no phone present the PIN is the only way
            // back out (S26a), so a missing PIN must block auto-entry.
            boolean pinSet = !store.valetPinHash().isEmpty();
            if (!active && probe.probe() == PhonePresence.NONE
                    && ValetPolicy.entryAllowed(true, pinSet, false)) {
                enter();
            }
        }, store.valetTimeoutS() * 1000L);
    }

    public void enter() {
        if (active) return;
        if (!store.valetEnabled()) return;                    // master switch off: valet inert (S27a)
        boolean pinSet = !store.valetPinHash().isEmpty();
        boolean trusted = probe.probe() == PhonePresence.PRESENT;
        if (!ValetPolicy.entryAllowed(true, pinSet, trusted)) {
            android.util.Log.i("ValetController", "valet entry refused: no exit configured (S26a)");
            return;
        }
        List<String> list = suspendList();
        // Persist first: crash-safe replay (S22).
        store.put("valet_active", true);
        store.put("valet_suspend", TextUtils.join(",", list));
        saveInterruptionFilter();
        suspend(list, true);
        try { nm.setInterruptionFilter(NotificationManager.INTERRUPTION_FILTER_NONE); }
        catch (Throwable t) { /* no policy access: notifications still blocked by suspension */ }
        statusBarDisable(true);
        active = true;
    }

    public void exit() {
        if (!active) return;
        List<String> list = split(store.getString("valet_suspend", ""));
        suspend(list, false);
        restoreInterruptionFilter();
        statusBarDisable(false);
        store.put("valet_active", false);
        store.put("valet_suspend", "");
        active = false;
    }

    /**
     * After a crash/restart: replay the persisted valet state. ValetPolicy.replayAction decides:
     * APPLY re-suspends, EXIT unsuspends - the EXIT case covers the master switch being turned off
     * AND the exit path disappearing (PIN wiped while active, BT dead), which must never re-trap
     * the owner (spec S22/S26a/S27a).
     */
    public void replayPending() {
        if (active) return;
        boolean persisted = store.getBool("valet_active", false);
        ValetPolicy.Replay action = ValetPolicy.replayAction(persisted, store.valetEnabled(),
            !store.valetPinHash().isEmpty(), trustedPhonePresent());
        if (action == ValetPolicy.Replay.NONE) return;
        List<String> list = split(store.getString("valet_suspend", ""));
        if (action == ValetPolicy.Replay.EXIT) {
            suspend(list, false);
            statusBarDisable(false);
            restoreInterruptionFilter();
            store.put("valet_active", false);
            store.put("valet_suspend", "");
            android.util.Log.i("ValetController", "valet replay: exiting (master off / no exit configured)");
            return;
        }
        suspend(list, true);
        statusBarDisable(true);
        try { nm.setInterruptionFilter(NotificationManager.INTERRUPTION_FILTER_NONE); }
        catch (Throwable t) { }
        active = true;
    }

    private void restoreInterruptionFilter() {
        try {
            int restore = savedFilter >= 0 ? savedFilter : NotificationManager.INTERRUPTION_FILTER_ALL;
            nm.setInterruptionFilter(restore);
        } catch (Throwable t) { /* no policy access: nothing more we can do */ }
    }

    List<String> suspendList() {
        return ValetPolicy.computeSuspend(installedApps(), allowedExtras());
    }

    /** Home tiles while in valet (spec S27). */
    public List<String> homeTiles() {
        return ValetPolicy.homeTiles(installedApps(), allowedExtras());
    }

    /** Extras for the drawer/suspend list: owner extras + the nav app the map card targets. */
    public Set<String> allowedExtras() {
        return ValetPolicy.withMapTarget(store.valetExtras(), navTarget);
    }

    /** Set by LauncherActivity after the map card resolved its target (spec S21/S7). */
    public void setNavTarget(String pkg) { navTarget = pkg; }

    private String navTarget;

    /** Re-derive the suspend list while active (nav target changed / replay ran before init). */
    public void refreshSuspension() {
        if (!active) return;
        List<String> fresh = suspendList();
        suspend(split(store.getString("valet_suspend", "")), false); // lift the old list first
        store.put("valet_suspend", TextUtils.join(",", fresh));
        suspend(fresh, true);
    }

    List<ValetPolicy.App> installedApps() {
        List<ValetPolicy.App> out = new ArrayList<>();
        try {
            for (ApplicationInfo a : pm.getInstalledApplications(0)) {
                boolean system = (a.flags & ApplicationInfo.FLAG_SYSTEM) != 0
                              || (a.flags & ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) != 0;
                out.add(new ValetPolicy.App(a.packageName, system));
            }
        } catch (Throwable t) { /* QUERY_ALL_PACKAGES missing: degrade to empty */ }
        return out;
    }

    void suspend(List<String> pkgs, boolean on) {
        if (pkgs.isEmpty()) return;
        try {
            Bundle appData = on ? new Bundle() : null;
            if (on) appData.putString("reason", "valet");
            pm.setPackagesSuspended(pkgs.toArray(new String[0]), appData);
        } catch (Throwable t) {
            // SecurityException/removed overload: leave manual toggle usable, log for debugging.
            android.util.Log.w("ValetController", "setPackagesSuspended failed", t);
        }
    }

    static List<String> split(String csv) {
        List<String> out = new ArrayList<>();
        for (String t : csv.split(",")) if (!t.isEmpty()) out.add(t.trim());
        return out;
    }

    void saveInterruptionFilter() {
        try {
            Method m = nm.getClass().getMethod("getCurrentInterruptionFilter");
            Object v = m.invoke(nm);
            if (v instanceof Integer) savedFilter = (Integer) v;
        } catch (Throwable ignore) { savedFilter = -1; }
    }

    /**
     * StatusBarManager.disable(mask): no shade, no quick settings, no recents (spec S24).
     * Constants are resolved reflectively from whatever the tree exposes; the mask is built at
     * runtime so drift cannot crash. VERIFY against frameworks/base StatusBarManager.java.
     */
    void statusBarDisable(boolean on) {
        try {
            Object sb = ctx.getSystemService("status_bar");
            Class<?> cls = sb.getClass();
            int mask = 0;
            for (String name : new String[]{"DISABLE_EXPAND", "DISABLE_NOTIFICATIONS", "DISABLE_RECENTS"}) {
                try {
                    java.lang.reflect.Field f = cls.getField(name);
                    mask |= f.getInt(null);
                } catch (NoSuchFieldException ignore) { }
            }
            Method disable = cls.getMethod("disable", int.class);
            disable.invoke(sb, on ? mask : 0);
        } catch (Throwable t) {
            android.util.Log.w("ValetController", "status bar disable failed", t);
        }
    }
}
