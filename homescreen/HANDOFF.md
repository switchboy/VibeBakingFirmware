# Handoff — VibeBaking homescreen launcher (2026-11-25)

**Where:** `homescreen/` (self-contained; nothing outside it was touched). Specs = `specs.md`
(S-ids + verification map), plan = `plan.md`, changelog = `CHANGELOG.md`, usage = `README.md`.

**Built:** platform-signed privileged app `org.vibebaking.launcher` (Soong `VibeLauncher`): home
screen (map card via WM Shell TaskView, media card via notification listener, RainViewer radar,
clock, battery chip), app drawer (alphabetical 4-column grid, `▦` → drawer, `✕`/HOME closes it), car
settings (`⚙`), valet mode (suspend outside the allowed set, DND total silence, shade/recents
blocked, PIN exit), day/night theme. Pure logic core in `logic/` compiles with plain javac; Android
classes are thin, degrade via reflection (S36), and compile only on the build host.

**Bottom favourite row (S40):** four one-tap slots under the card row. Slot 0 ships preinstalled with
the HCT Bluetooth app `com.microntek.bluetooth` (`☎`) and opens it on its dialler tab via the app's
own `curTab` extra (index cycleable in car settings). Empty slots show `+` and open the drawer;
long-press pins from the drawer (`★`) or clears a slot. Slots outside the allowed set are hidden in
valet and editing is refused while valet is active (S40b/S40c). Slot state is a 4-field CSV read
**positionally**, so clearing one slot never shifts the others; uninstalled favourites collapse to
`+`, and icon/label failures fall back to a glyph.

**Trusted phone (BT live since attempts 36/37):** both Bluetooth sources are consulted (S25a).
Primary = HCT/GOC: broadcasts `net.easyconn.bt.connected|notconnected|opened`, report
`com.microntek.bt.report`, plus the pair list in `Settings.System` (`MTC.BT.deviceList`/`matchList`).
Secondary = Android's own stack (adapter, bonded, A2DP/HFP proxies). HCT wins when informative; two
"unknown"s keep valet inert. Auto-entry is armed by default; `valet_enabled` stays **off** until the
owner configures it. The exit hook re-checks every 10 s while valet is active and is owned by the
valet state, so it survives the home screen being paused (was an activity-lifecycle bug).

**Crash-safety (owner requirement):** one BT service being unavailable never crashes the app —
receiver registration, Settings.System reads, broadcast extras, proxies, pair-list queries, teardown
and probe construction are guarded, so a broken source contributes UNKNOWN only; valet never calls a
probe raw (`probeSafe()`/`configuredSafe()`). Drawer and favourite row follow the same rule (package
enumeration, icons, launches caught). Entry needs an exit path — PIN, or a phone connected **or
paired**; with none, entry is refused with a warning (S26a) and crash replay unsuspends, never re-traps.

**Tests (all green here):** `bash tests/run.sh` → unit 228 checks, smoke 59 scenarios/139 checks,
static smoke 47 checks, conformance 50 C-ids. Device acceptance is owner-gated:
`VBF_CONFIRM=1 bash tests/device_acceptance.sh` (A12 BT signals, A13 phone slot).

**Smoke found and fixed (see CHANGELOG):** DayNight wrong for Tokyo evenings and polar day/night; NaN
coords; junk battery frames printed 121 V; `ThemePolicy.night(null,…)` NPE; stray callbacks; null
media package NPE; unknown stream max muted; garbage valet timeout fired instantly; wiped PIN + no
phone signal re-trapped the owner; failed radar fetch kept a stale grid and stacked timers; valet
suspended the Waze map card; favourite-slot CSV shifted slots; exit watch ran only while home visible.

**Next steps (build host + unit):**
1. Stage `app/` → `device/rockchip/rk3399/apps/VibeLauncher/`, add to `PRODUCT_PACKAGES`, drop
   Launcher3 there, copy `privapp-permissions-vibelauncher.xml` to `/system/etc/permissions/`.
2. `m VibeLauncher`, install, `pm set-home-activity org.vibebaking.launcher/.LauncherActivity`.
3. Verify before shipping: TaskView class/module names, `ActivityOptions.setEmbeddedTaskId`,
   `StatusBarManager.disable` masks, enforced permission for `setPackagesSuspended`, radio station
   state key, battery scaling vs multimeter (A06), Material lib module, BT action strings +
   `MTC.BT.deviceList` contents, and which `curTab` index is the BT dialler tab (A13).
4. Run device acceptance with owner approval; record results in `docs/findings.md` (parent).
5. Owner eyeballs: drawer at 1024x600 (12 icons + scroll), bottom row (☎ dialler, pin/un-pin),
   valet drawer allowed-only, night switch, BT auto-entry and phone-connect exit (~10 s).

**Gotchas:** no Android SDK here (app builds only on the NAS host); radar timer stops on
pause/destroy; volume restored on ACC_OFF too (lost BACKVIEW_STOP frame); `App` statics need
Application.onCreate; the BT app has one activity (`MainActivity`) with internal tabs, hence `curTab`.
