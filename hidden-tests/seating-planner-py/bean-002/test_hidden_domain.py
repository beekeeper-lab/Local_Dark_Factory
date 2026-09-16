"""Hidden tests for bean-002 — deliberately structural, and here is why.

bean-002 asks for `Event`, `Table`, `Guest` and `Group`. It does NOT fix their
API: it says a table has "a capacity, a shape and an (x, y) position" without
saying whether that is `capacity` or `seats`, `position` or `xy`. The spec step
settles that, and the spec is the worker's own output — so a hidden test that
guesses a constructor signature fails for a naming reason, costs the line a
build cycle, and teaches nobody anything.

What the bean DOES state literally, and what this file therefore asserts:

  * exactly four RSVP values, by name (ac2)
  * the three production limits, by number (ac5)
  * three constraints: no persistence, no solver imports, positions are floats
  * three non-goals: no seat-level positions, no rule model, no database
  * that a guest can be in more than one group — checked as a shape, not a call

Everything here reads the source rather than importing it with a guessed
signature. That is weaker than behavioural tests and it is what can honestly be
written before the API exists. When bean-002's spec is accepted, this file is
worth revisiting: the API is fixed by then, and the tests can be behavioural
without being written against the implementation.
"""

from __future__ import annotations

import ast
import os
from pathlib import Path

WORK = Path(os.environ.get("HIDDEN_TREE", "/work"))
assert WORK.is_dir(), f"HIDDEN_TREE is not a directory: {WORK}"

DOMAIN = WORK / "src" / "seating_planner" / "domain"


def _domain_files() -> list[Path]:
    assert DOMAIN.is_dir(), "bean-002 puts the domain under src/seating_planner/domain/"
    files = sorted(DOMAIN.rglob("*.py"))
    assert files, "the domain package is empty"
    return files


def _source() -> str:
    return "\n".join(p.read_text() for p in _domain_files())


def _imports(py: Path) -> set[str]:
    out: set[str] = set()
    for node in ast.walk(ast.parse(py.read_text(), filename=str(py))):
        if isinstance(node, ast.Import):
            out |= {a.name.split(".")[0] for a in node.names}
        elif isinstance(node, ast.ImportFrom) and node.module:
            out.add(node.module.split(".")[0])
    return out


def _classes() -> set[str]:
    names: set[str] = set()
    for py in _domain_files():
        for node in ast.walk(ast.parse(py.read_text(), filename=str(py))):
            if isinstance(node, ast.ClassDef):
                names.add(node.name)
    return names


# --- the vocabulary the bean names ------------------------------------------


def test_the_four_nouns_exist() -> None:
    # "An Event holds Tables and Guests; a Table has a capacity..." — the bean
    # names four types and the whole intent is that they exist as the product's
    # vocabulary. Names only; nothing here assumes a signature.
    have = _classes()
    missing = {"Event", "Table", "Guest", "Group"} - have
    assert not missing, f"bean-002 names these types: {sorted(missing)} absent; found {sorted(have)}"


# --- ac2: "exactly Confirmed, Pending, Declined and Cancelled" ---------------


def test_rsvp_has_exactly_the_four_named_values() -> None:
    src = _source()
    expected = ["Confirmed", "Pending", "Declined", "Cancelled"]
    for value in expected:
        assert value in src, f"RSVP status {value!r} is named by ac2 and is not in the domain source"
    # "and rejects anything else" — a fifth status is a different contract from
    # the one the bean asked for, and every later bean reads this one.
    for extra in ("Tentative", "Waitlist", "Maybe", "Unknown", "Invited"):
        assert extra not in src, (
            f"ac2 says exactly four RSVP values; {extra!r} appears in the domain source"
        )


# --- ac5: "rejects more than 500 guests, 60 tables, or 5000 rules" ----------


def test_the_production_limits_are_the_numbers_the_bean_gives() -> None:
    src = _source()
    for limit in ("500", "60", "5000"):
        assert limit in src, f"ac5 names the limit {limit} and it does not appear in the domain source"


# --- constraint: "no persistence in this bean", non_goal: "no database" -----


def test_nothing_persists() -> None:
    banned = {"sqlite3", "sqlalchemy", "psycopg", "psycopg2", "pymongo", "redis", "shelve", "pickle"}
    offenders = {}
    for py in _domain_files():
        hit = _imports(py) & banned
        if hit:
            offenders[str(py.relative_to(WORK))] = sorted(hit)
    assert not offenders, f"this bean has no persistence and no database: {offenders}"


# --- constraint: "no solver imports" ----------------------------------------


def test_nothing_imports_the_solver() -> None:
    offenders = {}
    for py in _domain_files():
        hit = _imports(py) & {"ortools"}
        if hit:
            offenders[str(py.relative_to(WORK))] = sorted(hit)
    assert not offenders, f"the solver arrives in a later bean: {offenders}"


# --- non_goal: "no rule model (bean-003)" ------------------------------------


def test_no_rule_model_yet() -> None:
    # ac5 makes the Event count rules, which means it must hold them somehow. It
    # must not DEFINE them: a Rule class here is bean-003's work arriving early,
    # and bean-003 would then have to edit a file outside its own write paths.
    assert "Rule" not in _classes(), (
        "the rule model is bean-003; ac5 only requires that an event can count rules"
    )


# --- constraint: "table position is a float pair on an arbitrary unit plane" --


def test_table_position_is_floats_not_integers() -> None:
    # A position typed `int` reads as a grid cell, and FR-014 proximity on an
    # arbitrary unit plane is not a grid. Checked as an annotation because the
    # attribute's NAME is the spec's to choose and its type is the bean's.
    src = _source()
    assert "float" in src, (
        "the bean says table position is a float pair on an arbitrary unit plane; "
        "no float annotation appears in the domain source"
    )


# --- ac4: "A guest may belong to more than one group" -----------------------


def test_group_membership_is_many_to_many_shaped() -> None:
    # Not a call — the API is the spec's to fix. But a Group that holds one guest,
    # or a Guest that holds one group, cannot satisfy ac4 whatever it is called,
    # and a collection annotation is the observable trace of the right shape.
    src = _source()
    assert any(token in src for token in ("list[", "set[", "frozenset[", "tuple[", "Sequence[")), (
        "ac4 needs a guest to be in more than one group; no collection type appears "
        "anywhere in the domain source"
    )


# --- the bean's own boundary -------------------------------------------------


def test_the_domain_stays_inside_its_write_paths() -> None:
    # allowed_write_paths is src/seating_planner/domain/** and tests/domain/**.
    # The gate checks the diff; this checks the tree, which catches a file that
    # arrived in an earlier attempt and was never cleaned up.
    stray = [
        p.name
        for p in (WORK / "src" / "seating_planner").glob("*.py")
        if p.name != "__init__.py"
    ]
    assert not stray, f"bean-002 writes under domain/ only; these are beside it: {stray}"
