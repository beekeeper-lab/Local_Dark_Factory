#!/usr/bin/env bash
# non-goals.sh — the half of a bean's non-goals a script can decide.
#
# `non_goals` has been a list of English sentences, checked by asking the judge.
# On 2026-09-16 that judge was measured accepting seeded defects 7 to 9 times out
# of 15, and `contradicts-non-goal` — a spec that plans work the bean forbids — was
# one of the cases it missed. bench/controller-fitness.sh had it as "not decidable
# from the documents, needs a judge".
#
# Half of it is decidable, and it is the half that keeps being violated: a non-goal
# about a PLACE ("no CI workflow files", "no solver code") is a statement about
# paths and imports, and paths and imports are countable. So a non-goal may carry
# them:
#
#   non_goals:
#     - no domain models                        # prose only, still the judge's
#     - text: no solver code
#       forbidden_paths: ["src/**/solver/**"]
#       forbidden_imports: [ortools]
#     - text: no CI workflow files
#       forbidden_paths: [".github/workflows/**"]
#
# Nothing is required. A bean written as prose keeps working exactly as before,
# and this reports that it had nothing to check rather than that everything is
# fine — those are different answers and a check that conflates them is the
# fail-open this project keeps finding.
#
# What it is honest about: `forbidden_imports` is a grep over added lines of the
# diff, anchored at the start of the line after the `+` and allowing indentation.
# It catches `import ortools`, `    import ortools` and `from ortools.sat import
# x`; it does not catch `__import__("ortools")`, a dynamic loader, or an import
# buried mid-line after a semicolon. It says so in its own output rather than
# implying a completeness it does not have.
set -uo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$PIPELINE_DIR/lib.sh"

usage() {
  cat <<'EOF'
non-goals.sh — check paths and imports against a bean's machine-readable non-goals.

usage: non-goals.sh --bean <bean.yaml> (--paths <json-array> | --diff <file>)
                    [--json <path>]

  --paths   a JSON array of paths or path patterns. Plan time: a task's
            write_paths, checked before any work is done.
  --diff    a unified diff. Gate time: what was actually written, plus the added
            lines that `forbidden_imports` is grepped over.
  --json    also write the result as JSON.

Exit: 0 nothing forbidden (or the bean declares none to check)
      1 a non-goal is violated, and it says which and by what
      2 could not check — a bean that will not parse, a missing interpreter
EOF
}

BEAN=""; PATHS=""; DIFF=""; JSON=""
while [ $# -gt 0 ]; do
  case "$1" in
    --bean)  BEAN="${2:?--bean needs a file}"; shift 2 ;;
    --paths) PATHS="${2:?--paths needs a JSON array}"; shift 2 ;;
    --diff)  DIFF="${2:?--diff needs a file}"; shift 2 ;;
    --json)  JSON="${2:?--json needs a path}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --version) cat "$PIPELINE_DIR/VERSION"; exit 0 ;;
    *) usage >&2; printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[ -n "$BEAN" ] && [ -f "$BEAN" ] || { usage >&2; printf 'non-goals: no bean at %s\n' "${BEAN:-<unset>}" >&2; exit 2; }
[ -n "$PATHS" ] || [ -n "$DIFF" ] || { usage >&2; printf 'non-goals: one of --paths or --diff\n' >&2; exit 2; }
[ -z "$DIFF" ] || [ -f "$DIFF" ] || { printf 'non-goals: no such diff file: %s\n' "$DIFF" >&2; exit 2; }

BEAN_JSON="$("$PIPELINE_DIR/yaml2json.sh" "$BEAN")" \
  || { printf 'non-goals: cannot read the bean: %s\n' "$BEAN" >&2; exit 2; }
PY="$(factory_python)"

# Only the entries that carry something to check. A plain string is prose and
# stays the judge's; an object with neither list is prose that happens to be an
# object, and is treated the same.
RULES="$(jq -c '[ (.non_goals // [])[]
  | select(type == "object")
  | {text: (.text // "(no text)"),
     paths: (.forbidden_paths // []),
     imports: (.forbidden_imports // [])}
  | select((.paths | length) > 0 or (.imports | length) > 0) ]' <<<"$BEAN_JSON")"

N_RULES="$(jq 'length' <<<"$RULES")"
if [ "$N_RULES" -eq 0 ]; then
  # Not "nothing forbidden". Nothing DECLARED — a different answer, and the one a
  # reader needs in order to know whether the judge is still the only thing
  # standing between this bean and its own non-goals.
  printf 'non-goals: this bean declares none in machine-readable form; its %s non-goal(s) are prose and remain the audit'"'"'s to judge\n' \
    "$(jq '(.non_goals // []) | length' <<<"$BEAN_JSON")"
  [ -n "$JSON" ] && jq -n --arg b "$(jq -r '.id // "?"' <<<"$BEAN_JSON")" \
    '{schema:"non-goals/1.0.0", bean:$b, checkable_rules:0, violations:[],
      note:"No non_goal carried forbidden_paths or forbidden_imports. Nothing was checked; that is not the same as nothing being wrong."}' > "$JSON"
  exit 0
fi

# What to check paths against.
CHECK_PATHS="$PATHS"
if [ -z "$CHECK_PATHS" ]; then
  # +++ b/<path> is what git writes for a file that exists after the change; a
  # deletion has /dev/null there and is not a write into a forbidden place.
  CHECK_PATHS="$(grep -E '^\+\+\+ b/' "$DIFF" 2>/dev/null | sed 's|^+++ b/||' \
    | jq -Rsc 'split("\n") | map(select(length > 0))')"
  [ -n "$CHECK_PATHS" ] || CHECK_PATHS='[]'
fi

VIOL='[]'
while IFS= read -r rule; do
  [ -n "$rule" ] || continue
  text="$(jq -r '.text' <<<"$rule")"
  pats="$(jq -c '.paths' <<<"$rule")"
  imps="$(jq -r '.imports[]?' <<<"$rule")"

  if [ "$(jq 'length' <<<"$pats")" -gt 0 ]; then
    # contain.py answers "is this path inside these patterns", which is the same
    # question with the sense flipped: a path INSIDE a forbidden pattern is the
    # violation. Reusing it rather than writing a second glob matcher, because two
    # glob matchers is one that will eventually disagree with the other.
    hits="$(jq -r '.[]' <<<"$CHECK_PATHS" | "$PY" "$PIPELINE_DIR/contain.py" --patterns "$pats" 2>/dev/null)"
    crc=$?
    if [ "$crc" -ge 2 ]; then
      printf 'non-goals: could not compute containment for %s\n' "$text" >&2
      exit 2
    fi
    # contain.py prints the paths that are OUTSIDE. Inside = the rest.
    inside="$(jq -c --argjson all "$CHECK_PATHS" --argjson out "$(printf '%s\n' "$hits" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
      -n '$all - $out')"
    if [ "$(jq 'length' <<<"$inside")" -gt 0 ]; then
      VIOL="$(jq -c --arg t "$text" --argjson p "$inside" --argjson pat "$pats" \
        '. + [{non_goal:$t, kind:"path", patterns:$pat, offending:$p}]' <<<"$VIOL")"
    fi
  fi

  if [ -n "$imps" ] && [ -n "$DIFF" ]; then
    while IFS= read -r mod; do
      [ -n "$mod" ] || continue
      # Added lines only. A diff that REMOVES an import of a forbidden module is
      # the bean being obeyed, not broken.
      # Anchored at the start of the added line, after the `+`, allowing
      # indentation. The first version tried `.*(^|[[:space:]])` to catch an
      # import anywhere on the line; `^` cannot match after `.*`, so it matched
      # nothing at all and reported a clean diff for one that began
      # `+from ortools.sat.python import cp_model`. A check that cannot fire is
      # worse than no check, because its silence reads as a pass.
      found="$(grep -E "^\+[[:space:]]*(from|import)[[:space:]]+${mod}([.,[:space:]]|\$)" "$DIFF" 2>/dev/null | head -3)"
      if [ -n "$found" ]; then
        VIOL="$(jq -c --arg t "$text" --arg m "$mod" \
          --argjson l "$(printf '%s\n' "$found" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
          '. + [{non_goal:$t, kind:"import", module:$m, lines:$l}]' <<<"$VIOL")"
      fi
    done <<< "$imps"
  fi
done < <(jq -c '.[]' <<<"$RULES")

N_VIOL="$(jq 'length' <<<"$VIOL")"
if [ -n "$JSON" ]; then
  mkdir -p "$(dirname "$JSON")"
  jq -n --arg b "$(jq -r '.id // "?"' <<<"$BEAN_JSON")" --argjson r "$N_RULES" --argjson v "$VIOL" \
    --argjson checked "$CHECK_PATHS" \
    '{schema:"non-goals/1.0.0", bean:$b, checkable_rules:$r, paths_checked:$checked, violations:$v,
      caveat:"forbidden_imports is a grep over added diff lines, anchored at the start of the line and allowing indentation. It catches `import x`, `    import x` and `from x import y`; it does not catch __import__, a dynamic loader, or an import after a semicolon mid-line. forbidden_paths is exact, because it is the same matcher the containment check uses."}' > "$JSON"
fi

if [ "$N_VIOL" -eq 0 ]; then
  printf 'non-goals: %s rule(s) checked, nothing forbidden was touched\n' "$N_RULES"
  exit 0
fi
printf 'non-goals: %s of the bean'"'"'s own non-goals are contradicted:\n' "$N_VIOL" >&2
jq -r '.[] | if .kind == "path"
  then "  - \"\(.non_goal)\" — \(.offending | join(", ")) is inside \(.patterns | join(", "))"
  else "  - \"\(.non_goal)\" — imports \(.module): \(.lines[0])" end' <<<"$VIOL" >&2
printf '\n  A non-goal is what the bean says this change is NOT for. Work that lands in one\n' >&2
printf '  is a different bean arriving early, and the bean that owns it would then have to\n' >&2
printf '  edit a file outside its own write paths.\n' >&2
exit 1
