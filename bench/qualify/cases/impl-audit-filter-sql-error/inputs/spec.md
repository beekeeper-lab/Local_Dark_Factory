# Spec: Persistence with an append-only audit record (bean-004)

## What and why

The bean adds a SQLite-backed `src/seating_planner/store/` package: a `Repository`
that saves and loads a whole `Event` (tables, guests, groups, rules) behind one
seam — "the rest of the code asks the Repository to load and save events and is
ignorant of SQLite" — plus an `AuditLog` of "who changed which entity and when"
(FR-003, NFR-013). Every save is a single transaction, so a write that fails
partway leaves the previously committed state (ac3); and the audit log is
append-only in the database itself, so "attempts to modify or delete existing
entries are rejected" even from a raw `sqlite3` connection (ac4).

## Current behaviour

The domain and rules types already exist in the tree (beans 002/003); nothing
persists anything yet. Evidence:

- `src/seating_planner/domain/__init__.py` — plain dataclasses, in-memory only:

  ```python
  # src/seating_planner/domain/__init__.py (docstring, line 3):
  # These types are in-memory only: there is no persistence and no solver code in
  # this module.

  # src/seating_planner/domain/__init__.py
  @dataclass
  class Event:
      id: str
      name: str
      tables: list[Table] = field(default_factory=list)
      guests: list[Guest] = field(default_factory=list)
      groups: list[Group] = field(default_factory=list)
      # rules is deliberately list[object]: bean-003 owns the rule model and
      # this bean only counts rules, so the 5000 ceiling is enforceable now
      # without borrowing bean-003's shape (open question 5).
      rules: list[object] = field(default_factory=list)

      def add_rule(self, rule: object) -> None: ...
  ```

- `src/seating_planner/rules/__init__.py` — `Rule` is a dataclass with a stable
  dictionary form and an exact inverse, which is what the store serializes with:

  ```python
  @dataclass
  class Rule:
      def to_dict(self) -> dict[str, object]: ...
      @classmethod
      def from_dict(cls, data: Mapping[str, Any]) -> Rule: ...
  ```

- `ls src/seating_planner` gives `__init__.py  domain  rules` — no `store/`;
  `ls tests` gives `domain  rules  test_scaffold.py` — no `tests/store/`. The
  bean is the first in the project to write a byte of disk state.

## Proposed change

Four new files total (budget: 5 files / 6 tasks / 400 diff lines; actual:
4 files, 4 tasks). No existing file is modified.

### task-1 — `src/seating_planner/store/audit.py` (+ one-line `store/__init__.py` package anchor)

The append-only audit record. `AuditEntry` is a frozen dataclass
(`event_id`, `entity_type`, `entity_id`, `action`, `actor`, `timestamp` — the
five attribution facts ac2 names). `AuditLog.append(entry)` is the only write
path; the table and its two BEFORE triggers are created in the database, so
rejection of modification works for *any* connection, not just callers of the
API:

```sql
CREATE TABLE IF NOT EXISTS audit_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id TEXT NOT NULL, entity_type TEXT NOT NULL, entity_id TEXT NOT NULL,
    action TEXT NOT NULL, actor TEXT NOT NULL, timestamp TEXT NOT NULL);
CREATE TRIGGER IF NOT EXISTS audit_no_update BEFORE UPDATE ON audit_log
BEGIN SELECT RAISE(ABORT, 'audit log entries cannot be modified'); END;
CREATE TRIGGER IF NOT EXISTS audit_no_delete BEFORE DELETE ON audit_log
BEGIN SELECT RAISE(ABORT, 'audit log entries cannot be deleted'); END;
```

A `BEFORE ... RAISE(ABORT)` surface makes `raw.execute("UPDATE ..."/"DELETE ...")`
raise `sqlite3.IntegrityError` — that is the mechanism ac4's "attempts are
rejected" asserts. `entries(event_id=None)` returns rows `ORDER BY id`.

### task-2 — `src/seating_planner/store/__init__.py` (the `Repository`)

`StoreError(ValueError)` marks store-level failures raised *inside* the save
transaction. `save_event(event, *, actor)` is one transaction
(`with self._conn:`): upsert the `events` row, then for tables/guests/groups/
rules delete the event's old rows and re-insert the saved ones in list order
(last-write-wins per event, PRD 18.1), then append one audit entry per saved
entity (`event`/`table`/`guest`/`group`/`rule`, action `"upsert"`), all under
one UTC ISO-8601 timestamp taken once for the save. A rule that is not
serializable (the domain allows any object in `Event.rules`) raises
`StoreError`, the transaction rolls back, and the committed state — audit
entries included — is untouched. `load_event` rebuilds domain objects
(`RsvpStatus(status)`, `position_x/y -> (float, float)` tuple,
`Rule.from_dict(json)`) and constructs the `Event` in one call so the domain's
construction-time checks re-run. `audit_log(event_id=None)` delegates to the
`AuditLog`. Rules are stored as JSON of `Rule.to_dict()`; group members as a
JSON list of guest ids. Child rows are keyed `(event_id, id)`, matching the
domain's per-event uniqueness rule.

### task-3 — `tests/store/test_repository.py`

`test_event_roundtrip` (ac1): build an event with two tables (positions,
capacities, shapes), three guests spanning the status spellings plus
`household_id`/`reserved_seat`, a group, and two rules (soft + hard); save;
`close()`; open a *second* `Repository` on the same file and assert the loaded
event equals the saved one collection by collection.
`test_failed_write_is_atomic` (ac3): save a good event; append
`object()` to a second event's rules (domain allows it — store must refuse);
`pytest.raises(StoreError)` on `save_event`, then assert the loaded event is
the *original* and the audit log is byte-identical to before the attempt.

```python
# tests/store/test_repository.py
def test_failed_write_is_atomic(tmp_path: Path) -> None:
    ...
    repo.save_event(committed, actor="alice")
    audit_before = repo.audit_log()
    broken = _sample_event()
    broken.add_rule(object())
    with pytest.raises(StoreError):
        repo.save_event(broken, actor="bob")
    assert repo.load_event("e1") == committed
    assert repo.audit_log() == audit_before
```

### task-4 — `tests/store/test_audit.py`

`test_mutation_writes_audit_entry` (ac2): after one save, every entry has
`actor == "alice"`, a non-empty action, and an aware ISO-8601 `timestamp`
parseable by `datetime.fromisoformat`, and the `(entity_type, entity_id)` set
covers the event, table, guest and rule. `test_audit_log_is_append_only` (ac4):
a raw `sqlite3.connect` on the same file attempts `UPDATE audit_log` and
`DELETE FROM audit_log`; both raise `sqlite3.IntegrityError`, and the
repository's entries compare equal to before.

## Risk

- **Partial-write regression**: the ac3 test only holds because every write
  — including the audit appends — is inside the one `with self._conn:`
  transaction. A save that commits child rows before the audit (or vice versa)
  silently breaks NFR-013; the pinned test and task-2's `python -c` verify
  catch it at build time, not at the gate.
- **Trigger rejection mapping**: the design assumes `RAISE(ABORT)` surfaces as
  `sqlite3.IntegrityError` on Python 3.12 (it does; task-1's verify asserts it
  explicitly, so any mismatch fails in the worker sandbox, where it is cheap).
- **Rule JSON couples to bean-003's shape**: the store serializes with
  `Rule.to_dict()` and rebuilds with `Rule.from_dict()`. Nothing in
  `src/seating_planner/rules/` is touched; if the rule shape changes in a
  later bean, the store's round-trip test is the tripwire.
- **Clock realism**: audit timestamps are system-clock UTC ISO-8601; the ac2
  test asserts parseability and awareness within a one-hour window rather than
  exact equality, so the test cannot flake on a slow machine without
  weakening the assertion (a timestamp the caller supplies could be
  backdated — deliberately rejected).
- No data migration exists: this bean is the first writer, there is no
  existing state to break.

## Blast radius

New: `src/seating_planner/store/__init__.py`, `src/seating_planner/store/audit.py`,
`tests/store/test_repository.py`, `tests/store/test_audit.py`.

Unchanged: `src/seating_planner/domain/`, `src/seating_planner/rules/`,
all existing tests, `pyproject.toml`, everything under `factory/`. The
SQLite files the tests use live under `tmp_path`/`tempfile` — no `.sqlite`
artifact enters the diff. The gate's 60%-coverage floor counts `src`
(`tests/` is excluded via `--cov=src`), so the store module reaches it only
through genuinely exercising tests.

## Verification

| ID | Criterion | Verify |
|----|-----------|--------|
| ac1 | An event with guests, tables and rules saved can be reloaded matching what was saved | `pytest -q tests/store/test_repository.py::test_event_roundtrip` |
| ac2 | Every mutation writes an audit entry with actor, timestamp, entity type, and entity id | `pytest -q tests/store/test_audit.py::test_mutation_writes_audit_entry` |
| ac3 | A write that fails partway leaves the previously committed state intact | `pytest -q tests/store/test_repository.py::test_failed_write_is_atomic` |
| ac4 | The audit log is append-only; attempts to modify or delete existing entries are rejected | `pytest -q tests/store/test_audit.py::test_audit_log_is_append_only` |

Per-task verifies additionally run `mypy src`, `ruff check .`,
`ruff format --check .`, a forbidden-import grep (no service drivers, ORM,
migrations framework, at-rest encryption), and task-4 closes with the exact
unit gate: `pytest -q --cov=src --cov-report=term-missing --cov-fail-under=60`.
The bean carries no `invariants_ref`, so no invariants file applies to it.

## Open questions

Assumptions (the pinned ac-tests define the effective contract):

1. **Save granularity**: a whole-event `save_event(event, *, actor)` with
   per-event last-write-wins — the exact v1 the bean's background records as
   settled (PRD 18.1) — rather than per-entity mutation methods; "every
   mutation writes an audit entry" is implemented as one audit entry per
   entity the save writes.
2. **Actor is caller-supplied** (`actor=` keyword, required): FR-003 asks for
   "the identity of each user who makes a change" and no auth exists yet, so
   the store records what it is told and refuses to save without it.
3. **Timestamps are store-generated** UTC ISO-8601, taken once per save; a
   caller-supplied "time" could backdate the log, so the store does not
   accept one.
4. **Append-only is database-enforced** (BEFORE triggers with `RAISE(ABORT)`),
   not API-enforced — the pinned ac4 test's raw-connection attack would
   otherwise be untestable.
5. **`Event.rules` is `list[object]` by design**; the store serializes anything
   exposing a callable `to_dict` and raises `StoreError` for anything else.
   This is also the mechanism ac3's failing write uses (an `object()` rule),
   so no monkey-patching is needed to break a save mid-transaction.
6. **Child-row ids are unique per `(event_id, id)`**, matching the domain's
   per-event uniqueness validation rather than assuming global uniqueness.
