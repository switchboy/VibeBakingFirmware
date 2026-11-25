#!/bin/sh
# Build HuSerialPortsOverlay.apk: a static framework-res overlay that lists the head unit's serial ports in
# config_serialPorts, so android.hardware.SerialManager.openSerialPort() accepts them (Android 14 ships an empty
# list; HCT's CarService, CanBus, TPMS and Bluetooth manager all open their ports through it).
# Usage: T=<LineageOS 21 tree with out/ built> sh hct/rro-serialports/build.sh [outdir]
# Signed with the tree's platform key: on a test-keys build that is the key framework-res is signed with.
set -e
T=${T:?set T to the LineageOS tree}; D=$(cd "$(dirname "$0")" && pwd); O=${1:-$D/out}
mkdir -p "$O"
"$T/out/host/linux-x86/bin/aapt2" compile --dir "$D/res" -o "$O/compiled.zip"
"$T/out/host/linux-x86/bin/aapt2" link -o "$O/unsigned.apk" --manifest "$D/AndroidManifest.xml" \
  -I "$T/out/target/common/obj/APPS/framework-res_intermediates/package-export.apk" \
  --min-sdk-version 34 --target-sdk-version 34 --no-resource-deduping "$O/compiled.zip"
"$T/prebuilts/jdk/jdk17/linux-x86/bin/java" -jar "$T/out/host/linux-x86/framework/apksigner.jar" sign \
  --key "$T/build/make/target/product/security/platform.pk8" \
  --cert "$T/build/make/target/product/security/platform.x509.pem" \
  --out "$O/HuSerialPortsOverlay.apk" "$O/unsigned.apk"
echo "built $O/HuSerialPortsOverlay.apk -> install as /product/overlay/HuSerialPortsOverlay.apk (0644 root, system_file)"
