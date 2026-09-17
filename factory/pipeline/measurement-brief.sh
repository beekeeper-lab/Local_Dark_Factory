#!/usr/bin/env bash
# measurement-brief.sh — a controller measurement, in the fewest bytes that keep
# it true.
#
# The judge is sent two measurements the controller already took: which verifies
# already passed before any work was done (`verify-precheck.json`), and which
# paths the spec says exist, checked against the repo (`claims-check.json`). Both
# go as raw JSON, and between them they are **4,805 of the 25,428 bytes** of a
# real spec audit — 19% of the prompt, spent on two facts that fit in a
# paragraph each.
#
# That matters because of the one thing measured this week that moved the
# false-accept rate: **size**. Three passes at 20,422 and 30,422 bytes rejected a
# seeded defect 3 of 3; at 40,422 the judge accepted it 2 of 3. Real audits sit
# at 25,428. Every byte that does not have to be there is worth removing, and
# these are the easiest ones in the prompt because nothing in them is under
# audit — they are the controller's own output.
#
# There is a second reason, which is what the judge did with the raw form. On a
# reaudit it read claims-check.json as "a confusing set of statements about its
# own task", invented a response shape, and ended twenty thousand characters of
# reasoning with "Could you clarify what exactly you'd like me to do?". A
# measurement rendered as sentences is harder to mistake for a question.
#
# The brief is written INTO the run directory, not held in memory. The quote
# check searches the run directory, so a judge quoting the brief must be able to
# have its quote found — a summary that exists only inside the prompt would make
# every quote from it read as an invention.
set -uo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
measurement-brief.sh — render a controller measurement as short prose.

usage: measurement-brief.sh <file.json> [--out <file.txt>]

Understands verify-precheck/1.x and claims-check/1.x. Anything else is refused
rather than summarised badly: a brief that silently drops a field the judge
needed is worse than the JSON it replaced.

Exit: 0 written · 2 could not read it, or does not know the schema
EOF
}

SRC=""; OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="${2:?--out needs a path}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; exit 2 ;;
    *) [ -z "$SRC" ] && SRC="$1" || { usage >&2; exit 2; }; shift ;;
  esac
done
[ -n "$SRC" ] && [ -f "$SRC" ] || { usage >&2; printf 'measurement-brief: no such file: %s\n' "${SRC:-<unset>}" >&2; exit 2; }
jq -e . "$SRC" >/dev/null 2>&1 || { printf 'measurement-brief: %s is not JSON\n' "$SRC" >&2; exit 2; }

SCHEMA="$(jq -r '.schema // .schema_version // ""' "$SRC")"
render() {
case "$SCHEMA" in
  verify-precheck/*)
    printf 'Every verify in the task list was run against the tree BEFORE any task\n'
    printf 'touched it. A verify that passed then cannot show the task was done.\n\n'
    # One line per task: how many of its verifies were already passing. The
    # whole judgement this measurement supports is "is there a task where every
    # check already passed", and that is a count, not a list of commands.
    jq -r '
      .tasks[]? as $t
      | ($t.verifies // []) as $v
      | ($v | map(select(.passes_before_the_work == true)) | length) as $pre
      | ($v | length) as $n
      | "  \($t.task): \($pre) of \($n) verifies already passed"
        + (if $n > 0 and $pre == $n then "   <- EVERY check already passed. Nothing about this task could be demonstrated by running them." else "" end)
    ' "$SRC"
    printf '\nOne already-passing verify among several is often legitimate: a lint that is\n'
    printf 'green on an empty directory, or a refactor whose check is that existing tests\n'
    printf 'still pass. A task where EVERY verify already passed is not.\n'
    ;;
  claims-check/*)
    printf 'What the spec says about the repository, checked against the repository by\n'
    printf 'the controller before you were asked anything.\n\n'
    jq -r '
      to_entries[]
      | select(.value | type == "object")
      | select(.value | has("checked"))
      | .value as $s
      | "  section \"\($s.section // .key)\": "
        + (if ($s.checked // false) then "checked" else "NOT CHECKED" end)
        + (if (($s.missing_paths // []) | length) > 0
           then "\n    says these exist and they do NOT: " + (($s.missing_paths // []) | join(", ")) else "" end)
        + (if (($s.said_absent_but_present // []) | length) > 0
           then "\n    says these are absent and they ARE present: " + (($s.said_absent_but_present // []) | join(", ")) else "" end)
        + (if ((($s.missing_paths // []) | length) == 0 and (($s.said_absent_but_present // []) | length) == 0)
           then "\n    every path it names is as the spec describes" else "" end)
    ' "$SRC"
    ;;
  *)
    printf 'measurement-brief: unknown schema %s in %s\n' "${SCHEMA:-<none>}" "$SRC" >&2
    printf '  Refusing rather than summarising it badly: a brief that silently drops a\n' >&2
    printf '  field the judge needed is worse than the JSON it replaced.\n' >&2
    return 2 ;;
esac
}

if [ -n "$OUT" ]; then
  mkdir -p "$(dirname "$OUT")"
  TMP="$(mktemp)"
  if render > "$TMP"; then mv "$TMP" "$OUT"; else rm -f "$TMP"; exit 2; fi
  printf 'measurement-brief: %s bytes -> %s bytes (%s)\n' \
    "$(wc -c < "$SRC")" "$(wc -c < "$OUT")" "$(basename "$OUT")"
else
  render || exit 2
fi
