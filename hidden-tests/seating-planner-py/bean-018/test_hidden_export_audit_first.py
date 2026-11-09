"""Hidden test for bean-018's ac6 -- a private export never reaches disk without
its audit record, including when the audit record cannot be written.

Written after round 1 fixed the concrete names ac1-ac5's own test ids route
through: ``guest_to_table_export(event, assignments, include_private=..., actor=...)``
from ``seating_planner.export.csv_export``, returning an object whose
``write(csv_path, audit_log)`` persists the file. Round 1 wrote the CSV, THEN
opened the audit log: an unopenable audit path raised FileNotFoundError with the
private CSV already on disk and no audit line (pre-merge review, 2026-11-08).

Asserts only the behaviour: when the audit append cannot happen, write() raises
and no CSV exists at the target; a control case with a writable audit path
still writes both, so the fix cannot simply refuse every private write."""

from __future__ import annotations

import dataclasses
import importlib
import os
import sys
from pathlib import Path
from typing import Any

import pytest

WORK = Path(os.environ.get("HIDDEN_TREE", "/work"))
assert WORK.is_dir(), f"HIDDEN_TREE is not a directory: {WORK}"
_SRC = str(WORK / "src")
if _SRC not in sys.path:
    sys.path.insert(0, _SRC)


def _event() -> tuple[Any, dict[str, str]]:
    from seating_planner.domain import Event, Guest, RsvpStatus, Table

    have = {f.name for f in dataclasses.fields(Guest)}
    st = next(n for n in ("status", "rsvp_status") if n in have)
    guests = [Guest(id="g1", name="Ada Quill", **{st: RsvpStatus.CONFIRMED})]
    tables = [Table(id="t1", name="Oak", capacity=4, shape="round", position=(0.0, 0.0))]
    return Event(id="ev-audit", name="Audit", tables=tables, guests=guests, rules=[]), {"g1": "t1"}


def _export() -> Any:
    mod = importlib.import_module("seating_planner.export.csv_export")
    event, chart = _event()
    return mod.guest_to_table_export(
        event, chart, include_private=("locked_to_table",), actor="organizer@example.com"
    )


def test_unwritable_audit_path_leaves_no_private_csv(tmp_path: Path) -> None:
    bundle = _export()
    csv_path = tmp_path / "guests.csv"
    bad_audit = tmp_path / "no-such-dir" / "audit.jsonl"
    with pytest.raises(Exception):
        bundle.write(csv_path, bad_audit)
    assert not csv_path.exists(), (
        "the private CSV reached disk although its audit record could not be written"
    )


def test_audit_path_that_is_a_directory_leaves_no_private_csv(tmp_path: Path) -> None:
    bundle = _export()
    csv_path = tmp_path / "guests.csv"
    audit_dir = tmp_path / "audit.jsonl"
    audit_dir.mkdir()
    with pytest.raises(Exception):
        bundle.write(csv_path, audit_dir)
    assert not csv_path.exists()


def test_writable_audit_path_still_writes_both(tmp_path: Path) -> None:
    bundle = _export()
    csv_path = tmp_path / "guests.csv"
    audit = tmp_path / "audit.jsonl"
    bundle.write(csv_path, audit)
    assert csv_path.is_file()
    assert len(audit.read_text(encoding="utf-8").strip().splitlines()) == 1
