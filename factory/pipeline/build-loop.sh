#!/usr/bin/env bash
# build-loop.sh — the task loop (spec §06 step 5), driven by the controller.
#
# The forked pipeline handed the model an entire spec in one session and hoped.
# That is the single largest reason a 27B fails work a frontier model would
# finish: not that it cannot write the code, but that it cannot hold the whole
# change in its head at once and still keep its promises about scope. §04 says
# so directly, and this loop is the answer:
#
#   for each task, in dependency order:
#     start a worker session with the spec, THIS task, and any prior feedback
#     the worker edits and declares done
#     the controller contains  — any edit outside the task's write_paths means
#                                the WHOLE attempt is rejected and the tree
#                                reset, with scoped feedback (not stripped:
#                                stripping teaches the model that overreach is
#                                free and leaves a diff nobody authored)
#     the controller verifies  — the task's own verify list, run by us, never
#                                by the worker
#     fail → the exact failure output becomes the next prompt, attempt++
#     max_attempts exhausted → the bean is blocked, with the evidence kept
#     verified → commit the task and move to the next one
#
# The model never marks its own task verified. The controller never writes code.
#
# Containment, and what is still open about it. With --sandbox, each task's
# verify list runs inside the pinned gate container against a copy of the tree
# with no .git in it (§06 step 5, §08's sandbox contract) — so a test that writes
# outside the tree, opens a socket, or shells out to git is stopped rather than
# noticed afterwards by an audit.
#
# The WORKER is contained too, as of worker-sandbox.sh: a pinned image with pi in
# it, no routes at all, one unix socket to the model, and an empty directory
# mounted over `.git` so the history it never needed is not there. Its edits still
# land in the real worktree, which is what the scan below reads.
#
# So the reject-and-reset below is no longer the only containment — but it is
# still the one that decides what a task may write, and nothing about a container
# makes it redundant.
#
# The run directory used to be the worst of that: excluded from the change scan
# so the evidence would survive a reset, and therefore the one place a worker
# could write without being seen — the place where the record of what it did is
# kept. It is now hashed before each session and compared after. The attempt's
# own directory is exempt, because that is the worker's channel for BLOCKED.md
# and QUESTIONS.md; the rest of the run dir is the record, and a session that
# alters it blocks the bean without a second attempt.
set -uo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$PIPELINE_DIR/lib.sh"

BLOCKED_RC=4

usage() {
  cat <<'EOF'
build-loop.sh — run one bean's task list, one task at a time.

usage: build-loop.sh <run_dir> --bean <bean.yaml> [options]

  --bean <path>       the bean this task list decomposes (required: its
                      allowed_write_paths bound every task's write_paths, and a
                      loop that cannot read them cannot contain anything)
  --tasks <path>      task list (default: <run_dir>/tasks.yaml, then tasks.json)
  --task <id>         run only this task (its dependencies must already be verified)
  --max-attempts <n>  override every task's max_attempts (default: per task, else 3)
  --sandbox           run each task's verify list inside the pinned gate container
                      against a .git-free copy of the tree (spec §06 step 5)
  --gates <file>      gate manifest naming the image (default: factory/gates.lock.yaml)
  --dry-run           print the plan — order, write paths, verifies — and stop

Exit: 0 every task verified · 4 a task exhausted its attempts (bean blocked,
evidence under <run_dir>/build/) · 1 the loop could not start.

Evidence per attempt, under <run_dir>/build/<task-id>/attempt-<n>/:
  task.json  feedback.md  worker.log  containment.json  verify-<i>.json/.log  result.json
Telemetry: <run_dir>/tasks.jsonl — one line per attempt, one per task outcome.
EOF
}

case "${1:-}" in
  --version) cat "$PIPELINE_DIR/VERSION"; exit 0 ;;
  -h|--help) usage; exit 0 ;;
esac

# ------------------------------------------------------------------ arguments
RUN_DIR=""; BEAN_FILE=""; TASKS_FILE=""; ONLY_TASK=""; MAX_OVERRIDE=""; DRY_RUN=0
SANDBOX=0; GATES_FILE=""; SANDBOX_TREE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --bean)        BEAN_FILE="${2:?--bean needs a path}"; shift 2 ;;
    --tasks)       TASKS_FILE="${2:?--tasks needs a path}"; shift 2 ;;
    --task)        ONLY_TASK="${2:?--task needs a task id}"; shift 2 ;;
    --max-attempts) MAX_OVERRIDE="${2:?--max-attempts needs a number}"; shift 2 ;;
    --dry-run)     DRY_RUN=1; shift ;;
    --sandbox)     SANDBOX=1; shift ;;
    --gates)       GATES_FILE="${2:?--gates needs a file}"; shift 2 ;;
    -*)            usage >&2; die "unknown flag: $1" ;;
    *)             [ -z "$RUN_DIR" ] || die "only one run dir (got '$1' after '$RUN_DIR')"
                   RUN_DIR="$1"; shift ;;
  esac
done
[ -n "$RUN_DIR" ] || { usage >&2; die "missing <run_dir>"; }
require_cmd jq
require_cmd git
[ -d "$RUN_DIR" ] || die "run directory not found: $RUN_DIR"
[ -f "$RUN_DIR/run.json" ] || die "run.json not found in $RUN_DIR"

BEAN_ID="$(jq -r '.bean // empty' "$RUN_DIR/run.json")"
[ -n "$BEAN_ID" ] || die "run.json has no bean id"
ROOT="$(repo_root)"

# ------------------------------------------------------- never on main --
# An authoring step on main means code committed straight to main with no branch
# and no PR. The orchestrator guards this too; the loop refuses independently
# because it is the thing that actually makes the commits.
CUR_BRANCH="$(git -C "$ROOT" branch --show-current 2>/dev/null || true)"
[ -n "$CUR_BRANCH" ] || die "detached HEAD: the build loop commits per task and will not do so without a branch"
[ "$CUR_BRANCH" != "main" ] || die "refusing to run the build loop on main (run branch expected; see run.json .branch)"

# Run dir, relative to the repo root, so it can be excluded from containment and
# protected from `git clean`. Losing the evidence directory to our own reset
# would destroy the record of why a bean blocked.
RUN_DIR_ABS="$(cd "$RUN_DIR" && pwd)"
RUN_DIR_REL=""
case "$RUN_DIR_ABS/" in
  "$ROOT"/*) RUN_DIR_REL="${RUN_DIR_ABS#"$ROOT"/}" ;;
esac

# ------------------------------------------------------------- inputs --
if [ -z "$TASKS_FILE" ]; then
  for cand in "$RUN_DIR/tasks.yaml" "$RUN_DIR/tasks.yml" "$RUN_DIR/tasks.json"; do
    [ -f "$cand" ] && { TASKS_FILE="$cand"; break; }
  done
fi
[ -n "$TASKS_FILE" ] || die "no task list: pass --tasks, or write one to $RUN_DIR/tasks.yaml (the specify step produces it)"
[ -f "$TASKS_FILE" ] || die "task list not found: $TASKS_FILE"
[ -n "$BEAN_FILE" ] || die "--bean is required: every task's write_paths must be bounded by the bean's allowed_write_paths, and the loop will not run a task list it cannot bound"
[ -f "$BEAN_FILE" ] || die "bean file not found: $BEAN_FILE"

TASKS_JSON="$("$PIPELINE_DIR/yaml2json.sh" "$TASKS_FILE")" || die "could not read task list: $TASKS_FILE"
BEAN_JSON="$("$PIPELINE_DIR/yaml2json.sh" "$BEAN_FILE")"   || die "could not read bean: $BEAN_FILE"

sv="$(jq -r '.schema_version // empty' <<<"$TASKS_JSON")"
[ "$sv" = "tasks/1.0.0" ] || die "task list schema_version is '${sv:-missing}', expected tasks/1.0.0"
tb="$(jq -r '.bean_id // empty' <<<"$TASKS_JSON")"
[ -n "$tb" ] || die "task list has no bean_id"
if [ "$(tr '[:upper:]' '[:lower:]' <<<"$tb")" != "$(tr '[:upper:]' '[:lower:]' <<<"$BEAN_ID")" ]; then
  die "task list is for '$tb' but this run is for '$BEAN_ID' — a task list from another bean would contain nothing"
fi
jq -e '.tasks | type == "array" and length > 0' >/dev/null <<<"$TASKS_JSON" \
  || die "task list has no tasks"

BEAN_PATHS_JSON="$(jq -c '.allowed_write_paths // []' <<<"$BEAN_JSON")"
jq -e 'length > 0' >/dev/null <<<"$BEAN_PATHS_JSON" \
  || die "bean $BEAN_ID declares no allowed_write_paths — nothing could be contained"

# ------------------------------------------- order, and the task-list checks --
# Dependency order, cycles, unknown ids and duplicate ids, in one pass. A cycle
# here would otherwise surface as a task that never runs.
ORDER="$(python3 - "$TASKS_JSON" <<'PY'
import json, sys
doc = json.loads(sys.argv[1])
tasks = doc["tasks"]
ids = [t["id"] for t in tasks]
dupes = {i for i in ids if ids.count(i) > 1}
if dupes:
    sys.exit("duplicate task ids: " + ", ".join(sorted(dupes)))
known = set(ids)
deps = {t["id"]: [d for d in (t.get("depends_on") or [])] for t in tasks}
for tid, ds in deps.items():
    for d in ds:
        if d not in known:
            sys.exit(f"task {tid} depends on {d}, which is not in this task list")
# Kahn, preserving authored order among ready tasks so the output is stable.
order, placed = [], set()
remaining = list(ids)
while remaining:
    ready = [t for t in remaining if all(d in placed for d in deps[t])]
    if not ready:
        sys.exit("dependency cycle among: " + ", ".join(remaining))
    for t in ready:
        order.append(t); placed.add(t); remaining.remove(t)
print("\n".join(order))
PY
)" || die "task list is not runnable: $ORDER"

# Every task's write_paths must be bounded by the bean's. This is the early
# warning; the binding check is at containment time on every attempt, where the
# actual changed files are matched against the task's paths AND the bean's.
BAD_PATHS=""
while IFS=$'\t' read -r tid pat; do
  [ -n "$tid" ] || continue
  if ! printf '%s\n' "$pat" | python3 "$PIPELINE_DIR/contain.py" --patterns "$BEAN_PATHS_JSON" >/dev/null 2>&1; then
    BAD_PATHS="$BAD_PATHS
  $tid: $pat"
  fi
done < <(jq -r '.tasks[] | .id as $i | .write_paths[] | [$i, .] | @tsv' <<<"$TASKS_JSON")
[ -z "$BAD_PATHS" ] || die "task write_paths outside the bean's allowed_write_paths ($(jq -rc '.' <<<"$BEAN_PATHS_JSON")):$BAD_PATHS"

# Every AC the bean declares should be claimed by some task. The spec audit owns
# this judgement (§06 step 4), so the loop reports rather than refuses — but it
# says so out loud, because an unclaimed AC is how a bean passes its tasks and
# still fails its acceptance criteria.
UNCLAIMED="$(jq -r --argjson t "$(jq -c '[.tasks[].satisfies // []] | flatten' <<<"$TASKS_JSON")" \
  '[(.acceptance_criteria // [])[].id] - $t | join(", ")' <<<"$BEAN_JSON")"

# The editable tree lives OUTSIDE the repository, which is the point: the
# controller keeps the real worktree on its side of the boundary (§09) and the
# container only ever sees a copy.
if [ "$SANDBOX" = 1 ]; then
  [ -n "$GATES_FILE" ] || GATES_FILE="$ROOT/factory/gates.lock.yaml"
  [ -f "$GATES_FILE" ] || die "--sandbox needs a gate manifest to name the image; not found: $GATES_FILE"
  SANDBOX_TREE="${FACTORY_SANDBOX_ROOT:-${TMPDIR:-/tmp}}/darkfactory/$(basename "$RUN_DIR_ABS")/tree"
  mkdir -p "$SANDBOX_TREE"
  printf 'SANDBOX %s (verifies run in %s)\n' "$SANDBOX_TREE" \
    "$("$PIPELINE_DIR/yaml2json.sh" "$GATES_FILE" | jq -r '.image' | sed 's/@.*//')" >&2
fi

# How this project becomes importable/runnable inside the container. Found the
# hard way: bean-001's acceptance criterion is `python -c "import
# seating_planner"`, and a src-layout package is not importable in a bare synced
# tree — there is no install step and §08 gives the gate no network to do one.
# The developer model spotted that and refused to write a spec around it, which
# was the correct call: it is a hole in the controller, not in the bean.
SANDBOX_ENV_ARGS=()
if [ -f "$CONFIG_PATH" ]; then
  while IFS= read -r kv; do
    [ -n "$kv" ] && SANDBOX_ENV_ARGS+=( --env "$kv" )
  done < <(jq -r '(.sandbox_env // {}) | to_entries[] | "\(.key)=\(.value)"' "$CONFIG_PATH" 2>/dev/null)
fi

TASKS_LOG="$RUN_DIR/tasks.jsonl"
[ -f "$TASKS_LOG" ] || : > "$TASKS_LOG"

log_event() { printf '%s\n' "$1" >> "$TASKS_LOG"; }

task_json() { jq -c --arg i "$1" '.tasks[] | select(.id == $i)' <<<"$TASKS_JSON"; }

task_is_verified() {
  jq -rs --arg i "$1" '[.[] | select(.event == "task" and .task == $i and .result == "verified")] | length > 0' \
    "$TASKS_LOG" 2>/dev/null | grep -q true
}

attempts_so_far() {
  jq -rs --arg i "$1" '[.[] | select(.event == "attempt" and .task == $i)] | length' "$TASKS_LOG" 2>/dev/null || echo 0
}

# ------------------------------------------------------------- dry run --
if [ "$DRY_RUN" = 1 ]; then
  printf 'build loop plan — %s (%s)\n\n' "$BEAN_ID" "$(basename "$TASKS_FILE")"
  n=0
  while IFS= read -r tid; do
    n=$((n+1))
    t="$(task_json "$tid")"
    printf '%2d. %-10s %s\n' "$n" "$tid" "$(jq -r '.title' <<<"$t")"
    printf '      write_paths: %s\n' "$(jq -rc '.write_paths | join(", ")' <<<"$t")"
    printf '      verify:      %s\n' "$(jq -rc '[.verify[] | .kind + (if .run then ": " + (.run|join(" ")) elif .test_id then ": " + .test_id elif .gate_id then ": " + .gate_id else "" end)] | join(" · ")' <<<"$t")"
    printf '      attempts:    %s\n' "${MAX_OVERRIDE:-$(jq -r '.max_attempts // 3' <<<"$t")}"
  done <<< "$ORDER"
  [ -z "$UNCLAIMED" ] || printf '\nwarning: acceptance criteria claimed by no task: %s\n' "$UNCLAIMED"
  exit 0
fi

[ -z "$UNCLAIMED" ] || printf 'WARN   acceptance criteria claimed by no task: %s\n' "$UNCLAIMED" >&2

# ---------------------------------------------------------------- helpers --

# run_verifies <task-json> <attempt-dir> — run the task's whole verify list.
# Returns 0 only if every entry passed. The worker never runs this; the worker's
# own opinion of its work is not evidence.
run_verifies() {
  local t="$1" adir="$2" i=0 n v res rc
  rm -f "$adir/verify-failed.json"
  n="$(jq '.verify | length' <<<"$t")"

  # Sync the tree the container will see. Fresh every attempt: a verify that
  # passed against a leftover file from the attempt before would be evidence
  # about nothing.
  local sb_args=()
  if [ "$SANDBOX" = 1 ]; then
    local ex=( --exclude "factory/runs" )
    [ -n "$RUN_DIR_REL" ] && ex+=( --exclude "$RUN_DIR_REL" )
    "$PIPELINE_DIR/sync-tree.sh" "$ROOT" "$SANDBOX_TREE" "${ex[@]}" >/dev/null \
      || { printf 'VERIFY could not sync the editable tree\n' >&2; return 1; }
    sb_args=( --sandbox "$SANDBOX_TREE" --gates "$GATES_FILE" )
  fi
  while [ "$i" -lt "$n" ]; do
    v="$(jq -c --argjson i "$i" '.verify[$i]' <<<"$t")"
    rc=0
    res="$("$PIPELINE_DIR/verify.sh" "$v" --out "$adir/verify-$((i+1)).log" ${sb_args+"${sb_args[@]}"} ${SANDBOX_ENV_ARGS+"${SANDBOX_ENV_ARGS[@]}"})" || rc=$?
    printf '%s\n' "$res" | jq . > "$adir/verify-$((i+1)).json" 2>/dev/null || printf '%s\n' "$res" > "$adir/verify-$((i+1)).json"
    if [ "$rc" -ne 0 ]; then
      printf '%s\n' "$res" > "$adir/verify-failed.json"
      printf 'VERIFY %s failed (%s)\n' "$(jq -r '.command // .kind' <<<"$res" 2>/dev/null)" \
        "$(jq -r 'if .status == "unrunnable" then "could not be run" else "exit " + (.exit_code|tostring) end' <<<"$res" 2>/dev/null)" >&2
      return 1
    fi
    i=$((i+1))
  done
  return 0
}

# verify_feedback <attempt-dir> — the failed check and its REAL output, which is
# the whole point: a summary of a failure teaches the model to guess.
verify_feedback() {
  local f="$1/verify-failed.json" kind cmd reason
  if [ ! -f "$f" ]; then printf 'The verification did not run.\n'; return 0; fi
  kind="$(jq -r '.kind // "?"' "$f" 2>/dev/null)"
  cmd="$(jq -r '.command // ""' "$f" 2>/dev/null)"
  reason="$(jq -r '.reason // ""' "$f" 2>/dev/null)"
  printf '## The check that failed\n\n'
  printf '    %s\n\n' "${cmd:-(kind: $kind)}"
  if [ -n "$reason" ] && [ "$reason" != "null" ]; then printf '%s\n\n' "$reason"; fi
  printf '## Its output\n\n'
  jq -r '.output_tail[]?' "$f" 2>/dev/null | sed 's/^/    /'
}

# commit_task <id> <title> <attempt> <result> — every hand-off is a commit (§06).
# Only the paths containment already accepted are staged, so a commit can never
# carry something the check did not see.
commit_task() {
  local tid="$1" title="$2" attempt="$3" result="$4"
  local -a paths=()
  mapfile -t paths < <(sed '/^$/d' "$RUN_DIR/build/$tid/attempt-$attempt/changed-paths.txt" 2>/dev/null)
  if [ "${#paths[@]}" -eq 0 ]; then
    printf 'NOTE   %-10s verified with no change — nothing to commit\n' "$tid"
    return 0
  fi
  git -C "$ROOT" add -- "${paths[@]}" || die "could not stage the task's files: ${paths[*]}"
  local msg
  msg="$(printf 'build(%s): %s\n\nbean: %s\nattempt: %s\nresult: %s\nverified by:\n%s\n' \
    "$tid" "$title" "$BEAN_ID" "$attempt" "$result" \
    "$(jq -r '.verify[] | "  - " + (.kind + (if .run then ": " + (.run|join(" ")) elif .test_id then ": " + .test_id elif .gate_id then ": " + .gate_id else "" end))' <<<"$T")")"
  git -C "$ROOT" commit -q -m "$msg" || die "could not commit task $tid"
  printf 'COMMIT %-10s %s\n' "$tid" "$(git -C "$ROOT" rev-parse --short HEAD)"
}

# write_blocked_evidence <task-id> — a blocked bean must arrive with its reasons
# attached. BEAN-127: the record is real evidence, never a stub.
write_blocked_evidence() {
  local tid="$1" bdir="$RUN_DIR/build/$1" ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$bdir"
  {
    printf '# BLOCKED — %s: task `%s` exhausted its attempts\n\n' "$BEAN_ID" "$tid"
    printf -- '- Run directory: `%s`\n' "$RUN_DIR"
    printf -- '- Task: `%s` — %s\n' "$tid" "$(jq -r '.title' <<<"$(task_json "$tid")")"
    printf -- '- Blocked: %s\n\n' "$ts"
    printf '## What the task was allowed to change\n\n'
    jq -r '.write_paths[] | "- `" + . + "`"' <<<"$(task_json "$tid")"
    printf '\n## Every attempt, and how it ended\n\n'
    jq -rs --arg t "$tid" '.[] | select(.event == "attempt" and .task == $t)
      | "- attempt \(.attempt): **\(.result)**" + (if .detail then " — " + .detail else "" end)
        + "\n  - evidence: `\(.evidence)`"' "$TASKS_LOG"
    printf '\n## The last failure, in full\n\n'
    local last
    last="$(ls -1d "$bdir"/attempt-* 2>/dev/null | sort -t- -k2 -n | tail -1)"
    if [ -n "$last" ] && [ -f "$last/verify-failed.json" ]; then
      printf '```\n'
      jq -r '.command // .kind' "$last/verify-failed.json"
      printf '\n'
      jq -r '.output_tail[]?' "$last/verify-failed.json"
      printf '```\n'
    elif [ -n "$last" ] && [ -f "$last/containment.json" ] \
         && [ "$(jq -r '.contained' "$last/containment.json")" = "false" ]; then
      printf 'The last attempt was rejected for writing outside its paths:\n\n'
      jq -r '(.violations_task + .violations_bean) | unique | .[] | "- `" + . + "`"' "$last/containment.json"
    else
      printf 'No verify output was recorded for the final attempt; see `%s`.\n' "${last:-$bdir}"
    fi
    printf '\n## Question for a human\n\n'
    printf 'This task failed %s times. Is the task wrong (badly scoped, missing a path it needs, '  "$(attempts_so_far "$tid")"
    printf 'or verified by a check that cannot pass), or is the work genuinely harder than one '
    printf 'session? The first is a spec problem and belongs back at intake; the second is a '
    printf 'decomposition problem and belongs in the task list.\n'
  } > "$bdir/BLOCKED.md"

  jq -c --arg t "$tid" --arg ts "$ts" \
    '. + {status: "blocked", blocked_task: $t, blocked_at: $ts}' \
    "$RUN_DIR/run.json" > "$RUN_DIR/run.json.tmp" && mv "$RUN_DIR/run.json.tmp" "$RUN_DIR/run.json"
}

# ----------------------------------------------------------- tree state --
# Containment attributes every change since the last verified task to the worker.
# That attribution is only true if the tree is clean when an attempt starts, so a
# dirty tree is refused rather than silently blamed on the model.
changed_paths() { # paths changed vs HEAD, repo-relative, run dir excluded
  git -C "$ROOT" status --porcelain=v1 -uall 2>/dev/null \
    | while IFS= read -r line; do
        p="${line:3}"
        case "$line" in R*|C*) p="${p##* -> }" ;; esac
        p="${p%\"}"; p="${p#\"}"
        [ -n "$p" ] || continue
        if [ -n "$RUN_DIR_REL" ]; then
          case "$p" in "$RUN_DIR_REL"/*|"$RUN_DIR_REL") continue ;; esac
        fi
        printf '%s\n' "$p"
      done
}

# The run directory is excluded from changed_paths above so that the evidence of
# an attempt survives the reset that throws the attempt away. That exclusion is a
# blind spot: a worker writing into the run directory would not be caught, and
# the run directory is where the record of what it did is kept — the one place a
# model with something to hide would most want to reach.
#
# So it is watched instead of ignored. The worker has exactly one legitimate
# destination in there, its own attempt directory: that is its channel for
# BLOCKED.md and QUESTIONS.md, and it is evidence of the attempt rather than of
# the run. Everything else under the run dir is the record, and the only writer
# that may touch it during a session is the controller appending to steps.jsonl.
run_dir_manifest() { # run_dir_manifest <attempt-dir> — hash the record, not the channel
  [ -n "$RUN_DIR_REL" ] || return 0
  local adir="${1:-}"
  find "$RUN_DIR_ABS" -type f -print0 2>/dev/null \
    | while IFS= read -r -d '' f; do
        case "$f" in
          "$RUN_DIR_ABS/steps.jsonl") continue ;;
        esac
        [ -n "$adir" ] && case "$f" in "$adir"/*|"$adir") continue ;; esac
        printf '%s  %s\n' "$(sha256sum < "$f" | cut -d' ' -f1)" "${f#"$RUN_DIR_ABS"/}"
      done | LC_ALL=C sort
}

dirty="$(changed_paths)"
[ -z "$dirty" ] || die "working tree is dirty before the loop starts; containment could not tell your changes from the worker's:
$dirty"

# reset_tree — throw the attempt away. Tracked files restored, untracked removed,
# with the run dir excluded so the evidence of WHY we reset survives the reset.
reset_tree() {
  git -C "$ROOT" checkout -- . 2>/dev/null || true
  if [ -n "$RUN_DIR_REL" ]; then
    git -C "$ROOT" clean -fdq -e "/$RUN_DIR_REL" || true
  else
    git -C "$ROOT" clean -fdq || true
  fi
}

# ------------------------------------------------------------ the loop --
BLOCKED_TASK=""
VERIFIED_COUNT=0
SKIPPED_COUNT=0

while IFS= read -r TID; do
  [ -n "$TID" ] || continue
  if [ -n "$ONLY_TASK" ] && [ "$TID" != "$ONLY_TASK" ]; then continue; fi

  T="$(task_json "$TID")"
  [ -n "$T" ] || die "task '$TID' not found in $TASKS_FILE"
  TITLE="$(jq -r '.title' <<<"$T")"

  if task_is_verified "$TID"; then
    printf 'SKIP   %-10s already verified\n' "$TID"
    SKIPPED_COUNT=$((SKIPPED_COUNT+1))
    continue
  fi

  MAXA="${MAX_OVERRIDE:-$(jq -r '.max_attempts // 3' <<<"$T")}"
  TASK_PATHS_JSON="$(jq -c '.write_paths' <<<"$T")"
  FEEDBACK=""
  VERIFIED=0
  prior="$(attempts_so_far "$TID")"

  printf '\nTASK   %-10s %s (max %s attempts, %s already recorded)\n' "$TID" "$TITLE" "$MAXA" "$prior"

  while [ "$prior" -lt "$MAXA" ]; do
    ATTEMPT=$((prior + 1))
    ADIR="$RUN_DIR/build/$TID/attempt-$ATTEMPT"
    mkdir -p "$ADIR"
    printf '%s\n' "$T" | jq . > "$ADIR/task.json"
    [ -n "$FEEDBACK" ] && printf '%s\n' "$FEEDBACK" > "$ADIR/feedback.md"

    started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    t0="$(date +%s)"

    # -- worker session -------------------------------------------------------
    printf 'ATTEMPT %s/%s  %s\n' "$ATTEMPT" "$MAXA" "$TID"
    RECORD_BEFORE="$(run_dir_manifest "$ADIR")"
    rc=0
    # pipefail is set, so PIPESTATUS[0] is the child's status, not tee's.
    "$PIPELINE_DIR/run-step.sh" "$RUN_DIR" build-task -- "$TID" "$ADIR" 2>&1 | tee "$ADIR/worker.log"
    rc="${PIPESTATUS[0]}"
    t1="$(date +%s)"

    result=""; detail=""
    CHANGED="$(changed_paths)"
    printf '%s\n' "$CHANGED" | sed '/^$/d' > "$ADIR/changed-paths.txt"

    # Did anything reach the record? This is checked before the exit status is
    # even looked at: a session that failed and altered the evidence on its way
    # out is the worse of the two events, and reporting it as "the worker exited
    # non-zero" would bury it.
    TOUCHED_RECORD="$(comm -13 <(printf '%s\n' "$RECORD_BEFORE") <(run_dir_manifest "$ADIR") \
                      | awk '{$1=""; sub(/^ +/, ""); print}' | LC_ALL=C sort -u)"
    if [ -n "$TOUCHED_RECORD" ]; then
      printf '%s\n' "$TOUCHED_RECORD" > "$ADIR/touched-the-record.txt"
      result="tampered"
      detail="the session wrote into the run's evidence directory, outside its own attempt directory: $(printf '%s' "$TOUCHED_RECORD" | tr '\n' ' ')"
      printf '\nTAMPERED  %s attempt %s — the run record was altered:\n' "$TID" "$ATTEMPT" >&2
      printf '%s\n' "$TOUCHED_RECORD" | sed 's/^/  /' >&2
      reset_tree

    elif [ "$rc" -ne 0 ]; then
      result="worker_error"
      detail="The worker session exited non-zero (status $rc) — it did not finish the task."
      FEEDBACK="$(cat <<EOF
# Attempt $ATTEMPT failed: the worker session ended with status $rc

The session did not complete. Nothing was verified. Read the task again, make the
smallest change that satisfies it, and finish the session cleanly.
EOF
)"
      reset_tree

    else
      # -- containment ---------------------------------------------------------
      # Both bounds, every attempt: the task's own paths, and the bean's. The
      # task-list check at startup is an early warning; this is the guarantee.
      VIOL_TASK="$(printf '%s\n' "$CHANGED" | sed '/^$/d' | python3 "$PIPELINE_DIR/contain.py" --patterns "$TASK_PATHS_JSON" || true)"
      VIOL_BEAN="$(printf '%s\n' "$CHANGED" | sed '/^$/d' | python3 "$PIPELINE_DIR/contain.py" --patterns "$BEAN_PATHS_JSON" || true)"
      jq -cn --argjson task_paths "$TASK_PATHS_JSON" --argjson bean_paths "$BEAN_PATHS_JSON" \
        --argjson changed "$(printf '%s\n' "$CHANGED" | sed '/^$/d' | jq -Rsc 'split("\n") | map(select(length > 0))')" \
        --argjson viol_task "$(printf '%s\n' "$VIOL_TASK" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
        --argjson viol_bean "$(printf '%s\n' "$VIOL_BEAN" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
        '{task_write_paths:$task_paths, bean_allowed_write_paths:$bean_paths,
          changed:$changed, violations_task:$viol_task, violations_bean:$viol_bean,
          contained: (($viol_task | length) == 0 and ($viol_bean | length) == 0)}' > "$ADIR/containment.json"

      if [ -n "$VIOL_TASK" ] || [ -n "$VIOL_BEAN" ]; then
        result="containment_violation"
        detail="edits outside the allowed paths: $(printf '%s %s' "$VIOL_TASK" "$VIOL_BEAN" | tr '\n' ' ')"
        FEEDBACK="$(cat <<EOF
# Attempt $ATTEMPT was rejected: it changed files this task may not touch

Your whole attempt was discarded and the tree reset. Nothing you wrote survives —
including the parts that were in scope. This is deliberate: an edit outside the
task's paths is rejected, not quietly stripped, because a diff nobody authored is
worse than no diff at all.

Files you changed that are out of scope:
$(printf '%s\n%s\n' "$VIOL_TASK" "$VIOL_BEAN" | sed '/^$/d' | sort -u | sed 's/^/  - /')

This task may write only:
$(jq -r '.[] | "  - " + .' <<<"$TASK_PATHS_JSON")

And the bean as a whole may write only:
$(jq -r '.[] | "  - " + .' <<<"$BEAN_PATHS_JSON")

If the task genuinely cannot be done inside those paths, do not work around it:
say so plainly in your final message and change nothing. A task that needs paths
it was not given is a spec problem, and a human should see it.
EOF
)"
        reset_tree

      elif [ -z "$(printf '%s' "$CHANGED" | sed '/^$/d')" ]; then
        # No change at all. Run the verify anyway: if it already passes, the task
        # was a no-op and the spec audit should have caught a criterion that is
        # true before the work. Record it loudly rather than blocking on it.
        if run_verifies "$T" "$ADIR"; then
          result="verified_no_changes"
          detail="the task's verify list already passed with no change — the criterion did not require this task"
        else
          result="no_changes"
          detail="the worker changed nothing and the verify list does not pass"
          FEEDBACK="$(cat <<EOF
# Attempt $ATTEMPT changed nothing

No file was modified, and the task's verification does not pass, so the task is
not done. Make the change the task describes.

$(verify_feedback "$ADIR")
EOF
)"
        fi
      else
        # -- verify ------------------------------------------------------------
        if run_verifies "$T" "$ADIR"; then
          result="verified"
        else
          result="verify_failed"
          detail="$(jq -r '.command // .reason // "verify failed"' "$ADIR/verify-failed.json" 2>/dev/null || echo 'verify failed')"
          FEEDBACK="$(cat <<EOF
# Attempt $ATTEMPT did not pass verification

Your edits are kept — fix them in place. This is the real output of the check
that failed, not a summary of it.

$(verify_feedback "$ADIR")

Change only what is needed to make that pass, and stay inside:
$(jq -r '.[] | "  - " + .' <<<"$TASK_PATHS_JSON")
EOF
)"
        fi
      fi
    fi

    dur=$((t1 - t0))
    log_event "$(jq -cn --arg ts "$started" --arg task "$TID" --argjson attempt "$ATTEMPT" \
      --arg result "$result" --arg detail "$detail" --argjson dur "$dur" \
      --arg evidence "$ADIR" --argjson rc "$rc" \
      '{ts:$ts, event:"attempt", task:$task, attempt:$attempt, result:$result,
        detail:(if $detail == "" then null else $detail end), worker_exit:$rc,
        duration_s:$dur, evidence:$evidence}')"
    jq -cn --arg result "$result" --arg detail "$detail" --argjson attempt "$ATTEMPT" \
      '{attempt:$attempt, result:$result, detail:(if $detail == "" then null else $detail end)}' > "$ADIR/result.json"

    case "$result" in
      verified|verified_no_changes)
        commit_task "$TID" "$TITLE" "$ATTEMPT" "$result"
        VERIFIED=1
        printf 'PASS   %-10s verified on attempt %s\n' "$TID" "$ATTEMPT"
        break ;;
      tampered)
        # No second attempt. Every other failure is a thing to give feedback on;
        # this one is a session that reached for the record of what it did, and
        # another go at the same task is not a proportionate answer to it.
        printf 'FAIL   %-10s attempt %s: the run record was altered — not retrying\n' "$TID" "$ATTEMPT"
        break ;;
      *)
        printf 'FAIL   %-10s attempt %s: %s\n' "$TID" "$ATTEMPT" "$result" ;;
    esac
    prior="$ATTEMPT"
  done

  if [ "$VERIFIED" = 1 ]; then
    VERIFIED_COUNT=$((VERIFIED_COUNT+1))
    log_event "$(jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg task "$TID" \
      --argjson attempts "$prior" '{ts:$ts, event:"task", task:$task, result:"verified", attempts:($attempts + 1)}')"
  else
    BLOCKED_TASK="$TID"
    log_event "$(jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg task "$TID" \
      --argjson attempts "$prior" '{ts:$ts, event:"task", task:$task, result:"blocked", attempts:$attempts}')"
    break
  fi
done <<< "$ORDER"

# ------------------------------------------------------------- outcome --
if [ -n "$BLOCKED_TASK" ]; then
  write_blocked_evidence "$BLOCKED_TASK"
  printf '\nBLOCKED  %s exhausted its attempts — evidence in %s/build/%s/\n' \
    "$BLOCKED_TASK" "$RUN_DIR" "$BLOCKED_TASK" >&2
  exit "$BLOCKED_RC"
fi

printf '\nBUILD COMPLETE  %s task(s) verified, %s already done\n' "$VERIFIED_COUNT" "$SKIPPED_COUNT"
exit 0
