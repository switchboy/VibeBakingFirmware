# Task: bottom bar + engine gauges + radar tweaks (owner request 2026-11-27)

Work in `homescreen/` only. Tests: `bash homescreen/tests/run.sh` must end with `ALL TESTS PASSED`.
You cannot compile against Android (no SDK). Use only APIs already used elsewhere in this app, or long-standing basic
ones (View, TextView, ImageView, LinearLayout, FrameLayout, BroadcastReceiver, IntentFilter, Context.RECEIVER_EXPORTED,
Handler/Looper, Color). Java 8 source level (no `var`, no `List.of`). The parent engineer compiles and tests on the unit.
**Do not touch** `MapCardController.java`, `MediaCardController.java` (except where stated), `CarClient.java`,
`RadioState.java`. Do not run git. Append a "Round 5" section to `BUILD-ERRORS-A14.md` listing every change and why.

## 1. Bottom strip: app drawer + settings next to the four-dot button

Today `res/layout/home_activity.xml` has a 32 dp bottom strip (`@dimen/bottom_strip_height`) with the four-dot button
`fav_handle` in the centre and the volt meter `battery` at the right. The app-drawer button `btn_apps` (▦) and the
settings button `btn_settings` (⚙) sit in the top-right row next to the clock.

* Move `btn_apps` and `btn_settings` into the bottom strip, inline with `fav_handle`: a centred horizontal group
  `[btn_apps] [fav_handle] [btn_settings]`, each about 64 dp wide, full strip height, same visual weight as the dots.
  Keep their ids and click behaviour (LauncherActivity already wires them by id; valet mode hides `btn_settings` -
  keep that working).
* Move `battery` out of the strip (see 2). The strip then holds only the three buttons.
* The strip may grow to 40 dp if the icons need it (update the dimen; `favorites_bar` uses it as its bottom margin).

## 2. Right column under the clock: voltage, engine temperature, RPM

The top-right row keeps only clock + date (now that the buttons are gone it can use the full column width). Directly
below it add one row of three gauges, right-aligned, same text size as the old volt meter (`@dimen/battery_size`):

    12.6 V     88 °C     2150 rpm

* Voltage: the existing `battery` TextView moves here (same id; `LauncherActivity.updateBattery()` keeps working),
  colour from the new policy below instead of `battery_ok` / `battery_low`.
* Engine temperature: new TextView `engine_temp`. Label oil temperature as "88 °C oil", coolant as "88 °C" (coolant is
  the common case). Hidden (`GONE`) until a value arrives.
* RPM: new TextView `engine_rpm`, "2150 rpm", neutral text colour (`@color/text_sub`), hidden until a value arrives.
  If no RPM broadcast arrives for 10 s, hide it again (ignition off / protocol without RPM).

### Data sources (verified in HCTCanBus by the parent engineer)

* RPM: broadcast `com.microntek.canbus.rpm`, String extra `rpm` (decimal, e.g. "2150"), sent by HCTCanBus via
  `sendBroadcastAsUser`. Register a runtime receiver in LauncherActivity (`Context.RECEIVER_EXPORTED`), parse with
  `Integer.parseInt(s.trim())` in try/catch, ignore negative or > 9000.
* Engine temperature: **no HCTCanBus protocol publishes coolant or oil temperature**. Build the pure logic and the view
  now; add one entry point `LauncherActivity.onEngineTemp(int celsius, boolean isOil)` (main thread) that updates the
  view, but do not invent a broadcast for it. A real source is wired later, once the car's CAN box is known. Also do
  NOT use `com.canbus.temperature`: that is the outside air temperature.
* Voltage: unchanged (`batteryRaw` from the car event, `BatteryState`).

### Colour policy (pure, new class `logic/EngineGauges.java`, unit-tested)

Colours as ints, reuse the palette in `res/values/colors.xml` where possible (add `gauge_cold` blue `#FF4FA3FF`,
`gauge_ok` green, `gauge_warn` yellow `#FFFFC83D`, `gauge_bad` red `#FFFF5A5A` if missing). Return an enum
`Level { COLD, OK, WARN, BAD }`; the activity maps level -> colour.

Battery voltage (12 V lead-acid; engine off rests 12.4-12.7 V, charging 13.8-14.7 V):

| Volts | Level |
|---|---|
| < 11.5 | BAD |
| 11.5 - < 12.0 | WARN |
| 12.0 - 14.8 | OK |
| > 14.8 - 15.2 | WARN |
| > 15.2 | BAD |

Coolant (VAG 1.2 TSI EA111, 105 hp; thermostat ~87 °C, fan from ~95 °C, cluster warning ~120 °C):

| °C | Level |
|---|---|
| < 70 | COLD |
| 70 - 104 | OK |
| 105 - 114 | WARN |
| >= 115 | BAD |

Oil (same engine; normal 90-110 °C, short spikes to ~125 under load are fine):

| °C | Level |
|---|---|
| < 70 | COLD |
| 70 - 124 | OK |
| 125 - 134 | WARN |
| >= 135 | BAD |

Put every threshold in named constants with this source comment ("VAG EA111 1.2 TSI 105 hp, owner 2026-11-27").
Tests: every boundary value above (e.g. 11.49 BAD, 11.5 WARN, 11.99 WARN, 12.0 OK, 14.8 OK, 14.81 WARN, 15.2 WARN,
15.21 BAD; coolant 69/70/104/105/114/115; oil 69/70/124/125/134/135), plus RPM parsing ("2150", " 800 ", "-1", "abc",
"12000", null).

## 3. Rain radar card

The radar card (`radar_card` with `radar_view` + `radar_attribution`) sits under the media card in the right column.
The new gauge row takes vertical space: the radar card must shrink to fit (it is weight-based; make sure nothing in
the right column is clipped at 1024x600 with the 40 dp strip), and must stay at least 120 dp high.

## 4. Radar base map more see-through

`RadarView.onDraw` draws the OpenStreetMap base tiles first, then the radar overlay. Draw the base tiles with alpha
**0.55** (day) and **0.45** (night, on top of the existing `NIGHT_BASE` tint), so the card background shows through and
the rain stands out. The radar overlay keeps its current alpha. Constants with a comment; keep the
`canvas.save()/translate/restore()` centring as it is.

## Deliverable

Reply with: files changed (one line each), the final test line, and anything you could not do.
