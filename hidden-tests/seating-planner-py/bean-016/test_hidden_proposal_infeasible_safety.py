"""Hidden test for bean-016's ac6 — accepting a proposal from an infeasible
solve must never silently wipe a saved chart.

Unlike test_hidden_proposals.py (written before bean-016 ever ran, blind to
its API), this is written after round 1 fixed the concrete names the bean's
own acceptance criteria already route through: ``optimize(event, saved=...,
mode=...) -> Proposal`` from ``seating_planner.solver.proposal``, and
``accept(store, proposal, actor=...)`` from the same module operating on a
``seating_planner.store.Repository``. These are the functions ac1-ac5's own
verify test ids already call, so assuming they exist is not a guess beyond
what the bean fixes — only the exact spelling of how a Proposal states its
feasibility (a ``status`` field, a ``feasible`` bool, or anything else) is
left open, and this test never reads that field directly: it only checks
the one thing ac6 actually requires, behaviourally, regardless of how the
implementation represents it internally — accept() must never let an
infeasible solve's empty assignments overwrite a real saved chart.

The fixture is bean-016.yaml's own ac6 example: one table of capacity 1,
two confirmed guests, a real saved chart already seating both of them at
that one table (clearly a pre-existing, valid-looking chart predating this
optimize/accept round). Re-optimizing in planning mode is infeasible (one
seat, two guests). A correct accept() must not touch the saved chart when
given that proposal — whether by raising before writing, or by any other
means — and a second, contrasting case confirms a genuinely feasible
no-change proposal still accepts normally (so the fix cannot simply refuse
every accept to pass this test)."""

from __future__ import annotations

import dataclasses
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


def _first_attr(module: Any, candidates: tuple[str, ...]) -> Any:
    """The first attribute of ``module`` named one of ``candidates``."""
    for candidate in candidates:
        found = getattr(module, candidate, None)
        if found is not None:
            return found
    raise AssertionError(f"none of {candidates} is an attribute of {module.__name__}")


def _first_field(cls: type, candidates: tuple[str, ...]) -> str:
    names = {f.name for f in dataclasses.fields(cls)}
    for candidate in candidates:
        if candidate in names:
            return candidate
    raise AssertionError(f"none of {candidates} is a field of {cls.__name__} (has {sorted(names)})")


def _repo_class() -> Any:
    from seating_planner import store

    return _first_attr(store, ("Repository", "EventRepository"))


def _save_event(repo: Any, event: Any, actor: str) -> None:
    (getattr(repo, "save_event", None) or repo.save)(event, actor=actor)


def _load_event(repo: Any, event_id: str) -> Any:
    return (getattr(repo, "load_event", None) or repo.load)(event_id)


def _locks(event: Any) -> dict[str, str]:
    if hasattr(event, "locks"):
        return dict(event.locks)
    return {g.id: g.locked_to_table for g in event.guests if getattr(g, "locked_to_table", None)}


def _make_event(**kwargs: Any) -> Any:
    """Event(...), without ``locks`` when this build keeps locks on the guest."""
    from seating_planner.domain import Event

    if "locks" not in {f.name for f in dataclasses.fields(Event)}:
        kwargs.pop("locks", None)
    return Event(**kwargs)


def _guest(gid: str) -> Any:
    from seating_planner.domain import Guest, RsvpStatus

    field = _first_field(Guest, ("status", "rsvp_status"))
    return Guest(id=gid, name=gid.upper(), **{field: RsvpStatus.CONFIRMED})


def _accept_and_optimize() -> tuple[Any, Any]:
    """(accept, optimize) as functions of (repo, proposal, actor) and the original call shape."""
    try:
        from seating_planner.solver.proposal import accept, optimize as opt
    except ImportError:
        from seating_planner.solver import proposals as pm

        def accept(repo: Any, proposal: Any, actor: str) -> None:
            repo.accept(proposal, actor)

        opt = pm.optimize

    def optimize(event: Any, saved: Any, mode: str, time_limit_s: float, seed: int) -> Any:
        params = inspect.signature(opt).parameters
        kwargs: dict[str, Any] = {"mode": mode}
        kwargs["saved" if "saved" in params else "saved_chart"] = saved
        if "time_limit_s" in params:
            kwargs.update(time_limit_s=time_limit_s, seed=seed)
        elif "config" in params:
            from seating_planner.solver import SolverConfig

            kwargs["config"] = SolverConfig(time_limit_s=time_limit_s, seed=seed)
        return opt(event, **kwargs)

    return accept, optimize


def _infeasible_event() -> Any:
    from seating_planner.domain import Table

    return _make_event(
        id="e1",
        name="Test Event",
        tables=[Table(id="t1", name="T1", capacity=1, shape="round", position=(0.0, 0.0))],
        guests=[
            _guest("g1"),
            _guest("g2"),
        ],
        groups=[],
        rules=[],
        locks={},
    )


def _feasible_event() -> Any:
    from seating_planner.domain import Table

    return _make_event(
        id="e2",
        name="Test Event 2",
        tables=[Table(id="t1", name="T1", capacity=2, shape="round", position=(0.0, 0.0))],
        guests=[
            _guest("g1"),
            _guest("g2"),
        ],
        groups=[],
        rules=[],
        locks={},
    )


def test_accepting_an_infeasible_proposal_never_wipes_the_saved_chart(tmp_path: Path) -> None:
    accept, optimize = _accept_and_optimize()
    Repository = _repo_class()

    repo = Repository(tmp_path / "db.sqlite3")
    event = _infeasible_event()
    _save_event(repo, event, "setup")

    saved_chart = {"g1": "t1", "g2": "t1"}
    repo.save_chart(event.id, saved_chart, actor="setup")
    assert repo.load_chart(event.id) == saved_chart

    proposal = optimize(event, saved=saved_chart, mode="planning", time_limit_s=2.0, seed=0)

    try:
        accept(repo, proposal, actor="organizer")
    except Exception:  # noqa: BLE001 - any refusal is acceptable; the chart is what matters
        pass

    after = repo.load_chart(event.id)
    assert after == saved_chart, (
        f"accepting a proposal from an infeasible solve must never change the saved "
        f"chart, but it became {after!r} (was {saved_chart!r})"
    )


def test_accepting_a_genuinely_feasible_no_change_proposal_still_works(tmp_path: Path) -> None:
    accept, optimize = _accept_and_optimize()
    Repository = _repo_class()

    repo = Repository(tmp_path / "db.sqlite3")
    event = _feasible_event()
    _save_event(repo, event, "setup")

    saved_chart = {"g1": "t1", "g2": "t1"}
    repo.save_chart(event.id, saved_chart, actor="setup")

    proposal = optimize(event, saved=saved_chart, mode="planning", time_limit_s=2.0, seed=0)

    # Guard: the fix must not become "refuse every accept" to dodge the first
    # test above — a genuinely feasible solve must still accept normally.
    accept(repo, proposal, actor="organizer")
    after = repo.load_chart(event.id)
    assert after is not None and after, (
        "a feasible proposal's accept must still succeed and leave a real chart "
        "in place -- it must not have been refused along with the infeasible case"
    )
