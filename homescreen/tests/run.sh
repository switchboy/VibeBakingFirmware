#!/usr/bin/env bash
# Run both test layers for the launcher: pure-logic unit tests (javac) + static conformance.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== unit tests (pure logic, javac) =="
rm -rf tests/out
javac -d tests/out app/src/org/vibebaking/launcher/logic/*.java tests/unit/*.java
java -cp tests/out org.vibebaking.launcher.unit.Main "$(pwd)"

echo "== conformance (spec C-ids) =="
python3 tests/conformance.py

echo "ALL TESTS PASSED"
