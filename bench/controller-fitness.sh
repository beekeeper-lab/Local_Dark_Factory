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
[ -n "$SPEC" ] && [ -n "$TASKS" ] && [ -n "$BEAN" ] || { usage >&2; exit 1; }
[ -n "$REPO" ] || REPO="$(cd "$(dirname "$BEAN")/../.." && pwd)"
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

# case | should_reject | what a controller catch looks like in its output
CASES='clean|no|
tautological-verify|yes|every verify already passes
contradicts-non-goal|yes|outside the bean
invented-current-behaviour|yes|describes files that are not there
unfinishable-task|yes|
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
  if [ -n "$catchphrase" ] && grep -qiF -- "$catchphrase" <<<"$out"; then
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
  '{schema:"controller-fitness/1.0.0", measured_at:$ts,
    seeded_defects:$seeded, caught_by_name:$caught,
    not_decidable:$missed, false_alarms:$fa, cases:$r,
    note:"Deterministic: no model, no GPU, no variance. A defect counted as caught was named by a check, not merely coincident with a failure."}' > "$OUT"

printf '\nof %s seeded defects: named by a check %s · not decidable %s · false alarms %s\n' \
  "$SEEDED" "$CAUGHT" "$MISSED" "$FALSE_ALARM"
printf '%s\n' "$OUT"
printf '\nThe ones marked not decidable are the judge'"'"'s actual job. Everything above\n'
printf 'them used to be, and was being done badly.\n'
[ "$FALSE_ALARM" -eq 0 ]
