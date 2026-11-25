#!/bin/bash
# Hand build for VibeLauncher on the NAS build host (docs/build-host.md).
#
# `m VibeLauncher` regenerates soong's whole graph, which the NAS OOM-killed at 21 GB RSS with its
# services running (attempt 38). This compiles the app directly against the tree's already-built
# A14 jars: javac -> d8 -> aapt2. Nothing in the tree is written; all output is on /tmp (tmpfs).
#
#   1. stage the app on the NAS (base64, because nested ssh quoting eats operands):
#      tar -c homescreen/app | base64 -w0 | ssh nas 'base64 -d | tar -x -C /tmp/vbl-build'
#   2. run this script there:  bash /tmp/vbl-build/build.sh
#
# Pass the tree root as $1 if the checkout is elsewhere.
set -u
T=${1:-/srv/dev-disk-by-label-SSData/aospbuild/lineage21s}
I=$T/out/soong/.intermediates
B=${VBL_SCRATCH:-/tmp/vbl-build}
A=$B/app
BIN=$T/out/host/linux-x86/bin
JDK=$(ls -d "$T"/prebuilts/jdk/jdk21/linux-x86 2>/dev/null | head -1)
JAVAC=${JDK:+$JDK/bin/javac}
JAVAC=${JAVAC:-javac}

# framework.jar (turbine-jarjar) = what soong hands an app without sdk_version; the APEX module
# jars are added separately because framework-minus-apex does not contain them.
FW=$(ls "$I"/frameworks/base/framework/android_common/*/repackaged-turbine-jarjar/framework.jar 2>/dev/null | head -1)
FWRES=$(ls "$T"/out/target/product/*/system/framework/framework-res.apk 2>/dev/null | head -1)
CORE=$(ls "$I"/libcore/core-oj/android_common_apex31/turbine/core-oj.jar \
          "$I"/libcore/core-libart/android_common_apex31/turbine/core-libart.jar 2>/dev/null | tr '\n' ':')
MODS=$(find "$I/packages/modules" "$I/frameworks/base/libs/hwui" "$I/frameworks/opt" \
        -path '*/android_common/turbine-jarjar/*.jar' 2>/dev/null | grep -vE '\.impl\.jar|\.stubs' | sort | tr '\n' ':')
CP="$FW:${MODS}"
[ -f "$FW" ] || { echo "no framework.jar in $T: run a build first"; exit 1; }
[ -f "$FWRES" ] || { echo "no framework-res.apk (needed as aapt2 -I): run a build first"; exit 1; }
[ -d "$A" ] || { echo "no $A: stage homescreen/app first"; exit 1; }

echo "javac: $JAVAC ($($JAVAC -version 2>&1))"
echo "framework jar: $FW"
echo "framework resources: $FWRES"
echo "classpath jars: $(echo "$CP" | tr ':' '\n' | grep -c '\.jar')"

rm -rf "$B/gen" "$B/classes" "$B/dexout" "$B/VibeLauncher.apk"; mkdir -p "$B/gen" "$B/classes" "$B/dexout"

echo "== aapt2 compile (resource validation) =="
"$BIN/aapt2" compile --dir "$A/res" -o "$B/res.zip" 2>&1 | head -20
echo "aapt2 compile exit: ${PIPESTATUS[0]}"

echo "== aapt2 link (manifest + R.java) =="
"$BIN/aapt2" link -o "$B/app.apk" -I "$FWRES" --manifest "$A/AndroidManifest.xml" \
    --min-sdk-version 26 --target-sdk-version 34 --java "$B/gen" "$B/res.zip" 2>&1 | head -20
LINK=${PIPESTATUS[0]}
RJ=$(find "$B/gen" -name 'R.java' 2>/dev/null | head -1)
if [ "$LINK" -ne 0 ] || [ -z "$RJ" ]; then
  RJ="$B/gen/R.java"
  echo "-- link failed: generating R.java from the resource inventory so javac can still run --"
  python3 - "$A" "$RJ" <<'PY'
import os, re, sys
app, out = sys.argv[1], sys.argv[2]
ids, names = set(), {}
for root, dirs, files in os.walk(os.path.join(app, "res")):
    for f in files:
        p = os.path.join(root, f)
        if not f.endswith(".xml"):
            if "/drawable/" in p: names.setdefault("drawable", set()).add(os.path.splitext(f)[0])
            continue
        s = open(p, encoding="utf-8").read()
        ids.update(re.findall(r"@\+id/([A-Za-z0-9_]+)", s))
        ids.update(re.findall(r"@android:id/([A-Za-z0-9_]+)", s))
        rel = p.replace(app, "")
        if "/layout/" in rel: names.setdefault("layout", set()).add(os.path.splitext(f)[0])
        if "/drawable/" in rel: names.setdefault("drawable", set()).add(os.path.splitext(f)[0])
        if "/values" in rel:
            for t, n in re.findall(r'<(string|color|dimen)\s+[^>]*name="([^"]+)"', s):
                names.setdefault(t, set()).add(n)
            for n in re.findall(r'<style\s+[^>]*name="([^"]+)"', s):
                names.setdefault("style", set()).add(n.replace(".", "_"))
for root, dirs, files in os.walk(os.path.join(app, "src")):
    for f in files:
        if f.endswith(".java"):
            s = open(os.path.join(root, f), encoding="utf-8").read()
            ids.update(re.findall(r"\bR\.id\.([A-Za-z0-9_]+)", s))
base = 0x7F000000
lines = ["package org.vibebaking.launcher;", "public final class R {"]
for kind in sorted(names) + ["id"]:
    vals = sorted(ids) if kind == "id" else sorted(names[kind])
    if not vals: continue
    lines.append(f"  public static final class {kind} {{")
    for v in vals:
        lines.append(f"    public static final int {v} = 0x{base:X};")
        base += 1
    lines.append("  }")
lines.append("}")
open(out, "w").write("\n".join(lines) + "\n")
print("generated", out)
PY
fi
echo "R.java: $RJ ($(grep -c 'public static final int' "$RJ") resource constants)"

echo "== javac (app sources against the A14 framework) =="
"$JAVAC" -nowarn -source 8 -target 8 -bootclasspath "$CORE" -classpath "$CP" \
    -d "$B/classes" $(find "$A/src" -name '*.java') "$RJ" 2>&1 | head -60
JRC=${PIPESTATUS[0]}
echo "javac exit: $JRC"
# A failed compile must not produce an APK: on Nov 26 a javac error still yielded a dex-less APK that installed and
# crashed the home screen (ClassNotFoundException: org.vibebaking.launcher.App).
[ "$JRC" -eq 0 ] || { echo "BUILD FAILED: javac"; exit 1; }
echo "classes produced: $(find "$B/classes" -name '*.class' | wc -l)"

echo "== d8 (dex compile) =="
if [ -n "$JDK" ]; then export PATH="$JDK/bin:$PATH"; fi
CPARGS=""; for j in $(echo "$CP" | tr ':' ' '); do CPARGS="$CPARGS --classpath $j"; done
LIBARGS=""; for j in $FW $(echo "$CORE" | tr ':' ' '); do [ -n "$j" ] && LIBARGS="$LIBARGS --lib $j"; done
"$BIN/d8" --min-api 28 $LIBARGS $CPARGS --output "$B/dexout" \
    $(find "$B/classes" -name '*.class') 2>&1 | head -20
DRC=${PIPESTATUS[0]}
echo "d8 exit: $DRC"; ls -l "$B/dexout" 2>/dev/null | tail -3
[ "$DRC" -eq 0 ] && [ -s "$B/dexout/classes.dex" ] || { echo "BUILD FAILED: d8"; exit 1; }

if [ -f "$B/dexout/classes.dex" ]; then
  cp "$B/app.apk" "$B/VibeLauncher.apk" 2>/dev/null && (cd "$B/dexout" && zip -q "$B/VibeLauncher.apk" classes.dex)
  echo "== aapt2 badging (what the installed app declares) =="
  "$BIN/aapt2" dump badging "$B/VibeLauncher.apk" 2>&1 | grep -E "package:|application-label|launchable|category|sdkVersion|sharedUserId" | head -20
  sha256sum "$B/VibeLauncher.apk"
fi
df -h /tmp | tail -1
