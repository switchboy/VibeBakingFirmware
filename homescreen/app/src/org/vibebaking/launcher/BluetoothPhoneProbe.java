package org.vibebaking.launcher;

import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothManager;
import android.bluetooth.BluetoothProfile;
import android.content.Context;

import org.vibebaking.launcher.logic.PhonePolicy;
import org.vibebaking.launcher.logic.PhonePresence;
import org.vibebaking.launcher.logic.PhonePresenceProbe;

import java.util.HashMap;
import java.util.Map;

/**
 * Real trusted-phone probe over Android's Bluetooth stack (spec S25/S26). The HCT stack is live
 * since attempts 36/37 (pairing, HFP calls, PBAP contacts, A2DP music all work), so
 * adapter/bonded/profile state is a trustworthy signal. Every decision is in `PhonePolicy` (pure);
 * anything we cannot read yields UNKNOWN, which never auto-enters valet and never exits it.
 */
public class BluetoothPhoneProbe implements PhonePresenceProbe {

    private final Context ctx;
    private BluetoothAdapter adapter;
    private final Map<Integer, BluetoothProfile> proxies = new HashMap<>();

    private final BluetoothProfile.ServiceListener proxyListener = new BluetoothProfile.ServiceListener() {
        @Override public void onServiceConnected(int profile, BluetoothProfile proxy) {
            synchronized (proxies) { proxies.put(profile, proxy); }
        }
        @Override public void onServiceDisconnected(int profile) {
            synchronized (proxies) { proxies.remove(profile); }
        }
    };

    public BluetoothPhoneProbe(Context c) {
        ctx = c.getApplicationContext();
        try {
            BluetoothManager mgr = (BluetoothManager) ctx.getSystemService(Context.BLUETOOTH_SERVICE);
            adapter = mgr == null ? null : mgr.getAdapter();
        } catch (Throwable t) { adapter = null; }
        if (adapter != null) {
            try {
                adapter.getProfileProxy(ctx, proxyListener, BluetoothProfile.A2DP);   // music connected
                adapter.getProfileProxy(ctx, proxyListener, BluetoothProfile.HEADSET); // hands-free connected
            } catch (Throwable t) { adapter = null; }
        }
    }

    @Override
    public PhonePresence probe() {
        try {
            if (adapter == null) return PhonePolicy.decideAndroid(false, 0, 0, true);
            if (!adapter.isEnabled()) return PhonePolicy.decideAndroid(false, 0, 0, false); // BT off: intent unknown
            boolean profilesReady;
            int connected;
            synchronized (proxies) {
                profilesReady = !proxies.isEmpty();
                connected = 0;
                for (BluetoothProfile p : proxies.values()) connected += p.getConnectedDevices().size();
            }
            int bonded = adapter.getBondedDevices().size(); // SecurityException -> caught below
            return PhonePolicy.decideAndroid(true, bonded, connected, !profilesReady);
        } catch (Throwable t) {
            return PhonePolicy.decideAndroid(false, 0, 0, true); // no BT permission / stack down: trust nothing
        }
    }

    /** Release the profile proxies (app teardown). */
    public void release() {
        synchronized (proxies) {
            if (adapter != null) {
                for (int profile : proxies.keySet()) {
                    try { adapter.closeProfileProxy(profile, proxies.get(profile)); }
                    catch (Throwable ignore) { }
                }
            }
            proxies.clear();
        }
    }

    /** Paired trusted phones configured (exit path even while the phone is away, spec S26a). */
    public boolean trustedPhoneConfigured() {
        try {
            return adapter != null && adapter.isEnabled()
                && PhonePolicy.trustedPhoneConfigured(!adapter.getBondedDevices().isEmpty());
        } catch (Throwable t) { return false; }
    }
}
