# VibeLauncher against Android 14 — compile status (2026-11-25)

**The app compiles.** Hand build on the NAS (`homescreen/build-on-build-host.sh`, because soong's
graph regeneration is OOM-killed there): `aapt2 compile` + `aapt2 link` (R.java, 96 resource
constants) + `javac` + `d8` all exit 0 — 77 classes, `classes.dex` 109 KB, and `aapt2 dump badging`
reports `provides-component:'launcher'`, `targetSdkVersion 34`, platform build version 34.
APK digest `81f77b19d731c41a45f27d91b59dd6361ea035ccfdc57936a5bb28c756351836` (the apk digest moves
with zip timestamps; `classes.dex` is 109336 B in both runs).

## Round 1 — 35 errors (parent loop's first compile)

| Error | Fix |
|---|---|
| `android.os.UiModeManager` (ThemeApplier) | `android.app.UiModeManager` |
| `android.media.MediaController` / `MediaSessionManager` (MediaCardController) | `android.media.session.*` (`MediaMetadata` stays in `android.media`) |
| `MediaPlayerControl` + `getPlayer()` (mirror/act) | removed in A14: read `PlaybackState` (state + action mask) and drive `MediaController.TransportControls` |
| `android.graphics.ColorMatrix` not on the classpath | night art dim is now a `PorterDuffColorFilter` MULTIPLY tint (`ArtPalette.nightArtDim()` scaled to a grey) |
| `SharedPreferences.getDouble/putDouble` | do not exist: doubles round-trip as raw bits in a `long` |
| `setPackagesSuspended(String[], Bundle)` | A14 overload `(String[], boolean, PersistableBundle, PersistableBundle, dialogInfo)` |
| `CharSequence` assigned to `String` (app label) | `.toString()` |
| `RadarView`: `RadarPlan plan = RadarPlan.build(...)` | the plan type is `RadarPlan.Plan` |
| `android.input.InputType` (PIN pads) | `android.text.InputType` |
| `ctx.startActivity(launch, opts)` | `opts.toBundle()` (`startActivity(Intent, Bundle)`) |
| `boolean` cannot be dereferenced (LauncherActivity) | the local `valet` shadowed the `ValetController` field; renamed to `valetOn` |
| `Set.of()` (ValetPolicy) | Java 9 API: `Collections.<String>emptySet()` so `-source 8` compiles |

## Round 2 — 12 errors, then 3 (this session's hand build)

| Error | Verified root cause | Fix |
|---|---|---|
| `BluetoothProfile.ProxyListener` | the tree has `BluetoothProfile.ServiceListener` (`javap`); `getProfileProxy` returns `boolean` | use `ServiceListener` |
| `PhonePolicy.trustedPhoneConfigured(int)` | the predicate is `boolean paired` | `!adapter.getBondedDevices().isEmpty()` |
| `android.app.SuspendDialogInfo` | it is **`android.content.pm.SuspendDialogInfo`** in this tree (`javap` shows the overload) | cast `(android.content.pm.SuspendDialogInfo) null` |
| `MediaListenerService` → `ComponentName` | `MediaSessionManager.getActiveSessions(android.content.ComponentName)` | `new ComponentName(ctx, MediaListenerService.class)` |
| `PlaybackState.STATE_PREPARING` | A14 states: NONE/STOPPED/PAUSED/PLAYING/FF/REWIND/BUFFERING/ERROR/CONNECTING/SKIPPING… | `STATE_PLAYING` + `STATE_BUFFERING` only |
| `BluetoothPhoneProbe` not a `PhonePresenceProbe` | missing `import ...logic.PhonePresenceProbe` — invisible locally, a hard error on the host | import added; static smoke `SA39` now checks every cross-package logic reference |

## Verified against the tree (not guessed)

- `PackageManagerService` enforces `android.permission.SUSPEND_APPS` for suspend
  (`services/core/java/com/android/server/pm/PackageManagerService.java:3263/3302`) → declared in
  the manifest and in `privapp-permissions-vibelauncher.xml`.
- Compile classpath for an app without `sdk_version`: `framework/android_common/*/repackaged-turbine-jarjar/framework.jar`
  plus the APEX module turbine-jarjar jars (Bluetooth is a module, not in framework-minus-apex).
- `aapt2 link -I` needs real framework resources: `out/target/product/rk3399/system/framework/framework-res.apk`.
- Themes extend `Theme.DeviceDefault[.Light].NoActionBar` and use `windowBackground`/`colorAccent`/
  `textColor` — the link resolves them against that framework-res.apk.

## Still parent-side

Stage `homescreen/app/` into the device tree (`device/rockchip/rk3399/apps/VibeLauncher/`), add
`VibeLauncher` to `PRODUCT_PACKAGES`, drop Launcher3 (spec S2b), copy the permissions xml. Soong
needs ~11 GB headroom on `SSData` (currently 98% full) and enough RSS that `soong_build` survives.

## First run on the unit (2026-11-25, platform-signed APK via `adb install`, not yet in the image)
Two start-up crashes, both fixed in `LauncherActivity.onCreate` (the unit tests cannot see these: they are Android lifecycle order):
1. `refreshFavorites()` ran before `store`/`valet` were fetched -> NPE `ValetController.isActive()`. Now called after them.
2. `car.attach()` + `applyTheme()` ran before the radar card existed -> NPE `RadarView.setNight`. The car block now runs
   last in `onCreate`; `radar` is null-guarded in `applyTheme()` and `onConfigurationChanged()`.

After that the home screen runs (screenshot `a14-work/launcher-3.png`). Open items, in order:
- **Map card embedding cannot work as written.** `com.android.wm.shell.taskview.TaskViewHost` is not on the app class path:
  it lives in SystemUI's WM Shell library (`ClassNotFoundException`). CarLauncher embeds because it *statically links*
  `WindowManager-Shell`, which needs a soong build of the app. The card then shows "Maps is not installed", which is
  wrong: Maps is installed and visible (QUERY_ALL_PACKAGES granted) - the fallback text must say the embed is
  unavailable and offer "tap to open Maps" instead. Owner decides: static WM Shell (soong, heavy) vs. a non-embedded card.
- Radar card is clipped at 1024x600 ("Rain radar offline" overflows the bottom of the right column).
- No clock/date visible on the home screen.
- Media card asks for notification access (expected; grant with
  `cmd notification allow_listener org.vibebaking.launcher/org.vibebaking.launcher.MediaListenerService`).
- Battery shows 12.0 V (bench supply; check against a multimeter, A06).
