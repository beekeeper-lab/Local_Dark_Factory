#!/usr/bin/env bash
# lib.sh — shared helpers for the ai/pipeline scripts (errors, args, paths).

# A sourced-only helper: normal callers source this file (after setting
# PIPELINE_DIR). Executed directly it only answers --version.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  _lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  case "${1:-}" in
    --version)
      cat "$_lib_dir/VERSION"
      exit 0
      ;;
    *)
      printf 'usage: lib.sh is a sourced helper (supports --version when executed)\n' >&2
      exit 2
      ;;
  esac
fi

# Must be sourced after PIPELINE_DIR has been set by the calling script.

LOG_PREFIX="${LOG_PREFIX:-pipeline}"

die() {
  printf '%s: error: %s\n' "$LOG_PREFIX" "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command \"$1\" not found in PATH"
}

# require_args <argcount> <minimum> <usage-line>
require_args() {
  if [ "$1" -lt "$2" ]; then
    printf 'usage: %s\n' "$3" >&2
    die "expected at least $2 argument(s), got $1"
  fi
}

# Repo root: prefer the git repository of the current working directory so the
# tools work in a throwaway repo (tests); fall back to this repo.
repo_root() {
  local r
  if r=$(git rev-parse --show-toplevel 2>/dev/null); then
    printf '%s\n' "$r"
  else
    cd "$PIPELINE_DIR/../.." && pwd
  fi
}

# resolve_repo_path <path> — absolute paths pass through; relative ones are
# resolved against the repo root.
resolve_repo_path() {
  if [ "${1#/}" != "$1" ]; then
    printf '%s\n' "$1"
  else
    printf '%s/%s\n' "$(repo_root)" "$1"
  fi
}

# main_root — the target repository's MAIN checkout, even from a linked worktree.
# Phase 4 runs each in-flight bean in its own worktree (worktree.sh), but a bean's
# run records, the state log and the leases belong to the repository, not to one
# checkout of it: the queue, reconciliation and telemetry must all see one set.
main_root() {
  local c
  if c=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
    case "$c" in */.git) printf '%s\n' "${c%/.git}" ;; *) repo_root ;; esac
  else
    repo_root
  fi
}

# runs_root_dir — the config's runs_root, resolved against the main checkout.
runs_root_dir() {
  local rr; rr="$(jq -r '.runs_root' "$CONFIG_PATH")"
  if [ "${rr#/}" != "$rr" ]; then printf '%s\n' "$rr"; else printf '%s/%s\n' "$(main_root)" "$rr"; fi
}

# Config location: overridable for tests, otherwise co-located with the scripts.
CONFIG_PATH="${PIPELINE_CONFIG:-$PIPELINE_DIR/config.json}"

require_config() {
  [ -f "$CONFIG_PATH" ] || die "pipeline config not found: $CONFIG_PATH"
}

# factory_python — the interpreter the pipeline's own Python tools run under.
# The factory's venv carries jsonschema and PyYAML; the system python3 may carry
# neither, and a schema check that silently degrades to "missing deps" is a check
# that is not happening. PIPELINE_PYTHON overrides for tests and odd hosts.
factory_python() {
  local venv="$PIPELINE_DIR/../../.venv/bin/python"
  if [ -n "${PIPELINE_PYTHON:-}" ]; then
    printf '%s\n' "$PIPELINE_PYTHON"
  elif [ -x "$venv" ]; then
    printf '%s\n' "$venv"
  else
    command -v python3 || printf 'python3\n'
  fi
}

# Location of Pi's session JSONL files; overridable for tests (PI_SESSIONS_DIR).
pi_sessions_dir() {
  printf '%s\n' "${PI_SESSIONS_DIR:-$HOME/.pi/agent/sessions}"
}

# verdicts_role <basename> — what a file in a run's verdicts/ directory IS.
#
# Prints one of: verdict, judgement, request, refusal, diagnostic, stray.
#
# Three readers of that directory have now learned this list separately —
# package-check.sh, phase1-audit.sh and the CLI's `factory status` — and each
# learned it by getting it wrong first. `<target>.request.json` raised a blocker
# on every real run; `factory status` printed `verdict: null null` for every
# refusal record within an hour of refusals existing; and package-check called
# `spec.unparseable.json` a misnamed verdict and halted bean-002 at audit-package
# with "the run record contradicts itself" — about a file the judge writes on
# purpose when its answer will not parse.
#
# So the list lives once, here. A new kind of file beside a verdict is a change
# to this function and every reader gets it.
#
#   verdict     <target>.attempt-N.json   — the only thing that authorises anything
#   judgement   what the model said, before the controller stamped it
#   request     what was sent to it: bytes, artifact count, model, context
#   refusal     the controller could not stamp it, and which rule said so
#   diagnostic  the judge kept what it could not use — the unparseable answer,
#               the truncated one, the reasoning behind an empty reply, and the
#               copy of a judgement that failed a rule
#   stray       anything else, which is a real finding: a verdict under a name
#               the driver cannot read is a verdict nobody will act on
verdicts_role() {
  case "$1" in
    *.judgement.json)  printf 'judgement\n' ;;
    *.request.json)    printf 'request\n' ;;
    *.refused.json)    printf 'refusal\n' ;;
    *.unparseable.json|*.truncated.json|*.thinking.txt|*.json.rejected)
                       printf 'diagnostic\n' ;;
    *.attempt-*.json)  printf 'verdict\n' ;;
    *)                 printf 'stray\n' ;;
  esac
}

# ---------------------------------------------------------------------------
# Inference recording (Phase 4 task 13) — opt-in, and identical to before when off.
#
# FACTORY_INFERENCE_RECORD=1 puts inference-recorder.py between this run and the
# model server, so every call's prompt_eval/eval counts and durations land in
# <run>/inference/calls.jsonl. Unset — the default — none of the functions below
# does anything, and the two addresses they answer are the addresses the line
# used before they existed. tests/test-inference-recorder.sh holds both halves.
#
# Two routes to the server and one variable for both: judge.sh speaks HTTP to a
# URL, and the worker's gateway forwards bytes to a host:port. Both read
# FACTORY_INFERENCE_ADDR, which only inference_record_start sets.

# judge_host — the URL judge.sh asks. Unchanged: OLLAMA_HOST, else :11434.
judge_host() {
  if [ -n "${FACTORY_INFERENCE_ADDR:-}" ]; then printf 'http://%s\n' "$FACTORY_INFERENCE_ADDR"
  else printf '%s\n' "${OLLAMA_HOST:-http://127.0.0.1:11434}"; fi
}

# gateway_upstream — where model-gateway.sh forwards. Unchanged: its own default.
gateway_upstream() {
  printf '%s\n' "${FACTORY_INFERENCE_ADDR:-127.0.0.1:11434}"
}

# inference_record_start <run_dir> <bean> [<owner_pid>] — start one recorder for
# this run, once, and export its address. A recorder that will not start is a
# measurement lost, not a step failed: it says so and the run goes on unrecorded,
# because the line must not halt on its own instrumentation.
inference_record_start() {
  [ "${FACTORY_INFERENCE_RECORD:-0}" = 1 ] || return 0
  [ -z "${FACTORY_INFERENCE_ADDR:-}" ] || return 0
  local run="$1" bean="$2" owner="${3:-$$}" d up port _i
  d="$run/inference"
  mkdir -p "$d/requests" 2>/dev/null || { printf 'INFER  could not create %s; not recording\n' "$d" >&2; return 0; }
  up="${FACTORY_INFERENCE_UPSTREAM:-127.0.0.1:11434}"
  rm -f "$d/port"
  # FACTORY_BEAN as a prefix on this one command, never exported: run-step.sh
  # reads FACTORY_ROLE as an override of the step's model, so the tag
  # environment must not leak into anything but the recorder.
  FACTORY_BEAN="$bean" "$(factory_python)" "$PIPELINE_DIR/inference-recorder.py" serve \
    --listen 127.0.0.1:0 --upstream "$up" --log "$d/calls.jsonl" --requests-dir "$d/requests" \
    --tags-file "$d/tags.json" --port-file "$d/port" --parent-pid "$owner" \
    >>"$d/recorder.log" 2>&1 </dev/null &
  for _i in $(seq 1 50); do [ -s "$d/port" ] && break; sleep 0.1; done
  port="$(cat "$d/port" 2>/dev/null || true)"
  if [ -z "$port" ]; then
    printf 'INFER  the recorder did not start (see %s); this run is not recorded\n' "$d/recorder.log" >&2
    return 0
  fi
  export FACTORY_INFERENCE_ADDR="127.0.0.1:$port"
  export FACTORY_INFERENCE_TAGS="$d/tags.json"
  printf 'INFER  recording %s -> %s into %s\n' "$FACTORY_INFERENCE_ADDR" "$up" "$d/calls.jsonl" >&2
}

# inference_tag <role> <step> [<task>] — say what the next calls are for. The
# worker reaches the server through a byte forwarder and cannot add a header,
# so the controller writes it down before each step and the recorder reads it
# on every call. Nothing happens unless a recorder is running.
inference_tag() {
  [ -n "${FACTORY_INFERENCE_TAGS:-}" ] || return 0
  jq -nc --arg r "$1" --arg s "$2" --arg t "${3:-}" \
    '{role:$r, step:$s} + (if $t == "" then {} else {task:$t} end)' \
    > "$FACTORY_INFERENCE_TAGS.tmp" 2>/dev/null \
    && mv "$FACTORY_INFERENCE_TAGS.tmp" "$FACTORY_INFERENCE_TAGS" 2>/dev/null || true
}
