#!/usr/bin/env bash
# Device acceptance for the launcher (A-ids in specs.md). Owner-gated: refuses to run unless
# VBF_CONFIRM=1 (owner approval). Read-only adb dumps except two reversible writes marked below:
#   A01: pm set-home-activity (default home switch)
#   A06/A08: setprop sys.hct.debug true (CarService frame logging; restored false at the end)
# Every result belongs in docs/findings.md (parent loop), not here.
set -uo pipefail
if [ "${VBF_CONFIRM:-0}" != "1" ]; then
    echo "refusing to touch the unit: run with VBF_CONFIRM=1 after owner approval"; exit 2
fi
ADB="${ADB:-adb}"
command -v "$ADB" >/dev/null || { echo "adb not on PATH"; exit 3; }

pkg=$("$ADB" shell pm list packages -f 2>/dev/null | grep org.vibebaking.launcher || true)
echo "A00 package: ${pkg:-MISSING} (expect /system/priv-app/VibeLauncher/VibeLauncher.apk)"

# A01 - default home. WRITE (reversible: pm set-home-activity <previous>).
echo "A01 setting default home (owner-approved write):"
"$ADB" shell pm set-home-activity org.vibebaking.launcher/.LauncherActivity
"$ADB" shell input keyevent KEYCODE_HOME
home=$("$ADB" shell dumpsys activity activities 2>/dev/null | grep -m1 'org.vibebaking.launcher')
echo "A01 home activity: ${home:-NOT RESOLVED}"

# A02/A03/A05/A09 - owner eyeballs: capture, map embed, radar tiles, theme switch.
"$ADB" shell screencap -p /data/local/tmp/vibe_home.png && "$ADB" pull /data/local/tmp/vibe_home.png /tmp/vibe_home.png
echo "A02 layout screenshot pulled - owner checks cards at 1024x600"
echo "A03 map embed: $("$ADB" shell dumpsys activity activities 2>/dev/null | grep -c -iE 'TaskView|embedded') embedded-task lines (owner sees Maps/Waze inside the card)"
echo "A04 sessions: $("$ADB" shell dumpsys media_session 2>/dev/null | grep -c 'Session') session lines (owner plays Spotify/YTM/Plexamp; card shows title+art)"
echo "A05 radar: owner sees tiles; net: $("$ADB" shell ping -c 2 rainviewer.com 2>/dev/null | tail -1)"

# A06 - battery scaling against a multimeter. WRITE (diagnostic prop; restore false).
"$ADB" shell setprop sys.hct.debug true
bat=$("$ADB" shell logcat -d 2>/dev/null | grep -m3 'cmdProc >>> cmd1: 16' | grep 'cmd2: 192' || true)
echo "A06 battery frames (cmd2 192 = 0xc0): ${bat:-none seen} - compare with multimeter, record the unit in findings.md"

# A07 - valet live: owner enables master + sets PIN + taps active, then read-only checks:
sus=$("$ADB" shell dumpsys package com.spotify.music 2>/dev/null | grep -m1 suspended || true)
echo "A07 suspended state on an outside app: ${sus:-none (owner must enter valet first)}"
echo "A07 DND filter: $("$ADB" shell dumpsys notification 2>/dev/null | grep -m1 interruptionFilter)"
echo "A07 shade blocked: owner swipes from the top (must not open)"
echo "A07 settings suspended: $("$ADB" shell dumpsys package com.android.settings 2>/dev/null | grep -m1 suspended)"

# A08 - headlight/reverse events (debug prop still on; restore after).
echo "A08 MCU frames seen: $("$ADB" shell logcat -d 2>/dev/null | grep -cE 'cmdProc >>> cmd1: 16')"

# A09 - night switch: owner sets dark mode cycle, screenshot again.
"$ADB" shell screencap -p /data/local/tmp/vibe_night.png && "$ADB" pull /data/local/tmp/vibe_night.png /tmp/vibe_night.png
echo "A09 night screenshot pulled - owner checks: no pure white, animated switch"

# A10 - degrade: no crash records for the launcher.
crashes=$("$ADB" shell ls /data/system/dropbox 2>/dev/null | grep -i vibebaking || true)
echo "A10 crash dropboxes: ${crashes:-none}"

"$ADB" shell setprop sys.hct.debug false
echo "done (sys.hct.debug restored; report results to findings.md)"
