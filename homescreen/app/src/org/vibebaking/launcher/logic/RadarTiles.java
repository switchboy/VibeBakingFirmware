package org.vibebaking.launcher.logic;

import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * RainViewer tile math + API parsing (spec S15-S17). Pure; HTTP + drawing glue in RadarView.
 * API: https://rainviewer.com/api/latest/radar_by_zoom/<zoom>/<lat>/<lon>/en.json
 * Answer carries info.attribution and types.rain.radar[] frames, each with tiles[] holding a
 * "{z}/{x}/{y}" template plus minZoom/maxZoom. Tiles are 256px Web-Mercator PNG overlays.
 */
public final class RadarTiles {

    public static final String BASE = "https://rainviewer.com";
    public static final int TILE_PX = 256;
    public static final int VIEW_W = 1024;   // the car panel (S3)
    public static final int VIEW_H = 600;
    public static final int DEFAULT_ZOOM = 7;

    private RadarTiles() {}

    public static String apiUrl(double lat, double lon, int zoom) {
        return BASE + "/api/latest/radar_by_zoom/" + zoom
             + "/" + fmtCoord(lat) + "/" + fmtCoord(lon) + "/en.json";
    }

    static String fmtCoord(double v) {
        String s = String.format(Locale.ROOT, "%.4f", v);
        while (s.contains(".") && (s.endsWith("0"))) s = s.substring(0, s.length() - 1);
        if (s.endsWith(".")) s = s.substring(0, s.length() - 1);
        return s;
    }

    /** Web-Mercator tile coordinates (slippy math). */
    public static int tileX(double lonDeg, int zoom) {
        double n = Math.pow(2.0, zoom);
        double x = (lonDeg + 180.0) / 360.0 * n;
        return Math.max(0, Math.min((int) n - 1, (int) Math.floor(x)));
    }

    public static int tileY(double latDeg, int zoom) {
        double n = Math.pow(2.0, zoom);
        double rad = Math.toRadians(latDeg);
        double y = (1.0 - Math.log(Math.tan(rad) + 1.0 / Math.cos(rad)) / Math.PI) / 2.0 * n;
        return Math.max(0, Math.min((int) n - 1, (int) Math.floor(y)));
    }

    public static String tileUrl(String template, int z, int x, int y) {
        return template.replace("{z}", String.valueOf(z))
                       .replace("{x}", String.valueOf(x))
                       .replace("{y}", String.valueOf(y));
    }

    /** Pixel offset (top-left corner of the tile grid) so the viewport centers on lat/lon. */
    public static int[] gridOriginPx(double lat, double lon, int zoom) {
        double n = Math.pow(2.0, zoom);
        double rad = Math.toRadians(lat);
        double cx = (lon + 180.0) / 360.0 * n * TILE_PX;
        double cy = (1.0 - Math.log(Math.tan(rad) + 1.0 / Math.cos(rad)) / Math.PI) / 2.0 * n * TILE_PX;
        return new int[] { (int) Math.floor(cx - VIEW_W / 2.0), (int) Math.floor(cy - VIEW_H / 2.0) };
    }

    public static int tilesAcross(int zoom) {
        int tilesW = (VIEW_W + TILE_PX - 1) / TILE_PX;
        int tilesH = (VIEW_H + TILE_PX - 1) / TILE_PX;
        return tilesW * tilesH;
    }

    /** Top-left tile of the viewport grid; grid covers tilesAcross() tiles. */
    public static int[] gridTopTile(double lat, double lon, int zoom) {
        int[] o = gridOriginPx(lat, lon, zoom);
        int[] xy = { o[0] / TILE_PX, o[1] / TILE_PX };
        return xy;
    }

    public static final class Frame {
        public String date;
        public String layer;
        public String urlTemplate;
        public int minZoom;
        public int maxZoom;
    }

    public static final class RadarSpec {
        public String attribution = "";
        public List<Frame> frames = new ArrayList<>();
    }

    /** Parse the API answer; rain type preferred, snow as fallback (owner: rain radar). */
    public static RadarSpec parseApi(String json) {
        RadarSpec spec = new RadarSpec();
        Map<String, Object> root = Json.object(Json.parse(json));
        Object info = root.get("info");
        if (info != null) spec.attribution = Json.str(Json.object(info).get("attribution"));
        Map<String, Object> types = Json.object(root.get("types"));
        List<Object> groups = new ArrayList<>();
        Object rain = types.get("rain");
        if (rain != null) groups.add(rain);
        Object snow = types.get("snow");
        if (snow != null && groups.isEmpty()) groups.add(snow);
        for (Object g : groups) {
            Object radar = Json.object(g).get("radar");
            if (radar == null) continue;
            for (Object f : Json.array(radar)) {
                Map<String, Object> fm = Json.object(f);
                Frame fr = new Frame();
                fr.date = Json.str(fm.get("date"));
                fr.layer = Json.str(fm.get("layer"));
                Object tiles = fm.get("tiles");
                if (tiles == null || Json.array(tiles).isEmpty()) continue;
                Map<String, Object> t = Json.object(Json.array(tiles).get(0));
                fr.urlTemplate = Json.str(t.get("url"));
                Double mn = Json.num(t.get("minZoom"));
                Double mx = Json.num(t.get("maxZoom"));
                fr.minZoom = mn == null ? 4 : mn.intValue();
                fr.maxZoom = mx == null ? 9 : mx.intValue();
                spec.frames.add(fr);
            }
        }
        return spec;
    }

    /** Latest frame by ISO date (Instant when parseable, else plain string comparison). */
    public static Frame pickLatest(RadarSpec spec) {
        Frame best = null;
        String bestKey = "";
        for (Frame f : spec.frames) {
            String key = f.date;
            try { key = String.valueOf(Instant.parse(f.date).toEpochMilli()); }
            catch (RuntimeException ignore) { /* keep ISO string; sorts correctly lexicographically */ }
            if (best == null || key.compareTo(bestKey) > 0) { best = f; bestKey = key; }
        }
        return best;
    }

    /** A frame that can serve the wanted zoom (clamped into its [minZoom,maxZoom]). */
    public static Frame pickLayer(RadarSpec spec, int wantedZoom) {
        Frame f = pickLatest(spec);
        if (f == null) return null;
        int z = Math.max(f.minZoom, Math.min(wantedZoom, f.maxZoom));
        Frame adjusted = new Frame();
        adjusted.date = f.date; adjusted.layer = f.layer; adjusted.urlTemplate = f.urlTemplate;
        adjusted.minZoom = f.minZoom; adjusted.maxZoom = f.maxZoom;
        return adjusted; // zoom itself is applied by tileUrl/gridOrigin callers
    }

    /** Effective zoom for a frame given the wanted one, clamped into the frame's range. */
    public static int zoomFor(Frame f, int wantedZoom) {
        return Math.max(f.minZoom, Math.min(wantedZoom, f.maxZoom));
    }

    /** Tile coordinate clamped to the world grid; null = outside the map (skip drawing). */
    public static int[] clampTile(int zoom, int x, int y) {
        int n = (int) Math.pow(2.0, zoom);
        if (y < 0 || y >= n) return null;
        int xx = Math.floorMod(x, n); // wrap horizontally around the antimeridian
        return new int[] { xx, y };
    }

    /** Own style (spec S16): day light basemap + saturated rain; night dark basemap + muted rain. */
    public static int[] palette(boolean night) {
        // [baseMapArgb, rainAlpha]
        return night ? new int[] { argb(18, 20, 27), 150 } : new int[] { argb(239, 230, 217), 255 };
    }

    public static int argb(int r, int g, int b) { return (0xFF << 24) | (r << 16) | (g << 8) | b; }
}
