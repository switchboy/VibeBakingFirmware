# Task: outside temperature + weather icon, gauge icons, four-dot contrast (owner 2026-11-27)

Work in `homescreen/` only; `bash homescreen/tests/run.sh` must end with `ALL TESTS PASSED`. No SDK: only framework
APIs already used in this app or long-standing basics. Java 8. **No git commands at all.** Do not touch
`MapCardController.java`, `MediaCardController.java`, `CarClient.java`, `RadioState.java`, `CarSettingsActivity.java`.
If you do not know a value, API name or resource: write UNKNOWN in a comment and list it in your report - never guess.
Append a "Round 7" section to `BUILD-ERRORS-A14.md`.

The icons already exist (added by the parent engineer, do not edit their path data): `res/drawable/ic_gauge_battery`,
`ic_gauge_engine`, `ic_gauge_coolant`, `ic_gauge_oil`, `ic_wx_sun`, `ic_wx_moon`, `ic_wx_sun_cloud`, `ic_wx_moon_cloud`,
`ic_wx_cloud`, `ic_wx_rain`, `ic_wx_pouring`, `ic_wx_fog`, `ic_wx_thunder`, `ic_wx_snow` (24x24 vectors, fill
`@color/text_sub`, meant to be tinted in code). Credits are in `homescreen/CREDITS.md`.

## 1. Weather next to the date (measured free space: ~120 dp)

In the top-right clock row (`clock` + `clock_date`), right-aligned after the date: a weather icon (28 dp) and the
outside temperature ("8°", same text size and colour as the date, one decimal never shown). Ids `weather_icon`,
`weather_temp`. Hidden until the first value. Must not push or ellipsize the clock; the date may ellipsize.

### Data
* Weather: Open-Meteo, no key, verified by the parent engineer:
  `https://api.open-meteo.com/v1/forecast?latitude=<lat>&longitude=<lon>&current=temperature_2m,weather_code,is_day`
  -> JSON `{"current":{"temperature_2m":8.3,"weather_code":3,"is_day":1,...}}`. Use the same HTTP helper style as
  `HttpRadarFetcher` (User-Agent "VibeLauncher/1.0 (head unit)", timeouts 10 s / 15 s), off the UI thread, result
  posted to the main thread. Refresh every 15 minutes while the home screen is visible and on resume when older than
  15 minutes. Failure: keep the last value; never crash.
* Position: the same position the radar uses (`LauncherActivity.updateHomePosition()` chooses GPS fix or the De Bilt
  default). **Privacy: round latitude/longitude to 1 decimal (~10 km) before building the URL**; never log or store the
  position.
* Car outside temperature: HCTCanBus broadcasts `com.canbus.temperature` with String extra `temperature` (format not yet
  seen on a car: parse the first signed decimal number in the string, e.g. "12.5", "-3", "12.5°C"). If one arrived in
  the last 10 minutes, show it instead of Open-Meteo's temperature (the car's sensor is local); the icon still comes from
  Open-Meteo. Runtime receiver, `Context.RECEIVER_EXPORTED`, unregistered in onDestroy.

### Icon mapping (pure, `logic/WeatherIcon.java`, unit-tested): WMO weather code + is_day -> drawable name
| WMO code | day | night |
|---|---|---|
| 0, 1 | ic_wx_sun | ic_wx_moon |
| 2 | ic_wx_sun_cloud | ic_wx_moon_cloud |
| 3 | ic_wx_cloud | ic_wx_cloud |
| 45, 48 | ic_wx_fog | ic_wx_fog |
| 51, 53, 55, 56, 57, 61, 80 | ic_wx_rain | ic_wx_rain |
| 63, 65, 66, 67, 81, 82 | ic_wx_pouring | ic_wx_pouring |
| 71, 73, 75, 77, 85, 86 | ic_wx_snow | ic_wx_snow |
| 95, 96, 99 | ic_wx_thunder | ic_wx_thunder |
| anything else | ic_wx_cloud | ic_wx_cloud |

Return an enum or the resource name; the activity maps it to `R.drawable.*`. Icon tints (make it pretty, subtle, both
themes readable): sun warm yellow `#FFFFC83D`, moon pale `#FFB8C7E0`, clouds/fog `@color/text_sub`, rain/pouring blue
`#FF4FA3FF`, snow white-blue `#FFCFE3FF`, thunder yellow `#FFFFC83D`. Also unit-test: temperature formatting (8.3 -> "8°",
-0.4 -> "0°" not "-0°", -3.6 -> "-4°"), JSON parsing of the sample above plus missing/garbled fields, the CAN string
parser ("12.5", " -3 ", "12.5°C", "abc", null), the 10-minute preference rule, and the coordinate rounding.

## 2. Gauge icons (instrument-cluster style outlines)

Each gauge in the row under the clock gets its icon on the left (`setCompoundDrawablesRelativeWithIntrinsicBounds`,
20 dp icon, 4 dp padding), tinted with the **same colour as its value** (`setCompoundDrawableTintList`, updated every time
the value's colour changes):
* `battery` -> `ic_gauge_battery`
* `engine_temp` -> `ic_gauge_coolant` for coolant, `ic_gauge_oil` for oil
* `engine_rpm` -> `ic_gauge_engine` (neutral `text_sub`, also for "Engine off")

## 3. Four-dot button contrast

`res/drawable/ic_four_dots.xml` has a hard-coded light fill (`#FFB8C0CC`) that is nearly invisible on the light day theme.
Use `@color/text_sub` like the other bottom-strip icons.

## Deliverable
Reply with the files changed (one line each), the final test line, and anything you could not do or marked UNKNOWN.
