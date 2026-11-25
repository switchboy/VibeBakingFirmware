package org.vibebaking.launcher;

import android.app.Activity;
import android.os.Bundle;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Button;

import org.vibebaking.launcher.logic.DayNight;
import org.vibebaking.launcher.logic.FavoritePolicy;
import org.vibebaking.launcher.logic.PhonePresence;
import org.vibebaking.launcher.logic.SettingsKeys;
import org.vibebaking.launcher.logic.ThemePolicy;

import java.util.TimeZone;

/** Launcher settings screen (spec S28-S31, S21, S25, S26) - the owner's car settings live here. */
public class CarSettingsActivity extends Activity {

    private SettingsStore store;

    @Override
    protected void onCreate(Bundle saved) {
        super.onCreate(saved);
        store = App.store();
        LinearLayout page = new LinearLayout(this);
        page.setOrientation(LinearLayout.VERTICAL);
        android.widget.ScrollView scroll = new android.widget.ScrollView(this);
        scroll.addView(page);
        setContentView(scroll);

        addCycle(page, "Car lights on \u2192 backlight",
            SettingsKeys.KEY_BACKLIGHT_MODE, new String[]{"nothing", "dim"}, store.backlightMode());
        addCycle(page, "Backlight dim level",
            SettingsKeys.KEY_BACKLIGHT_PERCENT, new int[]{20, 40, 60, 80}, store.backlightPercent());
        addCycle(page, "Car lights on \u2192 theme",
            SettingsKeys.KEY_THEME_ON_LIGHTS, new String[]{"nothing", "dark"}, store.themeOnLights());
        addCycle(page, "Dark mode",
            SettingsKeys.KEY_DARK_MODE, new String[]{"cycle", "always_light", "always_dark", "car_lights"},
            store.darkMode());
        addCycle(page, "Reverse gear \u2192 volume",
            SettingsKeys.KEY_REVERSE_VOLUME, new String[]{"unchanged", "lower", "mute"}, store.reverseVolume());
        addCycle(page, "Reverse volume level",
            SettingsKeys.KEY_REVERSE_VOLUME_PERCENT, new int[]{20, 30, 40, 50}, store.reversePercent());
        addCycle(page, "Let MCU attenuate reverse volume (ctl_backview_vol)",
            SettingsKeys.KEY_REVERSE_MCU, new boolean[]{false, true}, store.reverseMcu());
        addCycle(page, "Map card app",
            SettingsKeys.KEY_MAP_TARGET, new String[]{"auto", "maps", "waze"}, store.mapTarget());
        addCycle(page, "Bluetooth app tab for the phone slot (curTab)",
            SettingsKeys.KEY_BT_DIAL_TAB, new int[]{0, 1, 2}, store.btDialTab());
        addInfo(page, "Bottom favourite row: " + favSummary()
            + " — long-press an app in the drawer to pin it, long-press a slot to clear it");
        addCycle(page, "Valet auto-entry when no trusted phone connects (BT)",
            SettingsKeys.KEY_VALET_AUTO, new boolean[]{false, true}, store.valetAuto());
        addInfo(page, "Valet timeout (s): " + store.valetTimeoutS()
            + " — phone status now: " + phoneStatus());
        addInfo(page, "Allowed valet apps: Maps, radio, Bluetooth, front/rear camera (+extras, +the map card's nav app)");

        // Master switch (S27a) + manual toggle (S25) + bootstrap warning (S26a).
        Row masterRow = new Row("Valet mode enabled (master)", page);
        masterRow.textView.setText(store.valetEnabled() ? "on" : "off");
        masterRow.view.setOnClickListener(v -> {
            boolean next = !store.valetEnabled();
            store.put(SettingsKeys.KEY_VALET_ENABLED, next);
            masterRow.textView.setText(next ? "on" : "off");
            if (!next && App.valet().isActive()) App.valet().exit(); // turning off while active exits
            updateWarn();
        });
        Row activeRow = new Row("Valet mode active (manual toggle)", page);
        activeRow.textView.setText(App.valet().isActive() ? "on" : "off");
        activeRow.view.setOnClickListener(v -> {
            if (App.valet().isActive()) App.valet().exit(); else App.valet().enter();
            activeRow.textView.setText(App.valet().isActive() ? "on" : "off");
            updateWarn();
        });

        EditText pin = new EditText(this);
        pin.setHint("valet PIN");
        pin.setInputType(android.text.InputType.TYPE_CLASS_NUMBER);
        Button save = new Button(this);
        save.setText("Save PIN");
        save.setOnClickListener(v -> {
            String p = pin.getText().toString();
            if (p.length() >= 4) {
                store.setValetPin(p);
                save.setText("PIN saved");
                updateWarn();
            }
        });
        page.addView(pin);
        page.addView(save);
        valetWarn = new TextView(this);
        valetWarn.setTextSize(16f);
        valetWarn.setTextColor(getResources().getColor(R.color.battery_low));
        valetWarn.setPadding(24, 16, 24, 16);
        page.addView(valetWarn);
        updateWarn();
    }

    private TextView valetWarn;

    /** S26a warning: enabled but no exit path -> say it loudly. */
    void updateWarn() {
        boolean warn = org.vibebaking.launcher.logic.ValetPolicy.warnNoExit(
            store.valetEnabled(), !store.valetPinHash().isEmpty(), App.valet().phoneExitPath());
        valetWarn.setText(warn ? getString(R.string.valet_no_exit) : "");
        valetWarn.setVisibility(warn ? android.view.View.VISIBLE : android.view.View.GONE);
    }

    /** The bottom row as the owner sees it: glyph + package per slot, "+" for empty (spec S40). */
    String favSummary() {
        StringBuilder sb = new StringBuilder();
        for (String pkg : store.favSlots()) {
            sb.append(sb.length() == 0 ? "" : ", ");
            sb.append(FavoritePolicy.glyph(pkg)).append(" ").append(pkg.isEmpty() ? "empty" : pkg);
        }
        return sb.toString();
    }

    /** Human-readable trusted-phone verdict (spec S25/S26); the probes never throw. */
    String phoneStatus() {
        PhonePresence p = App.valet().probeSafe();
        boolean paired = App.valet().configuredSafe();
        switch (p) {
            case PRESENT: return "trusted phone connected";
            case NONE: return paired ? "phone paired but away" : "no phone paired";
            default: return paired ? "phone paired; BT state unknown" : "unknown (BT off or unavailable)";
        }
    }

    void addInfo(LinearLayout parent, String text) {
        TextView t = new TextView(this);
        t.setText(text);
        t.setTextSize(16f);
        t.setPadding(24, 16, 24, 16);
        parent.addView(t);
    }

    void addCycle(LinearLayout parent, String label, String key, String[] values, String current) {
        Row row = new Row(label, parent);
        row.textView.setText(current);
        row.view.setOnClickListener(v -> {
            int i = (indexOf(values, current) + 1) % values.length;
            store.put(key, values[i]);
            row.textView.setText(values[i]);
            reapplyTheme();
        });
    }

    void addCycle(LinearLayout parent, String label, String key, int[] values, int current) {
        Row row = new Row(label, parent);
        row.textView.setText(String.valueOf(current));
        row.view.setOnClickListener(v -> {
            int i = (indexOf(values, current) + 1) % values.length;
            store.put(key, values[i]);
            row.textView.setText(String.valueOf(values[i]));
        });
    }

    void addCycle(LinearLayout parent, String label, String key, boolean[] values, boolean current) {
        Row row = new Row(label, parent);
        row.textView.setText(current ? "on" : "off");
        row.view.setOnClickListener(v -> {
            boolean next = !current;
            store.put(key, next);
            row.textView.setText(next ? "on" : "off");
        });
    }

    static int indexOf(String[] a, String v) {
        for (int i = 0; i < a.length; i++) if (a[i].equals(v)) return i;
        return 0;
    }

    static int indexOf(int[] a, int v) {
        for (int i = 0; i < a.length; i++) if (a[i] == v) return i;
        return 0;
    }

    /** Dark-mode changes take effect immediately (spec S30). */
    void reapplyTheme() {
        long now = System.currentTimeMillis();
        int tz = TimeZone.getDefault().getOffset(now) / 3600_000;
        boolean night = ThemePolicy.night(store.darkMode(), App.car().booleanState("headlight"),
            DayNight.isNight(store.radarLat(), store.radarLon(), now, tz), store.themeOnLights());
        App.theme().apply(night);
    }

    private final class Row {
        final android.widget.LinearLayout view;
        final TextView textView;
        Row(String label, LinearLayout parent) {
            view = new android.widget.LinearLayout(CarSettingsActivity.this);
            view.setOrientation(LinearLayout.HORIZONTAL);
            TextView l = new TextView(CarSettingsActivity.this);
            l.setText(label);
            l.setTextSize(18f);
            l.setPadding(24, 16, 24, 16);
            textView = new TextView(CarSettingsActivity.this);
            textView.setTextSize(18f);
            textView.setPadding(24, 16, 24, 16);
            view.addView(l);
            view.addView(textView);
            parent.addView(view);
        }
    }

}
