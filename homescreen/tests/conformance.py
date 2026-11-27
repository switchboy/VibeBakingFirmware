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

def code(src):
    """Source with comments removed, so a note about a removed API never reads as a use of it."""
    s = re.sub(r"/\*.*?\*/", " ", src, flags=re.S)
    return re.sub(r"//.*", " ", s)

def all4(src):
    """The four slot/icon/label/glyph ids of the favourites bar."""
    return all(f'@+id/fav_slot{i}' in src and f'@+id/fav_icon{i}' in src
               and f'@+id/fav_glyph{i}' in src and f'@+id/fav_label{i}' in src for i in range(4))

def inside_guarded_probe(src):
    """True when every raw `probe.probe()` call sits inside the guarded `probeSafe()` body."""
    start = src.find("PhonePresence probeSafe()")
    if start < 0:
        return False
    end = src.find("\n    }", start)
    span = src[start:end] if end > start else src[start:]
    return src.count("probe.probe()") == span.count("probe.probe()")

# ---- S0/S1/S2 ----
man = read("app/AndroidManifest.xml")
bp = read("app/Android.bp")
priv = read("app/privapp-permissions-vibelauncher.xml")

ok("C01", 'package="org.vibebaking.launcher"' in man and 'sharedUserId="' not in man,
   "own app uid: the platform signature grants the permissions; never android.uid.system (system_server identity)")
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
ok("C06", "createVirtualDisplay" in mc and "setLaunchDisplayId" in mc and "setDisplayId" in mc
        and "injectInputEvent" in mc and "VIRTUAL_DISPLAY_FLAG_TRUSTED" in mc
        and "showPlaceholder" in mc and "ADD_TRUSTED_DISPLAY" in man and "INJECT_EVENTS" in man,
        "live map hosts the nav app on a trusted virtual display (WM Shell TaskView is not on the app class path on this ROM); failures fall back to the tap-to-open placeholder")
mt = read("app/src/org/vibebaking/launcher/logic/MapTargetPolicy.java")
ok("C07", "com.google.android.apps.maps" in mt and "com.waze" in mt)

# ---- S10/S11/S14 ----
md = read("app/src/org/vibebaking/launcher/MediaCardController.java")
ml = read("app/src/org/vibebaking/launcher/MediaListenerService.java")
mp = read("app/src/org/vibebaking/launcher/logic/MediaCardPolicy.java")
ok("C08", "getActiveSessions" in md and "NotificationListenerService" in ml
        and "BIND_NOTIFICATION_LISTENER_SERVICE" in man)
ok("C09", "skipToNext()" in md and "skipToPrevious()" in md and "tc.play()" in md and "tc.pause()" in md
        and "TR_PLAY_PAUSE" in mp and "TR_NEXT" in mp and "TR_PREV" in mp,
        "transport actions go through MediaController.TransportControls (MediaPlayerControl is gone in A14)")

# ---- S15/S16/S17 ----
rt = read("app/src/org/vibebaking/launcher/logic/RadarTiles.java")
rv = read("app/src/org/vibebaking/launcher/RadarView.java")
rf = read("app/src/org/vibebaking/launcher/HttpRadarFetcher.java")
la = read("app/src/org/vibebaking/launcher/LauncherActivity.java")
ok("C10", "api.rainviewer.com" in rt and "public/weather-maps.json" in rt
        and "tilecache.rainviewer.com" in rt and "1_1" in rt and "MAX_ZOOM" in rt
        and "/api/latest/radar_by_zoom/" not in code(rt),
        "the real RainViewer v2 API (index + {host}{path}/256/z/x/y/2/1_1.png); the dead 301 endpoint is gone")
ok("C10b", "tile.openstreetmap.org" in rt and "NIGHT_BASE" in rv
        and "baseTiles" in rv and "BASE_CACHE" in rv and "baseTileUrl" in rt
        and "OpenStreetMap contributors" in rt and "RainViewer" in rt
        and "REFRESH_MS" in rv and "AttributionSink" in rv and "radar_attribution" in lay,
        "OpenStreetMap base map under the transparent radar layer (tinted at night; CARTO now needs an API key), decoded tiles cached, attribution wired")
ok("C10c", "VibeLauncher/1.0 (head unit)" in rf and "setConnectTimeout" in rf and "setReadTimeout" in rf,
        "every HTTP request carries the User-Agent and bounded timeouts (connect 10 s, read 15 s)")
ok("C10d", "getLastKnownLocation" in la and '"gps"' in la and '"network"' in la and '"fused"' in la
        and "requestLocationUpdates" in la and "removeUpdates" in la and "SecurityException" in la
        and "RadarPosition" in la and "RECENTRE_METERS" in read("app/src/org/vibebaking/launcher/logic/RadarPosition.java")
        and "ACCESS_FINE_LOCATION" in man,
        "home position: newest of gps/network/fused known fixes, updates via GPS listener on resume, removed on pause; never stored")

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

# night code paths must not paint pure white. Carve-out: the map card's expand chip (white text
# on a translucent black chip over the LIVE map, never a night-paint path) belongs to the map
# card round that is rewriting MapCardController right now — that file is not ours to touch.
ok("C18", not re.search(r"0xFF(FFFFFF|FFFFFFFF)", allsrc.replace(mc, "")),
   "no white constants in Java sources outside the map card live-map chip")
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
   and "allowedExtras" in drw and "settingsButton.setVisibility(valetOn ? View.GONE : View.VISIBLE)" in la,
   "drawer: launchable-only, HOME packages hidden, valet limited to allowed set, gear hidden in valet")
ok("C28", "withMapTarget" in read("app/src/org/vibebaking/launcher/logic/ValetPolicy.java")
   and "valet.setNavTarget(map.navTarget())" in la and "refreshSuspension" in vc,
   "valet allowed set follows the map card nav target")

# ---- S25/S25a/S25b trusted phone over BOTH Bluetooth sources ----
# Action strings verified against apps/bt/smali/android/microntek/mtcser/BTDefine.smali (parent tree).
hct = read("app/src/org/vibebaking/launcher/HctBluetoothProbe.java")
comb = read("app/src/org/vibebaking/launcher/logic/CombinedPhoneProbe.java")
pp = read("app/src/org/vibebaking/launcher/logic/PhonePolicy.java")
ok("C29", '"net.easyconn.bt.connected"' in hct and '"net.easyconn.bt.notconnected"' in hct
   and '"net.easyconn.bt.opened"' in hct and '"com.microntek.bt.report"' in hct
   and '"MTC.BT.deviceList"' in hct and '"MTC.BT.matchList"' in hct
   and "Settings.System.getString" in hct and "static int parseDeviceList" in pp,
   "trusted-phone probe hooks the HCT/GOC BT broadcasts and the service's Settings.System pair list")
ok("C29b", "new HctBluetoothProbe(this)" in app and "new BluetoothPhoneProbe(this)" in app
   and "new CombinedPhoneProbe(hct, droid)" in app and "BLUETOOTH_CONNECT" in man,
   "both BT sources are wired in App.onCreate and the manifest asks for BT access")
ok("C30", "probeSafe()" in vc and inside_guarded_probe(vc) and "configuredSafe()" in vc
   and "exitPathAvailable" in vc and "startPhoneWatch()" in vc and "WATCH_MS" in vc
   and "PhonePolicy.exitWanted" in vc and "catch (Throwable" in comb
   and "phoneExitPath()" in vc and "App.valet().phoneExitPath()" in cs
   and "startPhoneWatch()" in vc and "stopPhoneWatch()" not in la,
   "valet entry/exit/replay use the fault-tolerant combined verdict; phone status shown in settings; "
   "the exit watch is owned by valet state, not the activity lifecycle")
ok("C31", "AppDrawerPolicy.pageCount" in drw and "%2$d pages" in read("app/res/values/strings.xml")
   and "homeTiles" not in vc and "homeTiles" not in read("app/src/org/vibebaking/launcher/logic/ValetPolicy.java")
   and "the drawer *is* the valet app surface" in read("specs.md"),
   "drawer page math wired into the UI; the dead valet-tiles API is gone (S27/S39b)")

# ---- S40 bottom favourite row ----
fp = read("app/src/org/vibebaking/launcher/logic/FavoritePolicy.java")
la_lay = read("app/res/layout/home_activity.xml")
fav_lay = read("app/res/layout/favorites_bar.xml")
ok("C38", 'android:id="@+id/favorites_bar"' in fav_lay and all4(fav_lay)
   and '<include layout="@layout/favorites_bar" />' in la_lay
   and '"com.microntek.bluetooth"' in fp and '"curTab"' in fp
   and "KEY_BT_DIAL_TAB" in read("app/src/org/vibebaking/launcher/logic/SettingsKeys.java")
   and "FavoritePolicy.BT_TAB_EXTRA" in la,
   "bottom row wired into the home layout; phone slot = com.microntek.bluetooth with its tab extra")
ok("C39", "allowed.contains(pkg)" in fp and "favSlots" in drw and "fav_pinned_prefix" in read("app/res/values/strings.xml")
   and "favSummary()" in cs,
   "valet hides slots outside the allowed set; pinned apps marked in the drawer; settings shows the row")

# ---- Round 5 (owner 2026-11-27): bottom-strip controls + engine gauges ----
day_colors = read("app/res/values/colors.xml")
dimens = read("app/res/values/dimens.xml")
eg = read("app/src/org/vibebaking/launcher/logic/EngineGauges.java")
ok("C41", "@+id/engine_temp" in lay and "@+id/engine_rpm" in lay
   and lay.find("@+id/btn_apps") < lay.find("@+id/fav_handle") < lay.find("@+id/btn_settings")
   and lay.find("@+id/battery") < lay.find("@+id/fav_handle")
   and 'bottom_strip_height">40dp' in dimens
   and '"com.microntek.canbus.rpm"' in la and "Context.RECEIVER_EXPORTED" in la
   and "RPM_STALE_MS" in la and "onEngineTemp(int celsius, boolean isOil)" in la
   and "import org.vibebaking.launcher.logic.EngineGauges;" in la
   and all(c in day_colors for c in ["gauge_cold", "gauge_ok", "gauge_warn", "gauge_bad"])
   and "VAG EA111 1.2 TSI 105 hp, owner 2026-11-27" in eg,
   "strip holds [btn_apps][fav_handle][btn_settings]; battery moved up to the gauge row before"
   " the strip; temp/rpm ids wired; exported rpm receiver + 10 s expiry; temp entry point;"
   " gauge palette + named EA111 thresholds present")
ok("C42", "BASE_ALPHA_DAY" in rv and "BASE_ALPHA_NIGHT" in rv
   and "paint.setAlpha(night ? BASE_ALPHA_NIGHT : BASE_ALPHA_DAY)" in code(rv)
   and 'android:minHeight="120dp"' in lay
   and all(c in night_colors for c in ["gauge_cold", "gauge_ok", "gauge_warn", "gauge_bad"])
   and not re.search(r"#(FFFF(FFFFFF)?|FFFFFF|ffffff|FFFFFFFF)\b", night_colors, re.I),
   "base tiles drawn see-through (0.55 day / 0.45 night on the NIGHT_BASE tint), radar card"
   " keeps a 120dp floor, night gauge palette dimmed with no pure white")

# ---- Round 6 (owner 2026-11-27): settings screen redesign ----
ok("C43", "Car settings" in code(cs) and "finish()" in code(cs)
   and "Display" in code(cs) and "Reverse gear" in code(cs) and "Home screen" in code(cs) and "Valet mode" in code(cs)
   and "R.drawable.card_bg" in code(cs)
   and '"Sun"' in code(cs) and '"Car lights"' in code(cs) and '"Unchanged"' in code(cs)
   and '"Mute"' in code(cs) and '"Auto"' in code(cs) and '"Waze"' in code(cs)
   and "android.widget.Switch" in cs and "SeekBar.OnSeekBarChangeListener" in code(cs)
   and "SettingsCycle" in code(cs) and "SettingsValidation.validPin(" in code(cs)
   and "SettingsValidation.timeoutOk(" in code(cs)
   and "android.text.InputType.TYPE_NUMBER_VARIATION_PASSWORD" in code(cs)
   and "EditorInfo.IME_ACTION_DONE" in code(cs) and "Typeface.MONOSPACE" in code(cs) and '"Saved"' in code(cs),
   "title+close (finish), four section cards on card_bg, pill segments with human labels,"
   " slider switches, snapping percent bars, password-number PIN field with Done-save and monospace digits")
ok("C44", ("resyncSwitch(sw, l," in code(cs) or "resyncSwitch(sw, this," in code(cs)) and "sw.setOnCheckedChangeListener(null)" in code(cs)
   and "SettingsKeys.KEY_VALET_TIMEOUT_S" in code(cs) and '" s"' in code(cs)
   and "store.getString(key, def)" in code(cs) and "GradientDrawable" in code(cs)
   and "R.color.field_bg" in code(cs),
   "valet switches resync without re-triggering; timeout editable on its existing key with a unit label;"
   " fresh store reads; styled rounded fields via GradientDrawable + field_bg")

# ---- Android 14 API surface (the tree's javac is the only real compile) ----
ok("C40", "android.media.MediaPlayerControl;" not in read("app/src/org/vibebaking/launcher/MediaCardController.java")
   and "android.os.UiModeManager" not in ta and "android.input.InputType" not in cs
   and "PersistableBundle" in vc and "android.content.pm.SuspendDialogInfo" in vc
   and "Double.doubleToRawLongBits" in read("app/src/org/vibebaking/launcher/SettingsStore.java")
   and "android.permission.SUSPEND_APPS" in read("app/AndroidManifest.xml")
   and "android.permission.SUSPEND_APPS" in read("app/privapp-permissions-vibelauncher.xml"),
   "no A14-removed APIs; suspend declares the permission PackageManagerService enforces (whitelisted)")

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
