# Plan — reaching the specs

Order of work (matches the owner's priority list: launcher is nicety #3, so nothing here blocks
the ROM port; all device-tree changes are staged in `homescreen/app/` and applied by the parent
loop to the build host tree).

## Phase 0 — spec + test scaffolding (this dir)
1. `specs.md`: homescreen.md translated into ID-tagged, verifiable specs.
2. `tests/conformance.py` + `tests/unit/`: runnable here on the workstation (javac + plain
   assertions; python static checks). Every U/C ID in the spec map must pass before the app is
   handed to the build host.
3. `tests/device_acceptance.sh`: adb check-list per A-ID; **never run without owner confirmation**
   (env-gated), never writes to the device beyond `pm set-home-activity` / launcher settings.

## Phase 1 — app code (stock Android 14 only: map, media, radar, clock)
Files under `homescreen/app/src/org/vibebaking/launcher/`:
- `LauncherActivity` — home activity; inflates `home_activity.xml` (S3 layout); clock + battery chip;
  animated day/night transition on uiMode config change (S32, S38); valet badge.
- `logic/` — pure-Java decision core, unit-tested here: `SettingsKeys` (+defaults), `ThemePolicy`,
  `DayNight` (sunrise/sunset), `VolumePolicy`, `BacklightPolicy`, `ValetPolicy`, `ValetPin`,
  `CarEventParser`, `RadarTiles` (API JSON + tile math + palette), `RadarPlan` (fetch + tile plan,
  all degrade decisions), `MediaCardPolicy`, `MapTargetPolicy`, `AppDrawerPolicy` (drawer filter +
  alphabetical order + 4x3 grid math, S39), `ClockFormat`, `BatteryState`, `ArtPalette`,
  `PhonePolicy` + `CombinedPhoneProbe` (trusted-phone verdict over both BT sources, S25/S25a/S25b).
- `CarClient` — the *only* class touching `android.microntek.CarManager`; reflective so a missing
  jar cannot crash the app (S36); maps Bundle callbacks to `CarEventParser` results.
- `MapCardController` — the *only* class touching WM Shell `TaskView`/`TaskViewHost` + hidden
  `ActivityOptions` embed API (S6); one class so build-host API drift is contained.
- `MediaCardController` + `MediaListenerService` — MediaSessionManager + NotificationListenerService
  (S10–S14); presentation logic delegated to `MediaCardPolicy`/`ArtPalette`.
- `RadarView` + `HttpRadarFetcher` — tile fetch/composition (S15–S17); fetching behind an interface,
  the plan/degrade logic in pure `RadarPlan` so it is testable offline against stubs.
- `AppDrawerActivity` — app drawer (S39): `▦` glyph opens it, `✕`/HOME closes; alphabetical grid,
  4 columns; in valet only the allowed apps; decisions delegated to `AppDrawerPolicy`. Long-press
  pins an app to the bottom favourite row (S40c).
- Bottom favourite row (S40): `res/layout/favorites_bar.xml` included under the card row, built and
  launched by `LauncherActivity.refreshFavorites()/launchFavorite()`, decisions in `logic/FavoritePolicy`
  (slot CSV read positionally; glyph fallbacks; BT dialler tab extra `curTab`).
- `ValetController` — suspend/unsuspend + DND filter + shade disable (S22–S24); policy delegated to
  `ValetPolicy`; persisted pending-state replay on start (crash safety).
- `CarSettingsActivity` + `ValetPinActivity` — settings rows cycling the enum values, PIN pad.
- `res/`: day values, `values-night`, layouts, drawables (no pure white at night, S33).
- `Android.bp` + `AndroidManifest.xml` + `privapp-permissions-vibelauncher.xml`.

## Phase 2 — car signals through the ported carservice
Headlight/backview/battery events already flow (attempt 35: `HCTPort: carservice registered`,
`/dev/ttyV2` raw receiving). Wire `CarClient` listeners to VolumePolicy/BacklightPolicy/ThemePolicy
and the battery chip. Battery scaling (tenths of volt) confirmed against a multimeter on the unit
(A06); if the MCU sends a different unit, `BatteryState.fromRaw()` is the one place to change.
Radio-as-source reads CarService state once `MicrontekServer` is stable.

## Phase 3 — valet BT entry/exit (BT stack live, attempts 36/37)
The GOC Bluetooth shim works now (pairing, HFP calls, PBAP contacts, A2DP music), so the trusted-phone
hook is real rather than a stub. `logic/PhonePolicy` + `logic/CombinedPhoneProbe` hold the decisions;
`HctBluetoothProbe` reads the HCT/GOC signals (`net.easyconn.bt.connected|notconnected|opened`,
`com.microntek.bt.report`, and the pair list the service stores in `Settings.System` as
`MTC.BT.deviceList` / `MTC.BT.matchList`), `BluetoothPhoneProbe` reads Android's own stack as the
second source. Auto-entry is armed by default (`DEFAULT_VALET_AUTO = true`) but the master switch
(`valet_enabled`, default off) gates everything; the exit watch polls the combined verdict every 10 s.
Both sources are fault-tolerant (spec S25b): one service being unavailable yields "unknown" from that
source only and never crashes the app. Verify on the unit: broadcast actions actually sent by the
model in use (RF210), and whether the device-list entries carry addresses or names.

## Build integration (done by the parent loop on the NAS build host, tree read-only here)
1. Copy `homescreen/app/*` into the tree as `device/rockchip/rk3399/apps/VibeLauncher/`
   (same pattern as the staged HCT apps).
2. `apps/Android.bp`: add module `VibeLauncher` (android_app, privileged, certificate platform).
   Verify on the host: WM Shell module name (`car-wm-shell-lib` vs `wm_shell_lib`) and the exact
   `TaskView`/`TaskViewHost` API in `frameworks/base/libs/wm/shell` for A14 — adjust
   `MapCardController` accordingly. Material lib module (`com.google.android.material`) optional
   via reflection, no hard dependency.
3. `device.mk` / `hu_apps.mk` staging: `PRODUCT_PACKAGES += VibeLauncher`; drop Launcher3 from `PRODUCT_PACKAGES` so this launcher is the
   only launcher (owner, Nov 25, spec S2b); copy
   `privapp-permissions-vibelauncher.xml` to `/system/etc/permissions/` (same PRODUCT_COPY_FILES
   pattern as the HCT whitelist).
4. Build `m VibeLauncher` first (fast module build), then full `m`; splice via
   `tools/splice_super.py` as usual.
5. On the card unit: `pm set-home-activity org.vibebaking.launcher/.LauncherActivity` (live fix,
   recorded in findings + facts), verify A-ids with `tests/device_acceptance.sh` (owner-gated).
6. Release checklist: move live fixes into first-boot provisioning (`docs/release.md` pattern).

## Verify-before-ship checks on the build host (things this workstation cannot check)
- `StatusBarManager.disable()` mask constant values (`DISABLE_EXPAND`/`DISABLE_NOTIFICATIONS`/…)
  read from `frameworks/base/…/StatusBarManager.java` in the tree.
- `setPackagesSuspended` enforcement permission in `PackageManagerService` for A14 — manifest
  declares `MANAGE_APP_TOKENS`+`MANAGE_USERS`; if PMS checks another permission, add it.
- `ActivityOptions` embed method name/signature for TaskView on A14 (CarLauncher is the reference).
- privapp whitelist completeness: boot log must show no "permission X not in whitelisting" for
  `org.vibebaking.launcher`.
- Hidden-API: platform-signed apps are exempt; still grep logcat for `hiddenapi` warnings on first boot.
- BT signals: the `net.easyconn.bt.*` action strings and the `MTC.BT.deviceList`/`MTC.BT.matchList`
  Settings.System keys were read from the mtcser smali (`BTDefine`, `RF210Model._reportDeviceList`).
  Confirm on the unit that the RF210 model actually sends them and that list entries carry device
  addresses (not only device names) — `settings get system MTC.BT.deviceList` (A12).
- `BLUETOOTH_CONNECT` availability with `sharedUserId="android.uid.system"`: confirm the probe reads
  bonded devices / profile proxies without a runtime prompt; if it does not, add a runtime request or
  a `default-permissions` xml entry.

## Risk list
| Risk | Mitigation |
|---|---|
| TaskView API drift vs CarLauncher | contained in `MapCardController`; fallback path S8 ships regardless |
| `setPackagesSuspended` permission mismatch | ValetController catches SecurityException → logs + keeps manual toggle; check PMS on host |
| Battery unit unknown (tenths?) | single `BatteryState.fromRaw` conversion point; A06 measurement before trusting display |
| carservice binder absent at boot | CarClient reflective + retry loop; home still renders (S36/S37) |
| RainViewer rate limits / offline | tile cache + retry backoff; placeholder never crashes |
| Theme race with UiModeManager | apply night mode on config change only; animated transition guarded to one run |
| BT service down / pair list unreadable | each source guarded → UNKNOWN; valet stays inert, entry refused (S25b/S26a) |
| Auto-entry entering valet while the owner's phone is away | master switch default off; exit path = PIN or paired phone (hook ends valet on connect) |
| BT dialler tab index (`curTab`) unknown | index is owner-cycleable 0..2 in car settings; A13 confirms on the unit |
| Favourite app uninstalled / icon unreadable | slot collapses to `+` (row stays aligned); launch failures caught (S40) |
