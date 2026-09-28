"""Hidden tests for bean-016 — optimization results are proposals until accepted.

Written from bean-016's criteria before its code existed. The bean introduces
new operations (a proposal, a comparison, accept, decline) and fixes none of
their names or signatures: it pins test ids and says what they must mean. So
nothing here calls an operation the bean has not named in code. What it checks:

  * ac5 — accepting "writes the new chart" into the saved state. The saved state
    is the store's sqlite database, and on main that database has no place for a
    chart at all: events, tables, guests, groups, rules, locks, audit_log, and
    not one column that holds a guest's table. So the store must gain one — a new
    table or a new column, whether created up front or on first accept — or,
    failing that, write the chart to a file of its own. Checked from the store's
    SQL and source, case-insensitively, never by name.
  * ac1 / constraint — optimizing does not modify the saved chart; optimize and
    accept are separate operations. The stable way to optimize is solve_event,
    in each of its three modes: run against an event loaded from a saved
    database, it must leave that database byte-identical and the event itself
    unchanged. A solve that commits as a side effect is exactly what the bean
    removes.
  * non-goal — no undo/redo stack.

The comparison (ac2, ac3) and decline (ac4) are not checked here: they are
reachable only through operations whose names the bean does not fix, and a
guessed name fails a correct implementation for a spelling.
"""

from __future__ import annotations

import ast
import hashlib
import os
import re
import sqlite3
import sys
from pathlib import Path
from typing import Any

WORK = Path(os.environ.get("HIDDEN_TREE", "/work"))
assert WORK.is_dir(), f"HIDDEN_TREE is not a directory: {WORK}"
_SRC = str(WORK / "src")
if _SRC not in sys.path:
    sys.path.insert(0, _SRC)

PKG = WORK / "src" / "seating_planner"
STORE = PKG / "store"

# The store's schema before this bean: every table, and every column in it.
BASELINE: dict[str, set[str]] = {
    "events": {"id", "name"},
    "tables": {"event_id", "id", "name", "capacity", "shape", "position_x", "position_y"},
    "guests": {"event_id", "id", "name", "status", "household_id", "reserved_seat"},
    "groups": {"event_id", "id", "name", "members"},
    "rules": {"event_id", "id", "data"},
    "locks": {"event_id", "guest_id", "table_id"},
    "audit_log": {"id", "event_id", "entity_type", "entity_id", "action", "actor", "timestamp"},
}


def _store_source() -> str:
    assert STORE.is_dir(), "the store package src/seating_planner/store/ is missing"
    files = sorted(STORE.rglob("*.py"))
    assert files, "the store package is empty"
    return "\n".join(p.read_text(encoding="utf-8") for p in files)


def _event() -> Any:
    from seating_planner.domain import Event, Guest, RsvpStatus, Table
    from seating_planner.rules import Hardness, Rule, RuleType

    return Event(
        id="e", name="E",
        tables=[Table(id=t, name=t, capacity=3, shape="round", position=(0.0, float(i)))
                for i, t in enumerate(["t-1", "t-2"])],
        guests=[Guest(id=f"g-{i}", name=f"g-{i}", status=RsvpStatus.CONFIRMED) for i in range(5)],
        groups=[],
        rules=[Rule(id="r-with", rule_type=RuleType.SAME_TABLE, hardness=Hardness.SOFT, weight=7,
                    guest_ids=("g-0", "g-3"))],
    )


def _fingerprint(directory: Path) -> dict[str, str]:
    return {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(directory.iterdir()) if p.is_file()}


def test_the_store_has_somewhere_to_keep_the_chart(tmp_path: Path) -> None:
    source = _store_source()
    from seating_planner.store import Repository

    # Up-front schema: open a fresh database and read what it holds.
    repo = Repository(tmp_path / "fresh.db")
    repo.close()
    conn = sqlite3.connect(str(tmp_path / "fresh.db"))
    try:
        names = [r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type = 'table'")]
        live = {n: {c[1] for c in conn.execute(f'PRAGMA table_info("{n}")')} for n in names
                if not n.startswith("sqlite_")}
    finally:
        conn.close()
    grown_live = any(n not in BASELINE or cols - BASELINE[n] for n, cols in live.items())

    # Schema created or altered later (on first accept, say): read the SQL text.
    created = {m.lower() for m in re.findall(r"CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?[\"'`]?(\w+)", source, re.I)}
    grown_text = bool(created - set(BASELINE)) or bool(re.search(r"ALTER\s+TABLE\s+\w+\s+ADD", source, re.I))

    # Or a chart kept outside sqlite, in a file the store writes itself.
    writes_file = bool(re.search(r"\.write_text\(|\.write_bytes\(|json\.dump\(|open\([^)]*[\"'][wa]b?\+?[\"']", source))

    assert grown_live or grown_text or writes_file, (
        "accepting a proposal writes the new chart to the saved state, but the store has "
        f"nowhere to keep one: its schema is still {sorted(live)} with no new table or column"
    )


def test_solving_in_any_mode_leaves_the_saved_database_untouched(tmp_path: Path) -> None:
    from seating_planner.solver import solve_event
    from seating_planner.store import Repository

    db = tmp_path / "saved.db"
    repo = Repository(db)
    repo.save_event(_event(), actor="organizer")
    repo.close()
    before = _fingerprint(tmp_path)

    repo = Repository(db)
    event = repo.load_event("e")
    snapshot = repr((event.tables, event.guests, event.groups, [r.to_dict() for r in event.rules], dict(event.locks)))
    planned = solve_event(event, mode="planning")
    assert planned.status == "feasible"
    chart = dict(planned.assignments)
    solve_event(event, mode="low_disruption", current=chart, movement_limit=1)
    solve_event(event, mode="event_day", current={g: t for g, t in chart.items() if g != "g-4"})
    assert repr((event.tables, event.guests, event.groups, [r.to_dict() for r in event.rules],
                 dict(event.locks))) == snapshot, "optimizing changed the event it was given"
    repo.close()

    assert _fingerprint(tmp_path) == before, (
        "optimizing wrote to the saved database; a result is a proposal until it is accepted"
    )


def test_there_is_no_undo_or_redo_stack() -> None:
    _store_source()
    offenders = []
    for path in sorted(PKG.rglob("*.py")):
        tree = ast.parse(path.read_text(encoding="utf-8"))
        for node in ast.walk(tree):
            if isinstance(node, ast.FunctionDef | ast.AsyncFunctionDef | ast.ClassDef) and re.search(
                r"undo|redo", node.name, re.I
            ):
                offenders.append(f"{path.relative_to(WORK)}::{node.name}")
    assert not offenders, f"the bean's non-goal is no undo/redo stack: {offenders}"
