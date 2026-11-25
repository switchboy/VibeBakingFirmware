package org.vibebaking.launcher.logic;

import java.util.Map;

/**
 * Parsing of CarService callback payloads (spec S19-S31 signals). The callback arrives from
 * CarService as onStatusChanged(String type, Bundle bundle); CarClient mirrors the Bundle to a
 * Map<String,Object> so this class is pure and unit-testable. Protocol facts:
 * cmd1=0x16 frames dispatch type string "CarEvent"; bundle keys "type"/"value"/"mode":
 *   backview: value=true(+mode)/false; headlight: value=boolean; battery: value=int (tenths of V,
 *   to be confirmed on the unit); ipod/handbrake: boolean; "key": int; acc_off/sleep: no value.
 */
public final class CarEventParser {

    public enum Kind { HEADLIGHT_ON, HEADLIGHT_OFF, BACKVIEW_START, BACKVIEW_STOP,
                       BATTERY, ACC_OFF, SLEEP, IPOD, HANDBRAKE, KEY, UNKNOWN }

    public static final class CarEvent {
        public final Kind kind;
        public final int intValue;      // battery tenths / key code
        public final String mode;       // backview mode: backview|frontview|rightview|""
        public final boolean flag;      // headlight/ipod/handbrake/backview value
        CarEvent(Kind k, int v, String m, boolean f) { kind = k; intValue = v; mode = m; flag = f; }
    }

    private CarEventParser() {}

    public static CarEvent parse(String callbackType, Map<String, Object> bundle) {
        if (bundle == null) return new CarEvent(Kind.UNKNOWN, 0, "", false);
        String type = String.valueOf(bundle.getOrDefault("type", ""));
        String mode = String.valueOf(bundle.getOrDefault("mode", ""));
        Object value = bundle.get("value");
        switch (type) {
            case "headlight":
                return truthy(value) ? new CarEvent(Kind.HEADLIGHT_ON, 0, "", true)
                                     : new CarEvent(Kind.HEADLIGHT_OFF, 0, "", false);
            case "backview":
                if (truthy(value)) return new CarEvent(Kind.BACKVIEW_START, 0, mode, true);
                return new CarEvent(Kind.BACKVIEW_STOP, 0, mode, false);
            case "battery":
                return new CarEvent(Kind.BATTERY, asInt(value), "", false);
            case "ipod":
                return new CarEvent(Kind.IPOD, 0, "", truthy(value));
            case "handbrake":
                return new CarEvent(Kind.HANDBRAKE, 0, "", truthy(value));
            case "key":
                return new CarEvent(Kind.KEY, asInt(value), "", false);
            case "acc_off":
                return new CarEvent(Kind.ACC_OFF, 0, "", false);
            case "sleep":
                return new CarEvent(Kind.SLEEP, 0, "", false);
            default:
                return new CarEvent(Kind.UNKNOWN, 0, "", false);
        }
    }

    /** Bundle booleans arrive as Boolean, ints as Integer; tolerate the mixed shapes. */
    public static boolean truthy(Object v) {
        if (v instanceof Boolean) return (Boolean) v;
        if (v instanceof Number) return ((Number) v).intValue() != 0;
        if (v instanceof String) return "true".equals(v);
        return false;
    }

    public static int asInt(Object v) {
        if (v instanceof Number) return ((Number) v).intValue();
        if (v instanceof String) { try { return Integer.parseInt((String) v); } catch (NumberFormatException e) { return 0; } }
        return 0;
    }
}
