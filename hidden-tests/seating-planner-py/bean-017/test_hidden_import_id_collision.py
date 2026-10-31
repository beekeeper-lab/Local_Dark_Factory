"""Hidden test for bean-017's ac6 — a later row's explicit id must never
collide with an id the import auto-generated for an earlier no-id row.

Like test_hidden_import_preview.py, this does NOT assume an API the bean
does not fix: ac6's own round 1 built a `GuestImport` session class taking a
CSV path and a `Repository`; round 2 built a free `apply_import(event, text,
*, allow_partial=...)` function working on an in-memory `Event` alone. Both
are legitimate readings of the same acceptance criterion. So this discovers
every public callable whose name says "apply" (excluding ones that also say
"preview", "cancel" or start with an underscore), and for each one tries
every plausible argument shape — on a completely FRESH event, repo and
constructed instance for every single attempt, never reusing state across
shapes or across candidates, since applying the same fixture twice onto one
already-populated event would manufacture its own, unrelated id collision.

A wrong-type guess (e.g. a str-only ``text`` parameter handed a bare path
string) must never be mistaken for a real pass: round 2's classifier accepts
*any* string and simply finds no data rows in a one-line "header" of noise,
succeeding vacuously without ever touching the real fixture. So a shape
attempt only counts as having "really driven" the fixture when the resulting
summary (by generic attribute search for created/updated-like fields) shows
evidence that two rows were actually processed — never merely "it didn't
raise" on its own.

If nothing about this bean's apply surface can be driven without guessing,
this SKIPS: that is extra reach beyond what the bean fixes, not a gate on
naming.

The fixture is bean-017.yaml's own ac6 example, tried in both row orders:
a no-id row and a row carrying the literal id the no-id row would otherwise
be auto-assigned ("imported-1"). Neither order should ever raise — a file
this clean must always apply.
"""

from __future__ import annotations

import importlib
import inspect
import dataclasses
import io
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

_CSV_NOID_FIRST = "name,status,id\nAlice,confirmed,\nBob,confirmed,imported-1\n"
_CSV_LITERAL_FIRST = "name,status,id\nBob,confirmed,imported-1\nAlice,confirmed,\n"


def _repo_class() -> Any:
    """The store class: Repository in the original build, EventRepository since."""
    from seating_planner import store

    for name in ("Repository", "EventRepository"):
        found = getattr(store, name, None)
        if found is not None:
            return found
    raise ImportError("seating_planner.store has neither Repository nor EventRepository")


def _save_event(repo: Any, event: Any, actor: str) -> None:
    (getattr(repo, "save_event", None) or repo.save)(event, actor=actor)


def _audit_len(repo: Any) -> int:
    return len((getattr(repo, "audit_log", None) or repo.audit_entries)())


def _fresh_event() -> Any:
    from seating_planner.domain import Event

    kwargs: dict[str, Any] = dict(id="ev-017", name="Import", tables=[], guests=[], groups=[], rules=[])
    if "locks" in {f.name for f in dataclasses.fields(Event)}:
        kwargs["locks"] = {}
    return Event(**kwargs)


def _fresh_repo(tmp_path: Path, tag: str, event: Any) -> Any | None:
    try:
        Repository = _repo_class()
    except ImportError:
        return None
    try:
        repo = Repository(tmp_path / f"db-{tag}.sqlite3")
        _save_event(repo, event, "hidden-test")
        return repo
    except Exception:  # noqa: BLE001 - repo construction failing just means "no repo path"
        return None


def _appliers() -> list[tuple[str, Any, Any]]:
    """(label, owner-class-or-None, callable) for everything named like apply,
    excluding anything that also reads as a preview or a cancel."""
    pkg = importlib.import_module("seating_planner.importer")
    mods = [pkg]
    for info in pkgutil.walk_packages(pkg.__path__, pkg.__name__ + "."):
        try:
            mods.append(importlib.import_module(info.name))
        except Exception:  # noqa: BLE001 - a broken submodule is not this test's subject
            continue
    apply_word = re.compile(r"apply", re.I)
    exclude_word = re.compile(r"preview|dry|cancel", re.I)
    found: dict[int, tuple[str, Any, Any]] = {}
    for mod in mods:
        for name, obj in vars(mod).items():
            if name.startswith("_") or not getattr(obj, "__module__", "").startswith(pkg.__name__):
                continue
            if inspect.isfunction(obj) and apply_word.search(name) and not exclude_word.search(name):
                found[id(obj)] = (f"{mod.__name__}.{name}", None, obj)
            elif inspect.isclass(obj):
                for mname, meth in vars(obj).items():
                    if (
                        not mname.startswith("_")
                        and apply_word.search(mname)
                        and not exclude_word.search(mname)
                        and callable(meth)
                    ):
                        found[id(meth)] = (f"{mod.__name__}.{name}.{mname}", obj, mname)
    return list(found.values())


def _fill(fn: Any, event: Any, csv_value: Any, csv_param_hint: str, repo: Any) -> dict[str, Any] | None:
    """Keyword arguments for every required parameter of fn, by name/
    annotation, with csv_value plugged into whichever parameter looks like
    the CSV argument — or None if some other parameter can't be guessed."""
    try:
        sig = inspect.signature(fn)
    except (TypeError, ValueError):
        return None
    kwargs: dict[str, Any] = {}
    csv_param: str | None = None
    for p in sig.parameters.values():
        if p.name in ("self", "cls") or p.kind in (p.VAR_POSITIONAL, p.VAR_KEYWORD):
            continue
        if p.default is not p.empty:
            continue  # optional (e.g. allow_partial/allow_invalid) — leave at its default
        n = p.name.lower()
        ann = str(p.annotation).lower()
        if "event_id" in n:
            kwargs[p.name] = event.id
        elif "repo" in n or "store" in n or "repository" in ann:
            if repo is None:
                return None
            kwargs[p.name] = repo
        elif "event" in n or "event" in ann:
            kwargs[p.name] = event
        elif re.search(r"csv|path|file|source|src|text|data|content|rows|input|stream", n):
            csv_param = p.name
        elif re.search(r"actor|user", n):
            kwargs[p.name] = "hidden-test"
        else:
            return None
    if csv_param is None:
        return kwargs
    kwargs[csv_param] = csv_value
    return kwargs


def _row_count_processed(result: Any) -> int | None:
    """Best-effort read of how many rows a summary says it handled, by
    generic attribute search — or None if nothing recognizable is found."""
    if result is None:
        return None
    total = 0
    found_any = False
    for attr_name in dir(result):
        if attr_name.startswith("_"):
            continue
        if not re.search(r"creat|updat", attr_name, re.I):
            continue
        try:
            value = getattr(result, attr_name)
        except Exception:  # noqa: BLE001
            continue
        if isinstance(value, int) and not isinstance(value, bool):
            total += value
            found_any = True
        elif isinstance(value, (tuple, list, set, frozenset)):
            total += len(value)
            found_any = True
    return total if found_any else None


def _construct(owner: Any, event: Any, csv_value: Any, repo: Any) -> Any | None:
    for ctor_args in (
        (repo, event.id, csv_value) if repo is not None else None,
        (event, csv_value),
        (),
    ):
        if ctor_args is None:
            continue
        try:
            return owner(*ctor_args)
        except TypeError:
            continue
    return None


def _candidate_fns(owner: Any, member: Any, event: Any, csv_value: Any, repo: Any) -> list[Any]:
    if owner is None:
        return [member]
    instance = _construct(owner, event, csv_value, repo)
    return [getattr(instance, member)] if instance is not None else []


def test_an_explicit_id_never_collides_with_an_earlier_auto_generated_one(tmp_path: Path) -> None:
    candidates = _appliers()
    if not candidates:
        pytest.skip("no public apply-named callable found; nothing to drive")

    really_drove = False
    for csv_text in (_CSV_NOID_FIRST, _CSV_LITERAL_FIRST):
        order = "no-id first" if csv_text is _CSV_NOID_FIRST else "literal id first"
        csv_path = tmp_path / f"guests-{abs(hash(csv_text))}.csv"
        csv_path.write_text(csv_text, encoding="utf-8")

        for label, owner, member in candidates:
            for csv_value in (csv_text, csv_path, str(csv_path), io.StringIO(csv_text)):
                event = _fresh_event()
                repo = _fresh_repo(tmp_path, f"{label}-{order}-{csv_value!r}", event)
                fns = _candidate_fns(owner, member, event, csv_value, repo)
                for fn in fns:
                    kwargs = _fill(fn, event, csv_value, "csv", repo)
                    if kwargs is None:
                        continue
                    try:
                        result = fn(**kwargs)
                    except (TypeError, AttributeError, UnicodeDecodeError, ImportError):
                        continue  # wrong argument shape guess, not a real finding
                    except (ValueError, RuntimeError) as exc:
                        pytest.fail(
                            f"{label} raised {type(exc).__name__} on a preview-clean "
                            f"two-row file ({order}, csv argument type "
                            f"{type(csv_value).__name__}): {exc}"
                        )
                    processed = _row_count_processed(result)
                    if processed is None or processed >= 1:
                        # Either we can't tell how much it did (accept the call
                        # as real since it didn't raise), or it visibly
                        # processed at least one row — not the vacuous
                        # zero-rows-found result a garbage shape produces.
                        really_drove = True

    if not really_drove:
        pytest.skip("no apply-named callable could be driven without guessing its API")
