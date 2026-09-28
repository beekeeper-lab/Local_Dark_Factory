"""Hidden tests for bean-004 — the things nothing visible checks.

Written before bean-004 ran, from `bean.yaml` alone.

bean-004's constraints and non-goals are already machine-readable —
`forbidden_imports` for psycopg, sqlalchemy, alembic, cryptography and the rest
— and `bean-forbids` checks every one of them against the diff at gate time. So
none of them are repeated here. A hidden test that re-asserts a visible check
costs a run and adds nothing, which is the mistake bean-001's suite made with
`test_no_ci_workflow_files`: it duplicated a `bean-forbids` non-goal at the wrong
resolution and then failed on a file the factory's own scaffold had installed.

What is left is the interesting half — five things the bean states that no other
check in the line asks about:

  * SQLite is USED, not merely un-avoided. The forbidden-import list rules out
    every other database; nothing says this one has to appear.
  * NFR-013: a save is one transaction. ac3 tests that a failed write leaves the
    previous state readable, and a test can pass that by luck on a small write;
    a transaction boundary in the source is the thing that makes it true.
  * the audit log is append-only (ac4) — checked as the absence of any UPDATE or
    DELETE aimed at it, which is what append-only MEANS in SQL and is not what a
    single rejection test proves.
  * the four fields ac2 names actually appear.
  * a removal has a name in the audit vocabulary (ac5, added 2026-09-24).

Nothing here guesses an API. The bean fixes the package path and says nothing
about whether the seam is a class, a module or a set of functions, so this reads
the source rather than importing a name.
"""

from __future__ import annotations

import ast
import os
import re
from pathlib import Path

WORK = Path(os.environ.get("HIDDEN_TREE", "/work"))
assert WORK.is_dir(), f"HIDDEN_TREE is not a directory: {WORK}"

STORE = WORK / "src" / "seating_planner" / "store"


def _store_files() -> list[Path]:
    assert STORE.is_dir(), "bean-004 puts the store under src/seating_planner/store/"
    files = sorted(STORE.rglob("*.py"))
    assert files, "the store package is empty"
    return files


def _source() -> str:
    return "\n".join(p.read_text(encoding="utf-8") for p in _store_files())


# --- the constraint, read the other way round: SQLite is what it uses -------


def test_sqlite_is_actually_used() -> None:
    # `bean-forbids` proves no OTHER database is imported. Nothing proves this
    # one is, and "SQLite only" is a statement about what the store IS.
    src = _source()
    assert re.search(r"\b(import|from)\s+sqlite3\b", src), (
        "bean-004 says SQLite only, and sqlite3 is not imported anywhere in the store"
    )


# --- NFR-013: "each save is one transaction" -------------------------------


def test_a_write_has_a_transaction_boundary() -> None:
    # ac3's test can pass by luck: a single INSERT that raises before it runs
    # leaves the previous state intact whether or not anything is transactional.
    # What makes ac3 true in general is a boundary in the source. Any of the
    # three ways SQLite offers counts — an explicit commit/rollback pair, the
    # connection used as a context manager, or an explicit BEGIN.
    src = _source()
    lowered = src.lower()
    ways = [
        bool(re.search(r"\.commit\s*\(", src) and re.search(r"\.rollback\s*\(", src)),
        bool(re.search(r"with\s+(self\.)?\w*(conn|connection|db)\w*\b", lowered)),
        "begin" in lowered and "transaction" in lowered,
    ]
    assert any(ways), (
        "NFR-013 makes each save one transaction; the store has no commit/rollback "
        "pair, no connection used as a context manager, and no explicit BEGIN"
    )


# --- ac4: "the audit log is append-only" -----------------------------------


def test_nothing_updates_or_deletes_the_audit_log() -> None:
    # Append-only is a property of the SQL, not of one rejection path. A store
    # that raises on `audit.delete()` and also has `DELETE FROM audit_log`
    # somewhere else is not append-only; ac4's test would pass anyway.
    src = _source()
    offenders = []
    for match in re.finditer(r"(?is)\b(delete\s+from|update)\s+([`\"'\[]?\w+)", src):
        target = match.group(2).strip("`\"'[")
        if "audit" in target.lower():
            offenders.append(match.group(0).strip())
    assert not offenders, (
        f"ac4 makes the audit log append-only; this SQL modifies it: {offenders}"
    )


# --- ac2: "actor, timestamp, entity type and entity id" --------------------


def test_the_audit_entry_names_all_four_fields() -> None:
    # Case-insensitive and substring: the bean writes these as English and fixes
    # no column names, so `actor`, `ACTOR` and `actor_id` all count, and
    # `entity_type`, `entityType` and "entity type" all count for the same one.
    src = _source().lower()
    assert "audit" in src, "ac2 is about an audit entry and the word is absent"
    missing = []
    for label, pattern in (
        ("actor", r"actor"),
        ("timestamp", r"timestamp|created_at|\bts\b|occurred"),
        ("entity type", r"entity[^a-z]{0,3}type|entity_kind"),
        ("entity id", r"entity[^a-z]{0,3}id"),
    ):
        if not re.search(pattern, src):
            missing.append(label)
    assert not missing, (
        f"ac2 names four fields an audit entry carries; these appear nowhere: {missing}"
    )


# --- ac5: a removal is a change, and is audited -----------------------------


def test_the_audit_log_can_record_a_removal() -> None:
    # Added 2026-09-24 with ac5. PR #5 replaced rows wholesale on every save
    # and audited only what was still present, so a removed guest vanished
    # without an entry, and every test — visible and hidden — was green.
    #
    # The bean fixes no API and no action vocabulary, so this asks only that
    # the store has a word for a removal that is not SQL: a string constant
    # such as "delete", "removed" or "remove". `DELETE FROM ...` does not
    # count; that is the store deleting rows, not saying it did.
    words = re.compile(r"^(delete|deleted|remove|removed|removal)$")
    found = [
        node.value
        for path in _store_files()
        for node in ast.walk(ast.parse(path.read_text(encoding="utf-8")))
        if isinstance(node, ast.Constant)
        and isinstance(node.value, str)
        and words.match(node.value.strip().lower())
    ]
    assert found, (
        "ac5: nothing in the store names a removal as an audit action, so a "
        "removed entity can leave no entry"
    )


# --- the test ids the bean pins --------------------------------------------


def test_the_pinned_tests_exist_and_assert_something() -> None:
    # The gate runs these by id. This asks a different question: whether they
    # assert anything. A test pinned by an acceptance criterion with an empty
    # body passes the gate, and the criterion it verifies is verified by nobody.
    pinned = {
        "tests/store/test_repository.py": ["test_event_roundtrip", "test_failed_write_is_atomic"],
        "tests/store/test_audit.py": [
            "test_mutation_writes_audit_entry",
            "test_audit_log_is_append_only",
            "test_removal_writes_audit_entry",
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


# --- the seam the background describes -------------------------------------


def test_the_store_package_imports() -> None:
    # The one behavioural assertion, safe because the bean fixes the path and
    # not the API. "The rest of the code asks it to load and save" is not true
    # of a package that does not import.
    import importlib
    import sys

    src = str(WORK / "src")
    if src not in sys.path:
        sys.path.insert(0, src)
    importlib.import_module("seating_planner.store")
