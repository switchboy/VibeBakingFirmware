package org.vibebaking.launcher;

import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.res.Configuration;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.widget.ImageView;
import android.widget.TextView;

import org.vibebaking.launcher.logic.BatteryState;
import org.vibebaking.launcher.logic.CarEventParser;
import org.vibebaking.launcher.logic.ClockFormat;
import org.vibebaking.launcher.logic.DayNight;
import org.vibebaking.launcher.logic.FavoritePolicy;
import org.vibebaking.launcher.logic.ThemePolicy;
import org.vibebaking.launcher.logic.ValetPolicy;

import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.TimeZone;

/** The home screen (spec S1-S5, S18-S20, S27, S32, S38). */
public class LauncherActivity extends Activity {

    private final Handler main = new Handler(Looper.getMainLooper());
    private SettingsStore store;
    private ThemeApplier theme;
    private CarClient car;
    private ValetController valet;
    private AudioAttenuator audio;
    private MapCardController map;
    private MediaCardController media;
    private RadarView radar;
    private TextView clock, date, battery, badge, settingsButton;
    private View root;
    private View[] favSlots;
    private ImageView[] favIcons;
    private TextView[] favGlyphs, favLabels;
    private List<String> favShown = FavoritePolicy.defaults(); // what the bar renders right now

    private boolean headlightOn;
    private Double brightnessBeforeLights; // captured once per lights-on spell (spec S28)
    private int batteryRaw = 0;            // 0 = no event yet -> chip hidden (spec S19)
    private long lastThemeSwitch = 0L;
    private String lastMapTarget;          // applied map card target (spec S7)

    @Override
    protected void onCreate(android.os.Bundle saved) {
        super.onCreate(saved);
        setContentView(R.layout.home_activity);
        root = findViewById(R.id.home_root);
        clock = findViewById(R.id.clock);
        date = findViewById(R.id.clock_date);
        battery = findViewById(R.id.battery);
        badge = findViewById(R.id.valet_badge);
        settingsButton = findViewById(R.id.btn_settings);
        findViewById(R.id.btn_settings).setOnClickListener(v ->
            startActivity(new Intent(this, CarSettingsActivity.class)));
        findViewById(R.id.btn_apps).setOnClickListener(v ->
            startActivity(new Intent(this, AppDrawerActivity.class)));
        badge.setOnClickListener(v -> startActivity(new Intent(this, ValetPinActivity.class)));

        // Bottom favourite row (spec S40): slot 0 ships preinstalled with the HCT dialler.
        favSlots = new View[] { findViewById(R.id.fav_slot0), findViewById(R.id.fav_slot1),
            findViewById(R.id.fav_slot2), findViewById(R.id.fav_slot3) };
        favIcons = new ImageView[] { findViewById(R.id.fav_icon0), findViewById(R.id.fav_icon1),
            findViewById(R.id.fav_icon2), findViewById(R.id.fav_icon3) };
        favGlyphs = new TextView[] { findViewById(R.id.fav_glyph0), findViewById(R.id.fav_glyph1),
            findViewById(R.id.fav_glyph2), findViewById(R.id.fav_glyph3) };
        favLabels = new TextView[] { findViewById(R.id.fav_label0), findViewById(R.id.fav_label1),
            findViewById(R.id.fav_label2), findViewById(R.id.fav_label3) };
        for (int i = 0; i < FavoritePolicy.MAX_SLOTS; i++) {
            final int idx = i;
            favSlots[idx].setOnClickListener(v -> launchFavorite(favShown.get(idx), idx));
            // Long-press empties a slot (owner un-pins); disabled in valet so the row stays fixed.
            favSlots[idx].setOnLongClickListener(v -> { clearFavorite(idx); return true; });
        }

        store = App.store();
        theme = App.theme();
        car = App.car();
        valet = App.valet();
        audio = new AudioAttenuator(this, car, store);
        refreshFavorites(); // needs store + valet (first on-device run: NPE when called before them)

        valet.replayPending();        // crash-safe re-apply (spec S22)
        valet.scheduleAutoEnter();    // spec S25 - HCT BT probe decides; UNKNOWN never auto-enters

        map = new MapCardController(this, findViewById(R.id.map_card));
        map.init(store.mapTarget());
        valet.setNavTarget(map.navTarget()); // valet allowed set follows the map card (S21)
        lastMapTarget = store.mapTarget();
        if (valet.isActive()) valet.refreshSuspension(); // replay ran before the target was known

        media = new MediaCardController(this, findViewById(R.id.media_card), store, car, theme);
        MediaListenerService.callback = () -> main.post(media::refresh);
        media.refresh(); // shows "no access" until the owner grants the listener (spec S14)

        radar = findViewById(R.id.radar_view);
        radar.setLatLon(store.radarLat(), store.radarLon());
        radar.setNight(theme.systemNight());
        TextView attribution = findViewById(R.id.radar_attribution);
        radar.setSink((text, frame) -> attribution.setText(text));
        radar.load();

        // Car signals (spec S28-S31, S19): initial state + event stream. Attached last: the listener and
        // applyTheme() use the map/media/radar cards (first on-device run: NPE on radar when this ran first).
        headlightOn = car.booleanState("headlight");
        car.attach(carListener);
        applyTheme();
        applyBacklight();

        main.postDelayed(tick, ClockFormat.TICK_MS);
    }

    private final CarClient.Listener carListener = new CarClient.Listener() {
        @Override public void onCarAvailable(boolean available) { }

        @Override public void onCarEvent(CarEventParser.CarEvent e) {
            switch (e.kind) {
                case HEADLIGHT_ON:  headlightOn = true;  applyTheme(); applyBacklight(); break;
                case HEADLIGHT_OFF: headlightOn = false; applyTheme(); applyBacklight(); break;
                case BACKVIEW_START: audio.onReverseStart(); break;   // spec S31
                case BACKVIEW_STOP:  audio.onReverseStop(); break;
                case BATTERY:        batteryRaw = e.intValue; updateBattery(); break; // spec S19
                case ACC_OFF:
                case SLEEP:          audio.onAccOff(); break; // lost BACKVIEW_STOP: restore volume (S31)
                default: break; // KEY handled by framework paths; screen off anyway
            }
        }
    };

    private final Runnable tick = new Runnable() {
        @Override public void run() {
            long now = System.currentTimeMillis();
            int tz = TimeZone.getDefault().getOffset(now) / 3600_000;
            clock.setText(ClockFormat.time(now, tz));
            date.setText(ClockFormat.date(now, tz));
            applyTheme();            // cycle mode re-evaluates night each minute (spec S30)
            updateBattery();
            media.refresh();         // session changes without a push event are picked up here
            main.postDelayed(this, ClockFormat.TICK_MS);
        }
    };

    /** Night decision + animated transition guard (spec S30/S32/S38). */
    void applyTheme() {
        long now = System.currentTimeMillis();
        int tz = TimeZone.getDefault().getOffset(now) / 3600_000;
        boolean night = ThemePolicy.night(store.darkMode(), headlightOn,
            DayNight.isNight(store.radarLat(), store.radarLon(), now, tz), store.themeOnLights());
        boolean wasNight = theme.systemNight();
        theme.apply(night);
        if (radar != null) radar.setNight(theme.systemNight());
        if (wasNight != theme.systemNight() && now - lastThemeSwitch > 600L) {
            lastThemeSwitch = now;
            animateThemeSwap(); // spec S32: animated, not abrupt
        }
    }

    void animateThemeSwap() {
        root.setAlpha(0f);
        root.animate().alpha(1f).setDuration(300).start();
    }

    void applyBacklight() {
        Double target = org.vibebaking.launcher.logic.BacklightPolicy.dimFraction(
            store.backlightMode(), store.backlightPercent(), headlightOn);
        if (target != null) {
            if (brightnessBeforeLights == null) brightnessBeforeLights = theme.captureBrightness();
            theme.applyBacklight(target, null);
        } else if (brightnessBeforeLights != null) {
            theme.applyBacklight(null, brightnessBeforeLights);
            brightnessBeforeLights = null;
        }
    }

    void updateBattery() {
        if (!BatteryState.known(batteryRaw)) { battery.setVisibility(View.GONE); return; }
        battery.setVisibility(View.VISIBLE);
        battery.setText(BatteryState.label(batteryRaw));
        battery.setTextColor(getResources().getColor(
            BatteryState.low(batteryRaw, BatteryState.DEFAULT_LOW_THRESHOLD_V)
                ? R.color.battery_low : R.color.battery_ok));
    }

    @Override
    public void onConfigurationChanged(Configuration newConfig) {
        super.onConfigurationChanged(newConfig);
        // uiMode is handled here (configChanges in the manifest) so the theme switch animates
        // instead of recreating the activity (spec S38).
        if (radar != null) radar.setNight(theme.systemNight());
        animateThemeSwap();
    }

    @Override
    protected void onResume() {
        super.onResume();
        boolean valetOn = valet.isActive() && store.valetEnabled();
        badge.setVisibility(valetOn ? View.VISIBLE : View.GONE);
        // In valet mode Settings is suspended anyway: hide the gear so the screen stays clean.
        settingsButton.setVisibility(valetOn ? View.GONE : View.VISIBLE);
        // Map target may have changed in settings while the home screen was in the background.
        if (map != null && !java.util.Objects.equals(lastMapTarget, store.mapTarget())) {
            map.init(store.mapTarget());
            valet.setNavTarget(map.navTarget()); // keep the chosen nav app allowed in valet (S21)
            lastMapTarget = store.mapTarget();
        }
        media.refresh();
        if (radar != null) radar.restart(); // one refresh timer per visible activity (S18')
        refreshFavorites(); // installs/uninstalls and valet state may have changed (S40)
    }

    /**
     * Rebuild the favourite row (spec S40/S40b). Every PackageManager call is guarded: a package
     * that vanished since the pref was written, or an app without an icon, degrades to the glyph.
     */
    void refreshFavorites() {
        boolean valetOn = valet.isActive() && store.valetEnabled();
        Set<String> allowed = valetOn ? ValetPolicy.allowedSet(valet.allowedExtras()) : null;
        PackageManager pm = getPackageManager();
        Set<String> launchable = new HashSet<>();
        for (String pkg : store.favSlots()) {
            if (pkg.isEmpty()) continue;
            try { if (pm.getLaunchIntentForPackage(pkg) != null) launchable.add(pkg); }
            catch (Throwable t) { /* package gone or PM error: treat as not launchable */ }
        }
        favShown = FavoritePolicy.visible(store.favSlots(), valetOn, allowed, launchable);
        for (int i = 0; i < FavoritePolicy.MAX_SLOTS; i++) {
            String pkg = favShown.get(i);
            if (pkg.isEmpty()) {
                favIcons[i].setVisibility(View.GONE);
                favLabels[i].setVisibility(View.GONE);
                favGlyphs[i].setVisibility(View.VISIBLE);
                favGlyphs[i].setText(FavoritePolicy.glyph("")); // "+" -> tap opens the drawer
                continue;
            }
            favGlyphs[i].setVisibility(View.GONE);
            favLabels[i].setVisibility(View.VISIBLE);
            favIcons[i].setVisibility(View.VISIBLE);
            try {
                favIcons[i].setImageDrawable(pm.getApplicationIcon(pm.getApplicationInfo(pkg, 0)));
                favLabels[i].setText(pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString());
            } catch (Throwable t) {
                // Icon/label unreadable (app gone since enumerate): fall back to the glyph.
                favIcons[i].setImageResource(R.drawable.ic_app_placeholder);
                favLabels[i].setText(pkg);
            }
        }
    }

    /** Tap a slot: launch it; the phone slot opens the BT app on its dialler tab (spec S40a). */
    void launchFavorite(String pkg, int slot) {
        if (pkg.isEmpty()) { startActivity(new Intent(this, AppDrawerActivity.class)); return; }
        try {
            Intent i = getPackageManager().getLaunchIntentForPackage(pkg);
            if (i == null) { // uninstalled since pinning: drop the slot instead of doing nothing
                store.setFavSlots(FavoritePolicy.clear(store.favSlots(), slot));
                refreshFavorites();
                return;
            }
            if (FavoritePolicy.isPhoneSlot(pkg)) i.putExtra(FavoritePolicy.BT_TAB_EXTRA, store.btDialTab());
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            startActivity(i);
        } catch (Throwable t) {
            android.util.Log.w("LauncherActivity", "favourite launch failed for " + pkg, t);
        }
    }

    /** Long-press a slot: empty it (owner un-pins). No-op in valet - the row must stay fixed. */
    void clearFavorite(int slot) {
        if (valet.isActive() && store.valetEnabled()) return;
        store.setFavSlots(FavoritePolicy.clear(store.favSlots(), slot));
        refreshFavorites();
        try {
            android.widget.Toast.makeText(this, R.string.fav_cleared, android.widget.Toast.LENGTH_SHORT).show();
        } catch (Throwable t) { /* toast is cosmetic: never fail the un-pin because of it */ }
    }

    @Override
    public void onPause() {
        super.onPause();
        // The home screen stays as-is; valet state is owned by ValetController + persisted prefs.
        // The trusted-phone exit watch (S26) is NOT stopped here: while valet is active the owner
        // may be sitting in the app drawer or settings, and the phone must still end valet.
        if (radar != null) radar.stop();
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        MediaListenerService.callback = null;
        if (radar != null) radar.stop();
        if (map != null) map.release();
    }
}
