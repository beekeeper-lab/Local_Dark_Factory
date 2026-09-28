"""Hidden tests for bean-018 — exports exclude private notes unless explicitly included.

Written from bean-018.yaml before the bean ran. The bean fixes a path
(src/seating_planner/export/) and five test ids, and NO API: it does not say
what the export function is called, whether it returns text or writes a file,
or how it is handed the chart. Nothing here imports a name the bean does not fix.

Worth knowing: on main, `Guest` has no notes field and `Rule` has no
explanation, and this bean may not write the domain. So "private data" can only
reach an export through a field somebody adds later — which is exactly ac2's
scenario, and the background's reason for an allow-list.

What it asserts:

  * the package exists, is not a stub, and imports
  * the constraint "exports are built from an explicit field allow-list": the
    export never serializes a guest wholesale (vars(), __dict__, asdict(),
    astuple() on a guest)
  * ac3/ac4, as the weakest facts that are still facts: the export source
    speaks of a warning and of an audit entry
  * ac1/ac2, behaviourally where the API can be found without guessing: a Guest
    subclass carrying a NEW field with a sentinel note (commas, a newline and
    quotes around it, the shapes CSV escapes), and a Rule subclass carrying a
    sentinel explanation and a sentinel in its id, are handed to every public
    export callable whose required parameters can all be supplied by name (an
    event, a guest->table chart, an output path or stream). Every produced
    output that shows a guest's name must contain neither sentinel nor the new
    field's name. Callables whose names say private/include/sensitive/warn/audit
    are not called: they may be the deliberate opt-in. If nothing can be driven,
    the test SKIPS — it is extra reach, not a gate on naming.
  * the pinned test ids exist and assert something

Deliberately NOT asserted: the warning's wording or type, the audit entry's
shape (ac3, ac4), and ac5's one-row-per-guest — which of the callables is the
table-by-table export is not something the bean says.
"""

from __future__ import annotations

import ast
import dataclasses
import importlib
import inspect
import io
import os
import pkgutil
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import pytest

WORK = Path(os.environ.get("HIDDEN_TREE", "/work"))
assert WORK.is_dir(), f"HIDDEN_TREE is not a directory: {WORK}"
_SRC = str(WORK / "src")
if _SRC not in sys.path:
    sys.path.insert(0, _SRC)

PKG = WORK / "src" / "seating_planner" / "export"

NOTE_TOKEN = "ZQXNOTSPEAKING4417"
RULE_TOKEN = "ZQXRULEDEFN5521"
NEW_FIELD = "whispered_aside"


def _files() -> list[Path]:
    assert PKG.is_dir(), "bean-018 puts exports under src/seating_planner/export/"
    files = sorted(PKG.rglob("*.py"))
    assert files, "the export package is empty"
    return files


def _source() -> str:
    return "\n".join(p.read_text(encoding="utf-8") for p in _files())


def test_the_export_package_lives_where_the_bean_says_and_imports() -> None:
    files = _files()
    assert any(p.stat().st_size > 200 for p in files), (
        f"every file under export/ is a stub: {[p.name for p in files]}"
    )
    importlib.import_module("seating_planner.export")


# --- constraint: an explicit allow-list, not serialization --------------------


def test_no_guest_is_serialized_wholesale() -> None:
    # The background names the failure: "someone adds a field to a guest record
    # and the export picks it up automatically." Each of these picks up every
    # field there is. Only calls whose argument reads as a guest are counted, so
    # an export building its OWN row type and serializing that is not failed.
    # A name, not a substring: `asdict(guest_row)` on an allow-listed row type is
    # the allow-list working, and must not be failed.
    guestish = re.compile(r"(guest|g|gst|person|attendee|invitee)s?(\[[^\]]*\])?", re.I)
    offenders = []
    for path in _files():
        tree = ast.parse(path.read_text(encoding="utf-8"))
        for node in ast.walk(tree):
            if isinstance(node, ast.Call):
                fname = node.func.attr if isinstance(node.func, ast.Attribute) else getattr(node.func, "id", "")
                if fname in {"vars", "asdict", "astuple"} and node.args:
                    arg = ast.unparse(node.args[0])
                    if guestish.fullmatch(arg.split(".")[-1]):
                        offenders.append(f"{path.name}: {ast.unparse(node)}")
            elif isinstance(node, ast.Attribute) and node.attr == "__dict__":
                if guestish.fullmatch(ast.unparse(node.value).split(".")[-1]):
                    offenders.append(f"{path.name}: {ast.unparse(node)}")
    assert not offenders, (
        f"exports are built from an explicit allow-list; these serialize a guest "
        f"whole, so a new private field is exported by default: {offenders}"
    )


# --- ac3/ac4: a warning, and an audit entry -----------------------------------


def test_including_private_fields_warns_and_is_audited() -> None:
    src = _source().lower()
    assert "warn" in src, (
        "ac3: requesting private fields returns a warning; the export source "
        "never speaks of a warning"
    )
    assert "audit" in src, (
        "ac4: a private export writes an audit entry; the export source never "
        "mentions the audit"
    )


# --- ac1/ac2: a new private field never reaches a default export --------------


def _event() -> tuple[Any, dict[str, str], list[str]]:
    from seating_planner.domain import Event, Guest, RsvpStatus, Table
    from seating_planner.rules import Hardness, Rule, RuleType

    @dataclass
    class NosyGuest(Guest):
        whispered_aside: str = ""

    @dataclass
    class ExplainedRule(Rule):
        explanation: str = ""

    note = f'not speaking, "since the wedding"\n{NOTE_TOKEN}, keep apart'
    guests = [
        NosyGuest(id="g-1", name="Ada Quill", status=RsvpStatus.CONFIRMED,
                  household_id="h-1", whispered_aside=note),
        NosyGuest(id="g-2", name="Bo Brandt", status=RsvpStatus.CONFIRMED,
                  household_id="h-2", whispered_aside=note),
        NosyGuest(id="g-3", name="Cy Dorn", status=RsvpStatus.CONFIRMED,
                  whispered_aside=note),
    ]
    tables = [
        Table(id="t-1", name="Oak", capacity=4, shape="round", position=(0.0, 0.0)),
        Table(id="t-2", name="Elm", capacity=4, shape="round", position=(1.0, 0.0)),
    ]
    rules = [
        ExplainedRule(id=f"apart-{RULE_TOKEN}", rule_type=RuleType.DIFFERENT_TABLE,
                      hardness=Hardness.HARD, weight=None, guest_ids=("g-1", "g-2"),
                      explanation=f"override: {RULE_TOKEN} they fought"),
    ]
    event = Event(id="ev-018", name="Privacy", tables=tables, guests=guests, rules=rules)
    chart = {"g-1": "t-1", "g-2": "t-2", "g-3": "t-1"}
    return event, chart, [g.name for g in guests]


_OPT_IN = re.compile(r"private|sensitive|include|warn|audit|confirm|allow|field", re.I)


def _exporters() -> list[tuple[str, Any]]:
    pkg = importlib.import_module("seating_planner.export")
    mods = [pkg]
    for info in pkgutil.walk_packages(pkg.__path__, pkg.__name__ + "."):
        try:
            mods.append(importlib.import_module(info.name))
        except Exception:  # noqa: BLE001 - a broken submodule is not this test's subject
            continue
    found: dict[int, tuple[str, Any]] = {}
    for mod in mods:
        for name, obj in vars(mod).items():
            if (
                inspect.isfunction(obj)
                and not name.startswith("_")
                and getattr(obj, "__module__", "").startswith(pkg.__name__)
                and not _OPT_IN.search(name)
            ):
                found[id(obj)] = (f"{mod.__name__}.{name}", obj)
    return list(found.values())


def _fill(fn: Any, event: Any, chart: dict[str, str], out_dir: Path) -> list[tuple[dict[str, Any], list[io.StringIO]]] | None:
    try:
        sig = inspect.signature(fn)
    except (TypeError, ValueError):
        return None
    base: dict[str, Any] = {}
    chart_param = None
    streams: list[io.StringIO] = []
    for p in sig.parameters.values():
        if p.kind in (p.VAR_POSITIONAL, p.VAR_KEYWORD):
            continue
        if p.default is not p.empty:
            continue
        n = p.name.lower()
        if _OPT_IN.search(n):
            return None
        if "event" in n or "event" in str(p.annotation).lower():
            base[p.name] = event
        elif re.search(r"assign|chart|seat|placement|mapping|result|solution|plan|arrangement", n):
            chart_param = p.name
        elif re.search(r"path|dest|file|filename|target|output_dir|directory|dir$", n):
            base[p.name] = out_dir / "export.csv"
        elif re.search(r"stream|fp$|fh$|buffer|writer|^out$|sink|handle|io$", n):
            s = io.StringIO()
            streams.append(s)
            base[p.name] = s
        else:
            return None
    if chart_param is None:
        return [(base, streams)]
    by_table: dict[str, list[str]] = {}
    for g, t in chart.items():
        by_table.setdefault(t, []).append(g)
    return [({**base, chart_param: dict(chart)}, streams), ({**base, chart_param: by_table}, streams)]


def _strings(value: Any, depth: int = 0) -> list[str]:
    # What an export PRODUCED: strings, bytes, containers of them, and the
    # string attributes of a result object. Domain objects handed back are not
    # descended into — an export result that keeps a reference to its input
    # event has not exported that event's notes.
    from seating_planner.domain import Event, Group, Guest, Table
    from seating_planner.rules import Rule

    if depth > 4 or value is None:
        return []
    if isinstance(value, bytes):
        return [value.decode("utf-8", "replace")]
    if isinstance(value, str):
        return [value]
    if isinstance(value, (Event, Guest, Group, Table, Rule, int, float, bool)):
        return []
    if isinstance(value, dict):
        return [x for k, v in value.items() for x in _strings(k, depth + 1) + _strings(v, depth + 1)]
    if isinstance(value, (list, tuple, set, frozenset)):
        return [x for v in value for x in _strings(v, depth + 1)]
    if isinstance(value, io.StringIO):
        return [value.getvalue()]
    if dataclasses.is_dataclass(value):
        return [x for f in dataclasses.fields(value) for x in _strings(getattr(value, f.name, None), depth + 1)]
    attrs = getattr(value, "__dict__", None)
    if isinstance(attrs, dict):
        return [x for v in attrs.values() for x in _strings(v, depth + 1)]
    return []


def _texts(ret: Any, streams: list[io.StringIO], out_dir: Path) -> list[str]:
    texts = ["\n".join(_strings(ret))]
    texts.extend(s.getvalue() for s in streams)
    for f in out_dir.rglob("*"):
        if f.is_file():
            texts.append(f.read_bytes().decode("utf-8", "replace"))
    return texts


def test_a_default_export_carries_no_private_field(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    _files()
    monkeypatch.chdir(tmp_path)
    driven: list[str] = []
    leaks: list[str] = []
    for i, (label, fn) in enumerate(_exporters()):
        for j in range(2):
            out_dir = tmp_path / f"run-{i}-{j}"
            out_dir.mkdir()
            event, chart, names = _event()
            attempts = _fill(fn, event, chart, out_dir)
            if attempts is None or j >= len(attempts):
                break
            kwargs, streams = attempts[j]
            try:
                ret = fn(**kwargs)
            except Exception:  # noqa: BLE001 - wrong shape guessed; try the next
                continue
            texts = [t for t in _texts(ret, streams, out_dir) if any(n in t for n in names)]
            if not texts:
                continue
            driven.append(label)
            for t in texts:
                for token in (NOTE_TOKEN, RULE_TOKEN, NEW_FIELD):
                    if token in t:
                        leaks.append(f"{label} exported {token!r}")
    assert not leaks, (
        "ac1/ac2: a field added to the guest (or rule) model reached a default "
        f"export: {sorted(set(leaks))}"
    )
    if not driven:
        pytest.skip("no export callable could be driven without guessing its API")


# --- the test ids the bean pins -----------------------------------------------


def test_the_pinned_tests_exist_and_assert_something() -> None:
    pinned = {
        "tests/export/test_privacy.py": [
            "test_default_export_excludes_private_fields",
            "test_export_uses_allowlist_not_serialization",
            "test_private_export_warns_and_names_fields",
            "test_private_export_is_audited",
        ],
        "tests/export/test_csv.py": ["test_table_by_table_export_complete"],
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
