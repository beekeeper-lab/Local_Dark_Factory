#!/usr/bin/env bash
# test-lib.sh — the helpers every other script in the line is built on.
#
# Nothing here is complicated, which is exactly why it had no tests: each
# function is four lines and obviously right. They are also the functions whose
# quiet misbehaviour is hardest to attribute — a repo_root that answers the wrong
# directory does not fail, it makes a later check measure a different repository,
# and the error surfaces somewhere else entirely.
#
# Two of them carry a decision rather than a convenience. factory_python picks
# the venv over the system interpreter because a schema check that silently
# degrades to "missing deps" is a check that is not happening; repo_root prefers
# the caller's git repository so the tools work on a throwaway one.
set -uo pipefail

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
check() {
  if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}
eq() {
  if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s — expected "%s", got "%s"\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}
rc_is() {
  if [ "$2" = "$3" ]; then printf '  ok    %s (exit %s)\n' "$1" "$3"; PASS=$((PASS+1))
  else printf '  FAIL  %s — expected exit %s, got %s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi
}

# Each case runs in its own bash, because these are shell functions and the point
# is what they do for a caller that sourced them, not what they do here.
call() { # call <script-body> [env assignments applied by the caller]
  printf 'PIPELINE_DIR=%q\nsource "$PIPELINE_DIR/lib.sh"\n%s\n' "$PIPELINE_DIR" "$1" > "$WORK/case.sh"
  bash "$WORK/case.sh" 2>&1
}

REPO="$WORK/repo/nested/deep"; mkdir -p "$REPO"
git init -q -b main "$WORK/repo"
git -C "$WORK/repo" config user.email t@e.com; git -C "$WORK/repo" config user.name T

# --------------------------------------------------------------------------
printf '\n== die says which tool spoke, and stops ==\n\n'
out="$(call 'die "the thing went wrong"')"; rc=$?
rc_is "it exits 1"                     "$rc" 1
check "it names the speaker"           "pipeline: error:" "$out"
check "and what happened"              "the thing went wrong" "$out"
out="$(call 'LOG_PREFIX=gate; die "no"')"
check "the prefix is overridable"      "gate: error:" "$out"
out="$(call 'die "first"; die "second"')"
check "and nothing runs after it"      "first" "$out"
if grep -qF "second" <<<"$out"; then
  printf '  FAIL  die must not return\n'; FAIL=$((FAIL+1))
else printf '  ok    die must not return\n'; PASS=$((PASS+1)); fi

# --------------------------------------------------------------------------
printf '\n== require_cmd and require_args ==\n\n'
out="$(call 'require_cmd definitely-not-a-real-command-here')"; rc=$?
rc_is "a missing command refuses"      "$rc" 1
check "and names it"                   "definitely-not-a-real-command-here" "$out"
out="$(call 'require_cmd jq; echo still-here')"
check "a present one does not"         "still-here" "$out"

out="$(call 'require_args 1 2 "tool <a> <b>"')"; rc=$?
rc_is "too few arguments refuses"      "$rc" 1
check "it shows the usage line"        "usage: tool <a> <b>" "$out"
check "and says how many it wanted"    "expected at least 2" "$out"
out="$(call 'require_args 3 2 "tool <a> <b>"; echo enough')"
check "enough arguments passes"        "enough" "$out"

# --------------------------------------------------------------------------
printf '\n== repo_root prefers the caller'"'"'s repository ==\n\n'
#
# So the tools work against a throwaway repo — which is what every test in this
# directory is, and what the line itself is when it builds another project.
out="$( cd "$REPO" && call 'repo_root' )"
eq "it finds the enclosing repo from a subdirectory" "$(cd "$WORK/repo" && pwd -P)" "$(cd "$out" && pwd -P)"
out="$( cd "$WORK" && call 'repo_root' )"
eq "outside a repo it falls back to the factory" "$(cd "$PIPELINE_DIR/../.." && pwd -P)" "$(cd "$out" && pwd -P)"

printf '\n-- resolve_repo_path --\n\n'
out="$( cd "$REPO" && call 'resolve_repo_path factory/beans' )"
eq "a relative path resolves against the root" "$(cd "$WORK/repo" && pwd -P)/factory/beans" "$out"
out="$( cd "$REPO" && call 'resolve_repo_path /already/absolute' )"
eq "an absolute path passes through"   "/already/absolute" "$out"
# A path that merely starts with a dot is still relative, and was worth checking
# once: the test is `${1#/}` != `$1`, not a guess about leading characters.
out="$( cd "$REPO" && call 'resolve_repo_path ./here' )"
eq "a dotted relative path still resolves" "$(cd "$WORK/repo" && pwd -P)/./here" "$out"

# --------------------------------------------------------------------------
printf '\n== require_config ==\n\n'
out="$(PIPELINE_CONFIG="$WORK/nope.json" call 'require_config')"; rc=$?
rc_is "a missing config refuses"       "$rc" 1
check "and says where it looked"       "$WORK/nope.json" "$out"
printf '{}' > "$WORK/cfg.json"
out="$(PIPELINE_CONFIG="$WORK/cfg.json" call 'require_config; echo ok; echo "$CONFIG_PATH"')"
check "a present one passes"           "ok" "$out"
check "and CONFIG_PATH is the override" "$WORK/cfg.json" "$out"

# --------------------------------------------------------------------------
printf '\n== factory_python prefers the venv over whatever is on PATH ==\n\n'
#
# The factory venv carries jsonschema and PyYAML. The system python3 may carry
# neither, and a schema check that degrades to "missing deps" is a check that is
# not happening — so this is a decision, not a convenience.
VENV="$PIPELINE_DIR/../../.venv/bin/python"
out="$(call 'factory_python')"
if [ -x "$VENV" ]; then
  eq "the venv wins"                   "$(cd "$(dirname "$VENV")" && pwd -P)/python" "$(cd "$(dirname "$out")" && pwd -P)/$(basename "$out")"
else
  printf '  skip  no venv on this box\n'
fi
printf '#!/bin/sh\necho stub\n' > "$WORK/py"; chmod +x "$WORK/py"
out="$(PIPELINE_PYTHON="$WORK/py" call 'factory_python')"
eq "PIPELINE_PYTHON overrides it"      "$WORK/py" "$out"
# The last resort must still be a runnable name rather than an empty string: a
# caller that does `"$(factory_python)" script.py` on an empty value runs the
# script as a command, and fails somewhere unrecognisable.
#
# Reaching that branch means a lib.sh with no venv two directories above it,
# which is a copy somewhere else rather than a PATH trick — emptying PATH would
# take bash with it.
FAKE="$WORK/fakepipe"; mkdir -p "$FAKE"
cp "$PIPELINE_DIR/lib.sh" "$PIPELINE_DIR/VERSION" "$FAKE/"
printf 'PIPELINE_DIR=%q\nsource "$PIPELINE_DIR/lib.sh"\nfactory_python\n' "$FAKE" > "$WORK/fallback.sh"
out="$(bash "$WORK/fallback.sh" 2>&1)"
eq "with no venv it falls back to python3" "$(command -v python3)" "$out"

# --------------------------------------------------------------------------
printf '\n== pi_sessions_dir ==\n\n'
out="$(PI_SESSIONS_DIR="$WORK/sessions" call 'pi_sessions_dir')"
eq "the override is honoured"          "$WORK/sessions" "$out"
out="$(call 'pi_sessions_dir')"
eq "and the default is pi's own"       "$HOME/.pi/agent/sessions" "$out"

# --------------------------------------------------------------------------
printf '\n== executing it directly is not a thing you do ==\n\n'
out="$(bash "$PIPELINE_DIR/lib.sh" 2>&1)"; rc=$?
rc_is "it refuses"                     "$rc" 2
check "and says it is a sourced helper" "sourced helper" "$out"
out="$(bash "$PIPELINE_DIR/lib.sh" --version 2>&1)"; rc=$?
rc_is "except for --version"           "$rc" 0
eq "which is the pipeline's"           "$(cat "$PIPELINE_DIR/VERSION")" "$out"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
