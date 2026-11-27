#!/usr/bin/env bash
# repo_update.sh - one call that mirrors the repo's docs and tooling onto the NAS build host and proves it.
#
#   scripts/repo_update.sh [--dry-run] [--message TEXT | --message-file FILE]
#                          [--skip RULE ...] [--dest PATH] [--host HOST]
#
# Order of operations:
#   1. tools/doc_lint.py over the docs; any finding aborts before a commit or an upload.
#      --skip RULE is passed straight to the linter (e.g. --skip broken-path for NAS-only files).
#   2. optional commit of the mirrored paths only (--message/--message-file). Nothing else is staged.
#   3. rsync the mirrored paths to $DEST (default /srv/dev-disk-by-label-SSData/aospbuild/VibeBakingFirmware).
#   4. sha256 on both sides, per file. PASS/FAIL per file; exit non-zero on a mismatch, an absent
#      file, or a stray file under a --delete dir.
#
# Safety:
#   - mirrors ONLY docs/ tools/ scripts/ device/rk3399-px6-hct4/ agentPlan.md README.md facts.tsv.
#     .git/, analysis/, incoming/, out/, out-hu/, bootableSD/ and the OEM packages are never touched.
#   - docs/ tools/ scripts/ are mirrored with --delete; device/rk3399-px6-hct4/ WITHOUT --delete,
#     because the NAS holds generated files that are not in git (vendor_build_wins.txt,
#     vendor_modules_extra.mk, vendor_dest_keep.txt, vendor_dest_skip_extra.txt, vendor_staging.mk,
#     vendor_props.mk, vintf/*.xml, prebuilt_apps/). A file deleted in the repo is therefore NOT
#     deleted in the device tree on the NAS: the build tree there is the authority.
#   - agentPlan.md README.md facts.tsv go over as single files, never with --delete.
#   - __pycache__ is excluded everywhere.
#   - --dry-run does not contact the NAS: it mirrors into $SCRATCH/repo_update_dryrun/ (see the scratch
#     probe below) and runs the same verification there, so the rsync rules and the checks are exercisable
#     offline.
#   - authentication is password-only, no keys, no BatchMode. SSH_ASKPASS points at the credential
#     wrapper $HOME/.config/vbf/askpass.sh, same env as scripts/cold_storage_move.sh.
set -eu

REPO=$(cd "$(dirname "$0")/.." && pwd)
HOST=${HOST:-root@192.168.1.29}
DEST=${DEST:-/srv/dev-disk-by-label-SSData/aospbuild/VibeBakingFirmware}
DRY=0
MSG=""
MSGFILE=""
SKIPS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --message) MSG=${2:?--message needs text}; shift 2 ;;
    --message-file) MSGFILE=${2:?--message-file needs a path}; shift 2 ;;
    --skip) SKIPS+=("$2"); shift 2 ;;
    --dest) DEST="$2"; shift 2 ;;
    --host) HOST="$2"; shift 2 ;;
    *) echo "repo_update: unknown argument $1" >&2; exit 2 ;;
  esac
done

export SSH_ASKPASS=$HOME/.config/vbf/askpass.sh
export SSH_ASKPASS_REQUIRE=force
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o PreferredAuthentications=password -o PubkeyAuthentication=no -o BatchMode=no -o ConnectTimeout=15"
RSYNC_OPTS="-a --no-progress"
# rsync -e is space-split, so the ssh options live inside its quoted -e operand.

DELETE_DIRS=(docs tools scripts)
KEEP_DIRS=(device/rk3399-px6-hct4)
SOLO_FILES=(agentPlan.md README.md facts.tsv)

# ---------------------------------------------------------------- 1. lint
lint_args=()
for s in ${SKIPS[@]+"${SKIPS[@]}"}; do lint_args+=(--skip "$s"); done
echo "== doc_lint =="
if ! python3 "$REPO/tools/doc_lint.py" ${lint_args[@]+"${lint_args[@]}"}; then
  echo "repo_update: doc_lint failed; nothing committed, nothing mirrored" >&2
  exit 1
fi

# ---------------------------------------------------------------- 2. optional commit
if [ -n "$MSG" ] || [ -n "$MSGFILE" ]; then
  if [ "$DRY" = 1 ]; then
    echo "repo_update: --dry-run does not commit"
  else
    git -C "$REPO" add -- "${DELETE_DIRS[@]}" "${KEEP_DIRS[@]}" "${SOLO_FILES[@]}"
    if git -C "$REPO" diff --cached --quiet; then
      echo "repo_update: nothing staged"
    elif [ -n "$MSGFILE" ]; then
      git -C "$REPO" commit --quiet -F "$MSGFILE"
      echo "repo_update: committed $(git -C "$REPO" rev-parse --short HEAD)"
    else
      git -C "$REPO" commit --quiet -m "$MSG"
      echo "repo_update: committed $(git -C "$REPO" rev-parse --short HEAD)"
    fi
  fi
fi

# Scratch for the verify script and the dry-run tree. /tmp on this workstation is a 16 GiB tmpfs with a
# per-user quota and it fills up: creating a directory succeeds there but writing fails (Errno 122), so the
# root is probed by an actual write, the same way tests/test_doc_edit.py probes it. Override with
# HU_SCRATCH_ROOT.
SCRATCH=${HU_SCRATCH_ROOT:-/run/media/Daan/Opslagmonster/a14-work/tmp}
if ! { mkdir -p "$SCRATCH" && : > "$SCRATCH/.repo_update_probe"; } 2>/dev/null; then
  SCRATCH=/run/media/Daan/Opslagmonster/a14-work/scratch
  mkdir -p "$SCRATCH" 2>/dev/null || true
fi
rm -f "$SCRATCH/.repo_update_probe"

# ---------------------------------------------------------------- 3. mirror
TARGET="$DEST"
if [ "$DRY" = 1 ]; then
  TARGET="$SCRATCH/repo_update_dryrun"
  rm -rf "$TARGET"
  mkdir -p "$TARGET"
  RSYNC_DEST="$TARGET"
  echo "== mirror (DRY RUN: local scratch $TARGET; the NAS is not contacted) =="
else
  echo "== mirror -> $HOST:$DEST =="
  # A remote rsync target needs the host prefix. Without it rsync treats the NAS path as a local
  # path and tries to mkdir it here - measured Nov 18: `rsync: [Receiver] mkdir
  # "/srv/dev-disk-by-label-SSData/aospbuild/VibeBakingFirmware/docs" failed: No such file or
  # directory (2)`, so the mirror silently did nothing while the ssh-side checks stayed correct.
  RSYNC_DEST="$HOST:$DEST"
  # rsync creates the leaf dir but not the parent, so the parents are made in one ssh call.
  parents=""
  for d in ${DELETE_DIRS[@]+"${DELETE_DIRS[@]}"} ${KEEP_DIRS[@]+"${KEEP_DIRS[@]}"}; do
    [ -d "$REPO/$d" ] && parents="$parents '$DEST/$d'"
  done
  [ -n "$parents" ] && ssh $SSH_OPTS "$HOST" "mkdir -p${parents}" >/dev/null
fi

for d in ${DELETE_DIRS[@]+"${DELETE_DIRS[@]}"}; do
  [ -d "$REPO/$d" ] || continue
  if [ "$DRY" = 1 ]; then mkdir -p "$TARGET/$d"; fi
  rsync $RSYNC_OPTS --delete --exclude __pycache__ -e "ssh $SSH_OPTS" "$REPO/$d/" "$RSYNC_DEST/$d/"
done
for d in ${KEEP_DIRS[@]+"${KEEP_DIRS[@]}"}; do
  [ -d "$REPO/$d" ] || continue
  if [ "$DRY" = 1 ]; then mkdir -p "$TARGET/$d"; fi
  rsync $RSYNC_OPTS --exclude __pycache__ -e "ssh $SSH_OPTS" "$REPO/$d/" "$RSYNC_DEST/$d/"
done
for f in ${SOLO_FILES[@]+"${SOLO_FILES[@]}"}; do
  [ -f "$REPO/$f" ] || continue
  rsync $RSYNC_OPTS -e "ssh $SSH_OPTS" "$REPO/$f" "$RSYNC_DEST/$f"
done

# ---------------------------------------------------------------- 4. verify sha256 on both sides
# Relative paths, sorted. None of these trees hold spaces in file names.
LIST=$(cd "$REPO" && {
  for d in ${DELETE_DIRS[@]+"${DELETE_DIRS[@]}"} ${KEEP_DIRS[@]+"${KEEP_DIRS[@]}"}; do
    [ -d "$d" ] && find "$d" -type f ! -path '*__pycache__*'
  done
  for f in ${SOLO_FILES[@]+"${SOLO_FILES[@]}"}; do [ -f "$f" ] && printf '%s\n' "$f"; done
} | sort)

# Nested ssh quoting eats operands, so the target-side script is transferred as base64, the way
# scripts/cold_storage_move.sh does. It hashes every listed file, and reports files that exist on
# the target but were not in the list as EXTRA.
TARGET_SCRIPT=$(mktemp "$SCRATCH/repo_update_check.XXXXXX.sh")
{
  printf '#!/bin/sh\ncd "%s" || { echo "MISSING-TREE %s"; exit 1; }\n' "$TARGET" "$TARGET"
  printf 'D=$(mktemp -d) || exit 1\n'
  printf 'cat <<"EOF_LIST" > "$D/src"\n'
  printf '%s\n' "$LIST"
  printf 'EOF_LIST\n'
  printf 'while read -r p; do\n'
  printf '  [ -n "$p" ] || continue\n'
  printf '  if [ -f "$p" ]; then sha256sum "$p"; else echo "MISSING  $p"; fi\ndone < "$D/src"\n'
  printf '{ for d in'
  for d in ${DELETE_DIRS[@]+"${DELETE_DIRS[@]}"} ${KEEP_DIRS[@]+"${KEEP_DIRS[@]}"}; do printf ' %s' "$d"; done
  printf '; do [ -d "$d" ] && find "$d" -type f ! -path "*__pycache__*"; done\n'
  printf 'for f in'
  for f in ${SOLO_FILES[@]+"${SOLO_FILES[@]}"}; do printf ' %s' "$f"; done
  printf '; do [ -f "$f" ] && printf "%%s\\n" "$f"; done } | sort > "$D/tgt"\n'
  printf 'sort "$D/src" > "$D/sorted"\n'
  printf 'comm -23 "$D/tgt" "$D/sorted" | sed "s/^/EXTRA  /"\n'
  printf 'rm -rf "$D"\n'
} > "$TARGET_SCRIPT"

echo "== verify sha256 =="
if [ "$DRY" = 1 ]; then
  REMOTE=$(bash "$TARGET_SCRIPT")
else
  b64=$(base64 -w0 "$TARGET_SCRIPT")
  REMOTE=$(ssh $SSH_OPTS "$HOST" "printf '%s' '$b64' | base64 -d > /var/tmp/repo_update_check.sh && bash /var/tmp/repo_update_check.sh")
fi
rm -f "$TARGET_SCRIPT"

fails=0
extras_delete=0
n=0
while read -r p; do
  [ -n "$p" ] || continue
  n=$((n + 1))
  lsha=$(cd "$REPO" && sha256sum "$p" | cut -d' ' -f1)
  case "$p" in
    docs/*|tools/*|scripts/*) in_delete_dir=1 ;;
    *) in_delete_dir=0 ;;
  esac
  rline=$(printf '%s\n' "$REMOTE" | grep -F "  $p" | head -1)
  if [ "$rline" = "MISSING  $p" ] || [ -z "$rline" ]; then
    echo "FAIL $p (absent on target)"
    fails=$((fails + 1))
    continue
  fi
  rsha=$(printf '%s' "$rline" | cut -d' ' -f1)
  if [ "$rsha" = "$lsha" ]; then
    echo "PASS $p"
  else
    echo "FAIL $p (local $lsha target $rsha)"
    fails=$((fails + 1))
  fi
done <<EOF
$LIST
EOF

# Extras: under docs/ tools/ scripts/ --delete should have removed them, so they are a failure; in
# the device tree they are the NAS-only generated files and are only listed.
printf '%s\n' "$REMOTE" | grep '^EXTRA  ' | while read -r _ p; do
  [ -n "$p" ] || continue
  case "$p" in
    docs/*|tools/*|scripts/*) echo "FAIL stray file on target (--delete should have removed it): $p" ;;
    *) echo "KEEP $p (NAS-only; the device tree is mirrored without --delete)" ;;
  esac
done
if printf '%s\n' "$REMOTE" | grep '^EXTRA  ' | grep -qE '^EXTRA  (docs|tools|scripts)/'; then
  extras_delete=1
fi

echo "== $n mirrored files, $fails mismatches, $extras_delete strays under a --delete dir =="
if [ "$fails" -gt 0 ] || [ "$extras_delete" -gt 0 ]; then
  echo "repo_update: MIRROR NOT VERIFIED" >&2
  exit 1
fi
echo "repo_update: PASS"
