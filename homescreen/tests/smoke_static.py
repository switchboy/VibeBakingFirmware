#!/usr/bin/env python3
"""Degradation smoke checks for the Android-side classes (they only compile on the build host).

Each SA-id is a failure scenario that must be handled by code we cannot run here: missing
framework classes, denied permissions, dead media sessions, a dying MCU bridge. Static analysis
of the degrade paths; the runtime proof happens on the device (tests/device_acceptance.sh).
"""
import os
import re
import sys

ROOT = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
results = []


def read(rel):
    p = os.path.realpath(os.path.join(ROOT, rel))
    assert p.startswith(ROOT), f"{rel} escapes the homescreen dir"
    return open(p, encoding="utf-8").read()


def ok(sa, cond, why=""):
    results.append((sa, bool(cond), why))
    print(("PASS " if cond else "FAIL ") + sa + (" — " + why if not cond and why else ""))


mapc = read("app/src/org/vibebaking/launcher/MapCardController.java")
radar = read("app/src/org/vibebaking/launcher/RadarView.java")
media = read("app/src/org/vibebaking/launcher/MediaCardController.java")
valet = read("app/src/org/vibebaking/launcher/ValetController.java")
car = read("app/src/org/vibebaking/launcher/CarClient.java")
theme = read("app/src/org/vibebaking/launcher/ThemeApplier.java")
audio = read("app/src/org/vibebaking/launcher/AudioAttenuator.java")
act = read("app/src/org/vibebaking/launcher/LauncherActivity.java")
settings = read("app/src/org/vibebaking/launcher/CarSettingsActivity.java")
pinact = read("app/src/org/vibebaking/launcher/ValetPinActivity.java")
app = read("app/src/org/vibebaking/launcher/App.java")
strings = read("app/res/values/strings.xml")
night = read("app/res/values-night/colors.xml")
man = read("app/AndroidManifest.xml")

# SA01 - no navigation app installed: placeholder decided BEFORE any TaskView touch.
init = mapc[mapc.find("public void init"):mapc.find("boolean isNavigation")]
ok("SA01", "showPlaceholder" in init and init.find("showPlaceholder") < init.find("embed("),
   "placeholder must be shown before embed() is attempted")

# SA02 - WM Shell TaskView classes missing/renamed: caught, placeholder, no crash.
catch_i = init.find("catch (Throwable t)")
ok("SA02", "Class.forName(\"com.android.wm.shell" in mapc and catch_i != -1
   and init.find("showPlaceholder", catch_i) != -1,
   "TaskView drift must degrade to placeholder")

# SA03 - placeholder tap when the app still isn't installed: guarded.
ok("SA03", re.search(r"if \(t != null\) \{", mapc), "placeholder click guarded against a missing app")

# SA04 - radar: a failed fetch must clear the stale grid (no frozen tiles from a previous load).
ok("SA04", radar.find("tiles.clear()") > radar.find("RadarPlan.build") and "origin = o" in radar,
   "stale tile grid must be replaced (cleared) on every load, including failures")

# SA05 - radar: refresh timer must not stack across pause/resume/recreate; stop() exists.
ok("SA05", "removeCallbacks" in radar and "public void stop()" in radar
   and "radar.stop()" in act, "single refresh timer, stopped on pause/destroy")

# SA06 - radar: undecodable tile body (HTML error page) is skipped, not fatal.
ok("SA06", "decodeByteArray" in radar and re.search(r"catch \(Throwable decodeFail\)", radar),
   "corrupt tile must be skipped")

# SA07 - media: listener never connected -> idle/no-access card, no crash.
refr = media[media.find("public void refresh"):media.find("int pickIndex")]
ok("SA07", "showNoAccess()" in refr and "MediaListenerService.instance == null" in refr,
   "no listener access -> showNoAccess")
ok("SA07b", "showNoAccess()" in refr and refr.find("instance == null") < refr.find("getActiveSessions"),
   "access check happens before the session call")

# SA08 - media: getActiveSessions throwing (SecurityException) is caught.
ok("SA08", re.search(r"catch \(Throwable t\)[^\n]*\n[^\n]*showNoAccess", media),
   "session enumeration failure must degrade to the no-access card")

# SA09 - media: player gone between refresh and click -> act() no-ops, caught.
act_fn = media[media.find("void act(int which)"):media.find("void cycleSource")]
ok("SA09", "cursor < 0 || cursor >= controllers.size()" in act_fn and "pc == null" in act_fn
   and "catch (Throwable t)" in act_fn, "transport click after a dead controller no-ops")

# SA10 - valet: persist-before-suspend, replay decision delegated to ValetPolicy.replayAction.
ok("SA10", valet.find('store.put("valet_active", true)') < valet.find("suspend(list, true)")
   and "ValetPolicy.replayAction" in valet,
   "pending state persisted before suspending; replay decision from pure policy (S26a/S27a)")

# SA11 - valet: denied permissions (setPackagesSuspended / StatusBarManager) degrade, not crash.
ok("SA11", re.search(r"catch \(Throwable t\) \{[\s\S]*?setPackagesSuspended failed", valet)
   and re.search(r"catch \(Throwable t\) \{[\s\S]*?status bar disable failed", valet),
   "suspend/status-bar failures must be logged and swallowed")
ok("SA11b", "if (pkgs.isEmpty()) return;" in valet, "empty suspend list skips the binder call")

# SA12 - car bridge: missing jar / hidden-API rejection retried, state reads guarded.
ok("SA12", "Class.forName(MANAGER_CLASS)" in car and "retries > 30" in car
   and "if (!methodsReady) return false" in car and "if (!methodsReady) return \"\"" in car,
   "CarManager drift degrades quietly and state reads return safe defaults")
ok("SA12b", "if (!connected) {" in car and "mirrorBundle" in car,
   "first callback marks availability; Bundle mirror never throws")

# SA13 - theme: setNightMode rejected -> app-level fallback -> worst case light, no crash.
ok("SA13", "setNightMode" in theme and "setApplicationNightMode" in theme
   and re.search(r"catch \(Throwable t2\) \{ return false; \}", theme),
   "night-mode application failure degrades to light")

# SA14 - backlight: WRITE_SETTINGS denied -> skipped; unreadable brightness -> no bogus restore.
ok("SA14", "SCREEN_BRIGHTNESS" in theme and "catch (Throwable t)" in theme
   and "return v < 0 ? null : v / 255.0" in theme,
   "brightness write/capture failures degrade")
ok("SA14b", "if (fraction == null && restore == null) return;" in theme,
   "applyBacklight(null, null) is a no-op (no restore of an unknown value)")

# SA15 - audio: a lost BACKVIEW_STOP is repaired by ACC_OFF/SLEEP; MCU delegation only when connected.
ok("SA15", "public void onAccOff()" in audio and "captured == null" in audio
   and "audio.onAccOff()" in act, "lost reverse-stop frame restores the volume on ACC_OFF")
ok("SA15b", "VolumePolicy.delegateToMcu(store.reverseMcu()) && car.isAvailable()" in audio,
   "MCU delegation only when the car bridge is alive")

# SA16 - settings: PIN save requires >=4 digits; master off exits active valet; warning refreshed.
ok("SA16", "p.length() >= 4" in settings and "App.valet().exit()" in settings
   and "updateWarn()" in settings and "valetEnabled" in settings,
   "PIN validation + master-off exit + bootstrap warning wired")

# SA17 - PIN pad: hash re-read per attempt (a PIN saved while the pad is open works).
ok("SA17", pinact.find("store.valetPinHash()") > pinact.find("setOnClickListener")
   or "String hash = store.valetPinHash()" in pinact[pinact.find("setOnClickListener"):],
   "PIN hash must be re-read on every attempt, not captured at onCreate")

# SA18 - badge hidden while the master switch is off (S27a).
ok("SA18", "valet.isActive() && store.valetEnabled()" in act, "valet badge hidden when valet is off")

# SA19 - resources: night palette has no pure white; placeholders exist; theme survives recreation.
ok("SA19", not re.search(r"#(FFFF(FF|FFFFFF)|FFFFFF)\b", night, re.I)
   and "radar_placeholder" in strings and "map_placeholder" in strings,
   "night palette must not contain pure white and placeholders must exist")
ok("SA19b", 'android:configChanges="' in man and "uiMode" in man
   and 'android:screenOrientation="landscape"' in man,
   "uiMode handled by the activity (animated theme switch), landscape panel")

# SA20 - dynamic accent absent: reflection candidates only, static accent stays.
ok("SA20", "Class.forName" in app and "import com.google.android.material" not in app,
   "material lib absence must not crash the app")

# SA21 - app drawer: launch failure (uninstalled mid-list / suspended package) is caught.
drw = read("app/src/org/vibebaking/launcher/AppDrawerActivity.java")
ok("SA21", "void launch(String pkg)" in drw and "catch (Throwable t)" in drw[drw.find("void launch"):]
   and "i == null" in drw, "drawer tap on a vanished app must no-op")

# SA22 - app drawer: package enumeration denied -> empty message, not a crash.
ok("SA22", "catch (Throwable t)" in drw[drw.find("List<AppDrawerPolicy.Entry> enumerate"):]
   and "drawer_empty" in strings, "denied enumeration shows the empty message")

# SA23 - app drawer: icon fetch failure keeps the default icon (no crash while drawing).
ok("SA23", "sym_def_app_icon" in drw and "getApplicationIcon" in drw
   and "catch (Throwable t)" in drw[drw.find("build()"):drw.find("List<AppDrawerPolicy.Entry> enumerate")],
   "missing app icon must fall back, not crash the grid")

# SA24 - app drawer is the only app surface in valet: gear hidden, drawer filtered, PIN badge live.
ok("SA24", "R.id.btn_apps" in act and "drawer_close" in read("app/res/layout/drawer_activity.xml")
   and "ValetPolicy.allowedSet" in read("app/src/org/vibebaking/launcher/logic/AppDrawerPolicy.java"),
   "valet drawer cannot escape the allowed set; close control exists")

fails = [r for r in results if not r[1]]
print(f"{len(results)} scenario checks, {len(fails)} failed")
sys.exit(1 if fails else 0)
