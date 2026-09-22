"""Hidden tests for bean-005 — structural, and written before the code existed.

Written while bean-003 was still walking the line, so this suite cannot have
been shaped by an implementation: there is none, and bean-004 has not run
either. That is the only way "write them from the bean, not from the diff" is
a fact rather than a promise.

bean-005 asks for four structurally impossible seating problems to be found and
explained *before the solver is invoked*. It does NOT fix the API. It never says
whether the entry point is `preflight()` or `check_feasibility()`, whether a
result is a list or a report object, or what the four findings are called — the
criteria name the failures in English and pin five test ids, and that is all.
So nothing here guesses a call signature or a type name. bean-002's suite
learned that twice, once in its own docstring and once for real when it failed a
correct implementation on the capital letter in `Confirmed`.

What the bean DOES state literally, and what this file therefore asserts:

  * the four failures it can detect by inspection, each named (ac1–ac4)
  * the five test ids it pins exist and assert something
  * the constraint the machine cannot read: structural only, never a search
  * the intent's sharp edge — this runs BEFORE the solver, so it may not reach
    for one (bean.yaml's `forbidden_imports` covers ortools; this covers the
    package bean-006 will add, and the search libraries nothing declares)
  * the background's claim that this is the first bean to READ earlier beans'
    code rather than build its own world

`forbidden_imports: [ortools]` is machine-readable and `bean-forbids` already
checks it against the diff at the right resolution, so it is not restated here.
A hidden test earns its cost by asking something nothing visible asks.

Everything is matched case-insensitively. The bean writes these words as English
prose in its criteria — "contradiction", "capacity", "zone" — not as
identifiers, and it fixes no spelling for any of them.
"""

from __future__ import annotations

import ast
import os
import re
from pathlib import Path

WORK = Path(os.environ.get("HIDDEN_TREE", "/work"))
assert WORK.is_dir(), f"HIDDEN_TREE is not a directory: {WORK}"

FEAS = WORK / "src" / "seating_planner" / "feasibility"
TESTS = WORK / "tests" / "feasibility"


def _feasibility_files() -> list[Path]:
    assert FEAS.is_dir(), (
        "bean-005 puts the pre-flight checks under src/seating_planner/feasibility/"
    )
    files = sorted(FEAS.rglob("*.py"))
    assert files, "the feasibility package is empty"
    return files


def _source() -> str:
    return "\n".join(p.read_text(encoding="utf-8") for p in _feasibility_files())


def _test_source() -> str:
    if not TESTS.is_dir():
        return ""
    return "\n".join(p.read_text(encoding="utf-8") for p in sorted(TESTS.rglob("*.py")))


# --- the bean's own path, and something actually in it ----------------------


def test_the_preflight_lives_where_the_bean_says() -> None:
    files = _feasibility_files()
    assert any(p.stat().st_size > 200 for p in files), (
        f"every file under feasibility/ is a stub: {[p.name for p in files]}"
    )


def test_the_feasibility_package_imports() -> None:
    # The one behavioural assertion here, and safe because the bean fixes the
    # path rather than the API: a pre-flight check that does not import cannot
    # run before anything, whatever its contents look like.
    import importlib
    import sys

    src = str(WORK / "src")
    if src not in sys.path:
        sys.path.insert(0, src)
    importlib.import_module("seating_planner.feasibility")


# --- ac1–ac4: the four failures the bean says are detectable by inspection ---


def test_the_four_detectable_failures_are_each_named() -> None:
    # Case-insensitive substrings, because these are English words in the bean's
    # criteria and it fixes no identifier for any of them. Each entry is a tuple
    # of alternatives: any one of them counts, so a spec that settles on
    # "contradictory" or "conflicting" is not failed over the choice.
    src = (_source() + "\n" + _test_source()).lower()
    wanted = {
        "ac1 — contradictory hard rules": ("contradict", "conflict"),
        "ac2 — a group larger than every table": ("group",),
        "ac3 — not enough seats for the eligible guests": ("capacit", "seat"),
        "ac4 — a rule naming a target that does not exist": ("zone", "missing", "unknown"),
    }
    missing = [what for what, words in wanted.items() if not any(w in src for w in words)]
    assert not missing, (
        f"bean-005 names four failures it must detect; nothing in the feasibility "
        f"source or its tests mentions these: {missing}"
    )


def test_the_capacity_check_counts_both_sides() -> None:
    # ac3 asks for the report to carry BOTH counts, and ac2 for the group AND
    # the largest capacity. The API is not fixed, so this asks the weakest thing
    # that is still a fact: the source does arithmetic over eligibility and
    # capacity rather than returning a bare flag. `eligible` is bean-002's own
    # word for the derived property and the criterion reuses it.
    src = _source().lower()
    assert "eligib" in src, (
        "ac3 is about ELIGIBLE guests exceeding total capacity, and nothing in "
        "the feasibility source mentions eligibility — bean-002 derives it and "
        "this bean is supposed to read it, not re-decide it"
    )


# --- the five test ids the bean pins ----------------------------------------


def test_the_pinned_tests_exist_and_assert_something() -> None:
    # The bean names five test ids by path and function. The gate runs them; this
    # asks a different question — whether they assert anything at all. A test
    # that is pinned by an acceptance criterion and contains no assertion is a
    # criterion nobody verified, and it passes the gate.
    pinned = {
        "tests/feasibility/test_preflight.py": [
            "test_contradictory_hard_rules",
            "test_group_larger_than_any_table",
            "test_insufficient_capacity",
            "test_rule_references_missing_target",
            "test_feasible_problem_is_clean",
        ],
    }
    problems = []
    for rel, names in pinned.items():
        path = WORK / rel
        if not path.is_file():
            problems.append(f"{rel} is missing")
            continue
        tree = ast.parse(path.read_text(encoding="utf-8"))
        defined = {
            n.name: n
            for n in ast.walk(tree)
            if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))
        }
        for name in names:
            fn = defined.get(name)
            if fn is None:
                problems.append(f"{rel}::{name} is not defined")
            elif not any(
                isinstance(sub, (ast.Assert, ast.Raise, ast.With, ast.Try))
                for sub in ast.walk(fn)
            ):
                problems.append(f"{rel}::{name} contains no assertion")
    assert not problems, f"the bean pins these and they are not there: {problems}"


# --- the intent: this runs BEFORE the solver is ever invoked ----------------


def test_the_preflight_does_not_reach_for_a_solver() -> None:
    # The bean's own reason, quoted from its constraint comment: "The whole point
    # of a pre-flight check is that it is cheaper than a solve." ortools is
    # bean.yaml's `forbidden_imports` and bean-forbids checks it — these are the
    # ones nothing else looks for, including the package bean-006 will add.
    src = _source()
    for banned in ("pulp", "cvxpy", "z3", "mip", "pyomo"):
        assert not re.search(r"^\s*(import|from)\s+" + banned + r"\b", src, re.M), (
            f"bean-005 must be cheaper than a solve and {banned} is imported"
        )
    assert not re.search(r"^\s*from\s+\S*seating_planner\.solver\b", src, re.M), (
        "the pre-flight runs BEFORE the solver is invoked; it imports the solver package"
    )
    assert not re.search(r"^\s*import\s+\S*seating_planner\.solver\b", src, re.M), (
        "the pre-flight runs BEFORE the solver is invoked; it imports the solver package"
    )


def test_the_checks_are_structural_rather_than_a_search() -> None:
    # "checks are structural only, never a search" is the one constraint on this
    # bean that no machine-readable field carries, so it is the one worth a test.
    # A permutation or product over the guests IS the search the bean forbids,
    # and it is the obvious way to get the four answers by brute force.
    src = _source()
    for banned in ("permutations", "product", "combinations_with_replacement"):
        assert not re.search(r"\bitertools\." + banned + r"\b|\bfrom\s+itertools\s+import\b[^\n]*\b" + banned + r"\b", src), (
            f"bean-005's checks are structural only, never a search; itertools.{banned} "
            f"enumerates arrangements, which is the search this bean exists to be "
            f"cheaper than"
        )


# --- the background: the first bean that READS earlier beans' code ----------


def test_it_reads_the_earlier_beans_rather_than_rebuilding_them() -> None:
    # "This is the first bean that reads code written by earlier beans rather
    # than creating its own world." A pre-flight that declares its own Rule or
    # its own Table passes every visible check — the gate only sees that the
    # tests are green — and is measuring a world nothing else shares.
    src = _source()
    assert re.search(r"^\s*(from|import)\s+\S*seating_planner\.(domain|rules)\b", src, re.M), (
        "bean-005 reads bean-002's domain and bean-003's rules; the feasibility "
        "source imports neither, so it is building its own world"
    )
    own = set()
    for path in _feasibility_files():
        tree = ast.parse(path.read_text(encoding="utf-8"))
        for node in ast.walk(tree):
            if isinstance(node, ast.ClassDef) and node.name in {
                "Event", "Table", "Guest", "Group", "Rule",
            }:
                own.add(f"{path.name}::{node.name}")
    assert not own, (
        f"these are bean-002's and bean-003's types, redeclared inside the "
        f"pre-flight instead of imported: {sorted(own)}"
    )


# --- non-goal: the solver is a later bean's work ----------------------------


def test_no_solver_package_yet() -> None:
    assert not (WORK / "src" / "seating_planner" / "solver").exists(), (
        "src/seating_planner/solver is bean-006's work arriving early"
    )
