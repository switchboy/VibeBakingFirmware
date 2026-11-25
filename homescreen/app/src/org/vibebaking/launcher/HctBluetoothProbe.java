package org.vibebaking.launcher;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.provider.Settings;

import org.vibebaking.launcher.logic.PhonePolicy;
import org.vibebaking.launcher.logic.PhonePresence;
import org.vibebaking.launcher.logic.PhonePresenceProbe;

/**
 * Trusted-phone probe through the HCT Bluetooth stack (spec S25/S25a) - the real BT on this unit;
 * Android's own stack is off here, so `BluetoothPhoneProbe` is only the second source.
 *
 * Two signals from the GOC daemon + `android.microntek.mtcser.BlueToothService`:
 *  - connection broadcasts: `net.easyconn.bt.connected` / `net.easyconn.bt.notconnected`
 *    / `net.easyconn.bt.opened` (BTDefine constants), plus the report `com.microntek.bt.report`;
 *  - the pair/device list the service stores in `Settings.System` via
 *    `saveList("MTC.BT.deviceList"|"MTC.BT.matchList", …)` -> newline-separated entries that
 *    contain the device addresses.
 *
 * Fault tolerance (spec S25b/S36/S37): a missing mtcser app, a receiver that cannot be registered,
 * junk broadcast extras or a Settings.System read failure simply leave this source UNKNOWN - no
 * exception ever escapes, and UNKNOWN never auto-enters valet and never exits it.
 */
public class HctBluetoothProbe implements PhonePresenceProbe {

    public static final String BT_CONNECTED = "net.easyconn.bt.connected";
    public static final String BT_NOT_CONNECTED = "net.easyconn.bt.notconnected";
    public static final String BT_OPENED = "net.easyconn.bt.opened";
    public static final String BT_REPORT = "com.microntek.bt.report";

    /** Settings.System keys written by BlueToothService.saveList(). */
    public static final String SETTINGS_DEVICE_LIST = "MTC.BT.deviceList";
    public static final String SETTINGS_MATCH_LIST = "MTC.BT.matchList";

    private final Context ctx;
    private volatile boolean registered;
    private volatile boolean sawSignal;
    private volatile boolean connected;
    private volatile boolean opened;
    private volatile boolean reportSawAddress;

    private final BroadcastReceiver receiver = new BroadcastReceiver() {
        @Override public void onReceive(Context c, Intent i) {
            try {
                String action = i == null ? "" : String.valueOf(i.getAction());
                switch (action) {
                    case BT_CONNECTED: connected = true; sawSignal = true; break;
                    case BT_NOT_CONNECTED: connected = false; sawSignal = true; break;
                    case BT_OPENED: opened = true; sawSignal = true; break;
                    case BT_REPORT:
                        sawSignal = true;
                        reportSawAddress = reportSawAddress || carriesDeviceAddress(i);
                        break;
                    default: break;
                }
            } catch (Throwable junkBroadcast) { /* never crash the launcher from a broadcast */ }
        }
    };

    public HctBluetoothProbe(Context c) {
        ctx = c.getApplicationContext();
        IntentFilter f = new IntentFilter();
        f.addAction(BT_CONNECTED);
        f.addAction(BT_NOT_CONNECTED);
        f.addAction(BT_OPENED);
        f.addAction(BT_REPORT);
        try {
            // API 34 requires an export flag for broadcasts sent by other apps.
            ctx.registerReceiver(receiver, f, Context.RECEIVER_EXPORTED);
            registered = true;
        } catch (Throwable t) {
            try {
                ctx.registerReceiver(receiver, f); // older platform path
                registered = true;
            } catch (Throwable t2) { registered = false; } // no receiver: probe stays UNKNOWN
        }
    }

    /** Pair-list/report heuristic: any extra that looks like a Bluetooth device address. */
    static boolean carriesDeviceAddress(Intent i) {
        if (i == null) return false;
        try {
            android.os.Bundle b = i.getExtras();
            if (b == null) return false;
            for (String key : b.keySet()) {
                Object v = b.get(key);
                if (v instanceof String && PhonePolicy.parseDeviceList((String) v) > 0) return true;
            }
        } catch (Throwable t) { /* malformed extras: treat as no address */ }
        return false;
    }

    /**
     * The service's stored pair list (Settings.System). Read fresh on every probe so a pairing done
     * while we were watching is picked up without waiting for a broadcast. Failure -> "".
     */
    String storedDeviceList() {
        try {
            String s = Settings.System.getString(ctx.getContentResolver(), SETTINGS_DEVICE_LIST);
            if (PhonePolicy.parseDeviceList(s) > 0) return s;
            return Settings.System.getString(ctx.getContentResolver(), SETTINGS_MATCH_LIST);
        } catch (Throwable t) { return ""; } // settings unreadable: no pair knowledge
    }

    @Override
    public PhonePresence probe() {
        boolean paired = pairedCount() > 0;
        // No broadcast yet but a stored pair list is still informative: the phone is paired.
        return PhonePolicy.decideHct(sawSignal || paired, connected, opened, paired);
    }

    /** Devices with an address in the service's list (exit path, spec S26a); failure -> 0. */
    int pairedCount() {
        return reportSawAddress ? 1 : PhonePolicy.parseDeviceList(storedDeviceList());
    }

    @Override
    public boolean trustedPhoneConfigured() { return pairedCount() > 0; }

    @Override
    public void release() {
        if (!registered) return;
        try { ctx.unregisterReceiver(receiver); } catch (Throwable ignore) { }
        registered = false;
    }
}
