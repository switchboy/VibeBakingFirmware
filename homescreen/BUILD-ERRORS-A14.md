# VibeLauncher: first real compile against Android 14 (2026-11-25)

Compiled on the build host by hand (soong's analysis was OOM-killed at 21 GB with the NAS services running): `javac -source 8 -target 8` with bootclasspath core-oj + core-libart (turbine jars) and classpath framework-minus-apex (turbine-jarjar) + framework-graphics/location/connectivity/permission/statsd/wifi/bluetooth/mediaprovider/media/sdkextensions turbine jars, sources = app/src + aapt2-generated R.java. Result: **35 errors**, all in the app code (none from the classpath). Root causes:

| Error | Fix |
|---|---|
| `android.os.UiModeManager` (ThemeApplier) | `android.app.UiModeManager` |
| `android.media.MediaController` / `MediaSessionManager` (MediaCardController) | `android.media.session.MediaController` / `android.media.session.MediaSessionManager` |
| `SharedPreferences.getDouble` / `Editor.putDouble` (SettingsStore) | do not exist: store as float, or `Double.doubleToRawLongBits` in a long |
| `PackageManager.setPackagesSuspended(String[], Bundle)` (ValetController:181) | Android 14: `setPackagesSuspended(String[] pkgs, boolean suspended, PersistableBundle appExtras, PersistableBundle launcherExtras, SuspendDialogInfo dialogInfo)` (system API, needs SUSPEND_APPS) |
| `RadarPlan plan = RadarPlan.build(...)` returns `Plan` (RadarView:73-83) | one type for the plan (fields attribution, frameDate, origin, zoom, tiles) |
| `CharSequence` assigned to `String` (MediaCardController:95) | `.toString()` (null-safe) |

Fix in the app code, keep `bash tests/run.sh` green, then send the tree back for another compile. Full javac output:

```
src/org/vibebaking/launcher/ThemeApplier.java:4: error: cannot find symbol
import android.os.UiModeManager;
                 ^
  symbol:   class UiModeManager
  location: package android.os
src/org/vibebaking/launcher/ThemeApplier.java:18: error: cannot find symbol
    private final UiModeManager uim;
                  ^
  symbol:   class UiModeManager
  location: class ThemeApplier
src/org/vibebaking/launcher/MediaCardController.java:5: error: cannot find symbol
import android.media.MediaController;
                    ^
  symbol:   class MediaController
  location: package android.media
src/org/vibebaking/launcher/MediaCardController.java:7: error: cannot find symbol
import android.media.MediaSessionManager;
                    ^
  symbol:   class MediaSessionManager
  location: package android.media
src/org/vibebaking/launcher/MediaCardController.java:33: error: cannot find symbol
    private List<MediaController> controllers = new ArrayList<>();
                 ^
  symbol:   class MediaController
  location: class MediaCardController
src/org/vibebaking/launcher/MediaCardController.java:83: error: cannot find symbol
    int pickIndex(List<MediaController> list) {
                       ^
  symbol:   class MediaController
  location: class MediaCardController
src/org/vibebaking/launcher/MediaCardController.java:90: error: cannot find symbol
    MediaCardPolicy.Ctl mirror(MediaController m) {
                               ^
  symbol:   class MediaController
  location: class MediaCardController
src/org/vibebaking/launcher/MediaCardController.java:117: error: cannot find symbol
    void showController(MediaController m) {
                        ^
  symbol:   class MediaController
  location: class MediaCardController
src/org/vibebaking/launcher/SettingsStore.java:21: error: cannot find symbol
    public double getDouble(String key, double def) { return p.getDouble(key, def); }
                                                              ^
  symbol:   method getDouble(String,double)
  location: variable p of type SharedPreferences
src/org/vibebaking/launcher/SettingsStore.java:25: error: cannot find symbol
    public void put(String key, double v) { p.edit().putDouble(key, v).apply(); }
                                                    ^
  symbol:   method putDouble(String,double)
  location: interface Editor
src/org/vibebaking/launcher/RadarView.java:73: error: incompatible types: Plan cannot be converted to RadarPlan
            RadarPlan plan = RadarPlan.build(fetcher, lat, lon, zoom);
                                            ^
src/org/vibebaking/launcher/RadarView.java:79: error: cannot find symbol
                att = plan.attribution;
                          ^
  symbol:   variable attribution
  location: variable plan of type RadarPlan
src/org/vibebaking/launcher/RadarView.java:80: error: cannot find symbol
                date = plan.frameDate;
                           ^
  symbol:   variable frameDate
  location: variable plan of type RadarPlan
src/org/vibebaking/launcher/RadarView.java:81: error: cannot find symbol
                o = plan.origin;
                        ^
  symbol:   variable origin
  location: variable plan of type RadarPlan
src/org/vibebaking/launcher/RadarView.java:82: error: cannot find symbol
                zoom = plan.zoom;
                           ^
  symbol:   variable zoom
  location: variable plan of type RadarPlan
src/org/vibebaking/launcher/RadarView.java:83: error: cannot find symbol
                for (RadarPlan.Tile t : plan.tiles) {
                                            ^
  symbol:   variable tiles
  location: variable plan of type RadarPlan
src/org/vibebaking/launcher/ThemeApplier.java:22: error: cannot find symbol
        UiModeManager m = null;
        ^
  symbol:   class UiModeManager
  location: class ThemeApplier
src/org/vibebaking/launcher/ThemeApplier.java:23: error: cannot find symbol
        try { m = (UiModeManager) ctx.getSystemService(Context.UI_MODE_SERVICE); } catch (Throwable ignore) { }
                   ^
  symbol:   class UiModeManager
  location: class ThemeApplier
src/org/vibebaking/launcher/ValetController.java:181: error: no suitable method found for setPackagesSuspended(String[],Bundle)
            pm.setPackagesSuspended(pkgs.toArray(new String[0]), appData);
              ^
    method PackageManager.setPackagesSuspended(String[],boolean,PersistableBundle,PersistableBundle,String) is not applicable
      (actual and formal argument lists differ in length)
    method PackageManager.setPackagesSuspended(String[],boolean,PersistableBundle,PersistableBundle,SuspendDialogInfo) is not applicable
      (actual and formal argument lists differ in length)
    method PackageManager.setPackagesSuspended(String[],boolean,PersistableBundle,PersistableBundle,SuspendDialogInfo,int) is not applicable
      (actual and formal argument lists differ in length)
src/org/vibebaking/launcher/MediaCardController.java:58: error: cannot find symbol
        List<MediaController> list = new ArrayList<>();
             ^
  symbol:   class MediaController
  location: class MediaCardController
src/org/vibebaking/launcher/MediaCardController.java:64: error: cannot find symbol
            MediaSessionManager mgr =
            ^
  symbol:   class MediaSessionManager
  location: class MediaCardController
src/org/vibebaking/launcher/MediaCardController.java:65: error: cannot find symbol
                (MediaSessionManager) ctx.getSystemService(Context.MEDIA_SESSION_SERVICE);
                 ^
  symbol:   class MediaSessionManager
  location: class MediaCardController
src/org/vibebaking/launcher/MediaCardController.java:85: error: cannot find symbol
        for (MediaController m : list) mirrors.add(mirror(m));
             ^
  symbol:   class MediaController
  location: class MediaCardController
src/org/vibebaking/launcher/MediaCardController.java:95: error: incompatible types: CharSequence cannot be converted to String
            c.pkgLabel = ctx.getPackageManager().getApplicationLabel(
                                                                    ^
src/org/vibebaking/launcher/MediaCardController.java:106: error: cannot find symbol
            android.media.MediaPlayerControl pc = m.getPlayer();
                         ^
  symbol:   class MediaPlayerControl
  location: package android.media
src/org/vibebaking/launcher/MediaCardController.java:139: error: cannot find symbol
                android.graphics.ColorMatrix cm = new android.graphics.ColorMatrix();
                                ^
  symbol:   class ColorMatrix
  location: package android.graphics
src/org/vibebaking/launcher/MediaCardController.java:139: error: cannot find symbol
                android.graphics.ColorMatrix cm = new android.graphics.ColorMatrix();
                                                                      ^
  symbol:   class ColorMatrix
  location: package android.graphics
src/org/vibebaking/launcher/MediaCardController.java:145: error: cannot access ColorMatrix
                p.setColorFilter(new android.graphics.ColorMatrixColorFilter(cm));
                                 ^
  class file for android.graphics.ColorMatrix not found
src/org/vibebaking/launcher/MediaCardController.java:170: error: cannot find symbol
        MediaController m = controllers.get(cursor);
        ^
  symbol:   class MediaController
  location: class MediaCardController
src/org/vibebaking/launcher/MediaCardController.java:172: error: cannot find symbol
            android.media.MediaPlayerControl pc = m.getPlayer();
                         ^
  symbol:   class MediaPlayerControl
  location: package android.media
src/org/vibebaking/launcher/ValetPinActivity.java:31: error: cannot find symbol
        pin.setInputType(android.input.InputType.TYPE_CLASS_NUMBER);
                                      ^
  symbol:   class InputType
  location: package android.input
src/org/vibebaking/launcher/MapCardController.java:110: error: incompatible types: ActivityOptions cannot be converted to Bundle
        ctx.startActivity(launch, opts);
                                  ^
src/org/vibebaking/launcher/LauncherActivity.java:174: error: boolean cannot be dereferenced
        boolean valet = valet.isActive() && store.valetEnabled();
                             ^
src/org/vibebaking/launcher/LauncherActivity.java:181: error: boolean cannot be dereferenced
            valet.setNavTarget(map.navTarget()); // keep the chosen nav app allowed in valet (S21)
                 ^
src/org/vibebaking/launcher/CarSettingsActivity.java:74: error: cannot find symbol
        pin.setInputType(android.input.InputType.TYPE_CLASS_NUMBER);
                                      ^
  symbol:   class InputType
  location: package android.input
Note: Some input files use or override a deprecated API.
Note: Recompile with -Xlint:deprecation for details.
Note: Some messages have been simplified; recompile with -Xdiags:verbose to get full output
35 errors
```
