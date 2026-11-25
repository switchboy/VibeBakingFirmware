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
  `SettingsKeys` (owner defaults), `Json`, `ColorTools`, `ArtPalette`, `RadarFetcher`,
  `PhonePresence`/`PhonePolicy`/`PhonePresenceProbe`/`CombinedPhoneProbe` (trusted-phone verdicts,
  both BT sources, fault tolerance), `FavoritePolicy` (bottom row slots, glyphs, BT dialer tab).
  This compiles and runs on any JDK — that is how the logic is tested here.
- `app/src/org/vibebaking/launcher/` — thin Android classes: `LauncherActivity`, `App`,
  `AppDrawerActivity`, `CarSettingsActivity`, `ValetPinActivity`, `CarClient` (reflective
  `android.microntek.CarManager`),
  `SettingsStore`, `ThemeApplier`, `AudioAttenuator`, `MapCardController` (WM Shell TaskView),
  `MediaListenerService`, `MediaCardController`, `RadarView`, `HttpRadarFetcher`,
  `HctBluetoothProbe` (HCT/GOC BT broadcasts + Settings.System pair list),
  `BluetoothPhoneProbe` (Android's own stack, second source).
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
   Soong's graph regeneration OOM-killed `soong_build` at 21 GB RSS (attempt 38), so until that is
   solved the app is compiled with `build-on-build-host.sh` (aapt2 + javac + d8 against the tree's
   built jars). **It compiles**: javac 0 errors, 77 classes, `classes.dex` 109 KB, badging reports
   `provides-component:'launcher'`. Details: `BUILD-ERRORS-A14.md`.
4. On the unit: `pm set-home-activity org.vibebaking.launcher/.LauncherActivity`
   (see `tests/device_acceptance.sh`, owner-gated with `VBF_CONFIRM=1`).
5. Verify-before-ship list is in `plan.md` (TaskView module/API names, StatusBarManager mask,
   radio station state key, battery scaling vs multimeter). The `setPackagesSuspended` permission is
   no longer open: the tree enforces `android.permission.SUSPEND_APPS`, now declared + whitelisted.

## Using it
- Home screen: left = navigation card (Maps or Waze embedded; placeholder if neither installed),
  right = clock/date + battery chip + media card + radar card; `▦` opens the app drawer, `⚙` opens
  car settings.
- **Bottom favourite row (S40)**: four one-tap slots along the bottom. Slot 0 ships preinstalled with
  the HCT Bluetooth app (`☎`) and opens it on its dialler tab (the app's own `curTab` extra, index
  cycleable in car settings until the unit confirms which index is the dialler). Empty slots show `+`
  and open the drawer. Long-press a drawer app to pin it (marked `★`; a full row replaces slot 0),
  long-press a home slot to clear it. Pinning/un-pinning is refused while valet is active, and slots
  outside the allowed set are hidden during valet (the `☎` slot always stays — Bluetooth is allowed).
- **App drawer (S39)**: alphabetical, 4-column grid (owner's 4x3 on 1024x600), scrollable when there
  are more apps. Only packages with a launch intent; HOME-resolving packages (this launcher,
  Launcher3 if still present) and protected framework/HCT services are hidden. Entry = `▦`,
  exit = `✕` or the HOME key. The header shows `N apps · M pages` (12 icons per page). In valet mode
  it lists **only the allowed apps** (plus the nav app the map card targets), so it can't escape the
  suspension; the gear is hidden while valet is active — the drawer *is* the valet app surface.
- Car settings cycles every owner preference (backlight, lights→theme, dark mode, reverse volume,
  MCU delegation, map target, valet master/auto/toggle, valet timeout, PIN).
- Valet mode: master switch (`valet_enabled`, default **off**) must be on **and** an exit path must
  exist (PIN set, or a trusted phone connected **or paired**). Entry is refused with a visible
  warning otherwise, so the owner can never be locked out of the unit (S26a). Exit = PIN pad (tap the
  VALET badge), or the paired phone connecting while valet is active (checked every 10 s, S26).
- **Trusted phone (S25/S25a)**: both Bluetooth sources are consulted — the HCT/GOC stack first
  (connection broadcasts `net.easyconn.bt.connected|notconnected|opened`, report
  `com.microntek.bt.report`, and the pair list the service stores in `Settings.System` under
  `MTC.BT.deviceList`/`MTC.BT.matchList`), Android's own stack second. The HCT verdict wins when it
  is informative. Car settings shows the live verdict ("trusted phone connected" / "phone paired but
  away" / "unknown"). Auto-entry is armed by default; the master switch keeps it inert until the
  owner enables valet. **One BT service being unavailable never crashes the app** (S25b): that source
  reports "unknown" and the other still answers; if both are unknown, valet stays inert.
- Media card needs notification-listener access; the card shows a "grant access" prompt until then.
- Radar: RainViewer tiles over our own basemap, refresh ~10 min, offline → placeholder text.

## Testing layers
- `bash tests/run.sh` — unit (228 checks) + degradation smoke (59 scenarios / 139 checks) +
  static smoke (58 scenario checks) + conformance (51 spec C-ids). All pass on this workstation.
- `VBF_CONFIRM=1 bash tests/device_acceptance.sh` — only with owner approval; read-only adb dumps
  plus two reversible writes (`pm set-home-activity`, `setprop sys.hct.debug`). Results belong in
  `docs/findings.md` in the parent repo.
- The Android classes themselves only compile on the build host (`build-on-build-host.sh`); their
  failure paths are covered by `tests/smoke_static.py` here and by device acceptance on the unit.
  `SA38`/`SA39` guard the Android 14 API surfaces and cross-package imports, which is what a local
  workstation cannot check.
