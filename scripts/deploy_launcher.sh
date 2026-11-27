#!/bin/bash
# Build VibeLauncher on the build host (hand build, homescreen/build-on-build-host.sh), sign with the platform test key,
# install on the unit and make it the home app. Stops at the first failure; never installs an APK without classes.dex.
set -u
REPO=/run/media/Daan/Opslagmonster/VibeBakingFirmware/homescreen
OUT=/run/media/Daan/Opslagmonster/a14-work/staging/VibeLauncher-signed.apk
export ANDROID_SERIAL=${ANDROID_SERIAL:-${HU_IP:-192.168.1.127}:5555}
cd "$REPO" || exit 1
bash tests/run.sh > /run/media/Daan/Opslagmonster/VibeBakingFirmware/log/launcher-tests.txt 2>&1; tail -1 /run/media/Daan/Opslagmonster/VibeBakingFirmware/log/launcher-tests.txt
grep -q "ALL TESTS PASSED" /run/media/Daan/Opslagmonster/VibeBakingFirmware/log/launcher-tests.txt || { echo "DEPLOY STOPPED: tests"; exit 1; }
cp build-on-build-host.sh app/.build.sh
tar -C . -czf /run/media/Daan/Opslagmonster/a14-work/scratch/vbl.tgz app && rm -f app/.build.sh
B=$(base64 -w0 /run/media/Daan/Opslagmonster/a14-work/scratch/vbl.tgz)
timeout 1500 $HOME/.config/vbf/omv.sh "cd /tmp/vbl-build && rm -rf app signed.apk al.apk && echo $B | base64 -d | tar xzf - && mv app/.build.sh build.sh && bash build.sh > log.txt 2>&1; RC=\$?; grep -E 'exit:|BUILD FAILED' log.txt; [ \$RC -eq 0 ] || { grep -A3 'error:' log.txt | head -30; echo REMOTE_BUILD_FAILED; exit 1; }
T=/srv/dev-disk-by-label-SSData/aospbuild/lineage21s; H=\$T/out/host/linux-x86; K=\$T/build/make/target/product/security
export PATH=\$T/prebuilts/jdk/jdk21/linux-x86/bin:\$T/prebuilts/jdk/jdk17/linux-x86/bin:\$PATH
\$H/bin/zipalign -f -p 4 VibeLauncher.apk al.apk && \$H/bin/apksigner sign --key \$K/platform.pk8 --cert \$K/platform.x509.pem --out signed.apk al.apk && echo SIGNED" 2>&1 | grep -v logParams | sed 's|/tmp/vbl-build/app/src/org/vibebaking/launcher/||' > /run/media/Daan/Opslagmonster/VibeBakingFirmware/log/launcher-build.txt
cat /run/media/Daan/Opslagmonster/VibeBakingFirmware/log/launcher-build.txt
grep -q "^SIGNED" /run/media/Daan/Opslagmonster/VibeBakingFirmware/log/launcher-build.txt || { echo "DEPLOY STOPPED: build"; exit 1; }
rm -f "$OUT"
timeout 300 $HOME/.config/vbf/omv.sh 'base64 -w0 /tmp/vbl-build/signed.apk' 2>/dev/null | grep -v logParams | tail -1 | base64 -d > "$OUT"
unzip -l "$OUT" 2>/dev/null | grep -q " classes.dex$" || { echo "DEPLOY STOPPED: no classes.dex in the APK"; exit 1; }
echo "apk $(sha256sum "$OUT" | cut -c1-16) ($(stat -c %s "$OUT") B)"
adb install -r "$OUT" 2>&1 | tail -1 | grep -q Success || { echo "DEPLOY STOPPED: install"; exit 1; }
adb shell 'sync; pm grant org.vibebaking.launcher android.permission.ACCESS_FINE_LOCATION; pm grant org.vibebaking.launcher android.permission.ACCESS_COARSE_LOCATION; cmd package set-home-activity org.vibebaking.launcher/.LauncherActivity >/dev/null; input keyevent KEYCODE_HOME' 2>&1 | tr -d '\r' | grep -v "^$"
echo "DEPLOYED"
