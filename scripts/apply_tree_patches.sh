#!/usr/bin/env bash
# Apply our small patches to a LineageOS checkout. Idempotent: `patch --forward` skips a hunk that
# is already applied, so running it inside package.sh on every pass is safe.
#
#   scripts/apply_tree_patches.sh /srv/.../lineage21s
set -eu
TREE=${1:?usage: apply_tree_patches.sh <lineage-tree>}
REPO=$(cd "$(dirname "$0")/.." && pwd)

for p in "$REPO"/patches/*.patch; do
  [ -e "$p" ] || continue
  if patch -p1 -d "$TREE" --forward --dry-run < "$p" >/dev/null 2>&1; then
    patch -p1 -d "$TREE" --forward < "$p" > /dev/null
    echo "applied $(basename "$p")"
  else
    # Already applied (or the file moved under us): say which, don't pretend it worked.
    if patch -p1 -d "$TREE" --forward --dry-run < "$p" 2>&1 | grep -q "previously applied"; then
      echo "already applied: $(basename "$p")"
    else
      echo "  ! $(basename "$p") does not apply cleanly - check the tree before building"
      patch -p1 -d "$TREE" --forward --dry-run < "$p" 2>&1 | head -8
      exit 1
    fi
  fi
done
