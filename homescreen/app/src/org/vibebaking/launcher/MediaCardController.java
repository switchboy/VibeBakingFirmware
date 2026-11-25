package org.vibebaking.launcher;

import android.content.Context;
import android.graphics.Bitmap;
import android.media.MediaController;
import android.media.MediaMetadata;
import android.media.MediaSessionManager;
import android.os.Handler;
import android.os.Looper;
import android.widget.ImageButton;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

import org.vibebaking.launcher.logic.ArtPalette;
import org.vibebaking.launcher.logic.MediaCardPolicy;

import java.util.ArrayList;
import java.util.List;

/** Media card presentation (spec S10-S14). All decisions delegate to MediaCardPolicy/ArtPalette. */
public class MediaCardController {

    private final Context ctx;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final SettingsStore store;
    private final CarClient car;
    private final ThemeApplier theme;
    private final LinearLayout card;
    private final TextView title, artist, source;
    private final ImageView art;
    private final ImageButton prev, playPause, next;
    private List<MediaController> controllers = new ArrayList<>();
    private int cursor = -1; // active controller index, for source cycling

    public MediaCardController(Context c, LinearLayout card, SettingsStore store,
                               CarClient car, ThemeApplier theme) {
        ctx = c.getApplicationContext();
        this.card = card;
        this.store = store;
        this.car = car;
        this.theme = theme;
        title = card.findViewById(R.id.media_title);
        artist = card.findViewById(R.id.media_artist);
        source = card.findViewById(R.id.media_source);
        art = card.findViewById(R.id.media_art);
        prev = card.findViewById(R.id.media_prev);
        playPause = card.findViewById(R.id.media_play_pause);
        next = card.findViewById(R.id.media_next);
        prev.setOnClickListener(v -> act(MediaCardPolicy.TR_PREV));
        playPause.setOnClickListener(v -> act(MediaCardPolicy.TR_PLAY_PAUSE));
        next.setOnClickListener(v -> act(MediaCardPolicy.TR_NEXT));
        source.setOnClickListener(v -> cycleSource());
    }

    /** Called when the notification listener connects (or from onResume, refreshed periodically). */
    public void refresh() {
        List<MediaController> list = new ArrayList<>();
        if (MediaListenerService.instance == null) {
            showNoAccess();
            return;
        }
        try {
            MediaSessionManager mgr =
                (MediaSessionManager) ctx.getSystemService(Context.MEDIA_SESSION_SERVICE);
            list = mgr.getActiveSessions(MediaListenerService.instance);
        } catch (Throwable t) {
            showNoAccess();
            return;
        }
        if (list == null || list.isEmpty()) {
            controllers = new ArrayList<>();
            cursor = -1;
            showIdle();
            return;
        }
        controllers = list;
        if (cursor < 0 || cursor >= controllers.size()) cursor = pickIndex(list);
        showController(controllers.get(cursor));
    }

    /** Active index per MediaCardPolicy.pickActive over mirrored candidates. */
    int pickIndex(List<MediaController> list) {
        List<MediaCardPolicy.Ctl> mirrors = new ArrayList<>();
        for (MediaController m : list) mirrors.add(mirror(m));
        MediaCardPolicy.Ctl pick = MediaCardPolicy.pickActive(mirrors);
        return pick == null ? 0 : mirrors.indexOf(pick);
    }

    MediaCardPolicy.Ctl mirror(MediaController m) {
        MediaCardPolicy.Ctl c = new MediaCardPolicy.Ctl();
        c.pkg = m.getPackageName();
        try {
            c.pkgLabel = ctx.getPackageManager().getApplicationLabel(
                ctx.getPackageManager().getApplicationInfo(c.pkg, 0));
        } catch (Throwable t) { c.pkgLabel = c.pkg; }
        MediaMetadata md = null;
        try { md = m.getMetadata(); } catch (Throwable ignore) { }
        if (md != null) {
            c.title = md.getString(MediaMetadata.METADATA_KEY_TITLE);
            c.artist = md.getString(MediaMetadata.METADATA_KEY_ARTIST);
            c.album = md.getString(MediaMetadata.METADATA_KEY_ALBUM);
        }
        try {
            android.media.MediaPlayerControl pc = m.getPlayer();
            if (pc != null) {
                c.playing = pc.isPlaying();
                c.canPlayPause = pc.canPause() || pc.canPlayAndPause();
                c.canSkipNext = pc.canSkipToNext();
                c.canSkipPrev = pc.canSkipToPrevious();
            }
        } catch (Throwable ignore) { }
        return c;
    }

    void showController(MediaController m) {
        MediaCardPolicy.Ctl c = mirror(m);
        boolean night = theme.systemNight();
        String station = isRadioPackage(c.pkg) ? radioStationHook() : "";
        title.setText(MediaCardPolicy.radioLabel(station, c));
        artist.setText(night ? MediaCardPolicy.album(c) : "");
        source.setText(c.pkgLabel.isEmpty() ? c.pkg : c.pkgLabel);
        MediaCardPolicy.Ctl pick = c;
        int enabled = MediaCardPolicy.transportEnabled(pick);
        prev.setEnabled((enabled & MediaCardPolicy.TR_PREV) != 0);
        playPause.setEnabled((enabled & MediaCardPolicy.TR_PLAY_PAUSE) != 0);
        next.setEnabled((enabled & MediaCardPolicy.TR_NEXT) != 0);
        Bitmap bmp = null;
        try { bmp = m.getMetadata() != null ? m.getMetadata().getBitmap(MediaMetadata.METADATA_KEY_ART) : null; }
        catch (Throwable ignore) { }
        if (bmp == null) {
            try { bmp = m.getMetadata() != null ? m.getMetadata().getBitmap(MediaMetadata.METADATA_KEY_ALBUM) : null; }
            catch (Throwable ignore) { }
        }
        if (bmp != null) {
            if (night) {
                double dim = ArtPalette.nightArtDim();
                android.graphics.ColorMatrix cm = new android.graphics.ColorMatrix();
                cm.setScale(dim, dim, dim, 1f);
                android.graphics.Bitmap d = android.graphics.Bitmap.createBitmap(
                    bmp.getWidth(), bmp.getHeight(), android.graphics.Bitmap.Config.ARGB_8888);
                android.graphics.Canvas canvas = new android.graphics.Canvas(d);
                android.graphics.Paint p = new android.graphics.Paint();
                p.setColorFilter(new android.graphics.ColorMatrixColorFilter(cm));
                canvas.drawBitmap(bmp, 0, 0, p);
                art.setImageBitmap(d);
            } else {
                art.setImageBitmap(bmp);
            }
            int tint = night ? ArtPalette.nightTint(sample(bmp)) : ArtPalette.dayTint(sample(bmp));
            card.setBackgroundColor(tint);
        } else {
            art.setImageResource(R.drawable.ic_music_placeholder);
        }
    }

    /** Downsample the album art to a palette sample grid (pure ArtPalette consumes it). */
    static int[] sample(Bitmap b) {
        int w = Math.min(16, b.getWidth()), h = Math.min(16, b.getHeight());
        int[] px = new int[w * h];
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
                px[y * w + x] = b.getPixel(x * b.getWidth() / w, y * b.getHeight() / h);
        return px;
    }

    void act(int which) {
        if (cursor < 0 || cursor >= controllers.size()) return;
        MediaController m = controllers.get(cursor);
        try {
            android.media.MediaPlayerControl pc = m.getPlayer();
            if (pc == null) return;
            if (which == MediaCardPolicy.TR_PLAY_PAUSE) { if (pc.isPlaying()) pc.pause(); else pc.start(); }
            else if (which == MediaCardPolicy.TR_NEXT) pc.skipToNext();
            else if (which == MediaCardPolicy.TR_PREV) pc.skipToPrevious();
        } catch (Throwable t) { /* controller died mid-click: refresh() next tick */ }
    }

    void cycleSource() {
        if (controllers.isEmpty()) return;
        cursor = (cursor + 1) % controllers.size();
        showController(controllers.get(cursor));
    }

    void showNoAccess() {
        title.setText(ctx.getString(R.string.media_no_access));
        artist.setText("");
        source.setText(ctx.getString(R.string.media_grant_access));
        source.setOnClickListener(v -> MediaListenerService.requestAccess(ctx));
        art.setImageResource(R.drawable.ic_music_placeholder);
        prev.setEnabled(false); playPause.setEnabled(false); next.setEnabled(false);
    }

    void showIdle() {
        title.setText(ctx.getString(R.string.media_idle));
        artist.setText("");
        source.setText("");
        art.setImageResource(R.drawable.ic_music_placeholder);
        prev.setEnabled(false); playPause.setEnabled(false); next.setEnabled(false);
    }

    /** Phase 2 hook (spec S13): HCT radio station text. State key must be confirmed on the unit. */
    String radioStationHook() {
        if (!car.isAvailable()) return "";
        String s = car.stringState("radio_station"); // VERIFY key against CarService mDataList on device
        return s == null ? "" : s;
    }

    static boolean isRadioPackage(String pkg) { return "com.microntek.radio".equals(pkg); }
}
