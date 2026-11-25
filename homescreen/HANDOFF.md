
> **Update (2026-11-25, after attempt 36):** the HCT Bluetooth stack works on the card build: pairing, HFP calls, PBAP contacts, A2DP music (GOC daemon via the ABI shim, `docs/findings.md`). The trusted-phone exit/entry route for valet mode is therefore testable; the "BT stack dead" remark below predates that. Building needs a soong run on the build host, where SSData has ~2.1 GB free (a regenerated build graph is ~3.6 GB) - free space first.
# Handoff — VibeBaking homescreen launcher (2026-11-25)

**Where:** `homescreen/` (self-contained; nothing outside it was touched). Specs = `specs.md`
(S-ids + verification map), plan = `plan.md`, changelog = `CHANGELOG.md`, usage = `README.md`.

**Built:** platform-signed privileged app `org.vibebaking.launcher` (Soong module `VibeLauncher`):
home screen (map card via WM Shell TaskView, media card via notification listener, RainViewer radar,
clock, battery chip), app drawer (alphabetical 4-column grid, `▦` → drawer, `✕`/HOME to close),
car settings (`⚙`), valet mode (suspend outside allowed set, DND total silence, shade/recents
blocked, PIN exit), day/night theme. Pure logic core in `logic/` compiles with plain javac; Android
classes are thin and degrade via reflection (S36) — they compile only on the build host.

**Tests (all green on this workstation):** `bash tests/run.sh` → unit 153 checks, degradation smoke
47 scenarios/108 checks, static smoke 30 scenario checks (Android-side paths), conformance 43 C-ids.
Device acceptance is owner-gated: `VBF_CONFIRM=1 bash tests/device_acceptance.sh`.

**Smoke found and fixed (see CHANGELOG):** DayNight got Tokyo evenings wrong (UTC wrap) and polar
day/night wrong; NaN/absurd coords broke the cycle; junk battery frames would print 121 V;
`ThemePolicy.night(null,…)` NPE'd; stray callback types were accepted; media sessions with a null
package NPE'd; unknown stream max would mute instead of leaving volume alone; garbage valet timeout
fired instantly; a wiped PIN while valet was active re-trapped the owner on restart; a failed radar
fetch kept a stale grid and stacked refresh timers; valet suspended the Waze map card.

**Bootstrap rules the owner must know:** `valet_enabled` defaults **off**; entry needs an exit path
(PIN or trusted phone), else it refuses with a visible warning (S26a). BT stack dead on the current
card build (attempt 35), so auto-entry stays off; PIN exit is the only working route today.

**Next steps (build host + unit):**
1. Stage `app/` → `device/rockchip/rk3399/apps/VibeLauncher/`, add to `PRODUCT_PACKAGES`, drop
   Launcher3 there, copy `privapp-permissions-vibelauncher.xml` to `/system/etc/permissions/`.
2. `m VibeLauncher`, install, `pm set-home-activity org.vibebaking.launcher/.LauncherActivity`.
3. Verify before shipping: TaskView class/module names, `ActivityOptions.setEmbeddedTaskId`
   signature, `StatusBarManager.disable` mask constants, enforced permission for
   `setPackagesSuspended`, radio station state key, battery scaling vs multimeter (A06),
   Material lib module for the dynamic accent (reflection handles absence).
4. Run device acceptance with owner approval; record every result in `docs/findings.md` (parent).
5. Owner eyeballs: drawer at 1024x600 (12 icons, scroll), valet drawer allowed-only, night switch.

**Gotchas:** no Android SDK on this workstation (app builds only on the NAS host); radar refresh
timer stopped on pause/destroy; volume restore also happens on ACC_OFF because a lost BACKVIEW_STOP
frame would leave the volume low; `App` statics require Application.onCreate (normal process start).
