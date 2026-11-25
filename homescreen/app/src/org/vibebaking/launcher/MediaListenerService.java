package org.vibebaking.launcher;

import android.app.Notification;
import android.content.Intent;
import android.service.notification.NotificationListenerService;
import android.service.notification.StatusBarNotification;

import org.vibebaking.launcher.logic.MapTargetPolicy;

/**
 * Notification listener: needed for MediaSessionManager.getActiveSessions (spec S10/S14), and used to see whether the
 * nav app is navigating (map card compact mode, MapCardPolicy).
 *
 * Navigation = the nav app (Maps/Waze) shows a notification with category "navigation" (measured on the unit: Google
 * Maps turn-by-turn posts one, flags ONGOING|NO_CLEAR|FOREGROUND_SERVICE, channel 1_foreground_1), or as a fallback an
 * ongoing foreground-service notification of the nav app.
 */
public class MediaListenerService extends NotificationListenerService {

    public static volatile MediaListenerService instance;
    public interface Callback { void onListenerConnected(); }
    public static volatile Callback callback;

    public interface NavCallback { void onNavigationChanged(boolean navigating); }
    public static volatile NavCallback navCallback;
    private static volatile boolean navigating;

    /** True while the nav app guides (see class comment). */
    public static boolean isNavigating() { return navigating; }

    @Override public void onListenerConnected() {
        instance = this;
        if (callback != null) callback.onListenerConnected();
        recomputeNavigation();
    }

    @Override public void onListenerDisconnected() { instance = null; }

    @Override public void onNotificationPosted(StatusBarNotification sbn) {
        if (sbn != null && isNavPackage(sbn.getPackageName())) recomputeNavigation();
    }

    @Override public void onNotificationRemoved(StatusBarNotification sbn) {
        if (sbn != null && isNavPackage(sbn.getPackageName())) recomputeNavigation();
    }

    static boolean isNavPackage(String pkg) {
        return MapTargetPolicy.MAPS.equals(pkg) || MapTargetPolicy.WAZE.equals(pkg);
    }

    static boolean isNavigationNotification(StatusBarNotification sbn) {
        if (sbn == null || !isNavPackage(sbn.getPackageName())) return false;
        Notification n = sbn.getNotification();
        if (n == null) return false;
        if (Notification.CATEGORY_NAVIGATION.equals(n.category)) return true;
        int both = Notification.FLAG_ONGOING_EVENT | Notification.FLAG_FOREGROUND_SERVICE;
        return (n.flags & both) == both;
    }

    private void recomputeNavigation() {
        boolean now = false;
        try {
            StatusBarNotification[] all = getActiveNotifications();
            if (all != null) for (StatusBarNotification s : all) if (isNavigationNotification(s)) { now = true; break; }
        } catch (Throwable ignore) { /* listener not bound yet: keep "not navigating" */ }
        if (now != navigating) {
            navigating = now;
            NavCallback cb = navCallback;
            if (cb != null) cb.onNavigationChanged(now);
        }
    }

    /** Ask the owner to enable listener access (spec S14). */
    public static void requestAccess(android.content.Context c) {
        Intent i = new Intent("android.settings.ACTION_NOTIFICATION_LISTENER_SETTINGS");
        i.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK);
        try { c.startActivity(i); } catch (Throwable ignore) { }
    }
}
