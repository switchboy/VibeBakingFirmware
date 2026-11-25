package org.vibebaking.launcher;

import android.app.Activity;
import android.content.Intent;
import android.content.res.Configuration;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.widget.TextView;

import org.vibebaking.launcher.logic.BatteryState;
import org.vibebaking.launcher.logic.CarEventParser;
import org.vibebaking.launcher.logic.ClockFormat;
import org.vibebaking.launcher.logic.DayNight;
import org.vibebaking.launcher.logic.ThemePolicy;

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
    private TextView clock, date, battery, badge;
    private View root;

    private boolean headlightOn;
    private Double brightnessBeforeLights; // captured once per lights-on spell (spec S28)
    private int batteryRaw = 0;            // 0 = no event yet -> chip hidden (spec S19)
    private long lastThemeSwitch = 0L;

    @Override
    protected void onCreate(android.os.Bundle saved) {
        super.onCreate(saved);
        setContentView(R.layout.home_activity);
        root = findViewById(R.id.home_root);
        clock = findViewById(R.id.clock);
        date = findViewById(R.id.clock_date);
        battery = findViewById(R.id.battery);
        badge = findViewById(R.id.valet_badge);
        findViewById(R.id.btn_settings).setOnClickListener(v ->
            startActivity(new Intent(this, CarSettingsActivity.class)));
        badge.setOnClickListener(v -> startActivity(new Intent(this, ValetPinActivity.class)));

        store = App.store();
        theme = App.theme();
        car = App.car();
        valet = App.valet();
        audio = new AudioAttenuator(this, car, store);

        valet.replayPending();        // crash-safe re-apply (spec S22)
        valet.scheduleAutoEnter();    // spec S25 (probe returns UNKNOWN while BT is dead)

        // Car signals (spec S28-S31, S19): initial state + event stream.
        headlightOn = car.booleanState("headlight");
        car.attach(carListener);
        applyTheme();
        applyBacklight();

        map = new MapCardController(this, findViewById(R.id.map_card));
        map.init(store.mapTarget());

        media = new MediaCardController(this, findViewById(R.id.media_card), store, car, theme);
        MediaListenerService.callback = () -> main.post(media::refresh);
        media.refresh(); // shows "no access" until the owner grants the listener (spec S14)

        radar = findViewById(R.id.radar_view);
        radar.setLatLon(store.radarLat(), store.radarLon());
        radar.setNight(theme.systemNight());
        TextView attribution = findViewById(R.id.radar_attribution);
        radar.setSink((text, frame) -> attribution.setText(text));
        radar.load();

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
        radar.setNight(theme.systemNight());
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
        radar.setNight(theme.systemNight());
        animateThemeSwap();
    }

    @Override
    protected void onResume() {
        super.onResume();
        badge.setVisibility(valet.isActive() && store.valetEnabled() ? View.VISIBLE : View.GONE);
        media.refresh();
        if (radar != null) radar.restart(); // one refresh timer per visible activity (S18')
    }

    @Override
    public void onPause() {
        super.onPause();
        // The home screen stays as-is; valet state is owned by ValetController + persisted prefs.
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
