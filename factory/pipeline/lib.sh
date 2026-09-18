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
