#!/usr/bin/env bash
# smoke-line.sh — run the real line, with real models, against a scratch repo.
#
# `factory/pipeline/tests/test-full-line.sh` drives every stage with stubs and is
# the right tool for logic. It cannot catch a break BETWEEN two real components,
# and one got through on 2026-09-17: `package-check` treats any `.json` in
# `verdicts/` that is not a judgement and does not match `<target>.attempt-N.json`
# as a misnamed verdict and raises a blocker — and `<target>.request.json`, added
# that morning, is exactly that shape. It would have failed every real run. It was
# found by reading code, because no fixture had ever put a request file in a
# verdicts directory.
#
# So: a throwaway repository, scaffolded from this one, run for real.
#
# Two things this encodes because both cost an attempt the first time:
#
#   an `origin`      preflight refuses a repository it cannot compare to a remote,
#                    so the scratch repo gets a bare one next to it
#   hidden_tests     `hidden_tests.dir` is relative to the config and assumes the
#                    target is a sibling of this repository. A scratch repo in
#                    /tmp is not, and `factory doctor` refuses at once — correctly.
#                    A scratch repo has no hidden suite, so the key is removed.
#
# It is not fast and it is not free: the spec step alone was 941 seconds and 16
# turns of a 27B model. Run it when the pipeline has changed, not on every commit.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

usage() {
  cat <<'EOF'
smoke-line.sh — run the line against a throwaway repo, with real models.

usage: smoke-line.sh [--bean <id>] [--stop-after <step>] [--dir <path>] [--keep]

  --bean        which bean (default: bean-001, the scaffold — smallest real one)
  --stop-after  spec (default), build, gate, doc, … — see `factory run --help`
  --dir         where to build it (default: a fresh mktemp -d)
  --keep        leave the repo and its origin behind; otherwise both are removed
                unless the run failed, in which case they are always kept and the
                path is printed

Exit: 0 the line got where it was told to · 1 it did not · 2 could not set up
EOF
}

BEAN="bean-001"; STOP="spec"; DIR=""; KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --bean)       BEAN="${2:?--bean needs an id}"; shift 2 ;;
    --stop-after) STOP="${2:?--stop-after needs a step}"; shift 2 ;;
    --dir)        DIR="${2:?--dir needs a path}"; shift 2 ;;
    --keep)       KEEP=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) usage >&2; printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

command -v git >/dev/null || { printf 'smoke-line: git is required\n' >&2; exit 2; }
[ -x "$ROOT/factory/bin/factory" ] || { printf 'smoke-line: no factory CLI at %s\n' "$ROOT/factory/bin/factory" >&2; exit 2; }

[ -n "$DIR" ] || DIR="$(mktemp -d "${TMPDIR:-/tmp}/factory-smoke.XXXXXX")"
REPO="$DIR/repo"; ORIGIN="$DIR/origin.git"
mkdir -p "$REPO" || { printf 'smoke-line: cannot write to %s\n' "$DIR" >&2; exit 2; }

printf '\nsmoke: %s\n  bean: %s, stopping after: %s\n\n' "$REPO" "$BEAN" "$STOP"

git init -q --bare "$ORIGIN" || exit 2
git init -q -b main "$REPO"  || exit 2
git -C "$REPO" config user.email smoke@example.invalid
git -C "$REPO" config user.name  "Line Smoke"
printf '# smoke\n\nA throwaway repository for one end-to-end run of the line.\n' > "$REPO/README.md"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m "init"

"$ROOT/factory/scaffold.sh" "$REPO" >/dev/null 2>&1 || { printf 'smoke-line: scaffold failed\n' >&2; exit 2; }

# No hidden suite here, and saying so is better than pointing at one that is not
# there: doctor refuses a dir it cannot find, which is the behaviour that matters
# on a real target and only noise on this one.
if [ -f "$REPO/factory/pipeline-config.json" ]; then
  jq 'del(.hidden_tests)' "$REPO/factory/pipeline-config.json" > "$REPO/.c" \
    && mv "$REPO/.c" "$REPO/factory/pipeline-config.json"
fi

git -C "$REPO" add -A && git -C "$REPO" commit -q -m "scaffold"
git -C "$REPO" remote add origin "$ORIGIN"
git -C "$REPO" push -q -u origin main || { printf 'smoke-line: could not push to the scratch origin\n' >&2; exit 2; }

printf -- '--- doctor ---\n'
( cd "$REPO" && "$ROOT/factory/bin/factory" doctor ) || { printf '\nsmoke-line: the scratch repo is not ready; nothing was run.\n' >&2; exit 2; }

printf -- '\n--- run ---\n'
rc=0
( cd "$REPO" && "$ROOT/factory/bin/factory" run "$BEAN" --stop-after "$STOP" ) || rc=$?

printf '\n'
if [ "$rc" -eq 0 ]; then
  printf 'SMOKE PASS — the line reached %s against a real model.\n' "$STOP"
  [ "$KEEP" = 1 ] && printf 'kept: %s\n' "$DIR" || rm -rf "$DIR"
else
  printf 'SMOKE FAIL (exit %s) — the repo is kept so the run can be read:\n  %s\n' "$rc" "$DIR" >&2
  printf 'Its run directory is under %s/repo/factory/runs.\n' "$DIR" >&2
fi
exit "$rc"
