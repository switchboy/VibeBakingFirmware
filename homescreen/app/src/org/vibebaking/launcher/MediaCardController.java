package org.vibebaking.launcher;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.graphics.Bitmap;
import android.graphics.PorterDuff;
import android.graphics.PorterDuffColorFilter;
import android.media.MediaMetadata;
import android.media.session.MediaController;
import android.media.session.MediaSessionManager;
import android.media.session.PlaybackState;
import android.os.Handler;
import android.os.Looper;
import android.widget.ImageButton;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

import org.vibebaking.launcher.logic.ArtPalette;
import org.vibebaking.launcher.logic.MediaCardPolicy;
import org.vibebaking.launcher.logic.RadioState;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

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

    // HCT radio (no media session): shown whenever the radio is the MCU audio source (logic/RadioState).
    private final RadioState radio = new RadioState();
    private boolean radioMode;
    private boolean radioOnBroadcast;   // last canbusdisplay radio-on/radio-off, fallback when the car service is down
    private boolean polling;
    private static final long RADIO_POLL_MS = 3000L;

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
        car.setRadioListener(this::onRadioEvent);
        try {
            ctx.registerReceiver(radioReceiver, new IntentFilter(RadioState.BC_DISPLAY), Context.RECEIVER_EXPORTED);
        } catch (Throwable t) { android.util.Log.w("MediaCardController", "radio receiver", t); }
    }

    /** Home screen visible: follow the radio source (av_channel) every few seconds and ask the radio for its state. */
    public void onResume() {
        if (!polling) { polling = true; main.post(radioPoll); }
        sendRadio(RadioState.ACT_REQUEST);
    }

    public void onPause() { polling = false; main.removeCallbacks(radioPoll); }

    private final Runnable radioPoll = new Runnable() {
        @Override public void run() {
            if (!polling) return;
            if (radioActive() != radioMode) refresh();
            main.postDelayed(this, RADIO_POLL_MS);
        }
    };

    private boolean radioActive() {
        if (car.isAvailable()) return RadioState.isRadioChannel(car.stringState("av_channel"));
        return radioOnBroadcast;
    }

    /** HCT car event type "Radio" (main thread): frequency and RDS station name. */
    void onRadioEvent(Map<String, Object> b) {
        Object t = b.get("type"), v = b.get("value");
        if ("freq".equals(t) && v instanceof Integer) radio.setFreq((Integer) v);
        else if ("psn".equals(t) && v instanceof byte[]) radio.psn = RadioState.decodePsn((byte[]) v);
        else return;
        if (radioMode) showRadio();
    }

    /** com.microntek.canbusdisplay from the radio app: radio-on / radio-off / radio (fre = kHz). */
    private final BroadcastReceiver radioReceiver = new BroadcastReceiver() {
        @Override public void onReceive(Context c, Intent i) {
            String type = i.getStringExtra("type");
            if ("radio-on".equals(type)) { radioOnBroadcast = true; refresh(); }
            else if ("radio-off".equals(type)) { radioOnBroadcast = false; refresh(); }
            else if ("radio".equals(type)) {
                int fre = i.getIntExtra("fre", 0);
                if (fre > 0) radio.setFreq(fre);
                if (radioMode) showRadio();
            }
        }
    };

    private void sendRadio(String action) {
        try { ctx.sendBroadcast(new Intent(action).setPackage(RadioState.PKG)); } catch (Throwable ignore) { }
    }

    void showRadio() {
        boolean entering = !radioMode;
        radioMode = true;
        radio.active = true;
        title.setText(radio.title());
        artist.setText(radio.subtitle());
        source.setText(ctx.getString(R.string.media_source_radio));
        art.setColorFilter(null);
        art.setImageResource(R.drawable.ic_radio);
        art.setOnClickListener(v -> {
            try {
                Intent l = ctx.getPackageManager().getLaunchIntentForPackage(RadioState.PKG);
                if (l != null) ctx.startActivity(l.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            } catch (Throwable ignore) { }
        });
        playPause.setImageResource(R.drawable.ic_power);
        prev.setEnabled(true); playPause.setEnabled(true); next.setEnabled(true);
        if (entering || radio.freqKhz <= 0) sendRadio(RadioState.ACT_REQUEST);
    }

    /** Back to session/idle presentation: undo the radio-only bits. */
    private void leaveRadio() {
        if (!radioMode) return;
        radioMode = false;
        radio.active = false;
        art.setOnClickListener(null);
        art.setClickable(false);
        playPause.setImageResource(R.drawable.ic_pause);
    }

    /** Called when the notification listener connects (or from onResume, refreshed periodically). */
    public void refresh() {
        if (radioActive()) { showRadio(); return; }   // the radio is what the car plays: it wins over sessions
        leaveRadio();
        List<MediaController> list = new ArrayList<>();
        if (MediaListenerService.instance == null) {
            showNoAccess();
            return;
        }
        try {
            MediaSessionManager mgr =
                (MediaSessionManager) ctx.getSystemService(Context.MEDIA_SESSION_SERVICE);
            list = mgr.getActiveSessions(new android.content.ComponentName(ctx, MediaListenerService.class));
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
        // A session can publish a null package; keep everything non-null so the card never NPEs.
        c.pkg = m.getPackageName() == null ? "" : m.getPackageName();
        try {
            c.pkgLabel = ctx.getPackageManager().getApplicationLabel(
                ctx.getPackageManager().getApplicationInfo(c.pkg, 0)).toString();
        } catch (Throwable t) { c.pkgLabel = ""; }
        MediaMetadata md = null;
        try { md = m.getMetadata(); } catch (Throwable ignore) { }
        if (md != null) {
            c.title = md.getString(MediaMetadata.METADATA_KEY_TITLE);
            c.artist = md.getString(MediaMetadata.METADATA_KEY_ARTIST);
            c.album = md.getString(MediaMetadata.METADATA_KEY_ALBUM);
        }
        // android.media.MediaPlayerControl is gone in Android 14: read the session's PlaybackState.
        try {
            PlaybackState ps = m.getPlaybackState();
            if (ps != null) {
                int st = ps.getState();
                // A14 PlaybackState has no STATE_PREPARING; buffering/connecting count as "about to play".
                c.playing = st == PlaybackState.STATE_PLAYING || st == PlaybackState.STATE_BUFFERING;
                long a = ps.getActions();
                c.canPlayPause = (a & (PlaybackState.ACTION_PLAY | PlaybackState.ACTION_PLAY_PAUSE
                    | PlaybackState.ACTION_PAUSE)) != 0;
                c.canSkipNext = (a & PlaybackState.ACTION_SKIP_TO_NEXT) != 0;
                c.canSkipPrev = (a & PlaybackState.ACTION_SKIP_TO_PREVIOUS) != 0;
            }
        } catch (Throwable ignore) { /* session without a playback state: buttons stay disabled */ }
        return c;
    }

    void showController(MediaController m) {
        MediaCardPolicy.Ctl c = mirror(m);
        boolean night = theme.systemNight();
        String station = isRadioPackage(c.pkg) ? radioStationHook() : "";
        title.setText(MediaCardPolicy.radioLabel(station, c));
        artist.setText(night ? MediaCardPolicy.album(c) : "");
        source.setText(MediaCardPolicy.sourceLabel(c));
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
            art.setImageBitmap(bmp);
            if (night) {
                // Night dim without ColorMatrix (absent from the compile classpath): a multiply tint
                // keeps white-on-transparent artwork dim instead of glaring (spec S33/S14).
                double dim = ArtPalette.nightArtDim();
                int g = (int) Math.round(Math.max(0.0, Math.min(1.0, dim)) * 255);
                int grey = (0xFF << 24) | (g << 16) | (g << 8) | g;
                art.setColorFilter(new PorterDuffColorFilter(grey, PorterDuff.Mode.MULTIPLY));
            } else {
                art.setColorFilter(null); // day: no dim (spec S35)
            }
            int tint = night ? ArtPalette.nightTint(sample(bmp)) : ArtPalette.dayTint(sample(bmp));
            card.setBackgroundColor(tint);
        } else {
            art.setColorFilter(null);
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
        if (radioMode) {
            if (which == MediaCardPolicy.TR_PREV) sendRadio(RadioState.ACT_PREV);
            else if (which == MediaCardPolicy.TR_NEXT) sendRadio(RadioState.ACT_NEXT);
            else if (which == MediaCardPolicy.TR_PLAY_PAUSE) sendRadio(RadioState.ACT_POWER); // off; the poll follows
            return;
        }
        if (cursor < 0 || cursor >= controllers.size()) return;
        MediaController m = controllers.get(cursor);
        try {
            MediaController.TransportControls tc = m.getTransportControls();
            if (tc == null) return;
            if (which == MediaCardPolicy.TR_PLAY_PAUSE) {
                // Toggle from the mirrored state (MediaPlayerControl is gone in Android 14).
                if (mirror(m).playing) tc.pause(); else tc.play();
            } else if (which == MediaCardPolicy.TR_NEXT) tc.skipToNext();
            else if (which == MediaCardPolicy.TR_PREV) tc.skipToPrevious();
        } catch (Throwable t) { /* controller died mid-click: refresh() next tick */ }
    }

    void cycleSource() {
        if (radioMode || controllers.isEmpty()) return;
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
