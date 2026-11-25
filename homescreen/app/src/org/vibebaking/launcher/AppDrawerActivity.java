package org.vibebaking.launcher;

import android.app.Activity;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.os.Bundle;
import android.view.View;
import android.widget.GridLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

import org.vibebaking.launcher.logic.AppDrawerPolicy;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * App drawer (spec S39): alphabetical grid, 4 columns (owner: 4x3 on the 1024x600 panel),
 * scrollable when there are more apps. Opens from the ▦ glyph on the home screen; closes with ✕
 * or the HOME key. While valet mode is active only the allowed apps are listed (S21/S27), so the
 * drawer is never an escape around the suspension.
 */
public class AppDrawerActivity extends Activity {

    private GridLayout grid;
    private TextView status;

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

    /** Rebuild the grid from PackageManager + AppDrawerPolicy (all decisions are in the policy). */
    void build() {
        boolean valet = App.valet().isActive() && App.store().valetEnabled();
        List<AppDrawerPolicy.Entry> visible = AppDrawerPolicy.visible(
            enumerate(), valet, App.valet().allowedExtras(), homeApps());

        grid.removeAllViews();
        status.setText(valet
            ? getString(R.string.drawer_count_valet, visible.size())
            : getString(R.string.drawer_count, visible.size()));
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
            try {
                icon.setImageDrawable(getPackageManager().getApplicationIcon(
                    getPackageManager().getApplicationInfo(e.pkg, 0)));
            } catch (Throwable t) { /* app vanished between enumerate and draw: keep the default icon */ }
            icon.setLayoutParams(new LinearLayout.LayoutParams(
                getResources().getDimensionPixelSize(R.dimen.drawer_icon),
                getResources().getDimensionPixelSize(R.dimen.drawer_icon)));
            TextView label = new TextView(this);
            label.setText(e.label);
            label.setTextSize(14f);
            label.setTextColor(getResources().getColor(R.color.text));
            label.setMaxLines(2);
            cell.addView(icon);
            cell.addView(label);
            cell.setClickable(true);
            cell.setOnClickListener(v -> launch(e.pkg));
            GridLayout.LayoutParams p = new GridLayout.LayoutParams();
            p.columnSpec = GridLayout.spec(GridLayout.UNDEFINED, 1f);
            p.rowSpec = GridLayout.spec(GridLayout.UNDEFINED, 1f);
            p.width = 0;
            p.height = cellHeight;
            grid.addView(cell, p);
        }
    }

    /** Launchable apps with labels; enumeration failure (QUERY_ALL_PACKAGES denied) -> empty. */
    List<AppDrawerPolicy.Entry> enumerate() {
        List<AppDrawerPolicy.Entry> out = new ArrayList<>();
        PackageManager pm = getPackageManager();
        try {
            for (ApplicationInfo a : pm.getInstalledApplications(0)) {
                boolean launchable = false;
                try { launchable = pm.getLaunchIntentForPackage(a.packageName) != null; }
                catch (Throwable ignore) { }
                String label;
                try { label = pm.getApplicationLabel(a).toString(); }
                catch (Throwable t) { label = a.packageName; }
                out.add(new AppDrawerPolicy.Entry(a.packageName, label, launchable));
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

    @SuppressWarnings("unused")
    private static boolean pageFits(int n) { return n <= AppDrawerPolicy.PAGE_SIZE; }
}
