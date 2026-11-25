package org.vibebaking.launcher.logic;

import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * RainViewer v2 tile math + index parsing (spec S15-S17). Pure; HTTP + drawing glue in RadarView.
 * The REAL API (verified live 2026-11-25; the old "rainviewer.com/api/latest/radar_by_zoom/..."
 * endpoint does not exist — it answers HTTP 301 to the website):
 *  - index:  GET https://api.rainviewer.com/public/weather-maps.json
 *            {"version":"2.0","generated":<unix>,"host":"https://tilecache.rainviewer.com",
 *             "radar":{"past":[{"time":<unix>,"path":"/v2/radar/<id>"}, ... oldest first],
 *             "nowcast":[]}}  — nowcast is EMPTY on RainViewer: never rely on it.
 *  - tile:   {host}{path}/{size}/{z}/{x}/{y}/{color}/{options}.png  (size 256, color 2,
 *            options "1_1") — a transparent PNG overlay, so a base map must be drawn under it.
 *  - zoom:   real tiles only up to z=7; z>=8 returns one constant placeholder image, so the
 *            requested zoom is clamped to MAX_ZOOM.
 * Tiles are 256px Web-Mercator overlays over OpenStreetMap standard tiles (same slippy grid; CARTO basemaps now
 * answer "API KEY REQUIRED"). OSM has no dark style: RadarView tints the base tiles at night.
 */
public final class RadarTiles {

    public static final String INDEX_URL = "https://api.rainviewer.com/public/weather-maps.json";
    public static final String TILECACHE = "https://tilecache.rainviewer.com"; // index host fallback
    public static final String BASE_DAY = "https://tile.openstreetmap.org/";
    public static final String BASE_NIGHT = BASE_DAY; // same tiles, darkened when drawn
    /** Attribution required by the tile providers (spec S17). */
    public static final String ATTRIBUTION = "\u00A9 OpenStreetMap contributors \u00B7 Radar: RainViewer";

    public static final int TILE_PX = 256;
    public static final int COLOR_SCHEME = 2;      // RainViewer colour scheme
    public static final String TILE_OPTIONS = "1_1"; // loop + radar sites labels
    public static final int VIEW_W = 1024;   // the car panel (S3)
    public static final int VIEW_H = 600;
    public static final int DEFAULT_ZOOM = 7;
    public static final int MAX_ZOOM = 7;    // above this RainViewer serves a constant placeholder

    private RadarTiles() {}

    /** Requested zoom, clamped into what RainViewer can actually serve (never above MAX_ZOOM). */
    public static int clampZoom(int zoom) { return Math.max(1, Math.min(zoom, MAX_ZOOM)); }

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

    /**
     * Radar overlay tile: {host}{path}/{size}/{z}/{x}/{y}/{color}/{options}.png.
     * The index gives host (never ending in '/') and path (starting with '/'); an absolute http
     * path is accepted defensively. Example:
     * https://tilecache.rainviewer.com/v2/radar/1d6614366d81/256/7/65/42/2/1_1.png
     */
    public static String radarTileUrl(String host, String path, int z, int x, int y) {
        String base;
        if (path.startsWith("http")) {
            base = path; // frame already carries an absolute URL
        } else {
            String h = host == null || host.isEmpty() ? TILECACHE : host;
            if (h.endsWith("/")) h = h.substring(0, h.length() - 1);
            base = h + (path.startsWith("/") ? path : "/" + path);
        }
        if (base.endsWith("/")) base = base.substring(0, base.length() - 1);
        return base + "/" + TILE_PX + "/" + z + "/" + x + "/" + y + "/" + COLOR_SCHEME + "/" + TILE_OPTIONS + ".png";
    }

    /** OpenStreetMap base tile under the transparent radar layer: same slippy x/y/z, day light / night dark. */
    public static String baseTileUrl(boolean night, int z, int x, int y) {
        return (night ? BASE_NIGHT : BASE_DAY) + z + "/" + x + "/" + y + ".png";
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

    /** Tile coordinate clamped to the world grid; null = outside the map (skip drawing). */
    public static int[] clampTile(int zoom, int x, int y) {
        int n = (int) Math.pow(2.0, zoom);
        if (y < 0 || y >= n) return null;
        int xx = Math.floorMod(x, n); // wrap horizontally around the antimeridian
        return new int[] { xx, y };
    }

    /** One radar frame from the index: timestamp (unix seconds) + tile path. */
    public static final class Frame {
        public long timeSec;
        public String path;
    }

    public static final class RadarSpec {
        public String host = TILECACHE;
        public List<Frame> frames = new ArrayList<>();
    }

    /** Parse weather-maps.json: radar.past frames only (satellite and empty nowcast ignored). */
    public static RadarSpec parseApi(String json) {
        RadarSpec spec = new RadarSpec();
        Map<String, Object> root = Json.object(Json.parse(json));
        String host = Json.str(root.get("host"));
        if (!host.isEmpty()) spec.host = host;
        Object radar = root.get("radar");
        if (radar == null) return spec;
        Object past = Json.object(radar).get("past");
        if (past == null) return spec;
        for (Object f : Json.array(past)) {
            Map<String, Object> fm = Json.object(f);
            String path = Json.str(fm.get("path"));
            if (path.isEmpty()) continue; // a past entry without a path cannot be drawn
            Frame fr = new Frame();
            Double t = Json.num(fm.get("time"));
            fr.timeSec = t == null ? 0L : t.longValue();
            fr.path = path;
            spec.frames.add(fr);
        }
        return spec;
    }

    /** Newest frame by frame time (the API lists frames oldest first; we want the latest). */
    public static Frame pickLatest(RadarSpec spec) {
        Frame best = null;
        for (Frame f : spec.frames) {
            if (f == null || f.path == null || f.path.isEmpty()) continue;
            if (best == null || f.timeSec > best.timeSec) best = f;
        }
        return best;
    }

    /** ISO-UTC label for a frame timestamp, shown alongside the attribution. */
    public static String frameLabel(long timeSec) {
        return timeSec > 0 ? Instant.ofEpochSecond(timeSec).toString() : "";
    }

    /** Own style (spec S16): day light basemap + saturated rain; night dark basemap + muted rain. */
    public static int[] palette(boolean night) {
        // [fallback background ARGB (only visible while base tiles are missing), rainAlpha]
        return night ? new int[] { argb(18, 20, 27), 150 } : new int[] { argb(239, 230, 217), 255 };
    }

    public static int argb(int r, int g, int b) { return (0xFF << 24) | (r << 16) | (g << 8) | b; }
}
