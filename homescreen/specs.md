# VibeBaking homescreen/launcher — testable specifications

Translated from `docs/homescreen.md` (owner idea 2026-11-24). Every spec has an ID and a
verification method: **U** = unit test (pure logic, runs on the build workstation),
**C** = conformance test (static check of the app sources, `tests/conformance.py`),
**A** = device acceptance (`tests/device_acceptance.sh`, run against a live unit, owner-gated).

Firmware facts this rests on (all verified in the repo, read-only):
- MCU→Android events arrive as frames `fa cmd1 cmd2 len(payload)` on `/dev/ttyV2`; ported
  CarService parses them (`HctUtil.getFramePos`, little-endian length) and dispatches
  `dispatchCallback(type, Bundle)` to clients of binder service `"carservice"`
  (`docs/hct-framework-port-survey.md` §3, live wire measured in `docs/findings.md` attempt 34/35).
- Client API on Android 14: `android.microntek.CarManager` (in `hct-framework.jar`, appended to
  BOOTCLASSPATH, hidden-API tokens stripped, so app code may call it):
  `attach(CarListener,String)` / `attach(Handler,String)`, `getParameters(String)`,
  `setParameters(String)`, `getBooleanState(String)`, `getStringState(String)`, `detach()`.
- Event protocol observed in `CarService.cmdProc` (cmd1=0x16, cmd2 per byte):
  | cmd2 | Bundle keys | meaning |
  |---|---|---|
  | `0x43` | `type="backview"`, `value=true`, `mode="backview"/"frontview"/"rightview"` | reverse/camera start |
  | `0x44` | `type="backview"`, `value=false` | camera stop |
  | `0x4a` | `type="headlight"`, `value=bool` | car lights (illumination `sta_ill`) on/off |
  | `0xc0` | `type="battery"`, `value=int` | battery voltage (bench frame `fa 16 c0 02 00 79 00` → 121 ⇒ 12.1 V, tenths of volt, to be confirmed live) |
  | `0x4e` | `type="key"`, `value=int` | hardware key press |
  | `0x49` | `type="acc_off"` / `0x42` `type="sleep"` | power state |
  Callback type string for these is `"CarEvent"`; current state readable with
  `getBooleanState("headlight")` / `getBooleanState("backview")` (CarService keeps them in `mDataList`).
- Allowed HCT packages (from the staged APKs in `device/rk3399-px6-hct4/apps/`):
  `com.microntek.radio`, `com.microntek.bluetooth`, `com.microntek.frontview`, `com.microntek.backview`.
- System packages that must never be suspended: framework `android`, `com.android.systemui`,
  `android.microntek.service` (HCTManagerService), `android.microntek.canbus` (HCTCanBus),
  `android.microntek.mtcser` (HCTBlueToothManager), and the launcher itself `org.vibebaking.launcher`.
  `com.android.settings` IS suspended while valet mode is on (owner decision in homescreen.md).

## S0 — environment
- **S0.1** Package `org.vibebaking.launcher`, Soong module `VibeLauncher`, installed as
  `/system/priv-app/VibeLauncher`, platform-signed (`certificate: "platform"`), `privileged: true`,
  `android:sharedUserId="android.uid.system"`. [C]
- **S0.2** Target API 34 (Android 14), built inside the LineageOS 21 tree via
  `device/rockchip/rk3399/...` device tree; no Gradle, no Play dependencies. [C]

## S1/S2 — replaces Launcher3 as the default home
- **S1** `LauncherActivity` declares intent-filter `MAIN` + categories `HOME` and `DEFAULT`. [C]
- **S2** Default home resolution points to `org.vibebaking.launcher/.LauncherActivity`
  (`adb shell pm set-home-activity …`, recorded as a live fix; release checklist moves it into a
  first-boot step). [A]
- **S2b** The launcher is the **only** launcher (owner, Nov 25): Launcher3 is dropped from
  `PRODUCT_PACKAGES` on the build host, and any HOME-resolving package is hidden from the app
  drawer so nothing else can be started from our home screen. [C, A]

## S3–S5 — layout for the 1024x600 landscape panel
- **S3** One screen, no scroll: map card left (≈58% width, full height), media card top-right,
  rain radar below it, clock top-right corner, battery chip beside the clock. [C]
- **S4** Orientation locked landscape; no rotation handling. [C]
- **S5** All four cards present in the layout XML simultaneously and visible at 1024x600. [C, A]

## S6–S9 — map card
- **S6** Navigation app runs as a real task embedded in a WM Shell `TaskView` (the mechanism
  Android Automotive CarLauncher uses), driven from the launcher; requires `MANAGE_ACTIVITY_TASKS`
  and platform signature. Code lives in `MapCardController` only, so API drift on the build host
  touches one class. [C]
- **S7** Target configurable: Google Maps (`com.google.android.apps.maps`) / Waze (`com.waze`) /
  auto (first installed wins); persisted setting. [U, C]
- **S8** If neither navigation app is installed or TaskView fails: placeholder + "open Maps/Waze"
  button; launcher keeps running. [U (selection logic), A]
- **S9** Map task follows the system night mode with no extra code (Maps/Waze do it themselves). [A]

## S10–S14 — media card
- **S10** Sessions enumerated with `MediaSessionManager.getActiveSessions(listener)` from a
  `NotificationListenerService` subclass; shows title / artist / album art of the active controller. [C]
- **S11** Transport toggles: play/pause, next, previous via `MediaController`
  (`ACTION_PLAY_PAUSE`, `ACTION_SKIP_TO_NEXT`, `ACTION_SKIP_TO_PREVIOUS`). [U (transport policy), C]
- **S12** Source switch: cycling through controllers that have a session; a controller publishing
  no metadata shows package label, never an empty card. [U]
- **S13** HCT radio appears as another source after the carservice port: station text readable via
  `CarManager.getStringState(...)`; phase 2, behind `CarClient` hook. [C (hook present), A (phase 2)]
- **S14** Notification-listener access: launcher detects `enabled_notification_listeners` and
  points the owner at the toggle if not granted; card degrades to "no access" state, no crash. [C]

## S15–S17 — rain radar
- **S15** Tiles fetched from the RainViewer public API (`https://rainviewer.com/api/latest/
  radar_by_zoom/<zoom>/<lat>/<lon>/en.json`, then the `{z}/{x}/{y}` tile template of the latest
  frame); tile grid math is pure and unit-tested; network fetch behind an injectable interface. [U]
- **S16** Own style: day = light basemap + saturated rain; night = dark basemap + muted rain
  (tile alpha lowered, no glow). Palette choice is pure logic. [U]
- **S17** Attribution text from the API `info.attribution` shown on the card. [U]
- **S18'** Offline: no tiles / API failure → placeholder drawn, no crash, retry later. [U, A]

## S18–S20 — clock & battery chip
- **S18** Clock shows current local time, refreshed each minute, locale date+time format. [U]
- **S19** Battery chip hidden until the first `CarEvent/battery` event; formats int value as
  volts with one decimal (121 → "12.1 V"). [U]
- **S20** Chip highlights when volts < threshold (default 11.5 V, owner-adjustable later). [U]

## S21–S27a — valet mode
- **S21** Allowed set (default, exactly the owner's list): `com.google.android.apps.maps`,
  `com.microntek.radio`, `com.microntek.bluetooth`, `com.microntek.frontview`,
  `com.microntek.backview`, plus launcher `org.vibebaking.launcher`. Extra packages are opt-in
  per package. [U, C]
- **S22** On entry: `setPackagesSuspended()` on every **non-system** package outside the allowed
  set; `com.android.settings` explicitly suspended; framework/SystemUI/HCT services/launcher and
  the rear camera never suspended; suspended list lifted on exit (also on launcher death via
  persisted state replay at start). [U (policy), C]
- **S23** All notifications suppressed: `NotificationManager.setInterruptionFilter(INTERRUPTION_FILTER_NONE)`
  on entry; previous filter restored on exit. [C]
- **S24** No shade / quick settings / recents escape: `StatusBarManager.disable(mask)` on entry,
  `disable(DISABLE_NONE)` on exit (mask constants verified against tree at build time). [C]
- **S25** Enter: manual toggle in launcher settings; automatic when a trusted-phone probe reports
  "no trusted phone" within timeout (default 60 s) after boot. The Bluetooth stack is **live** on
  this unit (attempts 36/37: pairing, HFP calls, PBAP contacts, A2DP music all work), so auto-entry
  is armed by default (`DEFAULT_VALET_AUTO = true`) — the master switch `valet_enabled` (S27a) still
  gates everything. An "unknown" verdict never auto-enters. [U]
- **S25a** Trusted-phone source: **both** stacks are consulted. Primary = the HCT/GOC stack
  (`android.microntek.mtcser.BlueToothService` + the GOC daemon), via its broadcasts
  `net.easyconn.bt.connected` / `net.easyconn.bt.notconnected` / `net.easyconn.bt.opened` and the
  BT report `com.microntek.bt.report` (pair list carrying device addresses). Secondary = Android's
  own Bluetooth stack (adapter state, bonded devices, A2DP/HFP profile proxies). The HCT verdict
  wins when it is informative; Android's is the fallback; two "unknown"s stay unknown. [U, C]
- **S25b** Fault tolerance of the phone probes (spec S36/S37): **one service being unavailable must
  not crash the app**. Each source is constructed and queried defensively — a missing mtcser app, a
  receiver that cannot be registered, a denied `BLUETOOTH_CONNECT`, a dead profile proxy or junk
  broadcast extras contribute "unknown" from that source only. The other source still answers; if
  both are unknown, valet stays inert (never auto-enters, never exits, entry refused per S26a).
  Teardown (`release()`) is guarded too. [U, C]
- **S26** Exit: trusted-phone-connected hook — while valet is active the launcher re-checks the
  combined verdict every 10 s (`ValetController.WATCH_MS`) and exits when a trusted phone connects;
  the watch is owned by the **valet state**, not by the home activity's lifecycle, so it keeps
  running while the owner is inside the app drawer or settings (it stops only on exit / master off).
  Or the valet PIN. PIN stored as SHA-256 hash; wrong PIN: max 5 attempts, then 30 s lockout.
  Correct PIN while locked resets nothing; lockout expires on time. [U, C, A]
- **S26a** Not-configured guard (bootstrap trap fix, owner note Nov 25): entry is refused when
  **no exit path exists** — no PIN set AND no trusted phone *reachable*. Reachable means connected
  now, **or** paired so that connecting it later ends valet (the S26 hook). Without an exit path the
  unit would lock the owner out (no PIN, no phone signal ⇒ no way back). Settings shows a warning
  "valet mode: no exit configured", plus a live phone-status line, until a PIN or phone exists.
  Exit itself always works. Crash replay after a lost exit path unsuspends instead of re-trapping. [U]
- **S27a** Master switch `valet_enabled` (default **off**): when off, no auto-entry, no manual
  entry, no suspension, no DND/shade disabling — valet code is inert. Turning it off while valet
  is active exits immediately. [U, C]
- **S27** Valet home screen keeps the cards + a valet badge; the app surface is the drawer limited
  to the allowed set (spec S39b), and the gear is hidden; exit affordance is the PIN pad.
  Launcher itself keeps full UI. Badge hidden while `valet_enabled` is off. [A]

## S28–S31 — car settings (in launcher settings screen)
- **S28** Car lights on → backlight: `nothing` / `dim to N %`; **default `nothing`**. Signal =
  headlight CarEvent (edge) + `getBooleanState("headlight")` (initial). Dimming applies the
  system screen-brightness level; default applies nothing. [U]
- **S29** Car lights on → theme: `nothing` / `dark`; **default `nothing`**. Same signal. [U]
- **S30** Dark mode: `day/night cycle` (default) / `always light` / `always dark` / `follow car
  lights`. Cycle = sunrise/sunset computed from GPS position (pure NOAA-style math, tested);
  applied with `UiModeManager.setApplicationNightMode(UI_MODE_NIGHT_YES|NO|UNSPECIFIED)`. The
  launcher theme follows the resulting uiMode. [U, C]
- **S31** Reverse gear → volume: `unchanged` / `lower to N %` (default **lower**, N default 30 %)
  / `mute`; applied on `backview` start, restored on `backview` stop (restore = volume captured
  before attenuation). Optional MCU delegation: `ctl_backview_vol` via
  `CarManager.setParameters(...)` when the owner enables "let MCU attenuate". [U, C]

## S32–S35 — day and night theming
- **S32** Night resources via `-night` qualifiers (`values-night`); switching is the standard
  `UiModeManager` configuration change; transition is animated (300 ms crossfade), not abrupt. [C]
- **S33** Night palette contains **no pure white** (no `#FFFFFFFF` / `#FFFFFF` in any night
  resource or night code path); conformance test greps. [C]
- **S34** Accent colour from Material You dynamic palette when the material library is present in
  the build (applied by reflection; absent → static accent fallback, no crash). Night keeps hue,
  lowers brightness. [C]
- **S35** Element rules: background/cards day high-contrast, night low-luminance; media backdrop
  tinted from album-art palette (light tint day, dark tint night, art dimmed at night); clock
  digits dark by day, dim light by night; radar per S16. [U (palette derivation), C]

## S36–S38 — robustness
- **S36** `android.microntek.CarManager` may be absent (jar not deployed) or `"carservice"` may be
  unregistered: launcher must not crash; car-event features degrade. Guarded with
  `Class.forName`/try-catch in `CarClient` only. [C]
- **S37** No network, no navigation app, no media sessions → launcher still renders home. [U, A]
- **S38** Survives uiMode/orientation configuration changes without activity recreation storm
  (`onConfigurationChanged` handles uiMode for the animated theme switch). [C]

## S39 — app drawer (owner, 2026-11-25)
- **S39** Simple app drawer: **alphabetical**, laid out as a **4x3 grid** on the 1024x600 panel
  (`AppDrawerPolicy.GRID_COLUMNS/GRID_ROWS`); more apps scroll vertically, page math is unit-testable.
  Entry = `▦` glyph in the clock row (`AppDrawerActivity`); exit = `✕` or the HOME key (HOME returns
  to the home screen, no back stack left behind). [U, C, A]
- **S39a** Contents: packages with a launch intent only — services and components are not apps;
  packages that resolve as `HOME` (this launcher, Launcher3 if still present) are hidden; protected
  framework/HCT service packages are hidden. Sorted case-insensitive by app label, package name as
  tie-breaker. [U]
- **S39b** In valet mode the drawer lists **only the allowed set** (spec S21/S27) — it is never an
  escape around the suspension. The gear (`⚙`) is hidden while valet is active; the badge opens the
  PIN pad. Replacing the old "valet tiles" idea: the drawer *is* the valet app surface, so the dead
  `homeTiles()` API was removed (allowed-set filtering lives in `AppDrawerPolicy`). [U, C, A]
- **S39c** Launch failures (app uninstalled mid-list, suspended package, activity-not-exported)
  are caught: the drawer logs and stays usable. [C]
- **S39d** The header status shows the count and page count from the pure grid math (`N apps · M
  pages`, 12 icons per page), so the page math is visible in the UI rather than only unit-tested. [C]

## S40 — bottom favourite row (owner, 2026-11-25)
- **S40** Four one-tap slots pinned to the bottom of the home screen (`res/layout/favorites_bar.xml`,
  included under the card row). Contents live in `logic/FavoritePolicy`; the store form is exactly
  four comma-separated fields read **positionally**, so clearing slot 2 never shifts slot 3. A
  favourite whose app was uninstalled collapses to an empty slot (aligned row, tap opens the drawer),
  and an unreadable icon/label falls back to the placeholder glyph. [U, C, A]
- **S40a** Slot 0 ships **preinstalled** with the HCT Bluetooth app `com.microntek.bluetooth`
  (glyph `☎`), which is the hands-free dialler: MainActivity holds the tabs, so the launcher passes
  the app's own tab extra `curTab` (index from the owner setting, garbage clamped 0..2). Verified on
  the unit which index is the dialler tab. [U, C, A]
- **S40b** Valet: slots outside the allowed set (spec S21 + the map card's nav app) are hidden while
  valet is active, so the row can never be an escape around the suspension; the Bluetooth slot always
  survives (it is in the owner's allowed list). [U, C]
- **S40c** Owner edits: long-press an app in the drawer → pins it to the first free slot (a full row
  replaces slot 0; a duplicate pin keeps its slot and shows `★`); long-press a home slot → empties it.
  Both are refused while valet is active, so the row cannot be edited under suspension. [C, A]

## Verification map
| Spec | U | C | A |
|---|---|---|---|
| S0,S1,S2,S2b | – | C01–C04 | A01 (default home) |
| S3–S5 | – | C05 | A02 (layout visible) |
| S39/S39a/b/c/d | U18 | C26,C27,C31 | A11 (drawer live + valet filter) |
| S40/S40a/b/c | U21 | C38,C39 | A13 (phone slot opens the BT dialler tab) |
| S6–S8 | U07 | C06,C07 | A03 (map task embedded) |
| S10–S14 | U02 | C08,C09 | A04 (media card live) |
| S15–S18' | U01,U03 | C10 | A05 (radar tiles) |
| S18–S20 | U04,U05 | – | A06 (battery chip live) |
| S21–S27a | U06,U08,U14,U19,U20 | C11,C12,C17,C29,C30 | A07 (valet suspend + DND live), A12 (BT entry/exit live) |
| S28–S31 | U09,U10,U11 | C13 | A08 (events live) |
| S32–S35 | U12 | C14,C15 | A09 (night switch) |
| S36–S38 | U13 | C16,C40 | A10 (degrade live) |
