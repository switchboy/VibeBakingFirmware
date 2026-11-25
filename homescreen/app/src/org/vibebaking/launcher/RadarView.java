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
import java.util.List;

/** Stylised rain radar (spec S15-S17, S18'): RainViewer tiles over our own basemap. */
public class RadarView extends View {

    public static final long REFRESH_MS = 10 * 60_000L; // RainViewer refreshes ~ every 5-10 min

    private final RadarFetcher fetcher;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final Paint paint = new Paint(Paint.FILTER_BITMAP_FLAG);
    private double lat, lon;
    private int zoom = RadarTiles.DEFAULT_ZOOM;
    private boolean night;

    private String attribution = "";
    private String frameDate = "";
    private int[] origin = null;      // px offset of the tile grid top-left
    private final List<BitmapPos> tiles = new ArrayList<>();
    private boolean loading;
    private boolean stopped;

    static final class BitmapPos {
        final Bitmap b; final int px, py;
        BitmapPos(Bitmap b, int px, int py) { this.b = b; this.px = px; this.py = py; }
    }

    public interface AttributionSink { void setAttribution(String text, String frameDate); }
    private AttributionSink sink;

    public RadarView(Context c, AttributeSet attrs) { this(c, attrs, new HttpRadarFetcher()); }
    public RadarView(Context c, AttributeSet attrs, RadarFetcher fetcher) {
        super(c, attrs);
        this.fetcher = fetcher;
    }
    public RadarView(Context c, RadarFetcher fetcher) { this(c, null, fetcher); }

    public void setLatLon(double lat, double lon) { this.lat = lat; this.lon = lon; }

    public void setNight(boolean night) {
        this.night = night;
        invalidate(); // spec S16: dark basemap + muted rain at night
    }

    public void setSink(AttributionSink s) { this.sink = s; }

    /**
     * Fetch API + tiles off the main thread. All failure decisions are in RadarPlan (pure), so
     * offline / bad JSON / empty frames / partial tiles degrade to the placeholder (spec S18').
     */
    public void load() {
        if (loading || stopped) return;
        loading = true;
        scheduleRefresh();
        new Thread(() -> {
            RadarPlan.Plan plan = RadarPlan.build(fetcher, lat, lon, zoom);
            String att = "";
            String date = "";
            int[] o = null;
            List<BitmapPos> fresh = new ArrayList<>();
            if (plan != null) {
                att = plan.attribution;
                date = plan.frameDate;
                o = plan.origin;
                zoom = plan.zoom;
                for (RadarPlan.Tile t : plan.tiles) {
                    try {
                        Bitmap b = BitmapFactory.decodeByteArray(t.png, 0, t.png.length);
                        if (b != null) fresh.add(new BitmapPos(b, t.px, t.py)); // undecodable body: skip
                    } catch (Throwable decodeFail) { /* corrupt tile: skip, keep the rest */ }
                }
            }
            // Replace the grid wholesale: a failed/empty fetch must clear stale tiles (S18').
            attribution = att;
            frameDate = date;
            origin = o;
            tiles.clear();
            tiles.addAll(fresh);
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
        paint.setColor(palette[0]);
        canvas.drawRect(new Rect(0, 0, getWidth(), getHeight()), paint);
        if (origin == null || tiles.isEmpty()) {
            paint.setColor(night ? 0xFF8A93A3 : 0xFF5A6470); // dim placeholder text, never white
            paint.setTextSize(30f);
            canvas.drawText(getContext().getString(R.string.radar_placeholder),
                            24f, getHeight() / 2f, paint);
            return;
        }
        paint.setAlpha(palette[1]); // day saturated, night muted (spec S16)
        for (BitmapPos t : tiles) canvas.drawBitmap(t.b, t.px, t.py, paint);
    }
}
