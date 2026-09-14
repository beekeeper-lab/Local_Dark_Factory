#!/usr/bin/env bash
# doclint.sh — are the document's required sections present, and do they say anything?
#
# §07 makes the section list lint-enforced on purpose: a 27B filling required
# sections is a content problem, which is the one worth having. Without the lint,
# the failure mode is not a missing section — it is a section with a sentence in
# it that restates its own heading, and a judge spending its attention noticing
# that instead of noticing whether the change is right.
#
# So this checks two things, and the second is the one that earns its keep:
#   1. every required section exists;
#   2. it has enough content to be worth reading, and is not just the heading
#      echoed back ("## Risk" / "The risk is low.").
#
# Spelling: both "behaviour" and "behavior" are accepted. The spec is written in
# British English and the developer model is not; failing a document over a
# vowel would teach exactly nothing.
set -uo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$PIPELINE_DIR/lib.sh"

USAGE="doclint.sh spec|impl <document.md>"
case "${1:-}" in
  --version) cat "$PIPELINE_DIR/VERSION"; exit 0 ;;
  -h|--help)
    echo "doclint.sh — check a line document has its required sections, filled in."
    echo "$USAGE"
    echo ""
    echo "spec.md   What and why · Current behaviour · Proposed change · Risk ·"
    echo "          Blast radius · Verification · Open questions"
    echo "impl.md   Summary · Walkthrough by task · Deviations from the spec ·"
    echo "          Risk & blast radius, as built · Evidence · How to verify locally · Rollback"
    echo ""
    echo "Exit 0 when every required section is present and substantive."
    echo "MIN_SECTION_CHARS (default 80) sets what 'substantive' means."
    exit 0 ;;
esac
require_args "$#" 2 "$USAGE"

KIND="$1"
DOC="$2"
[ -f "$DOC" ] || die "document not found: $DOC"
MIN_CHARS="${MIN_SECTION_CHARS:-80}"

case "$KIND" in
  spec) SECTIONS=(
          "what and why"
          "current behaviour|current behavior"
          "proposed change"
          "risk"
          "blast radius"
          "verification"
          "open questions" ) ;;
  impl) SECTIONS=(
          "summary"
          "walkthrough by task"
          "deviations from the spec"
          "risk & blast radius, as built|risk and blast radius, as built|risk & blast radius as built"
          "evidence"
          "how to verify locally"
          "rollback" ) ;;
  *) die "unknown document kind '$KIND' (expected spec or impl)" ;;
esac

FAIL=0
report_fail() { printf '  FAIL  %-32s %s\n' "$1" "$2"; FAIL=1; }
report_ok()   { printf '  ok    %-32s %s\n' "$1" "$2"; }

# Section bodies, extracted once: everything under a heading until the next
# heading of the same or higher level.
BODY_OF="$(python3 - "$DOC" <<'PY'
import json, re, sys
lines = open(sys.argv[1]).read().replace("\r\n", "\n").split("\n")
sections, cur, level = {}, None, 0
in_fence = False
for line in lines:
    if line.startswith("```"):
        in_fence = not in_fence
    m = None if in_fence else re.match(r"^(#{1,6})\s+(.*?)\s*$", line)
    if m:
        cur = re.sub(r"[`*_:]", "", m.group(2)).strip().lower()
        level = len(m.group(1))
        sections.setdefault(cur, [])
        continue
    if cur is not None:
        sections[cur].append(line)
print(json.dumps({k: "\n".join(v) for k, v in sections.items()}))
PY
)" || die "could not parse $DOC"

printf 'doclint %s — %s\n\n' "$KIND" "$DOC"

for spec in "${SECTIONS[@]}"; do
  primary="${spec%%|*}"
  found=""
  IFS='|' read -ra alts <<< "$spec"
  for alt in "${alts[@]}"; do
    if jq -e --arg k "$alt" 'has($k)' >/dev/null <<<"$BODY_OF"; then found="$alt"; break; fi
  done
  if [ -z "$found" ]; then
    report_fail "$primary" "section missing"
    continue
  fi

  body="$(jq -r --arg k "$found" '.[$k]' <<<"$BODY_OF")"
  # Content, excluding the heading itself and any nested headings.
  stripped="$(printf '%s' "$body" | sed '/^#\{1,6\} /d' | tr -s '[:space:]' ' ' | sed 's/^ *//; s/ *$//')"
  n="${#stripped}"

  # Order matters. A section that echoes its own heading is always shorter than
  # the minimum, so checking length first would make this branch unreachable and
  # report "too thin" where "you restated the heading" is the useful sentence.
  lowered="$(printf '%s' "$stripped" | tr '[:upper:]' '[:lower:]' | sed 's/[.:]*$//')"
  if [ "$n" -eq 0 ]; then
    report_fail "$primary" "section is empty"
  elif [ "$lowered" = "$primary" ] || [[ "|$spec|" == *"|$lowered|"* ]]; then
    report_fail "$primary" "restates its heading and says nothing else"
  elif [ "$n" -lt "$MIN_CHARS" ]; then
    report_fail "$primary" "only $n characters — too thin to be worth a reader's time (min $MIN_CHARS)"
  else
    report_ok "$primary" "$n characters"
  fi
done

# "None" in Deviations must be a claim, not a shrug: the pre-PR audit checks it
# against the diff, so the document has to say it plainly enough to be checked.
if [ "$KIND" = impl ]; then
  dev="$(jq -r '.["deviations from the spec"] // ""' <<<"$BODY_OF" | tr -s '[:space:]' ' ')"
  if printf '%s' "$dev" | grep -qiE '^\s*(none|n/a|nil)\.?\s*$'; then
    report_fail "deviations from the spec" \
      "a bare 'None' — say what was checked against what, so the pre-PR audit's matches_diff has something to agree or disagree with"
  fi
fi

printf '\n'
if [ "$FAIL" -eq 0 ]; then
  printf 'doclint: PASS\n'
  exit 0
fi
printf 'doclint: FAIL — the document is not ready for an audit to spend attention on\n'
exit 1
