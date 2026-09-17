#!/usr/bin/env bash
# test-invariants.sh — the independent invariants catch what they claim to catch.
#
# An invariant nobody has seen fail is a comment. Each case here builds a solver
# that is wrong in exactly one way and requires the matching invariant to fail —
# and, just as importantly, requires the others to keep passing, so a failure
# points at something.
#
# The invariants run in the gate container, which is also where the controller
# will run them: an independent check that only works on the author's machine is
# not independent of very much.
set -uo pipefail

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCAFFOLD="$PIPELINE_DIR/../scaffold/factory"
GATES="$SCAFFOLD/gates.lock.yaml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()   { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n          %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }

command -v podman >/dev/null 2>&1 || { echo "podman required" >&2; exit 1; }

TREE="$WORK/tree"
mkdir -p "$TREE/src/seating_planner" "$TREE/factory/invariants"
cp "$SCAFFOLD/invariants/test_seating_invariants.py" "$TREE/factory/invariants/"
cp "$SCAFFOLD/invariants/seating.yaml" "$TREE/factory/invariants/"

# A reference implementation that satisfies every invariant. It exists only to
# prove the invariants are satisfiable and that they fail when broken — it is not
# the seating planner, and nothing ships it.
cat > "$WORK/correct.py" <<'PY'
"""Deterministic reference solver — groups joined by hard same_table rules are
packed into tables largest-first, honouring capacity and different_table rules."""


def solve_from_spec(spec):
    tables = sorted((t["id"], t["capacity"]) for t in spec["tables"])
    eligible = [g["id"] for g in spec["guests"] if g["eligible"]]
    hard = [r for r in spec["rules"] if r.get("hardness") == "hard"]

    parent = {g: g for g in eligible}

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    for r in hard:
        if r["kind"] == "same_table":
            a, b = r["guests"]
            if a in parent and b in parent:
                parent[find(a)] = find(b)

    diff = [tuple(r["guests"]) for r in hard if r["kind"] == "different_table"]
    for a, b in diff:
        if a in parent and b in parent and find(a) == find(b):
            return {"status": "infeasible", "assignments": {}}

    groups = {}
    for g in eligible:
        groups.setdefault(find(g), []).append(g)

    assign, used = {}, {tid: 0 for tid, _ in tables}
    for _root, members in sorted(groups.items(), key=lambda kv: (-len(kv[1]), kv[0])):
        members = sorted(members)
        placed = False
        for tid, cap in tables:
            if used[tid] + len(members) > cap:
                continue
            clash = False
            for a, b in diff:
                if (a in members and assign.get(b) == tid) or (b in members and assign.get(a) == tid):
                    clash = True
                    break
            if clash:
                continue
            for m in members:
                assign[m] = tid
            used[tid] += len(members)
            placed = True
            break
        if not placed:
            return {"status": "infeasible", "assignments": {}}
    return {"status": "feasible", "assignments": assign}
PY

run_invariants() { # run_invariants -> pytest output
  bash "$PIPELINE_DIR/sandbox.sh" --tree "$TREE" --gates "$GATES" \
    --env "PYTHONPATH=/work/src" --timeout 180 \
    -- pytest -q --no-header factory/invariants/test_seating_invariants.py 2>&1
}

use() { cp "$1" "$TREE/src/seating_planner/invariant_api.py"; }
mutate() { # mutate <python-snippet-file>
  cp "$WORK/correct.py" "$TREE/src/seating_planner/invariant_api.py"
  cat "$1" >> "$TREE/src/seating_planner/invariant_api.py"
}

printf '\n== the seam is required, loudly ==\n\n'
rm -f "$TREE/src/seating_planner/invariant_api.py"
: > "$TREE/src/seating_planner/__init__.py"
out="$(run_invariants)"
if grep -q "conformance seam required" <<<"$out"; then ok "a missing seam fails with an explanation"
else bad "a missing seam should fail with the seam contract" "$(tail -5 <<<"$out")"; fi
if grep -qE "^[0-9]+ (skipped|passed)" <<<"$out" && ! grep -q "failed" <<<"$out"; then
  bad "a missing seam must FAIL, not skip or pass" "$(tail -3 <<<"$out")"
else ok "and it does not quietly skip"; fi

printf '\n== a correct solver satisfies every invariant ==\n\n'
use "$WORK/correct.py"
out="$(run_invariants)"
if grep -qE "[0-9]+ passed" <<<"$out" && ! grep -q "failed" <<<"$out"; then
  ok "all invariants pass against a correct implementation"
else bad "the invariants are not satisfiable by a correct solver" "$(tail -12 <<<"$out")"; fi

printf '\n== each invariant catches its own violation ==\n\n'

# Over-fill a table: exactly the silent wrong answer capacity exists to stop.
cat > "$WORK/m1.py" <<'PY'


_base = solve_from_spec


def solve_from_spec(spec):  # noqa: F811
    r = _base(spec)
    if r["status"] == "feasible" and r["assignments"]:
        first_table = sorted({t["id"] for t in spec["tables"]})[0]
        for g in spec["guests"]:
            if g["eligible"]:
                r["assignments"][g["id"]] = first_table
    return r
PY
mutate "$WORK/m1.py"
out="$(run_invariants)"
if grep -q "test_inv_capacity" <<<"$out" && grep -q "capacity is a hard constraint" <<<"$out"; then
  ok "inv-capacity catches an over-filled table"
else bad "inv-capacity did not catch every guest at one table" "$(tail -8 <<<"$out")"; fi

# Seat someone who is not eligible.
cat > "$WORK/m2.py" <<'PY'


_base = solve_from_spec


def solve_from_spec(spec):  # noqa: F811
    r = _base(spec)
    if r["status"] == "feasible":
        for g in spec["guests"]:
            if not g["eligible"]:
                r["assignments"][g["id"]] = sorted({t["id"] for t in spec["tables"]})[0]
                break
    return r
PY
mutate "$WORK/m2.py"
out="$(run_invariants)"
if grep -q "ineligible guests were assigned seats" <<<"$out"; then
  ok "inv-eligibility catches an ineligible guest being seated"
else bad "inv-eligibility missed an ineligible guest" "$(tail -8 <<<"$out")"; fi

# Break a hard rule while staying within capacity.
cat > "$WORK/m3.py" <<'PY'


_base = solve_from_spec


def solve_from_spec(spec):  # noqa: F811
    r = _base(spec)
    if r["status"] != "feasible":
        return r
    at = r["assignments"]
    for rule in spec["rules"]:
        if rule.get("hardness") == "hard" and rule["kind"] == "same_table":
            a, b = rule["guests"]
            if a in at and b in at:
                others = sorted({t["id"] for t in spec["tables"]} - {at[a]})
                if others:
                    at[b] = others[0]
                    break
    return r
PY
mutate "$WORK/m3.py"
out="$(run_invariants)"
if grep -q "hard same_table rule broken" <<<"$out"; then
  ok "inv-hard-rules catches a broken hard rule"
else bad "inv-hard-rules missed a separated same_table pair" "$(tail -8 <<<"$out")"; fi

# Return a partial chart with an infeasible verdict: reads like progress.
cat > "$WORK/m4.py" <<'PY'


_base = solve_from_spec


def solve_from_spec(spec):  # noqa: F811
    r = _base(spec)
    if r["status"] == "infeasible":
        first_table = sorted({t["id"] for t in spec["tables"]})[0]
        r["assignments"] = {g["id"]: first_table for g in spec["guests"][:1]}
    return r
PY
mutate "$WORK/m4.py"
out="$(run_invariants)"
if grep -q "an infeasible result carried assignments" <<<"$out"; then
  ok "inv-infeasible-is-total catches a partial chart"
else bad "inv-infeasible-is-total missed a partial answer" "$(tail -8 <<<"$out")"; fi

# Non-determinism: the one that invalidates every comparison in the benchmark.
cat > "$WORK/m5.py" <<'PY'

import itertools

_base = solve_from_spec
_counter = itertools.count()


def solve_from_spec(spec):  # noqa: F811
    r = _base(spec)
    if r["status"] == "feasible" and r["assignments"] and next(_counter) % 2 == 1:
        tables = sorted({t["id"] for t in spec["tables"]})
        if len(tables) > 1:
            g = sorted(r["assignments"])[0]
            r["assignments"][g] = tables[1] if r["assignments"][g] == tables[0] else tables[0]
    return r
PY
mutate "$WORK/m5.py"
out="$(run_invariants)"
if grep -q "produced different assignments" <<<"$out"; then
  ok "inv-reproducible catches a non-deterministic solver"
else bad "inv-reproducible missed a solver that answers differently each call" "$(tail -8 <<<"$out")"; fi

printf '\n== and a broken solver does not fail everything indiscriminately ==\n\n'
# The eligibility mutation breaks exactly one invariant. If every invariant fails
# together, a failure tells you nothing about what is wrong.
mutate "$WORK/m2.py"
out="$(run_invariants)"
failed_tests="$(grep -oE "test_inv_[a-z_]+" <<<"$out" | sort -u | tr '\n' ' ')"
if [ "$(grep -oE "test_inv_[a-z_]+" <<<"$out" | sort -u | wc -l)" -le 2 ]; then
  ok "one broken property fails one invariant ($failed_tests)"
else bad "a single fault failed several invariants: $failed_tests" "a failure should point somewhere"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
