package org.vibebaking.launcher.logic;

/**
 * Trusted-phone probe that consults BOTH sources (spec S25/S26): the HCT/GOC Bluetooth stack
 * (`HctBluetoothProbe`, the real BT on this unit) and Android's own stack (`BluetoothPhoneProbe`,
 * normally off here). Pure - no Android imports - so the fault-tolerance rules are unit-tested.
 *
 * Fault tolerance (spec S36/S37): a source that throws, returns null, or knows nothing contributes
 * UNKNOWN only. One service being unavailable must never crash the launcher and never poison the
 * other source's verdict. If both are UNKNOWN the combined verdict is UNKNOWN: valet never
 * auto-enters and never exits (S26a).
 */
public class CombinedPhoneProbe implements PhonePresenceProbe {

    private final PhonePresenceProbe hct;
    private final PhonePresenceProbe android;

    public CombinedPhoneProbe(PhonePresenceProbe hct, PhonePresenceProbe android) {
        this.hct = hct;
        this.android = android;
    }

    @Override
    public PhonePresence probe() {
        return PhonePolicy.combine(safe(hct), safe(android));
    }

    /** Either source reporting a paired device counts as a configured exit path (S26a). */
    @Override
    public boolean trustedPhoneConfigured() {
        return safeConfigured(hct) || safeConfigured(android);
    }

    @Override
    public void release() {
        safeRelease(hct);
        safeRelease(android);
    }

    /** A broken source contributes UNKNOWN; it must never propagate an exception. */
    static PhonePresence safe(PhonePresenceProbe p) {
        if (p == null) return PhonePresence.UNKNOWN;
        try {
            PhonePresence v = p.probe();
            return v == null ? PhonePresence.UNKNOWN : v;
        } catch (Throwable t) { return PhonePresence.UNKNOWN; }
    }

    static boolean safeConfigured(PhonePresenceProbe p) {
        if (p == null) return false;
        try { return p.trustedPhoneConfigured(); } catch (Throwable t) { return false; }
    }

    static void safeRelease(PhonePresenceProbe p) {
        if (p == null) return;
        try { p.release(); } catch (Throwable ignore) { }
    }

    /** Fallback source for builds with no usable BT stack: inert, never throws. */
    public static class Inert implements PhonePresenceProbe {
        @Override public PhonePresence probe() { return PhonePresence.UNKNOWN; }
    }
}
