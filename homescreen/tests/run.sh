#!/usr/bin/env bash
# All workstation test layers for the launcher. Never touches the device.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== unit tests (pure logic, javac) =="
rm -rf tests/out
javac -d tests/out app/src/org/vibebaking/launcher/logic/*.java \
    app/src/org/vibebaking/launcher/HttpRadarFetcher.java app/src/org/vibebaking/launcher/HttpWeatherFetcher.java \
    tests/unit/*.java
java -cp tests/out org.vibebaking.launcher.unit.Main "$(pwd)"

echo "== smoke tests (30+ degradation scenarios) =="
java -cp tests/out org.vibebaking.launcher.unit.Smoke

echo "== static smoke (Android-side degrade paths) =="
python3 tests/smoke_static.py

echo "== conformance (spec C-ids) =="
python3 tests/conformance.py

echo "ALL TESTS PASSED"
