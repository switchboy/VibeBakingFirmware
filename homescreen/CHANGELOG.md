# Changelog — VibeBaking homescreen launcher

All timestamps are the workstation date (2026-11-25). Spec ids refer to `specs.md`.

## 2026-11-25 — app drawer (owner request)
- **Added S39/S39a/S39b/S39c**: app drawer — alphabetical, 4x3 grid on the 1024x600 panel,
  scrollable beyond 12 icons. Entry `▦` in the clock row, exit `✕` or HOME.
  `logic/AppDrawerPolicy` (pure) + `AppDrawerActivity` + `res/layout/drawer_activity.xml`.
- **S39a filtering**: only packages with a launch intent (services are not apps); protected
  framework/HCT service packages hidden; packages resolving as `HOME` hidden (S2b).
- **S39b valet**: drawer lists only the allowed set while valet is active; the gear is hidden while
  valet is active; the badge opens the PIN pad. Replaces the earlier "valet tiles" idea (S27).
- **S2b**: launcher is the only launcher — Launcher3 must be dropped from `PRODUCT_PACKAGES` on the
  build host (parent-side change; noted in README/plan, not made here).
- **Fixed (found while wiring the drawer):** valet suspended the nav app the map card targets when
  the owner chose Waze (Waze is not in the owner's allowed list) → `ValetPolicy.withMapTarget()` +
  `MapCardController.navTarget()` + `ValetController.setNavTarget()/refreshSuspension()`; the map
  card is now re-inited on resume when the map-target setting changed.
- Tests added: unit U18 (order/filter/valet/grid math), smoke SG44–SG47, static SA21–SA24,
  conformance C26–C28, device acceptance A11.

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
