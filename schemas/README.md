# schemas

Eight JSON Schemas (Draft 2020-12). They are the contracts between the parts of
the line that do not share a process: a bean written by a human and read by a
model, a verdict written by a model and stamped by the controller, a run record
written by one run and compared against another.

`bench/validate.py` validates against them. `bench/validate.py --corpus <dir>`
validates a whole bean set, which is the one that matters at intake.

| schema | written by | validated |
| --- | --- | --- |
| `bean` | humans, at intake | at intake and in preflight |
| `task` | the spec step | `spec-check.sh`, every run |
| `verdict` | `audit-check.sh` | `bench/phase1-audit.sh` |
| `run-record` | `new-run.sh` | on creation, by new-run itself |
| `gate-manifest` | `factory/gate-image/build.sh` | asserted against the image at startup |
| `risk-policy` | humans | — |
| `repo-config` | `factory/scaffold.sh` | — |
| `event` | **nothing yet** — the Phase-2 bean state machine | — |

## Version strings that are not schemas

Several records the controller writes to a run directory carry a `schema:` field
naming a version that has no file here:

    gate-run/1.0.0        gate.json
    package-check/1.0.0   package-check.json
    test-integrity/1.0.0  test-integrity.json
    verify-precheck/1.0.0 verify-precheck.json
    claims-check/1.0.0    claims-check.json
    judgement/1.0.0       verdicts/<target>.attempt-<n>.judgement.json

These are controller-internal: written and read inside this repository, covered
by its tests, and never crossing a boundary where two parties must agree without
talking. The version string is a format marker so a later reader can tell which
shape it is looking at — it is not a promise that something validated it.

Stated here because the field is called `schema`, and a field called `schema`
with no schema behind it invites exactly the assumption this paragraph exists to
prevent. If one of these starts crossing a real boundary — a dashboard, another
repository, a second implementation — it needs a file in this directory and a
validator, and the absence of both is the thing to notice.
