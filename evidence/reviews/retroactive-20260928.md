# Retroactive reviews of merged beans, 2026-09-28

Three fresh Claude reviewers checked seven merged beans (002, 003, 006, 008, 010, 011, 012)
under the pre-merge-review rules. Every defect below was demonstrated in the pinned gate
image against seating-planner origin/main `d9ab289`. The demo scripts are in the session
scratchpad (`rev-006-008/`, `rev-010-011/`, `rev-012-002-003/`), which is not kept.
Together with the earlier reviews (005, 007, 009, 013, 014), all 12 merged beans that were
reviewed closely had at least one real defect.

## Proposed repairs (awaiting the owner's approval)

| proposed bean | defect | from | where on main |
| --- | --- | --- | --- |
| bean-026 | The default wedding template's accessible-seating rule is a HARD `min_distance` rule, which the solver refuses, so any event that uses the template cannot be solved, and preflight is silent about it. Proposed fix: create the rule disabled until seat positions are configured. Soft, or a preflight warning, are the alternatives, and the choice is the owner's. | bean-003 | `rules/template.py:199-207`, `solver/hard.py:568-571` |
| bean-027 | A hard rule with fewer than two eligible targets is never evaluated and is reported `satisfied`, while its soft twin is `unevaluable` (breaks bean-008 ac3). Duplicate rule ids are refused nowhere, so rule states collapse into one and the score contradicts them. | bean-008 | `solver/hard.py:500-512`, `domain/__init__.py:103-105` |
| bean-028 | The one-removal diagnosis has blind spots. With two independent conflicts, no rule is named. A seat shortage plus a rule conflict gives only capacity advice. When locks are the cause, the report blames "hard rules". When no single unlock fixes it, no lock is named. Proposed fix: fall back to CP-SAT's infeasible core and name every cause, with locks named as locks. | bean-010, bean-011 | `solver/hard.py:640-666`, `solver/report.py:134` |
| bean-029 | Validation only runs at construction. `Guest.eligible` returns `'no'` for `reserved_seat="no"`, so a pending guest is seated. For a rule, one valid distance measure lets an invalid other through (`distance_m="far apart"` is stored). Objects can be mutated after construction: a weight of 10^6 is scored, a hard rule can carry a weight, a group can name unknown guests, and guests can be appended past the 500 limit or with duplicate ids. A lock to a removed table raises a raw `KeyError` in the solve, and the event saves but will not load again. Hard-rule validation is skipped when an event has no eligible guests or no tables. Proposed fix: `solve_event` and `save_event` validate the whole event on use. | bean-002, bean-003, bean-006, bean-011 | `domain/__init__.py:69`, `rules/__init__.py:96-98`, `solver/hard.py:153-179, 459`, `store/__init__.py:157-162` |
| (owner decision) | `invariant_api.solve_from_spec` silently ignores a `mode` in the spec and always plans. Belongs with the open decision on adding `mode` to `factory/invariants/seating.yaml`. | bean-012 | `invariant_api.py:69-71` |

## Minor points (not proposed as beans)

- bean-006: any solver status other than feasible or infeasible is raised as `SolverTimeout`. Unknown keys in the seam's spec are silently ignored.
- bean-008: `unassigned_count` counts eligible guests only, and `Violation.guest_ids` leaves out ineligible guests.
- bean-010: the ac1 and ac2 tests would pass on the base commit. Each diagnosis probe gets the full time limit.
- bean-011: the unlock recommendation carries no structured guest or table id, and `report.py`'s docstring still says unlock is never emitted.
- bean-003: round-trip equality fails for list-typed `guest_ids`; `guest_ids="alice"` is split into characters; `enabled="false"` is truthy.
- bean-002: `Table.capacity` accepts 2.5 and True; positions accept NaN.
- bean-012: `SolverConfig` does not record the mode.
