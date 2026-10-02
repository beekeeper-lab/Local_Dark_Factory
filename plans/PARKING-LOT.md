# Parking lot

Ideas that are not in the active plan. Each one is reviewed when a phase closes, and at no
other time. Format: the idea, then its value, then my recommendation.

| Idea | Value | Recommendation |
| --- | --- | --- |
| Opus as the intake AI side, checked for byte-identical artifacts (from the Phase 3 ledger) | low: it is a comparison, not a capability | **dropped** at the Phase 3 close, 2026-10-02 |
| Judge accuracy beyond "produces a stamped verdict" | high, but it has cost the most for the least gain so far | Phase 5 only, via the model-change protocol |
| `hidden-tests/verify.sh --image` reports false NOT VERIFIED: its `mktemp -d` tree is 0700 and rootless podman cannot read it; the failed run also overwrites `verified/<repo>/<bean>.json` (found in bean-021 review, 2026-09-29) | medium: it gives a false negative on the tool that proves the hidden tests | **taken into Phase 2 (task 3a), done** |
| `mypy --strict src tests` stops on a duplicate module (`tests/solver/test_locks.py`, missing `__init__.py`) in seating-planner-py | low: the gate's own mypy invocation passes | fold into a Phase 4 bean |
| Local transcription skill: run Whisper (e.g. faster-whisper on the Forge GPU) behind the same `transcribe-audio` interface, then A/B it against OpenAI `gpt-4o-mini-transcribe` on the same recordings (word error rate against a hand-checked transcript, plus time). Owner request, 2026-09-30. | medium: it keeps intake fully local; the Phase 3 transcript came from the cloud | owner, 2026-10-02: run it when the GPU is idle; not in Phase 4's scope |
| claims-check flags every tic-tac-toe spec as calling existing files absent ("it also calls these absent, and they are not") when the spec says they exist (Phase 3 reviews 001–004) | medium: a check that always fires trains everyone to ignore it | **taken into Phase 4 (task 10)** by the owner, 2026-10-02 |
| Weak tests the Phase 3 reviews found that survive a mutant: bean-003's lowest-cell tie-breaks for win and side, `ValueError` on a finished game, X as the system's mark; bean-004's strategy asked for X's move instead of O's | medium: each is a real "suite passes on wrong code" case | **taken into Phase 4 (task 11)** by the owner, 2026-10-02 |
| Scaffold default `repo_allowed_paths` lacks `README.md`; every new target will hit the bean-005 containment failure if a bean writes run instructions | low: intake now refuses the path at check time, so it is caught early | **done 2026-10-02** (owner decision): `README.md` is in the scaffold's `repo_allowed_paths` and docs rule |
