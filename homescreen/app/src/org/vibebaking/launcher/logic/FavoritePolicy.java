package org.vibebaking.launcher.logic;

import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * The bottom favourite row on the home screen (spec S40): four slots, one tap each. Slot 0 ships
 * preinstalled with the HCT Bluetooth app (`com.microntek.bluetooth`), whose MainActivity carries the
 * dialer tab - the owner's hands-free dialling entry point (S40a). The other slots start empty and
 * the owner fills them from the app drawer (long-press an app, spec S40c).
 *
 * Pure: the Android side supplies icons/launch intents, this decides slot contents, ordering,
 * visibility during valet (S40b: slots outside the allowed set are hidden, so the row can never be
 * an escape around the suspension) and junk-tolerant parsing of the stored CSV.
 */
public final class FavoritePolicy {

    public static final int MAX_SLOTS = 4;

    /** Preinstalled slot-0 favourite: HCT Bluetooth app (MainActivity = dialer tab). */
    public static final String PHONE_PACKAGE = "com.microntek.bluetooth";

    /** Intent extra the BT app reads to select its tab (`curTab`); index verified on the unit (A13). */
    public static final String BT_TAB_EXTRA = "curTab";
    public static final int BT_TAB_MIN = 0;
    public static final int BT_TAB_MAX = 2;

    private FavoritePolicy() {}

    /**
     * Slots from the stored CSV, read **positionally**: the store form is exactly MAX_SLOTS
     * comma-separated fields, so clearing slot 2 must not shift slot 3. A missing/empty pref gives
     * the default row (phone slot preinstalled); a present pref is honoured even when every slot is
     * blank (the owner cleared them). Duplicate packages collapse to the later field (first wins).
     */
    public static List<String> slots(String csv) {
        if (csv == null || csv.isEmpty()) return defaults();
        String[] parts = csv.split(",", -1);
        List<String> out = new ArrayList<>();
        Set<String> seen = new HashSet<>();
        for (int i = 0; i < MAX_SLOTS; i++) {
            String v = i < parts.length ? parts[i].trim() : "";
            if (v.isEmpty() || !seen.add(v)) { out.add(""); continue; } // blank, or a duplicate
            out.add(v);
        }
        return out;
    }

    /** Default row: phone slot preinstalled (owner, Nov 25), three empty slots. */
    public static List<String> defaults() {
        List<String> out = new ArrayList<>();
        out.add(PHONE_PACKAGE);
        for (int i = 1; i < MAX_SLOTS; i++) out.add("");
        return out;
    }

    /** Store form: exactly MAX_SLOTS comma-separated fields (empty slots as empty fields). */
    public static String csv(List<String> slots) {
        List<String> s = normalize(slots);
        return String.join(",", s);
    }

    /** Always exactly MAX_SLOTS fields, blanks collapsed to "". */
    public static List<String> normalize(List<String> slots) {
        List<String> out = new ArrayList<>();
        if (slots == null) return defaults();
        for (String v : slots) out.add(v == null ? "" : v.trim());
        while (out.size() < MAX_SLOTS) out.add("");
        if (out.size() > MAX_SLOTS) out = out.subList(0, MAX_SLOTS);
        return out;
    }

    /**
     * Assign a package to a slot: duplicates are removed first (a favourite appears once), then the
     * first empty slot is used; if the row is full, slot 0 is replaced (slot 0 is the "primary"
     * slot, which is also where the preinstalled phone lives).
     */
    public static List<String> assign(List<String> slots, String pkg) {
        List<String> out = normalize(slots);
        if (pkg == null || pkg.trim().isEmpty()) return out;
        String p = pkg.trim();
        if (out.contains(p)) return out;   // already pinned: keep the slot it lives in
        int idx = out.indexOf("");
        if (idx < 0) idx = 0;              // row full: the primary slot is the one that gets replaced
        out.set(idx, p);
        return out;
    }

    /** Empty one slot (index out of range -> unchanged). */
    public static List<String> clear(List<String> slots, int index) {
        List<String> out = normalize(slots);
        if (index < 0 || index >= MAX_SLOTS) return out;
        out.set(index, "");
        return out;
    }

    /**
     * What the bar renders per slot: "" = empty slot (tap opens the drawer). Hidden packages
     * collapse to an empty slot so the four slots stay aligned: an uninstalled favourite must not
     * shift the row, and in valet mode anything outside the allowed set is hidden (S40b).
     */
    public static List<String> visible(List<String> slots, boolean valetActive,
                                      Set<String> allowed, Set<String> launchable) {
        List<String> out = new ArrayList<>();
        for (String pkg : normalize(slots)) {
            if (pkg.isEmpty()) { out.add(""); continue; }
            if (launchable != null && !launchable.contains(pkg)) { out.add(""); continue; }   // gone
            if (valetActive && allowed != null && !allowed.contains(pkg)) { out.add(""); continue; }
            out.add(pkg);
        }
        return out;
    }

    /** Glyph used when no app icon can be loaded (or for an empty slot). Never null. */
    public static String glyph(String pkg) {
        if (pkg == null || pkg.isEmpty()) return "＋";      // empty slot: tap opens the drawer
        if (pkg.equals(PHONE_PACKAGE)) return "☎";
        if (pkg.equals("com.microntek.radio")) return "♫";
        if (pkg.equals("com.microntek.frontview") || pkg.equals("com.microntek.backview")) return "◉";
        if (pkg.equals(MapTargetPolicy.MAPS) || pkg.equals(MapTargetPolicy.WAZE)) return "✥";
        return "▣";
    }

    /** BT dialer tab index from the owner setting; garbage clamped into BT_TAB_MIN..BT_TAB_MAX. */
    public static int dialTab(int raw) {
        if (raw < BT_TAB_MIN) return BT_TAB_MIN;
        if (raw > BT_TAB_MAX) return BT_TAB_MAX;
        return raw;
    }

    /** True when the package is the preinstalled phone slot (glyph + tab extra apply). */
    public static boolean isPhoneSlot(String pkg) { return PHONE_PACKAGE.equals(pkg); }

    /** Sorted allowed set for display (drawer marker / settings line); stable ordering. */
    public static List<String> sorted(List<String> pkgs) {
        List<String> out = new ArrayList<>();
        if (pkgs == null) return out;
        for (String p : pkgs) if (p != null && !p.isEmpty()) out.add(p);
        Collections.sort(out);
        return out;
    }
}
