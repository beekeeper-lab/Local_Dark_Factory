#!/usr/bin/env bash
# sync-tree.sh — copy a worktree into an editable tree the sandbox can mount.
#
# The boundary §08 describes is made of two halves and this is the second one:
# the controller keeps the real worktree outside the sandbox, and syncs a copy
# *without* .git into it. That is what makes "no git" structural rather than
# instructional — there is no repository inside to act on, so there is nothing
# for a worker to commit, branch, stash or push, whatever it decides to try.
#
# Sync-back is the same call with the arguments reversed, which is why direction
# is an argument rather than two scripts: one implementation, one set of
# exclusions, no chance of them drifting apart.
set -euo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$PIPELINE_DIR/lib.sh"

USAGE="sync-tree.sh <src> <dest> [--exclude <glob>]..."
case "${1:-}" in
  --version) cat "$PIPELINE_DIR/VERSION"; exit 0 ;;
  -h|--help)
    echo "sync-tree.sh — mirror <src> into <dest>, never carrying .git."
    echo "$USAGE"
    echo ""
    echo "Always excluded: .git, .git/**, and anything named by --exclude."
    echo "<dest> is made to match <src> exactly: files removed in src are removed"
    echo "in dest, because a stale file left behind is a file the gates would run"
    echo "against and nobody would think to look for."
    exit 0 ;;
esac
require_args "$#" 2 "$USAGE"

SRC="$1"; DEST="$2"; shift 2
EXCLUDES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --exclude) EXCLUDES+=( "${2:?--exclude needs a glob}" ); shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -d "$SRC" ] || die "source not found: $SRC"
mkdir -p "$DEST"
SRC="$(cd "$SRC" && pwd)"
DEST="$(cd "$DEST" && pwd)"
[ "$SRC" != "$DEST" ] || die "source and destination are the same directory"

# SYNC_TREE_NO_RSYNC=1 forces the fallback. It exists so the fallback can be
# tested: it is the path that had a .git leak, and on any machine with rsync
# installed nothing would ever run it, so the bug could only have been found by
# someone's machine lacking rsync on the day it mattered.
if [ "${SYNC_TREE_NO_RSYNC:-0}" != 1 ] && command -v rsync >/dev/null 2>&1; then
  args=( -a --delete --exclude='.git' --exclude='.git/**' )
  for e in ${EXCLUDES+"${EXCLUDES[@]}"}; do args+=( --exclude="$e" ); done
  rsync "${args[@]}" "$SRC"/ "$DEST"/
else
  # No rsync: do it with tar, which is everywhere. Still exact — the destination
  # is emptied first rather than merged into.
  find "$DEST" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  # `--exclude=.git`, not `--exclude=./.git`: the anchored form excludes only the
  # top-level one, so a nested .git — a submodule, a vendored checkout, anything
  # someone cloned into a subdirectory — would have been copied into the sandbox
  # by this path. rsync's unanchored pattern already matched at any depth, so the
  # two halves of this script disagreed about what "without .git" meant.
  tar_args=( --exclude=.git )
  for e in ${EXCLUDES+"${EXCLUDES[@]}"}; do tar_args+=( --exclude="./$e" ); done
  ( cd "$SRC" && tar -cf - "${tar_args[@]}" . ) | ( cd "$DEST" && tar -xf - )
fi

# The guarantee this script exists to provide, asserted rather than assumed — at
# every depth, because that is what the guarantee says. Checking only the top
# level would have let the tar path's bug through silently, which is how an
# assertion becomes decoration.
STRAY_GIT="$(find "$DEST" -name .git -print -quit 2>/dev/null)"
if [ -n "$STRAY_GIT" ]; then
  die "sync left a .git in the tree ($STRAY_GIT) — the sandbox boundary would be open"
fi
printf '%s\n' "$DEST"
