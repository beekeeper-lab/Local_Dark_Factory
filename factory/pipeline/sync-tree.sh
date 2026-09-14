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

if command -v rsync >/dev/null 2>&1; then
  args=( -a --delete --exclude='.git' --exclude='.git/**' )
  for e in ${EXCLUDES+"${EXCLUDES[@]}"}; do args+=( --exclude="$e" ); done
  rsync "${args[@]}" "$SRC"/ "$DEST"/
else
  # No rsync: do it with tar, which is everywhere. Still exact — the destination
  # is emptied first rather than merged into.
  find "$DEST" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  tar_args=( --exclude=./.git )
  for e in ${EXCLUDES+"${EXCLUDES[@]}"}; do tar_args+=( --exclude="./$e" ); done
  ( cd "$SRC" && tar -cf - "${tar_args[@]}" . ) | ( cd "$DEST" && tar -xf - )
fi

# The guarantee this script exists to provide, asserted rather than assumed.
if [ -e "$DEST/.git" ]; then
  die "sync left a .git in $DEST — the sandbox boundary would be open"
fi
printf '%s\n' "$DEST"
