package org.vibebaking.launcher;

import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.graphics.drawable.Drawable;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.widget.GridLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

import org.vibebaking.launcher.logic.AppDrawerPolicy;
import org.vibebaking.launcher.logic.FavoritePolicy;

import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * App drawer (spec S39): alphabetical grid, 4 columns (owner: 4x3 on the 1024x600 panel),
 * scrollable when there are more apps. Opens from the ▦ glyph on the home screen; closes with ✕
 * or the HOME key. While valet mode is active only the allowed apps are listed (S21/S27), so the
 * drawer is never an escape around the suspension.
 *
 * Round 3 (ANR fix): enumeration used to run getInstalledApplications + a launch-intent and label
 * lookup per package (~300) on the UI thread in onResume, and the system killed the launcher.
 * Now: ONE queryIntentActivities(LAUNCHER) call, labels from ResolveInfo.loadLabel, de-duplicated
 * by package, all on a background executor owned by the activity; the finished list is posted
 * back to the main thread. Results arriving after onDestroy, or after a newer build() started,
 * are dropped (generation counter). Icons are cached per package so re-opening the drawer does
 * not re-decode them.
 */
public class AppDrawerActivity extends Activity {

    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService bg = Executors.newSingleThreadExecutor();
    private GridLayout grid;
    private TextView status;
    private volatile boolean destroyed;
    private volatile int generation; // build() counter: results of an older build are ignored

    /**
     * Icons decoded once per package, kept across drawer opens (in-memory, process-lifetime).
     * This app has no package-change receiver, so a rebuild on resume reuses cached icons; a
     * changed app updates after the launcher process restarts. Bounded by the package count.
     */
    private static final Map<String, Drawable> ICON_CACHE = new HashMap<>();

    @Override
    protected void onCreate(Bundle saved) {
        super.onCreate(saved);
        setContentView(R.layout.drawer_activity);
        grid = findViewById(R.id.drawer_grid);
        status = findViewById(R.id.drawer_status);
        findViewById(R.id.drawer_close).setOnClickListener(v -> finish());
    }

    @Override
    protected void onResume() {
        super.onResume();
        build(); // re-read on resume: installs/uninstalls and valet state may have changed
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        destroyed = true; // results still in flight are dropped by the generation/destroyed check
        bg.shutdown();
    }

    /**
     * Start a rebuild: status shows "loading" while the worker enumerates, filters (policy) and
     * loads icons off the UI thread. Nothing here touches PackageManager on the UI thread.
     */
    void build() {
        final int gen = ++generation;
        status.setText(getString(R.string.drawer_loading));
        grid.removeAllViews(); // stale grid from a previous build must not linger while loading
        bg.execute(() -> {
            List<AppDrawerPolicy.Entry> all = enumerate();
            Set<String> home = homeApps();
            boolean valet;
            Set<String> extras;
            List<String> pinned;
            try {
                valet = App.valet().isActive() && App.store().valetEnabled();
                extras = App.valet().allowedExtras();
                pinned = App.store().favSlots(); // bottom row contents (spec S40c)
            } catch (Throwable t) { // app singletons not up yet / prefs unreadable: show everything normal
                valet = false;
                extras = Collections.emptySet();
                pinned = Collections.emptyList();
            }
            // Every result of queryIntentActivities(LAUNCHER) is launchable by definition; a
            // package can have several launcher activities -> one drawer cell per package.
            List<AppDrawerPolicy.Entry> visible = AppDrawerPolicy.visible(
                AppDrawerPolicy.dedupe(all), valet, extras, home);
            final Map<String, Drawable> icons = loadIcons(visible); // cached, off the UI thread
            final boolean valetOn = valet;
            final List<String> pinnedPkgs = pinned;
            main.post(() -> {
                if (!destroyed && gen == generation) render(visible, icons, valetOn, pinnedPkgs);
            });
        });
    }

    /** Draw the grid on the UI thread: only cached drawables are used, no PackageManager calls. */
    void render(List<AppDrawerPolicy.Entry> visible, Map<String, Drawable> icons,
                boolean valet, List<String> pinnedPkgs) {
        grid.removeAllViews();
        // Page math comes from the pure policy: 12 icons per screen (4x3), anything more scrolls.
        int pages = AppDrawerPolicy.pageCount(visible.size());
        status.setText(valet
            ? getString(R.string.drawer_count_valet, visible.size(), pages)
            : getString(R.string.drawer_count, visible.size(), pages));
        if (visible.isEmpty()) {
            TextView empty = new TextView(this);
            empty.setText(getString(R.string.drawer_empty));
            empty.setTextSize(18f);
            empty.setPadding(24, 16, 24, 16);
            grid.addView(empty);
            return;
        }
        int cellHeight = getResources().getDimensionPixelSize(R.dimen.drawer_cell_height);
        for (AppDrawerPolicy.Entry e : visible) {
            LinearLayout cell = new LinearLayout(this);
            cell.setOrientation(LinearLayout.VERTICAL);
            cell.setGravity(android.view.Gravity.CENTER_HORIZONTAL);
            ImageView icon = new ImageView(this);
            icon.setImageResource(android.R.drawable.sym_def_app_icon);
            Drawable cached = icons.get(e.pkg);
            if (cached != null) icon.setImageDrawable(cached);
            icon.setLayoutParams(new LinearLayout.LayoutParams(
                getResources().getDimensionPixelSize(R.dimen.drawer_icon),
                getResources().getDimensionPixelSize(R.dimen.drawer_icon)));
            TextView label = new TextView(this);
            boolean pinned = pinnedPkgs.contains(e.pkg);
            label.setText(pinned ? getString(R.string.fav_pinned_prefix) + e.label : e.label);
            label.setTextSize(14f);
            label.setTextColor(getResources().getColor(R.color.text));
            label.setMaxLines(2);
            cell.addView(icon);
            cell.addView(label);
            cell.setClickable(true);
            cell.setOnClickListener(v -> launch(e.pkg));
            // Long-press pins to the bottom row (spec S40c). Disabled in valet: the home row must
            // not be edited while the suspension is in force.
            if (!valet) {
                cell.setLongClickable(true);
                cell.setOnLongClickListener(v -> { pinToFavoriteRow(e.pkg); return true; });
            }
            GridLayout.LayoutParams p = new GridLayout.LayoutParams();
            p.columnSpec = GridLayout.spec(GridLayout.UNDEFINED, 1f);
            p.rowSpec = GridLayout.spec(GridLayout.UNDEFINED, 1f);
            p.width = 0;
            p.height = cellHeight;
            grid.addView(cell, p);
        }
    }

    /** Icons for the visible entries, from the cache when possible; worker thread only. */
    private Map<String, Drawable> loadIcons(List<AppDrawerPolicy.Entry> visible) {
        PackageManager pm = getPackageManager();
        Map<String, Drawable> out = new HashMap<>();
        for (AppDrawerPolicy.Entry e : visible) {
            Drawable d;
            synchronized (ICON_CACHE) { d = ICON_CACHE.get(e.pkg); }
            if (d == null) {
                try {
                    d = pm.getApplicationIcon(pm.getApplicationInfo(e.pkg, 0));
                } catch (Throwable t) { // app vanished / icon unreadable: keep the default icon
                    d = null;
                }
                if (d != null) synchronized (ICON_CACHE) { ICON_CACHE.put(e.pkg, d); }
            }
            if (d != null) out.put(e.pkg, d);
        }
        return out;
    }

    /** Long-press handler: assign to the first free slot; a full row replaces the primary slot. */
    void pinToFavoriteRow(String pkg) {
        try {
            App.store().setFavSlots(FavoritePolicy.assign(App.store().favSlots(), pkg));
            android.widget.Toast.makeText(this, R.string.fav_pinned, android.widget.Toast.LENGTH_SHORT).show();
            build(); // re-render the star markers (cheap: enumeration runs on the worker, icons cached)
        } catch (Throwable t) {
            android.util.Log.w("AppDrawerActivity", "pin failed for " + pkg, t);
        }
    }

    /**
     * Launchable apps with labels, ONE PackageManager call (worker thread): the launcher intent
     * query returns exactly the apps that can be started. Enumeration failure (QUERY_ALL_PACKAGES
     * denied) -> empty; the drawer then shows the empty message, no crash.
     */
    List<AppDrawerPolicy.Entry> enumerate() {
        List<AppDrawerPolicy.Entry> out = new ArrayList<>();
        PackageManager pm = getPackageManager();
        try {
            Intent launcher = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER);
            for (ResolveInfo r : pm.queryIntentActivities(launcher, 0)) {
                if (r == null || r.activityInfo == null) continue;
                String pkg = r.activityInfo.packageName;
                String label;
                try { label = r.loadLabel(pm).toString(); }
                catch (Throwable t) { label = pkg; } // label unreadable: the package name is honest
                out.add(new AppDrawerPolicy.Entry(pkg, label, true));
            }
        } catch (Throwable t) { /* permission denied: drawer shows the empty message, no crash */ }
        return out;
    }

    /** Packages that resolve as HOME (this launcher, Launcher3 if it is still installed): hidden. */
    Set<String> homeApps() {
        Set<String> s = new HashSet<>();
        try {
            Intent home = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME);
            for (ResolveInfo r : getPackageManager().queryIntentActivities(home, 0)) {
                if (r.activityInfo != null) s.add(r.activityInfo.packageName);
            }
        } catch (Throwable ignore) { }
        return s;
    }

    void launch(String pkg) {
        try {
            Intent i = getPackageManager().getLaunchIntentForPackage(pkg);
            if (i == null) return; // uninstalled since build(): do nothing
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            startActivity(i);
            finish(); // the app is on screen; HOME returns to the home screen
        } catch (Throwable t) {
            android.util.Log.w("AppDrawerActivity", "launch failed for " + pkg, t);
        }
    }
}
