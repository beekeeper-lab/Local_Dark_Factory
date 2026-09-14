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

# Location of Pi's session JSONL files; overridable for tests (PI_SESSIONS_DIR).
pi_sessions_dir() {
  printf '%s\n' "${PI_SESSIONS_DIR:-$HOME/.pi/agent/sessions}"
}
