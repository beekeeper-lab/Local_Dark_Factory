#!/usr/bin/env bash
# doc-check.sh — the controller's half of the documenting stage (§06 step 9).
#
# Lints the implementation document, spot-checks the claims a script can check,
# and renders it. The judge decides whether the document *teaches*; this decides
# whether it is about the right change.
#
# The cheap check that earns its place: every file the document names in a code
# block label should appear in the diff, and every file in the diff should appear
# somewhere in the document. A walkthrough that omits a changed file is how a
# reviewer misses the one hunk that mattered.
set -uo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$PIPELINE_DIR/lib.sh"

usage() {
  echo "doc-check.sh <run_dir> [--templates <dir>] [--base <ref>]"
  echo "Lints impl-detail.md, checks it covers the diff, renders impl-detail.html."
  echo "Exit: 0 ready to audit · 1 not yet a document an audit could judge."
}

RUN_DIR=""; TEMPLATES=""; BASE="main"
while [ $# -gt 0 ]; do
  case "$1" in
    --templates) TEMPLATES="${2:?}"; shift 2 ;;
    --base)      BASE="${2:?}"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    --version)   cat "$PIPELINE_DIR/VERSION"; exit 0 ;;
    -*)          usage >&2; die "unknown flag: $1" ;;
    *)           [ -z "$RUN_DIR" ] || die "only one run dir"; RUN_DIR="$1"; shift ;;
  esac
done
[ -n "$RUN_DIR" ] && [ -d "$RUN_DIR" ] || { usage >&2; exit 1; }
require_cmd jq
ROOT="$(repo_root)"
PY="$(factory_python)"
[ -n "$TEMPLATES" ] || TEMPLATES="$ROOT/factory/templates"

DOC="$RUN_DIR/impl-detail.md"
FAILED=0
ok()  { printf '  ok    %-26s %s\n' "$1" "$2"; }
bad() { printf '  FAIL  %-26s %s\n' "$1" "$2"; FAILED=1; }

printf '\nDOC CHECK %s\n\n' "$(basename "$RUN_DIR")"

if [ ! -f "$DOC" ]; then
  bad "impl-detail.md" "not written — there is nothing to audit or to attach to a PR"
  printf '\nDOC CHECK FAIL\n'; exit 1
fi

if out="$("$PIPELINE_DIR/doclint.sh" impl "$DOC" 2>&1)"; then
  ok "impl-detail.md" "$(grep -c '^  ok' <<<"$out") sections present and substantive"
else
  bad "impl-detail.md" "doclint failed"
  printf '%s\n' "$out" | sed -n '/FAIL/p' | sed 's/^/          /'
fi

# Does the document cover the change it claims to describe?
MERGE_BASE="$(git -C "$ROOT" merge-base "$BASE" HEAD 2>/dev/null || echo "$BASE")"
CHANGED="$(git -C "$ROOT" diff --name-only "$MERGE_BASE"...HEAD 2>/dev/null | sed '/^$/d')"
if [ -z "$CHANGED" ]; then
  printf '  note  %-26s %s\n' "coverage" "no diff against $BASE; nothing to cross-check"
else
  # Look in the WALKTHROUGH, not the whole document. §07 asks that section to
  # show the hunks that matter for each task; a filename that appears only in a
  # deviations sentence is a mention, not a walkthrough, and counting it would
  # let a document pass while the reviewer still has no account of the change.
  WALK="$("$PY" - "$DOC" <<'PY'
import re, sys
lines = open(sys.argv[1]).read().split("\n")
out, inside, fence = [], False, False
for line in lines:
    if line.startswith("```"):
        fence = not fence
    if not fence and re.match(r"^#{1,6}\s", line):
        inside = bool(re.match(r"^#{1,6}\s+walkthrough", line.strip(), re.I))
        continue
    if inside:
        out.append(line)
print("\n".join(out))
PY
)"
  missing=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -qF -- "$f" <<<"$WALK" || missing="$missing $f"
  done <<< "$CHANGED"
  if [ -n "$missing" ]; then
    bad "coverage" "changed files the walkthrough never covers:$missing"
  else
    ok "coverage" "the walkthrough covers all $(wc -l <<<"$CHANGED") changed file(s)"
  fi
  # And the other direction: a file the document walks through that is not in the
  # diff is a paragraph about work that did not happen.
  invented=""
  while IFS= read -r label; do
    [ -n "$label" ] || continue
    printf '%s\n' "$CHANGED" | grep -qF -- "$label" || invented="$invented $label"
  done < <(grep -oE '^```[a-z]* +[^ ]+\.[a-z]+' "$DOC" | awk '{print $2}' | sort -u)
  [ -z "$invented" ] && ok "no invented files" "every file the document shows is in the diff" \
    || bad "invented files" "shown in the document but absent from the diff:$invented"
fi

# Provenance the document claims must match what the gate recorded.
if [ -f "$RUN_DIR/gate.json" ]; then
  cand="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)"
  if grep -qF "${cand:0:12}" "$DOC" 2>/dev/null; then
    ok "provenance" "the document names the candidate it describes"
  else
    printf '  note  %-26s %s\n' "provenance" "the document does not name the candidate sha; not required, but a reviewer usually wants it"
  fi
fi

if [ -f "$TEMPLATES/impl-detail.html" ]; then
  if "$PY" "$PIPELINE_DIR/render-doc.py" "$DOC" "$TEMPLATES/impl-detail.html" \
      "$RUN_DIR/impl-detail.html" --meta "run=$(basename "$RUN_DIR")" >/dev/null 2>&1; then
    ok "impl-detail.html" "rendered into the repo's template"
  else
    bad "impl-detail.html" "could not be rendered"
  fi
else
  printf '  note  %-26s %s\n' "impl-detail.html" "no template at $TEMPLATES/impl-detail.html"
fi

printf '\n'
[ "$FAILED" = 0 ] && { printf 'DOC CHECK PASS\n'; exit 0; }
printf 'DOC CHECK FAIL — not yet a document an audit could spend attention on\n'
exit 1
