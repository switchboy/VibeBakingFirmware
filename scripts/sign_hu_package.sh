#!/usr/bin/env bash
# Put SignApk's PKCS#7 signature into the payload zip's EOCD comment - the format the PX6 unit's
# recovery verifies (**D25**, docs/decisions.md). Zip in, zip out, nothing else.
#
#   scripts/sign_hu_package.sh <in-zip> <out-zip> [cert.pem] [pk8]
#
# Run it on the build host: `signapk.jar` comes from the tree's host output and java from the tree's
# own prebuilt JDK (the NAS has no system java). Default cert/key are the tree's testkey; pass a
# different cert/pk8 as arguments if you ever get the key the recovery actually trusts (HCT's own
# cert cf2ab3818595c4ed..., which signs both stock packages - see docs/decisions.md).
set -eu
IN=${1:?usage: sign_hu_package.sh <in-zip> <out-zip> [cert.pem] [pk8]}
OUT=${2:?usage: sign_hu_package.sh <in-zip> <out-zip> [cert.pem] [pk8]}
REPO=$(cd "$(dirname "$0")/.." && pwd)
TREE=${TREE:-$REPO/../lineage21s}

JAR=$TREE/out/host/linux-x86/framework/signapk.jar
JAVA=${JAVA:-$TREE/prebuilts/jdk/jdk17/linux-x86/bin/java}
CERT=${3:-$TREE/build/make/target/product/security/testkey.x509.pem}
KEY=${4:-$TREE/build/make/target/product/security/testkey.pk8}

# SignApk signs through conscrypt, whose JNI library lives in the tree's host lib64 - java.library.path
# has to point there or the JVM throws "no conscrypt in java.library.path" (Nov 8 first run).
JAVA_OPTS=${JAVA_OPTS:-"-Djava.library.path=$TREE/out/host/linux-x86/lib64"}

for f in "$IN" "$JAR" "$JAVA" "$CERT" "$KEY"; do
  [ -s "$f" ] || { echo "missing: $f"; exit 1; }
done

# `-w` = whole-file mode: SignApk signs the zip as a whole and stores "signed by SignApk\0" + the DER
# PKCS#7 SignedData in the EOCD comment, which is the layout the stock packages carry and the recovery
# checks. Without `-w` it does APK v2 signing instead and the comment stays empty (Nov 8 test: 8,473 B
# output, comment 0). Recompresses nothing.
"$JAVA" $JAVA_OPTS -jar "$JAR" -w "$CERT" "$KEY" "$IN" "$OUT"

echo "  $IN  $(stat -c %s "$IN") B  (comment 0)"
echo "  $OUT $(stat -c %s "$OUT") B"
python3 "$REPO/tools/zip_comment_sig.py" "$OUT"
