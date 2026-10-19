"""Hidden test for bean-017's ac6 — a later row's explicit id must never
collide with an id the import auto-generated for an earlier no-id row.

Unlike test_hidden_import_preview.py (written before bean-017 ever ran, and
deliberately blind to its API), this file is written after round 1 fixed the
concrete API: ``preview_import(event, csv_path) -> Preview`` and
``GuestImport(repo, event_id, csv_path).apply(actor=...) -> Preview``, with
``Preview.would_create``/``invalid``/``missing``/``duplicates``. ac6 is
specifically about that now-known ``apply()`` entry point's behaviour, so
assuming the real names is the only way to test it meaningfully — a blind
test could not reach the bug at all.

The fixture is the one bean-017.yaml's background gives verbatim: row 1 has
no id (so an id-colliding implementation assigns it "imported-1"), row 2
carries the literal id "imported-1", matching no existing guest. Against an
empty event this previews as entirely clean (would_create == 2, nothing
invalid/missing/duplicate) — and a correct implementation must still apply
it without error, ending with two guests whose ids are distinct.
"""

from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

import pytest

WORK = Path(os.environ.get("HIDDEN_TREE", "/work"))
assert WORK.is_dir(), f"HIDDEN_TREE is not a directory: {WORK}"
_SRC = str(WORK / "src")
if _SRC not in sys.path:
    sys.path.insert(0, _SRC)

CSV_CONTENT = "name,status,id\nAlice,confirmed,\nBob,confirmed,imported-1\n"


def _build_importer(tmp_path: Path):
    from seating_planner.domain import Event
    from seating_planner.importer.guest_import import GuestImport, preview_import
    from seating_planner.store import Repository

    csv_path = tmp_path / "guests.csv"
    csv_path.write_text(CSV_CONTENT)
    db_path = tmp_path / "db.sqlite3"

    event = Event(id="e1", name="Test Event", tables=[], guests=[], groups=[], rules=[], locks={})
    preview = preview_import(event, csv_path)

    repo = Repository(db_path)
    repo.save_event(event, actor="test")
    importer = GuestImport(repo, "e1", csv_path)
    return preview, importer, repo


def test_a_preview_clean_file_always_applies_without_error(tmp_path: Path) -> None:
    preview, importer, repo = _build_importer(tmp_path)

    # Guard: the fixture previews as entirely clean — the crash this test
    # guards against happens on exactly this shape of innocent-looking file.
    assert preview.would_create == 2
    assert preview.would_update == 0
    assert preview.invalid == ()
    assert preview.missing == ()
    assert preview.duplicates == ()

    result = importer.apply(actor="test")

    assert result.would_create == 2
    final_guests = repo.load_event("e1").guests
    assert len(final_guests) == 2
    ids = [g.id for g in final_guests]
    assert len(set(ids)) == 2, f"duplicate guest ids after apply: {ids}"
    assert "imported-1" in ids  # Bob's literal id is honoured
