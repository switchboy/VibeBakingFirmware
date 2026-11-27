package org.vibebaking.launcher;

import android.app.Activity;
import android.graphics.drawable.GradientDrawable;
import android.graphics.Typeface;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.View;
import android.view.inputmethod.EditorInfo;
import android.widget.CompoundButton;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.SeekBar;
import android.widget.ScrollView;
import android.widget.Switch;
import android.widget.TextView;

import org.vibebaking.launcher.logic.DayNight;
import org.vibebaking.launcher.logic.FavoritePolicy;
import org.vibebaking.launcher.logic.PhonePresence;
import org.vibebaking.launcher.logic.SettingsCycle;
import org.vibebaking.launcher.logic.SettingsKeys;
import org.vibebaking.launcher.logic.SettingsValidation;
import org.vibebaking.launcher.logic.ThemePolicy;
import org.vibebaking.launcher.logic.ValetPolicy;

import java.util.TimeZone;

/**
 * Launcher settings screen (spec S28-S31, S21, S25, S26) - the owner's car settings live here.
 * Round 6 (owner request 2026-11-27): a table of section cards, slider Switches, segmented pill
 * selectors, snapping SeekBars and styled number fields. The stuck-row bug came from click
 * lambdas capturing the value the screen opened with - every control now reads the store fresh
 * at click time, and the cycle/band math lives in pure logic/SettingsCycle + logic/SettingsValidation.
 */
public class CarSettingsActivity extends Activity {

    private SettingsStore store;
    private final Handler main = new Handler(Looper.getMainLooper());

    private TextView valetWarn;
    private TextView phoneStatusView;
    private EditText pinField, timeoutField;
    private TextView pinStatus, timeoutStatus;

    /** Fixed-width control column so every switch/selector lines up vertically (owner Round 6). */
    private static final int CONTROL_COL_DP = 260;
    private static final int ROW_MIN_DP = 56;      // row height 56-64 dp incl. padding
    private static final long STATUS_FADE_MS = 2000L; // "Saved" fades after 2 s

    @Override
    protected void onCreate(Bundle saved) {
        super.onCreate(saved);
        store = App.store();

        LinearLayout page = new LinearLayout(this);
        page.setOrientation(LinearLayout.VERTICAL);
        page.setPadding(dp(12), dp(8), dp(12), dp(8));
        ScrollView scroll = new ScrollView(this);
        scroll.setBackgroundColor(getResources().getColor(R.color.bg));
        scroll.addView(page);
        setContentView(scroll);

        addTitleBar(page);

        LinearLayout display = card(page, "Display");
        addSwitchRow(display, "Car lights on \u2192 backlight", "dim the panel while the headlights are on",
            SettingsKeys.KEY_BACKLIGHT_MODE, SettingsKeys.DEFAULT_BACKLIGHT_MODE, "nothing", "dim");
        addPercentRow(display, "Backlight dim level", SettingsKeys.KEY_BACKLIGHT_PERCENT,
            SettingsKeys.DEFAULT_BACKLIGHT_PERCENT, new int[] {20, 40, 60, 80});
        addSwitchRow(display, "Car lights on \u2192 theme", "dark theme when the headlights are on",
            SettingsKeys.KEY_THEME_ON_LIGHTS, SettingsKeys.DEFAULT_THEME_ON_LIGHTS, "nothing", "dark");
        addStringSegmentRow(display, "Dark mode", "how night is decided", SettingsKeys.KEY_DARK_MODE,
            SettingsKeys.DEFAULT_DARK_MODE,
            new String[] {"cycle", "always_light", "always_dark", "car_lights"},
            new String[] {"Sun", "Light", "Dark", "Car lights"}, true);

        LinearLayout reverse = card(page, "Reverse gear");
        addStringSegmentRow(reverse, "Reverse gear \u2192 volume", "what happens while reversing",
            SettingsKeys.KEY_REVERSE_VOLUME, SettingsKeys.DEFAULT_REVERSE_VOLUME,
            new String[] {"unchanged", "lower", "mute"},
            new String[] {"Unchanged", "Lower", "Mute"}, false);
        addPercentRow(reverse, "Reverse volume level", SettingsKeys.KEY_REVERSE_VOLUME_PERCENT,
            SettingsKeys.DEFAULT_REVERSE_VOLUME_PERCENT, new int[] {20, 30, 40, 50});
        addBoolSwitchRow(reverse, "Let MCU attenuate reverse volume (ctl_backview_vol)",
            "hand the attenuate/restore commands to the MCU instead of the launcher",
            SettingsKeys.KEY_REVERSE_MCU, SettingsKeys.DEFAULT_REVERSE_MCU);

        LinearLayout home = card(page, "Home screen");
        addStringSegmentRow(home, "Map card app", "which nav app the card hosts",
            SettingsKeys.KEY_MAP_TARGET, SettingsKeys.DEFAULT_MAP_TARGET,
            new String[] {"auto", "maps", "waze"}, new String[] {"Auto", "Maps", "Waze"}, false);
        addIntSegmentRow(home, "Bluetooth app tab for the phone slot (curTab)",
            "which tab of the BT app MainActivity the phone slot opens",
            SettingsKeys.KEY_BT_DIAL_TAB, SettingsKeys.DEFAULT_BT_DIAL_TAB,
            new int[] {0, 1, 2}, new String[] {"1", "2", "3"});
        addInfo(home, "Bottom favourite row: " + favSummary()
            + " \u2014 long-press an app in the drawer to pin it, long-press a slot to clear it");

        LinearLayout valet = card(page, "Valet mode");
        addValetMasterRow(valet);
        addValetActiveRow(valet);
        addBoolSwitchRow(valet, "Valet auto-entry when no trusted phone connects (BT)",
            "arms the timeout timer; needs the HCT BT stack",
            SettingsKeys.KEY_VALET_AUTO, SettingsKeys.DEFAULT_VALET_AUTO);
        addTimeoutRow(valet);
        addPinRow(valet);
        addInfo(valet, "Allowed valet apps: Maps, radio, Bluetooth, front/rear camera (+extras, +the map card's nav app)");
        phoneStatusView = addInfo(valet, "Trusted phone: " + phoneStatus());
        valetWarn = addInfo(valet, "");
        valetWarn.setTextColor(getResources().getColor(R.color.gauge_bad));
        updateWarn();
    }

    /** S26a warning: enabled but no exit path -> say it loudly. */
    void updateWarn() {
        boolean warn = ValetPolicy.warnNoExit(
            store.valetEnabled(), !store.valetPinHash().isEmpty(), App.valet().phoneExitPath());
        valetWarn.setText(warn ? getString(R.string.valet_no_exit) : "");
        valetWarn.setVisibility(warn ? View.VISIBLE : View.GONE);
        refreshPhoneStatus();
    }

    /** Info lines span the whole card in grey (owner Round 6); the phone status line is dynamic. */
    private void refreshPhoneStatus() {
        if (phoneStatusView != null) phoneStatusView.setText("Trusted phone: " + phoneStatus());
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

    // ---------------- layout helpers ----------------

    private int dp(float v) { return Math.round(v * getResources().getDisplayMetrics().density); }

    private int strokePx() { return Math.max(1, Math.round(1.5f * getResources().getDisplayMetrics().density)); }

    private void addTitleBar(LinearLayout page) {
        LinearLayout bar = new LinearLayout(this);
        bar.setOrientation(LinearLayout.HORIZONTAL);
        bar.setGravity(Gravity.CENTER_VERTICAL);
        bar.setPadding(dp(4), dp(4), dp(4), dp(10));
        TextView title = new TextView(this);
        title.setText("Car settings");
        title.setTextSize(22f);
        title.setTextColor(getResources().getColor(R.color.clock));
        bar.addView(title, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f));
        TextView close = new TextView(this);
        close.setText("\u2715 Close");
        close.setTextSize(16f);
        close.setTextColor(getResources().getColor(R.color.text_sub));
        close.setPadding(dp(12), dp(8), dp(12), dp(8));
        close.setBackgroundResource(R.drawable.card_bg);
        close.setClickable(true);
        close.setOnClickListener(v -> finish()); // finishes the activity (owner Round 6)
        bar.addView(close, new LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT,
            LinearLayout.LayoutParams.WRAP_CONTENT));
        page.addView(bar);
    }

    /** One section card with a header; rows get added inside it. */
    private LinearLayout card(LinearLayout page, String header) {
        LinearLayout c = new LinearLayout(this);
        c.setOrientation(LinearLayout.VERTICAL);
        c.setBackgroundResource(R.drawable.card_bg);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        lp.setMargins(dp(8), dp(6), dp(8), dp(6));
        page.addView(c, lp);
        TextView h = new TextView(this);
        h.setText(header);
        h.setTextSize(14f);
        h.setTextColor(getResources().getColor(R.color.accent));
        h.setPadding(dp(12), dp(10), dp(12), dp(2));
        c.addView(h);
        return c;
    }

    /** Thin divider between rows; colour follows text_sub at ~30% alpha (theme-aware). */
    private void addDivider(LinearLayout card) {
        if (card.getChildCount() <= 1) return; // no divider right under the header
        View div = new View(this);
        int grey = getResources().getColor(R.color.text_sub) & 0x00FFFFFF;
        div.setBackgroundColor(0x50000000 | grey);
        div.setLayoutParams(new LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, Math.max(1, dp(0.5f))));
        card.addView(div);
    }

    /** One table row: label (+ grey one-line description) left, control right in a fixed column. */
    private LinearLayout row(LinearLayout card, String label, String desc) {
        addDivider(card);
        LinearLayout r = new LinearLayout(this);
        r.setOrientation(LinearLayout.HORIZONTAL);
        r.setGravity(Gravity.CENTER_VERTICAL);
        r.setMinimumHeight(dp(ROW_MIN_DP));
        r.setPadding(dp(12), dp(8), dp(12), dp(8));
        LinearLayout left = new LinearLayout(this);
        left.setOrientation(LinearLayout.VERTICAL);
        TextView l = new TextView(this);
        l.setText(label);
        l.setTextSize(18f);
        l.setTextColor(getResources().getColor(R.color.text));
        left.addView(l);
        if (desc != null && !desc.isEmpty()) {
            TextView d = new TextView(this);
            d.setText(desc);
            d.setTextSize(13f);
            d.setTextColor(getResources().getColor(R.color.text_sub));
            left.addView(d);
        }
        r.addView(left, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f));
        LinearLayout col = new LinearLayout(this);
        col.setOrientation(LinearLayout.HORIZONTAL);
        col.setGravity(Gravity.END | Gravity.CENTER_VERTICAL);
        r.addView(col, new LinearLayout.LayoutParams(dp(CONTROL_COL_DP), LinearLayout.LayoutParams.WRAP_CONTENT));
        card.addView(r);
        return col; // the fixed-width control column: add the control into this
    }

    /** Info line spanning the row in grey; returns the TextView so dynamic rows can update it. */
    private TextView addInfo(LinearLayout card, String text) {
        addDivider(card);
        TextView t = new TextView(this);
        t.setText(text);
        t.setTextSize(13f);
        t.setTextColor(getResources().getColor(R.color.text_sub));
        t.setPadding(dp(12), dp(8), dp(12), dp(8));
        card.addView(t);
        return t;
    }

    // ---------------- controls ----------------

    /** Slider switch writing a fresh value; two-value settings that are really on/off use this. */
    private void addSwitchRow(LinearLayout card, String label, String desc, String key, String def,
                              String offValue, String onValue) {
        LinearLayout col = row(card, label, desc);
        final Switch sw = new Switch(this);
        sw.setChecked(store.getString(key, def).equals(onValue)); // state from the store, listener off
        sw.setOnCheckedChangeListener((b, checked) -> {
            store.put(key, checked ? onValue : offValue); // fresh write, never a captured copy
            if (SettingsKeys.KEY_THEME_ON_LIGHTS.equals(key)) reapplyTheme();
        });
        col.addView(sw);
    }

    /** Slider switch for a plain boolean setting. */
    private void addBoolSwitchRow(LinearLayout card, String label, String desc, String key, boolean def) {
        LinearLayout col = row(card, label, desc);
        final Switch sw = new Switch(this);
        sw.setChecked(store.getBool(key, def)); // fresh from the store
        sw.setOnCheckedChangeListener((b, checked) -> store.put(key, checked));
        col.addView(sw);
    }

    /**
     * Valet master (S27a): write, exit when turned off while active, refresh the warning, then
     * re-read the REAL state into the switch with the listener removed (no re-trigger loop).
     */
    private void addValetMasterRow(LinearLayout card) {
        LinearLayout col = row(card, "Valet mode enabled (master)",
            "entry is refused unless an exit path exists: PIN or trusted phone (S26a)");
        final Switch sw = new Switch(this);
        sw.setChecked(store.valetEnabled());
        // Anonymous class, not a lambda: the listener re-installs itself (`this`), which a lambda cannot reference.
        final CompoundButton.OnCheckedChangeListener l = new CompoundButton.OnCheckedChangeListener() {
            @Override public void onCheckedChanged(CompoundButton b, boolean on) {
                store.put(SettingsKeys.KEY_VALET_ENABLED, on);
                if (!on && App.valet().isActive()) App.valet().exit(); // master off while active exits (S27a)
                updateWarn();
                resyncSwitch(sw, this, store.valetEnabled());
            }
        };
        sw.setOnCheckedChangeListener(l);
        col.addView(sw);
    }

    /** Valet manual toggle (S25): enter/exit, then resync the switch to the real state. */
    private void addValetActiveRow(LinearLayout card) {
        LinearLayout col = row(card, "Valet mode active (manual toggle)",
            "suspends everything outside the allowed set");
        final Switch sw = new Switch(this);
        sw.setChecked(App.valet().isActive());
        final CompoundButton.OnCheckedChangeListener l = new CompoundButton.OnCheckedChangeListener() {
            @Override public void onCheckedChanged(CompoundButton b, boolean on) {
                if (on) App.valet().enter(); else App.valet().exit();
                updateWarn();
                resyncSwitch(sw, this, App.valet().isActive());
            }
        };
        sw.setOnCheckedChangeListener(l);
        col.addView(sw);
    }

    /** Set the switch to the real state without re-triggering the listener (owner Round 6 rule). */
    private static void resyncSwitch(Switch sw, CompoundButton.OnCheckedChangeListener l, boolean real) {
        if (sw.isChecked() == real) return; // side effect left the state as the user set it
        sw.setOnCheckedChangeListener(null);
        sw.setChecked(real);
        sw.setOnCheckedChangeListener(l);
    }

    /** Segmented pill selector: selected pill filled with accent, tap writes fresh + re-renders. */
    private void addStringSegmentRow(LinearLayout card, String label, String desc, String key, String def,
                                     String[] values, String[] labels, boolean reapply) {
        LinearLayout col = row(card, label, desc);
        final TextView[] pills = new TextView[values.length];
        for (int i = 0; i < values.length; i++) {
            final int idx = i;
            pills[i] = makePill(labels[i]);
            pills[i].setOnClickListener(v -> {
                store.put(key, values[idx]); // fresh write
                paintPills(pills, values, store.getString(key, def)); // re-render from the store
                if (reapply) reapplyTheme(); // dark mode takes effect immediately (spec S30)
            });
            col.addView(pills[i], pillParams(i));
        }
        paintPills(pills, values, store.getString(key, def));
    }

    /** Same for int-valued settings (Bluetooth dialler tab); current read fresh via the clamped store getter. */
    private void addIntSegmentRow(LinearLayout card, String label, String desc, String key, int def,
                                  int[] values, String[] labels) {
        LinearLayout col = row(card, label, desc);
        final TextView[] pills = new TextView[values.length];
        for (int i = 0; i < values.length; i++) {
            final int idx = i;
            pills[i] = makePill(labels[i]);
            pills[i].setOnClickListener(v -> {
                store.put(key, values[idx]);
                paintPills(pills, labels, store.btDialTab());
            });
            col.addView(pills[i], pillParams(i));
        }
        paintPills(pills, labels, store.btDialTab());
    }

    private TextView makePill(String label) {
        TextView t = new TextView(this);
        t.setText(label);
        t.setTextSize(14f);
        t.setGravity(Gravity.CENTER);
        t.setPadding(dp(10), dp(6), dp(10), dp(6));
        t.setClickable(true);
        return t;
    }

    private LinearLayout.LayoutParams pillParams(int i) {
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        if (i > 0) lp.leftMargin = dp(6);
        return lp;
    }

    /** Selected pill: accent fill + bg text; unselected: transparent fill + thin text_sub outline. */
    private void paintPills(TextView[] pills, String[] labelsToShow, int selectedIndex) {
        for (int i = 0; i < pills.length; i++) paintPill(pills[i], i == selectedIndex);
    }

    private void paintPills(TextView[] pills, String[] values, String current) {
        int sel = SettingsCycle.indexOf(values, current); // -1 = nothing selected (garbage pref)
        for (int i = 0; i < pills.length; i++) paintPill(pills[i], i == sel);
    }

    private void paintPill(TextView pill, boolean selected) {
        GradientDrawable d = new GradientDrawable();
        d.setShape(GradientDrawable.RECTANGLE);
        d.setCornerRadius(dp(16f));
        if (selected) {
            d.setColor(getResources().getColor(R.color.accent));
            pill.setTextColor(getResources().getColor(R.color.bg));
        } else {
            d.setColor(android.graphics.Color.TRANSPARENT);
            d.setStroke(strokePx(), getResources().getColor(R.color.text_sub));
            pill.setTextColor(getResources().getColor(R.color.text));
        }
        pill.setBackground(d);
    }

    /** Percent band as a SeekBar that snaps to the allowed values; value shown right, saved on release. */
    private void addPercentRow(LinearLayout card, String label, String key, int def, final int[] values) {
        LinearLayout col = row(card, label, null);
        final SeekBar bar = new SeekBar(this);
        final TextView value = new TextView(this);
        bar.setMax(values.length - 1);
        bar.setProgress(SettingsCycle.nearest(values, store.getInt(key, def))); // fresh, garbage-safe
        value.setText(values[bar.getProgress()] + " %");
        value.setTextSize(16f);
        value.setTextColor(getResources().getColor(R.color.text));
        value.setGravity(Gravity.END);
        bar.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            @Override public void onProgressChanged(SeekBar s, int progress, boolean fromUser) {
                if (fromUser) value.setText(values[progress] + " %"); // live snapped label
            }
            @Override public void onStartTrackingTouch(SeekBar s) { }
            @Override public void onStopTrackingTouch(SeekBar s) {
                store.put(key, values[s.getProgress()]); // saved on release, never mid-drag
            }
        });
        col.addView(bar, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f));
        LinearLayout.LayoutParams vp = new LinearLayout.LayoutParams(dp(56),
            LinearLayout.LayoutParams.WRAP_CONTENT);
        vp.leftMargin = dp(6);
        col.addView(value, vp);
    }

    // ---------------- styled number fields ----------------

    private GradientDrawable fieldDrawable() {
        GradientDrawable d = new GradientDrawable();
        d.setShape(GradientDrawable.RECTANGLE);
        d.setCornerRadius(dp(8f));           // rounded outline box (owner Round 6)
        d.setColor(getResources().getColor(R.color.field_bg));
        d.setStroke(strokePx(), getResources().getColor(R.color.text_sub)); // 1.5 dp outline
        return d;
    }

    /** Outline turns accent on focus, text_sub off focus. */
    private void paintField(EditText f, boolean focused) {
        android.graphics.drawable.Drawable bg = f.getBackground();
        if (bg instanceof GradientDrawable) {
            ((GradientDrawable) bg).setStroke(strokePx(), focused
                ? getResources().getColor(R.color.accent)
                : getResources().getColor(R.color.text_sub));
        }
    }

    private EditText makeNumberField(int widthDp, int maxDigits) {
        EditText e = new EditText(this);
        e.setTextSize(23f);                   // large monospaced digits, centred (owner Round 6)
        e.setTypeface(Typeface.MONOSPACE);
        e.setGravity(Gravity.CENTER);
        e.setImeOptions(EditorInfo.IME_ACTION_DONE);
        e.setFilters(new android.text.InputFilter[] { new android.text.InputFilter.LengthFilter(maxDigits) });
        e.setBackground(fieldDrawable());
        return e;
    }

    /** Valet timeout, editable (was display-only): existing key, owner default unchanged. */
    private void addTimeoutRow(LinearLayout card) {
        LinearLayout col = row(card, "Valet timeout", "seconds before auto-entry when no trusted phone connects (10..3600)");
        timeoutField = makeNumberField(120, SettingsValidation.TIMEOUT_MAX_DIGITS);
        timeoutField.setText(String.valueOf(store.valetTimeoutS()));
        timeoutField.setInputType(android.text.InputType.TYPE_CLASS_NUMBER);
        timeoutField.setOnFocusChangeListener((v, has) -> {
            paintField(timeoutField, has);
            if (!has) saveTimeout(); // save on focus loss
        });
        timeoutField.setOnEditorActionListener((v, actionId, event) -> {
            if (actionId == EditorInfo.IME_ACTION_DONE) { saveTimeout(); return true; } // save on Done
            return false;
        });
        col.addView(timeoutField, new LinearLayout.LayoutParams(dp(120), dp(44)));
        TextView unit = new TextView(this);
        unit.setText(" s");
        unit.setTextSize(16f);
        unit.setTextColor(getResources().getColor(R.color.text_sub));
        col.addView(unit);
        timeoutStatus = makeStatus();
        col.addView(timeoutStatus);
    }

    /** Valet PIN: password-number keyboard, max 6 digits, accent-on-focus, Done/blur saves. */
    private void addPinRow(LinearLayout card) {
        LinearLayout col = row(card, "Valet PIN", "4-6 digits; used to exit valet mode (S26)");
        pinField = makeNumberField(160, SettingsValidation.PIN_MAX_DIGITS);
        pinField.setHint("valet PIN");
        pinField.setInputType(android.text.InputType.TYPE_CLASS_NUMBER
            | android.text.InputType.TYPE_NUMBER_VARIATION_PASSWORD);
        pinField.setOnFocusChangeListener((v, has) -> {
            paintField(pinField, has);
            if (!has) savePin();
        });
        pinField.setOnEditorActionListener((v, actionId, event) -> {
            if (actionId == EditorInfo.IME_ACTION_DONE) { savePin(); return true; }
            return false;
        });
        col.addView(pinField, new LinearLayout.LayoutParams(dp(160), dp(44)));
        pinStatus = makeStatus();
        col.addView(pinStatus);
    }

    private TextView makeStatus() {
        TextView t = new TextView(this); // inline "Saved"/error, right of the field
        t.setTextSize(13f);
        t.setVisibility(View.GONE);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        lp.leftMargin = dp(6);
        // width capped so a long error message cannot push the fixed column off-screen
        t.setMaxWidth(dp(120));
        t.setLayoutParams(lp);
        return t;
    }

    private void savePin() {
        String p = pinField.getText().toString();
        if (SettingsValidation.validPin(p)) {
            store.setValetPin(p);
            showStatus(pinStatus, "Saved", R.color.gauge_ok);
            updateWarn();
        } else {
            showStatus(pinStatus, "PIN: 4-6 digits", R.color.gauge_bad);
        }
    }

    private void saveTimeout() {
        Integer v = SettingsValidation.parseTimeout(timeoutField.getText().toString());
        if (v != null && SettingsValidation.timeoutOk(v.intValue())) {
            store.put(SettingsKeys.KEY_VALET_TIMEOUT_S, v.intValue());
            showStatus(timeoutStatus, "Saved", R.color.gauge_ok);
        } else {
            showStatus(timeoutStatus, "Timeout 10..3600 s", R.color.gauge_bad);
        }
    }

    /** Green "Saved" or red inline error; both fade away after STATUS_FADE_MS. */
    private void showStatus(TextView status, String msg, int colorRes) {
        status.setText(msg);
        status.setTextColor(getResources().getColor(colorRes));
        status.setVisibility(View.VISIBLE);
        main.removeCallbacks(statusFade);
        main.postDelayed(statusFade, STATUS_FADE_MS);
    }

    private final Runnable statusFade = new Runnable() {
        @Override public void run() {
            if (pinStatus != null) { pinStatus.setText(""); pinStatus.setVisibility(View.GONE); }
            if (timeoutStatus != null) { timeoutStatus.setText(""); timeoutStatus.setVisibility(View.GONE); }
        }
    };

    @Override
    protected void onDestroy() {
        super.onDestroy();
        main.removeCallbacks(statusFade); // never fade into a dead screen
    }

    /** Dark-mode changes take effect immediately (spec S30). */
    void reapplyTheme() {
        long now = System.currentTimeMillis();
        int tz = TimeZone.getDefault().getOffset(now) / 3600_000;
        boolean night = ThemePolicy.night(store.darkMode(), App.car().booleanState("headlight"),
            DayNight.isNight(store.radarLat(), store.radarLon(), now, tz), store.themeOnLights());
        App.theme().apply(night);
    }
}
