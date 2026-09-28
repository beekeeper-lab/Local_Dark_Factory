# bean-005 — Pre-flight feasibility checks before optimization

## What and why

A seating problem in this codebase is an `Event`: a set of `Table`s (each with a
name and a seating `capacity`), a set of `Guest`s (each with an RSVP status, from
which *eligibility* is *derived*: a Confirmed guest always counts; a Pending
guest counts only if a seat is reserved for them), a set of `Group`s (named bags
of guest ids), and a list of `Rule`s. A rule says how people may be seated —
*same table*, *different table*, *minimum distance* (from a named zone, like the
dance floor, or measured in metres), or *adjacent seat* — and it is either **hard**
(must hold in any answer) or **soft** (scored by weight).

As of today, nothing refuses an impossible problem before a solve is attempted.
A problem in which one guest pair is hard-ruled to sit *together* and also hard-ruled
to sit *apart*, or a ten-person family that no table holds, would go straight to the
constraint solver (CP-SAT, which arrives in bean-006) and come back as a bare
"infeasible". FR-041 asks for that to happen earlier and louder: **before
optimization, the system identifies contradictory hard constraints, groups larger
than every eligible table, unavailable required seats or zones, and insufficient
total capacity.**

So this bean adds one new package, `seating_planner.feasibility`, exposing a single
function, `run_preflight(event, zone_ids=None) -> list[Finding]`, that scans the
`Event` once by pure inspection — no search, no solver, no `ortools` import — and
returns one `Finding` per detected impossibility, each naming the entities involved.
The payoff is not speed alone: it reserves the solver's own "infeasible" for
genuinely hard cases, and it is what makes FR-050's later conflict report *explain*
a dead-end ("the Brides cannot fit any table") instead of merely declaring one.

## Current behaviour

All of the code this change reads was written by the earlier beans and is **not
modified here**. `src/seating_planner/feasibility/` does not exist yet — there is no
pre-flight step of any kind, and nothing in the repository references a feasibility
module, so there is no call site to update.

The inputs the checks will consume, from the real repository:

```python
# src/seating_planner/rules/__init__.py — what a rule is; the pre-flight reads, never evaluates, this
@dataclass
class Rule:
    id: str
    rule_type: RuleType   # SAME_TABLE | DIFFERENT_TABLE | MIN_DISTANCE | ADJACENT_SEAT
    hardness: Hardness    # HARD carries no weight; SOFT requires one (1..100)
    weight: int | None
    guest_ids: tuple[str, ...] = ()
    group_ids: tuple[str, ...] = ()
    table_ids: tuple[str, ...] = ()
    target: str | None = None       # a zone name, e.g. "dance_floor" — validated by nothing
    distance_m: float | None = None
    min_zones: int | None = None
    enabled: bool = True
```

```python
# src/seating_planner/domain/__init__.py — the three facts the checks lean on
    @property
    def eligible(self) -> bool:     # Guest: derived Confirmed / (Pending + reserved_seat)
        ...

@dataclass
class Event:
    tables: list[Table]             # Table.capacity: the only notion of "how many fits"
    guests: list[Guest]
    groups: list[Group]             # Group.member_ids: a bag of guest ids
    rules: list[object] = field(default_factory=list)   # deliberately untyped — the
                                                        # domain layer counts rules without
                                                        # knowing their shape
```

Three properties of this code matter for the design. First, `Event.rules` is
`list[object]` on purpose: the domain deliberately does not import the rules model,
so the pre-flight must `isinstance`-filter its rules before touching rule fields.
Second, eligibility is a *derived property*, so the capacity check must use
`guest.eligible`, not read `status` directly — the domain docstring warns that a
stored copy would drift. Third, there is **no zone registry anywhere**:
`Rule.target` is a free string (the template rule `template-accessible_seating`
points at `"dance_floor"`), and nothing in an `Event` enumerates which zones exist.
That shapes the one check this bean cannot implement unconditionally (see
*Open questions*).

## Proposed change

Two tasks (mirrored in `tasks.yaml`), in dependency order. Three new files, no
edits to existing code: `src/seating_planner/feasibility/__init__.py`,
`src/seating_planner/feasibility/preflight.py`, `tests/feasibility/test_preflight.py`.

**Task 1 — implement the module.** The public contract is fixed here, and the
message templates are pinned verbatim because task 2's tests assert on substrings
and FR-050's later conflict report will consume them:

```python
# src/seating_planner/feasibility/__init__.py
"""Pre-flight feasibility checks: structural impossibilities found by
inspection, before any solver run (bean-005). No solver imports, ever."""

from seating_planner.feasibility.preflight import Finding, run_preflight

__all__ = ["Finding", "run_preflight"]
```

```python
# src/seating_planner/feasibility/preflight.py — the public surface, with one
# representative check to fix the style (exact, ruff/mypy-strict clean)
@dataclass(frozen=True)
class Finding:
    """One pre-flight impossibility. code is a stable literal; message names
    every entity the acceptance criteria require it to name."""

    code: str
    message: str


def run_preflight(event: Event, zone_ids: frozenset[str] | None = None) -> list[Finding]:
    """Return the structural findings for event, in a fixed order, or []."""
    tables = {table.id: table for table in event.tables}
    groups = {group.id: group for group in event.groups}
    checks = (
        _contradictions(event.rules),
        _oversized_groups(event.rules, groups, tables),
        _capacity(event),
        _missing_tables(event.rules, tables),
        _missing_zones(event.rules, zone_ids),
    )
    findings: list[Finding] = []
    for check in checks:
        findings.extend(check)
    return findings


def _contradictions(event_rules: list[object]) -> list[Finding]:
    # one representative rule per (pair, kind); sorted ids keep the output
    # deterministic whatever order the rules arrive in
    same: dict[frozenset[str], Rule] = {}
    different: dict[frozenset[str], Rule] = {}
    for rule in sorted(_enabled_rules(event_rules), key=lambda r: r.id):
        if (
            rule.hardness is not Hardness.HARD
            or rule.rule_type not in (RuleType.SAME_TABLE, RuleType.DIFFERENT_TABLE)
            or len(rule.guest_ids) != 2
        ):
            continue
        (same if rule.rule_type is RuleType.SAME_TABLE else different).setdefault(
            frozenset(rule.guest_ids), rule
        )
    findings: list[Finding] = []
    for pair in sorted(same.keys() & different.keys(), key=lambda p: sorted(p)):
        same_rule, diff_rule = same[pair], different[pair]
        who = ", ".join(sorted(pair))
        findings.append(Finding("contradictory_hard_rules",
                                f"hard rules {same_rule.id!r} (same_table) and "
                                f"{diff_rule.id!r} (different_table) contradict for guests {who}"))
    return findings
```

The five checks, in the emission order above. Only **enabled** rules participate,
and `Event.rules` is filtered with `isinstance` before any attribute access:

| code | fires when | message (exact template) |
|---|---|---|
| `contradictory_hard_rules` | an enabled hard `SAME_TABLE` and an enabled hard `DIFFERENT_TABLE` share the same two-guest pair (order-insensitive) | `hard rules {same.id!r} (same_table) and {different.id!r} (different_table) contradict for guests {ids sorted, comma-joined}` |
| `group_larger_than_all_tables` | an enabled hard `SAME_TABLE` rule names a group via `group_ids` whose distinct `member_ids` exceed the largest `Table.capacity` in the event | `group {group.id!r} ({group.name}) must stay together at {size}, but the largest table seats {largest}` |
| `insufficient_capacity` | the count of guests with `guest.eligible` true exceeds `sum(table.capacity)` | `{eligible} eligible guests exceed {total} total seats` |
| `rule_missing_table` | an enabled rule's `table_ids` contains an id with no matching table | `rule {rule.id!r} references table {table_id!r}, which does not exist` |
| `rule_missing_zone` | only when `zone_ids is not None`: an enabled `MIN_DISTANCE` or `ADJACENT_SEAT` rule with a zone requirement (`target` set or `min_zones` set) names a target that is missing or not in `zone_ids` | `rule {rule.id!r} references zone {target!r}, which does not exist` |

With the default `zone_ids=None` the zone check is skipped: it is *not* a false
negative, it is the honest statement that no zone data exists to compare against
(see *Open questions*). Everything else is a single pass over rules, tables,
guests and groups — O(n) with at most one pair-dict per contradiction pair; no
search, no backtracking, no dependency beyond `seating_planner.domain` and
`seating_planner.rules`.

**Task 2 — the acceptance tests.** One file, `tests/feasibility/test_preflight.py`
(no `__init__.py`, matching the other test directories), one test per acceptance
criterion, named so each AC's `verify` test_id resolves. The file follows the
existing convention (module docstring, small `_table`/`_guest`/`_hard` factories,
plain asserts):

```python
# tests/feasibility/test_preflight.py — shape only; one test per AC
def test_contradictory_hard_rules() -> None:
    event = Event(
        id="e-1",
        name="Wedding",
        tables=[_table(0)],
        guests=[_guest(0), _guest(1)],
        rules=[
            _hard("r-same", RuleType.SAME_TABLE, guest_ids=("g-0", "g-1")),
            _hard("r-diff", RuleType.DIFFERENT_TABLE, guest_ids=("g-1", "g-0")),
        ],
    )
    findings = run_preflight(event)
    assert [f.code for f in findings] == ["contradictory_hard_rules"]
    assert "r-same" in findings[0].message
    assert "r-diff" in findings[0].message

# test_group_larger_than_any_table      — asserts "grp", its size "10" and the
#                                         largest capacity "8" appear in the message
# test_insufficient_capacity            — asserts both counts "4" and "3"
# test_rule_references_missing_target   — table branch without zone_ids, zone
#                                         branch with zone_ids=frozenset(...)
# test_feasible_problem_is_clean        — satisfiable event, mixed rule types,
#                                         run_preflight(...) == []
```

## Risk

The change is additive: three new files, zero edits to existing ones, so normal
regression risk is confined to "does the new code itself pass the gates" (it
cannot break existing tests it cannot import). The real risks are semantic:

1. **False positives** — a check too aggressive would flag *feasible* events and
   block real weddings. The template rule `template-accessible_seating` (a hard
   `MIN_DISTANCE` naming `dance_floor`) is the concrete near-miss: any zone check
   that fires by default would flag every stock template. It is handled by making
   the zone check opt-in via `zone_ids`, and `test_feasible_problem_is_clean`
   carries such a rule specifically to keep that true. How you'd notice a
   residual false positive: the clean-event test fails immediately.
2. **Checks too narrow** — contradictions that are only *implied* (a
   three-guest `SAME_TABLE` rule versus a `DIFFERENT_TABLE` on one of those
   pairs, or a conflict routed through two one-member groups) are not caught
   here; they still reach the solver. That is a declared, accepted boundary
   (see *Open questions*): the invariant backstop is that the solver still
   answers infeasible for them.
3. **Contract drift between tasks** — task 1 and task 2 are separate sessions
   with no shared memory, so the `code` literals and message templates above are
   pinned verbatim in this spec, and task 1's verification includes a behavioural
   smoke check that exercises four of the five checks before the tests exist.

Back-out is cheap and complete: delete `src/seating_planner/feasibility/` and
`tests/feasibility/`. Nothing imports the new package, no data is written, no
configuration or deployment changes ship with it, so a revert restores the exact
current behaviour.

## Blast radius

**Touched (all new files):**

- `src/seating_planner/feasibility/__init__.py` — package surface (re-exports).
- `src/seating_planner/feasibility/preflight.py` — the module and its five checks.
- `tests/feasibility/test_preflight.py` — the five acceptance tests.

**Read-only dependencies:** `seating_planner.domain` (`Event`, `Guest.eligible`,
`Table.capacity`, `Group.member_ids`) and `seating_planner.rules` (`Rule` and its
enums). Both are imported, never modified.

**Callers, data, deployments:** there are no callers yet — the solver built in
bean-006 is the first consumer of `run_preflight` — and the bean writes nothing
to disk: no persistence (that is bean-004's territory and out of scope), no
migration, no new dependency, and `ortools` stays out of this package by the
bean's `forbidden_imports` constraint.

**Explicitly not touched:** `src/seating_planner/domain/`, `src/seating_planner/rules/`,
the `store` package, `tests/domain/`, `tests/rules/`, `tests/test_scaffold.py`,
`pyproject.toml`, and everything under `factory/`.

## Verification

| AC | Criterion | verify |
|---|---|---|
| ac1 | same-table and different-table hard rules over one pair reported, both rules named | `pytest tests/feasibility/test_preflight.py::test_contradictory_hard_rules` |
| ac2 | togetherness group exceeding every table reported with group and largest capacity | `pytest tests/feasibility/test_preflight.py::test_group_larger_than_any_table` |
| ac3 | eligible guests exceeding total capacity reported with both counts | `pytest tests/feasibility/test_preflight.py::test_insufficient_capacity` |
| ac4 | rule naming a missing table or zone reported | `pytest tests/feasibility/test_preflight.py::test_rule_references_missing_target` |
| ac5 | satisfiable problem reports no findings | `pytest tests/feasibility/test_preflight.py::test_feasible_problem_is_clean` |

Task-level verification (run by the controller before the ACs above are
considered): task 1 passes on `ruff check`, `ruff format --check`, `mypy src`,
and a behavioural smoke check that drives the module through a contradiction,
an over-capacity, an oversized-group and a clean event; task 2 passes on
`pytest -q tests/feasibility/test_preflight.py` plus the two lint gates. The
repository gates (lint, format, types, and the unit gate with its 60% coverage
floor) apply to the whole tree afterwards; the new module's behaviour is fully
covered by the five tests, so the floor is unaffected.

Invariants: `seating-core` (`factory/invariants/seating.yaml`) does **not**
apply to this bean — its `applies_to` list is beans 006, 007, 009 and 013, and
its conformance seam (`seating_planner.invariant_api.solve_from_spec`) does not
exist yet and is a non-goal here. The bean's own constraints apply directly: no
`ortools` import anywhere in the new code (`forbidden_imports`), structural
checks only, never a search.

## Open questions

Nothing blocks the change; these are the assumptions the decomposition rests on,
declared rather than hidden:

1. **Zones cannot be validated from the `Event` alone.** FR-041 says "unavailable
   required seats **or zones**", but the domain defines no zone registry —
   `Rule.target` is a free string and constructing one would mean editing
   `src/seating_planner/domain/`, which the bean's `allowed_write_paths` forbid.
   The design's answer is the `zone_ids` parameter: zone references are checked
   exactly when a caller supplies the ids that exist, and skipped (not guessed)
   otherwise. If the line later decides zone definitions belong in the domain,
   that is a different bean.
2. **"A group that must stay together" is defined as a group named by an enabled
   hard `SAME_TABLE` rule** (via `group_ids`). A `Group` object on its own
   expresses nothing — it is a bag of ids — so only the rule confers
   togetherness. Group size is counted as *distinct* member ids, because the
   domain models `member_ids` as a bag.
3. **Contradiction scope is the direct pair only: two-guest hard
   `SAME_TABLE`/`DIFFERENT_TABLE` rules sharing a pair.** Implied contradictions
   (larger same-table sets, group-routed pairs) are left to the solver, in line
   with the non-goal "no attempt to prove general infeasibility".
4. **"Largest table" means the largest `capacity` among all tables in the
   event**; the domain has no notion of an *eligible* table, so no filtering is
   possible. An event with no tables has largest capacity 0, so any non-empty
   togetherness group is reported.
5. **Disabled rules (`enabled=False`) are ignored** by every check: a rule that
   is switched off cannot be unsatisfiable.
6. **An observation about the tree, not a conflict with the bean:**
   `src/seating_planner/store/` (bean-004's persistence work) is present only as
   `__pycache__` leftovers with no `.py` sources, even though the bean-004 run
   record shows the run completed and a PR was opened. bean-005 depends only on
   bean-003's artefacts (domain and rules), both of which are fully present, so
   this does not affect the plan — it is recorded here so nobody plans around
   a half-present package later. Likewise, the bean's background calls it "the
   first bean that reads code written by earlier beans", which bean-004 already
   was in fact.
