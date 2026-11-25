# VibeBaking homescreen launcher (`org.vibebaking.launcher` / `VibeLauncher`)

Android 14 head-unit home screen for the RK3399/px6-hct4 unit: map card (embedded Maps/Waze task),
media card, RainViewer radar card, clock, battery chip, car settings, valet mode, day/night theme.

Specs live in `specs.md` (S-ids), the build plan in `plan.md`, the changelog in `CHANGELOG.md`.
Everything here is self-contained; nothing outside this directory was modified.

## Layout
- `app/src/org/vibebaking/launcher/logic/` — **pure Java** decision core (no Android imports):
  `RadarTiles`, `RadarPlan` (fetch + tile plan incl. offline/bad-JSON/partial degrade),
  `MediaCardPolicy`, `MapTargetPolicy`, `AppDrawerPolicy` (drawer filter + alphabetical order +
  4x3 grid math), `ValetPolicy`, `ValetPin`, `ThemePolicy`, `DayNight`,
  `VolumePolicy`, `BacklightPolicy`, `BatteryState`, `CarEventParser`, `ClockFormat`,
  `SettingsKeys` (owner defaults), `Json`, `ColorTools`, `ArtPalette`, `RadarFetcher`.
  This compiles and runs on any JDK — that is how the logic is tested here.
- `app/src/org/vibebaking/launcher/` — thin Android classes: `LauncherActivity`, `App`,
  `AppDrawerActivity`, `CarSettingsActivity`, `ValetPinActivity`, `CarClient` (reflective
  `android.microntek.CarManager`),
  `SettingsStore`, `ThemeApplier`, `AudioAttenuator`, `MapCardController` (WM Shell TaskView),
  `MediaListenerService`, `MediaCardController`, `RadarView`, `HttpRadarFetcher`.
- `app/res/` — day + night (`values-night`) palettes/themes, layouts, icons.
- `app/Android.bp` + `app/privapp-permissions-vibelauncher.xml` — Soong module, platform cert,
  privileged, permission whitelist.
- `tests/` — `run.sh` runs everything: unit (`unit/Main.java`), degradation smoke
  (`unit/Smoke.java`), static smoke for Android-side paths (`smoke_static.py`),
  spec conformance (`conformance.py`), owner-gated device acceptance (`device_acceptance.sh`).

## Build / integrate (on the parent's build host — not this workstation)
1. Copy `app/` to `device/rockchip/rk3399/apps/VibeLauncher/` (same staging pattern as the HCT apps).
2. Add `VibeLauncher` to `PRODUCT_PACKAGES`, and copy `privapp-permissions-vibelauncher.xml`
   to `/system/etc/permissions/` via the `hu_apps.mk` whitelist pattern.
3. `lunch lineage_rk3399-ap2a-userdebug` then `m VibeLauncher`.
   The launcher must be the **only** launcher (owner, Nov 25): drop Launcher3 from
   `PRODUCT_PACKAGES` in the device config on the build host, so nothing else can take the HOME role.
4. On the unit: `pm set-home-activity org.vibebaking.launcher/.LauncherActivity`
   (see `tests/device_acceptance.sh`, owner-gated with `VBF_CONFIRM=1`).
5. Verify-before-ship list is in `plan.md` (TaskView module/API names, StatusBarManager mask,
   `setPackagesSuspended` enforced permission, radio station state key, battery scaling vs multimeter).

## Using it
- Home screen: left = navigation card (Maps or Waze embedded; placeholder if neither installed),
  right = clock/date + battery chip + media card + radar card; `▦` opens the app drawer, `⚙` opens
  car settings.
- **App drawer (S39)**: alphabetical, 4-column grid (owner's 4x3 on 1024x600), scrollable when there
  are more apps. Only packages with a launch intent; HOME-resolving packages (this launcher,
  Launcher3 if still present) and protected framework/HCT services are hidden. Entry = `▦`,
  exit = `✕` or the HOME key. In valet mode it lists **only the allowed apps** (plus the nav app the
  map card targets), so it can't escape the suspension; the gear is hidden while valet is active.
- Car settings cycles every owner preference (backlight, lights→theme, dark mode, reverse volume,
  MCU delegation, map target, valet master/auto/toggle, valet timeout, PIN).
- Valet mode: master switch (`valet_enabled`, default **off**) must be on **and** an exit path must
  exist (PIN set, or trusted phone connected). Entry is refused with a visible warning otherwise,
  so the owner can never be locked out of the unit (S26a). Exit = PIN pad (tap VALET badge).
- Media card needs notification-listener access; the card shows a "grant access" prompt until then.
- Radar: RainViewer tiles over our own basemap, refresh ~10 min, offline → placeholder text.

## Testing layers
- `bash tests/run.sh` — unit (153 checks) + degradation smoke (47 scenarios / 108 checks) +
  static smoke (30 scenario checks) + conformance (43 spec C-ids). All pass on this workstation.
- `VBF_CONFIRM=1 bash tests/device_acceptance.sh` — only with owner approval; read-only adb dumps
  plus two reversible writes (`pm set-home-activity`, `setprop sys.hct.debug`). Results belong in
  `docs/findings.md` in the parent repo.
- The Android classes themselves only compile on the build host; their failure paths are covered
  by `tests/smoke_static.py` here and by device acceptance on the unit.
