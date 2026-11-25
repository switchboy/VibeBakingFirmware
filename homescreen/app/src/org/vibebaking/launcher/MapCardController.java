package org.vibebaking.launcher;

import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.view.View;
import android.widget.FrameLayout;
import android.widget.TextView;

import org.vibebaking.launcher.logic.MapTargetPolicy;

import java.util.HashSet;
import java.util.Set;

/**
 * Map card (spec S6-S8): embeds the navigation app as a real task in a WM Shell TaskView - the
 * same mechanism Android Automotive's CarLauncher uses. Needs MANAGE_ACTIVITY_TASKS + platform
 * signature.
 *
 * BUILD-HOST VERIFY (do this before shipping, names may drift between A13/A14):
 *   frameworks/base/libs/wm/shell/src/com/android/wm/shell/taskview/TaskView.java, TaskViewHost.java
 *   - TaskViewHost(Context, Executor, Consumer<IBinder> leashCallback, TaskViewCallback)
 *   - host.createTask(); host.getTaskId(); host.releaseTask();
 *   - ActivityOptions.setEmbeddedTaskId(int) and setTaskViewHost(IBinder) are @hide (@SystemServer?)
 *   - module name for static_libs: "car-wm-shell-lib" vs "wm_shell_lib" in the tree's Android.bp
 * Everything TaskView-specific lives in this class only, so drift is contained to one file.
 * If embedding fails at runtime, the card falls back to the placeholder (spec S8) - the home
 * screen must never crash because Maps misbehaved.
 */
public class MapCardController {

    private final Context ctx;
    private final FrameLayout card;
    private final TextView placeholder;
    private Object taskViewHost; // com.android.wm.shell.taskview.TaskViewHost (reflection-safe init)
    private boolean embedded;

    public MapCardController(Context c, FrameLayout card) {
        ctx = c.getApplicationContext();
        this.card = card;
        placeholder = card.findViewById(R.id.map_placeholder);
    }

    /** Pick the target per the owner setting, then try to embed; placeholder otherwise (S7/S8). */
    public void init(String setting) {
        String target = MapTargetPolicy.target(setting, installedNav());
        if (target == null) { showPlaceholder(setting); return; }
        try {
            embed(target);
        } catch (Throwable t) {
            android.util.Log.w("MapCardController", "TaskView embed failed", t);
            showPlaceholder(setting);
        }
    }

    boolean isNavigation(String pkg) {
        return MapTargetPolicy.MAPS.equals(pkg) || MapTargetPolicy.WAZE.equals(pkg);
    }

    boolean isInstalled(String pkg) {
        try {
            Intent i = ctx.getPackageManager().getLaunchIntentForPackage(pkg);
            return i != null;
        } catch (Throwable t) { return false; }
    }

    /**
     * Embed flow (CarLauncher-style): create a TaskViewHost, add its view to the card, create a
     * task, start the nav app into that task with embedded task id + task-view host binder.
     * Reflection keeps compile/API drift from killing the app; verify the real signatures on the
     * build host and switch to direct calls if you want to drop reflection.
     */
    void embed(String pkg) throws Throwable {
        Class<?> hostCls = Class.forName("com.android.wm.shell.taskview.TaskViewHost");
        Class<?> callbackCls = Class.forName("com.android.wm.shell.taskview.TaskViewBase$TaskViewCallback");
        Object executor = java.util.concurrent.Executors.newSingleThreadExecutor();
        java.util.function.Consumer<Object> leash = binder -> {
            if (binder == null) return;
            // leash callback: the real task leash view is reparented into our card.
            try {
                java.lang.reflect.Method getLeash = hostCls.getMethod("getLeashWindowView");
                Object leashView = getLeash.invoke(taskViewHost);
                if (leashView instanceof View) {
                    card.addView((View) leashView);
                    embedded = true;
                }
            } catch (Throwable t) { android.util.Log.w("MapCardController", "no leash view", t); }
        };
        Object callback = java.lang.reflect.Proxy.newProxyInstance(
            callbackCls.getClassLoader(), new Class<?>[]{callbackCls},
            (p, m, args) -> null);
        taskViewHost = hostCls.getConstructor(Context.class, java.util.concurrent.Executor.class,
                java.util.function.Consumer.class, callbackCls)
            .newInstance(ctx, executor, (java.util.function.Consumer<Object>) leash, callback);
        hostCls.getMethod("createTask").invoke(taskViewHost);
        int taskId = (int) hostCls.getMethod("getTaskId").invoke(taskViewHost);
        Object binder = hostCls.getMethod("getIBinder").invoke(taskViewHost);
        Intent launch = ctx.getPackageManager().getLaunchIntentForPackage(pkg);
        android.app.ActivityOptions opts = android.app.ActivityOptions.makeBasic();
        // @hide ActivityOptions methods (VERIFY on the tree):
        opts.getClass().getMethod("setEmbeddedTaskId", int.class).invoke(opts, taskId);
        opts.getClass().getMethod("setTaskViewHost", android.os.IBinder.class).invoke(opts, binder);
        ctx.startActivity(launch, opts);
    }

    public void release() {
        if (taskViewHost == null) return;
        try { taskViewHost.getClass().getMethod("releaseTask").invoke(taskViewHost); }
        catch (Throwable ignore) { }
        taskViewHost = null;
        embedded = false;
    }

    public boolean isEmbedded() { return embedded; }

    void showPlaceholder(String setting) {
        embedded = false;
        placeholder.setVisibility(View.VISIBLE);
        String name = MapTargetPolicy.TARGET_WAZE.equals(setting) ? "Waze" : "Maps";
        placeholder.setText(ctx.getString(R.string.map_placeholder, name));
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
