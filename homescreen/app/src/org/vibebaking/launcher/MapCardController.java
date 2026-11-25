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
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;
import android.widget.FrameLayout;
import android.widget.TextView;

import org.vibebaking.launcher.logic.MapTargetPolicy;

import java.util.HashSet;
import java.util.Set;

/**
 * Map card (spec S6-S8): the navigation app runs live inside the card.
 *
 * Mechanism: a private, trusted virtual display that renders into a SurfaceView in the card. The nav app is started on
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
 */
public class MapCardController {

    private static final String TAG = "MapCardController";
    /** Private display: only our content, trusted, own focus, touch; the nav task goes with the display. */
    private static final int VD_FLAGS = DisplayManager.VIRTUAL_DISPLAY_FLAG_OWN_CONTENT_ONLY
            | DisplayManager.VIRTUAL_DISPLAY_FLAG_TRUSTED
            | DisplayManager.VIRTUAL_DISPLAY_FLAG_SUPPORTS_TOUCH
            | DisplayManager.VIRTUAL_DISPLAY_FLAG_OWN_FOCUS
            | DisplayManager.VIRTUAL_DISPLAY_FLAG_DESTROY_CONTENT_ON_REMOVAL;

    private final Context ctx;          // the activity (startActivity with a display id must come from an activity)
    private final FrameLayout card;
    private final TextView placeholder;
    private SurfaceView surface;
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
        surface = new SurfaceView(ctx);
        card.addView(surface, 0, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));
        surface.getHolder().addCallback(new SurfaceHolder.Callback() {
            @Override public void surfaceCreated(SurfaceHolder h) { }

            @Override public void surfaceChanged(SurfaceHolder h, int format, int w, int hgt) {
                try {
                    onSurface(h, w, hgt);
                } catch (Throwable t) {
                    Log.w(TAG, "virtual display failed", t);
                    showPlaceholder(true);
                }
            }

            @Override public void surfaceDestroyed(SurfaceHolder h) {
                // Keep the display (and the nav app on it) alive while the home screen is hidden; it just stops drawing.
                if (display != null) display.setSurface(null);
            }
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

    private void onSurface(SurfaceHolder h, int w, int hgt) {
        if (w <= 0 || hgt <= 0) return;
        int dpi = ctx.getResources().getDisplayMetrics().densityDpi;
        if (display == null) {
            DisplayManager dm = ctx.getSystemService(DisplayManager.class);
            display = dm.createVirtualDisplay("vibelauncher-map", w, hgt, dpi, h.getSurface(), VD_FLAGS);
            if (display == null) throw new IllegalStateException("createVirtualDisplay returned null");
            Log.i(TAG, "virtual display " + display.getDisplay().getDisplayId() + " " + w + "x" + hgt + " @" + dpi);
        } else {
            display.resize(w, hgt, dpi);
            display.setSurface(h.getSurface());
        }
        embedded = true;
        launchOnDisplay();
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

    public void release() {
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
