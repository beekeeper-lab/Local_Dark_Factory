#!/usr/bin/env bash
# verify.sh — run ONE `verify` entry and say plainly whether it passed.
#
# This is the controller's half of the build loop. The worker declares a task
# done; this decides whether it is. The model never runs this against itself and
# never sees its result except as feedback text.
#
# The one rule that matters: **an unsupported or misconfigured verify is a
# failure, never a pass.** A verify the controller cannot run is indistinguishable
# from a criterion nobody checked, and spec §05 exists precisely so that a bean's
# acceptance criteria cannot quietly become opinions. `kind: manual` and
# `kind: judge` are therefore refusals here — they are real kinds, but neither is
# machine-verifiable inside a task loop, so a task list containing one is a spec
# defect the loop must surface rather than absorb.
#
# Output: a JSON result object on stdout; the command's own output goes to the
# file named by --out (and its tail into the result, which is what the worker
# gets fed on the next attempt).
set -uo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$PIPELINE_DIR/lib.sh"

USAGE="verify.sh <verify-json> [--out <file>] [--timeout <seconds>] [--tail <lines>]"
case "${1:-}" in
  --version) cat "$PIPELINE_DIR/VERSION"; exit 0 ;;
  -h|--help)
    cat <<'EOF'
verify.sh — run one `verify` entry from a bean or task list.

usage: verify.sh <verify-json> [--out <file>] [--timeout <seconds>] [--tail <lines>]

<verify-json> is one object from a `verify` array (bean.schema.json#/$defs/verify):

  {"kind":"command","run":["pytest","-q","tests/test_x.py"]}
  {"kind":"test","test_id":"tests/test_x.py::test_y"}
  {"kind":"gate","gate_id":"unit"}

Resolution:
  command  argv is executed directly — no shell, so no quoting surprises.
  test     `test_command` from the pipeline config is the argv prefix and the
           test_id is appended (default: ["pytest","-q"]).
  gate     looked up in the config's `gates` (by name) or a gates manifest
           named by `gates_ref` (by id), and run through bash.
  judge    REFUSED — needs the judge model; it belongs to the gate stage.
  manual   REFUSED — forces human review by definition (spec §05).

Exit: 0 pass · 1 the verify ran and failed · 2 it could not be run at all.
Both non-zero cases are failures for the caller; they are distinguished so the
loop can tell the worker "your code is wrong" apart from "this task list is".

Prints a result object: {kind, status, exit_code, command, duration_s, output_tail, reason}.
EOF
    exit 0 ;;
esac
require_args "$#" 1 "$USAGE"
require_cmd jq

SPEC_JSON="$1"; shift
OUT_FILE=""
TIMEOUT_S=""
TAIL_N=40
SANDBOX_TREE=""
GATES_FILE=""
SANDBOX_ENV=()
while [ $# -gt 0 ]; do
  case "$1" in
    --sandbox) SANDBOX_TREE="${2:?--sandbox needs a tree}"; shift 2 ;;
    --env)     SANDBOX_ENV+=( "${2:?--env needs K=V}" ); shift 2 ;;
    --gates)   GATES_FILE="${2:?--gates needs a file}"; shift 2 ;;
    --out)     OUT_FILE="${2:?--out needs a path}"; shift 2 ;;
    --timeout) TIMEOUT_S="${2:?--timeout needs seconds}"; shift 2 ;;
    --tail)    TAIL_N="${2:?--tail needs a line count}"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

jq -e . >/dev/null 2>&1 <<<"$SPEC_JSON" || die "verify entry is not valid JSON: $SPEC_JSON"
KIND="$(jq -r '.kind // empty' <<<"$SPEC_JSON")"
[ -n "$KIND" ] || die "verify entry has no kind: $SPEC_JSON"

# Config is optional: a bare `kind: command` verify needs nothing from it.
CFG=""
[ -f "$CONFIG_PATH" ] && CFG="$CONFIG_PATH"
cfg_get() { # cfg_get <jq-filter> [default]
  local v=""
  [ -n "$CFG" ] && v="$(jq -r "$1 // empty" "$CFG" 2>/dev/null || true)"
  printf '%s' "${v:-${2:-}}"
}

[ -n "$TIMEOUT_S" ] || TIMEOUT_S="$(cfg_get '.verify_timeout_s' 600)"
[ -n "$OUT_FILE" ] || OUT_FILE="$(mktemp -t verify-XXXXXX.log)"
mkdir -p "$(dirname "$OUT_FILE")"

ROOT="$(repo_root)"

# result <status> <exit-code> <command-string> <reason> — emit and exit.
emit() {
  local status="$1" rc="$2" cmd="$3" reason="${4:-}"
  local dur="${DURATION_S:-0}"
  local tail_json="[]"
  [ -f "$OUT_FILE" ] && tail_json="$(jq -Rcn '[inputs]' < <(tail -n "$TAIL_N" "$OUT_FILE") 2>/dev/null || echo '[]')"
  jq -cn --arg kind "$KIND" --arg status "$status" --argjson rc "$rc" \
    --arg cmd "$cmd" --arg reason "$reason" --argjson dur "$dur" \
    --argjson tail "$tail_json" --arg out "$OUT_FILE" \
    --arg where "$([ -n "$SANDBOX_TREE" ] && echo sandbox || echo host)" \
    '{kind:$kind, status:$status, exit_code:$rc, command:$cmd, ran_in:$where,
      duration_s:$dur, output_file:$out, output_tail:$tail,
      reason:(if $reason == "" then null else $reason end)}'
  case "$status" in
    pass)        exit 0 ;;
    fail)        exit 1 ;;
    unrunnable)  exit 2 ;;
  esac
}

# refuse <reason> — a verify the controller cannot run. Never a pass.
refuse() {
  printf '%s\n' "$1" > "$OUT_FILE"
  emit unrunnable 2 "" "$1"
}

# cmd_string <argv...> — the command as a human (or a model reading its
# feedback) would type it. printf %q is accurate but unreadable: it renders
# `sh -c 'grep -q GOOD src/a.py'` as `sh -c grep\ -q\ GOOD\ src/a.py`, and the
# whole point of feeding the real command back is that it can be read.
cmd_string() {
  local out="" a
  for a in "$@"; do
    if [[ "$a" =~ ^[A-Za-z0-9._/=:@%+-]+$ ]]; then
      out="$out$a "
    else
      out="$out'${a//\'/\'\\\'\'}' "
    fi
  done
  printf '%s' "${out% }"
}

# run_argv <argv...> — execute without a shell and time it.
#
# With --sandbox, this runs inside the gate container instead of on the host,
# which is where §06 step 5 says a task's verify belongs. It matters beyond
# tidiness: a test is code the developer model wrote, and a test that writes
# outside the tree, opens a socket or shells out to git is a test the sandbox
# stops rather than one the audit has to notice afterwards.
run_argv() {
  local start end
  start="$(date +%s%3N)"
  if [ -n "$SANDBOX_TREE" ]; then
    local sb=( "$PIPELINE_DIR/sandbox.sh" --tree "$SANDBOX_TREE" --out "$OUT_FILE" )
    [ -n "$GATES_FILE" ] && sb+=( --gates "$GATES_FILE" )
    [ -n "$TIMEOUT_S" ] && [ "$TIMEOUT_S" != "0" ] && sb+=( --timeout "$TIMEOUT_S" )
    for kv in ${SANDBOX_ENV+"${SANDBOX_ENV[@]}"}; do sb+=( --env "$kv" ); done
    "${sb[@]}" -- "$@" 2>>"$OUT_FILE"
  elif [ -n "$TIMEOUT_S" ] && [ "$TIMEOUT_S" != "0" ] && command -v timeout >/dev/null 2>&1; then
    ( cd "$ROOT" && timeout --signal=TERM --kill-after=10 "$TIMEOUT_S" "$@" ) >"$OUT_FILE" 2>&1
  else
    ( cd "$ROOT" && "$@" ) >"$OUT_FILE" 2>&1
  fi
  local rc=$?
  end="$(date +%s%3N)"
  DURATION_S="$(awk -v a="$start" -v b="$end" 'BEGIN { printf "%.3f", (b - a) / 1000 }')"
  return "$rc"
}

run_shell() { # run_shell <command-string>
  local start end
  start="$(date +%s%3N)"
  if [ -n "$SANDBOX_TREE" ]; then
    local sb=( "$PIPELINE_DIR/sandbox.sh" --tree "$SANDBOX_TREE" --out "$OUT_FILE" )
    [ -n "$GATES_FILE" ] && sb+=( --gates "$GATES_FILE" )
    [ -n "$TIMEOUT_S" ] && [ "$TIMEOUT_S" != "0" ] && sb+=( --timeout "$TIMEOUT_S" )
    for kv in ${SANDBOX_ENV+"${SANDBOX_ENV[@]}"}; do sb+=( --env "$kv" ); done
    "${sb[@]}" -- sh -c "$1" 2>>"$OUT_FILE"
  elif [ -n "$TIMEOUT_S" ] && [ "$TIMEOUT_S" != "0" ] && command -v timeout >/dev/null 2>&1; then
    ( cd "$ROOT" && timeout --signal=TERM --kill-after=10 "$TIMEOUT_S" bash -c "$1" ) >"$OUT_FILE" 2>&1
  else
    ( cd "$ROOT" && bash -c "$1" ) >"$OUT_FILE" 2>&1
  fi
  local rc=$?
  end="$(date +%s%3N)"
  DURATION_S="$(awk -v a="$start" -v b="$end" 'BEGIN { printf "%.3f", (b - a) / 1000 }')"
  return "$rc"
}

case "$KIND" in
  command)
    jq -e '.run | type == "array" and length > 0' >/dev/null 2>&1 <<<"$SPEC_JSON" \
      || refuse "kind: command needs a non-empty 'run' argv array (got: $SPEC_JSON)"
    # NUL-delimited, never newline-delimited. An argv element may contain a
    # newline — `python -c "<script>"` is the commonest verify a spec writes —
    # and `mapfile -t < <(jq -r '.run[]')` turned each line of the script into
    # its own argument, so `python -c` ran the first line and nothing else.
    # bean-004's task-1 verified that way over an AuditLog.entries whose filter
    # branch is a SQL syntax error. --raw-output0 refuses an element that itself
    # contains a NUL, which could not be passed to exec anyway.
    jq -e '.run | all(type == "string")' >/dev/null 2>&1 <<<"$SPEC_JSON" \
      || refuse "kind: command needs 'run' to be an array of strings (got: $SPEC_JSON)"
    ARGV=()
    mapfile -d '' -t ARGV < <(jq --raw-output0 '.run[]' <<<"$SPEC_JSON")
    [ "${#ARGV[@]}" -eq "$(jq '.run | length' <<<"$SPEC_JSON")" ] \
      || refuse "kind: command 'run' did not survive being read as argv (an element with a NUL in it?)"
    # Only meaningful when running on the host: what is on this PATH says nothing
    # about what is in the gate image, and the sandbox reports its own failure.
    if [ -z "$SANDBOX_TREE" ]; then
      command -v "${ARGV[0]}" >/dev/null 2>&1 \
        || refuse "command not found: ${ARGV[0]} — the gate image must provide it (spec §08 pins tool versions)"
    fi
    CMD_STR="$(cmd_string "${ARGV[@]}")"
    rc=0; run_argv "${ARGV[@]}" || rc=$?
    [ "$rc" -eq 0 ] && emit pass 0 "$CMD_STR" || emit fail "$rc" "$CMD_STR"
    ;;

  test)
    TEST_ID="$(jq -r '.test_id // empty' <<<"$SPEC_JSON")"
    [ -n "$TEST_ID" ] || refuse "kind: test needs a test_id"
    # The runner is a property of the stack, not of the bean, so it comes from
    # config. Defaulting to pytest is honest for the python-cpsat corpus and
    # wrong everywhere else — which is why the default is recorded in the result.
    PREFIX_JSON="$(cfg_get '.test_command | tojson' '["pytest","-q"]')"
    ARGV=()
    mapfile -d '' -t ARGV < <(jq --raw-output0 '.[]' <<<"$PREFIX_JSON" 2>/dev/null)
    [ "${#ARGV[@]}" -gt 0 ] || refuse "config test_command is not a non-empty argv array"
    ARGV+=( "$TEST_ID" )
    if [ -z "$SANDBOX_TREE" ]; then
      command -v "${ARGV[0]}" >/dev/null 2>&1 \
        || refuse "test runner not found: ${ARGV[0]} (config test_command)"
    fi
    CMD_STR="$(cmd_string "${ARGV[@]}")"
    rc=0; run_argv "${ARGV[@]}" || rc=$?
    [ "$rc" -eq 0 ] && emit pass 0 "$CMD_STR" || emit fail "$rc" "$CMD_STR"
    ;;

  gate)
    GATE_ID="$(jq -r '.gate_id // empty' <<<"$SPEC_JSON")"
    [ -n "$GATE_ID" ] || refuse "kind: gate needs a gate_id"
    GATE_CMD=""
    [ -n "$CFG" ] && GATE_CMD="$(jq -r --arg g "$GATE_ID" \
      '(.gates // [])[] | select((.name // .id) == $g) | (.command // (.run | join(" ")))' "$CFG" 2>/dev/null | head -1)"
    if [ -z "$GATE_CMD" ]; then
      GATES_REF="$(cfg_get '.gates_ref')"
      if [ -n "$GATES_REF" ] && [ -f "$(resolve_repo_path "$GATES_REF")" ]; then
        GATE_CMD="$("$PIPELINE_DIR/yaml2json.sh" "$(resolve_repo_path "$GATES_REF")" 2>/dev/null \
          | jq -r --arg g "$GATE_ID" '(.gates // [])[] | select((.id // .name) == $g) | (.run // .command)' | head -1)"
      fi
    fi
    [ -n "$GATE_CMD" ] || refuse "gate '$GATE_ID' is not defined in the config's gates or in gates_ref — a task cannot be verified by a gate that does not exist"
    rc=0; run_shell "$GATE_CMD" || rc=$?
    [ "$rc" -eq 0 ] && emit pass 0 "$GATE_CMD" || emit fail "$rc" "$GATE_CMD"
    ;;

  judge)
    refuse "kind: judge cannot run in the build loop — it needs the judge model, and a loop that called the judge per attempt would make the developer's retries depend on a second model's opinion. Judge verifies belong to the gate stage (spec §06 step 6). Move it there or replace it with a machine check."
    ;;

  manual)
    refuse "kind: manual forces human review by definition (spec §05), so it can never be satisfied by a worker attempt. A manual verify in a task list is a spec defect: it belongs on the bean's acceptance criteria, where it flags the bean for a human."
    ;;

  *)
    refuse "unknown verify kind '$KIND' (expected command|test|gate|judge|manual)"
    ;;
esac
