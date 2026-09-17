#!/usr/bin/env bash
# spec-check.sh — the controller's half of the specifying stage (§06 step 2).
#
# The model wrote a document and a task list. This decides whether they are a
# contract: sections present and substantive, task list schema-valid, every
# acceptance criterion claimed, every task inside the bean's paths, every verify
# runnable by a machine, and the whole thing inside the bean's size budget. Then
# it renders the document, because the controller owns the HTML and the model
# never touches it.
#
# Everything here is a check the judge would otherwise spend its attention on.
# The judge's job is whether the plan is *right*; this is whether it is a plan.
set -uo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$PIPELINE_DIR/lib.sh"

SPLIT_RC=6

usage() {
  cat <<'EOF'
spec-check.sh — validate, size-check and render what the specify step produced.

usage: spec-check.sh <run_dir> --bean <bean.yaml> [--templates <dir>]

Checks, in order:
  1. spec.md exists and passes doclint (§07 sections, filled in)
  2. tasks.yaml exists and validates against schemas/task.schema.json
  3. every task's write_paths ⊆ the bean's allowed_write_paths
  3b. and none of them inside a path the bean's non_goals or constraints forbid
  4. every acceptance criterion is claimed by at least one task
  5. no verify the controller cannot run (manual / judge)
  6. dependencies resolve, and there are no cycles
  7. size_budget: max_tasks
  8. renders spec.html from spec.md into the repo's template

Exit: 0 ready to audit · 1 the spec is not a contract yet · 6 size_budget
exceeded (split_required — the bean goes back to a human, not to a retry).
EOF
}

RUN_DIR=""; BEAN_FILE=""; TEMPLATES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --bean)      BEAN_FILE="${2:?}"; shift 2 ;;
    --templates) TEMPLATES="${2:?}"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    --version)   cat "$PIPELINE_DIR/VERSION"; exit 0 ;;
    -*)          usage >&2; die "unknown flag: $1" ;;
    *)           [ -z "$RUN_DIR" ] || die "only one run dir"; RUN_DIR="$1"; shift ;;
  esac
done
[ -n "$RUN_DIR" ] || { usage >&2; exit 1; }
[ -d "$RUN_DIR" ] || die "run directory not found: $RUN_DIR"
[ -n "$BEAN_FILE" ] && [ -f "$BEAN_FILE" ] || die "--bean is required and must exist"
require_cmd jq

ROOT="$(repo_root)"
PY="$(factory_python)"
# Overridable so a test can remove the validator without removing the interpreter
# — pointing PIPELINE_PYTHON at nothing breaks every other Python tool here and
# tests the wrong failure.
VALIDATE="${SPEC_CHECK_VALIDATOR:-$PIPELINE_DIR/../../bench/validate.py}"
[ -n "$TEMPLATES" ] || TEMPLATES="$ROOT/factory/templates"

BEAN_JSON="$("$PIPELINE_DIR/yaml2json.sh" "$BEAN_FILE")" || die "cannot read bean"
BEAN_ID="$(jq -r '.id' <<<"$BEAN_JSON")"

FAILED=0
ok()   { printf '  ok    %-26s %s\n' "$1" "$2"; }
bad()  { printf '  FAIL  %-26s %s\n' "$1" "$2"; FAILED=1; }

printf '\nSPEC CHECK %s\n\n' "$BEAN_ID"

SPEC_MD="$RUN_DIR/spec.md"
TASKS="$RUN_DIR/tasks.yaml"
[ -f "$TASKS" ] || TASKS="$RUN_DIR/tasks.yml"

# ------------------------------------------------------------- 1. the document --
if [ ! -f "$SPEC_MD" ]; then
  bad "spec.md" "not written — the specify step produced no document"
else
  if out="$("$PIPELINE_DIR/doclint.sh" spec "$SPEC_MD" 2>&1)"; then
    ok "spec.md" "$(grep -c '^  ok' <<<"$out") sections present and substantive"
  else
    bad "spec.md" "doclint failed"
    printf '%s\n' "$out" | sed -n '/FAIL/p' | sed 's/^/          /'
  fi
fi

# ------------------------------------------------------------ 2. the task list --
if [ ! -f "$TASKS" ]; then
  bad "tasks.yaml" "not written — the build loop has nothing to run"
  printf '\nSPEC CHECK FAIL\n'
  exit 1
fi
TASKS_JSON="$("$PIPELINE_DIR/yaml2json.sh" "$TASKS")" || { bad "tasks.yaml" "is not parseable YAML"; printf '\nSPEC CHECK FAIL\n'; exit 1; }

if [ -f "$VALIDATE" ] && [ -x "$PY" ]; then
  if out="$("$PY" "$VALIDATE" task "$TASKS" 2>&1)"; then
    ok "tasks.yaml" "validates against task.schema.json"
  else
    bad "tasks.yaml" "does not validate"
    printf '%s\n' "$out" | sed 's/^/          /'
  fi
else
  # Not a note. A run whose task list was never schema-checked produces a record
  # saying the spec was checked, and it was — by a weaker check than anyone
  # reading that record would assume. This printed as a quiet note for a while
  # and a pipeline snapshot duly turned it on without anybody noticing.
  #
  # SPEC_CHECK_ALLOW_NO_SCHEMA=1 for a repo that genuinely has no validator.
  if [ "${SPEC_CHECK_ALLOW_NO_SCHEMA:-0}" = 1 ]; then
    printf '  note  %-26s %s\n' "tasks.yaml" "schema validation skipped (SPEC_CHECK_ALLOW_NO_SCHEMA=1)"
  else
    bad "tasks.yaml" "no schema validator: $VALIDATE with $PY. The task list was NOT
          checked against task.schema.json, and a spec check that skips that quietly is
          worse than one that refuses. Set SPEC_CHECK_ALLOW_NO_SCHEMA=1 to accept it."
  fi
fi

N_TASKS="$(jq '.tasks | length' <<<"$TASKS_JSON")"

# ------------------------------------------------- 3. tasks inside the bean --
BEAN_PATHS="$(jq -c '.allowed_write_paths // []' <<<"$BEAN_JSON")"
OUTSIDE=""; UNCHECKED=""
while IFS=$'\t' read -r tid pat; do
  [ -n "$tid" ] || continue
  # Exit 1 is "outside the paths"; exit 2 is contain.py refusing to run. `! cmd`
  # treats them alike, so an unreadable pattern list made every task look out of
  # bounds — a refusal for the wrong reason, which sends the next person to edit
  # a spec that was fine. The same two lines were in build-loop.sh twice.
  crc=0
  printf '%s\n' "$pat" | "$PY" "$PIPELINE_DIR/contain.py" --patterns "$BEAN_PATHS" >/dev/null 2>&1 || crc=$?
  if [ "$crc" -ge 2 ]; then
    UNCHECKED="$UNCHECKED $tid:$pat"
  elif [ "$crc" -ne 0 ]; then
    OUTSIDE="$OUTSIDE $tid:$pat"
  fi
done < <(jq -r '.tasks[] | .id as $i | .write_paths[] | [$i, .] | @tsv' <<<"$TASKS_JSON")
if [ -n "$UNCHECKED" ]; then
  bad "write_paths" "containment could not be computed for:$UNCHECKED — the paths may be fine; the check did not run"
elif [ -n "$OUTSIDE" ]; then
  bad "write_paths" "outside the bean's allowed paths:$OUTSIDE"
else
  ok "write_paths" "every task is inside the bean's $(jq 'length' <<<"$BEAN_PATHS") allowed path(s)"
fi

# ------------------------------------------ 3b. and out of the bean's non-goals --
#
# The same containment question with the sense flipped. A non-goal about a PLACE
# — "no CI workflow files", "no solver code" — is a statement about paths, and a
# task planning to write into one is `contradicts-non-goal`: the seeded defect the
# judge was measured missing 2 times in 3, and which controller-fitness had as
# "not decidable from the documents, needs a judge". It is decidable when the bean
# says where, and here is the cheapest place to decide it — before a model writes
# a line of the work.
NG_PATHS="$(jq -c '[.tasks[].write_paths[]?] | unique' <<<"$TASKS_JSON")"
ng_rc=0
NG_OUT="$("$PIPELINE_DIR/bean-forbids.sh" --bean "$BEAN_FILE" --paths "$NG_PATHS" \
  --json "$RUN_DIR/bean-forbids.json" 2>&1)" || ng_rc=$?
case "$ng_rc" in
  0) if grep -q 'declares none in machine-readable form' <<<"$NG_OUT"; then
       # Not a pass. The bean's non-goals are prose and nothing here looked at
       # them; saying "ok" without that word would claim a check that did not run.
       note_or_ok="$(printf '%s' "$NG_OUT" | sed 's/^bean-forbids: //')"
       ok "bean-forbids" "nothing to check — $note_or_ok"
     else
       ok "bean-forbids" "$(printf '%s' "$NG_OUT" | sed 's/^bean-forbids: //')"
     fi ;;
  1) bad "bean-forbids" "contradicts its own non-goal: $(printf '%s\n' "$NG_OUT" | grep -E '^  - ' | sed 's/^  - //' | paste -sd'; ' -)" ;;
  *) bad "bean-forbids" "could not be checked — $(printf '%s' "$NG_OUT" | head -1)" ;;
esac

# ------------------------------- 3c. is this plan doing a later bean's work? --
#
# The other half of "this task does not belong here", from the other source.
# bean-forbids reads what THIS bean says about itself; this reads the rest of the
# approved set, where every bean says in one line what it is for. The seeded
# defect is `unfinishable-task` — a task whose intent is "implement the complete
# seating optimizer: domain models, the CP-SAT solver, soft-constraint scoring,
# the persistence layer, the REST API and the report renderer" — which
# controller-fitness had as "not decidable from the documents, needs a judge".
#
# It refuses, and the two rules in plans-other-beans.sh are what make that safe:
# a term must be absent from this bean's own vocabulary and present in exactly one
# other bean's title. bean-002's non-goals name bean-003's rule model, and those
# words are therefore its own and cannot match. Measured against the real
# bean-001 task list before this was wired in: no false alarm, where the first
# version of the check raised one immediately on "rules" from ruff's rule list.
# The set is the repository's installed beans, named explicitly rather than
# inferred from where the bean file happens to sit. A harness may hand this a bean
# from a fixture directory — bench/fixtures holds two copies of bean-001 for an
# A/B — and inferring the set from that directory finds one bean, skips it as
# itself, and reports "nothing to compare against". Which is true of the
# directory and false of the run.
POB_ARGS=( --bean "$BEAN_FILE" --tasks "$TASKS" --json "$RUN_DIR/plans-other-beans.json" )
[ -d "$ROOT/factory/beans" ] && POB_ARGS+=( --beans-dir "$ROOT/factory/beans" )
pob_rc=0
POB_OUT="$("$PIPELINE_DIR/plans-other-beans.sh" "${POB_ARGS[@]}" 2>&1)" || pob_rc=$?
case "$pob_rc" in
  0) if grep -q 'no other beans to compare' <<<"$POB_OUT"; then
       ok "plans-other-beans" "nothing to check — this bean set has one bean in it"
     else
       ok "plans-other-beans" "$(printf '%s' "$POB_OUT" | sed 's/^plans-other-beans: //')"
     fi ;;
  1) bad "plans-other-beans" "plans work that belongs to another bean: $(printf '%s\n' "$POB_OUT" | grep -E '^  - ' | sed 's/^  - //' | paste -sd'; ' -)" ;;
  *) bad "plans-other-beans" "could not be checked — $(printf '%s' "$POB_OUT" | head -1)" ;;
esac

# ------------------------------------------- 4. every acceptance criterion claimed --
CLAIMED="$(jq -c '[.tasks[].satisfies // []] | flatten | unique' <<<"$TASKS_JSON")"
UNCLAIMED="$(jq -r --argjson c "$CLAIMED" '[(.acceptance_criteria // [])[].id] - $c | join(", ")' <<<"$BEAN_JSON")"
if [ -n "$UNCLAIMED" ]; then
  bad "acceptance criteria" "claimed by no task: $UNCLAIMED — the bean could pass every task and still fail"
else
  ok "acceptance criteria" "all $(jq '[(.acceptance_criteria // [])[]] | length' <<<"$BEAN_JSON") claimed by a task"
fi
# A task claiming a criterion the bean does not have is a different mistake.
INVENTED="$(jq -r --argjson acs "$(jq -c '[(.acceptance_criteria // [])[].id]' <<<"$BEAN_JSON")" \
  '$acs as $known | [.tasks[].satisfies // [] | .[]] | unique - $known | join(", ")' <<<"$TASKS_JSON")"
[ -z "$INVENTED" ] || bad "acceptance criteria" "tasks claim criteria the bean does not declare: $INVENTED"

# ------------------------------------------------- 5. verifies a machine can run --
UNRUNNABLE="$(jq -r '[.tasks[] | .id as $i | .verify[] | select(.kind == "manual" or .kind == "judge") | "\($i):\(.kind)"] | join(", ")' <<<"$TASKS_JSON")"
if [ -n "$UNRUNNABLE" ]; then
  bad "verify" "the controller cannot run these: $UNRUNNABLE (manual and judge belong on the bean, not in a task list)"
else
  ok "verify" "$(jq '[.tasks[].verify[]] | length' <<<"$TASKS_JSON") check(s), all machine-runnable"
fi

# ------------------------------------------------------------ 6. dependencies --
DEP_ERR="$("$PY" - "$TASKS_JSON" <<'PY' 2>&1
import json, sys
doc = json.loads(sys.argv[1])
ids = [t["id"] for t in doc["tasks"]]
known, problems = set(ids), []
dupes = {i for i in ids if ids.count(i) > 1}
if dupes:
    problems.append("duplicate ids: " + ", ".join(sorted(dupes)))
deps = {t["id"]: list(t.get("depends_on") or []) for t in doc["tasks"]}
for tid, ds in deps.items():
    for d in ds:
        if d not in known:
            problems.append(f"{tid} depends on {d}, which is not in the list")
placed, remaining = set(), list(ids)
while remaining:
    ready = [t for t in remaining if all(d in placed for d in deps[t])]
    if not ready:
        problems.append("dependency cycle among: " + ", ".join(remaining))
        break
    for t in ready:
        placed.add(t); remaining.remove(t)
print("; ".join(problems))
PY
)"
if [ -n "$DEP_ERR" ]; then bad "dependencies" "$DEP_ERR"; else ok "dependencies" "resolve, in order, no cycles"; fi

# ---------------------------------------------------------- 7. the size budget --
MAX_TASKS="$(jq -r '.size_budget.max_tasks // empty' <<<"$BEAN_JSON")"
SPLIT=0
if [ -n "$MAX_TASKS" ] && [ "$N_TASKS" -gt "$MAX_TASKS" ]; then
  bad "size_budget" "$N_TASKS tasks against a budget of $MAX_TASKS — split_required"
  SPLIT=1
else
  ok "size_budget" "$N_TASKS/${MAX_TASKS:-∞} tasks"
fi

# ------------------------------------- 8. how much is the audit asked to read --
#
# The existing size budget counts tasks, which bounds how much WORK a bean is.
# This counts bytes, which bounds how much READING an audit is. They are
# different failures: a bean with three enormous tasks passes the first and fails
# the second, and it is the second that has actually been hurting.
#
# The threshold is `spec_bytes_budget` in the pipeline config and there is no
# default, because a number invented here would be taste presented as policy.
# bench/size-sweep.sh measures where this judge stops finding a defect it can
# otherwise find; that measurement is what the number should come from.
ARTIFACT_BYTES=$(( $(wc -c < "$SPEC_MD" 2>/dev/null || echo 0) \
                 + $(wc -c < "$TASKS" 2>/dev/null || echo 0) \
                 + $(wc -c < "$BEAN_FILE" 2>/dev/null || echo 0) ))
BYTE_BUDGET="$(jq -r '.spec_bytes_budget // empty' "$CONFIG_PATH" 2>/dev/null)"
if [ -z "$BYTE_BUDGET" ]; then
  note_artifacts="$ARTIFACT_BYTES bytes of bean, spec and task list (no budget set)"
  ok "audit reading" "$note_artifacts"
elif [ "$ARTIFACT_BYTES" -gt "$BYTE_BUDGET" ]; then
  bad "audit reading" "$ARTIFACT_BYTES bytes, over the $BYTE_BUDGET budget — split the bean rather than asking one audit to hold all of it"
else
  ok "audit reading" "$ARTIFACT_BYTES bytes, within the $BYTE_BUDGET budget"
fi

# ------------------------- 9. does the spec's account of the code match it? --
#
# "Does the spec claim the code does something it does not?" is in the rubric,
# and one of the seeded defects in bench/judge-fitness.sh is exactly that — a
# Current-behaviour section describing a config module, an environment variable
# and a helper, none of which exist. Across four judge runs, nobody named it.
#
# It does not need a judge. A path named in that section is a claim about a file,
# and whether the file is there is a question for the filesystem.
CLAIMS_JSON="null"
if [ -f "$SPEC_MD" ]; then
  # It exits 1 when it FINDS something, which is the interesting case — so the
  # exit code is not what we read. `|| echo null` here discarded exactly the
  # results the check exists to produce.
  CLAIMS_JSON="$("$PY" "$PIPELINE_DIR/claims-check.py" "$SPEC_MD" --root "$ROOT" --json 2>/dev/null)"
  jq -e . >/dev/null 2>&1 <<<"$CLAIMS_JSON" || CLAIMS_JSON="null"
  MISSING_PATHS="$(jq -r '(.missing_paths // []) | join(", ")' <<<"$CLAIMS_JSON" 2>/dev/null)"
  ABSENT_SYMS="$(jq -r '(.absent_symbols // []) | join(", ")' <<<"$CLAIMS_JSON" 2>/dev/null)"
  WRONGLY_DENIED="$(jq -r '(.said_absent_but_present // []) | join(", ")' <<<"$CLAIMS_JSON" 2>/dev/null)"
  NAMED_N="$(jq -r '(.paths_said_to_exist // []) | length' <<<"$CLAIMS_JSON" 2>/dev/null)"
  MENTIONED_N="$(jq -r '(.paths_only_mentioned // []) | length' <<<"$CLAIMS_JSON" 2>/dev/null)"
  if [ "$(jq -r '.checked // false' <<<"$CLAIMS_JSON")" != true ]; then
    ok "current behaviour" "$(jq -r '.why // "not checked"' <<<"$CLAIMS_JSON")"
  elif [ -n "$MISSING_PATHS" ]; then
    bad "current behaviour" "describes files that are not there: $MISSING_PATHS"
  elif [ -n "$WRONGLY_DENIED" ]; then
    # Reported, never failed. See claims-check.py for why: deciding which noun a
    # negation attaches to is not reliable enough to fail a run on.
    ok "current behaviour" "every file it describes is there; it also calls these absent, and they are not: $WRONGLY_DENIED"
  elif [ -n "$ABSENT_SYMS" ]; then
    # A symbol may be prose, or a name the change is about to introduce. Worth
    # saying, never worth failing on.
    ok "current behaviour" "$NAMED_N claimed path(s) all present; these names occur nowhere in the repo, which may be fine: $ABSENT_SYMS"
  else
    ok "current behaviour" "every file it says exists is there ($NAMED_N claimed, ${MENTIONED_N:-0} mentioned without a claim)"
  fi
  jq -n --argjson c "$CLAIMS_JSON" '{schema:"claims-check/1.0.0", current_behaviour:$c}' \
    > "$RUN_DIR/claims-check.json" 2>/dev/null || true
fi

# -------------------------------- 10. can each verify fail? (run it and see) --
#
# A check that already passes on the unmodified tree cannot demonstrate that the
# task was done. The audit rubric calls that a blocker, and the judge was asked to
# spot it — and measurably does not: shown a task whose only verify was
# `test -d .`, it reported a YAML syntax error. So stop asking. This is
# decidable by running the command, and the controller can run commands.
#
# A pass here is not automatically a defect: a refactor's verify may legitimately
# be "the existing tests still pass". So it is reported, recorded, and handed to
# the judge as a fact rather than being made a hard failure — the deterministic
# half done deterministically, and the judgement left where judgement belongs.
#
# These commands were written by a model and have been through nothing yet — not
# the spec audit, not a human. So they run in the sandbox or they do not run: on
# the host this step would be the one place in the line where model-authored argv
# executes unconfined, and at the earliest stage, before any of the containment
# the rest of the line insists on. Without podman the check is skipped and says
# so, which is a gap in the evidence; running it anyway would be a hole in the
# containment, and a recorded gap is the cheaper of the two.
PRECHECK="[]"
VACUOUS=""
PRECHECK_RAN=0
if [ "${SPEC_CHECK_RUN_VERIFIES:-1}" = 1 ]; then
  SB=()
  PRE_TREE="${FACTORY_SANDBOX_ROOT:-${TMPDIR:-/tmp}}/darkfactory/$(basename "$RUN_DIR")/precheck-tree"
  if [ -f "$ROOT/factory/gates.lock.yaml" ] && command -v podman >/dev/null 2>&1 \
     && "$PIPELINE_DIR/sync-tree.sh" "$ROOT" "$PRE_TREE" --exclude "factory/runs" >/dev/null 2>&1; then
    SB=( --sandbox "$PRE_TREE" --gates "$ROOT/factory/gates.lock.yaml" )
    PRECHECK_RAN=1
  else
    ok "verify can fail" "not checked — no sandbox available, and these commands are not run on the host"
  fi
fi
if [ "$PRECHECK_RAN" = 1 ]; then
  ENVA=()
  while IFS= read -r kv; do [ -n "$kv" ] && ENVA+=( --env "$kv" ); done \
    < <(jq -r '(.sandbox_env // {}) | to_entries[] | "\(.key)=\(.value)"' "$CONFIG_PATH" 2>/dev/null)

  while IFS=$'\t' read -r tid idx vjson; do
    [ -n "$tid" ] || continue
    rc=0
    res="$("$PIPELINE_DIR/verify.sh" "$vjson" --out "$RUN_DIR/precheck-$tid-$idx.log" \
      --timeout 120 ${SB+"${SB[@]}"} ${ENVA+"${ENVA[@]}"} 2>/dev/null)" || rc=$?
    passed=$([ "$rc" -eq 0 ] && echo true || echo false)
    PRECHECK="$(jq -c --arg t "$tid" --argjson i "$idx" --argjson p "$passed" \
      --arg c "$(jq -r '.command // .reason // ""' <<<"$res" 2>/dev/null)" \
      '. + [{task:$t, verify_index:$i, passes_before_the_work:$p, command:$c}]' <<<"$PRECHECK")"
    [ "$passed" = true ] && VACUOUS="$VACUOUS $tid[$idx]"
  done < <(jq -r '.tasks[] | .id as $t | (.verify | to_entries[]) | [$t, (.key|tostring), (.value|tojson)] | @tsv' <<<"$TASKS_JSON")

  # The unit that matters is the TASK, not the individual check. The first real
  # spec this ran against made the distinction for us: task-3's `ruff check .`
  # passes on a scaffold with no Python in it, but its other three verifies do
  # not — so the task is still demonstrable, and failing the spec over that one
  # line would be a false positive on a task list that was fine. A task every one
  # of whose verifies already passes is the actual defect: nothing about it can
  # be shown by running it.
  PRECHECK="$(jq -c 'group_by(.task) | map({task: .[0].task,
      verifies: .,
      every_verify_passes_before_the_work: (map(.passes_before_the_work) | all)})' <<<"$PRECHECK")"
  UNDEMONSTRABLE="$(jq -r '[.[] | select(.every_verify_passes_before_the_work) | .task] | join(", ")' <<<"$PRECHECK")"

  jq -n --argjson p "$PRECHECK" \
    --arg note "Every verify was run against the tree before any task touched it. A verify that passes here passes on the code as it already is, so it cannot show the task was done. One such verify among several is often legitimate — a lint that is green on an empty directory, or a refactor whose check is that existing tests still pass. A task where every verify passes is not: there is nothing about it that running its checks could demonstrate." \
    '{schema:"verify-precheck/1.0.0", note:$note, tasks:$p}' > "$RUN_DIR/verify-precheck.json"

  if [ -n "$UNDEMONSTRABLE" ]; then
    bad "verify can fail" "every verify already passes for: $UNDEMONSTRABLE — nothing these tasks do could be shown by running them"
  elif [ -n "$VACUOUS" ]; then
    ok "verify can fail" "each task has a check that fails first; these do not, which may be fine:$VACUOUS"
  else
    ok "verify can fail" "every verify fails on the unmodified tree, as it must"
  fi
fi

# ------------------------------------------------------------ 11. render it --
if [ -f "$SPEC_MD" ] && [ -f "$TEMPLATES/spec.html" ]; then
  if "$PY" "$PIPELINE_DIR/render-doc.py" "$SPEC_MD" "$TEMPLATES/spec.html" "$RUN_DIR/spec.html" \
      --meta "bean=$BEAN_ID" \
      --meta "tasks=$N_TASKS" \
      --meta "run=$(basename "$RUN_DIR")" >/dev/null 2>&1; then
    ok "spec.html" "rendered from spec.md into the repo's template"
  else
    bad "spec.html" "could not be rendered"
  fi
elif [ ! -f "$TEMPLATES/spec.html" ]; then
  printf '  note  %-26s %s\n' "spec.html" "no template at $TEMPLATES/spec.html; not rendered"
fi

printf '\n'
if [ "$SPLIT" = 1 ]; then
  printf 'SPEC CHECK SPLIT_REQUIRED — %s tasks over the budget. This goes back to a human to\n' "$N_TASKS"
  printf 'be split at intake, not back to the model to be squeezed: a bean that needs thirty\n'
  printf 'tasks will wander whatever the model does with it (§04).\n'
  exit "$SPLIT_RC"
fi
if [ "$FAILED" = 0 ]; then printf 'SPEC CHECK PASS\n'; exit 0; fi
printf 'SPEC CHECK FAIL — the spec is not yet a contract an audit could judge\n'
exit 1
