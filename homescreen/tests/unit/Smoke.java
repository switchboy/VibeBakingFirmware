package org.vibebaking.launcher.unit;

import com.sun.net.httpserver.HttpServer;
import org.vibebaking.launcher.HttpRadarFetcher;
import org.vibebaking.launcher.logic.AppDrawerPolicy;
import org.vibebaking.launcher.logic.ArtPalette;
import org.vibebaking.launcher.logic.BacklightPolicy;
import org.vibebaking.launcher.logic.BatteryState;
import org.vibebaking.launcher.logic.CarEventParser;
import org.vibebaking.launcher.logic.ClockFormat;
import org.vibebaking.launcher.logic.ColorTools;
import org.vibebaking.launcher.logic.DayNight;
import org.vibebaking.launcher.logic.MapTargetPolicy;
import org.vibebaking.launcher.logic.MediaCardPolicy;
import org.vibebaking.launcher.logic.RadarFetcher;
import org.vibebaking.launcher.logic.RadarPlan;
import org.vibebaking.launcher.logic.RadarTiles;
import org.vibebaking.launcher.logic.SettingsKeys;
import org.vibebaking.launcher.logic.ThemePolicy;
import org.vibebaking.launcher.logic.ValetPin;
import org.vibebaking.launcher.logic.ValetPolicy;
import org.vibebaking.launcher.logic.VolumePolicy;

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

    /** Stub fetcher: API urls (contain "radar_by_zoom") answer apiBody; tile urls match tileBase. */
    static class Stub implements RadarFetcher {
        static final int OK = 0, TILES_FAIL_ALL = 1, TILES_FAIL_HALF = 2, API_FAIL = 3;
        String apiBody;
        String tileBase = "https://t/{z}/{x}/{y}.png";
        int mode = OK;
        int tileAttempts = 0;

        Stub api(String body) { apiBody = body; return this; }
        Stub tiles(String base) { tileBase = base; return this; }
        Stub mode(int m) { mode = m; return this; }

        @Override public byte[] fetch(String url) throws Exception {
            if (url.contains("radar_by_zoom")) {
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

    /** API body from a stub, tiles over real HTTP (HttpRadarFetcher against a local server). */
    static class Composite implements RadarFetcher {
        final String apiBody; final RadarFetcher tiles;
        Composite(String apiBody, RadarFetcher tiles) { this.apiBody = apiBody; this.tiles = tiles; }
        @Override public byte[] fetch(String url) throws Exception {
            if (url.contains("radar_by_zoom")) return apiBody.getBytes(StandardCharsets.UTF_8);
            return tiles.fetch(url);
        }
    }

    static String apiJson(String tileBase, String date, int minZ, int maxZ) {
        return "{\"info\":{\"attribution\":\"RainViewer\"},\"types\":{\"rain\":{\"radar\":[{\"date\":\""
            + date + "\",\"layer\":\"rain\",\"tiles\":[{\"url\":\"" + tileBase
            + "{z}/{x}/{y}.png\",\"minZoom\":" + minZ + ",\"maxZoom\":" + maxZ + "}]}]}}}";
    }

    static final String GOOD_API = apiJson("https://t/", "2026-11-25T12:30:00Z", 5, 9);

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
        check("SG01", RadarPlan.build(s, 52.09, 5.29, 7) == null);
        check("SG01b", RadarPlan.build(new Stub().api(
            "{\"types\":{\"rain\":{\"radar\":[{\"date\":\"d\",\"tiles\":[{\"url\":\"https://t/{z}/{x}/{y}.png\"}]}]}}}")
            .mode(Stub.TILES_FAIL_ALL).tiles("https://t/"), 52.09, 5.29, 7) != null);
        check("SG01c", RadarPlan.build(null, 52.09, 5.29, 7) == null); // no fetcher at all
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
        check("SG03", RadarPlan.build(new Stub().api("<html>429 Too Many Requests</html>"), 52.09, 5.29, 7) == null);
    }

    static void radarTruncated() {
        scenario("SG04", "radar: truncated JSON body (proxy cut the connection) -> placeholder");
        check("SG04", RadarPlan.build(new Stub().api("{\"types\":{\"rain\":{\"radar\":["), 52.09, 5.29, 7) == null);
        check("SG04b", RadarPlan.build(new Stub().api(""), 52.09, 5.29, 7) == null);
    }

    static void radarRealHttp() throws Exception {
        scenario("SG05", "radar: tiles fetched over real HTTP -> grid built, attribution kept");
        HttpServer srv = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        String base = "http://127.0.0.1:" + srv.getAddress().getPort() + "/tiles/";
        srv.createContext("/tiles/", ex -> {
            byte[] b = "fake-png".getBytes(StandardCharsets.UTF_8);
            ex.sendResponseHeaders(200, b.length); ex.getResponseBody().write(b); ex.close();
        });
        srv.start();
        RadarPlan.Plan p = RadarPlan.build(new Composite(apiJson(base, "2026-11-25T12:30:00Z", 5, 9),
            new HttpRadarFetcher()), 52.09, 5.29, 7);
        check("SG05", p != null && p.hasTiles() && p.attribution.equals("RainViewer"));
        check("SG05b", p != null && p.tiles.size() == RadarTiles.tilesAcross(p.zoom));
        srv.stop(0);
    }

    static void radarNoTiles() {
        scenario("SG06", "radar: frames without tiles[] -> placeholder");
        check("SG06", RadarPlan.build(new Stub().api("{\"info\":{},\"types\":{\"rain\":{\"radar\":[{\"date\":\"d\"}]}}}"),
            52.09, 5.29, 7) == null);
    }

    static void radarEmptyTypes() {
        scenario("SG07", "radar: API with empty types / empty tiles[] -> placeholder");
        check("SG07", RadarPlan.build(new Stub().api("{\"info\":{},\"types\":{}}"), 52.09, 5.29, 7) == null);
        check("SG07b", RadarPlan.build(new Stub().api("{\"types\":{\"rain\":{\"radar\":[{\"date\":\"d\",\"tiles\":[]}]}}}}"),
            52.09, 5.29, 7) == null);
    }

    static void radarTemplateNoPlaceholders() {
        scenario("SG08", "radar: tile URL without {z}/{x}/{y} -> still one URL, grid draws");
        RadarPlan.Plan p = RadarPlan.build(new Stub().api("{\"types\":{\"rain\":{\"radar\":[{\"date\":\"d\","
            + "\"tiles\":[{\"url\":\"https://t/static.png\",\"minZoom\":5,\"maxZoom\":9}]}]}}}"), 52.09, 5.29, 7);
        check("SG08", p != null && p.hasTiles());
    }

    static void radarAllTilesFail() {
        scenario("SG09", "radar: API ok but every tile fails -> placeholder, no half-blank card");
        RadarPlan.Plan p = RadarPlan.build(new Stub().api(GOOD_API).mode(Stub.TILES_FAIL_ALL), 52.09, 5.29, 7);
        check("SG09", p != null && !p.hasTiles());
    }

    static void radarHalfTilesFail() {
        scenario("SG10", "radar: every other tile fails -> partial grid still draws");
        RadarPlan.Plan p = RadarPlan.build(new Stub().api(GOOD_API).mode(Stub.TILES_FAIL_HALF), 52.09, 5.29, 7);
        check("SG10", p != null && p.hasTiles() && p.tiles.size() == RadarTiles.tilesAcross(7) / 2);
    }

    static void radarOversized() {
        scenario("SG11", "radar: oversized body (>1.5 MB) -> treated as failure, no memory blowup");
        byte[] big = new byte[RadarPlan.MAX_BODY_BYTES + 16];
        Arrays.fill(big, (byte) 'x');
        RadarFetcher f = url -> big;
        check("SG11", RadarPlan.build(f, 52.09, 5.29, 7) == null);
        RadarFetcher tilesBig = url -> url.contains("radar_by_zoom") ? GOOD_API.getBytes(StandardCharsets.UTF_8) : big;
        RadarPlan.Plan p = RadarPlan.build(tilesBig, 52.09, 5.29, 7);
        check("SG11b", p != null && !p.hasTiles()); // oversized tiles skipped -> placeholder
    }

    static void radarNaNCoords() {
        scenario("SG12", "radar: corrupted prefs coords (NaN / absurd) -> owner defaults, grid builds");
        double[] c = RadarPlan.sanitizeCoords(Double.NaN, Double.NaN);
        check("SG12", c[0] == SettingsKeys.DEFAULT_LAT && c[1] == SettingsKeys.DEFAULT_LON);
        RadarPlan.Plan p = RadarPlan.build(new Stub().api(GOOD_API), Double.NaN, 1e9, 7);
        check("SG12b", p != null && p.hasTiles());
    }

    static void radarExtremeZoom() {
        scenario("SG13", "radar: zoom 0 / zoom 30 -> clamped to 3..12, bounded tile count");
        check("SG13", RadarPlan.sanitizeZoom(0) == 3 && RadarPlan.sanitizeZoom(30) == 12);
        RadarPlan.Plan p = RadarPlan.build(new Stub().api(GOOD_API), 52.09, 5.29, 30);
        check("SG13b", p != null && p.zoom <= RadarPlan.ZOOM_MAX && p.tiles.size() <= RadarTiles.tilesAcross(p.zoom));
    }

    static void radarAntimeridian() {
        scenario("SG14", "radar: antimeridian longitude -> tiles wrap horizontally; above/below world skipped");
        int[] c = RadarTiles.clampTile(3, -5, 3);
        check("SG14", c != null && c[0] >= 0 && c[0] < 8);
        check("SG14b", RadarTiles.clampTile(3, 0, -1) == null && RadarTiles.clampTile(3, 0, 8) == null);
        RadarPlan.Plan p = RadarPlan.build(new Stub().api(GOOD_API), 0.0, 179.9, 5);
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
}
