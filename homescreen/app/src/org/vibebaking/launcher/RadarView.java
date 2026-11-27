package org.vibebaking.launcher;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Rect;
import android.os.Handler;
import android.os.Looper;
import android.util.AttributeSet;
import android.view.View;

import org.vibebaking.launcher.logic.RadarFetcher;
import org.vibebaking.launcher.logic.RadarPlan;
import org.vibebaking.launcher.logic.RadarTiles;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Rain radar (spec S15-S17, S18'): OpenStreetMap base tiles under the transparent RainViewer overlay.
 * Round 3: the overlay alone has no geographic reference (owner: radar shows nothing useful), so
 * the basemap is drawn first, light by day / dark by night (the existing night decision), and
 * decoded base tiles are cached in memory — they never change. HTTP + bitmap decoding stay off
 * the UI thread; every failure degrades to the "offline" placeholder, never a crash.
 */
public class RadarView extends View {

    public static final long REFRESH_MS = 5 * 60_000L; // index at most every 5 min (RainViewer frames update ~ every 10 min)

    private final RadarFetcher fetcher;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final Paint paint = new Paint(Paint.FILTER_BITMAP_FLAG);
    private static final android.graphics.LightingColorFilter NIGHT_BASE =
            new android.graphics.LightingColorFilter(0xFF3A4250, 0x00000000);
    // Owner 2026-11-27: draw the OSM base tiles see-through so the card background shows
    // through and the rain overlay stands out. ~0.55 by day, ~0.45 by night (on top of the
    // NIGHT_BASE tint); the radar overlay keeps its palette alpha (palette[1]) unchanged.
    private static final int BASE_ALPHA_DAY = 140;    // 0.55 * 255
    private static final int BASE_ALPHA_NIGHT = 115;  // 0.45 * 255
    private double lat, lon;
    private int zoom = RadarTiles.DEFAULT_ZOOM;
    private boolean night;

    private String attribution = "";
    private String frameDate = "";
    private int[] origin = null;      // px offset of the tile grid top-left
    private final List<BitmapPos> baseTiles = new ArrayList<>(); // basemap (decoded from the cache)
    private final List<BitmapPos> tiles = new ArrayList<>();     // radar overlay (fresh every load)
    private boolean loading;
    private boolean stopped;

    static final class BitmapPos {
        final Bitmap b; final int px, py;
        BitmapPos(Bitmap b, int px, int py) { this.b = b; this.px = px; this.py = py; }
    }

    /** Decoded basemap tiles never change (same z/x/y + theme): cache across loads and themes. */
    private static final Map<String, Bitmap> BASE_CACHE = new HashMap<>();

    public interface AttributionSink { void setAttribution(String text, String frameDate); }
    private AttributionSink sink;

    public RadarView(Context c, AttributeSet attrs) { this(c, attrs, new HttpRadarFetcher()); }
    public RadarView(Context c, AttributeSet attrs, RadarFetcher fetcher) {
        super(c, attrs);
        this.fetcher = fetcher;
    }
    public RadarView(Context c, RadarFetcher fetcher) { this(c, null, fetcher); }

    public void setLatLon(double lat, double lon) { this.lat = lat; this.lon = lon; }

    /** Night switch: repaint immediately, and refetch the dark basemap when the theme changed (S16). */
    public void setNight(boolean night) {
        if (this.night != night) { this.night = night; load(); }
        invalidate();
    }

    public void setSink(AttributionSink s) { this.sink = s; }

    /**
     * Fetch the frame index + both tile grids off the main thread and decode there too. All
     * failure decisions are in RadarPlan (pure), so offline / bad JSON / empty frames / partial
     * tiles degrade to the placeholder (spec S18').
     */
    public void load() {
        if (loading || stopped) return;
        loading = true;
        scheduleRefresh();
        final boolean wantNight = night;
        new Thread(() -> {
            RadarPlan.Plan plan = RadarPlan.build(fetcher, lat, lon, zoom, wantNight);
            String att = "";
            String date = "";
            int[] o = null;
            List<BitmapPos> freshBase = new ArrayList<>();
            List<BitmapPos> freshRadar = new ArrayList<>();
            if (plan != null) {
                att = plan.attribution;
                date = plan.frameDate;
                o = plan.origin;
                zoom = plan.zoom;
                for (RadarPlan.Tile t : plan.baseTiles) {
                    Bitmap b;
                    synchronized (BASE_CACHE) { b = BASE_CACHE.get(t.url); }
                    if (b == null) {
                        try { b = BitmapFactory.decodeByteArray(t.png, 0, t.png.length); }
                        catch (Throwable decodeFail) { b = null; } // corrupt basemap tile: skip
                        if (b != null) synchronized (BASE_CACHE) { BASE_CACHE.put(t.url, b); }
                    }
                    if (b != null) freshBase.add(new BitmapPos(b, t.px, t.py));
                }
                for (RadarPlan.Tile t : plan.tiles) {
                    try {
                        Bitmap b = BitmapFactory.decodeByteArray(t.png, 0, t.png.length);
                        if (b != null) freshRadar.add(new BitmapPos(b, t.px, t.py)); // undecodable body: skip
                    } catch (Throwable decodeFail) { /* corrupt tile: skip, keep the rest */ }
                }
            }
            // Replace the grid wholesale: a failed/empty fetch must clear stale tiles (S18').
            attribution = att;
            frameDate = date;
            origin = o;
            baseTiles.clear();
            tiles.clear();
            baseTiles.addAll(freshBase);
            tiles.addAll(freshRadar);
            loading = false;
            main.post(() -> {
                invalidate();
                if (sink != null) sink.setAttribution(attribution, frameDate);
            });
        }).start();
    }

    /** Stop + reload the periodic refresh: recreation must not stack timers (one timer only). */
    private final Runnable refresh = this::load;

    private void scheduleRefresh() {
        main.removeCallbacks(refresh);
        main.postDelayed(refresh, REFRESH_MS);
    }

    public void stop() {
        stopped = true;
        main.removeCallbacks(refresh);
    }

    public void restart() {
        stopped = false;
        load();
    }

    @Override
    protected void onDraw(Canvas canvas) {
        int[] palette = RadarTiles.palette(night);
        paint.setAlpha(255);
        paint.setColor(palette[0]); // fallback background: visible while base tiles are missing
        canvas.drawRect(new Rect(0, 0, getWidth(), getHeight()), paint);
        if (origin == null || tiles.isEmpty()) {
            paint.setColor(night ? 0xFF8A93A3 : 0xFF5A6470); // dim placeholder text, never white
            paint.setTextSize(30f);
            canvas.drawText(getContext().getString(R.string.radar_placeholder),
                            24f, getHeight() / 2f, paint);
            return;
        }
        // The plan puts the position at the centre of a VIEW_W x VIEW_H (full screen) frame; the card is smaller, so
        // shift that centre to the card's centre (first on-device run showed the frame's top-left corner instead).
        canvas.save();
        canvas.translate(getWidth() / 2f - RadarTiles.VIEW_W / 2f, getHeight() / 2f - RadarTiles.VIEW_H / 2f);
        // basemap first; OSM has no dark style, so at night the tiles are multiplied down to a dim blue-grey
        paint.setColorFilter(night ? NIGHT_BASE : null);
        paint.setAlpha(night ? BASE_ALPHA_NIGHT : BASE_ALPHA_DAY); // see-through basemap (owner 2026-11-27)
        for (BitmapPos t : baseTiles) canvas.drawBitmap(t.b, t.px, t.py, paint);
        paint.setColorFilter(null);
        paint.setAlpha(palette[1]); // radar overlay keeps its alpha: day saturated, night muted (spec S16)
        for (BitmapPos t : tiles) canvas.drawBitmap(t.b, t.px, t.py, paint);
        canvas.restore();
    }
}
