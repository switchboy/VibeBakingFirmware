#!/usr/bin/env bash
# Rebuild a flashable raw super image from a stock firmware package's logical images.
#
#   scripts/build_rollback_super.sh <extracted-package-dir> <out-dir> [super_size]
#
# This is the rollback artifact for M3: if Android 14 does not boot, one `dd` of this file back
# onto the super partition restores the Android 10 firmware exactly as the OTA would have installed
# it. It reads the package's `dynamic_partitions_op_list` (group name, group size, partition order
# and sizes), so it reproduces whatever layout the stock package asked for instead of guessing.
#
# Needs lpmake + simg2img on the host (either the AOSP host tools or the distro's android-tools).
# boot.img / recovery.img are NOT taken from the package - the real rollback for those is the
# partition dump taken off the unit before flashing (docs/flash.md), because the installed firmware
# is not necessarily identical to the package we have offline.
set -eu

PKG=${1:?usage: build_rollback_super.sh <extracted-package-dir> <out-dir> [super_size]}
OUT=${2:?usage: build_rollback_super.sh <extracted-package-dir> <out-dir> [super_size]}
SUPER_SIZE=${3:-3263168512}
OP_LIST=${OP_LIST_FILE:-"$PKG/dynamic_partitions_op_list"}
[ -f "$OP_LIST" ] || { echo "no dynamic_partitions_op_list in $PKG (set OP_LIST_FILE to point elsewhere)"; exit 1; }

command -v lpmake >/dev/null || { echo "lpmake not found"; exit 1; }
command -v simg2img >/dev/null || { echo "simg2img not found"; exit 1; }
mkdir -p "$OUT"

# Parse the op list: add_group <group> <size>, add <partition> <group>, resize <partition> <size>.
group=""; group_size=""
order=()
declare -A g_of s_of
while read -r kw rest; do
  case "$kw" in
    add_group) set -- $rest; group=$1; group_size=$2 ;;
    add)       set -- $rest; order+=("$1"); g_of["$1"]=$2 ;;
    resize)    set -- $rest; s_of["$1"]=$2 ;;
  esac
done < "$OP_LIST"

[ -n "$group" ] && [ -n "$group_size" ] || { echo "op list has no add_group line"; exit 1; }
total=0
args=(--metadata-size 65536 --metadata-slots 2 --super-name super
      --device "super:$SUPER_SIZE" --group "$group:$group_size")
for p in "${order[@]}"; do
  size=${s_of[$p]:-}
  [ -n "$size" ] || { echo "op list gives no size for $p"; exit 1; }
  img="$PKG/$p.img"
  [ -f "$img" ] || { echo "missing logical image: $img"; exit 1; }
  real=$(stat -c %s "$img")
  if [ "$real" -gt "$size" ]; then
    echo "  ! $p.img is $real B but the op list resizes $p to $size B - refusing"; exit 1
  fi
  total=$(( total + size ))
  # lpmake's --partition DATA is name:attributes:size:group (attributes "none" here), exactly the
  # form build_super_image.py passes: --partition system:none:0:hct_dynamic_partitions.
  args+=(--partition "$p:none:$size:${g_of[$p]}" --image "$p=$img")
done
echo "group $group size $group_size ; partitions ${order[*]} ; content $total B ; super $SUPER_SIZE B"
if [ "$total" -gt "$group_size" ]; then echo "  ! content exceeds group size"; exit 1; fi

lpmake "${args[@]}" --sparse --output "$OUT/super_stock.sparse.img"
simg2img "$OUT/super_stock.sparse.img" "$OUT/super_stock.img"
rm -f "$OUT/super_stock.sparse.img"

raw=$(stat -c %s "$OUT/super_stock.img")
echo "raw super: $raw B (want $SUPER_SIZE)"
[ "$raw" -eq "$SUPER_SIZE" ] || { echo "  ! wrong size"; exit 1; }

if command -v lpdump >/dev/null; then
  echo "--- layout ---"
  lpdump "$OUT/super_stock.img" | grep -E "Name:|Group:|^    0 \.\.|Group .*max" | head -30
fi

# Stock boot.img from the package, as a convenience; the authoritative copy is the on-unit dump.
if [ -f "$PKG/boot.img" ]; then cp "$PKG/boot.img" "$OUT/boot_stock.img"; fi

( cd "$OUT" && sha256sum super_stock.img boot_stock.img 2>/dev/null | tee sha256sums-rollback.txt )
echo "staged rollback in $OUT"
