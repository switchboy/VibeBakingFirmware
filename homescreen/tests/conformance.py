#!/usr/bin/env python3
"""Static spec-conformance checks for the VibeBaking launcher (spec map C-ids).

Runs on the build workstation; reads ONLY files inside this homescreen/ directory.
Exit code 0 = all C-ids pass.
"""
import os
import re
import sys

ROOT = os.path.realpath(os.path.dirname(os.path.abspath(__file__)) + "/..")

results = []

def ok(cid, cond, why=""):
    results.append((cid, bool(cond), why))
    print(("PASS " if cond else "FAIL ") + cid + (" — " + why if not cond and why else ""))

def read(rel):
    p = os.path.realpath(os.path.join(ROOT, rel))
    assert p.startswith(ROOT), f"{rel} escapes the homescreen dir"
    with open(p, "r", encoding="utf-8") as f:
        return f.read()

def exists(rel):
    p = os.path.realpath(os.path.join(ROOT, rel))
    return p.startswith(ROOT) and os.path.exists(p)

# ---- S0/S1/S2 ----
man = read("app/AndroidManifest.xml")
bp = read("app/Android.bp")
priv = read("app/privapp-permissions-vibelauncher.xml")

ok("C01", 'package="org.vibebaking.launcher"' in man and 'android:sharedUserId="android.uid.system"' in man)
ok("C03", re.search(r'name:\s*"VibeLauncher"', bp) and re.search(r'certificate:\s*"platform"', bp)
   and re.search(r"privileged:\s*true", bp))
ok("C02", 'android.intent.category.HOME' in man and 'android.intent.category.DEFAULT' in man
        and 'android.intent.action.MAIN' in man)
ok("C04", "org.vibebaking.launcher" in priv and all(
    p in priv for p in ["MANAGE_ACTIVITY_TASKS", "MANAGE_APP_TOKENS", "MANAGE_USERS",
                        "WRITE_SETTINGS", "ACCESS_NOTIFICATION_POLICY", "QUERY_ALL_PACKAGES"]))

# ---- S3/S4/S5 ----
lay = read("app/res/layout/home_activity.xml")
ids = ["map_card", "media_card", "radar_card", "radar_view", "clock", "clock_date", "battery",
       "valet_badge", "btn_settings", "home_root", "media_title", "media_artist", "media_source",
       "media_art", "media_prev", "media_play_pause", "media_next", "radar_attribution",
       "map_placeholder"]
ok("C05", all(f'@+id/{i}' in lay for i in ids))
navm = re.search(r'name=".LauncherActivity".*?configChanges="([^"]+)"', man, re.S)
ok("C05b", 'android:screenOrientation="landscape"' in man and navm and "uiMode" in navm.group(1))

# ---- S6/S7/S8 ----
mc = read("app/src/org/vibebaking/launcher/MapCardController.java")
ok("C06", "TaskViewHost" in mc and "setEmbeddedTaskId" in mc and "setTaskViewHost" in mc
        and "createTask" in mc and "MANAGE_ACTIVITY_TASKS" in man)
mt = read("app/src/org/vibebaking/launcher/logic/MapTargetPolicy.java")
ok("C07", "com.google.android.apps.maps" in mt and "com.waze" in mt)

# ---- S10/S11/S14 ----
md = read("app/src/org/vibebaking/launcher/MediaCardController.java")
ml = read("app/src/org/vibebaking/launcher/MediaListenerService.java")
mp = read("app/src/org/vibebaking/launcher/logic/MediaCardPolicy.java")
ok("C08", "getActiveSessions" in md and "NotificationListenerService" in ml
        and "BIND_NOTIFICATION_LISTENER_SERVICE" in man)
ok("C09", "skipToNext" in md and "skipToPrevious" in md and ".pause()" in md and ".start()" in md
        and "TR_PLAY_PAUSE" in mp and "TR_NEXT" in mp and "TR_PREV" in mp)

# ---- S15/S16/S17 ----
rt = read("app/src/org/vibebaking/launcher/logic/RadarTiles.java")
rv = read("app/src/org/vibebaking/launcher/RadarView.java")
ok("C10", "https://rainviewer.com" in rt and "/api/latest/radar_by_zoom/" in rt
        and "{z}" in rt and "{x}" in rt and "{y}" in rt
        and "REFRESH_MS" in rv and "AttributionSink" in rv and "radar_attribution" in lay)

# ---- S21/S22/S23/S24 ----
vp = read("app/src/org/vibebaking/launcher/logic/ValetPolicy.java")
vc = read("app/src/org/vibebaking/launcher/ValetController.java")
ok("C11", all(p in vp for p in ["com.google.android.apps.maps", "com.microntek.radio",
                                "com.microntek.bluetooth", "com.microntek.frontview",
                                "com.microntek.backview"])
        and all(p in vp for p in ["android.microntek.service", "android.microntek.canbus",
                                  "android.microntek.mtcser", "com.android.systemui"])
        and 'SETTINGS_PACKAGE = "com.android.settings"' in vp)
ok("C12", "setPackagesSuspended" in vc and "INTERRUPTION_FILTER_NONE" in vc
        and '"status_bar"' in vc and "disable" in vc)
# S22 crash-safety: pending state persisted BEFORE suspending.
p_enter = vc.find('store.put("valet_active", true)')
p_suspend = vc.find("suspend(list, true)")
ok("C21", p_enter != -1 and p_suspend != -1 and p_enter < p_suspend,
   "valet_active must be persisted before setPackagesSuspended")

# ---- S25/S26/S26a/S27a ----
sk = read("app/src/org/vibebaking/launcher/logic/SettingsKeys.java")
cs = read("app/src/org/vibebaking/launcher/CarSettingsActivity.java")
ok("C17", "KEY_VALET_ENABLED" in sk and "DEFAULT_VALET_ENABLED = false" in sk
        and "entryAllowed" in vp and "warnNoExit" in vp
        and "entryAllowed" in vc and "valetEnabled" in vc and "warnNoExit" in cs
        and "Valet mode enabled (master)" in cs and "Valet mode active (manual toggle)" in cs,
   "master switch default off; entry refused without exit path")
enter_i = vc.find("public void enter()")
guard_i = vc.find("entryAllowed", enter_i)
sus_i = vc.find("List<String> list = suspendList()", enter_i)
ok("C17b", enter_i != -1 and guard_i != -1 and sus_i != -1 and enter_i < guard_i < sus_i,
   "enter() refuses before suspending anything")

# ---- S28/S29/S30/S31 ----
ok("C13", re.search(r'DEFAULT_BACKLIGHT_MODE\s*=\s*"nothing"', sk)
        and re.search(r'DEFAULT_THEME_ON_LIGHTS\s*=\s*"nothing"', sk)
        and re.search(r'DEFAULT_DARK_MODE\s*=\s*"cycle"', sk)
        and re.search(r'DEFAULT_REVERSE_VOLUME\s*=\s*"lower"', sk)
        and re.search(r'DEFAULT_REVERSE_VOLUME_PERCENT\s*=\s*30', sk)
        and re.search(r'DEFAULT_VALET_TIMEOUT_S\s*=\s*60', sk)
        and re.search(r'DEFAULT_MAP_TARGET\s*=\s*"auto"', sk))
ta = read("app/src/org/vibebaking/launcher/ThemeApplier.java")
aa = read("app/src/org/vibebaking/launcher/AudioAttenuator.java")
ok("C13b", "setNightMode" in ta and "SCREEN_BRIGHTNESS" in ta
        and "ctl_backview_vol" in read("app/src/org/vibebaking/launcher/logic/VolumePolicy.java")
        and "onReverseStart" in aa and "onReverseStop" in aa)

# ---- S32/S33/S34/S35 ----
ok("C14", exists("app/res/values-night/colors.xml") and exists("app/res/values-night/themes.xml"))
night_colors = read("app/res/values-night/colors.xml")
ok("C14b", not re.search(r"#(FFFF(FFFFFF)?|FFFFFF|ffffff|FFFFFFFF)\b", night_colors, re.I),
   "night palette must contain no pure white")
night_theme = read("app/res/values-night/themes.xml")
ok("C14c", "Theme.DeviceDefault" in night_theme and "@color/bg" in night_theme)
day_theme = read("app/res/values/themes.xml")
ok("C32", "Theme.DeviceDefault" in day_theme and "windowBackground" in day_theme)
la = read("app/src/org/vibebaking/launcher/LauncherActivity.java")
ok("C19", "animateThemeSwap" in la and "onConfigurationChanged" in la and "ClockFormat.TICK_MS" in la
        and "replayPending" in la and "scheduleAutoEnter" in la)
app = read("app/src/org/vibebaking/launcher/App.java")
ok("C15", "DynamicColors" in app and "applyToActivitiesIfAvailable" in app)
src_files = []
for dirpath, _, files in os.walk(os.path.join(ROOT, "app/src")):
    for f in files:
        if f.endswith(".java"):
            src_files.append(os.path.join(dirpath, f))
allsrc = "".join(open(p, encoding="utf-8").read() for p in src_files)
ok("C15b", "import com.google.android.material" not in allsrc,
   "material must stay optional (reflection only)")
ok("C16", "Class.forName(" in allsrc and '"android.microntek' in allsrc
   and "import android.microntek" not in allsrc,
   "CarManager via reflection only; missing jar must not crash the app")
ok("C23", "RadarPlan" in read("app/src/org/vibebaking/launcher/RadarView.java")
   and "hasTiles" in read("app/src/org/vibebaking/launcher/logic/RadarPlan.java")
   and "sanitizeCoords" in read("app/src/org/vibebaking/launcher/logic/RadarPlan.java"),
   "radar degrade decisions live in pure RadarPlan (offline/empty/partial -> placeholder)")
ok("C25", "plausible" in read("app/src/org/vibebaking/launcher/logic/BatteryState.java")
   and "clampTimeoutS" in read("app/src/org/vibebaking/launcher/logic/SettingsKeys.java")
   and "maxVolume <= 0" in read("app/src/org/vibebaking/launcher/logic/VolumePolicy.java"),
   "junk signal values are rejected (implausible battery, garbage timeout, unknown stream max)")
ok("C35", "nightTint" in read("app/src/org/vibebaking/launcher/logic/ArtPalette.java")
        and "nightArtDim" in read("app/src/org/vibebaking/launcher/logic/ArtPalette.java"))

# night code paths must not paint pure white
ok("C18", not re.search(r"0xFF(FFFFFF|FFFFFFFF)", allsrc), "no white constants in Java sources")
for d in os.listdir(os.path.join(ROOT, "app/res/drawable")):
    if d.endswith(".xml"):
        t = read("app/res/drawable/" + d)
        ok("C18b:" + d, not re.search(r'fillColor="#FFFF(FFF|FFFFFF)"', t, re.I) or "@color/" in t)

# ---- S19/S20 ----
bs = read("app/src/org/vibebaking/launcher/logic/BatteryState.java")
ok("C20", "RAW_SCALE = 10.0" in bs and '"%.1f V"' in bs and "DEFAULT_LOW_THRESHOLD_V" in bs
        and "BATTERY" in la and "updateBattery" in la)

# ---- S39 app drawer ----
drw = read("app/src/org/vibebaking/launcher/AppDrawerActivity.java")
dp = read("app/src/org/vibebaking/launcher/logic/AppDrawerPolicy.java")
drwlay = read("app/res/layout/drawer_activity.xml")
ok("C26", 'android:name=".AppDrawerActivity"' in man and "drawer_grid" in drwlay
   and 'android:columnCount="4"' in drwlay and "GRID_COLUMNS = 4" in dp and "GRID_ROWS = 3" in dp
   and "R.id.btn_apps" in la and "apps_glyph" in read("app/res/values/strings.xml"),
   "drawer activity + 4-column grid + entry glyph wired")
ok("C27", "ValetPolicy.allowedSet" in dp and "homeApps.contains(e.pkg)" in dp
   and "queryIntentActivities" in drw and "getLaunchIntentForPackage" in drw
   and "allowedExtras" in drw and "settingsButton.setVisibility(valet ? View.GONE : View.VISIBLE)" in la,
   "drawer: launchable-only, HOME packages hidden, valet limited to allowed set, gear hidden in valet")
ok("C28", "withMapTarget" in read("app/src/org/vibebaking/launcher/logic/ValetPolicy.java")
   and "valet.setNavTarget(map.navTarget())" in la and "refreshSuspension" in vc,
   "valet allowed set follows the map card nav target")

# ---- docs ----
ok("C22", exists("specs.md") and exists("plan.md") and exists("README.md") and exists("HANDOFF.md"))
hand = read("HANDOFF.md")
ok("C22b", len(hand.splitlines()) <= 60, "handoff must stay <= 60 lines")
specs = read("specs.md")
ok("C22c", "S26a" in specs and "S27a" in specs and "| S21–S27a" in specs)
ok("C24", exists("tests/device_acceptance.sh") and "VBF_CONFIRM" in read("tests/device_acceptance.sh"),
   "device acceptance must be owner-gated")

fails = [r for r in results if not r[1]]
print(f"{len(results)} checks, {len(fails)} failed")
sys.exit(1 if fails else 0)
