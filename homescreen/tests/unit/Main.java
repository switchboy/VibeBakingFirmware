package org.vibebaking.launcher.unit;

import org.vibebaking.launcher.logic.AppDrawerPolicy;
import org.vibebaking.launcher.logic.ArtPalette;
import org.vibebaking.launcher.logic.BacklightPolicy;
import org.vibebaking.launcher.logic.BatteryState;
import org.vibebaking.launcher.logic.CarEventParser;
import org.vibebaking.launcher.logic.ClockFormat;
import org.vibebaking.launcher.logic.ColorTools;
import org.vibebaking.launcher.logic.CombinedPhoneProbe;
import org.vibebaking.launcher.logic.DayNight;
import org.vibebaking.launcher.logic.EngineGauges;
import org.vibebaking.launcher.logic.FavoritePolicy;
import org.vibebaking.launcher.logic.Json;
import org.vibebaking.launcher.logic.MapCardPolicy;
import org.vibebaking.launcher.logic.MapTargetPolicy;
import org.vibebaking.launcher.logic.RadioState;
import org.vibebaking.launcher.logic.MediaCardPolicy;
import org.vibebaking.launcher.logic.PhonePolicy;
import org.vibebaking.launcher.logic.PhonePresence;
import org.vibebaking.launcher.logic.PhonePresenceProbe;
import org.vibebaking.launcher.logic.RadarPlan;
import org.vibebaking.launcher.logic.RadarPosition;
import org.vibebaking.launcher.logic.RadarTiles;
import org.vibebaking.launcher.logic.SettingsCycle;
import org.vibebaking.launcher.logic.SettingsKeys;
import org.vibebaking.launcher.logic.SettingsValidation;
import org.vibebaking.launcher.logic.ThemePolicy;
import org.vibebaking.launcher.logic.ValetPin;
import org.vibebaking.launcher.logic.ValetPolicy;
import org.vibebaking.launcher.logic.VolumePolicy;
import org.vibebaking.launcher.logic.WeatherIcon;

import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Instant;
import java.time.LocalDate;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/** Plain-assertion unit harness for the launcher's pure logic core (spec map U-ids). */
public class Main {

    static int checks = 0;
    static final List<String> failures = new java.util.ArrayList<>();

    static void check(String id, boolean cond) {
        checks++;
        if (cond) System.out.println("PASS " + id);
        else { failures.add(id); System.out.println("FAIL " + id); }
    }

    /** Failure-note variant: the extra explanation is printed only when the check fails. */
    static void check(String id, boolean cond, String why) {
        check(id, cond);
        if (!cond) System.out.println("     why: " + why);
    }

    public static void main(String[] args) throws Exception {
        Path dir = Path.of(args.length > 0 ? args[0] : ".");
        t01Radar(dir);
        t02Json();
        t03RadarPalette();
        t04Clock();
        t05Battery();
        t06ValetPolicy();
        t07EntryGuard();
        t08ValetPin();
        t09ThemePolicy();
        t10VolumePolicy();
        t11BacklightPolicy();
        t12ArtPalette();
        t13MediaPolicy();
        t14CarEventParser();
        t15DayNight();
        t16MapTarget();
        t17OwnerDefaults();
        t18AppDrawer();
        t19PhonePolicy();
        t20CombinedPhoneProbe();
        t21FavoriteRow();
        t22RadarPosition();
        t23EngineGauges();
        t24SettingsCycle();
        t25SettingsValidation();
        t26WeatherIcon();
        System.out.println(checks + " checks, " + failures.size() + " failed");
        if (!failures.isEmpty()) {
            System.out.println("FAILED: " + String.join(", ", failures));
            System.exit(1);
        }
    }

    // U01/U03: RainViewer v2 index parse, latest past frame, zoom clamp, tile math, grid origin.
    static void t01Radar(Path dir) throws Exception {
        String json = Files.readString(dir.resolve("tests/fixtures/weather_maps.json"));
        RadarTiles.RadarSpec spec = RadarTiles.parseApi(json);
        check("U01.host", spec.host.equals("https://tilecache.rainviewer.com"));
        check("U01.frames3", spec.frames.size() == 3); // radar.past only; satellite + nowcast ignored
        RadarTiles.Frame latest = RadarTiles.pickLatest(spec);
        check("U01.latest", latest != null && latest.path.equals("/v2/radar/1d6614366d83") && latest.timeSec == 1764073800L,
            "frames are listed oldest first: the newest time must win, not the list order");
        check("U01.oldestFirstStillLatest", spec.frames.get(0).timeSec < latest.timeSec);
        String nowcastOnly = "{\"version\":\"2.0\",\"host\":\"https://tilecache.rainviewer.com\","
            + "\"radar\":{\"past\":[],\"nowcast\":[{\"time\":99,\"path\":\"/v2/radar/nc\"}]}}";
        RadarTiles.RadarSpec nc = RadarTiles.parseApi(nowcastOnly);
        check("U01.nowcastIgnored", nc.frames.isEmpty() && RadarTiles.pickLatest(nc) == null,
            "RainViewer's nowcast is empty in practice: never rely on it");
        check("U01.radarUrl", RadarTiles.radarTileUrl(spec.host, latest.path, 7, 65, 42)
            .equals("https://tilecache.rainviewer.com/v2/radar/1d6614366d83/256/7/65/42/2/1_1.png"));
        check("U01.baseDay", RadarTiles.baseTileUrl(false, 7, 65, 42)
            .equals("https://tile.openstreetmap.org/7/65/42.png"));
        check("U01.baseNight", RadarTiles.baseTileUrl(true, 7, 65, 42)
            .equals("https://tile.openstreetmap.org/7/65/42.png"));
        check("U01.zoomClamp", RadarTiles.clampZoom(8) == 7 && RadarTiles.clampZoom(7) == 7 && RadarTiles.clampZoom(3) == 3,
            "z=8+ is one constant placeholder image: never request more than 7");
        check("U01.zoomClampPlan", RadarPlan.sanitizeZoom(12) == 7 && RadarPlan.sanitizeZoom(0) == 3);
        check("U01.attribution", RadarTiles.ATTRIBUTION.equals("\u00A9 OpenStreetMap contributors \u00B7 Radar: RainViewer"));
        check("U01.noHostUsesTilecache", RadarTiles.parseApi("{\"radar\":{\"past\":[{\"time\":1,\"path\":\"/v2/radar/x\"}]}}")
            .host.equals(RadarTiles.TILECACHE));
        check("U01.noPathSkipped", RadarTiles.pickLatest(RadarTiles.parseApi("{\"radar\":{\"past\":[{\"time\":5}]}}")) == null,
            "a past entry without path cannot be drawn");
        check("U01.junkBody", throws_(s -> RadarTiles.parseApi(s), "<html>301 Moved Permanently</html>"),
            "the dead rainviewer.com endpoint answers HTML: garbage must throw, RadarPlan turns it into offline");
        check("U01.tileX", RadarTiles.tileX(5.18, 7) == 65);
        check("U01.tileY", RadarTiles.tileY(52.10, 7) == 42);
        int[] o = RadarTiles.gridOriginPx(52.10, 5.18, 7);
        check("U01.originX", Math.abs(o[0] - 16343) <= 2);
        check("U01.originY", Math.abs(o[1] - 10508) <= 2);
        check("U01.grid12", RadarTiles.tilesAcross(7) == 12);
        int[] c = RadarTiles.clampTile(7, 65, 42);
        check("U01.clampTile", Arrays.equals(c, new int[]{65, 42}));
        check("U01.wrapTile", Arrays.equals(RadarTiles.clampTile(7, -3, 42), new int[]{125, 42}));
        check("U01.skipTileY", RadarTiles.clampTile(7, 65, -1) == null);
        check("U01.frameLabel", RadarTiles.frameLabel(1764073800L).startsWith("2025-11-25T12:30"),
            "frame timestamps are unix seconds -> ISO UTC label");
    }

    // U02: JSON parser basics + error paths.
    static void t02Json() {
        Map<String, Object> m = Json.object(Json.parse("{\"a\":[1,2.5,true,null,\"x\\n\\u00e9\"],\"b\":{\"c\":3}}"));
        List<Object> arr = Json.array(m.get("a"));
        check("U02.num", arr.get(0).equals(1L));
        check("U02.double", arr.get(1).equals(2.5));
        check("U02.bool", arr.get(2).equals(Boolean.TRUE));
        check("U02.null", arr.get(3) == null);
        check("U02.escape", arr.get(4).equals("x\n\u00e9"));
        check("U02.nested", Json.object(m.get("b")).get("c").equals(3L));
        check("U02.bad", throws_(s -> Json.parse(s), "{oops") || throws_(s -> Json.parse(s), "{\"a\":1} x"));
    }

    static boolean throws_(java.util.function.Consumer<String> f, String s) {
        try { f.accept(s); return false; } catch (RuntimeException e) { return true; }
    }

    // U03: day/night radar palette (night muted, no white, lower alpha).
    static void t03RadarPalette() {
        int[] day = RadarTiles.palette(false);
        int[] night = RadarTiles.palette(true);
        check("U03.dayLight", ColorTools.luminance(day[0]) > 0.5);
        check("U03.nightDark", ColorTools.luminance(night[0]) < 0.25);
        check("U03.nightNoWhite", !ColorTools.isPureWhite(night[0]));
        check("U03.nightMuted", night[1] < day[1]);
        check("U03.daySaturated", day[1] >= 230);
    }

    // U04: car clock formatting + tick period.
    static void t04Clock() {
        long epoch = Instant.parse("2026-11-25T14:23:00Z").toEpochMilli();
        check("U04.time", ClockFormat.time(epoch, 1).equals("15:23"));
        check("U04.date", ClockFormat.date(epoch, 1).equals("Wed 25 Nov"));
        check("U04.tick", ClockFormat.TICK_MS == 60_000L);
    }

    // U05: battery chip (tenths-of-volt assumption, hidden when unknown, low threshold).
    static void t05Battery() {
        check("U05.label", BatteryState.label(121).equals("12.1 V"));
        check("U05.known", !BatteryState.known(0));
        check("U05.low", BatteryState.low(114, 11.5));
        check("U05.notLow", !BatteryState.low(121, 11.5));
        check("U05.scale", Math.abs(BatteryState.volts(121) - 12.1) < 0.001);
    }

    // U06: valet suspend policy (spec S21/S22).
    static void t06ValetPolicy() {
        List<ValetPolicy.App> apps = Arrays.asList(
            new ValetPolicy.App("com.google.android.apps.maps", false),
            new ValetPolicy.App("com.foo.game", false),
            new ValetPolicy.App("com.android.settings", true),
            new ValetPolicy.App("android", true),
            new ValetPolicy.App("com.android.systemui", true),
            new ValetPolicy.App("android.microntek.service", true),
            new ValetPolicy.App("android.microntek.canbus", true),
            new ValetPolicy.App("android.microntek.mtcser", true),
            new ValetPolicy.App("org.vibebaking.launcher", false),
            new ValetPolicy.App("com.microntek.backview", false),
            new ValetPolicy.App("com.microntek.frontview", false),
            new ValetPolicy.App("com.microntek.radio", true),
            new ValetPolicy.App("com.microntek.bluetooth", false),
            new ValetPolicy.App("com.spotify.music", false));
        List<String> suspend = ValetPolicy.computeSuspend(apps, Set.of());
        check("U06.suspend", suspend.equals(Arrays.asList(
            "com.android.settings", "com.foo.game", "com.spotify.music")));
        List<String> withExtra = ValetPolicy.computeSuspend(apps, Set.of("com.foo.game"));
        check("U06.extra", withExtra.equals(Arrays.asList("com.android.settings", "com.spotify.music")));
        check("U06.protectedBackview", ValetPolicy.PROTECTED.contains("com.microntek.backview"));
        check("U06.protectedHct", ValetPolicy.PROTECTED.contains("android.microntek.service")
            && ValetPolicy.PROTECTED.contains("android.microntek.canbus")
            && ValetPolicy.PROTECTED.contains("android.microntek.mtcser")
            && ValetPolicy.PROTECTED.contains("com.android.systemui")
            && ValetPolicy.PROTECTED.contains("android"));
        check("U06.allowedExact", ValetPolicy.DEFAULT_ALLOWED.equals(Set.of(
            "com.google.android.apps.maps", "com.microntek.radio", "com.microntek.bluetooth",
            "com.microntek.frontview", "com.microntek.backview")));
        Set<String> tiles = ValetPolicy.allowedSet(Set.of());
        check("U06.tiles", tiles.equals(Set.of(
            "com.google.android.apps.maps", "com.microntek.backview", "com.microntek.bluetooth",
            "com.microntek.frontview", "com.microntek.radio", "org.vibebaking.launcher")),
            "valet app surface = allowed set; the drawer renders exactly this (S27/S39b)");
        check("U06.allowedExtras", ValetPolicy.allowedSet(Set.of("com.foo.game")).contains("com.foo.game"));
        check("U06.noTilesApi", java.util.Arrays.stream(ValetPolicy.class.getMethods())
            .noneMatch(m -> m.getName().equals("homeTiles")),
            "the old valet-tiles idea is gone: the drawer is the app surface (S27/S39b)");
        check("U06.settingsSuspended", ValetPolicy.computeSuspend(apps, Set.of()).contains("com.android.settings"));
    }

    // U14: bootstrap guard (spec S26a/S27a) - no entry without master switch AND an exit path.
    static void t07EntryGuard() {
        check("U14.masterOff", !ValetPolicy.entryAllowed(false, true, true));
        check("U14.noExit", !ValetPolicy.entryAllowed(true, false, false));   // BT dead + no PIN = trap
        check("U14.pinSet", ValetPolicy.entryAllowed(true, true, false));
        check("U14.trustedPhone", ValetPolicy.entryAllowed(true, false, true));
        check("U14.warn", ValetPolicy.warnNoExit(true, false, false));
        check("U14.noWarnWhenOff", !ValetPolicy.warnNoExit(false, false, false));
        check("U14.noWarnWithPin", !ValetPolicy.warnNoExit(true, true, false));
    }

    // U08: PIN hash + attempt lockout (spec S26).
    static void t08ValetPin() {
        String h = ValetPin.hashPin("4321");
        check("U08.hashLen", h.length() == 64 && h.matches("[0-9a-f]+"));
        check("U08.hashStable", h.equals(ValetPin.hashPin("4321")));
        check("U08.hashDiffers", !h.equals(ValetPin.hashPin("4322")));
        ValetPin.Guard g = new ValetPin.Guard();
        long t0 = 1_700_000_000_000L;
        ValetPin.Verdict w1 = g.verify("1111", h, t0);
        check("U08.w1", !w1.ok && !w1.locked && w1.remaining == ValetPin.MAX_ATTEMPTS - 1);
        // 4 more wrong attempts -> the 5th arms the lockout and reports the full window.
        ValetPin.Verdict v = null;
        for (int i = 1; i < ValetPin.MAX_ATTEMPTS; i++) v = g.verify("1111", h, t0 + i * 1000);
        long armedAt = t0 + (ValetPin.MAX_ATTEMPTS - 1) * 1000L;
        check("U08.locked", v != null && v.locked && v.retryInMs == ValetPin.LOCKOUT_MS);
        check("U08.lockedBlocks", g.verify("4321", h, armedAt + ValetPin.LOCKOUT_MS - 1).locked);
        check("U08.countWhileLocked", g.verify("1111", h, armedAt + 1000).remaining == 0);
        check("U08.expired", g.verify("4321", h, armedAt + ValetPin.LOCKOUT_MS + 1).ok);
        g.reset();
        g.verify("1111", h, t0);           // one wrong
        check("U08.resetAfterOk", g.verify("4321", h, t0).ok && g.verify("1111", h, t0).remaining == ValetPin.MAX_ATTEMPTS - 1);
        check("U08.noPinNoVerify", !g.verify("1234", "", t0).ok);
    }

    // U09: dark-mode decision matrix (spec S29/S30).
    static void t09ThemePolicy() {
        check("U09.cycleNight", ThemePolicy.night("cycle", false, true, "nothing"));
        check("U09.cycleDay", !ThemePolicy.night("cycle", false, false, "nothing"));
        check("U09.alwaysLight", !ThemePolicy.night("always_light", true, true, "nothing"));
        check("U09.alwaysDark", ThemePolicy.night("always_dark", false, false, "nothing"));
        check("U09.carLightsOn", ThemePolicy.night("car_lights", true, false, "nothing"));
        check("U09.carLightsOff", !ThemePolicy.night("car_lights", false, true, "nothing"));
        check("U09.lightsForceDark", ThemePolicy.night("always_light", true, false, "dark"));
        check("U09.lightsNothing", !ThemePolicy.night("always_light", true, false, "nothing"));
    }

    // U10: reverse volume attenuation (spec S31, owner default lower@30).
    static void t10VolumePolicy() {
        check("U10.lower", VolumePolicy.targetVolume("lower", 30, 15, 10) == 5);
        check("U10.mute", VolumePolicy.targetVolume("mute", 30, 15, 10) == 0);
        check("U10.unchanged", VolumePolicy.targetVolume("unchanged", 30, 15, 10) == null);
        check("U10.clampHigh", VolumePolicy.targetVolume("lower", 120, 15, 8) == 15);
        check("U10.restore", VolumePolicy.restoreVolume(true, 10) == 10);
        check("U10.noRestore", VolumePolicy.restoreVolume(false, 10) == null);
        check("U10.captureOnce", VolumePolicy.capture(10, 5) == 10);
        check("U10.captureFirst", VolumePolicy.capture(null, 9) == 9);
        check("U10.mcuCmd", VolumePolicy.mcuVolumeCommand(30).equals("ctl_backview_vol=30"));
        check("U10.defaults", SettingsKeys.DEFAULT_REVERSE_VOLUME.equals("lower")
            && SettingsKeys.DEFAULT_REVERSE_VOLUME_PERCENT == 30);
    }

    // U11: backlight dim decision (spec S28, owner default nothing).
    static void t11BacklightPolicy() {
        check("U11.nothing", BacklightPolicy.dimFraction("nothing", 40, true) == null);
        check("U11.dimOn", BacklightPolicy.dimFraction("dim", 40, true) == 0.4);
        check("U11.dimOffLights", BacklightPolicy.dimFraction("dim", 40, false) == null);
        check("U11.clamp", BacklightPolicy.dimFraction("dim", 120, true) == 1.0);
        check("U11.clamp0", BacklightPolicy.dimFraction("dim", -5, true) == 0.0);
        check("U11.default", SettingsKeys.DEFAULT_BACKLIGHT_MODE.equals("nothing"));
    }

    // U12: album-art tinting (spec S35/S33: night tint dark, never white, hue kept).
    static void t12ArtPalette() {
        int[] red = {0xFFFF0000, 0xFFFF3300, 0xFFFF0000, 0xFFCC0000};
        double hue = ArtPalette.dominantHue(red);
        check("U12.redHue", hue >= 0 && hue <= 15);
        int day = ArtPalette.dayTint(red);
        int night = ArtPalette.nightTint(red);
        check("U12.dayBright", ColorTools.luminance(day) > 0.5);
        check("U12.nightDark", ColorTools.luminance(night) < 0.25);
        check("U12.nightNoWhite", !ColorTools.isPureWhite(night));
        double nh = ColorTools.rgbToHsv(night)[0];
        check("U12.hueKept", nh <= 15 || nh >= 345);
        int[] grey = {0xFF808080, 0xFF707070};
        check("U12.greyHue", ArtPalette.dominantHue(grey) < 0);
        check("U12.greyNight", ColorTools.luminance(ArtPalette.nightTint(grey)) < 0.25);
        check("U12.dim", Math.abs(ArtPalette.nightArtDim() - 0.62) < 0.001);
    }

    // U13/U02: media presentation degrade paths (spec S12/S37).
    static void t13MediaPolicy() {
        MediaCardPolicy.Ctl idle = new MediaCardPolicy.Ctl();
        idle.pkg = "com.foo"; idle.pkgLabel = "Foo"; idle.title = ""; idle.artist = "";
        MediaCardPolicy.Ctl playing = new MediaCardPolicy.Ctl();
        playing.pkg = "com.spotify.music"; playing.pkgLabel = "Spotify";
        playing.title = "Song"; playing.artist = "Artist"; playing.playing = true;
        playing.canPlayPause = true; playing.canSkipNext = true;
        check("U13.pickPlaying", MediaCardPolicy.pickActive(Arrays.asList(idle, playing)) == playing);
        check("U13.label", MediaCardPolicy.label(playing).equals("Song \u2022 Artist"));
        check("U13.labelFallback", MediaCardPolicy.label(idle).equals("Foo"));
        check("U13.empty", MediaCardPolicy.pickActive(List.of()) == null);
        check("U13.emptyLabel", MediaCardPolicy.label(null).equals(""));
        check("U13.transport", MediaCardPolicy.transportEnabled(playing) == (1 | 2));
        check("U13.radio", MediaCardPolicy.radioLabel("NPO 3FM", idle).equals("NPO 3FM"));
        check("U13.radioEmpty", MediaCardPolicy.radioLabel("", idle).equals("Foo"));
        check("U13.album", MediaCardPolicy.album(idle).equals(""));
    }

    // U14b: CarService event parsing (protocol per specs.md).
    static void t14CarEventParser() {
        Map<String, Object> b = new HashMap<>();
        b.put("type", "backview"); b.put("value", Boolean.TRUE); b.put("mode", "frontview");
        CarEventParser.CarEvent e = CarEventParser.parse("CarEvent", b);
        check("U14b.backviewStart", e.kind == CarEventParser.Kind.BACKVIEW_START && e.mode.equals("frontview") && e.flag);
        b.put("value", "false");
        check("U14b.backviewStop", CarEventParser.parse("CarEvent", b).kind == CarEventParser.Kind.BACKVIEW_STOP);
        Map<String, Object> hl = new HashMap<>();
        hl.put("type", "headlight"); hl.put("value", 1);
        check("U14b.headlightOn", CarEventParser.parse("CarEvent", hl).kind == CarEventParser.Kind.HEADLIGHT_ON);
        Map<String, Object> bat = new HashMap<>();
        bat.put("type", "battery"); bat.put("value", 121);
        check("U14b.battery", CarEventParser.parse("CarEvent", bat).intValue == 121);
        Map<String, Object> key = new HashMap<>();
        key.put("type", "key"); key.put("value", 0x111);
        check("U14b.key", CarEventParser.parse("CarEvent", key).kind == CarEventParser.Kind.KEY);
        Map<String, Object> acc = new HashMap<>();
        acc.put("type", "acc_off");
        check("U14b.accOff", CarEventParser.parse("CarEvent", acc).kind == CarEventParser.Kind.ACC_OFF);
        check("U14b.nullSafe", CarEventParser.parse("CarEvent", null).kind == CarEventParser.Kind.UNKNOWN);
        check("U14b.longValue", CarEventParser.asInt(121L) == 121);
    }

    // U22: day/night cycle math (NOAA approx, tolerance ~45 min).
    static void t15DayNight() {
        LocalDate june = LocalDate.of(2026, 6, 21);
        LocalDate dec = LocalDate.of(2026, 12, 21);
        Double rise = DayNight.sunriseUtcMinutes(52.09, 5.29, june);
        check("U15.juneRise", rise != null && Math.abs(rise - 196) < 45);
        Double riseD = DayNight.sunriseUtcMinutes(52.09, 5.29, dec);
        check("U15.decRise", riseD != null && Math.abs(riseD - 467) < 45);
        long juneNoon = Instant.parse("2026-06-21T11:00:00Z").toEpochMilli(); // 13:00 CEST
        check("U15.juneDay", !DayNight.isNight(52.09, 5.29, juneNoon, 2));
        long juneNight = Instant.parse("2026-06-21T21:00:00Z").toEpochMilli(); // 23:00 CEST
        check("U15.juneNight", DayNight.isNight(52.09, 5.29, juneNight, 2));
        long decNoon = Instant.parse("2026-12-21T11:00:00Z").toEpochMilli();   // 12:00 CET
        check("U15.decDay", !DayNight.isNight(52.09, 5.29, decNoon, 1));
        long decLate = Instant.parse("2026-12-21T16:00:00Z").toEpochMilli();   // 17:00 CET
        check("U15.decNight", DayNight.isNight(52.09, 5.29, decLate, 1));
        // Polar truth: Dec at 78N the sun never rises (night all day); June it never sets (day all day).
        long polarNight = Instant.parse("2026-12-21T02:00:00Z").toEpochMilli();
        check("U15.polarNight", DayNight.isNight(78.0, 15.0, polarNight, 1));
        long polarDecNoon = Instant.parse("2026-12-21T11:00:00Z").toEpochMilli();
        check("U15.polarDecNoonNight", DayNight.isNight(78.0, 15.0, polarDecNoon, 1));
        long polarJuneNightHour = Instant.parse("2026-06-21T02:00:00Z").toEpochMilli();
        check("U15.polarMidnightSunDay", !DayNight.isNight(78.0, 15.0, polarJuneNightHour, 1));
        check("U15.polarSunriseNull", DayNight.sunriseUtcMinutes(78.0, 15.0, dec) == null);
        check("U15.tz", DayNight.tzOffsetHours(0, ZoneOffset.ofHours(2)) == 2);
    }

    // U07: map target selection (spec S7/S8).
    static void t16MapTarget() {
        Set<String> both = new HashSet<>(Arrays.asList(MapTargetPolicy.MAPS, MapTargetPolicy.WAZE));
        check("U16.autoMaps", MapTargetPolicy.target("auto", both).equals(MapTargetPolicy.MAPS));
        check("U16.autoWaze", MapTargetPolicy.target("auto", Set.of(MapTargetPolicy.WAZE)).equals(MapTargetPolicy.WAZE));
        check("U16.none", MapTargetPolicy.target("auto", Set.of()) == null);
        check("U16.explicitWaze", MapTargetPolicy.target("waze", both).equals(MapTargetPolicy.WAZE));
        check("U16.explicitMissing", MapTargetPolicy.target("maps", Set.of(MapTargetPolicy.WAZE)) == null);
        check("U16.nullSetting", MapTargetPolicy.target(null, both).equals(MapTargetPolicy.MAPS));
    }

    // U17: owner defaults exactly as homescreen.md (spec S28-S31, S25-S27a).
    static void t17OwnerDefaults() {        check("U17.backlight", SettingsKeys.DEFAULT_BACKLIGHT_MODE.equals("nothing"));
        check("U17.theme", SettingsKeys.DEFAULT_THEME_ON_LIGHTS.equals("nothing"));
        check("U17.darkCycle", SettingsKeys.DEFAULT_DARK_MODE.equals("cycle"));
        check("U17.reverseLower", SettingsKeys.DEFAULT_REVERSE_VOLUME.equals("lower"));
        check("U17.reversePct", SettingsKeys.DEFAULT_REVERSE_VOLUME_PERCENT == 30);
        check("U17.mcuOff", SettingsKeys.DEFAULT_REVERSE_MCU == false);
        check("U17.timeout", SettingsKeys.DEFAULT_VALET_TIMEOUT_S == 60);
        check("U17.autoOn", SettingsKeys.DEFAULT_VALET_AUTO == true);
        check("U17.enabledOff", SettingsKeys.DEFAULT_VALET_ENABLED == false);
        check("U17.mapAuto", SettingsKeys.DEFAULT_MAP_TARGET.equals("auto"));
        check("U17.coords", SettingsKeys.DEFAULT_LAT == 52.10 && SettingsKeys.DEFAULT_LON == 5.18,
            "owner default position: De Bilt, NL (live GPS fixes are read in memory, never stored)");
    }

    // U18: app drawer arrangement (spec S39/S39a/S39b/S2b).
    static void t18AppDrawer() {
        List<AppDrawerPolicy.Entry> all = Arrays.asList(
            new AppDrawerPolicy.Entry("com.waze", "Waze", true),
            new AppDrawerPolicy.Entry("com.google.android.apps.maps", "Google Maps", true),
            new AppDrawerPolicy.Entry("com.spotify.music", "Spotify", true),
            new AppDrawerPolicy.Entry("com.foo.svc", "Foo Service", false),   // no launch intent
            new AppDrawerPolicy.Entry("org.vibebaking.launcher", "Vibe Launcher", true),
            new AppDrawerPolicy.Entry("com.android.launcher3", "Launcher3", true),
            new AppDrawerPolicy.Entry("android.microntek.service", "HCT Manager", false),
            new AppDrawerPolicy.Entry("com.android.settings", "Settings", true),
            new AppDrawerPolicy.Entry("com.microntek.radio", "Radio", true),
            new AppDrawerPolicy.Entry("aaa.app", "aaa", true));               // lowercase label test
        Set<String> home = Set.of("org.vibebaking.launcher", "com.android.launcher3");
        List<String> full = labels(AppDrawerPolicy.visible(all, false, Set.of(), home));
        check("U18.alpha", full.equals(Arrays.asList("aaa", "Google Maps", "Radio", "Settings", "Spotify", "Waze")));
        check("U18.noService", !full.contains("Foo Service"));      // services are not apps
        check("U18.noHomeApps", !full.contains("Vibe Launcher") && !full.contains("Launcher3")); // S2b
        check("U18.noProtected", !full.contains("HCT Manager"));
        List<String> valet = labels(AppDrawerPolicy.visible(all, true, Set.of(), home));
        check("U18.valetAllowed", valet.equals(Arrays.asList("Google Maps", "Radio")));
        check("U18.valetNoSettings", !valet.contains("Settings"));
        check("U18.valetExtras", labels(AppDrawerPolicy.visible(all, true, Set.of("com.spotify.music"), home))
            .contains("Spotify"));
        // The nav app the map card aims at is always allowed in valet (S21/S7): Waze would otherwise
        // be suspended and blank the map card.
        Set<String> withWazeTarget = ValetPolicy.withMapTarget(Set.of(), MapTargetPolicy.WAZE);
        check("U18.valetMapTarget", labels(AppDrawerPolicy.visible(all, true, withWazeTarget, home))
            .equals(Arrays.asList("Google Maps", "Radio", "Waze")));
        check("U18.mapTargetNull", labels(AppDrawerPolicy.visible(all, true,
            ValetPolicy.withMapTarget(Set.of(), null), home)).equals(Arrays.asList("Google Maps", "Radio")));
        check("U18.grid4x3", AppDrawerPolicy.GRID_COLUMNS == 4 && AppDrawerPolicy.GRID_ROWS == 3
            && AppDrawerPolicy.PAGE_SIZE == 12);
        check("U18.pages", AppDrawerPolicy.pageCount(12) == 1 && AppDrawerPolicy.pageCount(13) == 2
            && AppDrawerPolicy.pageCount(0) == 0);
        check("U18.rows", AppDrawerPolicy.rowCount(12) == 3 && AppDrawerPolicy.rowCount(13) == 4);
        check("U18.empty", AppDrawerPolicy.visible(List.of(), false, Set.of(), Set.of()).isEmpty());
        check("U18.nullSafe", AppDrawerPolicy.visible(null, true, null, null).isEmpty());
        // queryIntentActivities(LAUNCHER) can return several launch activities per package:
        // the drawer de-duplicates to one cell per package (Round 3 enumeration fix).
        List<AppDrawerPolicy.Entry> dup = AppDrawerPolicy.dedupe(Arrays.asList(
            new AppDrawerPolicy.Entry("com.waze", "Waze", true),
            new AppDrawerPolicy.Entry("com.waze", "Waze Route", true),
            new AppDrawerPolicy.Entry("com.spotify.music", "Spotify", true),
            null,
            new AppDrawerPolicy.Entry(null, "No package", true)));
        check("U18.dedupe", dup.size() == 2 && dup.get(0).pkg.equals("com.waze") && dup.get(0).label.equals("Waze")
            && dup.get(1).pkg.equals("com.spotify.music"), "first occurrence wins: junk entries dropped");
        check("U18.dedupeNull", AppDrawerPolicy.dedupe(null).isEmpty());
    }

    // U19: trusted-phone verdicts (spec S25/S26/S26a), both sources.
    static void t19PhonePolicy() {
        check("U19.androidDead", PhonePolicy.decideAndroid(false, 5, 1, false) == PhonePresence.UNKNOWN);
        check("U19.androidFailed", PhonePolicy.decideAndroid(true, 5, 1, true) == PhonePresence.UNKNOWN);
        check("U19.androidConnected", PhonePolicy.decideAndroid(true, 1, 1, false) == PhonePresence.PRESENT);
        check("U19.androidPairedAway", PhonePolicy.decideAndroid(true, 2, 0, false) == PhonePresence.NONE);

        // HCT: no broadcast seen yet -> UNKNOWN (never auto-enter, never exit).
        check("U19.hctSilent", PhonePolicy.decideHct(false, false, false, false) == PhonePresence.UNKNOWN);
        check("U19.hctConnected", PhonePolicy.decideHct(true, true, true, true) == PhonePresence.PRESENT);
        check("U19.hctDisconnected", PhonePolicy.decideHct(true, false, true, true) == PhonePresence.NONE);
        check("U19.hctOpenedNoPair", PhonePolicy.decideHct(true, false, true, false) == PhonePresence.NONE);
        check("U19.hctPairedOnly", PhonePolicy.decideHct(true, false, false, true) == PhonePresence.NONE);

        // Combination: HCT wins when informative (it is the real BT on this unit); Android is the
        // fallback; two UNKNOWNs stay UNKNOWN.
        check("U19.combineHctWins", PhonePolicy.combine(PhonePresence.NONE, PhonePresence.PRESENT) == PhonePresence.NONE);
        check("U19.combineAndroidFallback", PhonePolicy.combine(PhonePresence.UNKNOWN, PhonePresence.PRESENT) == PhonePresence.PRESENT);
        check("U19.combineBothUnknown", PhonePolicy.combine(PhonePresence.UNKNOWN, PhonePresence.UNKNOWN) == PhonePresence.UNKNOWN);
        check("U19.combineNullSafe", PhonePolicy.combine(null, null) == PhonePresence.UNKNOWN);
        check("U19.combineNullHct", PhonePolicy.combine(null, PhonePresence.NONE) == PhonePresence.NONE);

        // Auto-entry / exit rules (S25/S26) and the exit-path guard (S26a).
        check("U19.autoEntryOnlyNone", PhonePolicy.autoEntryWanted(PhonePresence.NONE)
            && !PhonePolicy.autoEntryWanted(PhonePresence.PRESENT)
            && !PhonePolicy.autoEntryWanted(PhonePresence.UNKNOWN));
        check("U19.exitOnlyPresent", PhonePolicy.exitWanted(PhonePresence.PRESENT)
            && !PhonePolicy.exitWanted(PhonePresence.NONE) && !PhonePolicy.exitWanted(PhonePresence.UNKNOWN));
        check("U19.exitPathPairedAway", PhonePolicy.exitPathAvailable(PhonePresence.NONE, true));
        check("U19.exitPathConnected", PhonePolicy.exitPathAvailable(PhonePresence.PRESENT, false));
        check("U19.noExitPath", !PhonePolicy.exitPathAvailable(PhonePresence.UNKNOWN, false));
        check("U19.entryNeedsExitPath", !ValetPolicy.entryAllowed(true, false, false)
            && ValetPolicy.entryAllowed(true, true, false)
            && ValetPolicy.entryAllowed(true, false, true));
        check("U19.replayExitsWhenPathLost",
            ValetPolicy.replayAction(true, true, false, false) == ValetPolicy.Replay.EXIT
            && ValetPolicy.replayAction(true, true, false, true) == ValetPolicy.Replay.APPLY);
        check("U19.addressHeuristic", PhonePolicy.parseDeviceList("AA:BB:CC:DD:EE:FF") == 1
            && PhonePolicy.parseDeviceList("iPhone 15") == 0);
        // HCT pair list as stored by saveList() -> Settings.System (newline-separated entries).
        check("U19.listOneAddress", PhonePolicy.parseDeviceList("AA:BB:CC:DD:EE:FF") == 1);
        check("U19.listTwoAddresses", PhonePolicy.parseDeviceList("aa:bb:cc:dd:ee:ff\n112233445566") == 2);
        check("U19.listNameWithAddress", PhonePolicy.parseDeviceList("Daan's Phone,AA:BB:CC:DD:EE:FF") == 1);
        check("U19.listNamesOnly", PhonePolicy.parseDeviceList("iPhone 15\nSamsung Galaxy") == 0);
        check("U19.listShortJunk", PhonePolicy.parseDeviceList("aa:bb:cc\ndeadbeefnothex") == 0);
        check("U19.listEmptyNull", PhonePolicy.parseDeviceList(null) == 0 && PhonePolicy.parseDeviceList("") == 0);
        // Paired list without any broadcast yet is still informative (phone paired but away).
        check("U19.pairedListWithoutBroadcast", PhonePolicy.decideHct(true, false, false, true) == PhonePresence.NONE
            && PhonePolicy.exitPathAvailable(PhonePolicy.decideHct(true, false, false, true), true));
    }

    // U20: BOTH phone sources are consulted, and one being unavailable must not break the other
    // or crash (spec S25/S26/S36).
    static void t20CombinedPhoneProbe() {
        CombinedPhoneProbe both = new CombinedPhoneProbe(
            new StubPhone(PhonePresence.NONE, true), new StubPhone(PhonePresence.PRESENT, true));
        check("U20.hctWins", both.probe() == PhonePresence.NONE);
        check("U20.pairedListSeen", both.trustedPhoneConfigured());

        CombinedPhoneProbe hctDead = new CombinedPhoneProbe(new ThrowingPhone(), new StubPhone(PhonePresence.PRESENT, true));
        check("U20.hctDeadAndroidAnswers", hctDead.probe() == PhonePresence.PRESENT);
        check("U20.hctDeadExitStillWorks", PhonePolicy.exitWanted(hctDead.probe()));
        check("U20.pairedListFromAndroid", hctDead.trustedPhoneConfigured());

        CombinedPhoneProbe androidDead = new CombinedPhoneProbe(new StubPhone(PhonePresence.NONE, true), new ThrowingPhone());
        check("U20.androidDeadHctAnswers", androidDead.probe() == PhonePresence.NONE);
        check("U20.androidDeadAutoEntryStillArmed", PhonePolicy.autoEntryWanted(androidDead.probe()));

        CombinedPhoneProbe bothDead = new CombinedPhoneProbe(new ThrowingPhone(), new ThrowingPhone());
        check("U20.bothDeadUnknown", bothDead.probe() == PhonePresence.UNKNOWN);
        check("U20.bothDeadNoPairKnowledge", !bothDead.trustedPhoneConfigured());
        check("U20.bothDeadInert", !PhonePolicy.autoEntryWanted(bothDead.probe())
            && !PhonePolicy.exitWanted(bothDead.probe()));
        check("U20.bothDeadNoExitPath", !PhonePolicy.exitPathAvailable(bothDead.probe(), bothDead.trustedPhoneConfigured()));
        check("U20.nullSourcesSafe", new CombinedPhoneProbe(null, null).probe() == PhonePresence.UNKNOWN);
        check("U20.nullConfiguredSafe", !new CombinedPhoneProbe(null, null).trustedPhoneConfigured());
        check("U20.nullProbeValueSafe", new CombinedPhoneProbe(new StubPhone(null, false), null).probe() == PhonePresence.UNKNOWN);
        // Teardown must never throw either, even when a source blows up.
        bothDead.release();
        new CombinedPhoneProbe(new ThrowingReleasePhone(), null).release();
        check("U20.releaseSafe", true);
    }

    static class StubPhone implements PhonePresenceProbe {
        private final PhonePresence v; private final boolean paired;
        StubPhone(PhonePresence v, boolean paired) { this.v = v; this.paired = paired; }
        @Override public PhonePresence probe() { return v; }
        @Override public boolean trustedPhoneConfigured() { return paired; }
    }

    static class ThrowingPhone implements PhonePresenceProbe {
        @Override public PhonePresence probe() { throw new IllegalStateException("BT service gone"); }
        @Override public boolean trustedPhoneConfigured() { throw new SecurityException("no BT permission"); }
    }

    static class ThrowingReleasePhone implements PhonePresenceProbe {
        @Override public PhonePresence probe() { return PhonePresence.UNKNOWN; }
        @Override public void release() { throw new IllegalStateException("proxy already closed"); }
    }

    // U21: bottom favourite row (spec S40/S40a/S40b/S40c).
    static void t21FavoriteRow() {
        check("U21.slots", FavoritePolicy.MAX_SLOTS == 4);
        check("U21.defaultPhoneSlot", FavoritePolicy.defaults().equals(Arrays.asList(
            "com.microntek.bluetooth", "", "", "")), "slot 0 ships preinstalled with the HCT dialler");
        check("U21.nullDefaults", FavoritePolicy.slots(null).equals(FavoritePolicy.defaults()));
        check("U21.blankDefaults", FavoritePolicy.slots("").equals(FavoritePolicy.defaults()));
        check("U21.junkPresentHonoured", FavoritePolicy.slots("   ,, , ").equals(Arrays.asList("", "", "", "")),
            "a present-but-empty pref means the owner cleared every slot: stay empty, do not re-add the phone app");
        check("U21.parsed", FavoritePolicy.slots("com.waze,,,com.microntek.radio")
            .equals(Arrays.asList("com.waze", "", "", "com.microntek.radio")),
            "CSV fields are literal slot positions: field 3 lands in slot 3, extra fields are ignored");
        check("U21.dedupeFirst", FavoritePolicy.slots("com.waze,com.waze,com.spotify.music")
            .equals(Arrays.asList("com.waze", "", "com.spotify.music", "")), "duplicate collapses its later slot");
        check("U21.capped", FavoritePolicy.slots("a,b,c,d,e").equals(Arrays.asList("a", "b", "c", "d")));
        check("U21.csvRoundTrip", FavoritePolicy.csv(Arrays.asList("a", "", "", "b")).equals("a,,,b")
            && FavoritePolicy.slots("a,,,b").equals(Arrays.asList("a", "", "", "b")));

        List<String> def = FavoritePolicy.defaults();
        check("U21.assignFirstEmpty", FavoritePolicy.assign(def, "com.waze")
            .equals(Arrays.asList("com.microntek.bluetooth", "com.waze", "", "")));
        check("U21.assignFullReplacesPrimary", FavoritePolicy.assign(
            Arrays.asList("a", "b", "c", "d"), "com.waze").equals(Arrays.asList("com.waze", "b", "c", "d")));
        check("U21.assignDedupe", FavoritePolicy.assign(def, "com.microntek.bluetooth").equals(def)
            && FavoritePolicy.assign(Arrays.asList("com.waze", "", "", ""), "com.waze")
                .equals(Arrays.asList("com.waze", "", "", "")),
            "pinning an app that is already pinned keeps it where it is (no double pin, no shift)");
        check("U21.assignBlankNoop", FavoritePolicy.assign(def, "").equals(def)
            && FavoritePolicy.assign(def, null).equals(def));
        check("U21.clearSlot", FavoritePolicy.clear(def, 0).equals(Arrays.asList("", "", "", "")));
        check("U21.clearOutOfRange", FavoritePolicy.clear(def, 9).equals(def)
            && FavoritePolicy.clear(def, -1).equals(def));

        // Visibility: a removed app collapses to an empty slot (row stays aligned, S40).
        List<String> row = Arrays.asList("com.microntek.bluetooth", "com.waze", "", "");
        Set<String> gone = Set.of("com.microntek.bluetooth"); // only the phone app is launchable
        List<String> v = FavoritePolicy.visible(row, false, null, gone);
        check("U21.goneCollapsed", v.equals(Arrays.asList("com.microntek.bluetooth", "", "", ""))
            && v.size() == FavoritePolicy.MAX_SLOTS, "uninstalled favourite must not shift the row");
        // Valet (S40b): the phone app is allowed (owner list); Waze without extras is hidden.
        List<String> vv = FavoritePolicy.visible(row, true, ValetPolicy.allowedSet(Set.of()), gone);
        check("U21.valetPhoneKept", vv.equals(Arrays.asList("com.microntek.bluetooth", "", "", "")));
        List<String> vvWaze = FavoritePolicy.visible(row, true,
            ValetPolicy.allowedSet(ValetPolicy.withMapTarget(Set.of(), MapTargetPolicy.WAZE)),
            Set.of("com.microntek.bluetooth", "com.waze"));
        check("U21.valetNavKept", vvWaze.equals(Arrays.asList("com.microntek.bluetooth", "com.waze", "", "")),
            "the map card's nav app stays allowed, so its pinned slot stays visible");
        List<String> nullSafe = FavoritePolicy.visible(null, true, null, null);
        check("U21.visibleNullSafe", nullSafe.size() == FavoritePolicy.MAX_SLOTS
            && nullSafe.get(0).equals(FavoritePolicy.PHONE_PACKAGE));

        // Glyphs + BT dialer tab (S40a).
        check("U21.glyphPhone", FavoritePolicy.glyph(FavoritePolicy.PHONE_PACKAGE).equals("☎"));
        check("U21.glyphEmpty", FavoritePolicy.glyph("").equals("＋") && FavoritePolicy.glyph(null).equals("＋"));
        check("U21.glyphRadio", FavoritePolicy.glyph("com.microntek.radio").equals("♫"));
        check("U21.glyphCamera", FavoritePolicy.glyph("com.microntek.backview").equals("◉")
            && FavoritePolicy.glyph("com.microntek.frontview").equals("◉"));
        check("U21.glyphNav", FavoritePolicy.glyph(MapTargetPolicy.MAPS).equals("✥")
            && FavoritePolicy.glyph(MapTargetPolicy.WAZE).equals("✥"));
        check("U21.glyphOther", FavoritePolicy.glyph("com.spotify.music").equals("▣"));
        check("U21.tabExtra", FavoritePolicy.BT_TAB_EXTRA.equals("curTab") && FavoritePolicy.dialTab(0) == 0);
        check("U21.tabClamp", FavoritePolicy.dialTab(-5) == 0 && FavoritePolicy.dialTab(7) == FavoritePolicy.BT_TAB_MAX);
        check("U21.isPhoneSlot", FavoritePolicy.isPhoneSlot(FavoritePolicy.PHONE_PACKAGE)
            && !FavoritePolicy.isPhoneSlot("com.waze"));
        check("U21.sortedNullSafe", FavoritePolicy.sorted(null).isEmpty()
            && FavoritePolicy.sorted(Arrays.asList("b", "", "a")).equals(Arrays.asList("a", "b")));
    }

    // U23: home/radar position choice (Round 3): newest of several fixes wins, default when none,
    // the radar recentres only when the position moved more than 5 km.
    static void t22RadarPosition() {
        RadarPosition.Fix older = new RadarPosition.Fix(52.10, 5.18, 1_000L);   // De Bilt known fix
        RadarPosition.Fix newer = new RadarPosition.Fix(52.35, 4.86, 2_000L);   // fresher GPS fix
        RadarPosition.Fix junk = new RadarPosition.Fix(Double.NaN, 5.18, 9_000L); // absurd, newest
        double[] def = new double[] { SettingsKeys.DEFAULT_LAT, SettingsKeys.DEFAULT_LON };
        check("U23.newestWins", RadarPosition.choose(Arrays.asList(older, newer), def)[0] == 52.35
            && RadarPosition.choose(Arrays.asList(older, newer), def)[1] == 4.86);
        check("U23.newestOrderIndependent", RadarPosition.choose(Arrays.asList(newer, older), def)[0] == 52.35);
        check("U23.junkIgnored", RadarPosition.choose(Arrays.asList(newer, junk), def)[0] == 52.35
            && RadarPosition.choose(Arrays.asList(junk), def)[0] == def[0] && RadarPosition.choose(Arrays.asList(junk), def)[1] == def[1],
            "a NaN GPS fix must never override a good one nor the default");
        check("U23.noneDefault", Arrays.equals(RadarPosition.choose(null, def), def)
            && Arrays.equals(RadarPosition.choose(List.of(), def), def));
        check("U23.farMove", RadarPosition.movedFar(52.10, 5.18, 52.35, 4.86, RadarPosition.RECENTRE_METERS),
            "De Bilt -> Amsterdam is ~30 km: recentre");
        check("U23.nearStay", !RadarPosition.movedFar(52.10, 5.18, 52.14, 5.20, RadarPosition.RECENTRE_METERS),
            "~4.6 km of drift is inside the 5 km band: do not recentre");
        check("U23.unknownRecentres", RadarPosition.movedFar(Double.NaN, Double.NaN, 52.10, 5.18, RadarPosition.RECENTRE_METERS),
            "no previous position (NaN) must take the first fix");

        // U24 map card compact mode (owner 2026-11-25): hide Maps' tab bar only while idle and not navigating.
        check("U24.idleCompact", MapCardPolicy.compact(false, Long.MAX_VALUE), "never touched, not navigating -> compact");
        check("U24.touchedFull", !MapCardPolicy.compact(false, 1000L), "touched 1 s ago -> full (route preview Start button)");
        check("U24.idleBoundary", MapCardPolicy.compact(false, MapCardPolicy.IDLE_MS) && !MapCardPolicy.compact(false, MapCardPolicy.IDLE_MS - 1));
        check("U24.navFull", !MapCardPolicy.compact(true, Long.MAX_VALUE), "navigating -> always the full UI");
        check("U24.cropPx", MapCardPolicy.cropPx(160) == 68 && MapCardPolicy.cropPx(192) == 82);

        // U25 HCT radio on the media card (owner 2026-11-26)
        check("U25.channelFm", RadioState.isRadioChannel("fm") && RadioState.isRadioChannel(" FM ")
            && !RadioState.isRadioChannel("bt") && !RadioState.isRadioChannel(null) && !RadioState.isRadioChannel(""));
        check("U25.formatFm", RadioState.formatFreq(100350).equals("100.35 MHz") && RadioState.formatFreq(87500).equals("87.50 MHz"));
        check("U25.formatAm", RadioState.formatFreq(1008).equals("1008 kHz") && RadioState.formatFreq(0).equals(""));
        check("U25.psnDecode", RadioState.decodePsn("RADIO 2 ".getBytes(java.nio.charset.StandardCharsets.ISO_8859_1)).equals("RADIO 2")
            && RadioState.decodePsn(new byte[]{0x51, 0x2D, 0x6D, 0x75, 0x73, 0x69, 0x63, 0x00}).equals("Q-music")
            && RadioState.decodePsn(null).equals("") && RadioState.decodePsn(new byte[]{0, 0, 0}).equals(""));
        RadioState rs = new RadioState();
        check("U25.titleUnknown", rs.title().equals("Radio") && rs.subtitle().equals(""));
        rs.setFreq(100350);
        check("U25.titleFreq", rs.title().equals("100.35 MHz") && rs.subtitle().equals("FM"), "no RDS: frequency as title");
        rs.psn = "SKYRADIO";
        check("U25.titlePsn", rs.title().equals("SKYRADIO") && rs.subtitle().equals("FM 100.35 MHz"), "RDS name as title");
        rs.setFreq(100350);
        check("U25.sameFreqKeepsPsn", rs.psn.equals("SKYRADIO"));
        rs.setFreq(101200);
        check("U25.newFreqClearsPsn", rs.psn.isEmpty() && rs.title().equals("101.20 MHz"));
        check("U25.normalize", RadioState.normalizeKhz(10135) == 101350 && RadioState.normalizeKhz(100350) == 100350
            && RadioState.normalizeKhz(8750) == 87500 && RadioState.normalizeKhz(1008) == 1008 && RadioState.normalizeKhz(0) == 0,
            "radio app fre=10135 (10 kHz steps, measured) and MCU kHz both become kHz; AM stays kHz");
        rs.setFreq(10135);
        check("U25.fre10k", rs.title().equals("101.35 MHz") && rs.subtitle().equals("FM"), "first unit run showed 10135 kHz AM");
    }

    // U26-U29: engine gauge colour policy + rpm parsing (owner request 2026-11-27):
    // every band boundary of the EngineGauges tables, and the junk-tolerant rpm extra.
    static void t23EngineGauges() {
        check("U26.badLow", EngineGauges.batteryLevel(11.49) == EngineGauges.Level.BAD);
        check("U26.warnLow", EngineGauges.batteryLevel(11.5) == EngineGauges.Level.WARN
            && EngineGauges.batteryLevel(11.99) == EngineGauges.Level.WARN);
        check("U26.okBand", EngineGauges.batteryLevel(12.0) == EngineGauges.Level.OK
            && EngineGauges.batteryLevel(14.8) == EngineGauges.Level.OK,
            "12.0 and 14.8 are inclusive OK (charging tops out at 14.7 V)");
        check("U26.warnHigh", EngineGauges.batteryLevel(14.81) == EngineGauges.Level.WARN
            && EngineGauges.batteryLevel(15.2) == EngineGauges.Level.WARN);
        check("U26.badHigh", EngineGauges.batteryLevel(15.21) == EngineGauges.Level.BAD);
        check("U26.nanBad", EngineGauges.batteryLevel(Double.NaN) == EngineGauges.Level.BAD,
            "junk voltage must read BAD, never OK");
        check("U27.coolCold", EngineGauges.coolantLevel(69) == EngineGauges.Level.COLD);
        check("U27.coolOk", EngineGauges.coolantLevel(70) == EngineGauges.Level.OK
            && EngineGauges.coolantLevel(104) == EngineGauges.Level.OK);
        check("U27.coolWarn", EngineGauges.coolantLevel(105) == EngineGauges.Level.WARN
            && EngineGauges.coolantLevel(114) == EngineGauges.Level.WARN);
        check("U27.coolBad", EngineGauges.coolantLevel(115) == EngineGauges.Level.BAD);
        check("U28.oilCold", EngineGauges.oilLevel(69) == EngineGauges.Level.COLD);
        check("U28.oilOk", EngineGauges.oilLevel(70) == EngineGauges.Level.OK
            && EngineGauges.oilLevel(124) == EngineGauges.Level.OK,
            "load spikes to ~125 are fine on this engine: 124 stays OK");
        check("U28.oilWarn", EngineGauges.oilLevel(125) == EngineGauges.Level.WARN
            && EngineGauges.oilLevel(134) == EngineGauges.Level.WARN);
        check("U28.oilBad", EngineGauges.oilLevel(135) == EngineGauges.Level.BAD);
        check("U29.parsePlain", EngineGauges.parseRpm("2150") == 2150);
        check("U29.parseSpaces", EngineGauges.parseRpm(" 800 ") == 800, "the extra is trimmed");
        check("U29.junk", EngineGauges.parseRpm("-1") == null && EngineGauges.parseRpm("abc") == null
            && EngineGauges.parseRpm("12000") == null && EngineGauges.parseRpm(null) == null,
            "negative / non-numeric / >9000 / missing extras all yield null, never a throw");
        check("U29.bounds", EngineGauges.parseRpm("0") == 0 && EngineGauges.parseRpm("9000") == 9000
            && EngineGauges.parseRpm("9001") == null);
        check("U29.floatJunk", EngineGauges.parseRpm("2150.0") == null && EngineGauges.parseRpm("") == null,
            "parseInt rejects decimals and blanks: the gauge stays hidden");
    }

    // U30/U31: settings cycle + percent band helpers (Round 6 fix for the stuck rows).
    static void t24SettingsCycle() {
        String[] dm = {"cycle", "always_light", "always_dark", "car_lights"};
        String cur = "cycle";
        List<String> seen = new ArrayList<>();
        for (int i = 0; i < 6; i++) { cur = SettingsCycle.next(dm, cur); seen.add(cur); }
        check("U30.walk", seen.equals(Arrays.asList("always_light", "always_dark", "car_lights",
            "cycle", "always_light", "always_dark")),
            "repeated application must walk every value and wrap - the old bug wrote the same value twice");
        check("U30.unknownFirst", SettingsCycle.next(dm, "garbage").equals("cycle")
            && SettingsCycle.next(dm, null).equals("cycle"), "unknown current -> first value");
        check("U30.emptySafe", SettingsCycle.next(new String[0], "x") == null
            && SettingsCycle.next(null, "x") == null, "empty/null value list never throws");
        check("U30.indexOf", SettingsCycle.indexOf(dm, "car_lights") == 3 && SettingsCycle.indexOf(dm, "nope") == -1);
        int[] band = {20, 40, 60, 80};
        check("U31.intWalk", SettingsCycle.next(band, 20) == 40 && SettingsCycle.next(band, 80) == 20,
            "int cycle wraps too");
        check("U31.intUnknown", SettingsCycle.next(band, 55) == 20 && SettingsCycle.next(band, -3) == 20);
        check("U31.intEmptySafe", SettingsCycle.next(new int[0], 7) == 7 && SettingsCycle.next(null, 7) == 7,
            "nothing to cycle to: stay at the current value");
        check("U31.nearest", SettingsCycle.nearest(band, 55) == 2 && SettingsCycle.nearest(band, 3) == 0
            && SettingsCycle.nearest(band, 100) == 3, "garbage stored percent snaps the SeekBar to the nearest band value");
        check("U31.nearestEdge", SettingsCycle.nearest(new int[0], 5) == 0
            && SettingsCycle.nearest(band, Integer.MIN_VALUE) == 0
            && SettingsCycle.nearest(band, Integer.MAX_VALUE) == 3,
            "no long-math overflow on absurd stored values");
    }

    // U32/U33: PIN + timeout validation for the styled number fields (Round 6).
    static void t25SettingsValidation() {
        check("U32.pinOk", SettingsValidation.validPin("4321") && SettingsValidation.validPin("000042")
            && SettingsValidation.validPin(" 4321 "), "4-6 digits ok, trimmed");
        check("U32.pinShort", !SettingsValidation.validPin("123") && !SettingsValidation.validPin("")
            && !SettingsValidation.validPin(null) && !SettingsValidation.validPin("   "),
            "PIN shorter than 4 digits must be refused");
        check("U32.pinLong", !SettingsValidation.validPin("1234567"));
        check("U32.pinJunk", !SettingsValidation.validPin("12ab") && !SettingsValidation.validPin("1 2 3 4")
            && !SettingsValidation.validPin("43.21"));
        check("U33.timeoutBounds", SettingsValidation.timeoutOk(10) && SettingsValidation.timeoutOk(60)
            && SettingsValidation.timeoutOk(3600), "10..3600 inclusive");
        check("U33.timeoutOut", !SettingsValidation.timeoutOk(9) && !SettingsValidation.timeoutOk(3601)
            && !SettingsValidation.timeoutOk(-5) && !SettingsValidation.timeoutOk(Integer.MAX_VALUE)
            && !SettingsValidation.timeoutOk(Integer.MIN_VALUE));
        check("U33.parse", SettingsValidation.parseTimeout("60").equals(60)
            && SettingsValidation.parseTimeout(" 90 ") == 90, "trimmed parse");
        check("U33.parseJunk", SettingsValidation.parseTimeout(null) == null
            && SettingsValidation.parseTimeout("abc") == null && SettingsValidation.parseTimeout("") == null
            && SettingsValidation.parseTimeout("2147483648") == null, "overflow yields null, never a throw");
        check("U33.mirrorsKeys", SettingsValidation.TIMEOUT_MIN_S == 10 && SettingsValidation.TIMEOUT_MAX_S == 3600
            && SettingsKeys.clampTimeoutS(9) == 10 && SettingsKeys.clampTimeoutS(3601) == 3600,
            "the inline error band mirrors SettingsKeys.clampTimeoutS");
    }

    // U34-U38: weather icon policy (owner 2026-11-27) - WMO code + is_day, temperature format,
    // Open-Meteo JSON, the com.canbus.temperature parser, the 10-minute preference and privacy rounding.
    static void t26WeatherIcon() {
        // U34: the owner's table, day and night, plus the unknown-code fallback and drawable names.
        check("U34.clear", WeatherIcon.iconFor(0, true) == WeatherIcon.Icon.SUN
            && WeatherIcon.iconFor(1, true) == WeatherIcon.Icon.SUN
            && WeatherIcon.iconFor(0, false) == WeatherIcon.Icon.MOON
            && WeatherIcon.iconFor(1, false) == WeatherIcon.Icon.MOON);
        check("U34.partlyCloudy", WeatherIcon.iconFor(2, true) == WeatherIcon.Icon.SUN_CLOUD
            && WeatherIcon.iconFor(2, false) == WeatherIcon.Icon.MOON_CLOUD,
            "code 2 has its own night glyph (moon behind cloud)");
        check("U34.overcast", WeatherIcon.iconFor(3, true) == WeatherIcon.Icon.CLOUD
            && WeatherIcon.iconFor(3, false) == WeatherIcon.Icon.CLOUD);
        check("U34.fog", WeatherIcon.iconFor(45, true) == WeatherIcon.Icon.FOG
            && WeatherIcon.iconFor(48, false) == WeatherIcon.Icon.FOG,
            "fog (45) and glaze fog (48) - the codes VAG regions actually get");
        check("U34.drizzleRain", codesAll(WeatherIcon.Icon.RAIN, new int[] { 51, 53, 55, 56, 57, 61, 80 }),
            "drizzle + light rain + rain showers, day and night");
        check("U34.pouring", codesAll(WeatherIcon.Icon.POURING, new int[] { 63, 65, 66, 67, 81, 82 }),
            "moderate/heavy drizzle and rain, day and night");
        check("U34.snow", codesAll(WeatherIcon.Icon.SNOW, new int[] { 71, 73, 75, 77, 85, 86 }),
            "snow fall/blizzard and snow showers, day and night");
        check("U34.thunder", codesAll(WeatherIcon.Icon.THUNDER, new int[] { 95, 96, 99 }),
            "thunder with and without hail");
        check("U34.unknownFallsBackToCloud", WeatherIcon.iconFor(4, true) == WeatherIcon.Icon.CLOUD
            && WeatherIcon.iconFor(-1, false) == WeatherIcon.Icon.CLOUD
            && WeatherIcon.iconFor(9999, true) == WeatherIcon.Icon.CLOUD,
            "an unlisted code must stay neutral, never crash");
        check("U34.drawableNames", WeatherIcon.drawableName(WeatherIcon.Icon.SUN).equals("ic_wx_sun")
            && WeatherIcon.drawableName(WeatherIcon.Icon.MOON).equals("ic_wx_moon")
            && WeatherIcon.drawableName(WeatherIcon.Icon.SUN_CLOUD).equals("ic_wx_sun_cloud")
            && WeatherIcon.drawableName(WeatherIcon.Icon.MOON_CLOUD).equals("ic_wx_moon_cloud")
            && WeatherIcon.drawableName(WeatherIcon.Icon.CLOUD).equals("ic_wx_cloud")
            && WeatherIcon.drawableName(WeatherIcon.Icon.FOG).equals("ic_wx_fog")
            && WeatherIcon.drawableName(WeatherIcon.Icon.RAIN).equals("ic_wx_rain")
            && WeatherIcon.drawableName(WeatherIcon.Icon.POURING).equals("ic_wx_pouring")
            && WeatherIcon.drawableName(WeatherIcon.Icon.SNOW).equals("ic_wx_snow")
            && WeatherIcon.drawableName(WeatherIcon.Icon.THUNDER).equals("ic_wx_thunder"),
            "the names must match the drawables the parent engineer added");
        check("U34.everyIconNamed", WeatherIcon.drawableName(WeatherIcon.Icon.CLOUD) != null
            && WeatherIcon.drawableName(WeatherIcon.Icon.THUNDER) != null);

        // U35: whole degrees only, and "-0°" must never appear.
        check("U35.roundDown", WeatherIcon.formatTemp(8.3).equals("8\u00B0"));
        check("U35.noMinusZero", WeatherIcon.formatTemp(-0.4).equals("0\u00B0")
            && WeatherIcon.formatTemp(-0.5).equals("0\u00B0"),
            "-0.4 rounds to 0: the sign must not be printed");
        check("U35.roundAwayFromZero", WeatherIcon.formatTemp(-3.6).equals("-4\u00B0"));
        check("U35.roundHalfUp", WeatherIcon.formatTemp(2.5).equals("3\u00B0"));
        check("U35.numeric", WeatherIcon.formatTemp(12.49).equals("12\u00B0")
            && WeatherIcon.formatTemp(-12.6).equals("-13\u00B0")
            && WeatherIcon.formatTemp(0.0).equals("0\u00B0"),
            "the decimal is never shown");
        check("U35.notANumber", WeatherIcon.formatTemp(Double.NaN).equals("")
            && WeatherIcon.formatTemp(Double.POSITIVE_INFINITY).equals("")
            && WeatherIcon.formatTemp(Double.NEGATIVE_INFINITY).equals(""),
            "garbage reading: nothing is painted, the chip stays hidden");

        // U36: Open-Meteo `current` block, exactly the shape the parent engineer verified.
        String sample = "{\"current\":{\"temperature_2m\":8.3,\"weather_code\":3,\"is_day\":1,"
            + "\"time\":\"2026-11-27T12:00\",\"utc_offset_seconds\":3600},\"hourly\":{}}";
        WeatherIcon.Reading r = WeatherIcon.parseCurrent(sample);
        check("U36.sample", r != null && r.tempC == 8.3 && r.wmoCode == 3 && r.day == Boolean.TRUE, sample);
        String nightBody = "{\"current\":{\"temperature_2m\":-1.2,\"weather_code\":71,\"is_day\":0}}";
        WeatherIcon.Reading n = WeatherIcon.parseCurrent(nightBody);
        check("U36.night", n != null && n.tempC == -1.2 && n.wmoCode == 71 && n.day == Boolean.FALSE, nightBody);
        check("U36.booleanFlag", WeatherIcon.parseCurrent("{\"current\":{\"weather_code\":2,\"is_day\":true}}").day == Boolean.TRUE
            && WeatherIcon.parseCurrent("{\"current\":{\"weather_code\":2,\"is_day\":false}}").day == Boolean.FALSE,
            "a boolean is_day (some builds) parses too");
        check("U36.missingIsDay", WeatherIcon.parseCurrent("{\"current\":{\"temperature_2m\":5,\"weather_code\":1}}").day == null,
            "missing is_day -> null; the activity falls back to the theme's night decision");
        check("U36.missingFields", WeatherIcon.parseCurrent("{\"current\":{}}").tempC == null
            && WeatherIcon.parseCurrent("{\"current\":{}}").wmoCode == null,
            "empty current block: every field null, nothing painted");
        check("U36.noCurrent", WeatherIcon.parseCurrent("{\"hourly\":{\"temperature_2m\":[8.3]}}") == null,
            "no current block -> offline");
        check("U36.garbled", WeatherIcon.parseCurrent("{\"current\":{\"temperature_2m\":8.3") == null
            && WeatherIcon.parseCurrent("") == null && WeatherIcon.parseCurrent(null) == null,
            "truncated body / empty body -> null, never a throw");
        check("U36.htmlPage", WeatherIcon.parseCurrent("<html>429 Too Many Requests</html>") == null,
            "rate-limit HTML page -> offline, the last value stays");
        check("U36.wrongTypes", WeatherIcon.parseCurrent("{\"current\":{\"temperature_2m\":\"cold\",\"weather_code\":[]}}").tempC == null
            && WeatherIcon.parseCurrent("{\"current\":{\"temperature_2m\":\"cold\",\"weather_code\":[]}}").wmoCode == null,
            "string/array values are not numbers -> null fields");
        check("U36.currentNotAnObject", WeatherIcon.parseCurrent("{\"current\":[1,2]}") == null);

        // U37: com.canbus.temperature extra "temperature" - format UNKNOWN on a car, so the first
        // signed decimal anywhere in the string is used, and junk never throws.
        check("U37.plain", WeatherIcon.parseCanTemp("12.5") == 12.5 && WeatherIcon.parseCanTemp("-3") == -3.0);
        check("U37.padded", WeatherIcon.parseCanTemp(" -3 ") == -3.0 && WeatherIcon.parseCanTemp("  12.5 ") == 12.5);
        check("U37.unitSuffix", WeatherIcon.parseCanTemp("12.5\u00B0C") == 12.5
            && WeatherIcon.parseCanTemp("temp: 7.2 deg") == 7.2,
            "trailing unit text / prefix text: the first number wins");
        check("U37.plusSign", WeatherIcon.parseCanTemp("+8") == 8.0);
        check("U37.junk", WeatherIcon.parseCanTemp("abc") == null && WeatherIcon.parseCanTemp("") == null
            && WeatherIcon.parseCanTemp(null) == null && WeatherIcon.parseCanTemp("-") == null
            && WeatherIcon.parseCanTemp("NaN") == null && WeatherIcon.parseCanTemp("--3") == null,
            "unrecognised frame -> null, so Open-Meteo's value stays");

        // U38: the car sensor wins for 10 minutes; coordinates are rounded before the URL is built.
        long now = 1_700_000_000_000L;
        check("U38.freshCarWins", WeatherIcon.preferCarTemp(now - 60_000L, now)
            && WeatherIcon.preferCarTemp(now - 10 * 60_000L, now),
            "exactly 10 minutes still counts as fresh");
        check("U38.staleCarLoses", !WeatherIcon.preferCarTemp(now - 10 * 60_000L - 1, now)
            && !WeatherIcon.preferCarTemp(now - 40 * 60_000L, now),
            "older than 10 min: Open-Meteo's temperature is shown again");
        check("U38.clockJumpBack", WeatherIcon.preferCarTemp(now + 60_000L, now),
            "boot/NTP clock jump backwards: the frame is treated as fresh, not stale");
        check("U38.constants", WeatherIcon.REFRESH_MS == 15 * 60_000L && WeatherIcon.CAR_TEMP_FRESH_MS == 10 * 60_000L,
            "15-minute refresh while visible, 10-minute sensor preference");
        check("U38.round1", WeatherIcon.round1(52.109876) == 52.1 && WeatherIcon.round1(5.178) == 5.2
            && WeatherIcon.round1(-3.14159) == -3.1 && WeatherIcon.round1(0.05) == 0.1,
            "~10 km resolution (owner privacy rule)");
        String url = WeatherIcon.urlFor(52.109876, 5.178);
        check("U38.urlShape", url.equals("https://api.open-meteo.com/v1/forecast?latitude=52.1&longitude=5.2"
            + "&current=temperature_2m,weather_code,is_day"), url);
        check("U38.urlPrivacy", !url.contains("52.109") && !url.contains("5.178"),
            "full-precision coordinates must never appear in the URL");
        check("U38.urlNaNDefaults", WeatherIcon.urlFor(Double.NaN, Double.NaN).contains("latitude=52.1")
            && WeatherIcon.urlFor(Double.NaN, Double.NaN).contains("longitude=5.2"),
            "no position yet: the De Bilt default, rounded like everything else");
    }

    /** true when every listed WMO code maps to `want` by day and by night. */
    static boolean codesAll(WeatherIcon.Icon want, int[] codes) {
        for (int code : codes) {
            if (WeatherIcon.iconFor(code, true) != want || WeatherIcon.iconFor(code, false) != want) return false;
        }
        return true;
    }

    static List<String> labels(List<AppDrawerPolicy.Entry> e) {
        List<String> out = new ArrayList<>();
        for (AppDrawerPolicy.Entry x : e) out.add(x.label);
        return out;
    }
}
