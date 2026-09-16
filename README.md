# Local Dark Factory

A lights-out software line running on local models on **Forge** (Framework Desktop, Fedora Server, ~126 GB unified memory). Humans and AI refine requirements into *beans*; the line writes the spec, audits it, builds it task by task, audits the build, writes the implementation-detail document, audits that, and opens the PR. Frontier models build and tune the line — they never run on it.

Roles: developer `qwen3.8:27b-mtp-q8_0` via Pi · judge `gpt-oss:120b` · deterministic Python and shell controller · human at intake and merge · Opus as outside builder via PRs to this repo.

## Running it

From inside the repository the line should build in:

```
factory doctor            # is this repo ready to be run against?
factory queue             # what is runnable, and what blocks the rest
factory go                # run the approved beans in order, stopping at the first halt
factory status            # what the newest run did, stage by stage
factory runs              # every run, newest first, and how each ended
```

`factory go` is the line; `factory run bean-001` is one bean of it. The queue
takes the order and the dependencies from the beans themselves, refuses anything
that is not `status: approved`, and stops the moment something halts — whatever
stopped one bean would stop the next.

With `merge_mode: human_required` it also stops when a bean's pull request is
open and unmerged, because the next bean builds against the default branch and
that is where the work is not yet. That is the line working, not the line broken.

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
| `factory/pipeline/tests/`, `bench/tests/` | `run-all.sh` runs every suite in both, ~1200 assertions in ~two minutes |

Both the worker and the verification gates run in containers with no network at all. The worker reaches exactly one model endpoint, over a unix socket bridged to a single address — there is no route to widen. See `RESUME.md` for what that cost and why it is built the way it is.

One check is not in the repository at all. `allowed_write_paths` stops the worker writing the tests it will be measured by; nothing stops it reading them, and code written against visible assertions satisfies exactly those. `hidden_tests` in the pipeline config names a directory **outside** the repo — refused if it is inside — mounted read-only into the gate container at a path the worker never had. What comes back is a count: no names, no assertions, no output, and the full log is written outside the repo too, because the run directory is in it.

| File | Role |
| --- | --- |
| `dark-factory-guide.html` | The specification (v5). Open in a browser. |
| `DARK_FACTORY_IMPLEMENTATION_PLAN.md` | The resumable phase ledger — check boxes as work completes. |
| `RESUME.md` | Where the work is, what is measured, and what is still open. Read this first when picking the work back up. |
