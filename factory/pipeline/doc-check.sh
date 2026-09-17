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
# Every other deterministic check in this line leaves a record — spec-check,
# package-check, the gate, claims-check, test-integrity, verify-precheck all
# write a JSON file. This one wrote only to the log, so "the document was
# checked" was a fact about a terminal and not about the run. That is the same
# gap package-check exists to close, one file over: a reader of the run directory
# could not tell whether doc-check had run, passed, or never happened.
CHECKS_JSON='[]'
record() { # record <name> <status> <detail>
  CHECKS_JSON="$(jq -c --arg n "$1" --arg s "$2" --arg d "$3" \
    '. + [{check:$n, status:$s, detail:$d}]' <<<"$CHECKS_JSON")"
}
ok()   { printf '  ok    %-26s %s\n' "$1" "$2"; record "$1" pass "$2"; }
bad()  { printf '  FAIL  %-26s %s\n' "$1" "$2"; FAILED=1; record "$1" fail "$2"; }
note() { printf '  note  %-26s %s\n' "$1" "$2"; record "$1" note "$2"; }

printf '\nDOC CHECK %s\n\n' "$(basename "$RUN_DIR")"

if [ ! -f "$DOC" ]; then
  bad "impl-detail.md" "not written — there is nothing to audit or to attach to a PR"
  printf '\nDOC CHECK FAIL\n'; exit 1
fi

if out="$("$PIPELINE_DIR/doclint.sh" impl "$DOC" 2>&1)"; then
  ok "impl-detail.md" "$(grep -c '^  ok' <<<"$out") sections present and substantive"

  # How big the doc AUDIT will be, said here where the author can still act.
  #
  # The doc audit sends three artifacts: this document, the spec it claims to
  # meet, and the diff it claims to describe. On bean-001 that is 36,731 bytes,
  # and this judge was measured on 2026-09-17 rejecting a seeded defect 18 times
  # out of 18 at around 20,000 bytes and 0 times out of 20 at around 40,000 —
  # with the padding in a separate labelled artifact as well as inside the
  # document, so it is not about which artifact carries the bytes.
  #
  # A note, never a failure. §07 asks this document to TEACH and doclint already
  # refuses thin sections; a length cap would pull against both, and the author
  # cannot shrink the diff or the spec. What it can do is say that a longer
  # document makes its own audit less reliable, which is a fact worth having
  # before writing another page, and is invisible otherwise.
  _dsz=$(( $(wc -c < "$DOC" 2>/dev/null || echo 0) ))
  _ssz=$(( $(wc -c < "$RUN_DIR/spec.md" 2>/dev/null || echo 0) ))
  _fsz=$(( $(wc -c < "$RUN_DIR/diff.txt" 2>/dev/null || echo 0) ))
  _tot=$(( _dsz + _ssz + _fsz ))
  if [ "$_tot" -gt "${DOC_AUDIT_SIZE_WARN:-30422}" ]; then
    note "doc audit size" "$_tot bytes will go to the judge ($_dsz this document + $_ssz spec + $_fsz diff) — above 30,422, where this judge stopped rejecting planted defects in every measurement. Not a fault in the document; the audit of it is less reliable, and the human merge is what carries that"
  else
    ok "doc audit size" "$_tot bytes will go to the judge, inside the range where it still rejects planted defects"
  fi
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

# The walkthrough runs until the next heading of the SAME OR HIGHER level, so its
# per-task subsections are part of it.
#
# The previous version set `inside` from whether the current heading matched
# "walkthrough", at any depth — so the first `### task-1` under it turned the
# section off and every file mentioned after that was invisible. The skill asks
# for the section BY TASK ("Walkthrough by task"), which means the first
# subsection heading is where the content starts, and everything the check was
# measuring was the empty run-up to it.
#
# Identical in shape to the bug found in doclint.sh the same afternoon, which
# reported a three-thousand-character section as empty and cost a real run two
# spec attempts. Both were written from the same wrong mental model: that a
# heading ends a section, rather than a heading of the same or higher level.
lines = open(sys.argv[1]).read().split("\n")

heads, fence = [], False
for i, line in enumerate(lines):
    if line.startswith("```"):
        fence = not fence
        continue
    if fence:
        continue
    m = re.match(r"^(#{1,6})\s+(.*)$", line)
    if m:
        heads.append((i, len(m.group(1)), m.group(2).strip()))

out = []
for n, (start, level, title) in enumerate(heads):
    if not re.match(r"^walkthrough", title, re.I):
        continue
    end = len(lines)
    for j in range(n + 1, len(heads)):
        if heads[j][1] <= level:
            end = heads[j][0]
            break
    out.extend(lines[start + 1:end])
    break
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
    note "provenance" "the document does not name the candidate sha; not required, but a reviewer usually wants it"
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
  note "impl-detail.html" "no template at $TEMPLATES/impl-detail.html"
fi

jq -n --arg schema "doc-check/1.0.0" --arg doc "$(basename "$DOC")" \
  --arg status "$([ "$FAILED" = 0 ] && echo pass || echo fail)" \
  --arg sha "$(sha256sum "$DOC" 2>/dev/null | cut -d' ' -f1)" \
  --argjson checks "$CHECKS_JSON" \
  '{schema:$schema, document:$doc, document_sha256:$sha, status:$status, checks:$checks,
    note:"What a machine can decide about a document: that its sections exist and are not fragments, that its walkthrough covers the diff both ways, and that it invents no file. Whether it teaches is the judge and the human."}' \
  > "$RUN_DIR/doc-check.json"

printf '\n'
[ "$FAILED" = 0 ] && { printf 'DOC CHECK PASS\n'; exit 0; }
printf 'DOC CHECK FAIL — not yet a document an audit could spend attention on\n'
exit 1
