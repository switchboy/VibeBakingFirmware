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

## Round 5 — bottom strip, engine gauges, radar tweaks (owner request 2026-11-27)

Not compiled here (no Android SDK); APIs used are only ones already used in this app plus long-standing basics
(`BroadcastReceiver`, `IntentFilter`, `Context.RECEIVER_EXPORTED` = API 33 constant + `registerReceiver(receiver, filter, int flags)`
API 33 overload, `View` attrs, `TextView`, `Handler`). Java 8 source: no `var`, no `List.of`, lambdas only (already used).

| Change | File | Reason |
|---|---|---|
| `▦` (`btn_apps`) and `⚙` (`btn_settings`) moved out of the top-right row into the bottom strip: centred horizontal `[btn_apps] [fav_handle] [btn_settings]` group, each 64dp wide, full strip height, 28sp glyphs / dots drawable — same visual weight. Ids and click wiring unchanged (`onCreate` finds them by id; `onResume` still hides `btn_settings` in valet) | `res/layout/home_activity.xml` | Owner: controls belong beside the four-dot button; the top-right row then uses the full column width for clock+date. |
| Strip height 32->40dp (`bottom_strip_height`); `favorites_bar` picks up the new bottom margin automatically | `res/values/dimens.xml` | 28sp glyphs and the dots need the room; the favourites overlay keeps sitting just above the strip. |
| Volt meter (`id battery`) moved from the strip into a new right-aligned gauge row directly under the clock: `battery` + new `engine_temp` + new `engine_rpm`, all `@dimen/battery_size` text, temp/rpm `visibility="gone"` until a value arrives; radar card got `android:minHeight="120dp"` | `res/layout/home_activity.xml` | Owner wants `12.6 V · 88 °C · 2150 rpm` under the clock. Budget at 1024x600: strip 40 + clock row ~77 + gauge row ~24 + media card ~104 leaves ~320dp for the weight-based radar card — no clipping, far above the 120dp floor. |
| New pure class `logic/EngineGauges.java`: `Level { COLD, OK, WARN, BAD }`, `batteryLevel(double)` (<11.5 BAD, 11.5..<12.0 WARN, 12.0..14.8 OK, >14.8..15.2 WARN, >15.2 BAD, NaN reads BAD), `coolantLevel(int)` (<70 COLD, 70..104 OK, 105..114 WARN, ≥115 BAD), `oilLevel(int)` (<70 COLD, 70..124 OK, 125..134 WARN, ≥135 BAD), `parseRpm(String)` = trim + `Integer.parseInt` in try/catch, null on negative/>9000/non-numeric/overflow. All thresholds named constants with the source comment "VAG EA111 1.2 TSI 105 hp, owner 2026-11-27" | `logic/EngineGauges.java` (new) | Colour policy must be pure + unit-tested; activity only maps Level -> colour. No HCTCanBus protocol publishes coolant/oil temperature, so the logic ships now and a real source is wired later. |
| Gauge palette added: day `gauge_cold #FF4FA3FF`, `gauge_ok #FF2F6D57` (reuses battery green), `gauge_warn #FFFFC83D`, `gauge_bad #FFFF5A5A`; night: dimmed same hues (`#FF7FB6E3/#FF79A98E/#FFD9A854/#FFD96A6A`), no pure white (spec S33, C14b) | `res/values/colors.xml`, `res/values-night/colors.xml` | `EngineGauges.Level` needs day/night colours; `theme.apply()` swaps the qualifier so `getResources().getColor()` follows automatically. |
| `updateBattery()` now colours the chip from `EngineGauges.batteryLevel(BatteryState.volts(batteryRaw))` instead of the old `battery_ok`/`battery_low` pair; new `levelColor(Level)`; voltage source (`batteryRaw`, `BatteryState.known/label`) unchanged | `LauncherActivity.java` | Round 5 colour policy; same id, hidden when unknown. |
| RPM runtime receiver: action `com.microntek.canbus.rpm`, String extra `rpm`, registered with `Context.RECEIVER_EXPORTED` (HCTCanBus sends via `sendBroadcastAsUser`), registration and `onReceive` both guarded (`Throwable` -> gauge stays hidden, home screen still runs, S36); valid frames paint `"2150 rpm"` in `@color/text_sub` and re-arm a `main.postDelayed(rpmStale, RPM_STALE_MS)` expiry; no usable frame for 10 s -> GONE (ignition off / protocol without RPM); `unregisterReceiver` + `removeCallbacks` in `onDestroy` | `LauncherActivity.java` | Owner-specified data source and staleness rule. Registered last in `onCreate`, after the car block (first-run NPE lesson). |
| `onEngineTemp(int celsius, boolean isOil)` entry point (main thread): paints `engine_temp` "88 °C oil" / "88 °C" + level colour, VISIBLE. No broadcast invented — nothing calls it yet; `com.canbus.temperature` is outside-air and deliberately NOT used | `LauncherActivity.java` | The view + policy ship now; wiring waits for the CAN box being known. |
| Radar base tiles see-through: `BASE_ALPHA_DAY = 140` (~0.55), `BASE_ALPHA_NIGHT = 115` (~0.45, on top of the existing `NIGHT_BASE` tint); radar overlay keeps its palette alpha; save/translate/restore centring unchanged | `RadarView.java` | Owner: card background must show through so the rain stands out. |
| Tests: `t23EngineGauges` (U26-U29: every band boundary — 11.49/11.5/11.99/12.0/14.8/14.81/15.2/15.21, coolant 69/70/104/105/114/115, oil 69/70/124/125/134/135, rpm "2150"/" 800 "/"-1"/"abc"/"12000"/null + 0/9000/9001/decimal bounds); Smoke SG60/SG61 junk-payload degrade; conformance C41 (strip order, battery before the strip, 40dp dimen, exported receiver + `RPM_STALE_MS` + `onEngineTemp` wired, palette + EA111 comment) and C42 (base alpha constants applied, radar 120dp floor, night palette no white) | `tests/unit/Main.java`, `tests/unit/Smoke.java`, `tests/conformance.py` | New pure policy + wiring must be covered; C41/C42 lock the layout/API choices. |
| `MapCardController.java`, `MediaCardController.java`, `CarClient.java`, `RadioState.java` untouched; `favorites_bar.xml` untouched; no git commands run | — | Task hard rules. |

**Suite now (Round 5):** 277 unit checks, 61 smoke scenarios / 144 checks, 58 static checks, 59 C-ids → `ALL TESTS PASSED`.
Not verifiable here: javac against framework.jar (no SDK on the workstation) — the parent engineer compiles on the build host.

## Round 6 - settings screen (owner request 2026-11-27)

Widgets used are all long-standing framework classes the task allows: `Switch`, `SeekBar`, `EditText`, `TextView`,
`LinearLayout`, `ScrollView`, `View`, `GradientDrawable`, `Typeface.MONOSPACE`, `android.text.InputType`,
`android.text.InputFilter.LengthFilter`, `android.view.inputmethod.EditorInfo`, `Handler/Looper`. No `TableLayout`
(the task allows plain LinearLayouts; a row is a horizontal LinearLayout with a fixed-width control column).
Java 8. Not compiled against the SDK here: a syntax-only javac run shows no parse errors, only missing-framework
supertype errors (`does not override` for `Activity.onCreate(Bundle)` / `SeekBar.OnSeekBarChangeListener` are the
normal no-SDK consequence, signatures are the standard framework ones).

| Change | File | Reason |
|---|---|---|
| Stuck-row bug fixed: `addCycle(...)` and its captured `current` lambda are gone. Every control reads the store fresh at click/change time (`store.getString/getBool/getInt` with the `SettingsKeys` default); the cycle/band math moved to new pure `logic/SettingsCycle.java` (`next(String[]/int[])` walks every value and wraps, unknown current -> first value, empty/null lists degrade inert; `nearest(int[],int)` snaps a garbage stored percent to the closest band value with long math) | `CarSettingsActivity.java`, `logic/SettingsCycle.java` (new) | Root cause per parent engineer: the lambda re-wrote the captured open-time value every tap. |
| New pure `logic/SettingsValidation.java`: `validPin` (digits only, 4..6 after trim), `timeoutOk` (10..3600 inclusive, mirrors `SettingsKeys.clampTimeoutS`), `parseTimeout` (null on junk/overflow, never throws) + constants | `logic/SettingsValidation.java` (new) | Inline Saved/error validation must be pure and unit-tested (task §4). |
| Screen rewritten as a table: title bar ("Car settings" + right `✕ Close` -> `finish()`); four section cards (`card_bg`, accent header): **Display** (lights→backlight switch, dim-level SeekBar, lights→theme switch, dark-mode pills), **Reverse gear** (volume pills, level SeekBar, MCU switch), **Home screen** (map-app pills, BT-tab pills, favourite-row info line), **Valet mode** (master, active, auto-entry switches, timeout field, PIN field, allowed-apps + phone-status + warning info lines). One row per setting: label + grey one-line description left (weight 1), control right-aligned in a fixed 260dp column so switches/selectors line up; thin divider between rows (theme `text_sub` at 0x50 alpha, 0.5dp min 1px); row `minHeight` 56dp + 8dp vertical padding -> 56-64dp actual; info lines span the row in grey | `CarSettingsActivity.java` | Owner's table layout (§2). `dp()` via `getDisplayMetrics().density`; page in a ScrollView. |
| On/off settings are slider `Switch`es with `setOnCheckedChangeListener` writing `isChecked`: booleans "Let MCU attenuate reverse volume", "Valet auto-entry", "Valet mode enabled (master)", "Valet mode active (manual toggle)" — the two C17 exact labels kept. Two-value on/off settings become switches too: `nothing`/`dim` (backlight) and `nothing`/`dark` (theme-on-lights; theme change calls `reapplyTheme()`) | `CarSettingsActivity.java` | §3. Initial `setChecked` happens before the listener attaches, so building the screen never writes prefs. |
| Valet master/active side effects kept (master-off while active -> `App.valet().exit()`; active -> enter/exit), then `resyncSwitch(sw, l, realState)` re-reads the real state with the listener detached (`setOnCheckedChangeListener(null)` -> `setChecked` -> re-add) and no-ops when the state already matches — no re-trigger loop; `updateWarn()` refreshes the S26a warning + phone status line | `CarSettingsActivity.java` | Owner rule §3; static check SA41 pins the pattern. |
| Choice settings became segmented pill selectors: TextView pills with `GradientDrawable` (16dp corners; selected = `accent` fill + `@color/bg` text — never white on accent at night; unselected = transparent + text_sub outline). Tap writes the value fresh, re-renders by re-reading the store (`SettingsCycle.indexOf`; a garbage pref selects nothing until a tap). Human labels: dark mode Sun/Light/Dark/Car lights, reverse volume Unchanged/Lower/Mute, map app Auto/Maps/Waze, BT tab 1/2/3. Dark mode still calls `reapplyTheme()` (S30); the settings activity has no `uiMode` configChanges, so the night flip recreates it and the palette re-resolves | `CarSettingsActivity.java` | §3 look + fresh-state rendering. |
| Percent settings became snapping SeekBars: band `{20,40,60,80}` / `{20,30,40,50}` maps to progress 0..len-1, initial progress = `SettingsCycle.nearest` (garbage stored percent lands on a legal value), live "40 %" label while dragging, saved on `onStopTrackingTouch` (never mid-drag) | `CarSettingsActivity.java` | §3. |
| Valet timeout is now editable (was an info line) on its existing key `KEY_VALET_TIMEOUT_S`, owner default unchanged; PIN/timeout fields styled: `GradientDrawable` outline (1.5dp stroke `text_sub`, turns `accent` on focus via `paintField`), 8dp corners, `field_bg` fill, monospaced 23sp centred digits, fixed widths (PIN 160dp, timeout 120dp + " s" unit label), numeric keyboard (`android.text.InputType.TYPE_CLASS_NUMBER`, PIN additionally `TYPE_NUMBER_VARIATION_PASSWORD`), `InputFilter.LengthFilter` caps (PIN 6, timeout 4), saves on `EditorInfo.IME_ACTION_DONE` and on focus loss, inline green "Saved" / red error (gauge_ok/gauge_bad) that clears after 2 s (`Handler`, callback removed in `onDestroy`) | `CarSettingsActivity.java`, `res/values/colors.xml`, `res/values-night/colors.xml` (new `field_bg`) | §4. Day note: the day card is already pure white — nothing can be lighter, so the day fill equals the card and the outline separates it; night fill `#FF262B36` is lighter than the night card. |
| Tests: `t24SettingsCycle` (U30/U31 walk+wrap+unknown-first+empty-safe+nearest incl. Integer.MIN/MAX), `t25SettingsValidation` (U32/U33 boundaries, junk, overflow, clamp mirroring); Smoke SG62/SG63 degrade scenarios; static SA16 re-pointed to `SettingsValidation.validPin(` (old `p.length() >= 4` inline check is gone), new SA40 (switch/seekbar/pill/LengthFilter wiring), SA41 (resync pattern), SA42 (addCycle gone + fresh store reads); conformance C43/C44 (structure, human labels, password variation, Done-save, resync, editable timeout key, rounded fields) | `tests/unit/Main.java`, `tests/unit/Smoke.java`, `tests/smoke_static.py`, `tests/conformance.py` | New pure logic + the redesigned screen must be covered. |
| `MapCardController.java`, `MediaCardController.java`, `CarClient.java`, `RadioState.java`, `RadarView.java` untouched; no git commands run | — | Task hard rules. |

**Suite now (Round 6):** 295 unit checks, 63 smoke scenarios / 149 checks, 61 static checks, 61 C-ids → `ALL TESTS PASSED`.
