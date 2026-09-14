#!/usr/bin/env bash
# sync-skills.sh — keep the repo's canonical pipeline skills and Pi's global skills dir in step.
set -euo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$PIPELINE_DIR/lib.sh"

USAGE="sync-skills.sh --check | --install [--skills-dir <dir>]"

case "${1:-}" in
  -h|--help)
    cat <<'EOF'
sync-skills.sh — the repo is the source of truth for the pipeline skills.

  --check     Compare ai/skills/<name>/SKILL.md against the installed copies.
              Exit 0 when identical, 1 on any drift, listing each difference.
  --install   Copy the repo's copies over the installed ones.

  --skills-dir <dir>   Override the target (default: $PI_SKILLS_DIR, else
                       ~/.pi/agent/skills). Used by the test suite.

Why this exists: the six skills are the pipeline's brain, they live outside the
repo in Pi's global skills directory, and nothing backed them up. A bad edit was
unrecoverable. The repo now holds the canonical copy; this script moves it into
place and detects drift.
EOF
    exit 0
    ;;
  --version) cat "$PIPELINE_DIR/VERSION"; exit 0 ;;
esac

MODE=""
SKILLS_DIR="${PI_SKILLS_DIR:-$HOME/.pi/agent/skills}"
while [ $# -gt 0 ]; do
  case "$1" in
    --check)   MODE="check" ;;
    --install) MODE="install" ;;
    --skills-dir)
      [ $# -ge 2 ] || die "--skills-dir requires a directory"
      SKILLS_DIR="$2"; shift ;;
    *) die "unknown argument '$1' — $USAGE" ;;
  esac
  shift
done
[ -n "$MODE" ] || die "$USAGE"

root="$(repo_root)"
SRC="$root/ai/skills"
[ -d "$SRC" ] || die "canonical skills not found: $SRC"

drift=0
found=0
for d in "$SRC"/*/; do
  [ -d "$d" ] || continue
  name="$(basename "$d")"
  src="$d/SKILL.md"
  [ -f "$src" ] || die "missing $src"
  found=$((found + 1))
  dst="$SKILLS_DIR/$name/SKILL.md"
  if [ "$MODE" = "install" ]; then
    mkdir -p "$SKILLS_DIR/$name"
    cp "$src" "$dst"
    printf 'installed  %s\n' "$name"
  else
    if [ ! -f "$dst" ]; then
      printf 'MISSING    %s (not installed at %s)\n' "$name" "$dst" >&2
      drift=1
    elif ! cmp -s "$src" "$dst"; then
      printf 'DRIFT      %s (repo and installed copy differ)\n' "$name" >&2
      drift=1
    else
      printf 'ok         %s\n' "$name"
    fi
  fi
done

[ "$found" -gt 0 ] || die "no skills found under $SRC"

if [ "$MODE" = "check" ] && [ "$drift" -ne 0 ]; then
  printf '\nRun: ai/pipeline/sync-skills.sh --install   (repo wins)\n' >&2
  printf 'Or copy the installed edits back into ai/skills/ and commit them.\n' >&2
  exit 1
fi
exit 0
