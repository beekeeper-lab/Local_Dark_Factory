# bean-007 — Soft-constraint scoring and the optimization objective

## What and why

bean-006 shipped a solver that answers "does any valid seating chart exist, and
if so, here is one": any valid chart. This bean makes it answer "here is the
*best* valid chart". The promise, from the requirements, is: after every hard
constraint is satisfied, the optimizer maximizes the **weighted total of
satisfied soft constraints**. Each soft rule that the table model can express
gets an indicator — a boolean that is true exactly when the rule holds in the
returned chart — and the solver is instructed to maximize the sum of each
indicator times the rule's integer weight (1–100, already enforced by the
rules model).

The part that matters and is explicitly not negotiable is the ordering: hard
constraints stay *constraints* in the solver's language, never heavily-weighted
preferences. A soft rule carrying the maximum weight of 100 must be unable to
drag the answer into a chart that breaks a hard rule. That property is not
something this bean can test into existence by comparing two charts; it follows
from the structure of the model — CP-SAT never returns any solution in which a
constraint is violated, whatever the objective — so the design is to leave
bean-006's constraints untouched and add a single objective on top that the
solver is allowed to chase only inside the set of hard-feasible charts.

A newcomer needs four facts from the existing code. First, the model the
objective is added to: `src/seating_planner/solver/hard.py` builds, for every
eligible guest and every table, one CP-SAT boolean `at[guest][table]`, requires
each guest sits at exactly one table, caps each table at its capacity, and
encodes every expressible hard rule; a rule of any other kind raises
`ValueError` — a hard rule the model cannot express is rejected, never
silently dropped. Second, rules are data: `Rule` carries `rule_type`
(`same_table`, `different_table`, `min_distance`, `adjacent_seat`),
`hardness` (`hard` or `soft`), and `weight` — an `int | None` that the rules
model forces to be in 1–100 for every soft rule and `None` for every hard one.
Third, `Event.rules` is typed `list[object]` because the domain layer refuses
to know the rules model, so the solver `isinstance`-filters before reading any
rule field — the hard path already does this and the soft path must do the
same. Fourth, only `same_table` and `different_table` have a table-level
reading; `min_distance` and `adjacent_seat` reason about zones and individual
seats, which this model does not track — hard ones of those kinds are already
refused with `ValueError`, and soft ones are currently ignored, which this
plan keeps: a soft rule the model cannot express simply does not count toward
the score, and that is honest, because the solver can genuinely do nothing
about it.

What changes is one function and its surroundings: `_build_model` grows an
objective, `solve_event`'s one-line contract grows from "a valid chart" to
"the highest-scoring valid chart", and three new acceptance tests check the
ordering the bean promises. No new module, no new call path, no change to the
`invariant_api` seam the invariants run through — it keeps calling
`solve_event` with the same signature.

## Current behaviour

`_build_model` in `src/seating_planner/solver/hard.py` builds the model the
objective will join. Quoted verbatim from the real repository:

```python
# src/seating_planner/solver/hard.py
def _build_model(event: Event, eligible: list[str]) -> tuple[Any, dict[str, dict[str, Any]]]:
    model: Any = cp_model.CpModel()
    # at[guest][table] is the "guest sits at table" boolean; ineligible guests
    # get no variables, which excludes them from every result by construction.
    at = {
        guest_id: {t.id: model.NewBoolVar(f"at_{guest_id}_{t.id}") for t in event.tables}
        for guest_id in eligible
    }

    for guest_id in eligible:
        model.AddExactlyOne(at[guest_id].values())
    for table in event.tables:
        model.Add(sum(at[guest_id][table.id] for guest_id in eligible) <= table.capacity)
    _add_rule_constraints(model, event, at)
    return model, at
```

Today there is no `model.Maximize` call anywhere in the package: the solver
stops as soon as CP-SAT finds the *first* hard-feasible chart, which one is
whatever the search hits first (deterministic for a fixed seed and worker
count, but arbitrary in quality). The hard rule encoding — quoted from the same
file, and the template the soft path copies — resolves a rule's targets
(`guest_ids` plus the members of every referenced group, deduped, restricted to
guests that have variables) and for every pair and every table adds

```python
# src/seating_planner/solver/hard.py (hard SAME_TABLE / hard DIFFERENT_TABLE)
        for first, second in combinations(targets, 2):
            for table_id, var_a in at[first].items():
                var_b = at[second][table_id]
                if rule.rule_type is RuleType.SAME_TABLE:
                    model.Add(var_a == var_b)
                else:
                    model.Add(var_a + var_b <= 1)
```

The soft rules sit unused. `_hard_rules` filters them out, so a
weight-100 soft rule and a weight-1 soft rule mean exactly nothing to the
model, and the package docstring says so out loud: "Soft scoring is not part
of this package (bean-007)". That is the only "before". Everything this bean
touches exists; no new file in `src/` is expected.

## Proposed change

Two tasks, in dependency order. Task 1 changes the model; task 2 adds the
acceptance tests. Together they touch three files
(`src/seating_planner/solver/hard.py`, `src/seating_planner/solver/__init__.py`,
`tests/solver/test_objective.py`), inside the bean's 350-line budget.

### task-1 — the objective in `src/seating_planner/solver/hard.py`

`_build_model` additionally calls a new `_add_soft_objective(model, event, at)`
before returning. For each enabled soft rule whose `rule_type` is
`SAME_TABLE` or `DIFFERENT_TABLE`, it resolves the targets with the same
rule as the hard path (unknown group or guest raises `ValueError`, mirroring
the hard path — a soft rule naming nobody is not seating advice, it is broken
input) and creates one indicator `sat`. The indicator is constrained so it can
be `true` only while the rule is satisfied, by adding, for every target pair
and every table, the rule's satisfaction condition with `sat` subtracted out.
For a soft `same_table` rule, both guests at table `t` is
`at[a][t] - at[b][t] <= 1` and `at[b][t] - at[a][t] <= 1` (equivalent to
equality on booleans), so the conditioned forms are:

```python
# src/seating_planner/solver/hard.py (soft indicator, per pair, per table)
    for rule in _soft_rules(event):
        sat = model.NewBoolVar(f"sat_{rule.id}")
        for first, second in combinations(targets, 2):
            for table_id, var_a in at[first].items():
                var_b = at[second][table_id]
                if rule.rule_type is RuleType.SAME_TABLE:
                    model.Add(sat + var_a - var_b <= 1)
                    model.Add(sat + var_b - var_a <= 1)
                else:  # DIFFERENT_TABLE
                    model.Add(var_a + var_b - sat <= 1)
        # Rule.weight is int | None; a soft rule always carries an int,
        # but mypy --strict wants the narrowing before the multiplication.
        if rule.weight is None:
            continue
        terms.append(rule.weight * sat)
    if terms:
        model.Maximize(sum(terms))
```

Algebra: with
`sat` true the inequalities reduce to the rule's constraint, so `sat` may only
be true when the rule holds; with `sat` false they impose nothing. Since the
solver maximizes, each `sat` will be true exactly when the rule is satisfied
in the final chart. The objective is then `model.Maximize` of the sum of
`rule.weight * sat` over the rules — hard rules contribute nothing, they are
constraints, and no reweighting or scaling is applied: the bean's background
prescribes "the sum of weight times indicator", and it is the constraint/
objective split, not any magnitude, that guarantees a weight-100 soft rule can
never buy its way past a hard rule.

Skipped, by design: disabled soft rules (same check the hard path makes),
soft rules that are not `SAME_TABLE`/`DIFFERENT_TABLE` (no table-level
interpretation; they count for nothing rather than crashing a soft-configured
event — the asymmetry with the hard path is deliberate and documented in the
docstring), and soft rules with fewer than two resolved target guests (the
indicator would be a constant and a constant cannot change which chart wins,
so omitting it is mathematically free). `_build_model` gains the one call;
`solve_event` gains nothing — its signature, the `SolveResult` shape, and the
status handling are unchanged (a maximization read back as `OPTIMAL` or
`FEASIBLE` fits the existing branch; an undecided-in-time solve still raises
`SolverTimeout`). The two docstrings claiming soft scoring does not exist yet
(`solver/__init__.py`, `hard.py`) are updated to say the solver now returns
the highest-scoring valid chart.

### task-2 — `tests/solver/test_objective.py`

A new file in the existing test style (private builders, asserting only on
`solve_event` result fields), with exactly the three tests the bean names.
Illustrative scenarios — the worker writes the code:

```python
# tests/solver/test_objective.py (three acceptance scenarios)
# ac1: weight-90 same_table(g-0, g-1) + weight-10 different_table(g-0, g-2),
#      both satisfiable  ->  assert the chart satisfies both rules.
# ac2: hard different_table(g-0, g-1) vs soft same_table(g-0, g-1, weight=100)
#      ->  assert status "feasible" and g-0, g-1 apart. (Soft-as-constraint
#      would make this infeasible; soft-beats-hard would break the assert.)
# ac3: same_table(g-0, g-1, w=80) vs same_table(g-0, g-2, w=40), and g-0 can
#      sit with only one of them  ->  assert the w=80 rule holds.
```

The tests assert what the bean promises — which rule is satisfied — and never
which guest is where beyond that: several charts can tie for the top score,
the search decides between equals, and that is not a contract.

## Risk

The one behaviour change is visible: for any event that carries an expressible
soft rule, the returned chart can differ from what bean-006 produced, because
the solver now chases the score instead of stopping at the first valid chart.
The risks and how each is caught. **A soft rule leaks into the constraint
set** (indicator wired up as a hard condition): the event ac2 constructs
turns infeasible, and `test_soft_never_overrides_hard` fails on the status.
**A hard rule gets re-expressed as a weight**: `test_soft_never_overrides_hard`
and the whole bean-006 suite fail, because an arbitrarily heavy weight can be
outbought in a larger chart while constraints cannot. **Objective arithmetic
is wrong** (weight read from the wrong field, `None` handling, a sign flip):
ac1 and ac3 fail, since both place a heavier and a lighter rule within reach.
**Determinism regresses**: the parameters are untouched (one worker, caller's
seed), the invariant suite runs in task 1's verify, and bean-009's
reproducibility invariant is unaffected because it already binds the
parameters rather than the objective. **Performance**: a soft same_table rule
adds two constraints per target pair per table, the same combinatorics the
hard path already accepts for hard rules; on the corpus-scale events
(hundreds of guests, tens of tables, thousands of rules) solve time can rise,
but the existing time limit still bounds it and an undecided solve still
fails loudly rather than silently. Notice is by the gates: bean-006's suite,
the invariants suite, ruff and mypy all re-run in both tasks. Backout is one
commit — the entire change is a new call inside `_build_model`, a new
private function, updated docstrings and one test file; reverting task 1's
hunk returns the model to "any valid chart" exactly.

## Blast radius

Touched, three files: `src/seating_planner/solver/hard.py` (new
`_soft_rules` / `_add_soft_objective` and one call in `_build_model`, plus
docstrings), `src/seating_planner/solver/__init__.py` (docstring only),
`tests/solver/test_objective.py` (new). Callers: `solve_from_spec` in
`src/seating_planner/invariant_api.py` calls `solve_event` with an unchanged
signature and needs no edit; there are no other callers in the repository.
Data: none — the solver is in-memory, the store and persistence are other
beans' territory. Deployments: none; this is a library built by the line,
merged by a human. **Not touched**, explicitly: the domain, rules, feasibility,
store and `invariant_api` modules; `factory/invariants/**`, which no bean may
write and which this bean is bound by (`seating.yaml` names bean-007 in
`applies_to`); every existing test, run unchanged as a regression; bean-008's
reporting (the bean declares "no reporting of which rules were violated" a
non-goal — `SolveResult` gains no score field, no violation list); and the
solver's parameters, which the reproducibility invariant depends on.

## Verification

The bean's acceptance criteria, each with its exact `verify` from
`bean.yaml`:

| AC | Criterion | Verify |
|---|---|---|
| ac1 | Given two valid arrangements, the one with the higher weighted soft score is returned. | `kind: test` — `tests/solver/test_objective.py::test_higher_score_preferred` |
| ac2 | A weight-100 soft rule never causes a hard rule to be violated. | `kind: test` — `tests/solver/test_objective.py::test_soft_never_overrides_hard` |
| ac3 | Soft rules are honoured in weight order when they conflict with each other. | `kind: test` — `tests/solver/test_objective.py::test_conflicting_soft_rules_follow_weight` |
| ac4 | Every hard-constraint test from bean-006 still passes unchanged. | `kind: command` — `pytest -q tests/solver/test_hard_constraints.py` |

The invariants named by the bean's `invariants_ref`
(`factory/invariants/seating.yaml`, id `seating-core`), which apply to
bean-007 and run through the unchanged seam: `inv-capacity`, `inv-one-table`,
`inv-eligibility`, `inv-hard-rules`, `inv-infeasible-is-total`, and
`inv-reproducible`, verified by `pytest -q --no-header
factory/invariants/test_seating_invariants.py`. Task-level verification:
task 1 re-runs ruff check/format, `mypy src`, the bean-006 suite and the
invariants suite on the modified model; task 2 runs the three new tests plus
the bean-006 suite as regression. This planning container can run ruff and
mypy but not pytest or the verify commands — those run in the gate image;
nothing here is a substitute for a green verify.

## Open questions

Assumptions declared, none hidden. **Reading of ac3 under aggregate
conflicts:** a plain weighted sum — the objective the bean's background
prescribes — honours weight order for *pairwise* conflicts: a weight-80 rule
cannot be sacrificed for a weight-40 one. It does not imply *lexicographic*
order across totals: with a weight-60 rule conflicting against two jointly
satisfiable weight-40 rules, the sum prefers 80 over 60 even though 60 is the
heavier single rule. The declared test (ac3) uses a pairwise conflict, and the
objective is the weighted sum the bean names; if the owner wants lexicographic
order by weight rank, that is a different objective and a different bean, and
this plan will say so rather than paper over it. **Soft rules without a
table-level reading:** soft `min_distance` / `adjacent_seat` rules are skipped
(no indicator, no error), extending bean-006's silent treatment — the
alternative (raising) would make any soft-configured event un-solvable and
would change the seam's behaviour, so this is declared rather than assumed
away. **One-member soft rules** contribute nothing (a constant objective term
cannot change the winner). **Ties among optimal charts** are not contracted:
the tests pin *which rules are satisfied*, not which tied chart the search
returns, and determinism per seed — not choice among equals — is what the
reproducible invariant guarantees.
