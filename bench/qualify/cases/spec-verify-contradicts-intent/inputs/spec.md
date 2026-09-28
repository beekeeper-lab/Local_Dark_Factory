# bean-003 — Structured seating rules with hardness, weight and the wedding template

## What and why

The product's first principle is that rules are explicit: no seating rule may be
prose, and no seating rule may exist only inside a prompt or hidden model
context. A *rule* in this product is a statement like "these two guests must
sit at the same table" or "keep this guest away from the dance floor", and for
the rest of the system to do anything with it — pre-flight checks (bean-005),
the CP-SAT solver (bean-006), soft-constraint scoring (bean-007), violation
reporting (bean-008) — the rule must exist as inspectable structured data with
four things pinned down: a **type** (what kind of statement it is), a
**hardness** (hard = may not be violated; soft = a preference), a **weight**
(for soft rules: an integer 1–100 expressing how much the preference matters),
and whatever **parameters** the type needs, such as a distance. This bean
builds exactly that data model in a new `seating_planner.rules` package, and
the second thing the requirements ask for: a new wedding event should start
from an editable default rule template covering couples, households, immediate
family, wedding party, children, vendors and accessible seating (FR-028/029).
The sharp edge is FR-035: a *minimum-distance* rule must carry a number — a
distance or a zone count — so the vague phrase "far apart" is rejected at
construction time rather than stored as something a solver later pretends to
enforce. This bean is data only: it contains no rule evaluation, no scoring and
no solver code — those are later beans, and this one's job is to make the
shape they consume impossible to get wrong.

## Current behaviour

The `rules` package does not exist yet. What exists is bean-002's domain
model, which already anticipated this bean: `Event` carries a `rules` field
typed deliberately as `list[object]` — bean-003 owns the rule model, so
bean-002 could only *count* rules (enforcing the 5000-rule ceiling from its
own open question 5) without borrowing a shape it was not allowed to define
(`src/seating_planner/domain/__init__.py`, as now in the tree):

```python
@dataclass
class Event:
    # rules is deliberately list[object]: bean-003 owns the rule model and
    # this bean only counts rules, so the 5000 ceiling is enforceable now
    # without borrowing bean-003's shape (open question 5).
    id: str
    name: str
    tables: list[Table] = field(default_factory=list)
    guests: list[Guest] = field(default_factory=list)
    groups: list[Group] = field(default_factory=list)
    rules: list[object] = field(default_factory=list)
```

with `MAX_RULES: Final[int] = 5000` and an `add_rule` that enforces the
ceiling. Today nothing constrains what a "rule" is — any `object()` passes —
and `tests/` holds only `tests/test_scaffold.py` beside `tests/domain/`. That is the
hole this bean closes: after it, the only thing that can be put in
`Event.rules` and still round-trip through serialization is a validated
`Rule`, and a new wedding starts with seven sensible, individually
enable-able rules instead of an empty list.

## Proposed change

Four new files, in dependency order (task numbers match
`tasks.yaml`); nothing is modified, only added.

**task-1** — `src/seating_planner/rules/__init__.py`: the rule model. Two
enums — `Hardness` (`hard`/`soft`) and `RuleType` (`same_table`,
`different_table`, `min_distance`, `adjacent_seat`) — and one `Rule`
dataclass whose `__post_init__` is where every FR edge is enforced:

```python
src/seating_planner/rules/__init__.py
class Rule:  # dataclass
    id: str
    rule_type: RuleType
    hardness: Hardness
    weight: int | None
    guest_ids: tuple[str, ...] = ()
    group_ids: tuple[str, ...] = ()
    table_ids: tuple[str, ...] = ()
    target: str | None = None
    distance_m: float | None = None
    min_zones: int | None = None
    enabled: bool = True
    # __post_init__: hard rule + weight -> ValueError; soft rule without an
    # integer weight in 1..100 -> ValueError; MIN_DISTANCE without a numeric
    # distance_m > 0 or min_zones >= 1 -> ValueError (FR-035)
```

`to_dict()` serialises to plain data using the spelling the independent
invariants' solver seam already assumes (`"kind": "same_table"`, `"hardness":
"hard"`) and `Rule.from_dict()` reparses it through the same constructors, so
construction-time and deserialisation-time validation are the same code and
every rule round-trips unchanged.

**task-2** — `tests/rules/test_rule_model.py`: the four AC-pinned test
functions — `test_all_rule_types_roundtrip` (one representative rule per
`RuleType`, `Rule.from_dict(r.to_dict()) == r` for each),
`test_soft_weight_bounds` (1 and 100 in; 0, 101, -1, 3.5, "50", None, True
out), `test_hard_rule_has_no_weight` (hard stores `None`; hard + weight=50
raises), `test_min_distance_requires_measure` (accepted with `distance_m=3.0`
or `min_zones=2`; rejected with neither, zero, negative, or the string
`"far apart"`).

**task-3** — `src/seating_planner/rules/template.py`: the editable default
template. One function, no state, so events can never share a rule object:

```python
src/seating_planner/rules/template.py
TEMPLATE_CATEGORIES = {"couples": "Couples", "households": "Households",
  "immediate_family": "Immediate family", "wedding_party": "Wedding party",
  "children": "Children", "vendors": "Vendors",
  "accessible_seating": "Accessible seating"}

def default_wedding_rules() -> list[Rule]:
    # seven fresh Rule objects, one per category, id f"template-{slug}",
    # group_ids (slug,) as the editable attachment point, all enabled:
    # couples/households/immediate_family/wedding_party/children:
    #   same_table, soft, weights 80/50/90/70/60
    # vendors:            different_table, soft, weight 40
    # accessible_seating: min_distance, hard, target "dance_floor",
    #                     min_zones 2 (a hard rule carries no weight)
```

**task-4** — `tests/rules/test_template.py`: the single AC-pinned test
`test_default_wedding_template`, asserting exactly seven rules, exactly the
seven categories, each re-serialisable, each starting enabled, and independence
in the strong sense — toggling one rule's `enabled` changes exactly one flag,
and a second call returns fresh objects all enabled again.

## Risk

The blast is small by construction: two new modules and two new test files,
no existing file is touched, `Event.rules` keeps its `list[object]` type so
nothing upstream changes, and the package imports only the standard library —
a `grep` in the task list fails the attempt if `ortools` appears anywhere,
which is the check that keeps the "no solver imports" constraint out of the
judge's head. The risks that remain are shape risks, all later-facing: if the
serialised spelling of a field does not match what bean-005…008 expect, they
rework the field name in their own paths (cheap, their own files); if the
`adjacent_seat` type is missing or misspelled, bean-020's "constructible"
claim breaks (its background quotes it verbatim); if a category is missing
from the template, ac5 fails *now*, loudly, in its own pinned test. How we
would notice is that this run's gates are exactly the checks: the four + one
pinned tests, the 60%-coverage unit gate, ruff, and mypy strict. Backout is a
single revert of one commit — the bean adds files only — with no data to
migrate because nothing persists rules yet (bean-004 is the persistence bean)
and no state to unwind because nothing has been written by users.

## Blast radius

**Touched:** exactly four new files — `src/seating_planner/rules/__init__.py`,
`src/seating_planner/rules/template.py`, `tests/rules/test_rule_model.py`,
`tests/rules/test_template.py` (4 of the 5-file budget).
**Explicitly not touched:** the domain package (bean-002's, including
`Event.rules`, whose `list[object]` typing stays), every existing test
(`tests/domain/`, `tests/test_scaffold.py`), `pyproject.toml`, and `factory/**`.
**Not touched, by the bean's own non-goals:** no `feasibility/` or `solver/`
code (bean-005/006+007's paths), no rule evaluation or scoring of any kind,
no adjacent-seat *evaluation* (only the constructible type; bean-020 owns the
unevaluable reporting), no natural-language rule parsing, no persistence
(bean-004). `Event.add_rule` keeps accepting `object` — tightening it to
`Rule` would mean writing bean-002's file, so rules of type `Rule` simply
become what everything downstream expects to find in `Event.rules`. No
deployment or data surface: the package is in-memory only, matching the
domain's stated posture.

## Verification

| AC | Criterion | verify |
|---|---|---|
| ac1 | Every rule type named in FR-034 can be constructed and round-trips through serialization unchanged. | `test` `tests/rules/test_rule_model.py::test_all_rule_types_roundtrip` |
| ac2 | A soft rule requires an integer weight in 1..100 and rejects values outside it. | `test` `tests/rules/test_rule_model.py::test_soft_weight_bounds` |
| ac3 | A hard rule carries no weight, and constructing one with a weight is rejected. | `test` `tests/rules/test_rule_model.py::test_hard_rule_has_no_weight` |
| ac4 | A minimum-distance rule without a numeric distance or zone count is rejected. | `test` `tests/rules/test_rule_model.py::test_min_distance_requires_measure` |
| ac5 | The default wedding template yields rules for couples, households, immediate family, wedding party, children, vendors and accessible seating, each independently enable-able. | `test` `tests/rules/test_template.py::test_default_wedding_template` |

Plus the run's own gates (`factory/gates.lock.yaml`): `ruff check`, `ruff
format --check`, `mypy src` strict, and `pytest -q --cov=src --cov-fail-under=60`.
Constraint checks beyond the tests: no `ortools` (or any solver) import in the
rules package — enforced per task by `! grep -rn ortools src/seating_planner/rules/`,
and data-only-ness (evaluation logic) by review in the ac tests' absence of any
scoring code. Invariants: the bean carries no `invariants_ref`;
`factory/invariants/seating-core` applies to bean-006/007/009/013, and this
bean's only relationship to it is that `Rule.to_dict`'s spelling (`"kind"`,
`"hardness": "hard"`) matches that seam's `spec_shape` so a later
`invariant_api` layer can pass rules through unchanged.

## Open questions

1. **The FR-034 rule-type list is evidenced, not quoted.** The requirements
   file (`benchmark/seating-planner/requirements/REQUIREMENTS.md`) is not in
   the tree. The four types — `same_table`, `different_table` (the
   independent invariants' `spec_shape` names both kinds), `min_distance`
   (FR-035, quoted in the bean) and `adjacent_seat` (bean-020: "FR-034 still
   allows an adjacent-seat rule to be created, and bean-003 makes such a
   rule constructible") — are every rule type the tree evidences. **Assumed:
   these four are the complete FR-034 set.** If a fifth type exists in the
   requirements, adding it is one enum member plus one round-trip case — a
   build-time fix inside these same paths, not a redesign.
2. **Category-to-rule-type mapping in the template is default data, not
   requirement text.** FR-028/029 name the seven categories but not their
   types, hardnesses or weights. **Assumed:** the people-groups (couples,
   households, immediate family, wedding party, children) are soft
   same-table rules, vendors is a soft different-table rule, and accessible
   seating is a hard min-distance rule (away from the dance floor). These are
   exactly the defaults FR-028/029 call *editable*, and ac5 pins only the
   categories and their independence.
3. **`enabled: bool = True` is a field on `Rule` itself.** "Each
   independently enable-able" needs a per-rule on/off; a flag on the data
   class is the only reading that makes independence structural rather than
   a caller convention. The flag round-trips with the rule.
4. **Template rules reference categories, not guests.** A new event's guests
   are not known to the template, so each default rule attaches to the
   category slug via `group_ids=(slug,)` — the user binds real guests to the
   group later. **Assumed:** an unbound template rule (no guests named yet)
   is valid *data*; the bean's constraint is that rules are data only, and
   nothing in it evaluates a rule, so an unbound rule costs nothing here.
   Subject non-emptiness and referencing existing guests/tables/zones get
   checked where targets can be checked — bean-005's pre-flight names
   missing-table/zone rules in its own ac.
5. **`min_distance`'s target stays optional at construction.** FR-035's
   quoted edge is the number; requiring a `target` (the zone or feature the
   guest is kept away from) was judged a bean-005 concern ("a rule naming a
   table or zone that does not exist is reported" is pre-flight's ac), so
   the constructor enforces the measure and leaves the target's existence to
   the event check.
