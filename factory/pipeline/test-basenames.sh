#!/usr/bin/env bash
# test-basenames.sh — would these test files collide under pytest's default import?
#
# usage: test-basenames.sh <repo-root> <path>...
#
# pytest's default import mode (prepend) imports a test file in a directory with
# no __init__.py as a top-level module named after its basename. Two such files
# with one basename — tests/domain/test_locks.py and tests/solver/test_locks.py —
# are one module name, and the whole suite stops at collection with "import file
# mismatch". bean-011's own criteria named exactly that pair; the task that
# first ran the full suite spent three attempts on it, on a path it could not
# write. Nothing about it needs a model to see.
#
# The paths given are the ones a bean or a task list is about to create or use.
# They are compared with each other and with every test file git already tracks.
# Only a collision involving a given path is reported: one already in the tree
# is the tree's problem, and the suite would be failing without this bean.
#
# Not checked when the repository configures --import-mode=importlib, which
# imports by path and has no such collision.
#
# Exit: 0 no collision, or not applicable · 1 a collision (printed) · 2 usage.
set -euo pipefail

[ $# -ge 1 ] || { echo "usage: test-basenames.sh <repo-root> <path>..." >&2; exit 2; }
ROOT="$1"; shift

for cfg in pyproject.toml pytest.ini setup.cfg tox.ini; do
  if [ -f "$ROOT/$cfg" ] && grep -Eq 'import-mode[= ]+importlib' "$ROOT/$cfg"; then
    printf 'test-basenames: not checked — %s sets --import-mode=importlib, which imports by path\n' "$cfg"
    exit 0
  fi
done

is_test() { case "${1##*/}" in test_*.py|*_test.py) return 0 ;; esac; return 1; }

declare -A GIVEN=()
for p in "$@"; do
  p="${p#./}"
  is_test "$p" && GIVEN["$p"]=1
done
[ "${#GIVEN[@]}" -gt 0 ] || { printf 'test-basenames: no test files named\n'; exit 0; }

# A directory is rootless when it has no __init__.py, on disk or among the paths
# this bean is about to create.
declare -A NEW_INIT=()
for p in "$@"; do case "${p##*/}" in __init__.py) NEW_INIT["$(dirname "${p#./}")"]=1 ;; esac; done
rootless() { local d="$1"; [ ! -f "$ROOT/$d/__init__.py" ] && [ -z "${NEW_INIT[$d]:-}" ]; }

declare -A ALL=()
for p in "${!GIVEN[@]}"; do ALL["$p"]=1; done
while IFS= read -r p; do
  [ -n "$p" ] && is_test "$p" && ALL["$p"]=1
done < <(git -C "$ROOT" ls-files -- '*.py' 2>/dev/null || true)

declare -A DIRS=()
for p in "${!ALL[@]}"; do
  d="$(dirname "$p")"
  rootless "$d" || continue
  b="${p##*/}"
  DIRS["$b"]="${DIRS[$b]:-} $p"
done

found=0
for b in "${!DIRS[@]}"; do
  read -r -a files <<<"${DIRS[$b]}"
  [ "${#files[@]}" -gt 1 ] || continue
  hit=0
  for f in "${files[@]}"; do [ -n "${GIVEN[$f]:-}" ] && hit=1; done
  [ "$hit" = 1 ] || continue
  found=1
  printf 'test-basenames: %s is one module name for %s — pytest stops at collection (no __init__.py, default import mode)\n' \
    "${b%.py}" "$(printf '%s\n' "${files[@]}" | sort | paste -sd' ' | sed 's/ / and /g')"
done

if [ "$found" = 1 ]; then
  printf 'test-basenames: rename one, add __init__.py to both directories, or set --import-mode=importlib\n'
  exit 1
fi
printf 'test-basenames: %s test file(s), no basename shared across directories\n' "${#GIVEN[@]}"
