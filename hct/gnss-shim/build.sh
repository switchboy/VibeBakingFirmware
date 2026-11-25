#!/bin/sh
# Build libhugnss.so (arm64) on a LineageOS 21 tree with out/ built (crt objects, bootstrap libc, liblog).
#   T=<tree> DEVICE=rk3399 sh hct/gnss-shim/build.sh <hugnss_shim.c> [outdir]
# Install: /vendor/lib64/libhugnss.so (vendor_file) and `setenv LD_PRELOAD /vendor/lib64/libhugnss.so` in the
# vendor.gnss_service block of /vendor/etc/init/android.hardware.gnss@1.0-service.rc.
set -e
T=${T:?tree}; DEVICE=${DEVICE:-rk3399}; SRC=${1:?source}; O=${2:-/tmp/hu-gnss}; mkdir -p "$O"; cd "$T"
B=prebuilts/clang/host/linux-x86/clang-r510928/bin; L=out/target/product/$DEVICE/system/lib64
INC=$(for d in hardware/libhardware/include hardware/libhardware/include_all; do [ -d $d ] && printf -- '-I%s ' $d; done)
CB=$(ls out/soong/.intermediates/bionic/libc/crtbegin_so/android_arm64_armv8-a*/obj/bionic/libc/arch-common/bionic/crtbegin_so.o | head -1)
CE=$(ls out/soong/.intermediates/bionic/libc/crtend_so/android_arm64_armv8-a*/obj/bionic/libc/arch-common/bionic/crtend_so.o | head -1)
RT=$(ls prebuilts/clang/host/linux-x86/clang-r510928/lib/clang/*/lib/linux/libclang_rt.builtins-aarch64-android.a | head -1)
SYS="-isystem bionic/libc/include -isystem bionic/libc/kernel/uapi -isystem bionic/libc/kernel/uapi/asm-arm64 \
 -isystem bionic/libc/kernel/android/uapi -isystem system/logging/liblog/include -isystem system/core/libcutils/include -isystem system/core/libsystem/include"
$B/clang -target aarch64-linux-android34 -nostdinc -isystem "$($B/clang -print-resource-dir)/include" \
  $SYS $INC -O2 -fPIC -fstack-protector-strong -Wall -Wextra -Wno-unused-parameter -c "$SRC" -o "$O/hugnss_shim.o"
$B/clang -target aarch64-linux-android34 -shared -nostdlib -fuse-ld=lld -Wl,--no-undefined -Wl,-soname,libhugnss.so \
  -Wl,--build-id=sha1 -Wl,-z,max-page-size=4096 -Wl,--hash-style=both \
  "$CB" "$O/hugnss_shim.o" -L"$L" -llog "$L/bootstrap/libc.so" "$L/bootstrap/libdl.so" "$RT" "$CE" -o "$O/libhugnss.so"
$B/llvm-nm -D --defined-only "$O/libhugnss.so" | grep -w hw_get_module
echo "built $O/libhugnss.so"
