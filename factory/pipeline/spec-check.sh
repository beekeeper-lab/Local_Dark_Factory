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
VALIDATE="$PIPELINE_DIR/../../bench/validate.py"
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
  printf '  note  %-26s %s\n' "tasks.yaml" "schema validator unavailable; structural checks only"
fi

N_TASKS="$(jq '.tasks | length' <<<"$TASKS_JSON")"

# ------------------------------------------------- 3. tasks inside the bean --
BEAN_PATHS="$(jq -c '.allowed_write_paths // []' <<<"$BEAN_JSON")"
OUTSIDE=""
while IFS=$'\t' read -r tid pat; do
  [ -n "$tid" ] || continue
  if ! printf '%s\n' "$pat" | "$PY" "$PIPELINE_DIR/contain.py" --patterns "$BEAN_PATHS" >/dev/null 2>&1; then
    OUTSIDE="$OUTSIDE $tid:$pat"
  fi
done < <(jq -r '.tasks[] | .id as $i | .write_paths[] | [$i, .] | @tsv' <<<"$TASKS_JSON")
if [ -n "$OUTSIDE" ]; then
  bad "write_paths" "outside the bean's allowed paths:$OUTSIDE"
else
  ok "write_paths" "every task is inside the bean's $(jq 'length' <<<"$BEAN_PATHS") allowed path(s)"
fi

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

# --------------------------------- 8. can each verify fail? (run it and see) --
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

# ------------------------------------------------------------- 9. render it --
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
