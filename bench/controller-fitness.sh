#!/usr/bin/env bash
# controller-fitness.sh — the same seeded defects, decided without a model.
#
# bench/judge-fitness.sh measures what gpt-oss:120b catches. This measures what
# the controller catches on the identical cases, and the two together are the
# only honest way to say whether moving a rubric item out of the judge was worth
# doing.
#
# It is not a fair fight and is not meant to be. A script can only see the
# defects that are decidable, and the point of the exercise is to find out how
# many of them there are — because every one the controller settles is one the
# judge is no longer spending its attention, and its attention was demonstrably
# the scarce resource.
#
# No GPU, no model, no variance. Run it as often as you like.
set -uo pipefail
# Run from a copy, always, without anyone having to remember.
#
# bash reads a script by byte offset as it executes, so editing one mid-run
# corrupts the run in progress. A three-pass measurement is seventy-five minutes
# — exactly the window in which someone improves the script — and on 2026-09-16
# that produced a zero-byte results file from a run whose numbers survived only
# because they had been printed to a terminal.
#
# `bench/snapshot.sh` existed for a day and was used once, by hand. A protection
# that depends on remembering it is not a protection, so the harness re-execs
# itself through the launcher. FACTORY_NO_SNAPSHOT=1 opts out, for iterating on
# the harness where seeing a change take effect is the point.
if [ "${FACTORY_BENCH_SNAPSHOTTED:-0}" != 1 ] && [ "${FACTORY_NO_SNAPSHOT:-0}" != 1 ]; then
  exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/snapshot.sh" \
    "$(basename "${BASH_SOURCE[0]}")" "$@"
fi

# Every figure carries where and on what it was measured. One emitter, because
# two lists of what a figure must record is one list that disagrees with itself.
# shellcheck source=provenance.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/provenance.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIPE="$ROOT/factory/pipeline"

usage() {
  cat <<'EOF'
controller-fitness.sh — what the deterministic checks catch, on the judge's cases.

usage: controller-fitness.sh --spec <spec.md> --tasks <tasks.yaml> --bean <bean.yaml>
                             [--repo <dir>] [--out <results.json>] [--only <case>]

--repo is the repository the spec describes (default: the bean's repo root).
EOF
}

SPEC=""; TASKS=""; BEAN=""; REPO=""; OUT=""; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --spec)  SPEC="${2:?}"; shift 2 ;;
    --tasks) TASKS="${2:?}"; shift 2 ;;
    --bean)  BEAN="${2:?}"; shift 2 ;;
    --repo)  REPO="${2:?}"; shift 2 ;;
    --out)   OUT="${2:?}"; shift 2 ;;
    --only)  ONLY="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
done
# Existence, not just presence. A flag pointing at a file that is not there
# produced a complete set of fitness numbers measured against nothing: the
# mutations applied to an empty spec, the judge answered about it, and the result
# was written to bench/results looking exactly like a real measurement. A harness
# that can fail open is worse than one that fails, because the output is a number
# someone will cite. judge-fitness.sh has always checked this; the three harnesses
# written after it copied the presence check and not the existence check.
for _f in "$SPEC" "$TASKS" "$BEAN"; do
  [ -n "$_f" ] && [ -f "$_f" ] || { usage >&2; printf 'missing input: %s\n' "${_f:-<unset>}" >&2; exit 2; }
done
[ -n "$REPO" ] || REPO="$(cd "$(dirname "$BEAN")/../.." && pwd)"
# The state of the target repository is an input to this measurement, not a
# detail of where it was run from.
#
# `verify can fail` asks whether each task's verification would fail BEFORE the
# task is done. Run against a repo with the bean's work already committed — a
# bean branch left checked out after a run — every verify already passes and the
# clean control fails, which is reported as a false alarm in a check that is
# behaving exactly as designed. A fitness number measured against a tree where
# the work is already done is not a fitness number, so this refuses rather than
# producing one.
if [ -d "$REPO/.git" ] || git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  _branch="$(git -C "$REPO" branch --show-current 2>/dev/null || true)"
  _default="main"
  if [ -f "$REPO/factory/repo.yaml" ]; then
    _default="$("$PIPE/yaml2json.sh" "$REPO/factory/repo.yaml" 2>/dev/null | jq -r '.default_branch // "main"')"
  fi
  if [ "$_branch" != "$_default" ]; then
    printf 'controller-fitness: %s is on "%s", not "%s".\n' "$REPO" "${_branch:-detached}" "$_default" >&2
    printf '  The spec under test describes the state of the base. On a bean branch the\n' >&2
    printf '  work is already committed, every verify already passes, and the clean control\n' >&2
    printf '  fails — which would be recorded as a false alarm in a check that is right.\n' >&2
    exit 2
  fi
  _dirty="$(git -C "$REPO" status --porcelain 2>/dev/null | grep -v ' factory/runs/' || true)"
  if [ -n "$_dirty" ]; then
    printf 'controller-fitness: %s has uncommitted changes; the measurement would be of\n' "$REPO" >&2
    printf '  whatever is in the tree right now: %s\n' "$(printf '%s' "$_dirty" | head -3 | tr '\n' ' ')" >&2
    exit 2
  fi
fi

[ -n "$OUT" ] || OUT="$ROOT/bench/results/controller-fitness-$(date -u +%Y%m%dT%H%M%SZ).json"
mkdir -p "$(dirname "$OUT")"

# The same mutations, from the same file, so the two harnesses cannot drift apart.
# Reading them out of judge-fitness.sh rather than copying them is the whole
# reason a comparison between the two means anything.
mutate() { # mutate <case> <specfile> <tasksfile>
  sed -n '/^mutate() {/,/^}/p' "$ROOT/bench/judge-fitness.sh" > "$TMP/mutate.sh"
  ROOT="$ROOT" bash -c "source '$TMP/mutate.sh'; mutate '$1' '$2' '$3'"
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Frozen, for the reason freeze_inputs gives: these three point outside the
# snapshot this harness re-execs through, and a run long enough to be worth doing
# is long enough for one of them to be edited while it runs.
FROZEN="$TMP/inputs"
BEAN_DIR="$(dirname "$BEAN")"
INPUT_SHAS="$(freeze_inputs "$FROZEN" "spec=$SPEC" "tasks=$TASKS" "bean=$BEAN_DIR")" \
  || { echo "could not freeze the inputs; refusing to measure a moving target" >&2; exit 2; }
SPEC="$FROZEN/$(basename "$SPEC")"
TASKS="$FROZEN/$(basename "$TASKS")"
BEAN="$FROZEN/$(basename "$BEAN_DIR")/$(basename "$BEAN")"

# case | should_reject | what a controller catch looks like in its output
#
# The phrase has to be one the check prints ONLY when it found this defect. It is
# matched against the FAILING output, and the suite asserts that the same words in
# a passing line are not a catch — because "non-goals" is both the name of a check
# and the start of its failure message, and a harness that cannot tell those apart
# scores a miss as a catch.
#
# `unfinishable-task` was blank until 2026-09-16 and read "not decidable from the
# documents, needs a judge". plans-other-beans.sh decides it: the seeded intent is
# "implement the complete seating optimizer: domain models, the CP-SAT solver,
# soft-constraint scoring, the persistence layer, the REST API and the report
# renderer", and soft-constraint scoring is bean-007's title in two words this
# bean never uses about itself.
CASES='clean|no|
tautological-verify|yes|every verify already passes
contradicts-non-goal|yes|contradicts its own non-goal
invented-current-behaviour|yes|describes files that are not there
unfinishable-task|yes|plans work that belongs to another bean
criterion-not-really-met|yes|'

printf '\ncontroller fitness — %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '%-28s %-9s %-8s %s\n' CASE EXPECT CAUGHT WHAT-CAUGHT-IT

RESULTS='[]'; SEEDED=0; CAUGHT=0; MISSED=0; FALSE_ALARM=0

while IFS='|' read -r name should_reject catchphrase; do
  [ -n "$name" ] || continue
  [ -n "$ONLY" ] && [ "$ONLY" != "$name" ] && continue

  RD="$TMP/$name"; mkdir -p "$RD"
  cp "$SPEC" "$RD/spec.md"; cp "$TASKS" "$RD/tasks.yaml"
  printf '{"run_id":"%s","bean":"%s","branch":"b"}\n' "$name" \
    "$("$PIPE/yaml2json.sh" "$BEAN" | jq -r '.id')" > "$RD/run.json"
  mutate "$name" "$RD/spec.md" "$RD/tasks.yaml"

  t0="$(date +%s)"
  # The precheck runs, which means a container runs, which makes this slower and
  # dependent on podman being here. Worth it: the tautological verify is the case
  # the precheck exists for, and a fitness harness that skipped the one check
  # that catches the defect would be measuring its own convenience.
  # SPEC_CHECK_RUN_VERIFIES=0 in the environment still turns it off.
  out="$(cd "$REPO" && PIPELINE_CONFIG="$REPO/factory/pipeline-config.json" \
        bash "$PIPE/spec-check.sh" "$RD" --bean "$BEAN" 2>&1)"
  rc=$?
  t1="$(date +%s)"

  rejected=no; [ "$rc" -ne 0 ] && rejected=yes
  what=""
  # A catch requires a REJECTION. Without this, a catchphrase that also appears in
  # a passing line scores a miss as a catch — and one just did: `non-goals` is in
  # both spec-check's pass line and its failure, so a phrase matching the check's
  # NAME would credit a bean whose non-goals are prose and were never looked at.
  # The phrase now names the failure, and this makes that belt-and-braces: a check
  # that did not refuse did not catch anything, whatever it printed.
  if [ "$rejected" = yes ] && [ -n "$catchphrase" ] && grep -qiF -- "$catchphrase" <<<"$out"; then
    what="$(grep -iF -- "$catchphrase" <<<"$out" | head -1 | sed 's/^ *//' | cut -c1-58)"
  fi

  if [ "$should_reject" = yes ]; then
    SEEDED=$((SEEDED+1))
    if [ -n "$what" ]; then
      CAUGHT=$((CAUGHT+1)); outcome="$what"
    elif [ "$rejected" = yes ]; then
      outcome="rejected, but not for the seeded defect"
    else
      MISSED=$((MISSED+1)); outcome="not decidable from the documents — needs a judge"
    fi
  else
    if [ "$rejected" = yes ]; then
      FALSE_ALARM=$((FALSE_ALARM+1)); outcome="FALSE ALARM — failed the clean control"
    else
      outcome="passed the clean control, correctly"
    fi
  fi

  printf '%-28s %-9s %-8s %s  (%ss)\n' "$name" "$should_reject" "$rejected" "$outcome" "$((t1-t0))"
  RESULTS="$(jq -c --arg n "$name" --arg sr "$should_reject" --arg r "$rejected" \
    --arg o "$outcome" --argjson s "$((t1-t0))" \
    '. + [{case:$n, should_reject:$sr, rejected:$r, outcome:$o, seconds:$s}]' <<<"$RESULTS")"
done <<< "$CASES"

jq -n --argjson r "$RESULTS" --argjson seeded "$SEEDED" --argjson caught "$CAUGHT" \
  --argjson missed "$MISSED" --argjson fa "$FALSE_ALARM" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson inputs "$INPUT_SHAS" \
  --argjson prov "$(provenance_block)" \
    --arg repo_branch "$(git -C "$REPO" branch --show-current 2>/dev/null || echo '-')" \
  --arg repo_head "$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo '-')" \
'{schema:"controller-fitness/1.0.0", measured_at:$ts, provenance:$prov,
    inputs:$inputs,
    measured_against:{repo:$repo_branch, head:$repo_head},
    seeded_defects:$seeded, caught_by_name:$caught,
    not_decidable:$missed, false_alarms:$fa, cases:$r,
    note:"Deterministic: no model, no GPU, no variance. A defect counted as caught was named by a check, not merely coincident with a failure."}' > "$OUT"

printf '\nof %s seeded defects: named by a check %s · not decidable %s · false alarms %s\n' \
  "$SEEDED" "$CAUGHT" "$MISSED" "$FALSE_ALARM"
printf '%s\n' "$OUT"
# "Not decidable" and "not decidable FOR THIS BEAN" are different sentences.
#
# contradicts-non-goal became decidable on 2026-09-16 for any bean that says where
# its non-goals live. Against one whose non_goals are prose there is nothing to
# check, and reporting that as "the judge'"'"'s actual job" would hide a mechanism
# that exists and is simply unused here.
NG_CHECKABLE="$("$PIPE/yaml2json.sh" "$BEAN" 2>/dev/null \
  | jq '[(.non_goals // [])[] | select(type == "object") | select(((.forbidden_paths // []) | length) > 0 or ((.forbidden_imports // []) | length) > 0)] | length' 2>/dev/null || echo 0)"
printf '\nThe ones marked not decidable are the judge'"'"'s actual job. Everything above\n'
printf 'them used to be, and was being done badly.\n'
if [ "${NG_CHECKABLE:-0}" -eq 0 ]; then
  printf '\nExcept contradicts-non-goal, if it is among them: %s declares no non-goal in\n' "$(jq -r '.id // "this bean"' <<<"$("$PIPE/yaml2json.sh" "$BEAN" 2>/dev/null || echo '{}')")"
  printf 'machine-readable form, so there was nothing for the controller to check. The\n'
  printf 'mechanism exists (factory/pipeline/bean-forbids.sh); this bean does not use it.\n'
fi
[ "$FALSE_ALARM" -eq 0 ]
