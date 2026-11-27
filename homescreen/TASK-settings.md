# Task: car settings screen - fix stuck toggles, slider switches, table layout, styled inputs (owner 2026-11-27)

Work in `homescreen/` only; `bash homescreen/tests/run.sh` must end with `ALL TESTS PASSED`. No Android SDK: use only
long-standing framework widgets (`android.widget.Switch`, `SeekBar`, `TextView`, `EditText`, `LinearLayout`,
`TableLayout`/`TableRow` or plain LinearLayouts, `GradientDrawable` for backgrounds). Java 8. No git. Do not touch
`MapCardController.java`, `MediaCardController.java`, `CarClient.java`, `RadioState.java`, `RadarView.java`.
Append a "Round 6 - settings screen" section to `BUILD-ERRORS-A14.md`.

## 1. Bug: toggles and cycles get stuck (root cause found by the parent engineer)

`CarSettingsActivity.addCycle(...)` captures the value the setting had when the screen opened (`current`) in the
click lambda: `next = !current` / `indexOf(values, current) + 1`. The first tap works; every later tap writes the
same value again, so the row is stuck. Fix: read the stored value at click time (`store.getBool/getString/getInt`
with the key's default from `SettingsKeys`), never a captured copy. Add a pure helper in `logic/` (e.g.
`SettingsCycle.next(String[] values, String current)` / `next(int[] values, int current)`) with unit tests: repeated
application walks through all values and wraps; unknown current -> first value.

## 2. Look: a table of settings

Screen 1024x600 landscape, dark theme of the launcher (reuse `@color/` and `@drawable/card_bg` from the home screen).

* Title bar: "Car settings" left, a close/back button right (finishes the activity).
* Settings grouped in sections, each section one card (`card_bg`), with a section header:
  **Display** (car lights -> backlight, backlight dim level, car lights -> theme, dark mode),
  **Reverse gear** (reverse -> volume, reverse volume level, let MCU attenuate),
  **Home screen** (map card app, Bluetooth app tab for the phone slot, favourite row info),
  **Valet mode** (master, active, auto-entry, timeout, PIN, allowed apps info, phone status, warning).
* Inside a card every setting is one table row: label (and a one-line grey description when useful) on the left,
  the control right-aligned in a fixed-width control column so all switches/selectors line up vertically. Thin
  divider between rows, 56-64 dp row height, generous padding. Info lines span the row in grey.

## 3. Controls

* On/off settings -> `android.widget.Switch` (slider), right-aligned, state from the store, `setOnCheckedChangeListener`
  writes the new `isChecked` value. Valet master/active keep their side effects (exit valet when master goes off,
  enter/exit on the active switch, `updateWarn()`); after a side effect, re-read the real state and set the switch
  without re-triggering the listener (remove listener, setChecked, re-add).
  Bool settings: "Let MCU attenuate reverse volume", "Valet auto-entry", "Valet mode enabled", "Valet mode active".
* Two-value settings that are really on/off become switches too: "Car lights on -> backlight" (`nothing`/`dim`),
  "Car lights on -> theme" (`nothing`/`dark`).
* Choice settings (dark mode, reverse -> volume, map card app, Bluetooth tab) -> a segmented selector: a row of
  pill buttons, the selected one filled with the accent colour, tap selects (writes the value, re-renders the row).
  Human labels: dark mode `cycle`="Sun", `always_light`="Light", `always_dark`="Dark", `car_lights`="Car lights";
  reverse volume `unchanged`="Unchanged", `lower`="Lower", `mute`="Mute"; map app `auto`="Auto", `maps`="Maps",
  `waze`="Waze"; BT tab 0/1/2 = "1"/"2"/"3". Dark-mode changes still call `reapplyTheme()`.
* Percent settings (backlight dim level 20/40/60/80, reverse volume level 20/30/40/50) -> a `SeekBar` snapping to the
  allowed values, with the value shown right of it ("40 %"), saved on release.

## 4. Manual input (valet PIN, valet timeout)

Styled number fields instead of a bare EditText + Button:
* Rounded outline box (`GradientDrawable`: 1.5 dp stroke in `text_sub`, 8 dp corners, slightly lighter fill than the
  card), large monospaced digits (22-24 sp), centred, fixed width (PIN 4-6 digits ~160 dp; timeout ~120 dp + unit
  label "s" after it), numeric keyboard (`InputType.TYPE_CLASS_NUMBER`; PIN additionally
  `TYPE_NUMBER_VARIATION_PASSWORD`), max length (PIN 6, timeout 4).
* Stroke turns the accent colour on focus. Save on the keyboard's Done action and on focus loss; show a short inline
  confirmation ("Saved" in green, fades after 2 s) or an inline error in red (PIN shorter than 4 digits; timeout
  outside 10..3600 s). Put validation in a pure `logic/` method with unit tests.
* If the timeout is currently only displayed (not editable) in the existing code, make it editable with its existing
  key (`SettingsKeys`), default unchanged.

## Deliverable
Reply with the files changed (one line each), the final test line, and anything you could not do.
