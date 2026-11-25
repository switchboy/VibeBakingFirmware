#!/bin/sh
# Build libhugoc.so (32-bit ARM) on a LineageOS 21 tree with out/ built, using the exact compile flags soong used for
# libaudioclient (expanded from out/soong/build.<product>.ninja), and link it against the device's own system/lib.
#   T=<tree> PRODUCT=lineage_rk3399 DEVICE=rk3399 sh hct/goc-shim/build.sh [outdir]
# Then: python3 hct/goc-shim/rename_syms.py <gocsdkrf210> <gocsdkrf210.hu> --exports <outdir>/exports.txt
set -e
T=${T:?tree}; PRODUCT=${PRODUCT:-lineage_rk3399}; DEVICE=${DEVICE:-rk3399}
D=$(cd "$(dirname "$0")" && pwd); O=${1:-/tmp/hu-shim}; mkdir -p "$O"; cd "$T"
N=out/soong/build.$PRODUCT.ninja
grep -m1 -F "m.libaudioclient_android_arm_armv8-a_static.cFlags1 = " "$N" > "$O/cflags.raw"
python3 - "$N" "$O" <<'PY'
import re, sys
N, O = sys.argv[1], sys.argv[2]
raw = open(O + "/cflags.raw").read().split(" = ", 1)[1].strip()
want = set(re.findall(r"\$\{(g\.[^}]+)\}", raw)); defs = {}
pat = re.compile(r"^(g\.[A-Za-z0-9_.]+) = (.*)$")
with open(N, errors="replace") as f:
    for i, line in enumerate(f):
        if i > 400000: break
        m = pat.match(line.rstrip("\n"))
        if m: defs[m.group(1)] = m.group(2)
def exp(s, d=0): return re.sub(r"\$\{([^}]+)\}", lambda m: exp(defs.get(m.group(1), ""), d + 1) if d < 10 else "", s)
open(O + "/cflags.txt", "w").write(exp(raw))
PY
B=prebuilts/clang/host/linux-x86/clang-r510928/bin; L=out/target/product/$DEVICE/system/lib
$B/clang++ $(cat "$O/cflags.txt") -Iframeworks/av/media/ndk/include -std=gnu++20 -fPIC -fno-sanitize=all \
  -Wno-unused-parameter -include binder/Binder.h -c "$D/hugoc_shim.cpp" -o "$O/hugoc_shim.o"
CB=$(ls out/soong/.intermediates/bionic/libc/crtbegin_so/android_arm_armv8-a_apex31/obj/bionic/libc/arch-common/bionic/crtbegin_so.o)
CE=$(ls out/soong/.intermediates/bionic/libc/crtend_so/android_arm_armv8-a_apex31/obj/bionic/libc/arch-common/bionic/crtend_so.o)
RT=$(ls prebuilts/clang/host/linux-x86/clang-r510928/lib/clang/*/lib/linux/libclang_rt.builtins-arm-android.a | head -1)
$B/clang++ -target armv7a-linux-androideabi34 -march=armv8-a -mfloat-abi=softfp -shared -nostdlib -fuse-ld=lld \
  -Wl,--no-undefined -Wl,-soname,libhugoc.so -Wl,--build-id=sha1 -Wl,-z,max-page-size=4096 -Wl,--hash-style=both \
  "$CB" "$O/hugoc_shim.o" -L"$L" -laudioclient -lmedia -lutils -lbinder -llog -lcutils "$L/framework-permission-aidl-cpp.so" \
  -lc++ "$L/bootstrap/libc.so" "$L/bootstrap/libm.so" "$L/bootstrap/libdl.so" "$RT" "$CE" -o "$O/libhugoc.so"
$B/llvm-nm -D --defined-only "$O/libhugoc.so" | awk '{print $3}' | grep -E 'hugoc__|__cxa_type_match' > "$O/exports.txt"
echo "built $O/libhugoc.so ($(wc -l < "$O/exports.txt") exports)"
