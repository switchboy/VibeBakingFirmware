#!/usr/bin/env bash
# write_card_chunked.sh - write a whole-partition image to the SD-boot card in verified chunks,
# staging each chunk in the unit's RAM, with retries (D104).
#
# Why chunked (measured Nov 23, twice): the transfer chain workstation -> ethernet -> adb -> FAT32 on
# the second card -> dd -> boot card corrupted data in two different places. First the boot card's own
# p14 came back with three single-bit errors that proved to be frozen cells (D102). Then a 3,263,168,512 B
# push onto the second card itself hashed wrong on arrival. A single 3 GB write with one digest at the
# end cannot tell those apart and cannot repair either. This writes CHUNK_MIB at a time through
# /tmp (tmpfs, RAM - no stuck cells), verifies the chunk in RAM before it is written and verifies the
# partition region after it is written, and retries each step. Chunks that cannot be made to match are
# listed at the end with their byte ranges, which is exactly the input tools/repack_super_place.py
# needs to design around frozen cells.
#
# Safety: the destination is resolved on the device by WHOLE-DEVICE block count plus sysfs type SD and
# by the partition's own block count (D76). The eMMC (61,341,696 blocks) and the second card
# (30,533,632 blocks) can never match, and the script refuses to run if more than one device matches.
# Nothing outside the named partition is touched; the eMMC's heads are printed before and after.
#
# Usage: scripts/write_card_chunked.sh IMAGE PARTITION_INDEX EXPECTED_PARTITION_BLOCKS
#   e.g. scripts/write_card_chunked.sh .../card-p14-a14-placed.img 14 3186688
# Env: ANDROID_SERIAL, CHUNK_MIB (default 128), RETRY (default 3), DRY_RUN=1 to stop before writing,
#      ONLY_CHUNKS="i j k" to write and verify only those chunk indexes (0-based CHUNK_MIB chunks from
#      the start of the partition); unset means every chunk, exactly as before.
set -u

IMG=${1:?usage: write_card_chunked.sh IMAGE PARTITION_INDEX EXPECTED_BLOCKS}
IDX=${2:?partition index}
WANT_BLOCKS=${3:?expected partition blocks}
CHUNK_MIB=${CHUNK_MIB:-128}
RETRY=${RETRY:-3}
ONLY_CHUNKS=${ONLY_CHUNKS:-}
BOOT_CARD_BLOCKS=7761920
EVID_CARD_BLOCKS=30533632
EMMC_BLOCKS=61341696
STAGE=/tmp/hu-chunk.bin

die() { printf 'ABORT: %s\n' "$*" >&2; exit 1; }
sh_() { adb shell "$@" 2>/dev/null | tr -d '\r'; }

[ -f "$IMG" ] || die "no image $IMG"
ISZ=$(stat -c %s "$IMG")
[ $((ISZ % 1048576)) -eq 0 ] || die "image $ISZ B is not a whole number of MiB"
[ "$ISZ" = "$((WANT_BLOCKS * 1024))" ] || die "image $ISZ B != partition $((WANT_BLOCKS * 1024)) B"
[ "$CHUNK_MIB" -ge 1 ] || die "CHUNK_MIB=$CHUNK_MIB is not a positive number of MiB"
CHUNKS=$(( (ISZ / 1048576 + CHUNK_MIB - 1) / CHUNK_MIB ))
[ "$CHUNKS" -ge 1 ] || die "image $ISZ B holds no ${CHUNK_MIB} MiB chunks"

# --- which chunk indexes to write ---------------------------------------------------------
# Done before adb is touched, so a bad ONLY_CHUNKS aborts without ever reaching the unit.
# Unset => SEL is every index 0..CHUNKS-1, which is exactly the old loop.
declare -a SEL
n_sel=0
if [ -n "$ONLY_CHUNKS" ]; then
  listed=""
  for tok in $ONLY_CHUNKS; do
    case "$tok" in
      ''|*[!0-9]*) die "ONLY_CHUNKS: '$tok' is not a chunk index (only digits allowed)" ;;
    esac
    [ "$tok" -lt "$CHUNKS" ] || die "ONLY_CHUNKS: index $tok is out of range: $ISZ B is $CHUNKS chunks (0..$((CHUNKS - 1))) of ${CHUNK_MIB} MiB"
    case " $listed " in *" $tok "*) continue ;; esac
    listed="$listed $tok"
    SEL+=("$tok")
    n_sel=$((n_sel + 1))
  done
  [ "$n_sel" -gt 0 ] || die "ONLY_CHUNKS is set but names no chunk index"
else
  i=0
  while [ "$i" -lt "$CHUNKS" ]; do SEL+=("$i"); i=$((i + 1)); done
fi

adb root >/dev/null 2>&1
[ "$(sh_ 'id -u')" = 0 ] || die "adb is not root on the unit"

# --- resolve the card, on the device, by size and type -------------------------------------------
dev=$(sh_ 'for d in /sys/block/mmcblk*; do n=${d##*/};
  b=$(grep -E "[ ]$n\$" /proc/partitions | while read -r _ _ bb _; do echo "$bb"; done);
  t=$(cat "$d/device/type" 2>/dev/null);
  [ "$b" = '"$BOOT_CARD_BLOCKS"' ] && [ "$t" = SD ] && echo "$n"; done')
[ -n "$dev" ] || die "no SD device of $BOOT_CARD_BLOCKS blocks on the unit"
[ "$(printf '%s\n' "$dev" | wc -l)" = 1 ] || die "more than one device matches the boot card: $dev"
case "$dev" in
  *" "*) die "ambiguous device name '$dev'" ;;
esac
pb=$(sh_ "grep -E '[ ]${dev}p${IDX}\$' /proc/partitions | while read -r _ _ bb _; do echo \$bb; done")
[ "$pb" = "$WANT_BLOCKS" ] || die "/dev/block/${dev}p${IDX} is $pb blocks, expected $WANT_BLOCKS"
[ "$pb" = "$EVID_CARD_BLOCKS" ] && die "refusing: that is the second card"
[ "$pb" = "$EMMC_BLOCKS" ] && die "refusing: that is the eMMC"
NODE=/dev/block/${dev}p${IDX}
echo "destination $NODE ($pb blocks of 1024 B) on card $dev ($BOOT_CARD_BLOCKS blocks, type SD)"

emmc_heads() {
  sh_ 'e=; for d in /sys/block/mmcblk*; do n=${d##*/};
    b=$(grep -E "[ ]$n\$" /proc/partitions | while read -r _ _ bb _; do echo "$bb"; done);
    [ "$b" = '"$EMMC_BLOCKS"' ] && e=$n; done
    for p in 3 7 8; do printf "  eMMC %sp%s head4k " "$e" "$p";
      /system/bin/dd if=/dev/block/${e}p${p} bs=4096 count=1 2>/dev/null | /system/bin/sha256sum | cut -d" " -f1; done'
}
echo "== eMMC heads before =="; emmc_heads

echo "image $ISZ B -> $CHUNKS chunks of ${CHUNK_MIB} MiB, $RETRY retries per step"
if [ -n "$ONLY_CHUNKS" ]; then
  echo "ONLY_CHUNKS: writing and verifying only chunk(s):${SEL[*]}"
fi
[ "${DRY_RUN:-0}" = 1 ] && { echo "DRY_RUN: stopping before any write"; exit 0; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
bad=""
for i in "${SEL[@]}"; do
  off=$(( i * CHUNK_MIB ))                       # MiB from the start of the partition
  left=$(( ISZ / 1048576 - off ))
  n=$(( left < CHUNK_MIB ? left : CHUNK_MIB ))
  dd if="$IMG" of="$tmp/c.bin" bs=1048576 skip="$off" count="$n" status=none
  want=$(sha256sum "$tmp/c.bin" | cut -d' ' -f1)

  staged=""; t=0
  while [ "$t" -lt "$RETRY" ]; do
    adb push "$tmp/c.bin" "$STAGE" >/dev/null 2>&1
    staged=$(sh_ "/system/bin/sha256sum $STAGE | cut -d' ' -f1")
    [ "$staged" = "$want" ] && break
    t=$((t+1)); echo "  chunk $i: staged digest wrong (try $t), re-pushing"
  done
  if [ "$staged" != "$want" ]; then
    echo "  chunk $i [$((off))..$((off+n)) MiB]: COULD NOT STAGE - skipped, nothing written"
    bad="$bad $i:stage"; continue
  fi

  got=""; t=0
  while [ "$t" -lt "$RETRY" ]; do
    sh_ "/system/bin/dd if=$STAGE of=$NODE bs=1048576 seek=$off count=$n conv=fsync,notrunc >/dev/null 2>&1; sync; echo 3 > /proc/sys/vm/drop_caches"
    got=$(sh_ "/system/bin/dd if=$NODE bs=1048576 skip=$off count=$n 2>/dev/null | /system/bin/sha256sum | cut -d' ' -f1")
    [ "$got" = "$want" ] && break
    t=$((t+1)); echo "  chunk $i: partition digest wrong (try $t), rewriting"
  done
  if [ "$got" = "$want" ]; then
    printf '  chunk %2d/%d  %5d..%5d MiB  OK\n' "$((i+1))" "$CHUNKS" "$off" "$((off+n))"
  else
    printf '  chunk %2d/%d  %5d..%5d MiB  UNFIXABLE (card returns %s)\n' "$((i+1))" "$CHUNKS" "$off" "$((off+n))" "${got:0:12}"
    bad="$bad $i:medium"
  fi
done
sh_ "rm -f $STAGE"

echo "== whole-partition readback =="
if [ -n "$ONLY_CHUNKS" ]; then
  echo "ONLY_CHUNKS set: only the chunks listed above were written. If the partition held the image's"
  echo "predecessor and ONLY_CHUNKS lists every chunk that differs, the digests below must be EQUAL;"
  echo "a difference means the partition was not in the expected state or a chunk list was incomplete"
fi
sh_ "echo 3 > /proc/sys/vm/drop_caches; /system/bin/sha256sum $NODE"
echo "image digest: $(sha256sum "$IMG" | cut -d' ' -f1)"
echo "== eMMC heads after =="; emmc_heads
if [ -n "$bad" ]; then
  echo "chunks that did not verify:$bad"
  echo "(a 'medium' chunk means frozen cells - narrow it per MiB and feed the byte offsets to"
  echo " tools/repack_super_place.py so the payload is placed around them)"
  exit 2
fi
if [ -n "$ONLY_CHUNKS" ]; then
  echo "the selected chunks verified; the other chunks were not written"
else
  echo "all chunks verified"
fi
