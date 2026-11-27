package org.vibebaking.launcher.unit;

import com.sun.net.httpserver.HttpServer;
import org.vibebaking.launcher.HttpRadarFetcher;
import org.vibebaking.launcher.HttpWeatherFetcher;
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
import org.vibebaking.launcher.logic.MapTargetPolicy;
import org.vibebaking.launcher.logic.MediaCardPolicy;
import org.vibebaking.launcher.logic.PhonePolicy;
import org.vibebaking.launcher.logic.PhonePresence;
import org.vibebaking.launcher.logic.PhonePresenceProbe;
import org.vibebaking.launcher.logic.RadarFetcher;
import org.vibebaking.launcher.logic.RadarPlan;
import org.vibebaking.launcher.logic.RadarTiles;
import org.vibebaking.launcher.logic.SettingsCycle;
import org.vibebaking.launcher.logic.SettingsKeys;
import org.vibebaking.launcher.logic.SettingsValidation;
import org.vibebaking.launcher.logic.ThemePolicy;
import org.vibebaking.launcher.logic.ValetPin;
import org.vibebaking.launcher.logic.ValetPolicy;
import org.vibebaking.launcher.logic.VolumePolicy;
import org.vibebaking.launcher.logic.WeatherFetcher;
import org.vibebaking.launcher.logic.WeatherIcon;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Degradation smoke tests: failure scenarios that must never crash the home screen and must
 * degrade visibly (spec S18'/S37/S26a). One SG-id = one scenario; extra checks are SGxxb/c.
 * A FAIL is a real defect: it goes in CHANGELOG.md until fixed.
 */
public class Smoke {

    static int checks = 0;
    static final List<String> failures = new java.util.ArrayList<>();
    static final Map<String, String> titles = new java.util.LinkedHashMap<>();

    static void scenario(String sg, String title) { titles.put(sg, title); }

    static void check(String sg, boolean cond) {
        checks++;
        if (cond) System.out.println("PASS " + sg);
        else { failures.add(sg); System.out.println("FAIL " + sg + " — " + titles.getOrDefault(sg, "?")); }
    }

    /** Failure-note variant: the extra explanation is printed only when the check fails. */
    static void check(String sg, boolean cond, String why) {
        check(sg, cond);
        if (!cond) System.out.println("     why: " + why);
    }

    /** Stub fetcher: index URL (contains "weather-maps.json") answers apiBody; tile urls match tileBase. */
    static class Stub implements RadarFetcher {
        static final int OK = 0, TILES_FAIL_ALL = 1, TILES_FAIL_HALF = 2, API_FAIL = 3;
        String apiBody;
        String tileBase = "https://t/";
        int mode = OK;
        int tileAttempts = 0;

        Stub api(String body) { apiBody = body; return this; }
        Stub tiles(String base) { tileBase = base; return this; }
        Stub mode(int m) { mode = m; return this; }

        @Override public byte[] fetch(String url) throws Exception {
            if (url.contains("weather-maps.json")) {
                if (mode == API_FAIL || apiBody == null) throw new IOException("HTTP 404 api");
                return apiBody.getBytes(StandardCharsets.UTF_8);
            }
            String prefix = tileBase.indexOf('{') < 0 ? tileBase : tileBase.substring(0, tileBase.indexOf('{'));
            if (url.startsWith(prefix)) {
                tileAttempts++;
                if (mode == TILES_FAIL_ALL || (mode == TILES_FAIL_HALF && tileAttempts % 2 == 0))
                    throw new IOException("HTTP 500 tile");
                return "png-bytes".getBytes(StandardCharsets.UTF_8);
            }
            throw new IOException("unrouted " + url);
        }
    }

    /** Index body from a stub, tiles over real HTTP (HttpRadarFetcher against a local server). */
    static class Composite implements RadarFetcher {
        final String apiBody; final RadarFetcher tiles;
        Composite(String apiBody, RadarFetcher tiles) { this.apiBody = apiBody; this.tiles = tiles; }
        @Override public byte[] fetch(String url) throws Exception {
            if (url.contains("weather-maps.json")) return apiBody.getBytes(StandardCharsets.UTF_8);
            return tiles.fetch(url);
        }
    }

    /** weather-maps.json answer with one radar.past frame (the real API shape, verified live). */
    static String apiJson(String host, String path, long time) {
        return "{\"version\":\"2.0\",\"host\":\"" + host + "\",\"radar\":{\"past\":[{\"time\":"
            + time + ",\"path\":\"" + path + "\"}],\"nowcast\":[]}}";
    }

    static final String GOOD_API = apiJson("https://t", "/v2/radar/test", 1764073800L);

    public static void main(String[] args) throws Exception {
        radarOffline();
        radarHttp404();
        radarHtml();
        radarTruncated();
        radarRealHttp();
        radarNoTiles();
        radarEmptyTypes();
        radarTemplateNoPlaceholders();
        radarAllTilesFail();
        radarHalfTilesFail();
        radarOversized();
        radarNaNCoords();
        radarExtremeZoom();
        radarAntimeridian();
        clockDst();
        batteryNoSignal();
        batteryImplausible();
        batteryGarbage();
        pinWrong();
        pinUnset();
        pinLostWhileActive();
        masterOffWhileActive();
        suspendSafety();
        extrasCsvGarbage();
        timeoutGarbage();
        noNavApp();
        navMismatch();
        navListEmpty();
        mediaNoSessions();
        mediaNullPackage();
        mediaNoMetadata();
        mediaNoCapabilities();
        mediaCycling();
        eastLongitudeEvening();
        polarMidnightSun();
        polarNightPole();
        themeNaNCoords();
        audioMaxUnknown();
        volumePercentGarbage();
        backlightPercentGarbage();
        carEventGarbage();
        carEventStringValue();
        themeUnknownMode();
        appDrawer();
        phoneSources();
        favorites();
        gaugesJunk();
        settingsInput();
        weatherOffline();
        weatherGarbled();
        weatherCarSensor();
        weatherPrivacy();

        System.out.println(titles.size() + " scenarios, " + checks + " checks, " + failures.size() + " failed");
        if (!failures.isEmpty()) {
            System.out.println("FAILED: " + String.join(", ", failures));
            System.exit(1);
        }
    }

    // ---------------- radar (spec S15-S18') ----------------
    static void radarOffline() {
        scenario("SG01", "radar: no internet (DNS/UnknownHost) -> placeholder, never a crash");
        Stub s = new Stub().mode(Stub.API_FAIL);
        check("SG01", RadarPlan.build(s, 52.10, 5.18, 7, false) == null);
        check("SG01b", RadarPlan.build(new Stub().api(apiJson("https://t", "/v2/radar/a", 1764073800L))
            .mode(Stub.TILES_FAIL_ALL).tiles("https://t/"), 52.10, 5.18, 7, false) != null,
            "index ok but every tile down: plan exists, draws nothing (placeholder)");
        check("SG01c", RadarPlan.build(null, 52.10, 5.18, 7, false) == null); // no fetcher at all
    }

    static void radarHttp404() throws Exception {
        scenario("SG02", "radar: API answers HTTP 404 -> placeholder (real HttpURLConnection)");
        HttpServer srv = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        srv.createContext("/api/", ex -> { ex.sendResponseHeaders(404, -1); ex.close(); });
        srv.start();
        String url = "http://127.0.0.1:" + srv.getAddress().getPort() + "/api/en.json";
        boolean threw = false;
        try { new HttpRadarFetcher().fetch(url); } catch (Exception e) { threw = true; }
        check("SG02", threw);
        srv.stop(0);
    }

    static void radarHtml() {
        scenario("SG03", "radar: API returns an HTML rate-limit page -> placeholder");
        check("SG03", RadarPlan.build(new Stub().api("<html>429 Too Many Requests</html>"), 52.10, 5.18, 7, false) == null);
    }

    static void radarTruncated() {
        scenario("SG04", "radar: truncated JSON body (proxy cut the connection) -> placeholder");
        check("SG04", RadarPlan.build(new Stub().api("{\"types\":{\"rain\":{\"radar\":["), 52.10, 5.18, 7, false) == null);
        check("SG04b", RadarPlan.build(new Stub().api(""), 52.10, 5.18, 7, false) == null);
    }

    static void radarRealHttp() throws Exception {
        scenario("SG05", "radar: tiles fetched over real HTTP -> grid built, attribution kept");
        HttpServer srv = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        String host = "http://127.0.0.1:" + srv.getAddress().getPort();
        srv.createContext("/v2/", ex -> {
            byte[] b = "fake-png".getBytes(StandardCharsets.UTF_8);
            ex.sendResponseHeaders(200, b.length); ex.getResponseBody().write(b); ex.close();
        });
        srv.start();
        RadarPlan.Plan p = RadarPlan.build(new Composite(apiJson(host, "/v2/radar/test", 1764073800L),
            new HttpRadarFetcher()), 52.10, 5.18, 7, false);
        check("SG05", p != null && p.hasTiles() && p.attribution.equals(RadarTiles.ATTRIBUTION));
        check("SG05b", p != null && p.tiles.size() == RadarTiles.tilesAcross(p.zoom));
        srv.stop(0);
    }

    static void radarNoTiles() {
        scenario("SG06", "radar: past frames without path -> placeholder");
        check("SG06", RadarPlan.build(new Stub().api("{\"radar\":{\"past\":[{\"time\":1764073800}]}}"),
            52.10, 5.18, 7, false) == null);
    }

    static void radarEmptyTypes() {
        scenario("SG07", "radar: index with empty radar.past / pathless frames -> placeholder");
        check("SG07", RadarPlan.build(new Stub().api("{\"version\":\"2.0\",\"radar\":{\"past\":[]}}"), 52.10, 5.18, 7, false) == null);
        check("SG07b", RadarPlan.build(new Stub().api("{\"radar\":{\"past\":[{\"time\":1,\"path\":\"\"}]}}"),
            52.10, 5.18, 7, false) == null);
    }

    static void radarTemplateNoPlaceholders() {
        scenario("SG08", "radar: index without host -> tilecache fallback; tiles down -> placeholder, zoom clamped");
        RadarPlan.Plan p = RadarPlan.build(new Stub().api("{\"version\":\"2.0\","
            + "\"radar\":{\"past\":[{\"time\":1764073800,\"path\":\"/v2/radar/x\"}]}}")
            .mode(Stub.TILES_FAIL_ALL).tiles("https://t/"), 52.10, 5.18, 7, false);
        check("SG08", p != null && !p.hasTiles()); // index parsed, every tile down -> placeholder
        check("SG08b", p != null && p.zoom == RadarTiles.MAX_ZOOM); // z never above 7
    }

    static void radarAllTilesFail() {
        scenario("SG09", "radar: API ok but every tile fails -> placeholder, no half-blank card");
        RadarPlan.Plan p = RadarPlan.build(new Stub().api(GOOD_API).mode(Stub.TILES_FAIL_ALL), 52.10, 5.18, 7, false);
        check("SG09", p != null && !p.hasTiles());
    }

    static void radarHalfTilesFail() {
        scenario("SG10", "radar: every other tile fails -> partial grid still draws");
        RadarPlan.Plan p = RadarPlan.build(new Stub().api(GOOD_API).mode(Stub.TILES_FAIL_HALF), 52.10, 5.18, 7, false);
        check("SG10", p != null && p.hasTiles() && p.tiles.size() == RadarTiles.tilesAcross(7) / 2);
    }

    static void radarOversized() {
        scenario("SG11", "radar: oversized body (>1.5 MB) -> treated as failure, no memory blowup");
        byte[] big = new byte[RadarPlan.MAX_BODY_BYTES + 16];
        Arrays.fill(big, (byte) 'x');
        RadarFetcher f = url -> big;
        check("SG11", RadarPlan.build(f, 52.10, 5.18, 7, false) == null);
        RadarFetcher tilesBig = url -> url.contains("weather-maps.json") ? GOOD_API.getBytes(StandardCharsets.UTF_8) : big;
        RadarPlan.Plan p = RadarPlan.build(tilesBig, 52.10, 5.18, 7, false);
        check("SG11b", p != null && !p.hasTiles()); // oversized tiles skipped -> placeholder
    }

    static void radarNaNCoords() {
        scenario("SG12", "radar: corrupted prefs coords (NaN / absurd) -> owner defaults, grid builds");
        double[] c = RadarPlan.sanitizeCoords(Double.NaN, Double.NaN);
        check("SG12", c[0] == SettingsKeys.DEFAULT_LAT && c[1] == SettingsKeys.DEFAULT_LON);
        RadarPlan.Plan p = RadarPlan.build(new Stub().api(GOOD_API), Double.NaN, 1e9, 7, false);
        check("SG12b", p != null && p.hasTiles());
    }

    static void radarExtremeZoom() {
        scenario("SG13", "radar: zoom 0 / zoom 30 -> clamped to 3..7 (RainViewer max), bounded tile count");
        check("SG13", RadarPlan.sanitizeZoom(0) == 3 && RadarPlan.sanitizeZoom(30) == RadarTiles.MAX_ZOOM);
        RadarPlan.Plan p = RadarPlan.build(new Stub().api(GOOD_API), 52.10, 5.18, 30, false);
        check("SG13b", p != null && p.zoom <= RadarPlan.ZOOM_MAX && p.tiles.size() <= RadarTiles.tilesAcross(p.zoom));
    }

    static void radarAntimeridian() {
        scenario("SG14", "radar: antimeridian longitude -> tiles wrap horizontally; above/below world skipped");
        int[] c = RadarTiles.clampTile(3, -5, 3);
        check("SG14", c != null && c[0] >= 0 && c[0] < 8);
        check("SG14b", RadarTiles.clampTile(3, 0, -1) == null && RadarTiles.clampTile(3, 0, 8) == null);
        RadarPlan.Plan p = RadarPlan.build(new Stub().api(GOOD_API), 0.0, 179.9, 5, false);
        check("SG14c", p != null && p.hasTiles());
    }

    // ---------------- clock ----------------
    static void clockDst() {
        scenario("SG15", "clock: DST offset (1h/2h) and midnight rollover keep the right time/date");
        long winter = Instant.parse("2026-12-21T23:30:00Z").toEpochMilli();
        long summer = Instant.parse("2026-06-21T23:30:00Z").toEpochMilli();
        check("SG15", ClockFormat.time(winter, 1).equals("00:30") && ClockFormat.date(winter, 1).startsWith("Tue"));
        check("SG15b", ClockFormat.time(summer, 2).equals("01:30") && ClockFormat.date(summer, 2).startsWith("Mon"));
    }

    // ---------------- battery ----------------
    static void batteryNoSignal() {
        scenario("SG16", "battery: no event yet / zero / negative raw -> chip hidden (no '0.0 V')");
        check("SG16", !BatteryState.known(0) && !BatteryState.known(-12) && !BatteryState.known(-1));
    }

    static void batteryImplausible() {
        scenario("SG17", "battery: implausible value (1210 -> 121 V) -> hidden, never shown");
        check("SG17", !BatteryState.known(1210) && !BatteryState.plausible(1210));
        check("SG17b", BatteryState.plausible(121) && BatteryState.plausible(240)); // 12.1 V / 24.0 V ok
    }

    static void batteryGarbage() {
        scenario("SG18", "battery: overflow/junk frame values -> hidden, no absurd label");
        check("SG18", !BatteryState.known(Integer.MAX_VALUE) && !BatteryState.known(Integer.MIN_VALUE));
        check("SG18b", !BatteryState.label(Integer.MAX_VALUE).contains("214748365"));
    }

    // ---------------- valet PIN + bootstrap ----------------
    static void pinWrong() {
        scenario("SG19", "valet: wrong PIN -> 5 attempts, 30 s lockout, correct PIN blocked while locked, then ok");
        String h = ValetPin.hashPin("4321");
        ValetPin.Guard g = new ValetPin.Guard();
        long t0 = 1_700_000_000_000L;
        ValetPin.Verdict v = null;
        for (int i = 0; i < ValetPin.MAX_ATTEMPTS; i++) v = g.verify("9999", h, t0 + i * 1000);
        long armedAt = t0 + (ValetPin.MAX_ATTEMPTS - 1) * 1000L;
        check("SG19", v != null && v.locked && v.retryInMs == ValetPin.LOCKOUT_MS);
        check("SG19b", g.verify("4321", h, armedAt + ValetPin.LOCKOUT_MS - 1).locked);
        check("SG19c", g.verify("4321", h, armedAt + ValetPin.LOCKOUT_MS + 1).ok);
        check("SG19d", !g.verify("", h, t0 + 100_000).ok); // empty PIN never verifies
    }

    static void pinUnset() {
        scenario("SG20", "valet: enabled with no PIN and BT dead -> entry refused + settings warning");
        check("SG20", !ValetPolicy.entryAllowed(true, false, false) && ValetPolicy.warnNoExit(true, false, false));
        check("SG20b", ValetPolicy.entryAllowed(true, true, false) && !ValetPolicy.warnNoExit(true, true, false));
    }

    static void pinLostWhileActive() {
        scenario("SG21", "valet: PIN lost (prefs wiped) while active -> restart must EXIT, never re-trap");
        check("SG21", ValetPolicy.replayAction(true, true, false, false) == ValetPolicy.Replay.EXIT);
        check("SG21b", ValetPolicy.replayAction(true, true, true, false) == ValetPolicy.Replay.APPLY);
        check("SG21c", ValetPolicy.replayAction(false, true, true, false) == ValetPolicy.Replay.NONE);
    }

    static void masterOffWhileActive() {
        scenario("SG22", "valet: master switch turned off while active -> restart exits fully (S27a)");
        check("SG22", ValetPolicy.replayAction(true, false, true, false) == ValetPolicy.Replay.EXIT);
        check("SG22b", !ValetPolicy.entryAllowed(false, true, true));
    }

    static void suspendSafety() {
        scenario("SG23", "valet: framework/SystemUI/HCT/camera/launcher never suspended; Settings suspended");
        List<ValetPolicy.App> apps = Arrays.asList(
            new ValetPolicy.App("android", true),
            new ValetPolicy.App("com.android.systemui", true),
            new ValetPolicy.App("android.microntek.service", false),
            new ValetPolicy.App("android.microntek.canbus", false),
            new ValetPolicy.App("android.microntek.mtcser", false),
            new ValetPolicy.App("com.microntek.backview", false),
            new ValetPolicy.App("org.vibebaking.launcher", false),
            new ValetPolicy.App("com.foo.game", false),
            new ValetPolicy.App("com.android.settings", true));
        List<String> s = ValetPolicy.computeSuspend(apps, Set.of());
        check("SG23", s.equals(Arrays.asList("com.android.settings", "com.foo.game")));
        check("SG23b", !s.contains("android.microntek.canbus") && !s.contains("com.microntek.backview"));
        check("SG23c", ValetPolicy.PROTECTED.containsAll(
            List.of("android", "com.android.systemui", "android.microntek.service",
                    "android.microntek.canbus", "android.microntek.mtcser",
                    "com.microntek.backview", ValetPolicy.LAUNCHER_PACKAGE)));
    }

    static void extrasCsvGarbage() {
        scenario("SG24", "valet: corrupted extras CSV (blank/space/duplicate entries) -> tolerated set");
        check("SG24", ValetPolicy.parseExtrasCsv(" , ,com.foo.game,,com.foo.game, ").equals(Set.of("com.foo.game")));
        check("SG24b", ValetPolicy.parseExtrasCsv(null).isEmpty() && ValetPolicy.parseExtrasCsv("").isEmpty());
    }

    static void timeoutGarbage() {
        scenario("SG25", "valet: timeout pref garbage (0/negative/overflow) -> clamped, no instant entry");
        check("SG25", SettingsKeys.clampTimeoutS(0) == 10 && SettingsKeys.clampTimeoutS(-5) == 10);
        long ms = SettingsKeys.clampTimeoutS(Integer.MAX_VALUE) * 1000L;
        check("SG25b", ms > 0 && SettingsKeys.clampTimeoutS(Integer.MAX_VALUE) <= 3600);
        check("SG25c", SettingsKeys.clampTimeoutS(60) == 60);
    }

    // ---------------- map card ----------------
    static void noNavApp() {
        scenario("SG26", "map card: NO navigation app installed -> placeholder, no embed attempt");
        check("SG26", MapTargetPolicy.target("auto", Set.of()) == null);
        check("SG26b", MapTargetPolicy.target("auto", null) == null);
    }

    static void navMismatch() {
        scenario("SG27", "map card: owner picked Waze but only Maps installed (and vice versa) -> placeholder");
        check("SG27", MapTargetPolicy.target("waze", Set.of(MapTargetPolicy.MAPS)) == null);
        check("SG27b", MapTargetPolicy.target("maps", Set.of(MapTargetPolicy.WAZE)) == null);
        check("SG27c", MapTargetPolicy.target("carplay", Set.of(MapTargetPolicy.MAPS)).equals(MapTargetPolicy.MAPS));
    }

    static void navListEmpty() {
        scenario("SG28", "map card: package enumeration denied -> empty set -> placeholder");
        check("SG28", MapTargetPolicy.target(null, Set.of()) == null && MapTargetPolicy.target(null, null) == null);
    }

    // ---------------- media card ----------------
    static void mediaNoSessions() {
        scenario("SG29", "media: listener not connected / no sessions -> idle card, no crash");
        check("SG29", MediaCardPolicy.pickActive(List.of()) == null && MediaCardPolicy.pickActive(null) == null);
        check("SG29b", MediaCardPolicy.label(null).equals(""));
    }

    static void mediaNullPackage() {
        scenario("SG30", "media: session with null package/labels -> empty strings, no NPE");
        MediaCardPolicy.Ctl c = new MediaCardPolicy.Ctl(); // everything null
        check("SG30", MediaCardPolicy.label(c).equals(""));
        check("SG30b", MediaCardPolicy.sourceLabel(c).equals(""));
        check("SG30c", MediaCardPolicy.transportEnabled(c) == 0 && MediaCardPolicy.radioLabel(null, c).equals(""));
    }

    static void mediaNoMetadata() {
        scenario("SG31", "media: session publishes no metadata -> package label, empty album");
        MediaCardPolicy.Ctl c = new MediaCardPolicy.Ctl();
        c.pkg = "com.foo.player"; c.pkgLabel = "Foo Player";
        check("SG31", MediaCardPolicy.label(c).equals("Foo Player"));
        check("SG31b", MediaCardPolicy.album(c).equals("") && MediaCardPolicy.radioLabel("", c).equals("Foo Player"));
        check("SG31c", MediaCardPolicy.label(c).equals(MediaCardPolicy.radioLabel(null, c)));
    }

    static void mediaNoCapabilities() {
        scenario("SG32", "media: controller without transport caps -> all buttons disabled");
        MediaCardPolicy.Ctl c = new MediaCardPolicy.Ctl();
        c.pkg = "com.foo.radio"; c.pkgLabel = "Radio"; c.title = "Station";
        check("SG32", MediaCardPolicy.transportEnabled(c) == 0);
        MediaCardPolicy.Ctl p = new MediaCardPolicy.Ctl();
        p.pkg = "com.spotify.music"; p.title = "S"; p.canSkipNext = true;
        check("SG32b", MediaCardPolicy.transportEnabled(p) == MediaCardPolicy.TR_NEXT);
    }

    static void mediaCycling() {
        scenario("SG33", "media: many sessions, one playing -> playing wins; source cycling wraps safely");
        MediaCardPolicy.Ctl a = new MediaCardPolicy.Ctl(); a.pkg = "a"; a.pkgLabel = "A"; a.title = "Idle";
        MediaCardPolicy.Ctl b = new MediaCardPolicy.Ctl(); b.pkg = "b"; b.pkgLabel = "B"; b.title = "Playing"; b.playing = true;
        MediaCardPolicy.Ctl c = new MediaCardPolicy.Ctl(); c.pkg = "c"; c.pkgLabel = "C";
        check("SG33", MediaCardPolicy.pickActive(Arrays.asList(a, b, c)) == b);
        check("SG33b", MediaCardPolicy.pickActive(Arrays.asList(a, c)) == a);
        int size = 3, cursor = 2;
        check("SG33c", (cursor + 1) % size == 0 && MediaCardPolicy.pickActive(Arrays.asList(a)) == a);
    }

    // ---------------- day/night cycle ----------------
    static void eastLongitudeEvening() {
        scenario("SG34", "theme: east longitude must not wrap (Tokyo 23:00 UTC = 08:00 JST -> day)");
        check("SG34", !DayNight.isNight(35.68, 139.7, Instant.parse("2026-06-21T23:00:00Z").toEpochMilli(), 9));
        check("SG34b", !DayNight.isNight(35.68, 139.7, Instant.parse("2026-06-22T03:00:00Z").toEpochMilli(), 9));
        check("SG34c", !DayNight.isNight(35.68, 139.7, Instant.parse("2026-06-22T21:00:00Z").toEpochMilli(), 9)); // 06:00 JST, after sunrise
        check("SG34d", DayNight.isNight(35.68, 139.7, Instant.parse("2026-06-23T14:00:00Z").toEpochMilli(), 9)); // 23:00 JST
        check("SG34e", DayNight.isNight(35.68, 139.7, Instant.parse("2026-06-22T15:00:00Z").toEpochMilli(), 9)); // 00:00 JST
    }

    static void polarMidnightSun() {
        scenario("SG35", "theme: midnight sun (78N June) -> always day, 02:00 UTC is not night");
        check("SG35", !DayNight.isNight(78.0, 15.0, Instant.parse("2026-06-21T02:00:00Z").toEpochMilli(), 1));
        check("SG35b", !DayNight.isNight(78.0, 15.0, Instant.parse("2026-06-21T12:00:00Z").toEpochMilli(), 1));
    }

    static void polarNightPole() {
        scenario("SG36", "theme: polar night (78N December) -> always night, noon is night");
        check("SG36", DayNight.isNight(78.0, 15.0, Instant.parse("2026-12-21T12:00:00Z").toEpochMilli(), 1));
        check("SG36b", DayNight.isNight(78.0, 15.0, Instant.parse("2026-12-21T03:00:00Z").toEpochMilli(), 1));
    }

    static void themeNaNCoords() {
        scenario("SG37", "theme: NaN/absurd coords -> owner defaults, night still correct");
        long nightUtc = Instant.parse("2026-12-21T02:00:00Z").toEpochMilli(); // 03:00 CET
        long dayUtc = Instant.parse("2026-06-21T11:00:00Z").toEpochMilli();   // 13:00 CEST
        check("SG37", DayNight.isNight(Double.NaN, Double.NaN, nightUtc, 1));
        check("SG37b", DayNight.isNight(999.0, -999.0, nightUtc, 1));
        check("SG37c", !DayNight.isNight(Double.NaN, Double.NaN, dayUtc, 2));
    }

    // ---------------- volume / backlight ----------------
    static void audioMaxUnknown() {
        scenario("SG38", "volume: stream max unknown (0) -> leave volume alone, never accidental mute");
        check("SG38", VolumePolicy.targetVolume("lower", 30, 0, 5) == null);
        check("SG38b", VolumePolicy.targetVolume("mute", 30, 0, 5) == null);
        check("SG38c", VolumePolicy.targetVolume("lower", 30, 15, 10) == 5);
    }

    static void volumePercentGarbage() {
        scenario("SG39", "volume: percent -50 / 500 -> clamped inside 0..max, MCU command clamped too");
        check("SG39", VolumePolicy.targetVolume("lower", -50, 15, 10) == 0);
        check("SG39b", VolumePolicy.targetVolume("lower", 500, 15, 10) == 15);
        check("SG39c", VolumePolicy.mcuVolumeCommand(-50).equals("ctl_backview_vol=0")
            && VolumePolicy.mcuVolumeCommand(500).equals("ctl_backview_vol=100"));
    }

    static void backlightPercentGarbage() {
        scenario("SG40", "backlight: percent garbage -> fraction stays 0..1, 'nothing' still applies nothing");
        check("SG40", BacklightPolicy.dimFraction("dim", -50, true) == 0.0);
        check("SG40b", BacklightPolicy.dimFraction("dim", 500, true) == 1.0);
        check("SG40c", BacklightPolicy.dimFraction("nothing", 40, true) == null);
        check("SG40d", BacklightPolicy.dimFraction("dim", 40, false) == null);
    }

    // ---------------- car events ----------------
    static void carEventGarbage() {
        scenario("SG41", "car events: garbage bundle (null type, junk value) -> UNKNOWN, no crash");
        Map<String, Object> b = new HashMap<>();
        b.put("type", null); b.put("value", "abc");
        check("SG41", CarEventParser.parse("CarEvent", b).kind == CarEventParser.Kind.UNKNOWN);
        check("SG41b", CarEventParser.parse("Whatever", Map.of("type", "headlight", "value", true)).kind == CarEventParser.Kind.UNKNOWN);
        check("SG41c", CarEventParser.parse("CarEvent", null).kind == CarEventParser.Kind.UNKNOWN);
        check("SG41d", !CarEventParser.truthy(null) && CarEventParser.truthy(Boolean.TRUE) && !CarEventParser.truthy("yes"));
    }

    static void carEventStringValue() {
        scenario("SG42", "car events: battery value as String -> parsed; junk value -> 0 -> chip hidden");
        check("SG42", CarEventParser.parse("CarEvent", Map.of("type", "battery", "value", "121")).intValue == 121);
        check("SG42b", CarEventParser.parse("CarEvent", Map.of("type", "battery", "value", "junk")).intValue == 0);
        check("SG42c", !BatteryState.known(CarEventParser.parse("CarEvent", Map.of("type", "battery", "value", "junk")).intValue));
    }

    static void themeUnknownMode() {
        scenario("SG43", "theme: unknown dark-mode pref -> cycle fallback; night palette never white");
        check("SG43", ThemePolicy.night("garbage", false, true, "nothing"));
        check("SG43b", !ThemePolicy.night("garbage", false, false, "nothing"));
        check("SG43c", ThemePolicy.night(null, false, true, "nothing"));
        check("SG43d", !ColorTools.isPureWhite(RadarTiles.palette(true)[0])
            && !ColorTools.isPureWhite(ArtPalette.nightTint(new int[0]))
            && !ColorTools.isPureWhite(ArtPalette.nightTint(new int[] { 0xFFFFFFFF })));
    }

    static void appDrawer() {
        scenario("SG44", "drawer: package enumeration denied -> empty drawer, no crash");
        check("SG44", AppDrawerPolicy.visible(null, false, null, null).isEmpty());
        check("SG44b", AppDrawerPolicy.visible(java.util.List.of(
            new AppDrawerPolicy.Entry("com.foo.svc", "Service", false)), false, Set.of(), Set.of()).isEmpty());
        scenario("SG45", "drawer: HOME packages (our launcher, Launcher3) hidden - we are the only launcher");
        check("SG45", AppDrawerPolicy.visible(java.util.List.of(
            new AppDrawerPolicy.Entry("org.vibebaking.launcher", "Vibe Launcher", true),
            new AppDrawerPolicy.Entry("com.android.launcher3", "Launcher3", true),
            new AppDrawerPolicy.Entry("com.waze", "Waze", true)), false, Set.of(),
            Set.of("org.vibebaking.launcher", "com.android.launcher3")).size() == 1);
        scenario("SG46", "drawer in valet: only the allowed set + the map card's nav app; Settings gone");
        java.util.List<AppDrawerPolicy.Entry> all = java.util.List.of(
            new AppDrawerPolicy.Entry("com.google.android.apps.maps", "Maps", true),
            new AppDrawerPolicy.Entry("com.microntek.radio", "Radio", true),
            new AppDrawerPolicy.Entry("com.waze", "Waze", true),
            new AppDrawerPolicy.Entry("com.android.settings", "Settings", true),
            new AppDrawerPolicy.Entry("com.foo.game", "Game", true));
        java.util.List<String> v = new java.util.ArrayList<>();
        for (AppDrawerPolicy.Entry e : AppDrawerPolicy.visible(all, true,
            ValetPolicy.withMapTarget(Set.of(), MapTargetPolicy.WAZE), Set.of())) v.add(e.label);
        check("SG46", v.equals(java.util.List.of("Maps", "Radio", "Waze")));
        check("SG46b", !v.contains("Settings") && !v.contains("Game"));
        scenario("SG47", "drawer grid math: 4x3 = 12 icons, overflow pages/scroll without explosion");
        check("SG47", AppDrawerPolicy.PAGE_SIZE == 12 && AppDrawerPolicy.pageCount(37) == 4
            && AppDrawerPolicy.rowCount(37) == 10);
    }

    static void phoneSources() {
        scenario("SG48", "BT stack silent at boot (no broadcast yet): verdict UNKNOWN, valet stays inert");
        CombinedPhoneProbe silent = new CombinedPhoneProbe(new SilentHct(), new DeadAndroid());
        check("SG48", silent.probe() == PhonePresence.UNKNOWN);
        check("SG48b", !PhonePolicy.autoEntryWanted(silent.probe()) && !PhonePolicy.exitWanted(silent.probe()));
        check("SG48c", !PhonePolicy.exitPathAvailable(silent.probe(), silent.trustedPhoneConfigured())
            && !ValetPolicy.entryAllowed(true, false, PhonePolicy.exitPathAvailable(silent.probe(), silent.trustedPhoneConfigured())),
            "no PIN + no phone signal -> entry refused, owner is never trapped (S26a)");

        scenario("SG49", "Android stack dead (BT off on this unit) while HCT works: no crash, HCT answers");
        CombinedPhoneProbe androidDead = new CombinedPhoneProbe(new ConnectedHct(), new DeadAndroid());
        check("SG49", androidDead.probe() == PhonePresence.PRESENT && PhonePolicy.exitWanted(androidDead.probe()));
        check("SG49b", androidDead.trustedPhoneConfigured());

        scenario("SG50", "HCT service missing / receiver denied: Android stack verdict still used");
        CombinedPhoneProbe hctDead = new CombinedPhoneProbe(new ThrowingHct(), new PairedAwayAndroid());
        check("SG50", hctDead.probe() == PhonePresence.NONE);
        check("SG50b", hctDead.trustedPhoneConfigured() && PhonePolicy.autoEntryWanted(hctDead.probe()));
        check("SG50c", ValetPolicy.entryAllowed(true, false, PhonePolicy.exitPathAvailable(
            hctDead.probe(), hctDead.trustedPhoneConfigured())), "paired-but-away phone is an exit path (S26)");

        scenario("SG51", "both BT sources blow up mid-run: UNKNOWN, no exception, valet inert + replay exits");
        CombinedPhoneProbe bothDead = new CombinedPhoneProbe(new ThrowingHct(), new ThrowingAndroid());
        check("SG51", bothDead.probe() == PhonePresence.UNKNOWN);
        check("SG51b", ValetPolicy.replayAction(true, true, false, false) == ValetPolicy.Replay.EXIT,
            "crash replay must unsuspend, not re-trap (S22/S26a)");
        bothDead.release();
        check("SG51c", true);

        scenario("SG52", "junk phone-name entries in the HCT pair list must not count as addresses");
        check("SG52", PhonePolicy.parseDeviceList("iPhone 15\nSamsung Galaxy") == 0,
            "device names in MTC.BT.deviceList must not read as addresses");
        check("SG52b", PhonePolicy.parseDeviceList("aa:bb:cc:dd:ee:ff\nAA:BB:CC:DD:EE:FF") == 2,
            "colon-separated and bare addresses both count");
        check("SG52c", PhonePolicy.parseDeviceList("aa:bb:cc\ndeadbeefnothex\n\n") == 0,
            "short or non-hex junk must not count");
        check("SG52d", PhonePolicy.parseDeviceList(null) == 0 && PhonePolicy.parseDeviceList("   ") == 0,
            "missing/garbage settings value must not crash or count");
        scenario("SG53", "HCT pair list present but no connection broadcast yet: paired-but-away, exit path exists");
        PhonePresence p = PhonePolicy.decideHct(true, false, false, PhonePolicy.parseDeviceList("AA:BB:CC:DD:EE:FF") > 0);
        check("SG53", p == PhonePresence.NONE && PhonePolicy.autoEntryWanted(p));
        check("SG53b", PhonePolicy.exitPathAvailable(p, true) && ValetPolicy.entryAllowed(true, false, PhonePolicy.exitPathAvailable(p, true)),
            "paired phone is an exit path even while away (S26a/S26 hook)");
    }

    /** Degradation scenarios for the bottom favourite row (spec S40/S40a/S40b/S40c). */
    static void favorites() {
        scenario("SG54", "favourite row: garbage/empty pref handled without blank icons or duplicates");
        check("SG54", FavoritePolicy.slots(null).equals(FavoritePolicy.defaults())
            && FavoritePolicy.slots("").equals(FavoritePolicy.defaults()),
            "a missing pref means the factory row: phone slot filled, three empty");
        check("SG54a", FavoritePolicy.slots(",,, ,,,,").equals(java.util.List.of("", "", "", "")),
            "a present pref is honoured even when cleared: the owner un-pinned everything");
        check("SG54b", FavoritePolicy.slots(",,,com.waze,,,com.waze").equals(java.util.List.of("", "", "", "com.waze")),
            "CSV fields are literal slot positions (field 3 -> slot 3); fields past slot 3 are ignored");
        check("SG54c", FavoritePolicy.csv(FavoritePolicy.slots("a,,,b")).equals("a,,,b")
            && FavoritePolicy.slots(FavoritePolicy.csv(FavoritePolicy.slots("a,,,b")))
                .equals(java.util.List.of("a", "", "", "b")), "store round-trip must be stable");

        scenario("SG55", "favourite app uninstalled since pinning: slot collapses to empty, row stays aligned");
        java.util.List<String> row = java.util.List.of("com.microntek.bluetooth", "com.waze", "", "");
        java.util.List<String> v = FavoritePolicy.visible(row, false, null, java.util.Set.of("com.microntek.bluetooth"));
        check("SG55", v.size() == 4 && v.equals(java.util.List.of("com.microntek.bluetooth", "", "", "")),
            "a dead favourite must not shift the other slots");
        check("SG55b", FavoritePolicy.glyph(v.get(1)).equals("＋"), "empty slot is the tap-to-drawer affordance");

        scenario("SG56", "row full: pinning replaces the primary slot, duplicates never double-pin");
        check("SG56", FavoritePolicy.assign(java.util.List.of("a", "b", "c", "d"), "com.waze")
            .equals(java.util.List.of("com.waze", "b", "c", "d")));
        check("SG56b", FavoritePolicy.assign(java.util.List.of("com.waze", "", "", ""), "com.waze")
            .equals(java.util.List.of("com.waze", "", "", "")),
            "a duplicate pin keeps its slot instead of moving to the next free one");

        scenario("SG57", "valet mode: only allowed favourites stay visible; the phone slot always does");
        java.util.List<String> vv = FavoritePolicy.visible(row, true,
            ValetPolicy.allowedSet(java.util.Set.of()), java.util.Set.of("com.microntek.bluetooth", "com.waze"));
        check("SG57", vv.equals(java.util.List.of("com.microntek.bluetooth", "", "", "")),
            "Waze is not in the owner's allowed list -> hidden while valet is active");
        java.util.List<String> vvNav = FavoritePolicy.visible(row, true,
            ValetPolicy.allowedSet(ValetPolicy.withMapTarget(java.util.Set.of(), MapTargetPolicy.WAZE)),
            java.util.Set.of("com.microntek.bluetooth", "com.waze"));
        check("SG57b", vvNav.equals(java.util.List.of("com.microntek.bluetooth", "com.waze", "", "")),
            "the map card's nav app stays allowed, so its pinned slot survives valet");
        java.util.List<String> nullRow = FavoritePolicy.visible(null, true, null, null);
        check("SG57c", nullRow.size() == 4 && nullRow.get(0).equals(FavoritePolicy.PHONE_PACKAGE));

        scenario("SG58", "BT dialer tab index: garbage clamped, never passed through to the BT app");
        check("SG58", FavoritePolicy.dialTab(-100) == 0 && FavoritePolicy.dialTab(99) == FavoritePolicy.BT_TAB_MAX
            && FavoritePolicy.dialTab(1) == 1 && FavoritePolicy.BT_TAB_EXTRA.equals("curTab"));
        scenario("SG59", "clearing slots: out-of-range index leaves the row untouched");
        check("SG59", FavoritePolicy.clear(FavoritePolicy.defaults(), 99).equals(FavoritePolicy.defaults())
            && FavoritePolicy.clear(FavoritePolicy.defaults(), -1).equals(FavoritePolicy.defaults()));
        check("SG59b", FavoritePolicy.clear(null, 0).size() == 4 && FavoritePolicy.clear(null, 0).get(0).equals(""),
            "a null row normalises to the factory row first, then slot 0 empties: never a crash");
    }

    /** Degradation scenarios for the engine gauge inputs (owner request 2026-11-27). */
    static void gaugesJunk() {
        scenario("SG60", "rpm broadcast junk: garbage/overflow/missing extras parse to null, gauge stays hidden");
        check("SG60", EngineGauges.parseRpm(null) == null && EngineGauges.parseRpm("") == null
            && EngineGauges.parseRpm("abc") == null && EngineGauges.parseRpm("-5") == null,
            "an absent or junk 'rpm' extra must never paint a value");
        check("SG60b", EngineGauges.parseRpm("9001") == null && EngineGauges.parseRpm("2147483648") == null,
            "over-band and overflowing strings must not reach the panel");

        scenario("SG61", "no engine-temp broadcast exists (only the onEngineTemp entry point): policy still total");
        check("SG61", EngineGauges.coolantLevel(87) == EngineGauges.Level.OK
            && EngineGauges.oilLevel(125) == EngineGauges.Level.WARN
            && EngineGauges.oilLevel(135) == EngineGauges.Level.BAD,
            "thermostat 87 C is OK; 125 is a fine load spike edge -> WARN; 135 must be BAD");
        check("SG61b", EngineGauges.batteryLevel(12.6) == EngineGauges.Level.OK
            && EngineGauges.batteryLevel(Double.NaN) == EngineGauges.Level.BAD,
            "resting 12.6 V reads OK; a NaN voltage reads BAD, never a colour crash");
    }

    /** Degradation scenarios for the settings cycle/band helpers + styled number inputs (Round 6). */
    static void settingsInput() {
        scenario("SG62", "settings cycle/band helpers: garbage current and empty bands degrade, never crash");
        check("SG62", SettingsCycle.next(null, "x") == null && SettingsCycle.next(new String[0], "x") == null
            && SettingsCycle.next(null, 5) == 5,
            "empty/null option lists leave the row inert instead of throwing");
        check("SG62b", SettingsCycle.nearest(new int[] {20, 40, 60, 80}, 1000) == 3
            && SettingsCycle.nearest(new int[] {20, 40, 60, 80}, Integer.MIN_VALUE) == 0
            && SettingsCycle.nearest(new int[0], 5) == 0,
            "a garbage stored percent still lands the SeekBar on a legal band value");
        check("SG62c", SettingsCycle.indexOf(new String[] {"a"}, null) == -1,
            "null current must read as 'unknown -> first option' in the UI, not an index");

        scenario("SG63", "settings manual input: junk PIN/timeout strings validate without exceptions");
        check("SG63", SettingsValidation.parseTimeout(null) == null
            && SettingsValidation.parseTimeout("2147483648") == null
            && !SettingsValidation.validPin(null) && !SettingsValidation.validPin("nan"),
            "the inline save path must never throw on absent or junk text");
        check("SG63b", !SettingsValidation.timeoutOk(Integer.MAX_VALUE) && !SettingsValidation.timeoutOk(Integer.MIN_VALUE),
            "overflowed timeout input is refused, the auto-entry timer keeps the stored sane value");
    }

    /** Round 7 (owner 2026-11-27): Open-Meteo degrade paths, the CAN outside-air sensor, privacy. */
    static final String WX_SAMPLE = "{\"current\":{\"temperature_2m\":8.3,\"weather_code\":3,\"is_day\":1}}";

    static void weatherOffline() throws Exception {
        scenario("SG64", "weather: Open-Meteo 404 / oversized body / no connection -> last value stays, no crash");
        HttpServer srv = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        srv.createContext("/forecast", ex -> { ex.sendResponseHeaders(404, -1); ex.close(); });
        srv.createContext("/big", ex -> {
            byte[] big = new byte[WeatherIcon.MAX_BODY_BYTES + 16];
            Arrays.fill(big, (byte) 'x');
            ex.sendResponseHeaders(200, big.length); ex.getResponseBody().write(big); ex.close();
        });
        srv.createContext("/ok", ex -> {
            byte[] b = WX_SAMPLE.getBytes(StandardCharsets.UTF_8);
            ex.sendResponseHeaders(200, b.length); ex.getResponseBody().write(b); ex.close();
        });
        srv.start();
        String base = "http://127.0.0.1:" + srv.getAddress().getPort();
        HttpWeatherFetcher f = new HttpWeatherFetcher();
        String err404 = null;
        try { f.fetch(base + "/forecast?latitude=52.1&longitude=5.2"); } catch (Exception e) { err404 = e.getMessage(); }
        check("SG64", err404 != null, "HTTP 404 must surface as an exception (the activity keeps the last reading)");
        check("SG64b", err404 != null && !err404.contains("latitude") && !err404.contains("127.0.0.1"),
            "the failure message must not carry the coordinates (privacy rule)");
        boolean oversized = false;
        try { f.fetch(base + "/big"); } catch (Exception e) { oversized = true; }
        check("SG64c", oversized, "an oversized body is refused instead of buffered without bound");
        WeatherIcon.Reading ok = WeatherIcon.parseCurrent(new String(f.fetch(base + "/ok"), StandardCharsets.UTF_8));
        check("SG64d", ok != null && ok.tempC == 8.3 && ok.wmoCode == 3
            && WeatherIcon.iconFor(ok.wmoCode.intValue(), true) == WeatherIcon.Icon.CLOUD,
            "a live 200 answer parses and maps to the overcast glyph");
        srv.stop(0);
        boolean unreachable = false;
        try { f.fetch("http://127.0.0.1:1/forecast"); } catch (Exception e) { unreachable = true; }
        check("SG64e", unreachable, "no connection at all: an exception, never a crash on the UI thread");
    }

    static void weatherGarbled() throws Exception {
        scenario("SG65", "weather: HTML rate-limit page / truncated JSON / missing fields -> nothing painted, no crash");
        check("SG65", WeatherIcon.parseCurrent("<html>429 Too Many Requests</html>") == null
            && WeatherIcon.parseCurrent("{\"current\":{\"temperature_2m\":8.3") == null
            && WeatherIcon.parseCurrent("") == null,
            "garbled bodies must read as offline, not as a half value");
        check("SG65b", WeatherIcon.parseCurrent(null) == null, "an absent body is offline, never a NullPointerException");
        WeatherIcon.Reading partial = WeatherIcon.parseCurrent("{\"current\":{\"temperature_2m\":-0.4}}");
        check("SG65c", partial != null && partial.wmoCode == null && partial.day == null
            && WeatherIcon.formatTemp(partial.tempC).equals("0\u00B0"),
            "a missing weather code paints no icon; -0.4 C shows 0\u00B0, never -0\u00B0");
        check("SG65d", WeatherIcon.iconFor(9999, true) == WeatherIcon.Icon.CLOUD,
            "an unlisted WMO code falls back to the neutral glyph");
        WeatherFetcher htmlFetcher = url -> "<html>429 Too Many Requests</html>".getBytes(StandardCharsets.UTF_8);
        check("SG65e", WeatherIcon.parseCurrent(new String(htmlFetcher.fetch(WeatherIcon.urlFor(52.10, 5.18)),
            StandardCharsets.UTF_8)) == null, "the activity's fetch+parse chain degrades on an HTML page");
    }

    static void weatherCarSensor() {
        scenario("SG66", "weather: com.canbus.temperature format UNKNOWN -> junk frames ignored, fresh frame wins 10 min");
        check("SG66", WeatherIcon.parseCanTemp("12.5\u00B0C") == 12.5 && WeatherIcon.parseCanTemp(" -3 ") == -3.0,
            "the first signed decimal is read whatever decoration the frame carries");
        check("SG66b", WeatherIcon.parseCanTemp("abc") == null && WeatherIcon.parseCanTemp(null) == null
            && WeatherIcon.parseCanTemp("-") == null && WeatherIcon.parseCanTemp("--3") == null,
            "an unrecognised frame must not overwrite Open-Meteo's value");
        long now = System.currentTimeMillis();
        check("SG66c", WeatherIcon.preferCarTemp(now - 9 * 60_000L, now) && !WeatherIcon.preferCarTemp(now - 11 * 60_000L, now),
            "the local sensor beats Open-Meteo only while its frame is fresh");
        check("SG66d", WeatherIcon.preferCarTemp(now + 5_000L, now),
            "a boot/NTP clock jump backwards reads as fresh, not as a stale frame");
    }

    static void weatherPrivacy() {
        scenario("SG67", "weather privacy: GPS precision is rounded to ~10 km before the URL; defaults when no fix");
        check("SG67", WeatherIcon.urlFor(52.1098765, 5.1781234).equals(
            "https://api.open-meteo.com/v1/forecast?latitude=52.1&longitude=5.2&current=temperature_2m,weather_code,is_day"));
        check("SG67b", !WeatherIcon.urlFor(41.8781, -87.6598).contains("87.6598")
            && WeatherIcon.urlFor(41.8781, -87.6598).contains("-87.7"),
            "full-precision coordinates must never reach the request URL");
        check("SG67c", WeatherIcon.urlFor(Double.NaN, Double.NaN).contains("latitude=52.1")
            && WeatherIcon.urlFor(Double.NaN, Double.NaN).contains("longitude=5.2"),
            "no position yet: the rounded De Bilt default is used, not garbage");
    }

    /** HCT broadcast source before any BT broadcast has been seen (boot / service down). */
    static class SilentHct implements PhonePresenceProbe {
        @Override public PhonePresence probe() { return PhonePolicy.decideHct(false, false, false, false); }
    }
    static class ConnectedHct implements PhonePresenceProbe {
        @Override public PhonePresence probe() { return PhonePolicy.decideHct(true, true, true, true); }
        @Override public boolean trustedPhoneConfigured() { return true; }
    }
    static class ThrowingHct implements PhonePresenceProbe {
        @Override public PhonePresence probe() { throw new IllegalStateException("android.microntek.mtcser gone"); }
        @Override public boolean trustedPhoneConfigured() { throw new IllegalStateException("no receiver"); }
        @Override public void release() { throw new IllegalStateException("already unregistered"); }
    }
    static class DeadAndroid implements PhonePresenceProbe {
        @Override public PhonePresence probe() { return PhonePolicy.decideAndroid(false, 0, 0, true); }
        @Override public boolean trustedPhoneConfigured() { return false; }
    }
    static class PairedAwayAndroid implements PhonePresenceProbe {
        @Override public PhonePresence probe() { return PhonePolicy.decideAndroid(true, 1, 0, false); }
        @Override public boolean trustedPhoneConfigured() { return true; }
    }
    static class ThrowingAndroid implements PhonePresenceProbe {
        @Override public PhonePresence probe() { throw new SecurityException("BLUETOOTH_CONNECT denied"); }
        @Override public void release() { throw new IllegalStateException("proxy closed twice"); }
    }
}
