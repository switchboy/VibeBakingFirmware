#!/usr/bin/env bash
# Apply our patches to a LineageOS checkout. Idempotent, and safe to run on every packaging pass.
#
#   scripts/apply_tree_patches.sh /srv/.../lineage21s
#
# Patch paths are written relative to the tree root (a/build/make/...), which is what `git apply
# -p1` expects. We use git apply rather than patch(1): GNU patch 2.8 rejects our hunks even though
# the context lines match the file byte-for-byte, while `git apply --check` accepts them.
set -eu
TREE=$(cd "${1:?usage: apply_tree_patches.sh <lineage-tree>}" && pwd)
REPO=$(cd "$(dirname "$0")/.." && pwd)

for p in "$REPO"/patches/*.patch; do
  [ -e "$p" ] || continue
  name=$(basename "$p")
  if git -C "$TREE" apply -p1 --check "$p" 2>/dev/null; then
    git -C "$TREE" apply -p1 "$p"
    echo "applied $name"
  elif git -C "$TREE" apply -p1 -R --check "$p" 2>/dev/null; then
    echo "already applied: $name"
  else
    echo "  ! $name does not apply cleanly (line drift in the tree) - check before building"
    git -C "$TREE" apply -p1 --check -v "$p" 2>&1 | tail -6
    exit 1
  fi
done
