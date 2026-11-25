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


def all4(src):
    """The four slot/icon/label/glyph ids of the favourites bar."""
    return all(f'@+id/fav_slot{i}' in src and f'@+id/fav_icon{i}' in src
               and f'@+id/fav_glyph{i}' in src and f'@+id/fav_label{i}' in src for i in range(4))


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

# SA25 - trusted phone: HCT BT broadcasts + Settings.System pair list, both guarded.
hct = read("app/src/org/vibebaking/launcher/HctBluetoothProbe.java")
ok("SA25", '"net.easyconn.bt.connected"' in hct and '"net.easyconn.bt.notconnected"' in hct
   and '"net.easyconn.bt.opened"' in hct and '"com.microntek.bt.report"' in hct
   and '"MTC.BT.deviceList"' in hct and '"MTC.BT.matchList"' in hct,
   "probe hooks the HCT/GOC signals, not only Android's stack")
ok("SA25b", "catch (Throwable junkBroadcast)" in hct and "catch (Throwable t)" in hct[hct.find("String storedDeviceList"):],
   "a junk broadcast or an unreadable settings value must not crash the launcher")
ok("SA25c", hct.find("Context.RECEIVER_EXPORTED") < hct.find("catch (Throwable t2)")
   and "registered = false" in hct, "a receiver that cannot be registered degrades to UNKNOWN")

# SA26 - Android's own stack as the second source: denied permission / dead proxy -> UNKNOWN only.
btandroid = read("app/src/org/vibebaking/launcher/BluetoothPhoneProbe.java")
ok("SA26", "catch (Throwable t)" in btandroid and "PhonePolicy.decideAndroid(false, 0, 0, true)" in btandroid
   and "getProfileProxy" in btandroid and "closeProfileProxy" in btandroid,
   "Android stack failures must yield UNKNOWN, not an exception")

# SA27 - BOTH sources consulted, and one being unavailable must never crash the app (spec S25b).
comb = read("app/src/org/vibebaking/launcher/logic/CombinedPhoneProbe.java")
ok("SA27", "catch (Throwable t) { return PhonePresence.UNKNOWN; }" in comb
   and "catch (Throwable t) { return false; }" in comb and "catch (Throwable ignore)" in comb,
   "a throwing source contributes UNKNOWN only; configured/release are guarded too")
ok("SA27b", "new HctBluetoothProbe(this)" in app and "new BluetoothPhoneProbe(this)" in app
   and app.find("try { hct = new HctBluetoothProbe(this); }") < app.find("btProbe = new CombinedPhoneProbe(hct, droid)")
   and "CombinedPhoneProbe.Inert" in app,
   "probe construction is guarded in App.onCreate: a dead BT service cannot crash the app at start")
ok("SA27c", "PhonePolicy.combine" in comb and "if (hct != null && hct != PhonePresence.UNKNOWN) return hct;"
   in read("app/src/org/vibebaking/launcher/logic/PhonePolicy.java"),
   "HCT verdict wins when informative; Android is the fallback")

# SA28 - valet uses the crash-safe verdict everywhere, and the exit hook polls it.
ok("SA28", "probeSafe()" in valet and valet.count("probe.probe()") == 1
   and "PhonePresence p = probeSafe()" in valet
   and valet.find("PhonePresence p = probe.probe();") > valet.find("PhonePresence probeSafe()")
   and "configuredSafe()" in valet and "PhonePolicy.exitPathAvailable" in valet
   and "startPhoneWatch()" in valet and "stopPhoneWatch()" in valet,
   "the only raw probe call is inside probeSafe(); timers and the exit watch use the guarded verdict")
ok("SA28b", "App.valet().probeSafe()" in settings and "App.valet().configuredSafe()" in settings
   and "phoneStatus()" in settings, "settings phone status reads the guarded verdict")

# SA29 - drawer status shows the page math (12 icons per screen), and the old valet-tiles API is gone.
ok("SA29", "AppDrawerPolicy.pageCount(visible.size())" in drw
   and "%1$d apps · %2$d pages" in strings and "%1$d allowed apps (valet mode) · %2$d pages" in strings,
   "page math must be wired into the UI, not only unit-tested")
ok("SA29b", "homeTiles" not in drw and "homeTiles" not in valet
   and "homeTiles" not in read("app/src/org/vibebaking/launcher/logic/ValetPolicy.java"),
   "the valet-tiles idea is dead code: the drawer is the valet app surface (S27/S39b)")

# SA30 - the phone-exit watch must survive the home screen being paused (owner in drawer/settings).
ok("SA30", "stopPhoneWatch()" not in act and "startPhoneWatch()" not in act,
   "watch lifecycle belongs to ValetController (enter/exit), not the activity lifecycle (S26)")

# SA35 - bottom favourite row exists, four aligned slots, placeholder glyph/icon fallbacks.
favbar = read("app/res/layout/favorites_bar.xml")
ok("SA35", 'android:id="@+id/favorites_bar"' in favbar and all4(favbar)
   and '<include layout="@layout/favorites_bar" />' in read("app/res/layout/home_activity.xml")
   and "fav_bar_height" in read("app/res/values/dimens.xml") and "ic_app_placeholder" in favbar,
   "four slots in the bar, included at the bottom of the home layout")
ok("SA36", "void launchFavorite(String pkg, int slot)" in act
   and "catch (Throwable t)" in act[act.find("void launchFavorite"):]
   and "FavoritePolicy.BT_TAB_EXTRA" in act and "isEmpty()) { startActivity(new Intent(this, AppDrawerActivity.class))" in act,
   "phone slot opens the BT dialler tab; an empty slot opens the drawer; launch failures are caught")
ok("SA36b", "store.setFavSlots(FavoritePolicy.clear(store.favSlots(), slot))" in act,
   "a favourite that was uninstalled drops its slot instead of doing nothing")
ok("SA37", "catch (Throwable t)" in act[act.find("void refreshFavorites"):act.find("void launchFavorite")]
   and "favIcons[i].setImageResource(R.drawable.ic_app_placeholder)" in act,
   "unreadable icon/label must fall back to the placeholder, not crash the bar")
ok("SA37b", "if (valet.isActive() && store.valetEnabled()) return;" in act[act.find("void clearFavorite"):]
   and "if (!valet)" in drw and "pinToFavoriteRow" in drw,
   "pinning/un-pinning is refused while valet is active (S40c)")

fails = [r for r in results if not r[1]]
print(f"{len(results)} scenario checks, {len(fails)} failed")
sys.exit(1 if fails else 0)
