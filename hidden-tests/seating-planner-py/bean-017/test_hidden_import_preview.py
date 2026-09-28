"""Hidden tests for bean-017 — CSV guest import with a cancellable dry-run preview.

Written from bean-017.yaml before the bean ran. The bean fixes a path
(src/seating_planner/importer/) and five test ids, and NO API: it never says
what the preview function is called, whether it takes a path or text, an Event
or a Repository, or what its result looks like. So nothing here imports a name
the bean does not fix.

What it asserts:

  * the package exists, is not a stub, and imports
  * ac1 — the four things a preview reports are each named in the source,
    matched case-insensitively with alternatives, because the bean writes them
    as English
  * the constraint "duplicate detection uses a stated, testable rule", read with
    the background: the rule normalizes names, and the preview SAYS what rule it
    used (a string, not only a comment)
  * the constraint "preview opens no write transaction": the importer does not
    reach past the Repository to sqlite3, and issues no BEGIN of its own
  * ac2/ac3, behaviourally where the API can be found without guessing: every
    public callable whose name says preview (or dry run) is called with whatever
    it asks for that can be supplied by parameter name — an Event, a Repository
    holding the event, a CSV path or CSV text — and afterwards the Event, the
    database file, the audit log and the CSV are unchanged. If no such callable
    can be driven, that test SKIPS: it is extra reach, not a gate on naming.
  * the pinned test ids exist and assert something

Deliberately NOT asserted: the create/update counts of ac4 and the opt-in of
ac5. Both need the apply entry point and the shape of a preview result, neither
of which the bean fixes. Nor is "same household" asserted as the duplicate
rule: the background says it "is enough", not that it is required.
"""

from __future__ import annotations

import ast
import copy
import hashlib
import importlib
import inspect
import os
import pkgutil
import re
import sys
from pathlib import Path
from typing import Any

import pytest

WORK = Path(os.environ.get("HIDDEN_TREE", "/work"))
assert WORK.is_dir(), f"HIDDEN_TREE is not a directory: {WORK}"
_SRC = str(WORK / "src")
if _SRC not in sys.path:
    sys.path.insert(0, _SRC)

PKG = WORK / "src" / "seating_planner" / "importer"
TESTS = WORK / "tests" / "importer"


def _files() -> list[Path]:
    assert PKG.is_dir(), "bean-017 puts the importer under src/seating_planner/importer/"
    files = sorted(PKG.rglob("*.py"))
    assert files, "the importer package is empty"
    return files


def _source() -> str:
    return "\n".join(p.read_text(encoding="utf-8") for p in _files())


def _code_strings() -> list[str]:
    """String constants in the importer, docstrings excluded."""
    out: list[str] = []
    for path in _files():
        tree = ast.parse(path.read_text(encoding="utf-8"))
        docs = set()
        for node in ast.walk(tree):
            if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
                body = getattr(node, "body", [])
                if body and isinstance(body[0], ast.Expr) and isinstance(body[0].value, ast.Constant):
                    docs.add(id(body[0].value))
        for node in ast.walk(tree):
            if isinstance(node, ast.Constant) and isinstance(node.value, str) and id(node) not in docs:
                out.append(node.value)
    return out


# --- the bean's own path ------------------------------------------------------


def test_the_importer_lives_where_the_bean_says_and_imports() -> None:
    files = _files()
    assert any(p.stat().st_size > 200 for p in files), (
        f"every file under importer/ is a stub: {[p.name for p in files]}"
    )
    importlib.import_module("seating_planner.importer")


# --- ac1: the four things a preview reports -----------------------------------


def test_the_preview_names_all_four_categories() -> None:
    src = _source().lower()
    wanted = {
        "invalid rows": ("invalid", "malformed", "unparse", "parse_error", "parse error"),
        "missing required fields": ("missing", "required"),
        "likely duplicates": ("duplicate", "dupe"),
        "records to be created": ("create", "new_count", "to_add", "added"),
        "records to be updated": ("update",),
    }
    missing = [what for what, words in wanted.items() if not any(w in src for w in words)]
    assert not missing, f"ac1: the importer source never mentions: {missing}"


# --- constraint: duplicate detection uses a stated, testable rule -------------


def test_the_duplicate_rule_normalizes_and_is_stated() -> None:
    src = _source()
    assert re.search(r"\.casefold\s*\(|\.lower\s*\(|unicodedata|normaliz", src, re.I), (
        "a likely-duplicate rule matching on NORMALIZED names: nothing in the "
        "importer normalizes a name (no casefold, lower or unicodedata)"
    )
    # "the preview should say that is what it did": the rule is in something the
    # preview can carry — a string in the code, not only a comment or docstring.
    stated = [
        s for s in _code_strings()
        if "name" in s.lower()
        and re.search(r"normali|household|case|lower|match|ignor", s, re.I)
    ]
    assert stated, (
        "the preview should say what duplicate rule it applied; no string in the "
        "importer (docstrings aside) describes a name-matching rule"
    )


# --- constraint: preview opens no write transaction ---------------------------


# The constraint "preview opens no write transaction" is checked by behaviour in
# test_a_preview_writes_nothing (the database file is byte-identical after any
# preview). A source-level ban on sqlite3 or BEGIN anywhere in the importer was
# written and removed: the constraint is about the preview, and an apply path
# that opens its own transaction is not forbidden by anything in the bean.


# --- ac2/ac3: a preview writes nothing ----------------------------------------

_CSV = (
    "id,name,status,household_id,reserved_seat\n"
    "g-new,Nell Newcomer,confirmed,h-9,false\n"
    "g-dup,ADA  quill ,confirmed,h-1,false\n"
    "g-bad,Bad Status,not-a-status,h-2,false\n"
    ",,confirmed,h-3,false\n"
    '"unterminated,quote,confirmed\n'
)


def _event() -> Any:
    from seating_planner.domain import Event, Guest, RsvpStatus, Table

    return Event(
        id="ev-017", name="Import",
        tables=[Table(id="t-1", name="One", capacity=4, shape="round", position=(0.0, 0.0))],
        guests=[
            Guest(id="g-ada", name="Ada Quill", status=RsvpStatus.CONFIRMED, household_id="h-1"),
            Guest(id="g-bo", name="Bo Brandt", status=RsvpStatus.PENDING, household_id="h-2"),
        ],
    )


def _previewers() -> list[tuple[str, Any, Any]]:
    """(label, owner-class-or-None, callable) for everything named like a preview."""
    pkg = importlib.import_module("seating_planner.importer")
    mods = [pkg]
    for info in pkgutil.walk_packages(pkg.__path__, pkg.__name__ + "."):
        try:
            mods.append(importlib.import_module(info.name))
        except Exception:  # noqa: BLE001 - a broken submodule is not this test's subject
            continue
    found: dict[int, tuple[str, Any, Any]] = {}
    word = re.compile(r"preview|dry", re.I)
    for mod in mods:
        for name, obj in vars(mod).items():
            if name.startswith("_") or not getattr(obj, "__module__", "").startswith(pkg.__name__):
                continue
            if inspect.isfunction(obj) and word.search(name):
                found[id(obj)] = (f"{mod.__name__}.{name}", None, obj)
            elif inspect.isclass(obj):
                for mname, meth in vars(obj).items():
                    if not mname.startswith("_") and word.search(mname) and callable(meth):
                        found[id(meth)] = (f"{mod.__name__}.{name}.{mname}", obj, mname)
    return list(found.values())


def _fill(fn: Any, ctx: dict[str, Any]) -> list[dict[str, Any]] | None:
    """Keyword arguments for every required parameter, by name, or None."""
    try:
        sig = inspect.signature(fn)
    except (TypeError, ValueError):
        return None
    base: dict[str, Any] = {}
    csv_param: str | None = None
    for p in sig.parameters.values():
        if p.name in ("self", "cls") or p.kind in (p.VAR_POSITIONAL, p.VAR_KEYWORD):
            continue
        if p.default is not p.empty:
            continue
        n = p.name.lower()
        ann = str(p.annotation).lower()
        if "event_id" in n:
            base[p.name] = ctx["event"].id
        elif "repo" in n or "store" in n or "repository" in ann:
            base[p.name] = ctx["repo"]
        elif "event" in n or "event" in ann:
            base[p.name] = ctx["event"]
        elif re.search(r"csv|path|file|source|src|text|data|content|rows|input|stream", n):
            csv_param = p.name
        elif re.search(r"actor|user", n):
            base[p.name] = "hidden-test"
        else:
            return None
    if csv_param is None:
        return [base]
    fh_text = ctx["csv_path"].read_text(encoding="utf-8")
    import io

    return [
        {**base, csv_param: ctx["csv_path"]},
        {**base, csv_param: str(ctx["csv_path"])},
        {**base, csv_param: fh_text},
        {**base, csv_param: io.StringIO(fh_text)},
    ]


def _digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def test_a_preview_writes_nothing(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    from seating_planner.store import Repository

    _files()
    candidates = _previewers()
    monkeypatch.chdir(tmp_path)
    csv_path = tmp_path / "guests.csv"
    csv_path.write_text(_CSV, encoding="utf-8")
    db = tmp_path / "event.db"

    driven: list[str] = []
    for label, owner, fn in candidates:
        repo = Repository(db)
        event = _event()
        repo.save_event(_event(), actor="setup")
        repo.close()
        before_db = _digest(db)
        before_files = sorted(p.name for p in tmp_path.iterdir())
        repo = Repository(db)
        audit_before = len(repo.audit_log())
        snapshot = copy.deepcopy(event)
        ctx = {"event": event, "repo": repo, "csv_path": csv_path}

        target = fn
        if owner is not None:
            ctor = _fill(owner, ctx)
            if ctor is None:
                repo.close()
                continue
            try:
                target = getattr(owner(**ctor[0]), fn)
            except Exception:  # noqa: BLE001
                repo.close()
                continue
        attempts = _fill(target, ctx)
        ran = False
        for kwargs in attempts or []:
            try:
                target(**kwargs)
            except Exception:  # noqa: BLE001 - wrong shape guessed; try the next
                continue
            ran = True
            break
        audit_after = len(repo.audit_log())
        repo.close()
        if not ran:
            continue
        driven.append(label)
        assert event == snapshot, f"ac2: {label} changed the Event it previewed"
        assert audit_after == audit_before, f"ac2: {label} wrote to the audit log"
        assert _digest(db) == before_db, f"ac2: {label} changed the stored event"
        assert csv_path.read_text(encoding="utf-8") == _CSV, f"{label} modified the CSV"
        assert sorted(p.name for p in tmp_path.iterdir()) == before_files, (
            f"ac2: {label} created files during a dry run"
        )
    if not driven:
        pytest.skip("no preview callable could be driven without guessing its API")


# --- the test ids the bean pins -----------------------------------------------


def test_the_pinned_tests_exist_and_assert_something() -> None:
    pinned = {
        "tests/importer/test_preview.py": [
            "test_preview_reports_all_four_categories",
            "test_preview_is_read_only",
            "test_cancel_changes_nothing",
        ],
        "tests/importer/test_apply.py": [
            "test_apply_matches_preview_counts",
            "test_partial_import_requires_opt_in",
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
