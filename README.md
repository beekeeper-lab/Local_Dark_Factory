# Local Dark Factory

A lights-out software line running on local models on **Forge** (Framework Desktop, Fedora Server, ~126 GB unified memory). Humans and AI refine requirements into *beans*; the line writes the spec, audits it, builds it task by task, audits the build, writes the implementation-detail document, audits that, and opens the PR. Frontier models build and tune the line — they never run on it.

Roles: developer `qwen3.8:27b-mtp-q8_0` via Pi · judge `gpt-oss:120b` · deterministic Python and shell controller · human at intake and merge · Opus as outside builder via PRs to this repo.

## Running it

From inside the repository the line should build in:

```
factory doctor            # is this repo ready to be run against?
factory beans             # the approved beans, in run order
factory run bean-001      # the whole line: preflight → pull request
factory status            # what the newest run did, stage by stage
factory runs              # every run, newest first, and how each ended
```

`factory` is `factory/bin/factory`. It finds the target repo's config, snapshots the pipeline and runs from the copy, so the line can be edited while a bean is building.

Two more, for the things a script cannot settle:

```
factory policy            # what risk-policy.yaml does to each bean, as a table
factory read              # record that a human read a run's two documents
```

## What holds the line together

The controller decides; the models write. Anything decidable by running something is decided by running it, and the judge is asked only for what counting cannot reach — see `bench/controller-fitness.sh` for which is which.

| Where | What |
| --- | --- |
| `factory/pipeline/` | the controller: one script per stage, each refusing rather than degrading |
| `factory/skills/` | what the models are asked for, and the contracts they are measured against |
| `factory/worker-image/`, `factory/gate-image/` | the two pinned containers: one writes code, one judges whether it works |
| `schemas/*.json` | the eight contracts: bean, task, verdict, event, gate-manifest, risk-policy, repo-config, run-record |
| `bench/` | measurement — fitness harnesses, phase audits, conformance probes |
| `factory/pipeline/tests/` | `run-all.sh` runs every suite (~500 assertions, ~80s) |

Both the worker and the verification gates run in containers with no network at all. The worker reaches exactly one model endpoint, over a unix socket bridged to a single address — there is no route to widen. See `RESUME.md` for what that cost and why it is built the way it is.

| File | Role |
| --- | --- |
| `dark-factory-guide.html` | The specification (v5). Open in a browser. |
| `DARK_FACTORY_IMPLEMENTATION_PLAN.md` | The resumable phase ledger — check boxes as work completes. |
| `RESUME.md` | Where the work is, what is measured, and what is still open. Read this first when picking the work back up. |
