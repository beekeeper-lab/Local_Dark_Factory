---
name: pipeline-doc
description: |
  Write the implementation-detail document for a completed pipeline run: what
  was built, why, how the pieces fit, and what changed from the spec and why.
  Produces implementation.html (human) and implementation.json (machine). Use
  when the user asks to document an implementation (doc step of the pipeline).
---

# pipeline-doc

The doc step. This document teaches the change. The section that keeps this
step worth its runtime is **"what changed from the spec, and why"** — if it is
consistently empty across runs, this step gets cut. An honest
"nothing changed" is a finding in itself. Do not pad.

## Rules

- Fresh context: describe what is actually in the diff, not what the spec
  promised and not what any conversation claimed. Fresh context means you have
  no conversation — the diff is what you have.
- Project specifics come from `ai/pipeline/config.json` in the current working
  directory. Never hardcode repo paths.

## Inputs

Arguments: `<run-dir>`.

## Process

1. Read `<run_dir>/run.json` and `<run_dir>/spec.json` (what was promised).
2. Start the step: `bash ai/pipeline/step.sh <run-dir> doc start`.
3. Read what was actually built: `git diff main...HEAD --stat` and the changed
   files (use the file list in spec.json plus the diff to find anything else).
4. Write both artifacts (see below).
5. End the step: `bash ai/pipeline/step.sh <run-dir> doc end`.

## Artifacts

### `<run_dir>/implementation.json` — the source of truth

```json
{
  "bean": "BEAN-NNN",
  "what_built": "what the change does, verified against the diff",
  "why": "why it is wanted; why this approach over the alternatives",
  "how_it_fits": "how the new/changed pieces fit into the existing structure",
  "changes_from_spec": [
    { "spec_said": "…quote or paraphrase spec.json…", "it_did": "…what the diff shows…", "why": "…" }
  ]
}
```

- `changes_from_spec` is an empty array **only** if the diff actually matches
  the spec. Every deviation goes here with its reason. Omitting a real
  deviation is a blocker the audit will look for.

### `<run_dir>/implementation.html` — the human review surface

Self-contained (no external assets). Same content as the JSON, plus enough
code-level detail (the important functions/queries/routes) that a reviewer who
never saw the diff lands on it, gets the point, and can trust the
"changes from spec" section.
