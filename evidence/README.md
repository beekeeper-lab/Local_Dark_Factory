# evidence

Artifacts the line itself produced, kept because they are the only record of what
it can actually do. Run directories are gitignored — they are per-run working
state — so anything worth citing later is copied here by hand, named for the bean
and the date.

This is not a sample gallery. Each file is here because a claim somewhere else
rests on it.

| file | what it evidences |
| --- | --- |
| `bean-001-spec-20260915.md` | The first spec the line produced that passed every controller check: doclint, schema, path containment, criteria coverage, the verify precheck and the current-behaviour claims check. Written by `qwen3.8:27b-mtp-q8_0` in a contained worker with no network. It names risks with notice-ness and back-out, and is honest where it is weak — "coverage floor on a two-line package is a near-vacuous pass. That is accepted: the floor is a backstop". |
| `bean-001-tasks-20260915.yaml` | Its task list: three tasks, dependency-ordered, every acceptance criterion claimed, every check machine-runnable. |
| `bean-001-spec-judgement-20260915.json` | The judge's verdict on it — `accept`, 186 seconds. Kept as much for what is wrong with it as what is right: `confidence: 100` against a contract of 0..1 (now refused by audit-check), and two "findings" that are positive observations, one labelled major and one not true in any reading. The verdict was right and the reasoning was noise. |

## The run that reached a pull request

`bean-001-20260915T192025Z`, 2026-09-15 → 16. Eleven steps, about two and a half
hours of step time, ending at
[PR #1](https://github.com/beekeeper-lab/seating-planner-py/pull/1) — +64/−0 across
four files. These are copied out of that run directory, which is gitignored: it is
the run's working state, and the only reason these particular files survive is
that claims elsewhere rest on them.

| file | what it evidences |
| --- | --- |
| `bean-001-impl-detail-20260915.md` | The implementation document, 23KB, written by the developer model on its sixth attempt at the doc step. Worth reading for what it volunteers: two deviations from the spec written up with the comparison method stated, and one inconsistency in the gate's own output it declined to explain away — *"the run directory doesn't record which file set was scanned, so it is flagged as an unresolved inconsistency rather than explained away"*. Nothing asked it to do that. |
| `bean-001-gate-20260915.json` | The gate that authorised the pull request: four pinned gates, four acceptance criteria, whole-diff containment, tier 2 bound by policy, and `test_integrity` showing the tests fail without the change. Taken before `gate_manifest` was added, so it does **not** say which image it ran in — which is the defect that field now fixes, and this file is the evidence that it was missing. |
| `bean-001-package-check-20260915.json` | The pre-PR arithmetic: twenty step attempts each opened and closed once, status agreeing with the log, verdicts named so the driver can read them. |
| `bean-001-telemetry-20260915.json` | Where the time and tokens went, per step attempt. The doc step's six attempts are six rows, which is the point: "doc took ninety minutes" and "doc took six attempts" are different facts and only the second explains anything. |
| `bean-001-run-20260915.json` | The run record — kept **because it does not validate**. No `schema_version`, `bean_id`, `corpus` or `conditions`: it was created hours before new-run.sh was made to conform to its own schema, so the run that produced the first pull request cannot say what corpus it derives from or what models it ran on. Repairing it would be inventing provenance. `bench/phase1-audit.sh` reports it. |
| `judge-fitness-low-20260916.log` | The measurement that moved `roles.json` to `thinking: low` — **and it is a terminal log rather than a results JSON, on purpose.** The harness wrote a zero-byte artifact because I edited `judge-fitness.sh` while it was running, and bash reads a script by byte offset as it executes. The numbers survived only because they had been printed. Kept as what it is, not reconstructed into a file the harness never produced; `bench/snapshot.sh` exists so the next one cannot happen. |
| `bean-002-worker-questions-20260916.md` | **The developer model refusing to work around a controller error, and being right.** `factory go` started bean-002 after bean-001 reached a pull request; the queue had treated an open PR as done. The model opened the tree, found no `src/`, no `pyproject.toml`, no `tests/`, cross-checked that against bean-001's own spec and gate record, quoted both sides, and stopped rather than planning around a missing precondition. It also noticed that `/work/.git` is a read-only empty mount so it could not check the branch state itself, and said so instead of guessing. Kept because this is the behaviour the whole line is built to produce, and because the fault it found was mine. |
| `judge-fitness-low-20260916.log` | The measurement that moved `roles.json` to `thinking: low` — **a terminal log rather than a results JSON, on purpose.** The harness wrote a zero-byte artifact because I edited `judge-fitness.sh` while it was running, and bash reads a script by byte offset as it executes. The numbers survived only because they had been printed. Kept as what it is rather than reconstructed into a file the harness never produced; `bench/snapshot.sh` exists so the next one cannot happen. |
| `bean-001-pr-body-20260915.md` | What a reviewer actually sees. Leads with the fact that no audit verdict authorises it, names what did, and says the documents and the diff are the review rather than a summary of one. |

The spec cost two attempts, and the first failure was the controller's fault:
doclint reported a three-thousand-character section as empty because it treated
any heading as the end of a section. The model said so in its own retry report
and was right. See the commit "doclint called a 3000-character section empty, and
the model was right".
