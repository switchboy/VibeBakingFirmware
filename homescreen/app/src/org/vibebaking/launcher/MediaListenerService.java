package org.vibebaking.launcher;

import android.content.Intent;
import android.service.notification.NotificationListenerService;

/** Notification listener used for MediaSessionManager.getActiveSessions (spec S10/S14). */
public class MediaListenerService extends NotificationListenerService {

    public static volatile MediaListenerService instance;
    public interface Callback { void onListenerConnected(); }
    public static volatile Callback callback;

    @Override public void onListenerConnected() {
        instance = this;
        if (callback != null) callback.onListenerConnected();
    }

    @Override public void onListenerDisconnected() { instance = null; }

    /** Ask the owner to enable listener access (spec S14). */
    public static void requestAccess(android.content.Context c) {
        Intent i = new Intent("android.settings.ACTION_NOTIFICATION_LISTENER_SETTINGS");
        i.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK);
        try { c.startActivity(i); } catch (Throwable ignore) { }
    }
}
