# Changelog — VibeBaking homescreen launcher

All timestamps are the workstation date (2026-11-25). Spec ids refer to `specs.md`.

## 2026-11-25 — Android 14 compile: the app builds (owner: "make it build")
Compiled for real on the NAS build host (`homescreen/build-on-build-host.sh`: aapt2 compile + link,
javac against the tree's turbine jars, d8). The parent's first pass reported 35 errors; after those
fixes the hand build found 12 more, then 3. Result: **javac 0 errors**, 77 classes, `classes.dex`
109 KB, `aapt2 dump badging` shows `provides-component:'launcher'` and `targetSdkVersion 34`.
- **API drift fixed** (full list in `BUILD-ERRORS-A14.md`): `android.app.UiModeManager`;
  `android.media.session.{MediaController,MediaSessionManager}`; `MediaPlayerControl`/`getPlayer()`
  removed in A14 → `PlaybackState` state + action mask and `TransportControls` for the buttons;
  `ColorMatrix` (absent from the classpath) → night art dim as a `PorterDuffColorFilter` MULTIPLY
  tint; `SharedPreferences` has no double API → lat/lon round-trip as raw bits in a `long`;
  `setPackagesSuspended` A14 overload with `PersistableBundle`s; `android.content.pm.SuspendDialogInfo`
  (not `android.app`); `MediaSessionManager.getActiveSessions(android.content.ComponentName)`;
  `PlaybackState` has no `STATE_PREPARING`; `BluetoothProfile.ServiceListener` (no `ProxyListener`);
  `android.text.InputType`; `ActivityOptions.toBundle()`; `RadarPlan.Plan`; `Set.of()` → Java 8-safe
  `Collections.emptySet()`.
- **Two bugs only a real compile could catch:** a local `boolean valet` shadowed the `ValetController`
  field (so `valet.isActive()` and `valet.setNavTarget()` resolved to the boolean), and
  `BluetoothPhoneProbe` never imported `PhonePresenceProbe`. Static smoke `SA38`/`SA39` now assert the
  A14 API surfaces and that every logic type used outside `logic/` is imported — both are checks that
  would have failed before this round.
- **Suspend permission verified against the tree:** `PackageManagerService` enforces
  `android.permission.SUSPEND_APPS` (`pm/PackageManagerService.java:3263/3302`), so the manifest and
  the privapp whitelist now declare it. Conformance `C40` checks that pairing.
- Static smoke grew to 58 checks, conformance to 51 (`SA38a–j`, `SA39`, `C40`); `SA09`/`C09`/`C27`
  assertions updated to the TransportControls/`valetOn` forms.

## 2026-11-25 — bottom favourite row + phone dialler slot (owner request)
- **Added S40/S40a/S40b/S40c**: four one-tap slots at the bottom of the home screen
  (`res/layout/favorites_bar.xml`, included under the card row). Slot 0 is **preinstalled** with the
  HCT Bluetooth app `com.microntek.bluetooth` (`☎`) — verified against the staged apk: package
  `com.microntek.bluetooth`, single activity `MainActivity` with MAIN/LAUNCHER, tabs implemented with
  `FragmentTabHost` and a `DialFragment`, and the app reads an intent extra `curTab` (dex strings
  `curTab`/`getIntExtra`). The launcher passes `curTab` from the owner setting (`bt_dial_tab`,
  cycled 0/1/2, garbage clamped); which index is the dialler tab must be confirmed on the unit (A13).
- **New pure logic:** `logic/FavoritePolicy` — slot parsing/serialisation, glyphs, visibility rules,
  assign/clear semantics, tab clamp.
- **Slot positions are literal CSV fields** (found while testing): the first parser dropped blanks and
  compacted entries, so clearing slot 1 shifted slot 2. Now `slots()` splits with `-1` and maps each
  field to its slot; a duplicate collapses its later field; a missing/empty pref yields the factory
  row (phone slot filled); a present-but-all-blank pref stays empty (owner cleared everything).
- **Robustness:** uninstalled favourite collapses its slot to `+` (row stays aligned) and the slot is
  dropped on tap; icon/label fetch failures fall back to `ic_app_placeholder` + glyph; launch
  failures are logged, never thrown; the row is rebuilt on resume (installs/uninstalls).
- **Valet (S40b):** slots outside the allowed set (owner list + the map card's nav app) are hidden
  while valet is active, so the row cannot escape the suspension; Bluetooth stays (owner's allowed
  list). Pinning/un-pinning is refused while valet is active (S40c). Drawer apps show `★` when pinned.
- Settings: `Bluetooth app tab for the phone slot (curTab)` cycle + a line listing the row contents.
- Tests added: unit U21 (parse/round-trip/dedupe/assign/clear/visibility/glyphs/tab clamp), smoke
  SG54–SG59 (junk pref, cleared row, uninstalled favourite, full row, duplicate pin, valet hiding,
  tab clamp, out-of-range clear), static SA35–SA37, conformance C38/C39, device acceptance A13.
- Test corrections in this round: slot-position expectations (the parser was wrong, not the tests'
  intent), duplicate-pin expectation (now "keeps its slot"), cleared-row vs factory-row semantics,
  out-of-range clear on a null row.

## 2026-11-25 — trusted phone over the live HCT Bluetooth stack (BT fixed by the parent loop)
The Bluetooth stack is alive now (pairing, HFP calls, PBAP contacts, A2DP music), so valet
auto-entry/exit became real instead of a stub (S25/S26).
- **Added S25a/S25b**: the trusted-phone check consults **both** sources. Primary = HCT/GOC
  (`android.microntek.mtcser.BlueToothService` + GOC daemon): broadcasts
  `net.easyconn.bt.connected` / `net.easyconn.bt.notconnected` / `net.easyconn.bt.opened`
  (`BTDefine` constants) and the report `com.microntek.bt.report`; plus the pair/device list the
  service stores via `saveList()` → `Settings.System` keys `MTC.BT.deviceList` / `MTC.BT.matchList`
  (newline-separated entries containing device addresses). Secondary = Android's own stack
  (adapter enabled, bonded devices, A2DP/HFP profile proxies). The HCT verdict wins when it is
  informative; Android's is the fallback; two UNKNOWNs stay UNKNOWN.
- **New files:** `logic/PhonePresence.java`, `logic/PhonePolicy.java` (verdicts + combination +
  exit-path rule + `parseDeviceList()` address parsing), `logic/PhonePresenceProbe.java` (source
  interface), `logic/CombinedPhoneProbe.java` (pure, fault-tolerant combination),
  `HctBluetoothProbe.java`, `BluetoothPhoneProbe.java`.
- **Crash safety (owner requirement, S25b): one BT service being unavailable must not crash the app.**
  Receiver registration (API-34 export flag, fallback to the older call, `registered=false` on
  failure), broadcast handling, `Settings.System` reads, extras parsing, profile-proxy setup,
  pair-list queries and `release()` are all guarded; a broken source contributes UNKNOWN only.
  `App.onCreate` wraps both probe constructions and falls back to an inert source. `ValetController`
  never calls a probe raw — every path goes through `probeSafe()` / `configuredSafe()`.
- **Exit hook (S26):** while valet is active the combined verdict is re-checked every 10 s
  (`WATCH_MS`); a connected trusted phone exits. Started on entry and on `onResume`, stopped on
  `onPause`/`exit()` so no BT polling runs in the background.
- **Fixed (found while wiring BT):** the trusted-phone exit watch was started/stopped from the home
  activity's `onResume`/`onPause`, so a phone connecting while the owner sat in the app drawer or
  settings would not end valet until they returned home. The watch is now owned by the valet state
  (`enter()` → start, `exit()` → stop) and survives the home screen being paused. Static SA30 + C30
  assert no activity-lifecycle calls remain; spec S26 updated.
- **Exit path semantics (S26a) widened:** a *paired* phone counts as an exit path even while away,
  because the hook ends valet when it connects. Entry is still refused when neither a PIN nor any
  phone signal exists; crash replay exits (unsuspends) instead of re-trapping the owner.
- **Settings:** live phone-status line ("trusted phone connected" / "phone paired but away" /
  "unknown (BT off or unavailable)"), and the no-exit warning uses the same guarded verdict.
- **Default change:** `DEFAULT_VALET_AUTO` is now `true` (owner's spec intent: enter automatically
  when no trusted phone connects within the timeout). `DEFAULT_VALET_ENABLED` stays `false`, so
  nothing happens until the owner turns valet on. Manifest adds `BLUETOOTH_CONNECT` (runtime; with
  `sharedUserId="android.uid.system"` the uid already holds it) — noted in the privapp whitelist.
- Tests added: unit U19 (verdicts, combination, exit-path rules), U20 (both sources, one dead, both
  dead, null sources, teardown), smoke SG48–SG53 (silent stack, dead Android stack, dead HCT service,
  both blowing up mid-run, junk pair-list entries, paired-but-away), static SA25–SA28, conformance
  C29/C30, device acceptance A12 (`settings get system MTC.BT.deviceList`, BT broadcast counts,
  auto-entry/exit walk-through, BT-service-stopped crash check).
- Test corrections in this round: `DEFAULT_VALET_AUTO` expectation updated to `true`; the address
  heuristic assertion in SG52 was inverted (a real address must count); SG52 split into separate
  checks now that parsing lives in pure `PhonePolicy.parseDeviceList`.

## 2026-11-25 — app drawer (owner request)
- **Added S39/S39a/S39b/S39c**: app drawer — alphabetical, 4x3 grid on the 1024x600 panel,
  scrollable beyond 12 icons. Entry `▦` in the clock row, exit `✕` or HOME.
  `logic/AppDrawerPolicy` (pure) + `AppDrawerActivity` + `res/layout/drawer_activity.xml`.
- **S39a filtering**: only packages with a launch intent (services are not apps); protected
  framework/HCT service packages hidden; packages resolving as `HOME` hidden (S2b).
- **S39d** The header status shows the count and page count from the pure grid math (`N apps · M
  pages`, 12 icons per page) so the page math is visible in the UI rather than only unit-tested. [C]
- **S39b valet**: drawer lists only the allowed set while valet is active; the gear is hidden while
  valet is active; the badge opens the PIN pad. Replaces the earlier "valet tiles" idea (S27): the
  dead `ValetPolicy.homeTiles()` / `ValetController.homeTiles()` API was removed - the drawer renders
  the allowed set through `AppDrawerPolicy.visible(valet=true, …)`.
- **S2b**: launcher is the only launcher — Launcher3 must be dropped from `PRODUCT_PACKAGES` on the
  build host (parent-side change; noted in README/plan, not made here).
- **Fixed (found while wiring the drawer):** valet suspended the nav app the map card targets when
  the owner chose Waze (Waze is not in the owner's allowed list) → `ValetPolicy.withMapTarget()` +
  `MapCardController.navTarget()` + `ValetController.setNavTarget()/refreshSuspension()`; the map
  card is now re-inited on resume when the map-target setting changed.
- **Dead code removed:** `AppDrawerActivity.pageFits()` and `CarSettingsActivity.pinOk()`
  (suppressed-unused placeholders; PIN validation happens in the settings dialog and the PIN pad).
- Tests added: unit U18 (order/filter/valet/grid math), smoke SG44–SG47, static SA21–SA24 + SA29,
  conformance C26–C28 + C31, device acceptance A11.

## 2026-11-25 — degradation smoke round (43 scenarios)
Scenarios were written first; the failures below were real defects, each fixed the same day.

| Scenario | Defect | Fix |
|---|---|---|
| SG34 | `DayNight.isNight` classified Tokyo (139.7E) evenings as night — sunrise/sunset minutes compared without wrapping past UTC midnight | hour-difference-around-solar-noon with wrap into [-12,12] |
| SG35/SG36 | midnight sun (78N June) reported night; polar night (78N Dec) reported day at noon | `Polar` states from cos(hour angle): never-rises = always night, never-sets = always day |
| SG37/SG12 | NaN / absurd lat-lon made the theme "day forever" and produced `NaN` API URLs | `DayNight.clampLat/clampLon` + `RadarPlan.sanitizeCoords` fall back to the owner defaults |
| SG17/SG18 | battery frame 1210 would render "121 V"; overflow values rendered absurd labels | `BatteryState.plausible()` (4..32 V window), `known()` uses it, `label()` returns "" when implausible |
| SG43 | `ThemePolicy.night(null, …)` threw NPE on a corrupted pref value | null/unknown dark-mode falls back to `cycle` |
| SG41b | stray CarService callbacks (callback type other than `"CarEvent"`) were parsed as events | `CarEventParser.parse` requires callback type `"CarEvent"`; `mode` null-safe |
| SG30 | media session with a null package/label NPE'd in `MediaCardController.showController` | `mirror()` normalises null pkg/label; `MediaCardPolicy.sourceLabel()` added, `label()` null-safe |
| SG38 | `AudioManager` stream max unknown (0) → `targetVolume("lower", …)` returned 0 = accidental mute | `targetVolume` returns null when `maxVolume <= 0` |
| SG39 | volume percent -50/500 escaped the 0..max range (and the MCU command) | percent clamped 0..100 in `targetVolume`/`mcuVolumeCommand` |
| SG25 | garbage valet timeout (0/negative/overflow) → `postDelayed` fired instantly / overflowed | `SettingsKeys.clampTimeoutS(10..3600)` applied in `SettingsStore` |
| SG21 | PIN wiped while valet was active + BT stack dead → crash-replay re-suspended and locked the owner out | `ValetPolicy.replayAction()` → `EXIT` when the exit path is gone; wired in `ValetController.replayPending` |
| SG24 | corrupted valet extras CSV produced blank entries | `ValetPolicy.parseExtrasCsv()` (trim, drop blanks/duplicates) |
| SG09/SG04 | a failed radar fetch kept the previous tile grid drawn (stale tiles); refresh timers stacked per load | extracted pure `logic/RadarPlan` (fetch+plan, null on failure); `RadarView` replaces the grid wholesale, single refresh timer, `stop()/restart()` on pause/destroy |
| SG11 | oversized bodies were fetched without a bound | `RadarPlan.MAX_BODY_BYTES` cap + `HttpRadarFetcher` bound |
| SG13 | zoom 0/30 produced unbounded tile math | `RadarPlan.sanitizeZoom(3..12)` |
| SG16 | tiles above/below the world grid were wrapped; only horizontal wrap is correct | `clampTile` returns null for out-of-world y, wraps x |
| SG40 | a lost `BACKVIEW_STOP` frame (MCU power-down) left the volume attenuated | `AudioAttenuator.onAccOff()` restores; `LauncherActivity` handles ACC_OFF/SLEEP |
| SG42 | battery value arriving as a String/junk → chip showed 0 V | `CarEventParser.asInt` tolerates strings, junk → 0 → chip hidden |

**Harness added:** `tests/unit/Smoke.java` (runs the pure core against stub fetchers and a local
HTTP server: offline, HTTP 404, HTML rate-limit page, truncated JSON, oversized body, partial tile
failures, antimeridian, DST clock rollover, PIN lockout, valet bootstrap guard, replay decision),
`tests/smoke_static.py` (SA-ids: TaskView drift → placeholder, denied permissions, dead media
sessions, missing CarManager jar, theme failure fallback, drawer launch/icon/enumeration failures).
`tests/run.sh` now runs unit + smoke + static smoke + conformance.

**Test-harness corrections (not product defects):** malformed fixture JSON in the smoke scenarios,
wrong weekday expectations for the DST clock scenario, stale polar expectations in U15 (December at
78N is polar night, so noon is night), lockout timing arithmetic in U08.

**Conformance additions:** C16 regex fixed (reflection constants, not literal `Class.forName("…")`),
C03 fixed (regex vs literal string compare), new C23 (radar degrade lives in pure `RadarPlan`),
C25 (junk-signal rejection: plausible battery, clamped timeout, unknown stream max), C26–C28 (drawer),
C22 docs requirement satisfied by `README.md` / `HANDOFF.md`.

## 2026-11-25 — valet bootstrap guard (owner note)
- **Added S26a**: entry refused when no exit path exists (no PIN and no trusted phone) — with the HCT
  Bluetooth stack dead this would lock the owner out of the unit permanently; settings shows
  "valet mode: no exit configured".
- **Added S27a**: master switch `valet_enabled`, default **off**; turning it off while active exits.
- `ValetPin.Guard` treats an empty stored hash as "never verifies"; settings and the PIN pad say so.

## 2026-11-25 — first build
- Pure logic core (`logic/`): RainViewer tile math/API parse, JSON parser, media/map/valet/theme/
  volume/backlight/battery/day-night policies, colour tools, album-art tinting, car-event parsing,
  settings keys with the owner defaults from `docs/homescreen.md`.
- Android classes: `LauncherActivity`, `App`, `CarClient` (reflective `android.microntek.CarManager`),
  `SettingsStore`, `ThemeApplier`, `AudioAttenuator`, `MapCardController` (WM Shell TaskView),
  `MediaListenerService`, `MediaCardController`, `RadarView`, `HttpRadarFetcher`,
  `CarSettingsActivity`, `ValetPinActivity`.
- `Android.bp` (`VibeLauncher`, platform cert, privileged, no dex preopt), manifest
  (MAIN+HOME+DEFAULT, landscape, `configChanges` incl. `uiMode`), day/night resources,
  `privapp-permissions-vibelauncher.xml`.
- Specs + plan (`specs.md`, `plan.md`), unit tests `tests/unit/Main.java`, conformance
  `tests/conformance.py`, owner-gated `tests/device_acceptance.sh`.
