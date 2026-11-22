#!/usr/bin/env bash
# build_hu_wrap.sh - compile tools/hu_wrap.c for the boot ramdisk and for HU_TEST runs.
#
# aarch64: zig cc -target aarch64-linux-musl -static -Os, stripped, no build-id, SOURCE_DATE_EPOCH set
#          so the digest is reproducible. Raw syscalls only, so no libc runtime deps beyond musl's
#          syscall path; verified with file/readelf (no NEEDED, no INTERP).
# x86_64: the same source, for the workstation HU_TEST scenarios. qemu-aarch64 runs the aarch64
#          binary; the unit runs it natively from /data/local/tmp.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-/run/media/Daan/Opslagmonster/a14-work/hu-wrap}
SRC="$REPO/tools/hu_wrap.c"
EPOCH=${SOURCE_DATE_EPOCH:-1760000000}
mkdir -p "$OUT"

{
  echo "=== hu_wrap build, $(date -u +%FT%TZ) ==="
  echo "source: $SRC  sha256 $(sha256sum "$SRC" | cut -d' ' -f1)"
  echo "zig: $(zig version)"
  echo "qemu-aarch64: $(qemu-aarch64 --version | head -1)"
  echo "llvm-strip: $(llvm-strip --version | head -1)"
  echo "SOURCE_DATE_EPOCH=$EPOCH"
  echo "flags aarch64: zig cc -target aarch64-linux-musl -static -Os -Wl,--build-id=none (strip applied separately)"
  echo "flags x86_64 : zig cc -target x86_64-linux-musl -static -Os -Wl,--build-id=none (strip applied separately)"
} > "$OUT/build.log"

cd "$OUT"
SOURCE_DATE_EPOCH="$EPOCH" zig cc -target aarch64-linux-musl -static -Os -Wl,--build-id=none \
  -o hu-wrap-aarch64.unstripped "$SRC" 2>>"$OUT/build.log"
llvm-strip hu-wrap-aarch64.unstripped -o hu-wrap-aarch64
SOURCE_DATE_EPOCH="$EPOCH" zig cc -target x86_64-linux-musl -static -Os -Wl,--build-id=none \
  -o hu-wrap-x86_64.unstripped "$SRC" 2>>"$OUT/build.log"
llvm-strip hu-wrap-x86_64.unstripped -o hu-wrap-x86_64

for b in hu-wrap-aarch64 hu-wrap-x86_64; do
  echo "--- $b" >> "$OUT/build.log"
  file "$b" >> "$OUT/build.log"
  echo "size $(stat -c '%s' "$b")  sha256 $(sha256sum "$b" | cut -d' ' -f1)" >> "$OUT/build.log"
  if readelf -d "$b" | grep -qa NEEDED; then echo "FAIL: $b has NEEDED entries" >> "$OUT/build.log"; fi
  if readelf -l "$b" | grep -qa INTERP; then echo "FAIL: $b has an INTERP segment" >> "$OUT/build.log"; fi
  echo "dynamic section lines: $(readelf -d "$b" | grep -ca . )" >> "$OUT/build.log"
done
cat "$OUT/build.log"
grep -q FAIL "$OUT/build.log" && { echo "build gate failed"; exit 1; } || echo "build gate ok (no NEEDED, no INTERP)"
