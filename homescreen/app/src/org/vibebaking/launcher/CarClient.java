package org.vibebaking.launcher;

import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;

import org.vibebaking.launcher.logic.CarEventParser;

import java.lang.reflect.Method;
import java.util.HashMap;
import java.util.Map;

/**
 * Reflective bridge to android.microntek.CarManager (spec S36): the HCT framework jar may not be
 * deployed yet, and "carservice" may register late (HCTManagerService.onCreate, attempt 35).
 * Reflection keeps a missing jar from ever crashing the launcher. Retry every RETRY_MS until a
 * callback arrives. All Bundle payloads are mirrored to Map<String,Object> and parsed by
 * CarEventParser (pure logic).
 */
public class CarClient {

    public static final long RETRY_MS = 10_000L;
    private static final String LISTENER_CLASS = "android.microntek.CarListener";
    private static final String MANAGER_CLASS = "android.microntek.CarManager";

    public interface Listener {
        void onCarEvent(CarEventParser.CarEvent e);
        void onCarAvailable(boolean available);
    }

    private final Handler main = new Handler(Looper.getMainLooper());
    private Listener listener;
    private Object carManager;      // android.microntek.CarManager instance or null
    private Method getBooleanState;
    private Method getStringState;
    private Method setParameters;
    private boolean methodsReady;   // CarManager usable for state reads
    private boolean connected;      // at least one callback arrived: "carservice" really alive
    private int retries;

    public void attach(Listener l) {
        listener = l;
        tryConnect();
    }

    private void tryConnect() {
        if (connected || retries > 30) return; // give up after ~5 min; try again next boot
        retries++;
        try {
            Class<?> mgrCls = Class.forName(MANAGER_CLASS);
            if (carManager == null) carManager = mgrCls.getConstructor().newInstance();
            // CarManager.attach(CarListener, String) registers the callback for ALL event types;
            // the callback delivers onStatusChanged(String type, Bundle bundle) on a BINDER thread (no handler is
            // passed): the bundle is copied there, the event is handed to the main thread (see deliver()).
            Class<?> listenerCls = Class.forName(LISTENER_CLASS);
            Object proxy = java.lang.reflect.Proxy.newProxyInstance(
                listenerCls.getClassLoader(), new Class<?>[]{listenerCls},
                (p, m, args) -> {
                    if ("onStatusChanged".equals(m.getName())) {
                        String type = args[0] instanceof String ? (String) args[0] : "";
                        Bundle b = args[1] instanceof Bundle ? (Bundle) args[1] : null;
                        final Map<String, Object> copy = mirrorBundle(b);
                        main.post(() -> deliver(type, copy));
                    }
                    return null;
                });
            Method attach = mgrCls.getMethod("attach", listenerCls, String.class);
            attach.invoke(carManager, proxy, "CarEvent");
            getBooleanState = mgrCls.getMethod("getBooleanState", String.class);
            getStringState = mgrCls.getMethod("getStringState", String.class);
            setParameters = mgrCls.getMethod("setParameters", String.class);
            methodsReady = true;
            // attach() swallows RemoteException (binder not up yet) - keep re-registering until a
            // callback actually arrives; RemoteCallbackList dedupes our callback binder.
            main.postDelayed(() -> tryConnect(), RETRY_MS);
        } catch (Throwable t) {
            // jar missing, hidden-API rejection: degrade quietly, retry until next boot.
            main.postDelayed(() -> tryConnect(), RETRY_MS);
        }
    }

    /**
     * Main thread only. The listener touches views (volt meter, theme); on the unit (2026-11-26) a binder-thread
     * delivery set layout flags up to the DecorView before ViewRootImpl threw CalledFromWrongThreadException, which
     * the HCT callback swallowed - every later layout request was then ignored (favourites overlay, compact map).
     */
    private void deliver(String type, Map<String, Object> bundle) {
        if (!connected) { connected = true; if (listener != null) listener.onCarAvailable(true); }
        CarEventParser.CarEvent e = CarEventParser.parse(type, bundle);
        if (listener != null && e.kind != CarEventParser.Kind.UNKNOWN) listener.onCarEvent(e);
    }

    /** Bundle -> Map via Bundle.get(String) (public); tolerate RemoteException-style failures. */
    static Map<String, Object> mirrorBundle(Bundle b) {
        Map<String, Object> m = new HashMap<>();
        if (b == null) return m;
        try {
            for (String k : b.keySet()) m.put(k, b.get(k));
        } catch (Throwable ignore) { /* never crash the home screen */ }
        return m;
    }

    public boolean isAvailable() { return connected; }

    /** Initial state reads (spec S28/S31 initial signals); false on any failure. */
    public boolean booleanState(String key) {
        if (!methodsReady) return false;
        try {
            Object v = getBooleanState.invoke(carManager, key);
            return v instanceof Boolean && (Boolean) v;
        } catch (Throwable t) { return false; }
    }

    public String stringState(String key) {
        if (!methodsReady) return "";
        try {
            Object v = getStringState.invoke(carManager, key);
            return v instanceof String ? (String) v : "";
        } catch (Throwable t) { return ""; }
    }

    /** MCU command pass-through (spec S31 MCU delegation: ctl_backview_vol=<pct>). */
    public boolean sendCommand(String cmd) {
        if (!methodsReady) return false;
        try {
            setParameters.invoke(carManager, cmd);
            return true;
        } catch (Throwable t) { return false; }
    }

    public void detach() {
        try {
            carManager.getClass().getMethod("detach").invoke(carManager);
        } catch (Throwable ignore) { }
        connected = false;
    }
}
