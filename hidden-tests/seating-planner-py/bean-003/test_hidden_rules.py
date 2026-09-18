"""Hidden tests for bean-003 — structural, and written before the code existed.

Written while bean-003's spec step was still running, which is the only way this
suite is independent: it cannot have been shaped by the implementation, because
there was none.

bean-003 asks for seating rules as inspectable structured data with a type,
hardness and weight. It does NOT fix the API: it never says whether the class is
`Rule` or `SeatingRule`, whether hardness is an enum or a bool, or what FR-034's
rule types are called — the requirement is referenced by number and the names
are not in the bean. So nothing here guesses a constructor signature or a type
name. bean-002's suite learned that lesson twice: once in its own docstring, and
once for real when it failed a correct implementation on the capital letter in
`Confirmed`.

What the bean DOES state literally, and what this file therefore asserts:

  * hardness is explicit, and both kinds are named (intent, ac3)
  * a soft weight runs 1..100, both bounds (ac2)
  * a minimum-distance rule carries a measure — FR-035's sharp edge (ac4)
  * the seven default wedding-template categories, by name (ac5)
  * the five test ids the bean pins exist and assert something
  * two constraints: data only, no solver import
  * two non-goals: no evaluation package, no natural-language parsing

Everything is matched case-insensitively. The bean writes these words as English
prose — "couples", "households", "immediate family" — not as identifiers, and it
fixes no spelling for any of them.
"""

from __future__ import annotations

import ast
import os
import re
from pathlib import Path

WORK = Path(os.environ.get("HIDDEN_TREE", "/work"))
assert WORK.is_dir(), f"HIDDEN_TREE is not a directory: {WORK}"

RULES = WORK / "src" / "seating_planner" / "rules"
TESTS = WORK / "tests" / "rules"


def _rule_files() -> list[Path]:
    assert RULES.is_dir(), "bean-003 puts the rules under src/seating_planner/rules/"
    files = sorted(RULES.rglob("*.py"))
    assert files, "the rules package is empty"
    return files


def _source() -> str:
    return "\n".join(p.read_text(encoding="utf-8") for p in _rule_files())


def _test_source() -> str:
    if not TESTS.is_dir():
        return ""
    return "\n".join(p.read_text(encoding="utf-8") for p in sorted(TESTS.rglob("*.py")))


# --- the intent: "never as prose and never only inside a prompt" ------------


def test_rules_live_where_the_bean_says() -> None:
    files = _rule_files()
    assert any(p.stat().st_size > 200 for p in files), (
        f"every file under rules/ is a stub: {[p.name for p in files]}"
    )


def test_the_rules_package_imports() -> None:
    # The one behavioural assertion here, and safe because the bean fixes the
    # path rather than the API: a package that does not import is not data
    # anything can inspect, whatever its contents look like.
    import importlib
    import sys

    src = str(WORK / "src")
    if src not in sys.path:
        sys.path.insert(0, src)
    importlib.import_module("seating_planner.rules")


# --- ac3 + the intent: hardness is explicit ---------------------------------


def test_hard_and_soft_are_both_named() -> None:
    src = _source().lower()
    for word in ("hard", "soft"):
        assert word in src, (
            f"the bean's rules carry an explicit hardness; {word!r} is not in the source"
        )


# --- ac2: "an integer weight in 1..100" -------------------------------------


def test_the_weight_bounds_are_in_the_source() -> None:
    src = _source().lower()
    assert "weight" in src, "ac2 is about a weight and the word is not in the source"
    # Both bounds, as numbers. A range enforced with numbers that are not these
    # is not the range the bean asked for, and 1 and 100 are the two the
    # criterion states.
    assert re.search(r"\b100\b", src), "ac2's upper bound of 100 is not in the source"
    assert re.search(r"\b1\b", src), "ac2's lower bound of 1 is not in the source"


# --- ac4 / FR-035: "far apart" cannot be stored as an executable rule -------


def test_a_minimum_distance_rule_names_a_measure() -> None:
    src = _source().lower()
    assert "distance" in src, "ac4 is about a minimum-distance rule"
    # A measure, not a mood. The bean allows either a number or a zone count,
    # so this accepts either word rather than picking one.
    assert ("zone" in src) or re.search(r"\bfloat\b|\bint\b|\bdecimal\b|\bnumber\b", src), (
        "FR-035: a minimum-distance rule must carry a measure — no zone count and "
        "no numeric type appears anywhere in the rules source"
    )


# --- ac5: the seven default wedding-template categories ---------------------


def test_the_seven_template_categories_are_named() -> None:
    # Case-insensitive and substring, because these are English words in a
    # sentence of the bean and it fixes no identifier for any of them. "immediate
    # family" is checked as two words joined by anything, so
    # `IMMEDIATE_FAMILY`, `immediate-family` and "immediate family" all count.
    src = (_source() + "\n" + _test_source()).lower()
    wanted = [
        ("couple",),
        ("household",),
        ("immediate", "family"),
        ("wedding", "party"),
        ("child",),          # children / child / CHILDREN
        ("vendor",),
        ("accessible",),
    ]
    missing = []
    for parts in wanted:
        if len(parts) == 1:
            if parts[0] not in src:
                missing.append(parts[0])
        elif not re.search(parts[0] + r"[^a-z]{0,3}" + parts[1], src):
            missing.append(" ".join(parts))
    assert not missing, (
        f"ac5 names seven template categories; these appear nowhere: {missing}"
    )


# --- the five test ids the bean pins ----------------------------------------


def test_the_pinned_tests_exist_and_assert_something() -> None:
    # The bean names five test ids by path and function. The gate runs them; this
    # asks a different question — whether they assert anything at all. A test
    # that is pinned by an acceptance criterion and contains no assertion is a
    # criterion nobody verified, and it passes the gate.
    pinned = {
        "tests/rules/test_rule_model.py": [
            "test_all_rule_types_roundtrip",
            "test_soft_weight_bounds",
            "test_hard_rule_has_no_weight",
            "test_min_distance_requires_measure",
        ],
        "tests/rules/test_template.py": ["test_default_wedding_template"],
    }
    problems = []
    for rel, names in pinned.items():
        path = WORK / rel
        if not path.is_file():
            problems.append(f"{rel} is missing")
            continue
        tree = ast.parse(path.read_text(encoding="utf-8"))
        defined = {
            n.name: n for n in ast.walk(tree)
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


# --- constraint: "rules are data only; no evaluation logic in this bean" ----


def test_no_solver_import() -> None:
    src = _source()
    for banned in ("ortools", "pulp", "cvxpy", "z3"):
        assert not re.search(r"\b(import|from)\s+" + banned + r"\b", src), (
            f"bean-003 is data only and forbids solver imports; {banned} is imported"
        )


# --- non-goals: no evaluation, no natural-language parsing ------------------


def test_no_evaluation_package_yet() -> None:
    for rel in ("src/seating_planner/feasibility", "src/seating_planner/solver"):
        assert not (WORK / rel).exists(), (
            f"{rel} is a later bean's work arriving early (bean-005, bean-007)"
        )


def test_no_natural_language_parsing() -> None:
    src = _source()
    for banned in ("nltk", "spacy", "transformers", "openai", "anthropic"):
        assert not re.search(r"\b(import|from)\s+" + banned + r"\b", src), (
            f"bean-003 does not parse natural-language rules; {banned} is imported"
        )
