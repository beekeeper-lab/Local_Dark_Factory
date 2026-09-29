# Parking lot

Ideas that are not in the active plan. Each one is reviewed when a phase closes, and at no
other time. Format: the idea, then its value, then my recommendation.

| Idea | Value | Recommendation |
| --- | --- | --- |
| Opus as the intake AI side, checked for byte-identical artifacts (from the Phase 3 ledger) | low: it is a comparison, not a capability | drop |
| Judge accuracy beyond "produces a stamped verdict" | high, but it has cost the most for the least gain so far | Phase 5 only, via the model-change protocol |
| `hidden-tests/verify.sh --image` reports false NOT VERIFIED: its `mktemp -d` tree is 0700 and rootless podman cannot read it; the failed run also overwrites `verified/<repo>/<bean>.json` (found in bean-021 review, 2026-09-29) | medium: it gives a false negative on the tool that proves the hidden tests | **taken into Phase 2 (task 3a), done** |
| `mypy --strict src tests` stops on a duplicate module (`tests/solver/test_locks.py`, missing `__init__.py`) in seating-planner-py | low: the gate's own mypy invocation passes | fold into a Phase 4 bean |
