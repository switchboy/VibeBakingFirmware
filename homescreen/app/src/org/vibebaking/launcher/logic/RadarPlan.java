package org.vibebaking.launcher.logic;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

/**
 * Radar tile-plan builder (spec S15-S17 + degrade paths S18'). Pure: takes a fetcher stub,
 * returns the tile grid to draw, or null when the API is unreachable/malformed (placeholder path).
 * Android glue in RadarView only decodes bitmaps; every network/format failure decision lives here
 * so it is unit-smokable on the workstation (see tests/unit/Smoke.java).
 */
public final class RadarPlan {

    public static final int ZOOM_MIN = 3;
    public static final int ZOOM_MAX = 12;
    public static final int MAX_BODY_BYTES = 1_500_000;

    /** One fetched tile: raw PNG bytes plus its pixel position inside the viewport. */
    public static final class Tile {
        public final byte[] png;
        public final int px, py;
        Tile(byte[] png, int px, int py) { this.png = png; this.px = px; this.py = py; }
    }

    public static final class Plan {
        public String attribution = "";
        public String frameDate = "";
        public int zoom;
        public int[] origin;               // px offset of the tile grid top-left
        public final List<Tile> tiles = new ArrayList<>();

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
     * Fetch the API answer and the tile grid. Never throws: any failure yields null (offline /
     * bad JSON / no frames). Per-tile failures are skipped, so a partial grid still draws.
     */
    public static Plan build(RadarFetcher fetcher, double lat, double lon, int wantedZoom) {
        if (fetcher == null) return null;
        double[] c = sanitizeCoords(lat, lon);
        int z0 = sanitizeZoom(wantedZoom);
        RadarTiles.RadarSpec spec;
        try {
            byte[] api = cap(fetcher.fetch(RadarTiles.apiUrl(c[0], c[1], z0)));
            spec = RadarTiles.parseApi(new String(api, StandardCharsets.UTF_8));
        } catch (Throwable apiFail) {
            return null; // offline, DNS down, HTTP error, truncated/garbage JSON
        }
        RadarTiles.Frame f = RadarTiles.pickLayer(spec, z0);
        if (f == null || f.urlTemplate == null || f.urlTemplate.isEmpty()) return null;
        int z = RadarTiles.zoomFor(f, z0);
        int[] o = RadarTiles.gridOriginPx(c[0], c[1], z);
        int tilesW = (RadarTiles.VIEW_W + RadarTiles.TILE_PX - 1) / RadarTiles.TILE_PX;
        int tilesH = (RadarTiles.VIEW_H + RadarTiles.TILE_PX - 1) / RadarTiles.TILE_PX;
        int topX = Math.floorDiv(o[0], RadarTiles.TILE_PX);
        int topY = Math.floorDiv(o[1], RadarTiles.TILE_PX);

        Plan plan = new Plan();
        plan.attribution = spec.attribution;
        plan.frameDate = f.date;
        plan.zoom = z;
        plan.origin = o;
        for (int gy = 0; gy < tilesH; gy++) {
            for (int gx = 0; gx < tilesW; gx++) {
                int[] xy = RadarTiles.clampTile(z, topX + gx, topY + gy);
                if (xy == null) continue; // outside the world grid: skip (poles/edges)
                try {
                    byte[] png = cap(fetcher.fetch(RadarTiles.tileUrl(f.urlTemplate, z, xy[0], xy[1])));
                    plan.tiles.add(new Tile(png, xy[0] * RadarTiles.TILE_PX - o[0],
                                            xy[1] * RadarTiles.TILE_PX - o[1]));
                } catch (Throwable tileFail) {
                    // one tile down (HTTP 404/timeout): keep the rest of the grid
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
