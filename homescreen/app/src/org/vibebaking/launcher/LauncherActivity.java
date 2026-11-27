package org.vibebaking.launcher;

import android.app.Activity;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.content.res.ColorStateList;
import android.content.res.Configuration;
import android.graphics.drawable.Drawable;
import android.location.Location;
import android.location.LocationListener;
import android.location.LocationManager;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.widget.ImageView;
import android.widget.TextView;

import org.vibebaking.launcher.logic.BatteryState;
import org.vibebaking.launcher.logic.CarEventParser;
import org.vibebaking.launcher.logic.ClockFormat;
import org.vibebaking.launcher.logic.DayNight;
import org.vibebaking.launcher.logic.EngineGauges;
import org.vibebaking.launcher.logic.FavoritePolicy;
import org.vibebaking.launcher.logic.RadarPosition;
import org.vibebaking.launcher.logic.SettingsKeys;
import org.vibebaking.launcher.logic.ThemePolicy;
import org.vibebaking.launcher.logic.ValetPolicy;
import org.vibebaking.launcher.logic.WeatherFetcher;
import org.vibebaking.launcher.logic.WeatherIcon;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
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
    private TextView clock, date, battery, badge, settingsButton, engineTemp, engineRpm;
    private ImageView weatherIcon;
    private TextView weatherTemp;
    private View root;
    private View[] favSlots;
    private ImageView[] favIcons;
    private TextView[] favGlyphs, favLabels;
    private List<String> favShown = FavoritePolicy.defaults(); // what the bar renders right now

    private boolean headlightOn;
    private Double brightnessBeforeLights; // captured once per lights-on spell (spec S28)
    private int batteryRaw = 0;            // 0 = no event yet -> chip hidden (spec S19)
    // Engine gauges (owner 2026-11-27): RPM arrives on the HCTCanBus broadcast
    // com.microntek.canbus.rpm (String extra "rpm", decimal, sent via sendBroadcastAsUser).
    // If no usable frame arrives for RPM_STALE_MS the gauge hides again (ignition off / a
    // protocol without RPM). Temperature has no broadcast source yet - see onEngineTemp().
    private static final String RPM_ACTION = "com.microntek.canbus.rpm";
    private static final String RPM_EXTRA = "rpm";
    private static final long RPM_STALE_MS = 10_000L;
    // "Engine off" only once this protocol has proven it sends RPM (owner 2026-11-27): a protocol without RPM must
    // not show "Engine off" while driving, so before the first frame the gauge stays hidden.
    private boolean rpmSeen;
    // Bench test hook: adb shell am broadcast -a org.vibebaking.launcher.TEST_ENGINE_TEMP --ei celsius 100 --ez oil true
    // Only senders holding android.permission.DUMP (the adb shell) are delivered; apps cannot fake engine data.
    private static final String TEST_TEMP_ACTION = "org.vibebaking.launcher.TEST_ENGINE_TEMP";
    // Bench test hook (DUMP-protected like the one above): centre the radar on a rainy spot for 5 minutes to check it
    // draws rain. adb shell am broadcast -a org.vibebaking.launcher.TEST_RADAR_CENTER --ef lat 41.9 --ef lon 12.5
    private static final String TEST_RADAR_ACTION = "org.vibebaking.launcher.TEST_RADAR_CENTER";
    private static final long RADAR_TEST_MS = 5 * 60_000L;
    private long radarTestUntil;
    // Outside temperature + weather icon (owner request 2026-11-27). Two sources: Open-Meteo's
    // `current` block (weather code + is_day -> icon, temperature_2m) and HCTCanBus's
    // com.canbus.temperature (String extra "temperature", the outside air temp). A car frame
    // younger than WeatherIcon.CAR_TEMP_FRESH_MS wins for the number; the icon always comes from
    // Open-Meteo. Privacy: only rounded (~10 km) coordinates go in the URL, nothing is stored or logged.
    private static final String CAN_TEMP_ACTION = "com.canbus.temperature";
    private static final String CAN_TEMP_EXTRA = "temperature";
    private final WeatherFetcher weatherHttp = new HttpWeatherFetcher();
    private boolean weatherPending;          // one in-flight fetch at a time (no stacked threads)
    private long lastWeatherAttempt;         // 0 = never; a failed attempt only retries after REFRESH_MS
    private WeatherIcon.Icon weatherKind;    // null until the first Open-Meteo reading
    private Double openMeteoTemp;            // last temperature_2m from Open-Meteo
    private Double carTemp;                  // last com.canbus.temperature value
    private long carTempAt;                  // wall clock of that frame
    private boolean homeVisible;             // refresh only while the home screen is on screen
    // Gauge glyphs are tinted with their value's colour; the resource id is kept so the tint can be
    // re-resolved when the day/night qualifier swaps (onConfigurationChanged, spec S38).
    private int batteryColorRes = R.color.gauge_ok;
    private int engineTempColorRes = R.color.gauge_ok;
    // Gauge icons (owner 2026-11-27): 20dp glyph left of the value, 4dp gap, tinted like the value.
    private static final float GAUGE_ICON_DP = 20f;
    private static final float GAUGE_ICON_PADDING_DP = 4f;
    private long lastThemeSwitch = 0L;
    private String lastMapTarget;          // applied map card target (spec S7)
    private LocationManager locationManager;
    private RadarPosition.Fix liveFix;     // newest GPS listener fix — memory only, never stored (privacy)
    private double lastPosLat = Double.NaN, lastPosLon = Double.NaN; // radar centre currently on screen

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
        // Engine gauge row under the clock (owner 2026-11-27): temp and rpm start GONE; they
        // appear when a value arrives (onEngineTemp / the rpm broadcast).
        engineTemp = findViewById(R.id.engine_temp);
        engineRpm = findViewById(R.id.engine_rpm);
        // Weather beside the date (owner 2026-11-27): stays hidden until the first value arrives.
        weatherIcon = findViewById(R.id.weather_icon);
        weatherTemp = findViewById(R.id.weather_temp);
        weatherIcon.setVisibility(View.GONE);
        weatherTemp.setVisibility(View.GONE);
        // Gauge icons left of every value (owner 2026-11-27); the tint is re-applied whenever the
        // value's colour changes (updateBattery / onEngineTemp / the rpm paint path).
        setGaugeIcon(battery, R.drawable.ic_gauge_battery);
        tintGauge(battery, getResources().getColor(R.color.gauge_ok));
        setGaugeIcon(engineTemp, R.drawable.ic_gauge_coolant);
        tintGauge(engineTemp, getResources().getColor(R.color.gauge_ok));
        setGaugeIcon(engineRpm, R.drawable.ic_gauge_engine);
        tintGauge(engineRpm, getResources().getColor(R.color.text_sub));
        // The owner saw no clock on the first run: the tick fired a minute after start, so paint
        // the clock/date right away; the minute tick keeps them updated from then on (spec S5).
        long startedAt = System.currentTimeMillis();
        int startedTz = TimeZone.getDefault().getOffset(startedAt) / 3600_000;
        clock.setText(ClockFormat.time(startedAt, startedTz));
        date.setText(ClockFormat.date(startedAt, startedTz));
        findViewById(R.id.btn_settings).setOnClickListener(v ->
            startActivity(new Intent(this, CarSettingsActivity.class)));
        findViewById(R.id.btn_apps).setOnClickListener(v ->
            startActivity(new Intent(this, AppDrawerActivity.class)));
        badge.setOnClickListener(v -> startActivity(new Intent(this, ValetPinActivity.class)));
        // Favourite row is an overlay (owner 2026-11-25): the four-dot button in the bottom strip opens/closes it.
        favBar = findViewById(R.id.favorites_bar);
        findViewById(R.id.fav_handle).setOnClickListener(v -> toggleFavorites());

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

        MapCardController kept = App.mapCard();
        if (kept != null && kept.hasDisplay() && java.util.Objects.equals(kept.setting(), store.mapTarget())) {
            map = kept;                                   // theme rebuild: the nav app keeps running on its display
            map.reattach(this, findViewById(R.id.map_card));
        } else {
            if (kept != null) kept.release();
            map = new MapCardController(this, findViewById(R.id.map_card));
            map.init(store.mapTarget());
            App.setMapCard(map);
        }
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
        registerRpmReceiver(); // car signal attached last, per the first-run NPE lesson
        registerWeatherReceiver();

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
            // Owner 2026-11-27: the minute tick is the 15-minute weather clock (only while visible).
            if (homeVisible) refreshWeatherIfNeeded();
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
        repaintIconTints(); // gauge + weather glyphs follow the day/night palette
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
        // Round 5 policy (EngineGauges) instead of the old battery_ok/battery_low pair.
        // Round 7: the battery icon takes the same colour as the value.
        int colorRes = levelColorRes(EngineGauges.batteryLevel(BatteryState.volts(batteryRaw)));
        batteryColorRes = colorRes;
        battery.setTextColor(getResources().getColor(colorRes));
        tintGauge(battery, getResources().getColor(colorRes));
    }

    /**
     * EngineGauges.Level -> gauge_* colour as a resource id, so a value's text colour and its glyph
     * tint can be re-resolved after a day/night swap (the theme changes the qualifier, spec S30/S38).
     */
    private int levelColorRes(EngineGauges.Level level) {
        switch (level) {
            case COLD: return R.color.gauge_cold;
            case WARN: return R.color.gauge_warn;
            case BAD:  return R.color.gauge_bad;
            case OK:
            default:   return R.color.gauge_ok;
        }
    }

    /**
     * Engine temperature entry point (owner 2026-11-27), main thread: updates `engine_temp`.
     * No HCTCanBus protocol publishes coolant or oil temperature (com.canbus.temperature is
     * the outside air temp), so nothing calls this yet - the view + pure policy are ready for
     * the wiring round once the car's CAN box is known. Oil reads "88 °C oil", coolant "88 °C".
     */
    void onEngineTemp(int celsius, boolean isOil) {
        if (engineTemp == null) return;
        engineTemp.setText(isOil ? celsius + " °C oil" : celsius + " °C");
        int colorRes = levelColorRes(isOil ? EngineGauges.oilLevel(celsius) : EngineGauges.coolantLevel(celsius));
        engineTempColorRes = colorRes;
        engineTemp.setTextColor(getResources().getColor(colorRes));
        // Round 7 glyph: coolant vs oil outline, always tinted with the value's colour.
        setGaugeIcon(engineTemp, isOil ? R.drawable.ic_gauge_oil : R.drawable.ic_gauge_coolant);
        tintGauge(engineTemp, getResources().getColor(colorRes));
        engineTemp.setVisibility(View.VISIBLE);
    }

    /**
     * Icon tints follow the theme (owner 2026-11-27): uiMode is handled in onConfigurationChanged
     * (no recreation, spec S38), so every gauge glyph and the weather glyph are re-resolved after a
     * day/night swap. Idempotent - re-applying the same tint costs nothing.
     */
    private void repaintIconTints() {
        if (battery != null) tintGauge(battery, getResources().getColor(batteryColorRes));
        if (engineTemp != null) tintGauge(engineTemp, getResources().getColor(engineTempColorRes));
        if (engineRpm != null) tintGauge(engineRpm, getResources().getColor(R.color.text_sub));
        if (weatherIcon != null && weatherKind != null) {
            weatherIcon.setImageResource(weatherDrawable(weatherKind));
            weatherIcon.setImageTintList(ColorStateList.valueOf(
                getResources().getColor(weatherTint(weatherKind))));
        }
    }

    /**
     * Gauge glyph on the start side of a value (owner 2026-11-27). The owner named
     * `setCompoundDrawablesRelativeWithIntrinsicBounds`, but that draws these vectors at their
     * intrinsic 24dp while 20dp is asked for, so the bounds are set explicitly and the same
     * relative API without intrinsic sizing is used (both API 17, long-standing).
     */
    private void setGaugeIcon(TextView tv, int drawableRes) {
        float density = getResources().getDisplayMetrics().density;
        Drawable d = getResources().getDrawable(drawableRes);
        int px = Math.round(GAUGE_ICON_DP * density);
        d.setBounds(0, 0, px, px);
        tv.setCompoundDrawablesRelative(d, null, null, null);
        tv.setCompoundDrawablePadding(Math.round(GAUGE_ICON_PADDING_DP * density));
    }

    /** Icon tint = the value's colour (owner 2026-11-27): called whenever that colour changes. */
    private void tintGauge(TextView tv, int color) {
        tv.setCompoundDrawableTintList(ColorStateList.valueOf(color));
    }

    /**
     * Weather refresh decision (owner 2026-11-27): at most every WeatherIcon.REFRESH_MS while the
     * home screen is visible (the minute tick calls this), and immediately on resume when the last
     * attempt is older than that or never happened. One in-flight fetch at a time.
     */
    private void refreshWeatherIfNeeded() {
        if (weatherPending || weatherIcon == null) return;
        long now = System.currentTimeMillis();
        if (lastWeatherAttempt != 0L && now - lastWeatherAttempt < WeatherIcon.REFRESH_MS) return;
        lastWeatherAttempt = now;
        weatherPending = true;
        // urlFor() rounds lat/lon to 1 decimal (~10 km): the full position never leaves the unit,
        // and neither the URL nor the coordinates are ever logged or stored.
        final String url = WeatherIcon.urlFor(lastPosLat, lastPosLon);
        new Thread(() -> {
            WeatherIcon.Reading reading = null;
            try {
                byte[] body = weatherHttp.fetch(url);
                reading = WeatherIcon.parseCurrent(new String(body, StandardCharsets.UTF_8));
            } catch (Throwable offline) {
                // Offline / HTTP error / HTML page / truncated body: keep the last value (S36).
                // Deliberately not logged: the failure message could carry the position.
            }
            final WeatherIcon.Reading result = reading;
            main.post(() -> {
                weatherPending = false;
                if (result != null) applyWeather(result); // garbled body: previous values stay
            });
        }).start();
    }

    /** Main thread: remember the Open-Meteo reading and repaint. Missing fields leave the old value. */
    void applyWeather(WeatherIcon.Reading r) {
        if (r == null) return;
        if (r.tempC != null) openMeteoTemp = r.tempC;
        if (r.wmoCode != null) {
            // is_day missing: fall back to the theme's night decision rather than guessing.
            boolean day = r.day != null ? r.day.booleanValue() : !theme.systemNight();
            weatherKind = WeatherIcon.iconFor(r.wmoCode.intValue(), day);
        }
        showWeather();
    }

    /** The number to show: the car's own outside-air sensor beats Open-Meteo while it is fresh. */
    private Double preferredTemp() {
        if (carTemp != null && WeatherIcon.preferCarTemp(carTempAt, System.currentTimeMillis())) return carTemp;
        return openMeteoTemp;
    }

    /** Paint the icon + temperature; both stay GONE until the first value of either kind arrives. */
    private void showWeather() {
        if (weatherIcon == null || weatherTemp == null) return;
        Double temp = preferredTemp();
        String label = temp == null ? "" : WeatherIcon.formatTemp(temp.doubleValue());
        if (label.isEmpty()) {
            weatherTemp.setVisibility(View.GONE);
        } else {
            weatherTemp.setText(label);
            weatherTemp.setVisibility(View.VISIBLE);
        }
        if (weatherKind == null) { weatherIcon.setVisibility(View.GONE); return; }
        weatherIcon.setImageResource(weatherDrawable(weatherKind));
        weatherIcon.setImageTintList(ColorStateList.valueOf(getResources().getColor(weatherTint(weatherKind))));
        weatherIcon.setVisibility(View.VISIBLE);
    }

    /** WeatherIcon.Icon -> drawable resource (the logic layer returns names; ids are compile-checked). */
    private static int weatherDrawable(WeatherIcon.Icon icon) {
        switch (icon) {
            case SUN: return R.drawable.ic_wx_sun;
            case MOON: return R.drawable.ic_wx_moon;
            case SUN_CLOUD: return R.drawable.ic_wx_sun_cloud;
            case MOON_CLOUD: return R.drawable.ic_wx_moon_cloud;
            case CLOUD: return R.drawable.ic_wx_cloud;
            case FOG: return R.drawable.ic_wx_fog;
            case RAIN: return R.drawable.ic_wx_rain;
            case POURING: return R.drawable.ic_wx_pouring;
            case SNOW: return R.drawable.ic_wx_snow;
            case THUNDER:
            default: return R.drawable.ic_wx_thunder;
        }
    }

    /** Icon tint (owner palette 2026-11-27): sun/thunder warm, moon pale, rain blue, snow white-blue. */
    private static int weatherTint(WeatherIcon.Icon icon) {
        switch (icon) {
            case SUN:
            case SUN_CLOUD: return R.color.weather_sun;     // partly cloudy keeps the warm sun hue
            case MOON:
            case MOON_CLOUD: return R.color.weather_moon;
            case RAIN:
            case POURING: return R.color.weather_rain;
            case SNOW: return R.color.weather_snow;
            case THUNDER: return R.color.weather_thunder;
            case CLOUD:
            case FOG:
            default: return R.color.weather_cloud;          // owner: text_sub in both themes
        }
    }

    private final BroadcastReceiver testRadarReceiver = new BroadcastReceiver() {
        @Override public void onReceive(Context c, Intent i) {
            float lat = i.getFloatExtra("lat", Float.NaN), lon = i.getFloatExtra("lon", Float.NaN);
            if (radar == null || Float.isNaN(lat) || Float.isNaN(lon) || Math.abs(lat) > 85 || Math.abs(lon) > 180) return;
            radarTestUntil = android.os.SystemClock.uptimeMillis() + RADAR_TEST_MS;
            radar.setLatLon(lat, lon);
            radar.restart();
            main.postDelayed(() -> { radarTestUntil = 0; lastPosLat = Double.NaN; updateHomePosition(); }, RADAR_TEST_MS);
        }
    };

    private final BroadcastReceiver testTempReceiver = new BroadcastReceiver() {
        @Override public void onReceive(Context c, Intent i) {
            int t = i.getIntExtra("celsius", Integer.MIN_VALUE);
            if (t > -50 && t < 200) onEngineTemp(t, i.getBooleanExtra("oil", false));
        }
    };

    /** HCTCanBus rpm broadcast: extras are parsed guarded - junk must never crash the launcher. */
    private final BroadcastReceiver rpmReceiver = new BroadcastReceiver() {
        @Override public void onReceive(Context c, Intent i) {
            try {
                Integer rpm = EngineGauges.parseRpm(i.getStringExtra(RPM_EXTRA));
                if (rpm == null) return; // negative / > 9000 / non-numeric: leave the gauge as-is
                if (engineRpm == null) return;
                rpmSeen = true;
                engineRpm.setText(rpm == 0 ? getString(R.string.engine_off) : rpm + " rpm");
                tintGauge(engineRpm, getResources().getColor(R.color.text_sub)); // neutral, also for "Engine off"
                engineRpm.setVisibility(View.VISIBLE);
                main.removeCallbacks(rpmStale);
                main.postDelayed(rpmStale, RPM_STALE_MS);
            } catch (Throwable junkBroadcast) {
                android.util.Log.w("LauncherActivity", "junk rpm broadcast", junkBroadcast);
            }
        }
    };

    /** RPM frame stale for RPM_STALE_MS -> hide the gauge (spec: no RPM protocol / ignition off). */
    private final Runnable rpmStale = new Runnable() {
        @Override public void run() {
            if (engineRpm == null) return;
            if (rpmSeen) { engineRpm.setText(getString(R.string.engine_off)); engineRpm.setVisibility(View.VISIBLE); }
            else engineRpm.setVisibility(View.GONE);
        }
    };

    private void registerRpmReceiver() {
        try {
            // HCTCanBus sends via sendBroadcastAsUser: the receiver must be exported (A14).
            registerReceiver(rpmReceiver, new IntentFilter(RPM_ACTION), Context.RECEIVER_EXPORTED);
            registerReceiver(testTempReceiver, new IntentFilter(TEST_TEMP_ACTION),
                android.Manifest.permission.DUMP, null, Context.RECEIVER_EXPORTED);
            registerReceiver(testRadarReceiver, new IntentFilter(TEST_RADAR_ACTION),
                android.Manifest.permission.DUMP, null, Context.RECEIVER_EXPORTED);
        } catch (Throwable t) {
            // Denied or framework drift: the gauge stays hidden, the home screen still runs (S36).
            android.util.Log.w("LauncherActivity", "rpm receiver registration failed", t);
        }
    }

    /**
     * HCTCanBus outside-air temperature broadcast: com.canbus.temperature, String extra
     * "temperature". The frame format has not been seen on a car yet (UNKNOWN), so
     * WeatherIcon.parseCanTemp reads the first signed decimal in it; an unrecognised frame changes
     * nothing (Open-Meteo's value stays). Exported like the rpm receiver (sendBroadcastAsUser).
     */
    private final BroadcastReceiver canTempReceiver = new BroadcastReceiver() {
        @Override public void onReceive(Context c, Intent i) {
            try {
                Double t = WeatherIcon.parseCanTemp(i.getStringExtra(CAN_TEMP_EXTRA));
                if (t == null) return; // junk / unknown format: keep the previous value
                carTemp = t;
                carTempAt = System.currentTimeMillis();
                showWeather();
            } catch (Throwable junkBroadcast) {
                android.util.Log.w("LauncherActivity", "junk canbus temperature broadcast", junkBroadcast);
            }
        }
    };

    private void registerWeatherReceiver() {
        try {
            registerReceiver(canTempReceiver, new IntentFilter(CAN_TEMP_ACTION), Context.RECEIVER_EXPORTED);
        } catch (Throwable t) {
            // Denied or framework drift: the Open-Meteo temperature still works, no crash (S36).
            android.util.Log.w("LauncherActivity", "canbus temperature receiver registration failed", t);
        }
    }

    @Override
    public void onConfigurationChanged(Configuration newConfig) {
        super.onConfigurationChanged(newConfig);
        // uiMode is handled here (configChanges in the manifest) so the theme switch animates
        // instead of recreating the activity (spec S38).
        if (radar != null) radar.setNight(theme.systemNight());
        repaintIconTints(); // the night palette differs for gauge + weather glyphs (owner 2026-11-27)
        animateThemeSwap();
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (map != null) map.onHomeVisible();
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
        media.onResume(); // radio source polling + state request while home is visible
        if (radar != null) radar.restart(); // one refresh timer per visible activity (S18')
        refreshFavorites(); // installs/uninstalls and valet state may have changed (S40)
        // Owner position (Round 3): the app read no position at all before. Newest known GPS fix,
        // else the De Bilt default; live fixes keep coming via the listener while resumed. The
        // position is memory-only — never written to SharedPreferences, never logged (privacy).
        if (locationManager == null) {
            try { locationManager = (LocationManager) getSystemService(Context.LOCATION_SERVICE); }
            catch (Throwable t) { locationManager = null; } // service absent: stay on the default position
        }
        updateHomePosition();
        // Weather (owner 2026-11-27): refresh now when the last attempt is older than 15 min (or
        // never happened); updateHomePosition() above is what the rounded URL is built from.
        homeVisible = true;
        refreshWeatherIfNeeded();
        try {
            if (locationManager != null) {
                locationManager.requestLocationUpdates("gps", 60_000L, 1000f, locationListener, Looper.getMainLooper());
            }
        } catch (SecurityException | IllegalArgumentException t) {
            // ACCESS_FINE_LOCATION revoked (A14) or no gps provider: known fixes + default still work
        }
    }

    /** GPS updates arrive on the main looper (listener registered with it). */
    private final LocationListener locationListener = new LocationListener() {
        @Override public void onLocationChanged(Location fix) {
            if (fix == null) return;
            liveFix = new RadarPosition.Fix(fix.getLatitude(), fix.getLongitude(), fix.getTime());
            updateHomePosition();
        }
    };

    /**
     * Choose the home/radar position: newest of gps > network > fused known fixes plus the newest
     * live listener fix, else SettingsKeys.DEFAULT_LAT/LON (De Bilt). Recentre the radar when the
     * chosen position moved more than 5 km from the one currently drawn (spec S15/S30).
     */
    private void updateHomePosition() {
        if (android.os.SystemClock.uptimeMillis() < radarTestUntil) return; // bench test centre active
        List<RadarPosition.Fix> fixes = new ArrayList<>();
        if (liveFix != null) fixes.add(liveFix);
        if (locationManager != null) {
            for (String provider : new String[] { "gps", "network", "fused" }) {
                try {
                    Location fix = locationManager.getLastKnownLocation(provider);
                    if (fix != null) fixes.add(new RadarPosition.Fix(fix.getLatitude(), fix.getLongitude(), fix.getTime()));
                } catch (SecurityException t) {
                    // provider permission revoked on A14: this source contributes nothing
                }
            }
        }
        double[] pos = RadarPosition.choose(fixes, new double[] { SettingsKeys.DEFAULT_LAT, SettingsKeys.DEFAULT_LON });
        if (radar == null) return;
        boolean fresh = Double.isNaN(lastPosLat) || Double.isNaN(lastPosLon)
            || RadarPosition.movedFar(lastPosLat, lastPosLon, pos[0], pos[1], RadarPosition.RECENTRE_METERS);
        radar.setLatLon(pos[0], pos[1]);
        if (fresh) radar.restart(); // tile grid must be centred on the new position
        lastPosLat = pos[0];
        lastPosLon = pos[1];
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
    private View favBar;

    void toggleFavorites() { setFavoritesShown(favBar.getVisibility() != View.VISIBLE); }

    /** Slide the favourite overlay in/out over the cards. */
    void setFavoritesShown(boolean show) {
        if (favBar == null) return;
        if (show == (favBar.getVisibility() == View.VISIBLE)) return;
        favBar.animate().cancel();
        if (show) {
            favBar.setTranslationY(favBar.getHeight() > 0 ? favBar.getHeight() : 120f);
            favBar.setAlpha(0f);
            favBar.setVisibility(View.VISIBLE);
            favBar.animate().translationY(0f).alpha(1f).setDuration(180).start();
        } else {
            favBar.animate().translationY(favBar.getHeight()).alpha(0f).setDuration(150)
                .withEndAction(() -> favBar.setVisibility(View.GONE)).start();
        }
    }

    void launchFavorite(String pkg, int slot) {
        setFavoritesShown(false); // the overlay closes on every slot tap
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
        if (map != null) map.onHomeHidden();
        if (media != null) media.onPause();
        if (favBar != null) { favBar.animate().cancel(); favBar.setVisibility(View.GONE); } // closed when home is left
        // The home screen stays as-is; valet state is owned by ValetController + persisted prefs.
        // The trusted-phone exit watch (S26) is NOT stopped here: while valet is active the owner
        // may be sitting in the app drawer or settings, and the phone must still end valet.
        if (radar != null) radar.stop();
        homeVisible = false; // the 15-minute weather clock stops with the home screen (owner rule)
        try {
            if (locationManager != null) locationManager.removeUpdates(locationListener);
        } catch (SecurityException | IllegalArgumentException t) {
            // provider gone or permission revoked while paused: nothing to unregister
        }
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        MediaListenerService.callback = null;
        if (radar != null) radar.stop();
        if (map != null) {
            if (isChangingConfigurations()) map.detachForRecreate();   // day/night rebuild: keep the display
            else { map.release(); App.setMapCard(null); }
        }
        main.removeCallbacks(rpmStale);
        try { unregisterReceiver(testTempReceiver); } catch (Throwable ignore) { }
        try { unregisterReceiver(testRadarReceiver); } catch (Throwable ignore) { }
        try { unregisterReceiver(rpmReceiver); }
        catch (Throwable ignore) { /* never registered (guarded above) or already unregistered */ }
        try { unregisterReceiver(canTempReceiver); }
        catch (Throwable ignore) { /* never registered (guarded above) or already unregistered */ }
    }
}
