"""Independent invariants for any seating assignment — see seating.yaml.

These were written before the implementation existed, by something other than the
model that will write it, and they live where that model cannot edit them
(`factory/invariants/**` is tier 3 and is not in `repo_allowed_paths`). That is
the whole point: a test the developer wrote and a test the developer could not
touch fail in different ways, and only the second one is evidence about the
developer.

They check properties of the ANSWER, through the one conformance seam
`seating.yaml` declares. They deliberately know nothing about how the solver is
built, which module holds the domain types, or what the internal API looks like.

Randomised, but with a fixed seed: the same cases run every time, so a failure is
reproducible and a run is comparable to the run before it. Finding new cases is
not this file's job — holding the line on known ones is.
"""
from __future__ import annotations

import importlib
import random
from typing import Any

import pytest

SEAM_MODULE = "seating_planner.invariant_api"
SEAM_CALLABLE = "solve_from_spec"

SEAM_MISSING = f"""
The conformance seam required by factory/invariants/seating.yaml is not present.

Expected: {SEAM_MODULE}.{SEAM_CALLABLE}(spec: dict) -> dict

This is not a test helper and it is not optional. It is the one entry point an
independently written check can call without having been shown the design, and
the bean that references these invariants is not done until it exists. See
`seam:` in factory/invariants/seating.yaml for the exact spec and result shapes.
""".strip()


def seam():
    try:
        module = importlib.import_module(SEAM_MODULE)
    except ImportError as exc:  # pragma: no cover - the message is the point
        pytest.fail(f"{SEAM_MISSING}\n\nImport failed: {exc}")
    fn = getattr(module, SEAM_CALLABLE, None)
    if not callable(fn):
        pytest.fail(SEAM_MISSING)
    return fn


# --------------------------------------------------------------------- specs --


def make_spec(rng: random.Random, *, tight: bool = False, contradictory: bool = False) -> dict[str, Any]:
    """A small, valid problem. `tight` removes slack; `contradictory` makes it unsolvable."""
    n_tables = rng.randint(2, 5)
    tables = [{"id": f"t{i}", "capacity": rng.randint(2, 6)} for i in range(n_tables)]
    seats = sum(t["capacity"] for t in tables)

    n_guests = seats if tight else max(2, int(seats * 0.6))
    guests = []
    for i in range(n_guests + 3):  # a few ineligible ones, always
        guests.append({"id": f"g{i}", "eligible": i < n_guests})

    eligible = [g["id"] for g in guests if g["eligible"]]
    rules: list[dict[str, Any]] = []
    if len(eligible) >= 4:
        a, b, c, d = rng.sample(eligible, 4)
        rules.append({"kind": "same_table", "guests": [a, b], "hardness": "hard"})
        rules.append({"kind": "different_table", "guests": [c, d], "hardness": "hard"})
        rules.append({"kind": "same_table", "guests": [c, d], "hardness": "soft"})

    if contradictory and len(eligible) >= 2:
        x, y = eligible[0], eligible[1]
        rules.append({"kind": "same_table", "guests": [x, y], "hardness": "hard"})
        rules.append({"kind": "different_table", "guests": [x, y], "hardness": "hard"})

    return {
        "tables": tables,
        "guests": guests,
        "rules": rules,
        "config": {"seed": 7, "time_limit_s": 10},
    }


def specs(n: int = 12, **kw) -> list[dict[str, Any]]:
    rng = random.Random(20260914)
    return [make_spec(rng, **kw) for _ in range(n)]


def check_result_shape(result: Any) -> None:
    assert isinstance(result, dict), f"result must be a dict, got {type(result).__name__}"
    assert result.get("status") in {"feasible", "infeasible"}, (
        f"status must be 'feasible' or 'infeasible', got {result.get('status')!r}"
    )
    assert isinstance(result.get("assignments", {}), dict), "assignments must be a mapping"


# ---------------------------------------------------------------- invariants --


@pytest.mark.parametrize("spec", specs(), ids=lambda s: f"{len(s['tables'])}t")
def test_inv_capacity(spec):
    """inv-capacity — no table is over its capacity. FR-047."""
    result = seam()(spec)
    check_result_shape(result)
    if result["status"] != "feasible":
        pytest.skip("infeasible; capacity is checked on feasible answers")
    capacity = {t["id"]: t["capacity"] for t in spec["tables"]}
    counts: dict[str, int] = {}
    for guest, table in result["assignments"].items():
        assert table in capacity, f"guest {guest} assigned to unknown table {table!r}"
        counts[table] = counts.get(table, 0) + 1
    for table, count in counts.items():
        assert count <= capacity[table], (
            f"table {table} holds {count} guests but seats {capacity[table]} — "
            "capacity is a hard constraint in every mode (FR-047)"
        )


@pytest.mark.parametrize("spec", specs(), ids=lambda s: f"{len(s['tables'])}t")
def test_inv_one_table(spec):
    """inv-one-table — an assigned guest sits at exactly one table."""
    result = seam()(spec)
    check_result_shape(result)
    if result["status"] != "feasible":
        pytest.skip("infeasible")
    assignments = result["assignments"]
    # A dict cannot hold a guest twice, so the real risk is a list-shaped answer
    # smuggled through, or a guest id that is not a guest.
    known = {g["id"] for g in spec["guests"]}
    for guest, table in assignments.items():
        assert guest in known, f"assignment names {guest!r}, which is not a guest in the spec"
        assert isinstance(table, str), f"guest {guest} is assigned {table!r}, not a table id"


@pytest.mark.parametrize("spec", specs(), ids=lambda s: f"{len(s['tables'])}t")
def test_inv_eligibility(spec):
    """inv-eligibility — ineligible guests are never seated. FR-019."""
    result = seam()(spec)
    check_result_shape(result)
    ineligible = {g["id"] for g in spec["guests"] if not g["eligible"]}
    seated = set(result.get("assignments", {}))
    leaked = ineligible & seated
    assert not leaked, (
        f"ineligible guests were assigned seats: {sorted(leaked)} — "
        "only Confirmed guests, and Pending guests with a reserved seat, are eligible (FR-019)"
    )


@pytest.mark.parametrize("spec", specs(), ids=lambda s: f"{len(s['tables'])}t")
def test_inv_hard_rules(spec):
    """inv-hard-rules — every hard rule in the input holds in the answer. FR-045."""
    result = seam()(spec)
    check_result_shape(result)
    if result["status"] != "feasible":
        pytest.skip("infeasible")
    at = result["assignments"]
    for rule in spec["rules"]:
        if rule.get("hardness") != "hard":
            continue
        a, b = rule["guests"]
        if a not in at or b not in at:
            continue  # an unseated guest cannot violate a seating rule
        if rule["kind"] == "same_table":
            assert at[a] == at[b], (
                f"hard same_table rule broken: {a} at {at[a]}, {b} at {at[b]} (FR-045)"
            )
        else:
            assert at[a] != at[b], (
                f"hard different_table rule broken: {a} and {b} both at {at[a]} (FR-045)"
            )


@pytest.mark.parametrize("spec", specs(contradictory=True), ids=lambda s: f"{len(s['tables'])}t")
def test_inv_infeasible_is_total(spec):
    """inv-infeasible-is-total — an infeasible answer is empty, never partial."""
    result = seam()(spec)
    check_result_shape(result)
    assert result["status"] == "infeasible", (
        "a spec containing both a hard same_table and a hard different_table rule for the "
        "same pair cannot be satisfied, but the solver reported it feasible"
    )
    assert not result.get("assignments"), (
        "an infeasible result carried assignments — a partial chart reads like success "
        "and is the failure most likely to reach a user (FR-050/FR-051)"
    )


@pytest.mark.parametrize("spec", specs(6), ids=lambda s: f"{len(s['tables'])}t")
def test_inv_reproducible(spec):
    """inv-reproducible — same spec, same config, same answer. FR-048."""
    solve = seam()
    first = solve(spec)
    second = solve(spec)
    check_result_shape(first)
    check_result_shape(second)
    assert first["status"] == second["status"], (
        f"two runs of the same spec disagreed on feasibility: "
        f"{first['status']} then {second['status']} (FR-048)"
    )
    assert first.get("assignments") == second.get("assignments"), (
        "two runs of the same spec produced different assignments — CP-SAT is deterministic "
        "per seed only when the worker count is fixed, and every comparison in the benchmark "
        "assumes this holds (FR-048)"
    )
