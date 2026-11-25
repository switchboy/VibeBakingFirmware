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

## Round 3 (owner feedback, first on-device use)

| Change | File | Reason |
|---|---|---|
| Drawer enumeration: ONE `queryIntentActivities(ACTION_MAIN + CATEGORY_LAUNCHER)` call, label from `ResolveInfo.loadLabel(pm)`, de-duplicated by package (`AppDrawerPolicy.dedupe`, new + tested) | `AppDrawerActivity.java`, `logic/AppDrawerPolicy.java` | ANR: `getInstalledApplications(0)` + `getLaunchIntentForPackage` + `getApplicationLabel` for ~300 packages on the UI thread in `onResume`; the system killed the launcher. Every launcher-resolved activity is launchable, so the per-package lookups were unnecessary. |
| Enumeration + icon loading on a single-thread `Executor` owned by the activity; results posted back via `Handler(Looper.getMainLooper())`; status shows "Loading apps…" meanwhile; results dropped after `onDestroy` or when a newer `build()` started (generation counter) | `AppDrawerActivity.java` (+ string `drawer_loading`) | UI thread must never block on PackageManager; a stale worker result must never overwrite a newer build. |
| Icon cache per package (in-memory `Map<String, Drawable>`), reused across drawer opens; this app has no package-change receiver, so rebuild-on-resume keeps cached icons | `AppDrawerActivity.java` | Re-opening the drawer must not re-decode ~300 icons. |
| Media card height ~2/3 (≈138dp -> ≈88dp): `art_size` 96->64dp, transport buttons beside (not under) the text, all three labels one ellipsized line | `res/layout/home_activity.xml`, `res/values/dimens.xml` | Owner: media card too tall, radar card clipped ("Rain radar offline" overflowed). The long no-access message used to wrap and grow the card; radar keeps the rest of the column via `layout_weight=1`. |
| Volt meter (`id battery`) moved OUT of the top-right row to the bottom-right corner of the content area, directly above the favourites bar (`layout_gravity="bottom\|end"`, `marginBottom=@dimen/battery_above_fav_bar` = 60+2×8dp); the row is now clock/date block (`layout_weight=1`, date ellipsized) + ▦ + ⚙ | `res/layout/home_activity.xml`, `res/values/dimens.xml` | Clock+date+battery pushed `btn_settings` (and ▦) off-screen at 1024x600. Same id, same `updateBattery()` logic, unchanged code. |
| Clock/date painted in `onCreate` (first tick ran a minute after start) | `LauncherActivity.java` | Owner saw no clock on the first run. |
| Rain radar rewritten for the REAL API: index `api.rainviewer.com/public/weather-maps.json` (`radar.past` frames, oldest first — newest `time` wins; `nowcast` is empty, ignored), tile `{host}{path}/256/{z}/{x}/{y}/2/1_1.png`; zoom clamped to 7 (`MAX_ZOOM`; z≥8 is one constant placeholder). The old `rainviewer.com/api/latest/radar_by_zoom/…` endpoint does not exist (HTTP 301) and is gone | `logic/RadarTiles.java`, `logic/RadarPlan.java`, `RadarView.java` | Verified by the parent with live HTTP: the old API never existed, so the radar was permanently "offline". Fixture `tests/fixtures/weather_maps.json` replaces `radar_en.json`; U01 rewritten. |
| CARTO base map under the transparent radar layer: `light_all`/`dark_all` (day/night from the existing `RadarView.setNight`), same slippy grid z≤7; decoded base tiles cached in memory (they never change); night change refetches dark tiles | `logic/RadarTiles.java`, `logic/RadarPlan.java`, `RadarView.java` | Rain overlay had no geographic reference. `RadarPlan.build` fetches base tiles first, radar overlay second; partial grids still draw. |
| Attribution "© OpenStreetMap contributors © CARTO · Radar: RainViewer"; index refresh every 5 min (`REFRESH_MS`, frames update ~ every 10 min) | `logic/RadarTiles.java`, `RadarView.java` | Tile-provider attribution terms; frames update every 10 min, polling faster is waste. |
| `User-Agent: VibeLauncher/1.0 (head unit)` on every request; connect 10 s / read 15 s timeouts kept; HTTP + bitmap decode off the UI thread; failures degrade to "Rain radar offline", never crash | `HttpRadarFetcher.java`, `RadarView.java` | Tile hosts reject requests without a User-Agent; UI thread must stay free. |
| Home position: default De Bilt NL (`DEFAULT_LAT 52.10`, `DEFAULT_LON 5.18`, false "replaced by GPS fixes" comment fixed); on resume `getLastKnownLocation` gps→network→fused (each guarded against `SecurityException`), newest non-null else default; `requestLocationUpdates("gps", 60000ms, 1000m, listener, main Looper)` in `onResume`, `removeUpdates` in `onPause`; radar recentres when position moves > 5 km (`logic/RadarPosition`, new + tested U23); live position kept in memory only — never stored, never logged | `logic/SettingsKeys.java`, `logic/RadarPosition.java`, `LauncherActivity.java` | The app never read a position at all; owner wants the radar centred on the van with the De Bilt default. Privacy rule per owner task. |
| Test updates: U01 (weather-maps parse, radar + base URLs, zoom clamp 7), U17.coords De Bilt, U18.dedupe, U23 position choice/5 km rule, Smoke SG01-SG14 stubs rewritten to weather-maps + night param, conformance C10/C10b/C10c/C10d rewritten for the new API + position wiring | `tests/unit/Main.java`, `tests/unit/Smoke.java`, `tests/conformance.py`, fixtures | Policies changed; new pure logic needs coverage. |
| Static/conformance drift for the map card rewrite currently in the tree (virtual-display host instead of WM Shell TaskView; expand-chip white): SA01/SA02/SA38e strings and C06 updated, C18 given an explicit map-card carve-out — `MapCardController.java` itself untouched (another engineer owns it) | `tests/smoke_static.py`, `tests/conformance.py` | Those checks encoded the removed TaskView design and failed against the in-flight rewrite; the map round's own policy decisions stay with its engineer. |

**Suite now:** 242 unit checks, 59 smoke scenarios / 140 checks, 58 static checks, 54 C-ids → `ALL TESTS PASSED`.
