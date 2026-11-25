package org.vibebaking.launcher.logic;

/**
 * Trusted-phone decision (spec S25/S26/S26a). Pure: the Bluetooth glue lives in `HctBluetoothProbe`
 * (the HCT/GOC BT stack's broadcasts) and `BluetoothPhoneProbe` (Android's own stack, kept as a
 * second source). This maps the raw signals to a verdict so the valet auto-entry and exit rules are
 * unit-testable without a phone in the car.
 */
public final class PhonePolicy {
    private PhonePolicy() {}

    /**
     * Android-stack verdict: adapterUsable = adapter present and enabled. Unknown/broken adapter ->
     * UNKNOWN: never auto-enter on a signal we cannot trust (S25), never treat it as "present".
     * Paired but not connected means the phone is not in the car -> NONE.
     */
    public static PhonePresence decideAndroid(boolean adapterUsable, int bondedCount, int connectedCount, boolean failed) {
        if (failed || !adapterUsable) return PhonePresence.UNKNOWN;
        if (connectedCount > 0) return PhonePresence.PRESENT;
        if (bondedCount <= 0) return PhonePresence.NONE;
        return PhonePresence.NONE; // trusted phone paired but away
    }

    /**
     * HCT verdict from the GOC/BlueToothService signals. `sawSignal` = we have heard at least one
     * BT state broadcast since registration (otherwise the stack told us nothing -> UNKNOWN).
     * connected = `net.easyconn.bt.connected` seen without a later `notconnected`.
     * opened    = `net.easyconn.bt.opened` seen (stack up, phone not necessarily connected).
     * paired    = the pair list carries at least one device address.
     */
    public static PhonePresence decideHct(boolean sawSignal, boolean connected, boolean opened, boolean paired) {
        if (!sawSignal) return PhonePresence.UNKNOWN; // no broadcasts yet: trust nothing
        if (connected) return PhonePresence.PRESENT;
        if (paired) return PhonePresence.NONE;         // paired phone, currently away
        return opened ? PhonePresence.NONE : PhonePresence.UNKNOWN;
    }

    /**
     * Combine the two sources. The HCT stack is the real BT on this unit, so its verdict wins when
     * it is informative; Android's stack is the fallback (and wins only if HCT told us nothing).
     * Two UNKNOWNs stay UNKNOWN: never auto-enter, never exit (spec S25/S26a).
     */
    public static PhonePresence combine(PhonePresence hct, PhonePresence android) {
        if (hct != null && hct != PhonePresence.UNKNOWN) return hct;
        if (android != null && android != PhonePresence.UNKNOWN) return android;
        return PhonePresence.UNKNOWN;
    }

    /** Whether a trusted phone is *configured* (paired): a potential exit path even while away. */
    public static boolean trustedPhoneConfigured(boolean paired) { return paired; }

    /**
     * Counts Bluetooth device addresses in the HCT pair/device list as stored by
     * `BlueToothService.saveList()` -> `Settings.System` (`MTC.BT.deviceList` / `MTC.BT.matchList`),
     * newline-separated. Entries that are device *names* or junk do not count; colon-separated and
     * bare 12-hex-digit addresses do. Null/garbage -> 0, never an exception.
     */
    public static int parseDeviceList(String raw) {
        if (raw == null || raw.isEmpty()) return 0;
        int n = 0;
        for (String line : raw.split("\n")) {
            if (line == null || line.isEmpty()) continue;
            // An entry may be "Name,AA:BB:CC:DD:EE:FF" or just the address: look anywhere in it.
            String t = line.replace(":", "");
            java.util.regex.Matcher m = java.util.regex.Pattern.compile("[0-9a-fA-F]{12}").matcher(t);
            if (m.find()) n++;
        }
        return n;
    }

    /**
     * Exit path for valet (spec S26a): the phone is in the car now, or it is paired so that
     * connecting it later ends valet. Both probes being UNKNOWN means no phone signal at all ->
     * only a PIN counts as an exit path, so valet entry is refused rather than trapping the owner.
     */
    public static boolean exitPathAvailable(PhonePresence p, boolean configured) {
        return exitWanted(p) || configured;
    }

    /** Auto-entry only when the signal is trustworthy and says "no phone in the car" (S25). */
    public static boolean autoEntryWanted(PhonePresence p) { return p == PhonePresence.NONE; }

    /** Exit hook: valet ends when a trusted phone connects (S26). */
    public static boolean exitWanted(PhonePresence p) { return p == PhonePresence.PRESENT; }
}
