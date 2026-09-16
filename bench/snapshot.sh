#!/usr/bin/env bash
# snapshot.sh — run a bench harness from a copy, so editing it mid-run cannot
# corrupt it.
#
# bash reads a script incrementally, by byte offset, while it executes. Rewriting
# one during a run does not take effect next time; it corrupts the run in
# progress, which resumes parsing at an offset that now points into different
# text. `factory run` has snapshotted the pipeline for this reason since
# 2026-09-15, after it happened twice.
#
# The bench harnesses had no such protection and are more exposed, not less: a
# three-pass fitness measurement runs for seventy-five minutes, which is exactly
# the window in which someone improves the script. On 2026-09-16 I added a field
# to judge-fitness.sh while it was measuring, and the run finished normally and
# wrote a ZERO-BYTE results file — the numbers survived only because they had
# been printed to a terminal. An empty artifact is worse than a missing one: it
# sits in bench/results looking like a figure.
#
#   bench/snapshot.sh judge-fitness.sh --spec ... --repeat 3
#
# FACTORY_NO_SNAPSHOT=1 runs from the working tree, for iterating on a harness
# where the point is to see a change take effect.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

usage() { printf 'usage: snapshot.sh <harness.sh> [args...]\n'; }
[ $# -ge 1 ] || { usage >&2; exit 2; }
HARNESS="$1"; shift
case "$HARNESS" in */*) ;; *) HARNESS="$HERE/$HARNESS" ;; esac
[ -f "$HARNESS" ] || { printf 'no such harness: %s\n' "$HARNESS" >&2; exit 2; }

if [ "${FACTORY_NO_SNAPSHOT:-0}" = 1 ]; then
  exec bash "$HARNESS" "$@"
fi

SNAP="$(mktemp -d "${TMPDIR:-/tmp}/factory-bench.XXXXXX")"
# The whole repository layout the harnesses climb through: bench/ for each other
# and the shared helpers, factory/ for judge.sh and roles.json, schemas/ for the
# validator. Copying bench/ alone puts $HERE/../factory somewhere that does not
# exist, which fails in a way that looks like a missing model.
mkdir -p "$SNAP"
cp -r "$ROOT/bench" "$SNAP/bench"
cp -r "$ROOT/factory" "$SNAP/factory"
[ -d "$ROOT/schemas" ] && cp -r "$ROOT/schemas" "$SNAP/schemas"
[ -d "$ROOT/evidence" ] && cp -r "$ROOT/evidence" "$SNAP/evidence"
# Results are written back to the real tree, not into the copy that is about to
# be deleted. Everything else about the run comes from the snapshot.
rm -rf "$SNAP/bench/results"
ln -s "$ROOT/bench/results" "$SNAP/bench/results"
# The venv, by symlink rather than by copy: it is hundreds of megabytes, it is not
# what anyone edits mid-run, and the harnesses reach for it as `$ROOT/.venv/bin/python`.
# Without it every mutation in judge-fitness fails — which the first snapshotted
# run demonstrated, six times in a row.
[ -d "$ROOT/.venv" ] && ln -s "$ROOT/.venv" "$SNAP/.venv"
trap 'rm -rf "$SNAP"' EXIT

printf 'bench snapshot: %s\n' "$SNAP/bench" >&2
cd "$ROOT"
# Everything after the harness call is on this one line, deliberately.
#
# bash reads a script by byte offset as it executes — the reason this launcher
# exists at all — and that applies to the launcher too. On 2026-09-16 a
# seventy-five minute judge-fitness run finished, printed its whole summary and
# wrote its results file, and then this script died with
#
#   bench/snapshot.sh: line 61: unexpected EOF while looking for matching `"'
#
# on a file that is sixty lines long and passes `bash -n`. RC=2, bash's
# syntax-error code, for a measurement that had completely succeeded. What
# rewrote the bytes between the read that started the run and the read that
# should have followed it is NOT identified; nothing in this session edited this
# file, and a short probe harness does not reproduce it.
#
# The cause is open. The consequence is closed: bash has already read this whole
# line before it runs the first command on it, so there is nothing left to read
# after the harness returns, and a successful measurement can no longer be
# reported as a failed launcher.
FACTORY_BENCH_SNAPSHOTTED=1 bash "$SNAP/bench/$(basename "$HARNESS")" "$@"; _rc=$?; trap - EXIT; rm -rf "$SNAP"; exit "$_rc"
