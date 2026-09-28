"""Hidden tests for bean-019 — split the solver module, change nothing observable.

bean-019 is a refactor: model construction, solving and result interpretation
move into separate modules "with no change in behaviour whatsoever", and the
public entry point keeps its name and signature. So the strongest thing a
hidden suite can ask is the thing the bean says defines it: the same inputs
give the same answers as before.

Hidden tests cannot import the pre-refactor code, so the answers are frozen
here as data. They were produced on 2026-09-28 by running seating-planner's
main (87450c2) in the gate image, twice per case (identical both times), and
EVERY ONE WAS ALSO CONFIRMED BY BRUTE FORCE: each case was kept only if
enumerating every chart gives a unique best answer (planning and event_day: the
one highest-scoring valid chart; low_disruption: fewest moves within the
limit, then highest score) and that answer is what main returned. Infeasible
cases were kept only when enumeration agrees no valid chart exists and agrees
with main's conflict list under its one-removal definition. (Drawn from
random.Random(19019): 2-3 tables of capacity 1-3, 3-6 guests of mixed status,
1-5 two- or three-guest rules, at most one lock; 41 kept of 247 drawn.) So no frozen
answer depends on how the solver breaks a tie — a refactor that reorders
variables, or an earlier bean that does, cannot fail a case for a reason that
is not a behaviour change.

WHICH FIELDS ARE COMPARED, AND WHY ONLY THESE. Beans 015–018 land before this
one and may legitimately add to the result (ranked alternatives, proposal
state), so the whole to_dict() is not compared. Compared are the fields that
exist now and whose meaning no earlier bean changes:

  * status
  * assignments                     (feasible cases)
  * score                           (feasible cases)
  * the set of violated rule ids    (feasible cases)
  * sorted conflict_rule_ids        (infeasible cases)

Each is read as an attribute, falling back to the to_dict() key of the same
name.

WHICH INPUTS ARE AVOIDED, AND WHY. Beans 021–025 repair solver behaviour and
also land before this one, so no frozen case touches what they change:

  * no soft different_table rule (bean-021 repairs how those score — measured:
    main returns a sub-optimal chart when one is present);
  * no groups (bean-022 is about group size);
  * mode is always a literal string (bean-023 is about equal-but-not-identical
    mode strings);
  * num_search_workers is never passed (bean-024);
  * no event_day case combines an explicit lock with an unlock, and no
    event_day case is infeasible (bean-025's unlock and diagnosis repairs, and
    bean-015's ranked alternatives for a guest with no seat).

Also left out: min_distance and adjacent_seat rules, whose reporting bean-020
changes after this bean. Guest statuses are a letter each: c confirmed, r
pending with a reserved seat (eligible), p pending, d declined, x cancelled.

The structural checks ask only what ac2 says — three jobs, separate modules —
and never a module or function name, because the bean fixes none. The pinned
test ids are the gate's to run and are not restated here.
"""

from __future__ import annotations

import ast
import inspect
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

SOLVER = WORK / "src" / "seating_planner" / "solver"

_STATUS = {
    "c": ("confirmed", False),
    "r": ("pending", True),
    "p": ("pending", False),
    "d": ("declined", False),
    "x": ("cancelled", False),
}

# fmt: off
CASES: list[dict[str, Any]] = [
    {'mode': 'planning', 'tables': (('t0', 2), ('t1', 3), ('t2', 1)), 'guests': (('g0', 'd'), ('g1', 'd'), ('g2', 'd'), ('g3', 'x')), 'rules': [('r0', 'diff', 'hard', None, ('g2', 'g3')), ('r1', 'same', 'hard', None, ('g3', 'g1')), ('r2', 'same', 'soft', 45, ('g0', 'g3', 'g1')), ('r3', 'same', 'hard', None, ('g2', 'g1'))], 'locks': (), 'seed': 32, 'expected': {'status': 'feasible', 'assignments': {}, 'score': 0, 'violated_rule_ids': []}},
    {'mode': 'planning', 'tables': (('t0', 3), ('t1', 1)), 'guests': (('g0', 'c'), ('g1', 'c'), ('g2', 'd'), ('g3', 'd'), ('g4', 'c'), ('g5', 'c')), 'rules': [('r0', 'same', 'soft', 3, ('g2', 'g4')), ('r1', 'same', 'soft', 76, ('g4', 'g5')), ('r2', 'same', 'soft', 40, ('g4', 'g0')), ('r3', 'same', 'soft', 55, ('g1', 'g2')), ('r4', 'same', 'hard', None, ('g2', 'g4'))], 'locks': (('g4', 't1'),), 'expected': {'status': 'feasible', 'assignments': {'g0': 't0', 'g1': 't0', 'g4': 't1', 'g5': 't0'}, 'score': 0, 'violated_rule_ids': ['r1', 'r2']}},
    {'mode': 'planning', 'tables': (('t0', 1), ('t1', 3)), 'guests': (('g0', 'c'), ('g1', 'c'), ('g2', 'd'), ('g3', 'x'), ('g4', 'c'), ('g5', 'd')), 'rules': [('r0', 'same', 'soft', 58, ('g0', 'g1')), ('r1', 'same', 'soft', 67, ('g4', 'g1')), ('r2', 'same', 'soft', 88, ('g0', 'g3')), ('r3', 'same', 'soft', 80, ('g5', 'g3', 'g0')), ('r4', 'same', 'soft', 34, ('g5', 'g1', 'g2'))], 'locks': (), 'expected': {'status': 'feasible', 'assignments': {'g0': 't1', 'g1': 't1', 'g4': 't1'}, 'score': 125, 'violated_rule_ids': []}},
    {'mode': 'planning', 'tables': (('t0', 1), ('t1', 2), ('t2', 1)), 'guests': (('g0', 'd'), ('g1', 'c'), ('g2', 'c'), ('g3', 'c')), 'rules': [('r0', 'same', 'hard', None, ('g3', 'g0')), ('r1', 'same', 'soft', 69, ('g3', 'g2')), ('r2', 'same', 'soft', 48, ('g1', 'g2'))], 'locks': (('g1', 't0'),), 'expected': {'status': 'feasible', 'assignments': {'g1': 't0', 'g2': 't1', 'g3': 't1'}, 'score': 69, 'violated_rule_ids': ['r2']}},
    {'mode': 'planning', 'tables': (('t0', 2), ('t1', 1), ('t2', 2)), 'guests': (('g0', 'c'), ('g1', 'd'), ('g2', 'c')), 'rules': [('r0', 'same', 'soft', 82, ('g1', 'g2', 'g0')), ('r1', 'same', 'soft', 37, ('g0', 'g2', 'g1'))], 'locks': (('g0', 't2'),), 'seed': 34, 'expected': {'status': 'feasible', 'assignments': {'g0': 't2', 'g2': 't2'}, 'score': 119, 'violated_rule_ids': []}},
    {'mode': 'planning', 'tables': (('t0', 2), ('t1', 3)), 'guests': (('g0', 'c'), ('g1', 'c'), ('g2', 'd'), ('g3', 'x'), ('g4', 'c'), ('g5', 'c')), 'rules': [('r0', 'same', 'hard', None, ('g3', 'g5', 'g4')), ('r1', 'same', 'soft', 49, ('g1', 'g2')), ('r2', 'same', 'soft', 41, ('g4', 'g5', 'g1')), ('r3', 'same', 'soft', 3, ('g4', 'g0'))], 'locks': (('g0', 't1'),), 'expected': {'status': 'feasible', 'assignments': {'g0': 't1', 'g1': 't0', 'g4': 't1', 'g5': 't1'}, 'score': 3, 'violated_rule_ids': ['r2']}},
    {'mode': 'planning', 'tables': (('t0', 3), ('t1', 1)), 'guests': (('g0', 'c'), ('g1', 'x'), ('g2', 'c'), ('g3', 'c')), 'rules': [('r0', 'same', 'hard', None, ('g1', 'g2')), ('r1', 'same', 'soft', 5, ('g0', 'g3')), ('r2', 'diff', 'hard', None, ('g2', 'g1'))], 'locks': (('g2', 't0'),), 'expected': {'status': 'feasible', 'assignments': {'g0': 't0', 'g2': 't0', 'g3': 't0'}, 'score': 5, 'violated_rule_ids': []}},
    {'mode': 'planning', 'tables': (('t0', 3), ('t1', 1)), 'guests': (('g0', 'c'), ('g1', 'r'), ('g2', 'd'), ('g3', 'c'), ('g4', 'x')), 'rules': [('r0', 'diff', 'hard', None, ('g0', 'g4', 'g1')), ('r1', 'same', 'soft', 33, ('g3', 'g1')), ('r2', 'diff', 'hard', None, ('g2', 'g1', 'g4'))], 'locks': (('g1', 't1'),), 'expected': {'status': 'feasible', 'assignments': {'g0': 't0', 'g1': 't1', 'g3': 't0'}, 'score': 0, 'violated_rule_ids': ['r1']}},
    {'mode': 'planning', 'tables': (('t0', 2), ('t1', 2)), 'guests': (('g0', 'r'), ('g1', 'p'), ('g2', 'c'), ('g3', 'c'), ('g4', 'c')), 'rules': [('r0', 'same', 'soft', 39, ('g3', 'g4'))], 'locks': (('g2', 't0'),), 'seed': 66, 'expected': {'status': 'feasible', 'assignments': {'g0': 't0', 'g2': 't0', 'g3': 't1', 'g4': 't1'}, 'score': 39, 'violated_rule_ids': []}},
    {'mode': 'planning', 'tables': (('t0', 2), ('t1', 3)), 'guests': (('g0', 'x'), ('g1', 'c'), ('g2', 'r'), ('g3', 'p'), ('g4', 'c'), ('g5', 'r')), 'rules': [('r0', 'same', 'soft', 82, ('g1', 'g4', 'g5')), ('r1', 'same', 'soft', 78, ('g4', 'g2')), ('r2', 'same', 'soft', 7, ('g1', 'g3', 'g4')), ('r3', 'same', 'soft', 78, ('g4', 'g1', 'g0'))], 'locks': (), 'seed': 22, 'expected': {'status': 'feasible', 'assignments': {'g1': 't1', 'g2': 't0', 'g4': 't1', 'g5': 't1'}, 'score': 167, 'violated_rule_ids': ['r1']}},
    {'mode': 'planning', 'tables': (('t0', 1), ('t1', 2)), 'guests': (('g0', 'c'), ('g1', 'c'), ('g2', 'd'), ('g3', 'c'), ('g4', 'p')), 'rules': [('r0', 'same', 'soft', 65, ('g2', 'g4')), ('r1', 'same', 'hard', None, ('g1', 'g2')), ('r2', 'same', 'soft', 59, ('g4', 'g3', 'g0')), ('r3', 'same', 'soft', 21, ('g0', 'g4')), ('r4', 'same', 'soft', 34, ('g0', 'g3'))], 'locks': (('g0', 't0'),), 'expected': {'status': 'feasible', 'assignments': {'g0': 't0', 'g1': 't1', 'g3': 't1'}, 'score': 0, 'violated_rule_ids': ['r2', 'r4']}},
    {'mode': 'planning', 'tables': (('t0', 3), ('t1', 3)), 'guests': (('g0', 'c'), ('g1', 'p'), ('g2', 'c')), 'rules': [('r0', 'same', 'soft', 25, ('g1', 'g0', 'g2')), ('r1', 'same', 'soft', 11, ('g1', 'g0'))], 'locks': (('g0', 't0'),), 'expected': {'status': 'feasible', 'assignments': {'g0': 't0', 'g2': 't0'}, 'score': 25, 'violated_rule_ids': []}},
    {'mode': 'low_disruption', 'tables': (('t0', 1), ('t1', 2)), 'guests': (('g0', 'd'), ('g1', 'c'), ('g2', 'c')), 'rules': [('r0', 'same', 'soft', 28, ('g0', 'g1')), ('r1', 'same', 'soft', 77, ('g0', 'g2')), ('r2', 'same', 'hard', None, ('g1', 'g2', 'g0')), ('r3', 'same', 'soft', 52, ('g0', 'g2')), ('r4', 'same', 'soft', 76, ('g1', 'g0', 'g2'))], 'locks': (), 'current': {'g1': 't1'}, 'movement_limit': 0, 'seed': 36, 'expected': {'status': 'feasible', 'assignments': {'g1': 't1', 'g2': 't1'}, 'score': 76, 'violated_rule_ids': []}},
    {'mode': 'low_disruption', 'tables': (('t0', 1), ('t1', 3)), 'guests': (('g0', 'c'), ('g1', 'c'), ('g2', 'c')), 'rules': [('r0', 'diff', 'hard', None, ('g2', 'g1')), ('r1', 'same', 'soft', 88, ('g1', 'g0', 'g2')), ('r2', 'same', 'soft', 85, ('g1', 'g2')), ('r3', 'same', 'soft', 86, ('g0', 'g1'))], 'locks': (), 'current': {'g0': 't1', 'g1': 't0', 'g2': 't1'}, 'movement_limit': 2, 'expected': {'status': 'feasible', 'assignments': {'g0': 't1', 'g1': 't0', 'g2': 't1'}, 'score': 0, 'violated_rule_ids': ['r1', 'r2', 'r3']}},
    {'mode': 'low_disruption', 'tables': (('t0', 3), ('t1', 1)), 'guests': (('g0', 'c'), ('g1', 'd'), ('g2', 'c'), ('g3', 'c'), ('g4', 'c')), 'rules': [('r0', 'same', 'soft', 79, ('g0', 'g3')), ('r1', 'same', 'hard', None, ('g0', 'g2')), ('r2', 'same', 'soft', 27, ('g2', 'g1'))], 'locks': (), 'current': {'g0': 't1', 'g2': 't1', 'g4': 't0'}, 'movement_limit': 2, 'seed': 22, 'expected': {'status': 'feasible', 'assignments': {'g0': 't0', 'g2': 't0', 'g3': 't1', 'g4': 't0'}, 'score': 0, 'violated_rule_ids': ['r0']}},
    {'mode': 'low_disruption', 'tables': (('t0', 2), ('t1', 3)), 'guests': (('g0', 'c'), ('g1', 'x'), ('g2', 'c')), 'rules': [('r0', 'same', 'soft', 10, ('g0', 'g2')), ('r1', 'same', 'soft', 27, ('g0', 'g2'))], 'locks': (('g0', 't0'),), 'current': {'g0': 't0'}, 'movement_limit': 2, 'expected': {'status': 'feasible', 'assignments': {'g0': 't0', 'g2': 't0'}, 'score': 37, 'violated_rule_ids': []}},
    {'mode': 'low_disruption', 'tables': (('t0', 2), ('t1', 1)), 'guests': (('g0', 'p'), ('g1', 'p'), ('g2', 'r'), ('g3', 'c'), ('g4', 'r'), ('g5', 'p')), 'rules': [('r0', 'same', 'hard', None, ('g1', 'g4')), ('r1', 'diff', 'hard', None, ('g4', 'g2')), ('r2', 'same', 'hard', None, ('g1', 'g3', 'g0')), ('r3', 'diff', 'hard', None, ('g5', 'g1')), ('r4', 'same', 'soft', 12, ('g3', 'g4'))], 'locks': (('g3', 't0'),), 'current': {'g2': 't0'}, 'movement_limit': 0, 'expected': {'status': 'feasible', 'assignments': {'g2': 't0', 'g3': 't0', 'g4': 't1'}, 'score': 0, 'violated_rule_ids': ['r4']}},
    {'mode': 'low_disruption', 'tables': (('t0', 1), ('t1', 3)), 'guests': (('g0', 'c'), ('g1', 'c'), ('g2', 'c'), ('g3', 'c')), 'rules': [('r0', 'same', 'soft', 14, ('g1', 'g0')), ('r1', 'same', 'soft', 24, ('g0', 'g3', 'g2'))], 'locks': (('g2', 't1'),), 'current': {'g3': 't1'}, 'movement_limit': 0, 'seed': 87, 'expected': {'status': 'feasible', 'assignments': {'g0': 't1', 'g1': 't0', 'g2': 't1', 'g3': 't1'}, 'score': 24, 'violated_rule_ids': ['r0']}},
    {'mode': 'low_disruption', 'tables': (('t0', 3), ('t1', 3), ('t2', 3)), 'guests': (('g0', 'x'), ('g1', 'r'), ('g2', 'c'), ('g3', 'd')), 'rules': [('r0', 'same', 'soft', 73, ('g3', 'g2')), ('r1', 'same', 'soft', 36, ('g1', 'g0', 'g2'))], 'locks': (('g1', 't2'),), 'current': {'g1': 't2'}, 'movement_limit': 2, 'expected': {'status': 'feasible', 'assignments': {'g1': 't2', 'g2': 't2'}, 'score': 36, 'violated_rule_ids': []}},
    {'mode': 'low_disruption', 'tables': (('t0', 2), ('t1', 2)), 'guests': (('g0', 'c'), ('g1', 'c'), ('g2', 'c'), ('g3', 'c'), ('g4', 'd')), 'rules': [('r0', 'same', 'soft', 40, ('g4', 'g1', 'g2')), ('r1', 'same', 'soft', 99, ('g2', 'g1', 'g3')), ('r2', 'same', 'soft', 39, ('g2', 'g0')), ('r3', 'same', 'soft', 86, ('g4', 'g0')), ('r4', 'same', 'hard', None, ('g3', 'g1', 'g4'))], 'locks': (), 'current': {'g0': 't0', 'g1': 't0', 'g3': 't1'}, 'movement_limit': 1, 'seed': 17, 'expected': {'status': 'feasible', 'assignments': {'g0': 't0', 'g1': 't1', 'g2': 't0', 'g3': 't1'}, 'score': 39, 'violated_rule_ids': ['r0', 'r1']}},
    {'mode': 'low_disruption', 'tables': (('t0', 2), ('t1', 3)), 'guests': (('g0', 'c'), ('g1', 'c'), ('g2', 'd'), ('g3', 'c')), 'rules': [('r0', 'same', 'soft', 86, ('g0', 'g3')), ('r1', 'diff', 'hard', None, ('g3', 'g0')), ('r2', 'same', 'soft', 85, ('g0', 'g1')), ('r3', 'same', 'soft', 49, ('g1', 'g3', 'g0')), ('r4', 'diff', 'hard', None, ('g1', 'g0'))], 'locks': (), 'current': {'g0': 't0'}, 'movement_limit': 1, 'expected': {'status': 'feasible', 'assignments': {'g0': 't0', 'g1': 't1', 'g3': 't1'}, 'score': 0, 'violated_rule_ids': ['r0', 'r2', 'r3']}},
    {'mode': 'low_disruption', 'tables': (('t0', 1), ('t1', 3)), 'guests': (('g0', 'c'), ('g1', 'c'), ('g2', 'x'), ('g3', 'c'), ('g4', 'x'), ('g5', 'c')), 'rules': [('r0', 'same', 'soft', 44, ('g3', 'g1')), ('r1', 'same', 'hard', None, ('g2', 'g4', 'g5'))], 'locks': (), 'current': {'g1': 't0'}, 'movement_limit': 1, 'expected': {'status': 'feasible', 'assignments': {'g0': 't1', 'g1': 't0', 'g3': 't1', 'g5': 't1'}, 'score': 0, 'violated_rule_ids': ['r0']}},
    {'mode': 'event_day', 'tables': (('t0', 3), ('t1', 3), ('t2', 3)), 'guests': (('g0', 'r'), ('g1', 'x'), ('g2', 'c')), 'rules': [('r0', 'same', 'hard', None, ('g1', 'g0', 'g2')), ('r1', 'same', 'hard', None, ('g0', 'g1', 'g2')), ('r2', 'same', 'soft', 62, ('g0', 'g1', 'g2')), ('r3', 'same', 'soft', 53, ('g0', 'g1', 'g2'))], 'locks': (), 'current': {'g2': 't0'}, 'seed': 74, 'expected': {'status': 'feasible', 'assignments': {'g0': 't0', 'g2': 't0'}, 'score': 115, 'violated_rule_ids': []}},
    {'mode': 'event_day', 'tables': (('t0', 1), ('t1', 2), ('t2', 1)), 'guests': (('g0', 'c'), ('g1', 'r'), ('g2', 'c'), ('g3', 'd'), ('g4', 'x')), 'rules': [('r0', 'same', 'soft', 87, ('g2', 'g3', 'g0'))], 'locks': (), 'current': {'g1': 't0', 'g2': 't2'}, 'expected': {'status': 'feasible', 'assignments': {'g0': 't1', 'g1': 't0', 'g2': 't2'}, 'score': 0, 'violated_rule_ids': ['r0']}},
    {'mode': 'event_day', 'tables': (('t0', 3), ('t1', 1), ('t2', 1)), 'guests': (('g0', 'r'), ('g1', 'c'), ('g2', 'd')), 'rules': [('r0', 'same', 'soft', 82, ('g1', 'g0', 'g2')), ('r1', 'same', 'hard', None, ('g1', 'g0', 'g2'))], 'locks': (), 'current': {'g1': 't1'}, 'unlocked': ('g1',), 'seed': 81, 'expected': {'status': 'feasible', 'assignments': {'g0': 't0', 'g1': 't0'}, 'score': 82, 'violated_rule_ids': []}},
    {'mode': 'event_day', 'tables': (('t0', 1), ('t1', 3)), 'guests': (('g0', 'r'), ('g1', 'c'), ('g2', 'c'), ('g3', 'c')), 'rules': [('r0', 'same', 'soft', 31, ('g2', 'g3')), ('r1', 'same', 'soft', 74, ('g0', 'g1')), ('r2', 'same', 'soft', 75, ('g2', 'g1')), ('r3', 'same', 'soft', 94, ('g1', 'g3')), ('r4', 'same', 'soft', 79, ('g2', 'g3', 'g1'))], 'locks': (), 'current': {'g0': 't1', 'g2': 't1', 'g3': 't0'}, 'expected': {'status': 'feasible', 'assignments': {'g0': 't1', 'g1': 't1', 'g2': 't1', 'g3': 't0'}, 'score': 149, 'violated_rule_ids': ['r0', 'r3', 'r4']}},
    {'mode': 'event_day', 'tables': (('t0', 2), ('t1', 3), ('t2', 2)), 'guests': (('g0', 'c'), ('g1', 'c'), ('g2', 'd'), ('g3', 'p'), ('g4', 'p')), 'rules': [('r0', 'same', 'soft', 22, ('g4', 'g1')), ('r1', 'same', 'soft', 29, ('g4', 'g2')), ('r2', 'same', 'soft', 25, ('g1', 'g0')), ('r3', 'same', 'hard', None, ('g4', 'g2'))], 'locks': (), 'current': {'g1': 't1'}, 'seed': 52, 'expected': {'status': 'feasible', 'assignments': {'g0': 't1', 'g1': 't1'}, 'score': 25, 'violated_rule_ids': []}},
    {'mode': 'event_day', 'tables': (('t0', 2), ('t1', 1), ('t2', 1)), 'guests': (('g0', 'x'), ('g1', 'c'), ('g2', 'r'), ('g3', 'x')), 'rules': [('r0', 'diff', 'hard', None, ('g3', 'g2')), ('r1', 'same', 'hard', None, ('g2', 'g3', 'g1'))], 'locks': (), 'current': {'g1': 't0'}, 'expected': {'status': 'feasible', 'assignments': {'g1': 't0', 'g2': 't0'}, 'score': 0, 'violated_rule_ids': []}},
    {'mode': 'event_day', 'tables': (('t0', 3), ('t1', 1)), 'guests': (('g0', 'x'), ('g1', 'p'), ('g2', 'c'), ('g3', 'c')), 'rules': [('r0', 'same', 'soft', 61, ('g2', 'g1', 'g3')), ('r1', 'same', 'soft', 82, ('g1', 'g2')), ('r2', 'diff', 'hard', None, ('g1', 'g2')), ('r3', 'diff', 'hard', None, ('g0', 'g2')), ('r4', 'same', 'hard', None, ('g0', 'g3'))], 'locks': (), 'current': {'g3': 't0'}, 'expected': {'status': 'feasible', 'assignments': {'g2': 't0', 'g3': 't0'}, 'score': 61, 'violated_rule_ids': []}},
    {'mode': 'event_day', 'tables': (('t0', 2), ('t1', 3), ('t2', 3)), 'guests': (('g0', 'c'), ('g1', 'r'), ('g2', 'c'), ('g3', 'x')), 'rules': [('r0', 'same', 'soft', 96, ('g3', 'g0', 'g2')), ('r1', 'same', 'soft', 66, ('g3', 'g0'))], 'locks': (), 'current': {'g0': 't1', 'g1': 't1', 'g2': 't2'}, 'expected': {'status': 'feasible', 'assignments': {'g0': 't1', 'g1': 't1', 'g2': 't2'}, 'score': 0, 'violated_rule_ids': ['r0']}},
    {'mode': 'planning', 'tables': (('t0', 3), ('t1', 2)), 'guests': (('g0', 'c'), ('g1', 'c'), ('g2', 'c'), ('g3', 'd')), 'rules': [('r0', 'same', 'hard', None, ('g3', 'g0', 'g1')), ('r1', 'same', 'hard', None, ('g2', 'g0')), ('r2', 'same', 'soft', 58, ('g1', 'g3')), ('r3', 'diff', 'hard', None, ('g1', 'g0')), ('r4', 'same', 'hard', None, ('g1', 'g3', 'g0'))], 'locks': (), 'seed': 77, 'expected': {'status': 'infeasible', 'conflict_rule_ids': ['r3']}},
    {'mode': 'planning', 'tables': (('t0', 1), ('t1', 2)), 'guests': (('g0', 'd'), ('g1', 'c'), ('g2', 'c'), ('g3', 'c'), ('g4', 'c'), ('g5', 'd')), 'rules': [('r0', 'diff', 'hard', None, ('g1', 'g5', 'g0')), ('r1', 'same', 'soft', 3, ('g2', 'g4')), ('r2', 'diff', 'hard', None, ('g5', 'g4')), ('r3', 'diff', 'hard', None, ('g1', 'g5')), ('r4', 'same', 'hard', None, ('g3', 'g5'))], 'locks': (('g4', 't0'),), 'expected': {'status': 'infeasible', 'conflict_rule_ids': []}},
    {'mode': 'planning', 'tables': (('t0', 1), ('t1', 1)), 'guests': (('g0', 'r'), ('g1', 'c'), ('g2', 'c'), ('g3', 'p'), ('g4', 'c')), 'rules': [('r0', 'same', 'soft', 89, ('g3', 'g2', 'g4')), ('r1', 'same', 'hard', None, ('g2', 'g3')), ('r2', 'diff', 'hard', None, ('g0', 'g4', 'g3'))], 'locks': (('g4', 't0'),), 'expected': {'status': 'infeasible', 'conflict_rule_ids': []}},
    {'mode': 'planning', 'tables': (('t0', 1), ('t1', 2)), 'guests': (('g0', 'c'), ('g1', 'c'), ('g2', 'c')), 'rules': [('r0', 'same', 'soft', 80, ('g2', 'g1', 'g0')), ('r1', 'diff', 'hard', None, ('g2', 'g1', 'g0')), ('r2', 'same', 'soft', 81, ('g2', 'g1', 'g0')), ('r3', 'diff', 'hard', None, ('g2', 'g1'))], 'locks': (('g2', 't0'),), 'expected': {'status': 'infeasible', 'conflict_rule_ids': ['r1']}},
    {'mode': 'planning', 'tables': (('t0', 1), ('t1', 1), ('t2', 1)), 'guests': (('g0', 'x'), ('g1', 'd'), ('g2', 'c'), ('g3', 'd'), ('g4', 'c')), 'rules': [('r0', 'same', 'soft', 66, ('g2', 'g0')), ('r1', 'same', 'hard', None, ('g3', 'g4')), ('r2', 'same', 'soft', 47, ('g4', 'g0')), ('r3', 'same', 'soft', 89, ('g3', 'g1')), ('r4', 'same', 'hard', None, ('g4', 'g2'))], 'locks': (('g2', 't2'),), 'expected': {'status': 'infeasible', 'conflict_rule_ids': ['r4']}},
    {'mode': 'planning', 'tables': (('t0', 1), ('t1', 1)), 'guests': (('g0', 'c'), ('g1', 'c'), ('g2', 'c')), 'rules': [('r0', 'same', 'hard', None, ('g2', 'g1')), ('r1', 'same', 'soft', 9, ('g0', 'g1', 'g2')), ('r2', 'diff', 'hard', None, ('g1', 'g0', 'g2')), ('r3', 'same', 'hard', None, ('g1', 'g0', 'g2')), ('r4', 'diff', 'hard', None, ('g1', 'g2'))], 'locks': (('g2', 't0'),), 'expected': {'status': 'infeasible', 'conflict_rule_ids': []}},
    {'mode': 'low_disruption', 'tables': (('t0', 1), ('t1', 1)), 'guests': (('g0', 'c'), ('g1', 'r'), ('g2', 'c'), ('g3', 'r'), ('g4', 'x'), ('g5', 'c')), 'rules': [('r0', 'same', 'soft', 4, ('g5', 'g3'))], 'locks': (('g3', 't1'),), 'current': {'g0': 't1', 'g1': 't0', 'g3': 't0', 'g5': 't0'}, 'movement_limit': 0, 'seed': 91, 'expected': {'status': 'infeasible', 'conflict_rule_ids': []}},
    {'mode': 'low_disruption', 'tables': (('t0', 1), ('t1', 2)), 'guests': (('g0', 'p'), ('g1', 'c'), ('g2', 'd'), ('g3', 'c'), ('g4', 'c')), 'rules': [('r0', 'diff', 'hard', None, ('g4', 'g0', 'g1')), ('r1', 'same', 'soft', 92, ('g0', 'g3')), ('r2', 'same', 'hard', None, ('g0', 'g3')), ('r3', 'same', 'soft', 11, ('g2', 'g0')), ('r4', 'diff', 'hard', None, ('g3', 'g4'))], 'locks': (('g4', 't1'),), 'current': {'g3': 't1', 'g4': 't0'}, 'movement_limit': 1, 'expected': {'status': 'infeasible', 'conflict_rule_ids': ['r0', 'r4']}},
    {'mode': 'low_disruption', 'tables': (('t0', 1), ('t1', 1), ('t2', 3)), 'guests': (('g0', 'c'), ('g1', 'd'), ('g2', 'c'), ('g3', 'p'), ('g4', 'x'), ('g5', 'c')), 'rules': [('r0', 'same', 'soft', 50, ('g0', 'g4', 'g3')), ('r1', 'same', 'soft', 20, ('g4', 'g5')), ('r2', 'same', 'soft', 94, ('g3', 'g2'))], 'locks': (('g2', 't0'),), 'current': {'g0': 't1', 'g2': 't1', 'g5': 't2'}, 'movement_limit': 0, 'expected': {'status': 'infeasible', 'conflict_rule_ids': []}},
    {'mode': 'low_disruption', 'tables': (('t0', 1), ('t1', 3)), 'guests': (('g0', 'c'), ('g1', 'c'), ('g2', 'x'), ('g3', 'c'), ('g4', 'x'), ('g5', 'r')), 'rules': [('r0', 'same', 'hard', None, ('g1', 'g0', 'g5')), ('r1', 'same', 'hard', None, ('g5', 'g4')), ('r2', 'same', 'hard', None, ('g2', 'g1')), ('r3', 'same', 'hard', None, ('g1', 'g3')), ('r4', 'diff', 'hard', None, ('g5', 'g1', 'g3'))], 'locks': (('g1', 't0'),), 'current': {'g5': 't0'}, 'movement_limit': 0, 'expected': {'status': 'infeasible', 'conflict_rule_ids': []}},
    {'mode': 'low_disruption', 'tables': (('t0', 2), ('t1', 2)), 'guests': (('g0', 'c'), ('g1', 'c'), ('g2', 'c'), ('g3', 'd')), 'rules': [('r0', 'same', 'soft', 46, ('g0', 'g2')), ('r1', 'same', 'hard', None, ('g1', 'g0')), ('r2', 'same', 'soft', 41, ('g0', 'g1')), ('r3', 'same', 'soft', 61, ('g1', 'g3'))], 'locks': (), 'current': {'g1': 't1', 'g2': 't1'}, 'movement_limit': 0, 'expected': {'status': 'infeasible', 'conflict_rule_ids': []}},
]
# fmt: on


def _event(case: dict[str, Any]) -> Any:
    from seating_planner.domain import Event, Guest, Table
    from seating_planner.rules import Hardness, Rule, RuleType

    kinds = {"same": RuleType.SAME_TABLE, "diff": RuleType.DIFFERENT_TABLE}
    hard = {"hard": Hardness.HARD, "soft": Hardness.SOFT}
    return Event(
        id="e",
        name="E",
        tables=[
            Table(id=t, name=t, capacity=c, shape="round", position=(0.0, float(i)))
            for i, (t, c) in enumerate(case["tables"])
        ],
        guests=[
            Guest(id=g, name=g, status=_STATUS[s][0], reserved_seat=_STATUS[s][1])
            for g, s in case["guests"]
        ],
        groups=[],
        rules=[
            Rule(id=rid, rule_type=kinds[k], hardness=hard[h], weight=w, guest_ids=tuple(gs))
            for rid, k, h, w, gs in case["rules"]
        ],
        locks=dict(case["locks"]),
    )


def _solve(case: dict[str, Any]) -> Any:
    from seating_planner.solver import solve_event

    kw: dict[str, Any] = {"mode": case["mode"]}
    for key in ("current", "movement_limit", "seed"):
        if key in case:
            kw[key] = case[key]
    if "unlocked" in case:
        kw["unlocked"] = set(case["unlocked"])
    return solve_event(_event(case), **kw)


def _field(obj: Any, name: str) -> Any:
    if isinstance(obj, dict):
        return obj[name]
    if hasattr(obj, name):
        return getattr(obj, name)
    return obj.to_dict()[name]


def _observed(result: Any) -> dict[str, Any]:
    status = _field(result, "status")
    out: dict[str, Any] = {"status": status}
    if status == "feasible":
        out["assignments"] = dict(_field(result, "assignments"))
        out["score"] = _field(result, "score")
        out["violated_rule_ids"] = sorted(_field(v, "rule_id") for v in _field(result, "violations"))
    else:
        report = _field(result, "infeasibility_report")
        assert report is not None, "an infeasible result carries its diagnosis"
        out["conflict_rule_ids"] = sorted(_field(report, "conflict_rule_ids"))
    return out


def _case_id(i: int, case: dict[str, Any]) -> str:
    return f"{i:02d}-{case['mode']}-{case['expected']['status']}"


@pytest.mark.parametrize("case", CASES, ids=[_case_id(i, c) for i, c in enumerate(CASES)])
def test_behaviour_is_preserved(case: dict[str, Any]) -> None:
    # ac4 and the constraint "no behaviour change of any kind": each fixed
    # scenario gives exactly what it gave before the refactor, and gives it
    # again on a second run.
    first = _observed(_solve(case))
    assert first == case["expected"], (
        f"the refactor changed what this scenario produces: expected "
        f"{case['expected']}, got {first}"
    )
    assert _observed(_solve(case)) == first, "a repeat run of the same scenario differs"


def test_the_frozen_cases_cover_every_mode_and_both_outcomes() -> None:
    # Guards the data above, and fails with the rest on an empty tree because
    # it solves one case of each kind.
    kinds = {(c["mode"], c["expected"]["status"]) for c in CASES}
    assert {("planning", "feasible"), ("planning", "infeasible"), ("low_disruption", "feasible"),
            ("low_disruption", "infeasible"), ("event_day", "feasible")} <= kinds
    for mode, status in sorted(kinds):
        case = next(c for c in CASES if c["mode"] == mode and c["expected"]["status"] == status)
        assert _observed(_solve(case))["status"] == status


# The signature as main has it. bean-019's ac3: the public entry point keeps its
# name and signature. An earlier bean may add a parameter, so an extra one is
# allowed provided it has a default (every existing call still works); none of
# these may go, change kind, change default or change order.
_EMPTY = inspect.Parameter.empty
_KW = inspect.Parameter.KEYWORD_ONLY
_POS = inspect.Parameter.POSITIONAL_OR_KEYWORD
SIGNATURE = [
    ("event", _POS, _EMPTY),
    ("mode", _KW, _EMPTY),
    ("current", _KW, None),
    ("movement_limit", _KW, None),
    ("unlocked", _KW, None),
    ("time_limit_s", _KW, 10.0),
    ("seed", _KW, 0),
    ("num_search_workers", _KW, 1),
]


def test_entry_point_keeps_its_name_and_signature() -> None:
    from seating_planner.solver import solve_event

    params = inspect.signature(solve_event).parameters
    names = list(params)
    for name, kind, default in SIGNATURE:
        assert name in params, f"solve_event lost its {name!r} parameter"
        assert params[name].kind == kind, f"solve_event's {name!r} changed kind"
        assert params[name].default == default, (
            f"solve_event's {name!r} default changed from {default!r} to {params[name].default!r}"
        )
    kept = [n for n in names if n in {s[0] for s in SIGNATURE}]
    assert kept == [s[0] for s in SIGNATURE], f"solve_event's parameters were reordered: {names}"
    extra = [n for n in names if n not in kept]
    assert all(params[n].default is not _EMPTY for n in extra), (
        f"solve_event gained a required parameter, which breaks every existing call: {extra}"
    )


# --- ac2: three jobs, three places ------------------------------------------
#
# The bean fixes no module names, so these look at what each module DOES,
# read from its syntax tree (comments and docstrings cannot count):
#
#   * building the model: creating CP-SAT variables (NewBoolVar / NewIntVar)
#   * solving it: creating a CpSolver
#   * interpreting the result: building the Violation entries or reading the
#     satisfied / violated / unevaluable state names
#
# Before the refactor all three happen in one module. Asked is only that each
# job has a module the other two are absent from — not that no module mixes
# any of them, which would decide the refactor's design for it.

_BUILD = {"NewBoolVar", "NewIntVar", "new_bool_var", "new_int_var"}
_SOLVE = {"CpSolver"}
_INTERPRET_CALLS = {"Violation"}
_INTERPRET_NAMES = {"SATISFIED", "VIOLATED", "UNEVALUABLE"}


def _modules() -> dict[str, dict[str, bool]]:
    assert SOLVER.is_dir(), "the solver package src/seating_planner/solver/ is missing"
    found: dict[str, dict[str, bool]] = {}
    for path in sorted(SOLVER.rglob("*.py")):
        tree = ast.parse(path.read_text(encoding="utf-8"))
        names = set()
        calls = set()
        loads = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Attribute):
                names.add(node.attr)
            elif isinstance(node, ast.Name):
                names.add(node.id)
                if isinstance(node.ctx, ast.Load):
                    loads.add(node.id)
            if isinstance(node, ast.Call):
                fn = node.func
                calls.add(fn.attr if isinstance(fn, ast.Attribute) else getattr(fn, "id", ""))
        found[str(path.relative_to(SOLVER))] = {
            "build": bool(names & _BUILD),
            "solve": bool(names & _SOLVE),
            "interpret": bool(calls & _INTERPRET_CALLS) or bool(loads & _INTERPRET_NAMES),
        }
    assert any(f["build"] for f in found.values()), "no solver module builds a CP-SAT model"
    assert any(f["solve"] for f in found.values()), "no solver module runs a CpSolver"
    return found


def test_model_construction_lives_apart_from_solving() -> None:
    mods = _modules()
    assert any(f["build"] and not f["solve"] for f in mods.values()), (
        f"every module that builds the CP-SAT model also runs the solver: {mods}"
    )
    assert any(f["solve"] and not f["build"] for f in mods.values()), (
        f"every module that runs the solver also builds the model's variables: {mods}"
    )


def test_result_interpretation_lives_apart_from_both() -> None:
    mods = _modules()
    assert any(f["interpret"] and not f["build"] and not f["solve"] for f in mods.values()), (
        f"the rule states and violations are only worked out in a module that also "
        f"builds or solves the model: {mods}"
    )
