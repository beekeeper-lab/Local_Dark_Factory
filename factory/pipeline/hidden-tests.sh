#!/usr/bin/env bash
# hidden-tests.sh — tests the worker has never seen, run against what it built.
#
# Every other check in this line runs code the worker could read. `allowed_write_paths`
# stops it writing the tests; nothing stops it reading them, and a model that can
# read the assertions it will be measured by can satisfy exactly those and nothing
# else. That is not dishonesty, it is what optimising against a visible objective
# looks like, and the spec's answer is a set of tests that are not in the tree.
#
# So the one thing this script is really about is WHERE the tests live:
#
#   * not in the repository. The worker sandbox mounts the whole tree at /work,
#     so anything in it is readable. A `dir` that resolves inside the repo is
#     refused here and refused again by sandbox.sh; two refusals because this is
#     the property the whole feature is, and it would be quietly lost by a
#     plausible-looking config change.
#   * mounted read-only into the gate container at a path the worker never had,
#     and only there.
#
# The second thing, which is easy to get wrong in the other direction: NOTHING
# the worker can read may quote a hidden test. That is a stronger rule than
# "redact the feedback string", and the difference matters:
#
#   * The run directory is inside the repository, and the worker mounts the whole
#     repository. A full failure log written to <run_dir>/ is a file the worker
#     opens on its next attempt. So the log goes OUTSIDE the repo, beside the
#     hidden tests themselves, and the run directory gets a path to it.
#   * The judge reads gate.json and its findings are fed back to the worker as
#     `feedback_to_worker`. A judge that can see the failing assertion can quote
#     it, in good faith, into the worker's next prompt. So the judge sees the
#     count too, and says what it can say from a count.
#
# What the worker is told is: hidden tests failed, and how many. No names, no
# assertion text, no output.
#
# Not configured is NOT a pass. It is its own status and its own exit code,
# because "this repo has no hidden tests" and "the hidden tests passed" are
# different facts and a gate that reports them the same way is the fail-open this
# project keeps finding.
set -uo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$PIPELINE_DIR/lib.sh"

usage() {
  cat <<'EOF'
hidden-tests.sh — run tests the worker cannot read, against what it built.

usage: hidden-tests.sh <run_dir> [--sandbox] [--gates <file>] [--env K=V]
                       [--tree <dir>]

Configured in the pipeline config under `hidden_tests`:

  "hidden_tests": {
    "dir": "/somewhere/outside/the/repo",
    "command": ["pytest", "-q"],
    "mount_at": "/hidden"
  }

  dir          REQUIRED. Must not be inside the repository: the worker mounts
               the whole tree, so a directory in it is one it can read.
  command      default ["pytest","-q"]; run with the mount point appended.
  mount_at     default /hidden.
  results_dir  where the full output goes. Default: a `hidden-test-results`
               directory beside `dir`. Also refused inside the repository — the
               run directory is in the repo, which is why the log is not there.

Writes <run_dir>/hidden-tests.json (a count, no test text) and the full output to
results_dir, whose path the record names.

Exit: 0 they ran and passed
      1 they ran and FAILED
      2 configured, and could not be run — a refusal, a missing directory, or a
        directory with no tests in it. Never reported as a pass.
      3 not configured for this repository
EOF
}

RUN_DIR=""; SANDBOX=0; GATES=""; TREE=""; ENV_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --sandbox) SANDBOX=1; shift ;;
    --gates)   GATES="${2:?--gates needs a file}"; shift 2 ;;
    --tree)    TREE="${2:?--tree needs a directory}"; shift 2 ;;
    --env)     ENV_ARGS+=( --env "${2:?--env needs K=V}" ); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --version) cat "$PIPELINE_DIR/VERSION"; exit 0 ;;
    -*)        usage >&2; die "unknown flag: $1" ;;
    *)         [ -z "$RUN_DIR" ] && RUN_DIR="$1" || die "unexpected argument: $1"; shift ;;
  esac
done
[ -n "$RUN_DIR" ] || { usage >&2; exit 2; }
[ -d "$RUN_DIR" ] || die "no such run directory: $RUN_DIR"

OUT_JSON="$RUN_DIR/hidden-tests.json"
# LOG is set once the config says where results may be written. It is never under
# $RUN_DIR: that is inside the repository and the worker mounts the repository.
LOG=""

# One writer for the record, so no path can exit without one. A gate that reads
# hidden-tests.json and finds nothing cannot tell "did not run" from "ran and was
# fine", and it is the gate that decides whether the branch moves.
write_record() { # write_record <status> <exit_code> <why> <feedback> [count]
  jq -n --arg st "$1" --argjson ec "$2" --arg why "$3" --arg fb "$4" \
        --arg dir "${HT_DIR:-}" --arg sha "${DIR_SHA:-}" \
        --argjson files "${FILE_COUNT:-0}" \
        --argjson cmd "${CMD_JSON:-[]}" \
        --arg log "${LOG:-}" \
        --argjson failed "${FAILED_N:-0}" \
    '{schema_version:"hidden-tests/2.0.0", status:$st, exit_code:$ec, why:$why,
      dir:$dir, dir_sha256:$sha, test_files:$files, failed_count:$failed,
      command:$cmd,
      output_path:$log,
      worker_feedback:$fb,
      caveat:"This file lives in the run directory, which is inside the repository, which the worker mounts whole. So it carries counts and never test text: no names, no assertions, no output. The full output is at output_path, outside the repository. That also bounds what the judge can quote into feedback_to_worker, which is the other way a hidden test reaches the worker."}' \
    > "$OUT_JSON"
}

CFG_HT=""
if [ -f "$CONFIG_PATH" ]; then
  CFG_HT="$(jq -c '.hidden_tests // empty' "$CONFIG_PATH" 2>/dev/null || true)"
fi
if [ -z "$CFG_HT" ]; then
  write_record not_configured 3 "no hidden_tests block in $CONFIG_PATH" ""
  printf 'hidden tests: not configured for this repository\n'
  exit 3
fi

HT_DIR="$(jq -r '.dir // empty' <<<"$CFG_HT")"
MOUNT_AT="$(jq -r '.mount_at // "/hidden"' <<<"$CFG_HT")"
RESULTS_DIR="$(jq -r '.results_dir // empty' <<<"$CFG_HT")"
CMD_JSON="$(jq -c '.command // ["pytest","-q"]' <<<"$CFG_HT")"

if [ -z "$HT_DIR" ]; then
  write_record could_not_run 2 "hidden_tests is configured with no dir" \
    "The hidden tests could not be run. This is a configuration problem, not yours."
  printf 'hidden tests: REFUSED — hidden_tests has no dir\n' >&2
  exit 2
fi
# Relative to the config file, which is where a reader would expect it to be
# relative to — and which, for a config inside the repo, puts it inside the repo
# and straight into the refusal below. That is the intended lesson.
case "$HT_DIR" in
  /*) ;;
  *)  HT_DIR="$(cd "$(dirname "$CONFIG_PATH")" && pwd)/$HT_DIR" ;;
esac

if [ ! -d "$HT_DIR" ]; then
  write_record could_not_run 2 "hidden_tests.dir does not exist: $HT_DIR" \
    "The hidden tests could not be run. This is a configuration problem, not yours."
  printf 'hidden tests: REFUSED — no such directory: %s\n' "$HT_DIR" >&2
  exit 2
fi
HT_DIR="$(cd "$HT_DIR" && pwd)"

# The property the feature is. sandbox.sh refuses this too; it is checked here as
# well because here is where the message can name the config key, and because a
# run without --sandbox would otherwise never hit the other check.
ROOT="$(repo_root)"
case "$HT_DIR/" in
  "$ROOT"/*)
    write_record could_not_run 2 "hidden_tests.dir is inside the repository ($HT_DIR)" \
      "The hidden tests could not be run. This is a configuration problem, not yours."
    printf 'hidden tests: REFUSED — %s is inside the repository.\n' "$HT_DIR" >&2
    printf '  The worker mounts the whole tree at /work, so a test in it is a test it can\n' >&2
    printf '  read, and a test it can read is one it can satisfy exactly. Put hidden_tests.dir\n' >&2
    printf '  outside %s.\n' "$ROOT" >&2
    exit 2 ;;
esac

# Where the full output may be written. Not the run directory: that is inside the
# repository and the worker mounts the repository, so a failure log there is a
# file the worker opens on its next attempt — which is the whole feature, undone
# by the most natural place to put a log.
[ -n "$RESULTS_DIR" ] || RESULTS_DIR="$(dirname "$HT_DIR")/hidden-test-results"
case "$RESULTS_DIR" in
  /*) ;;
  *)  RESULTS_DIR="$(cd "$(dirname "$CONFIG_PATH")" && pwd)/$RESULTS_DIR" ;;
esac
mkdir -p "$RESULTS_DIR" 2>/dev/null || true
if [ ! -d "$RESULTS_DIR" ]; then
  write_record could_not_run 2 "cannot create hidden_tests.results_dir: $RESULTS_DIR" \
    "The hidden tests could not be run. This is a configuration problem, not yours."
  printf 'hidden tests: REFUSED — cannot create %s\n' "$RESULTS_DIR" >&2
  exit 2
fi
RESULTS_DIR="$(cd "$RESULTS_DIR" && pwd)"
case "$RESULTS_DIR/" in
  "$ROOT"/*)
    write_record could_not_run 2 "hidden_tests.results_dir is inside the repository ($RESULTS_DIR)" \
      "The hidden tests could not be run. This is a configuration problem, not yours."
    printf 'hidden tests: REFUSED — results_dir %s is inside the repository.\n' "$RESULTS_DIR" >&2
    printf '  The worker reads the whole tree. A failure log in it is a hidden test it can read.\n' >&2
    exit 2 ;;
esac
LOG="$RESULTS_DIR/$(basename "$RUN_DIR").log"

# What is actually in there. Counted, and hashed, so the record says which tests
# ran without the record being a copy of them.
FILE_COUNT="$(find "$HT_DIR" -type f -name '*.py' | wc -l)"
DIR_SHA="$(find "$HT_DIR" -type f -exec sha256sum {} + 2>/dev/null | sort -k2 | sha256sum | cut -d' ' -f1)"
if [ "$FILE_COUNT" -eq 0 ]; then
  write_record could_not_run 2 "no test files in $HT_DIR" \
    "The hidden tests could not be run. This is a configuration problem, not yours."
  printf 'hidden tests: REFUSED — %s has no .py test files. An empty hidden suite\n' "$HT_DIR" >&2
  printf '  that reports success is worse than none: it reads as a check that passed.\n' >&2
  exit 2
fi

[ -n "$TREE" ] || TREE="$ROOT"
mapfile -t CMD < <(jq -r '.[]' <<<"$CMD_JSON")
CMD+=( "$MOUNT_AT" )

printf 'hidden tests: %s file(s) from %s, mounted read-only at %s\n' \
  "$FILE_COUNT" "$HT_DIR" "$MOUNT_AT"
printf '  %s\n\n' "${CMD[*]}"

rc=0
if [ "$SANDBOX" = 1 ]; then
  sb=( --tree "$TREE" --mount-ro "$HT_DIR:$MOUNT_AT" --out "$LOG" )
  [ -n "$GATES" ] && sb+=( --gates "$GATES" )
  sb+=( ${ENV_ARGS+"${ENV_ARGS[@]}"} )
  "$PIPELINE_DIR/sandbox.sh" "${sb[@]}" -- "${CMD[@]}" || rc=$?
  # 5 is the sandbox refusing, which is not the tests failing. Conflating the two
  # is this project's most-repeated defect and it does not get to happen here.
  if [ "$rc" = 5 ]; then
    write_record could_not_run 2 "the gate sandbox refused to run them (see $LOG)" \
      "The hidden tests could not be run. This is a configuration problem, not yours."
    printf '\nhidden tests: the sandbox REFUSED — they did not run, and that is not a pass.\n' >&2
    exit 2
  fi
else
  # Uncontained, for tests of this script and for a host run that has already
  # said out loud that it is uncontained. The mount does not exist, so the tests
  # are given their real directory instead.
  CMD[${#CMD[@]}-1]="$HT_DIR"
  ( cd "$TREE" && "${CMD[@]}" ) > "$LOG" 2>&1 || rc=$?
fi

if [ "$rc" -eq 0 ]; then
  write_record passed 0 "$FILE_COUNT hidden test file(s) passed against the built tree" ""
  printf '\nhidden tests: PASS\n'
  exit 0
fi

# The count, and nothing else, is what may go back to the worker.
FAILED_N="$(grep -cE '^(FAILED|ERROR) ' "$LOG" 2>/dev/null || true)"
[ "$FAILED_N" -gt 0 ] 2>/dev/null || FAILED_N=1
write_record failed 1 "hidden tests failed (exit $rc); see $LOG" \
  "$FAILED_N hidden test(s) failed. They are not in the repository and you cannot read them: they were written against the bean's acceptance criteria, not against your implementation. Re-read the criteria and the spec rather than guessing at the assertions."
printf '\nhidden tests: FAIL — %s failing, full output in %s\n' "$FAILED_N" "$LOG" >&2
printf '  The worker is told the count and nothing else.\n' >&2
exit 1
