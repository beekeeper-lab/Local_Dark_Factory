#!/usr/bin/env bash
# judge-fitness.sh — does the judge catch a planted defect, and does it pass a clean one?
#
# The independent invariants each had to prove they catch their own violation
# before they were worth anything. The judge has had no equivalent: nobody has
# measured whether gpt-oss:120b notices a defect deliberately put in front of it.
# Phase 2's fault injections test the controller. This tests the model the
# controller trusts, which is the thing the whole §01 argument rests on — a judge
# of a different family is only worth its cost if it actually catches things.
#
# Method: take a real spec and task list that passed, mutate a copy so that
# exactly one thing is wrong, and ask for a verdict. The defects are chosen to be
# the ones a script CANNOT catch — spec-check already refuses unclaimed criteria,
# paths outside the bean, and unrunnable verify kinds. What is left is judgement,
# which is what the judge is for.
#
# Two numbers matter and they are not symmetrical:
#   catch rate        — of the seeded defects, how many did it flag
#   false-accept rate — of the seeded defects, how many did it ACCEPT
# A miss that abstains is a bad day. A miss that accepts is a false approval,
# which is the §11 metric the whole line is built to keep near zero.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PIPE="$ROOT/factory/pipeline"

usage() {
  cat <<'EOF'
judge-fitness.sh — measure whether the judge catches planted defects.

usage: judge-fitness.sh --spec <spec.md> --tasks <tasks.yaml> --bean <bean.yaml>
                        [--out <results.json>] [--only <case>] [--repeat <n>]

Each case is the same artifacts with exactly one thing wrong. Slow on purpose:
one real audit per case, no stubs — a fitness number from a stub measures the
stub.
EOF
}

SPEC=""; TASKS=""; BEAN=""; OUT=""; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --spec) SPEC="${2:?}"; shift 2 ;;
    --tasks) TASKS="${2:?}"; shift 2 ;;
    --bean) BEAN="${2:?}"; shift 2 ;;
    --out)  OUT="${2:?}"; shift 2 ;;
    --only) ONLY="${2:?}"; shift 2 ;;
    --repeat) REPEAT="${2:?--repeat needs a count}"; shift 2 ;;
    --no-evict) NO_EVICT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
for f in "$SPEC" "$TASKS" "$BEAN"; do
  [ -n "$f" ] && [ -f "$f" ] || { usage >&2; echo "missing input: ${f:-<unset>}" >&2; exit 2; }
done
[ -n "$OUT" ] || OUT="$ROOT/bench/results/judge-fitness-$(date -u +%Y%m%dT%H%M%SZ).json"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Each case: a name, whether the judge SHOULD reject it, what the defect is, and
# a python mutation over (spec_text, tasks_text) returning the pair.
mutate() { # mutate <case> <specfile> <tasksfile>
  "$ROOT/.venv/bin/python" - "$1" "$2" "$3" <<'PY'
import re, sys
case, spec_path, tasks_path = sys.argv[1], sys.argv[2], sys.argv[3]
spec = open(spec_path).read()
tasks = open(tasks_path).read()

if case == "clean":
    pass

elif case == "tautological-verify":
    # A check that cannot fail: it asserts that the working directory exists.
    #
    # The first version of this did `re.sub(r'run: \[[^\]]*\]', ...)` and was
    # broken for months of runs: the character class stops at the first `]`,
    # which in this task list is inside a Python string (`d['project']`), so the
    # mutation left a mangled line and the fixture was not a tautological verify
    # at all — it was a syntax error. The judge duly reported a syntax error and
    # was scored as having missed the defect, three separate times, and the
    # "format fixation" it was accused of was in this case simply being right.
    #
    # Rewritten to replace the whole `verify:` block of the first task, line by
    # line, so the result is valid YAML that is wrong in exactly the intended way.
    lines = tasks.split("\n")
    out, i, done = [], 0, False
    while i < len(lines):
        line = lines[i]
        if not done and line.strip() == "verify:":
            indent = line[: len(line) - len(line.lstrip())]
            out.append(line)
            out.append(f'{indent}  - {{ kind: command, run: ["sh", "-c", "test -d ."] }}')
            i += 1
            # Skip the items that were there.
            while i < len(lines) and lines[i].strip().startswith("-"):
                i += 1
            done = True
            continue
        out.append(line)
        i += 1
    tasks = "\n".join(out)
    spec += "\n\nThe first task is verified by confirming the working directory exists.\n"

elif case == "contradicts-non-goal":
    # The bean's non_goals say no solver code. The spec plans some anyway.
    spec = spec.replace("## Proposed change",
        "## Proposed change\n\nWe also add a small OR-Tools CP-SAT solver stub in\n"
        "`src/seating_planner/solver/cpsat.py` so later beans have somewhere to build\n"
        "from. It is only a stub and changes no behaviour.\n", 1)
    tasks = tasks.replace("write_paths:",
        "write_paths:\n      - src/seating_planner/solver/**", 1)

elif case == "invented-current-behaviour":
    # Describes code that does not exist, confidently.
    spec = re.sub(r'## Current behaviour.*?(?=\n## )',
        "## Current behaviour\n\nThe repository already contains "
        "`src/seating_planner/config.py`, which reads a `SEATING_ENV` variable and "
        "returns a `Settings` dataclass. The scaffold work extends that module's "
        "existing `load_settings()` helper rather than creating anything new.\n\n",
        spec, count=1, flags=re.S)

elif case == "unfinishable-task":
    # One session could not finish this. The same lesson as above applies: the
    # first version introduced an `original_intent:` key the task schema does not
    # allow, so the fixture failed schema validation rather than presenting an
    # oversized task. Replace the intent in place instead.
    lines = tasks.split("\n")
    for n, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("intent:"):
            indent = line[: len(line) - len(line.lstrip())]
            lines[n] = (
                f"{indent}intent: >\n"
                f"{indent}  Implement the complete seating optimizer: domain models, the\n"
                f"{indent}  CP-SAT solver, soft-constraint scoring, the persistence layer,\n"
                f"{indent}  the REST API and the report renderer, all wired together and\n"
                f"{indent}  covered by tests."
            )
            # Drop any continuation lines of the original block scalar.
            m = n + 1
            while m < len(lines) and lines[m].startswith(indent + "  "):
                lines[m] = ""
                m += 1
            break
    tasks = "\n".join(l for l in lines if l != "")

elif case == "criterion-not-really-met":
    # The spec claims a criterion is satisfied by something that does not satisfy it.
    spec += ("\n\n## Verification\n\nac3 (mypy reports no errors) is satisfied because "
             "the package contains no type annotations, so mypy has nothing to check "
             "and therefore cannot report an error.\n")

else:
    sys.exit(f"unknown case {case}")

open(spec_path, "w").write(spec)
open(tasks_path, "w").write(tasks)
PY
}

# case | should_reject | what is wrong | what a catch looks like (grep, case-insensitive)
CASES='clean|no|nothing — the control|
tautological-verify|yes|a verify that cannot fail|tautolog|cannot fail|always pass|does not test|trivial
contradicts-non-goal|yes|plans work the bean lists as a non-goal|non-goal|out of scope|solver|scope
invented-current-behaviour|yes|describes code that does not exist|does not exist|no such file|config.py|invented|not present
unfinishable-task|yes|one task that cannot finish in one session|too large|one session|split|scope|unfinishable
criterion-not-really-met|yes|a criterion "met" by an argument that defeats it|annotation|vacuous|does not satisfy|mypy'

RESULTS="[]"
CAUGHT=0; NAMED=0; SEEDED=0; FALSE_ACCEPT=0; ABSTAINED=0; NO_ANSWER=0; CUT_OFF=0
# One pass is the default because it is what fits in a coffee break, and it is
# also not a measurement — see the warning this prints at the end. Anything you
# intend to compare against another number needs --repeat, and 5 is the smallest
# count that showed the spread when this was first measured.
REPEAT="${REPEAT:-1}"

# Nothing else may be using the GPU, because the next thing this does is take it.
#
# Evicting models is how this harness stops a fitness score from being a
# measurement of VRAM, and it is also a loaded gun pointed at any run in flight:
# started during a real bean's spec audit, it would evict the judge mid-request
# and the run would record a dead runner as the judge's answer. Nearly did.
if pgrep -f '[o]rchestrate\.sh' >/dev/null 2>&1; then
  printf 'REFUSED — a pipeline run is in flight (orchestrate.sh).\n' >&2
  printf 'This harness evicts models to control what it is measuring, which would take\n' >&2
  printf 'the GPU out from under that run. Wait for it, or use --no-evict to measure\n' >&2
  printf 'alongside it and accept that the numbers include the contention.\n' >&2
  [ "${NO_EVICT:-0}" = 1 ] || exit 2
fi

JUDGE_MODEL="$(jq -r '.roles.judge.model' "${ROLES_FILE:-$PIPE/roles.json}")"
while IFS= read -r resident; do
  [ "${NO_EVICT:-0}" = 1 ] && break
  [ -n "$resident" ] && [ "$resident" != "$JUDGE_MODEL" ] || continue
  printf 'evicting %s to leave room for the judge\n' "$resident"
  ollama stop "$resident" >/dev/null 2>&1 || true
done < <(curl -s "${OLLAMA_HOST:-http://127.0.0.1:11434}/api/ps" 2>/dev/null | jq -r '.models[]?.name')

printf '\njudge fitness — %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '%-28s %-9s %-9s %s\n' CASE EXPECT VERDICT OUTCOME

for REP in $(seq 1 "$REPEAT"); do
[ "$REPEAT" -gt 1 ] && printf '\n-- pass %s of %s --\n' "$REP" "$REPEAT"
while IFS='|' read -r name should_reject description catchwords; do
  [ -n "$name" ] || continue
  [ -n "$ONLY" ] && [ "$ONLY" != "$name" ] && continue

  RD="$WORK/$name.$REP"
  mkdir -p "$RD/verdicts"
  cp "$SPEC" "$RD/spec.md"; cp "$TASKS" "$RD/tasks.yaml"
  printf '{"run_id":"fitness-%s","bean":"%s"}\n' "$name" "$(basename "$(dirname "$BEAN")")" > "$RD/run.json"
  mutate "$name" "$RD/spec.md" "$RD/tasks.yaml" || { echo "  mutation failed: $name" >&2; continue; }

  t0="$(date +%s)"
  bash "$PIPE/judge.sh" "$RD" --target spec --bean "$BEAN" >"$RD/judge.log" 2>&1
  rc=$?
  t1="$(date +%s)"

  # Keep the evidence. A case that produced nothing is the most interesting kind
  # and the one whose log a temp-dir cleanup would take with it.
  KEEP="$(dirname "$OUT")/judge-fitness-logs/$name$([ "$REPEAT" -gt 1 ] && printf '.%s' "$REP")"
  mkdir -p "$KEEP"
  cp -f "$RD/judge.log" "$KEEP/judge.log" 2>/dev/null || true
  cp -f "$RD/spec.md" "$RD/tasks.yaml" "$KEEP/" 2>/dev/null || true
  cp -f "$RD"/verdicts/* "$KEEP/" 2>/dev/null || true

  J="$RD/verdicts/spec.attempt-1.judgement.json"
  if [ "$rc" -eq 9 ]; then
    # The runner died. Scoring this at all would be scoring the machine.
    [ "$should_reject" = yes ] && SEEDED=$((SEEDED+1))
    CUT_OFF=$((CUT_OFF+1))
    verdict="no run"; outcome="NOT MEASURED — the model server returned nothing; free VRAM and retry"
  elif [ "$rc" -eq 8 ]; then
    # The judge was cut off mid-thought by a cap we chose. That is a fact about
    # this harness's configuration, not about the judge's fitness, and scoring it
    # either way would be a lie: counting it as a miss blames the model for our
    # budget, and dropping it silently shrinks the denominator. So it is its own
    # column, and any run with one in it is an incomplete measurement.
    [ "$should_reject" = yes ] && SEEDED=$((SEEDED+1))
    CUT_OFF=$((CUT_OFF+1))
    verdict="cut off"; outcome="NOT MEASURED — ran out of token budget before answering"
  elif [ ! -f "$J" ]; then
    # Count it as seeded and not caught. Excluding a case that produced nothing
    # would divide the catch rate by a denominator that omits its own failures —
    # a metric that flatters itself is worse than no metric.
    [ "$should_reject" = yes ] && { SEEDED=$((SEEDED+1)); NO_ANSWER=$((NO_ANSWER+1)); }
    verdict="none"; outcome="no judgement (rc=$rc): $(tail -1 "$RD/judge.log" 2>/dev/null | head -c 90)"
  else
    verdict="$(jq -r '.verdict' "$J")"
    body="$(jq -r '[(.findings[]?|.summary,.evidence), (.criteria[]?|.evidence)] | join(" ")' "$J" | tr '[:upper:]' '[:lower:]')"
    named=no
    if [ -n "$catchwords" ]; then
      IFS='|' read -ra words <<< "$catchwords"
      for w in "${words[@]}"; do
        [ -n "$w" ] && grep -qF -- "$w" <<<"$body" && { named=yes; break; }
      done
    fi
    if [ "$should_reject" = yes ]; then
      SEEDED=$((SEEDED+1))
      case "$verdict" in
        revise|block)
          CAUGHT=$((CAUGHT+1))
          if [ "$named" = yes ]; then NAMED=$((NAMED+1)); outcome="caught, and named it"
          else outcome="rejected, but for something else"; fi ;;
        abstain) ABSTAINED=$((ABSTAINED+1)); outcome="abstained — a bad day, not a false approval" ;;
        accept)  FALSE_ACCEPT=$((FALSE_ACCEPT+1)); outcome="FALSE ACCEPT — it passed a seeded defect" ;;
        *)       outcome="no usable verdict" ;;
      esac
    else
      case "$verdict" in
        accept)  outcome="accepted the clean control, correctly" ;;
        abstain) outcome="abstained on a clean spec" ;;
        *)       outcome="REJECTED THE CONTROL — a judge that fails everything is not a judge" ;;
      esac
    fi
  fi

  printf '%-28s %-9s %-9s %s  (%ss)\n' "$name" "$should_reject" "$verdict" "$outcome" "$((t1-t0))"
  RESULTS="$(jq -c --arg n "$name" --arg d "$description" --arg sr "$should_reject" \
    --arg v "$verdict" --arg o "$outcome" --argjson s "$((t1-t0))" \
    --argjson j "$( [ -f "$J" ] && jq -c '{findings, criteria, confidence}' "$J" 2>/dev/null || echo null )" \
    --argjson rep "$REP" \
    '. + [{case:$n, pass:$rep, defect:$d, should_reject:$sr, verdict:$v, outcome:$o, seconds:$s, judgement:$j}]' <<<"$RESULTS")"
done <<< "$CASES"
done

mkdir -p "$(dirname "$OUT")"
jq -n --argjson r "$RESULTS" --argjson caught "$CAUGHT" --argjson seeded "$SEEDED" \
  --argjson fa "$FALSE_ACCEPT" --argjson ab "$ABSTAINED" \
  --argjson named "$NAMED" --argjson noans "$NO_ANSWER" --argjson cut "$CUT_OFF" \
  --arg model "$(jq -r '.roles.judge.model' "$PIPE/roles.json")" \
  --arg digest "$(ollama list 2>/dev/null | awk -v m="$(jq -r '.roles.judge.model' "$PIPE/roles.json")" '$1==m{print $2;exit}')" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson passes "$REPEAT" \
  '{schema:"judge-fitness/1.0.0", measured_at:$ts,
    judge:{model:$model, digest:$digest},
    passes:$passes,
    one_pass_is_not_a_measurement: ($passes < 2),
    seeded_defects:$seeded, rejected:$caught, named_the_defect:$named,
    false_accepts:$fa, abstentions:$ab, no_answer:$noans, cut_off_by_token_budget:$cut,
    complete: ($cut == 0),
    reject_rate: (if $seeded > 0 then (($caught*100/$seeded)|floor) else null end),
    named_rate: (if $seeded > 0 then (($named*100/$seeded)|floor) else null end),
    false_accept_rate: (if $seeded > 0 then (($fa*100/$seeded)|floor) else null end),
    cases:$r}' > "$OUT"

if [ "$REPEAT" -gt 1 ]; then
  printf '\nper case, across %s passes — the spread is the point:\n\n' "$REPEAT"
  printf '%-28s %-34s %s\n' CASE VERDICTS NAMED-THE-DEFECT
  while IFS='|' read -r name _ _ _; do
    [ -n "$name" ] || continue
    [ -n "$ONLY" ] && [ "$ONLY" != "$name" ] && continue
    printf '%-28s %-34s %s\n' "$name" \
      "$(jq -r --arg n "$name" '[.[] | select(.case == $n) | .verdict] | group_by(.) | map("\(.[0])×\(length)") | join(" ")' <<<"$RESULTS")" \
      "$(jq -r --arg n "$name" '[.[] | select(.case == $n) | .outcome | test("named it")] | "\(map(select(.)) | length)/\(length)"' <<<"$RESULTS")"
  done <<< "$CASES"
  printf '\nA case with more than one verdict in that column is not a result. It is the\n'
  printf 'judge disagreeing with itself on identical input, and no amount of arithmetic\n'
  printf 'over it produces a number worth acting on.\n'
fi

printf '\nof %s seeded defects (%s case(s) × %s pass(es)): rejected %s, NAMED the actual defect %s\n' "$SEEDED" "$((SEEDED / REPEAT))" "$REPEAT" "$CAUGHT" "$NAMED"
printf 'false accepts %s · abstentions %s · no answer at all %s\n' "$FALSE_ACCEPT" "$ABSTAINED" "$NO_ANSWER"
if [ "$CUT_OFF" -gt 0 ]; then
  printf '\nINCOMPLETE — %s case(s) were cut off by the token budget and never judged.\n' "$CUT_OFF"
  printf 'The rates above are computed over a denominator that includes them, so they are\n'
  printf 'lower bounds on a judge that was not allowed to finish. Raise JUDGE_NUM_PREDICT\n'
  printf 'and measure again before comparing this run to another.\n'
fi
printf '%s\n' "$OUT"
printf '\nThe false-accept count is the one that matters. A judge that misses and says\n'
printf 'so costs a retry; a judge that misses and accepts is the failure the line exists\n'
printf 'to prevent, and it is invisible from the outside.\n'
printf '\nONE RUN IS NOT A MEASUREMENT. bench/judge-variance.sh asked this judge the same\n'
printf 'question five times with identical input at temperature 0 and got two different\n'
printf 'verdicts, findings counts of 9, 1, 1 and 4, and a defect that was named in an\n'
printf 'earlier run and missed in all five. Do not compare a number here against another\n'
printf 'number here and conclude something changed: establish the spread first, or the\n'
printf 'comparison is measuring the weather.\n'
[ "$FALSE_ACCEPT" -eq 0 ]
