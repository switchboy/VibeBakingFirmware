package org.vibebaking.launcher;

import android.app.ActivityOptions;
import android.content.Context;
import android.content.Intent;
import android.hardware.display.DisplayManager;
import android.hardware.display.VirtualDisplay;
import android.hardware.input.InputManager;
import android.util.Log;
import android.view.Display;
import android.view.Gravity;
import android.view.MotionEvent;
import android.graphics.SurfaceTexture;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.view.Surface;
import android.view.TextureView;
import android.view.View;
import android.widget.FrameLayout;
import android.widget.TextView;

import org.vibebaking.launcher.logic.MapCardPolicy;
import org.vibebaking.launcher.logic.MapTargetPolicy;

import java.util.HashSet;
import java.util.Set;

/**
 * Map card (spec S6-S8): the navigation app runs live inside the card.
 *
 * Mechanism: a private, trusted virtual display that renders into a TextureView in the card. The nav app is started on
 * that display (ActivityOptions.setLaunchDisplayId) and touches on the card are re-targeted to the display and injected
 * (MotionEvent.setDisplayId + InputManager.injectInputEvent). This is how Android's former ActivityView worked and how
 * projection (Android Auto) hosts apps.
 *
 * Why not a WM Shell TaskView: on Android 14 a TaskView needs a task organizer and transition handler, and SystemUI
 * already owns both on this ROM; a second organizer in the launcher would take tasks away from SystemUI (split screen,
 * PiP, transitions). AOSP's own CarLauncher therefore hosts its map in SystemUI (RemoteCarTaskView via the car service),
 * which does not exist on a non-automotive build.
 *
 * Needs the platform signature: ADD_TRUSTED_DISPLAY (a trusted display may host any activity and has its own focus),
 * INJECT_EVENTS (input to another app's window). If anything fails, the card falls back to a tap-to-open placeholder;
 * the home screen must never crash because the nav app misbehaved.
 *
 * Compact mode (MapCardPolicy): while nobody touches the card and no navigation runs, the view (and so the display)
 * is made taller than the card, and the card clips the bottom strip - Maps' tab bar (Explore/Saved/Contribute) is not
 * shown. A touch or navigation restores the full height, so route preview (Start button) and guidance are complete.
 * A TextureView is used because it is clipped by its parent like any view; a SurfaceView's layer is not.
 */
public class MapCardController {

    private static final String TAG = "MapCardController";
    /** Private display: only our content, trusted, own focus, touch; the nav task goes with the display. */
    private static final int VD_FLAGS = DisplayManager.VIRTUAL_DISPLAY_FLAG_OWN_CONTENT_ONLY
            | DisplayManager.VIRTUAL_DISPLAY_FLAG_TRUSTED
            | DisplayManager.VIRTUAL_DISPLAY_FLAG_SUPPORTS_TOUCH
            | DisplayManager.VIRTUAL_DISPLAY_FLAG_OWN_FOCUS
            | DisplayManager.VIRTUAL_DISPLAY_FLAG_DESTROY_CONTENT_ON_REMOVAL;

    private Context ctx;                  // the activity (startActivity with a display id must come from an activity)
    private FrameLayout card;
    private TextView placeholder;
    private TextureView surface;
    private Surface vdSurface;
    private final Handler main = new Handler(Looper.getMainLooper());
    private long lastTouch = 0L;     // uptime ms of the last touch on the card, 0 = never
    private boolean compact;
    // Home screen in front (onResume..onPause). A TextureView keeps its surface while the launcher is only stopped, so the
    // surface is no proof the card is visible: the watchdog used it and pulled Maps back out of full screen (owner, Nov 27).
    private boolean homeVisible;
    private TextView expand;
    private VirtualDisplay display;
    private boolean embedded;
    private boolean launched;
    private String target;              // nav package the card aims at (installed), null = placeholder
    private String setting;

    public MapCardController(Context c, FrameLayout card) {
        ctx = c;
        this.card = card;
        placeholder = card.findViewById(R.id.map_placeholder);
    }

    /** Pick the target per the owner setting, then embed it; placeholder otherwise (S7/S8). */
    public void init(String setting) {
        // init() runs again when the owner changes the map setting: drop the previous display and views first.
        release();
        if (surface != null) { card.removeView(surface); surface = null; }
        if (expand != null) { card.removeView(expand); expand = null; }
        this.setting = setting;
        target = MapTargetPolicy.target(setting, installedNav());
        if (target == null) { showPlaceholder(false); return; }
        try {
            attachSurface();
        } catch (Throwable t) {
            Log.w(TAG, "live map unavailable", t);
            showPlaceholder(true);
        }
    }

    /**
     * The nav package this card aims at (installed, even if embedding failed). Valet keeps it in the allowed set
     * (spec S21) so the map card is never suspended while driving.
     */
    public String navTarget() { return target; }

    boolean isNavigation(String pkg) {
        return MapTargetPolicy.MAPS.equals(pkg) || MapTargetPolicy.WAZE.equals(pkg);
    }

    boolean isInstalled(String pkg) {
        try { return ctx.getPackageManager().getLaunchIntentForPackage(pkg) != null; }
        catch (Throwable t) { return false; }
    }

    private void attachSurface() {
        placeholder.setVisibility(View.GONE);
        surface = new TextureView(ctx);
        card.addView(surface, 0, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT, Gravity.TOP));
        surface.setSurfaceTextureListener(new TextureView.SurfaceTextureListener() {
            @Override public void onSurfaceTextureAvailable(SurfaceTexture st, int w, int hgt) { onSurface(st, w, hgt); }
            @Override public void onSurfaceTextureSizeChanged(SurfaceTexture st, int w, int hgt) { onSurface(st, w, hgt); }
            @Override public boolean onSurfaceTextureDestroyed(SurfaceTexture st) {
                // Keep the display (and the nav app on it) alive while the home screen is hidden; it just stops drawing.
                if (display != null) display.setSurface(null);
                if (vdSurface != null) { vdSurface.release(); vdSurface = null; }
                return true;
            }
            @Override public void onSurfaceTextureUpdated(SurfaceTexture st) { }
        });
        surface.setOnTouchListener((v, e) -> forwardTouch(e));

        // Small corner button: open the nav app full screen (moves its task to the main display).
        expand = new TextView(ctx);
        expand.setText("⤢");
        expand.setTextSize(22f);
        expand.setTextColor(0xFFFFFFFF);
        expand.setBackgroundColor(0x80000000);
        expand.setPadding(18, 6, 18, 10);
        expand.setOnClickListener(v -> openFullScreen());
        FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.TOP | Gravity.END);
        card.addView(expand, lp);
    }

    private void onSurface(SurfaceTexture st, int w, int hgt) {
        try {
            onSurfaceUnsafe(st, w, hgt);
        } catch (Throwable t) {
            Log.w(TAG, "virtual display failed", t);
            showPlaceholder(true);
        }
    }

    private void onSurfaceUnsafe(SurfaceTexture st, int w, int hgt) {
        if (w <= 0 || hgt <= 0) return;
        boolean fresh = vdSurface == null;
        if (fresh) vdSurface = new Surface(st);
        int dpi = ctx.getResources().getDisplayMetrics().densityDpi;
        if (display == null) {
            DisplayManager dm = ctx.getSystemService(DisplayManager.class);
            display = dm.createVirtualDisplay("vibelauncher-map", w, hgt, dpi, vdSurface, VD_FLAGS);
            if (display == null) throw new IllegalStateException("createVirtualDisplay returned null");
            Log.i(TAG, "virtual display " + display.getDisplay().getDisplayId() + " " + w + "x" + hgt + " @" + dpi);
        } else {
            display.resize(w, hgt, dpi);
            display.setSurface(vdSurface);
        }
        boolean first = !embedded;
        embedded = true;
        // (Re)launch when the texture is new (home screen shown again: pulls the app back from full screen), not on a
        // compact/full resize - that would bring the nav app's start screen back over a route the owner is planning.
        if (fresh || first) launchOnDisplay();
        if (first) { MediaListenerService.navCallback = nav -> applyCompact(); main.postDelayed(compactTick, 2000L); }
    }

    private int tickCount;

    private final Runnable compactTick = new Runnable() {
        @Override public void run() {
            if (display == null) return;
            applyCompact();
            if (++tickCount % 5 == 0) watchdog(); // every 10 s
            main.postDelayed(this, 2000L);
        }
    };

    /**
     * The card must always show the nav app. If no task runs on the card's display any more (the app was killed, crashed,
     * or its task went full screen and was closed there), start it on the display again. Only while the card is on
     * screen (the texture exists): a hidden home screen must not pull the app away from the owner.
     */
    private void watchdog() {
        if (!homeVisible || display == null || vdSurface == null || !launched) return;
        int id = display.getDisplay().getDisplayId();
        try {
            android.app.ActivityManager am = ctx.getSystemService(android.app.ActivityManager.class);
            for (android.app.ActivityManager.RunningTaskInfo t : am.getRunningTasks(30)) {
                if (t.getDisplayId() == id) return; // still hosted
            }
            Log.i(TAG, "no task on display " + id + ": relaunching " + target);
            launchOnDisplay();
        } catch (Throwable t) {
            Log.w(TAG, "watchdog failed", t);
        }
    }

    /** Compact (bottom strip clipped) only while idle and not navigating (MapCardPolicy). */
    private void applyCompact() {
        if (surface == null || card.getHeight() <= 0) return;
        long since = lastTouch == 0L ? Long.MAX_VALUE : SystemClock.uptimeMillis() - lastTouch;
        boolean nav = MediaListenerService.isNavigating();
        boolean want = MapCardPolicy.compact(nav, since);
        if (want == compact) return;
        Log.i(TAG, "compact " + compact + " -> " + want + " (navigating=" + nav + ", idle=" + (since == Long.MAX_VALUE ? "never touched" : since + " ms") + ")");
        compact = want;
        FrameLayout.LayoutParams lp = (FrameLayout.LayoutParams) surface.getLayoutParams();
        lp.height = want ? card.getHeight() + MapCardPolicy.cropPx(ctx.getResources().getDisplayMetrics().densityDpi)
                         : FrameLayout.LayoutParams.MATCH_PARENT;
        surface.setLayoutParams(lp); // -> onSurfaceTextureSizeChanged -> display.resize
    }

    /** Start (or bring back) the nav app on the card's display. Called on every new surface: after the owner used the
     *  app full screen, returning home pulls it back into the card. */
    private void launchOnDisplay() {
        if (display == null || target == null) return;
        Intent i = ctx.getPackageManager().getLaunchIntentForPackage(target);
        if (i == null) { showPlaceholder(false); return; }
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        ActivityOptions o = ActivityOptions.makeBasic();
        o.setLaunchDisplayId(display.getDisplay().getDisplayId());
        ctx.startActivity(i, o.toBundle());
        launched = true;
    }

    private void openFullScreen() {
        if (target == null) return;
        try {
            Intent i = ctx.getPackageManager().getLaunchIntentForPackage(target);
            if (i == null) return;
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            ActivityOptions o = ActivityOptions.makeBasic();
            o.setLaunchDisplayId(Display.DEFAULT_DISPLAY);
            ctx.startActivity(i, o.toBundle());
        } catch (Throwable t) { Log.w(TAG, "full-screen launch failed", t); }
    }

    /** Touch in card coordinates == virtual display coordinates (the display has the surface's size). */
    private boolean forwardTouch(MotionEvent e) {
        if (display == null || !launched) return false;
        lastTouch = SystemClock.uptimeMillis();
        if (compact && e.getActionMasked() == MotionEvent.ACTION_DOWN) applyCompact(); // full UI as soon as touched
        MotionEvent m = MotionEvent.obtain(e);
        try {
            m.setDisplayId(display.getDisplay().getDisplayId());
            ctx.getSystemService(InputManager.class).injectInputEvent(m, InputManager.INJECT_INPUT_EVENT_MODE_ASYNC);
        } catch (Throwable t) {
            Log.w(TAG, "touch injection failed", t);
        } finally {
            m.recycle();
        }
        return true;
    }

    /** True while a virtual display hosts the nav app (the controller can survive an activity rebuild). */
    public boolean hasDisplay() { return display != null && embedded; }

    /** The map setting this controller was initialised with. */
    public String setting() { return setting; }

    /**
     * Theme switch (owner, Nov 27): the activity is recreated so every resource colour follows day/night, but the nav app
     * must keep running (navigation at dusk). The old activity calls this in onDestroy: drop its views, keep the display.
     */
    public void detachForRecreate() {
        main.removeCallbacks(compactTick);
        homeVisible = false;
        if (display != null) display.setSurface(null);
        if (vdSurface != null) { vdSurface.release(); vdSurface = null; }
        if (surface != null) { surface.setSurfaceTextureListener(null); surface = null; }
        expand = null;
        compact = false;
    }

    /** The new activity hands over its card; a new TextureView is attached to the existing display. */
    public void reattach(Context activity, FrameLayout newCard) {
        ctx = activity;
        card = newCard;
        placeholder = newCard.findViewById(R.id.map_placeholder);
        try {
            attachSurface();
        } catch (Throwable t) {
            Log.w(TAG, "reattach failed", t);
            showPlaceholder(true);
            return;
        }
        main.removeCallbacks(compactTick);
        main.postDelayed(compactTick, 2000L);
    }

    /** LauncherActivity.onResume: the card is visible again; bring the nav app back into it (the intended return path). */
    public void onHomeVisible() {
        homeVisible = true;
        if (display != null && launched) {
            try { launchOnDisplay(); } catch (Throwable t) { Log.w(TAG, "relaunch on resume failed", t); }
        }
    }

    /** LauncherActivity.onPause: the owner left the home screen (full-screen Maps, another app): hands off. */
    public void onHomeHidden() { homeVisible = false; }

    public void release() {
        main.removeCallbacks(compactTick);
        if (MediaListenerService.navCallback != null) MediaListenerService.navCallback = null;
        compact = false;
        if (vdSurface != null) { vdSurface.release(); vdSurface = null; }
        if (display != null) {
            try { display.release(); } catch (Throwable ignore) { }
            display = null;
        }
        embedded = false;
        launched = false;
    }

    public boolean isEmbedded() { return embedded; }

    /** @param installedButFailed true: the app is installed but cannot run in the card -> tap opens it full screen. */
    void showPlaceholder(boolean installedButFailed) {
        embedded = false;
        if (surface != null) { card.removeView(surface); surface = null; }
        if (expand != null) { card.removeView(expand); expand = null; }
        placeholder.setVisibility(View.VISIBLE);
        String name = MapTargetPolicy.TARGET_WAZE.equals(setting) ? "Waze" : "Maps";
        placeholder.setText(installedButFailed
                ? ctx.getString(R.string.map_open_full, name)
                : ctx.getString(R.string.map_placeholder, name));
        placeholder.setOnClickListener(v -> {
            String t = MapTargetPolicy.target(setting, installedNav());
            if (t != null) {
                try { ctx.startActivity(ctx.getPackageManager().getLaunchIntentForPackage(t)); }
                catch (Throwable ignore) { }
            }
        });
    }

    private Set<String> installedNav() {
        Set<String> s = new HashSet<>();
        if (isInstalled(MapTargetPolicy.MAPS)) s.add(MapTargetPolicy.MAPS);
        if (isInstalled(MapTargetPolicy.WAZE)) s.add(MapTargetPolicy.WAZE);
        return s;
    }
}
