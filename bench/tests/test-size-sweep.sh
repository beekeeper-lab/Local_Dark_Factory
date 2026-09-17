#!/usr/bin/env bash
# test-size-sweep.sh — the sweep's independent variable has to actually vary.
#
# The sweep pads the artifacts to a series of sizes and asks whether the judge
# still catches a defect. Everything it says rests on the padding being the size
# the table claims. On 2026-09-17 it was not: `--pad-from` pointed at a bean SET
# (flat, `<dir>/bean-001.yaml`) where the glob expected a scaffolded repo
# (`<dir>/<id>/bean.yaml`), so it matched nothing, padded with 161 bytes, and
# printed a full table with rows labelled 10000 and 20000.
#
# Nothing was wrong with the output except that it was not a measurement. That is
# the fail-open shape this project keeps finding, and both halves are asserted
# here: the layout it could not read, and the refusal it did not make.
#
# No model is involved. Every assertion below is reached before the first judge
# call, which is also why they are worth having — the parts of this script that
# need a GPU cannot be tested cheaply, and these parts are where it went wrong.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SWEEP="$ROOT/bench/size-sweep.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
check() { if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
          else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "${3:0:200}"; FAIL=$((FAIL+1)); fi }
rc_is() { if [ "$2" = "$3" ]; then printf '  ok    %s (exit %s)\n' "$1" "$3"; PASS=$((PASS+1))
          else printf '  FAIL  %s — expected exit %s, got %s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi }

SPEC="$ROOT/evidence/bean-001-spec-20260915.md"
TASKS="$ROOT/evidence/bean-001-tasks-20260915.yaml"
CORPUS="$ROOT/benchmark/seating-planner/bean-sets/v1/beans"
BEAN="$ROOT/bench/fixtures/bean-001-annotated.yaml"
if [ ! -f "$SPEC" ] || [ ! -d "$CORPUS" ] || [ ! -f "$BEAN" ]; then
  printf '  SKIP  no corpus or fixtures\n\n0 passed, 0 failed\n'; exit 0
fi

sweep() { FACTORY_NO_SNAPSHOT=1 timeout 60 bash "$SWEEP" --spec "$SPEC" --tasks "$TASKS" --bean "$BEAN" "$@" 2>&1; }

printf '\n== it refuses a sweep it cannot pad to ==\n\n'
# bench/fixtures holds two copies of one bean, which is 161 bytes of padding
# after the bean under test is excluded. Asking for 20,000 from it is asking for
# a measurement that cannot be made.
out="$(sweep --pad-from "$ROOT/bench/fixtures" --sizes '0 20000' --repeat 1 --out "$WORK/a.json")"; rc=$?
rc_is "it exits 2"                    "$rc" 2
check "and says how short it is"      "161 bytes of padding available, 20000 needed" "$out"
check "and names the directory"       "bench/fixtures" "$out"
check "and says what a pad source looks like" "<dir>/<id>/bean.yaml or <dir>/<id>.yaml" "$out"
check "and why it will not proceed"   "would report a sweep that" "$out"
if [ -f "$WORK/a.json" ]; then
  printf '  FAIL  it wrote a results file for a sweep it refused to run\n'; FAIL=$((FAIL+1))
else
  printf '  ok    and writes no results file\n'; PASS=$((PASS+1))
fi

printf '\n== a flat bean set is a pad source, not an empty one ==\n\n'
# The layout that matched nothing. 20 beans, so the padding is tens of kilobytes.
out="$(sweep --pad-from "$CORPUS" --sizes '0' --repeat 1 --out "$WORK/b.json" | head -3)"
have="$(grep -oE 'padding available: [0-9]+' <<<"$out" | grep -oE '[0-9]+')"
if [ -n "$have" ] && [ "$have" -gt 20000 ]; then
  printf '  ok    a flat bean set yields %s bytes\n' "$have"; PASS=$((PASS+1))
else
  printf '  FAIL  a flat bean set yielded %s bytes — the glob is only matching one layout again\n' "${have:-0}"; FAIL=$((FAIL+1))
fi

printf '\n== and the scaffolded layout still is ==\n\n'
# The layout it always read: one directory per bean. Built here rather than
# depending on a target repo being checked out.
SCAF="$WORK/scaffolded"; mkdir -p "$SCAF"
i=0
for b in "$CORPUS"/bean-*.yaml; do
  i=$((i+1)); [ "$i" -gt 6 ] && break
  d="$SCAF/$(basename "$b" .yaml)-slug"; mkdir -p "$d"; cp "$b" "$d/bean.yaml"
done
out="$(sweep --pad-from "$SCAF" --sizes '0' --repeat 1 --out "$WORK/c.json" | head -3)"
have="$(grep -oE 'padding available: [0-9]+' <<<"$out" | grep -oE '[0-9]+')"
if [ -n "$have" ] && [ "$have" -gt 5000 ]; then
  printf '  ok    a scaffolded directory yields %s bytes\n' "$have"; PASS=$((PASS+1))
else
  printf '  FAIL  a scaffolded directory yielded %s bytes\n' "${have:-0}"; FAIL=$((FAIL+1))
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
