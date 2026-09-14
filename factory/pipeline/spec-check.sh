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

# ------------------------------------------------------------- 8. render it --
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
