package org.vibebaking.launcher.logic;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

/**
 * Radar tile-plan builder (spec S15-S17 + degrade paths S18'). Pure: takes a fetcher stub,
 * returns the tile grid to draw, or null when the API is unreachable/malformed (placeholder path).
 * Android glue in RadarView only decodes bitmaps; every network/format failure decision lives here
 * so it is unit-smokable on the workstation (see tests/unit/Smoke.java).
 * Round 3: the plan now covers BOTH layers — OpenStreetMap base tiles (drawn first, cached by the caller)
 * and the transparent RainViewer overlay from the latest radar.past frame of weather-maps.json.
 * Zoom is clamped to RadarTiles.MAX_ZOOM (7): above that RainViewer serves one placeholder image.
 */
public final class RadarPlan {

    public static final int ZOOM_MIN = 3;
    public static final int ZOOM_MAX = RadarTiles.MAX_ZOOM; // 7 (verified: z>=8 is a constant placeholder)
    public static final int MAX_BODY_BYTES = 1_500_000;

    /** One fetched tile: raw PNG bytes, its pixel position inside the viewport, and its URL. */
    public static final class Tile {
        public final byte[] png;
        public final int px, py;
        public final String url; // caller-side cache key (base tiles never change)
        Tile(byte[] png, int px, int py, String url) { this.png = png; this.px = px; this.py = py; this.url = url; }
    }

    public static final class Plan {
        public String attribution = RadarTiles.ATTRIBUTION;
        public String frameDate = "";
        public int zoom;
        public int[] origin;               // px offset of the tile grid top-left
        public final List<Tile> baseTiles = new ArrayList<>(); // OpenStreetMap basemap (drawn under the radar)
        public final List<Tile> tiles = new ArrayList<>();     // RainViewer overlay (transparent PNG)

        /** false = nothing to draw -> the caller shows the placeholder (S18'). */
        public boolean hasTiles() { return origin != null && !tiles.isEmpty(); }
    }

    private RadarPlan() {}

    /** Coordinate sanity: NaN / out-of-range pref values fall back to the owner defaults. */
    public static double[] sanitizeCoords(double lat, double lon) {
        double l = lat, n = lon;
        if (Double.isNaN(l) || Double.isInfinite(l) || l < -85 || l > 85) l = SettingsKeys.DEFAULT_LAT;
        if (Double.isNaN(n) || Double.isInfinite(n) || n < -180 || n > 180) n = SettingsKeys.DEFAULT_LON;
        return new double[] { l, n };
    }

    public static int sanitizeZoom(int zoom) { return Math.max(ZOOM_MIN, Math.min(ZOOM_MAX, zoom)); }

    /**
     * Fetch the frame index and both tile grids. Never throws: any failure yields null (offline,
     * DNS down, HTTP error, garbage JSON, no usable frames). Per-tile failures are skipped, so a
     * partial grid still draws. `night` picks the night tint; the latest radar.past frame wins.
     */
    public static Plan build(RadarFetcher fetcher, double lat, double lon, int wantedZoom, boolean night) {
        if (fetcher == null) return null;
        double[] c = sanitizeCoords(lat, lon);
        int z = sanitizeZoom(wantedZoom);
        RadarTiles.RadarSpec spec;
        try {
            byte[] api = cap(fetcher.fetch(RadarTiles.INDEX_URL));
            spec = RadarTiles.parseApi(new String(api, StandardCharsets.UTF_8));
        } catch (Throwable apiFail) {
            return null; // offline, DNS down, HTTP error, truncated/garbage JSON
        }
        RadarTiles.Frame f = RadarTiles.pickLatest(spec);
        if (f == null || f.path == null || f.path.isEmpty()) return null;
        int[] o = RadarTiles.gridOriginPx(c[0], c[1], z);
        int tilesW = (RadarTiles.VIEW_W + RadarTiles.TILE_PX - 1) / RadarTiles.TILE_PX;
        int tilesH = (RadarTiles.VIEW_H + RadarTiles.TILE_PX - 1) / RadarTiles.TILE_PX;
        int topX = Math.floorDiv(o[0], RadarTiles.TILE_PX);
        int topY = Math.floorDiv(o[1], RadarTiles.TILE_PX);

        Plan plan = new Plan();
        plan.attribution = RadarTiles.ATTRIBUTION;
        plan.frameDate = RadarTiles.frameLabel(f.timeSec);
        plan.zoom = z;
        plan.origin = o;
        // Two passes: base tiles first (they never change, the caller caches them by URL), then
        // the transparent radar overlay. A dead tile in either pass is skipped, never fatal.
        for (int pass = 0; pass < 2; pass++) {
            for (int gy = 0; gy < tilesH; gy++) {
                for (int gx = 0; gx < tilesW; gx++) {
                    int[] xy = RadarTiles.clampTile(z, topX + gx, topY + gy);
                    if (xy == null) continue; // outside the world grid: skip (poles/edges)
                    String url = pass == 0 ? RadarTiles.baseTileUrl(night, z, xy[0], xy[1])
                                           : RadarTiles.radarTileUrl(spec.host, f.path, z, xy[0], xy[1]);
                    try {
                        byte[] png = cap(fetcher.fetch(url));
                        Tile t = new Tile(png, xy[0] * RadarTiles.TILE_PX - o[0],
                                          xy[1] * RadarTiles.TILE_PX - o[1], url);
                        if (pass == 0) plan.baseTiles.add(t); else plan.tiles.add(t);
                    } catch (Throwable tileFail) {
                        // one tile down (HTTP 404/timeout/oversized): keep the rest of the grid
                    }
                }
            }
        }
        return plan;
    }

    /** Bound memory on hostile bodies; oversized = treated as a failure by the caller. */
    static byte[] cap(byte[] body) {
        if (body == null) throw new IllegalStateException("empty response");
        if (body.length > MAX_BODY_BYTES) throw new IllegalStateException("response too large");
        return body;
    }
}
