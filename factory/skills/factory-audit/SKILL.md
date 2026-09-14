---
name: factory-audit
description: |
  Independently audit one pipeline artifact in a fresh context and write a
  schema-conformant PASS/FAIL verdict with evidence-backed findings. Targets:
  spec, impl, doc, package. Use when a pipeline step's output needs auditing;
  invoked as /skill:factory-audit <target> <run-dir>, typically inside a child
  pi process that can see the artifact but not the conversation that produced it.
---

# pipeline-audit

You audit work you did not see produced. That is the point: the fresh context
is what stops you rationalizing the artifact. If you find yourself assuming
"they must have meant X" about prior intent, delete the assumption — you
cannot know it.

## Rules

- **Everything you need arrives by file, named in your arguments or in the run
  dir.** Never assume a prior conversation. Never read run-dir artifacts that
  are not the input of this target (e.g. when auditing `spec`, do not read
  `implementation.json`).
- Project specifics come from `ai/pipeline/config.json` in the current working
  directory (`bin_dir` holds the pipeline scripts). Never hardcode repo paths.
- **No evidence, no finding.** Every finding needs a command output, a quote,
  or a file:line that proves it. Vague findings cost a retry and are worse than
  a PASS.

## Inputs

Arguments (appended to this skill as `User: <args>` — parse them from there):
`<target> <run-dir>` where target is `spec`, `impl`, `doc`, or `package`.

## Process

1. Validate target and that `<run-dir>` exists. The target must be exactly one
   of `spec`, `impl`, `doc`, or `package`. Anything else is an **invalid
   target: STOP — report the invalid target and exit without starting the
   step, writing a verdict, or touching `<run-dir>`**.
2. **Read the verdict schema first — do not reconstruct it from memory:**
   `cat <bin_dir>/VERDICT-SCHEMA.md` and write your verdict to match it exactly.
3. Determine `attempt`: `1 + ` the count of existing
   `<run-dir>/verdicts/<target>.attempt-*.json` files.
4. Start the step: `bash <bin_dir>/step.sh <run-dir> audit-<target> start`.
5. Audit per the target's rubric below. You are in a fresh context: verify
   claims by re-running commands and re-reading files, never by trusting
   earlier output in the run dir.
6. Write the verdict JSON to `<run-dir>/verdicts/<target>.attempt-<n>.json`
   (`mkdir -p` first), and print the verdict JSON to stdout.
   **The file name comes from the target argument only.** Target `impl` →
   step name `audit-impl` for `step.sh`, and the file exactly
   `<run-dir>/verdicts/impl.attempt-1.json` — never `audit-impl.attempt-1.json`,
   never `audit-implementation.attempt-1.json`. The driver looks up verdicts
   by target name; a file under any other spelling makes a passed audit
   indistinguishable from a missing one and the run halts on a phantom
   failure.
7. End the step: `bash <bin_dir>/step.sh <run-dir> audit-<target> end PASS|FAIL`
   (verdict from your JSON).

## Rubrics

### `spec`

Read `spec.json` (and `spec.html` if sanity-checking consistency with the
JSON — the JSON is the contract). Judge:

- Complete: problem, per-file changes, acceptance criteria, tests, and an
  explicit expected-file list are all present and concrete.
- **Every acceptance criterion has a test that could fail.** A criterion whose
  "test" is manual, nonexistent, or a tautology (`test -f` on something a test
  itself creates) is a blocker. Where a named test already exists on disk, run
  it against the current unmodified tree and confirm it actually fails — that
  is your evidence either way.
- Scope: does the spec name files it has no business touching?

### `impl`

Read `spec.json` and the actual diff: `git diff main...HEAD --stat` then the
changed files.

- Does the diff do what the spec said, no more, no less?
- **Are the tests real?** Read every test the spec names. Assertions that
  would pass with the change reverted (truthy-by-construction, asserting the
  test's own setup) are blockers. Where a source file exists on `main`, run
  `bash <bin_dir>/fails-on-revert.sh <source-file> <test-command>` yourself.
- **Run `bash <bin_dir>/checks.sh <run-dir>` yourself and require exit 0.**
  Do not trust any recorded claims.
- scope_check: compare `git diff main...HEAD --name-only` against
  `expected_files`; files not in the spec fail the scope check.

### `doc`

Read `implementation.json` (and `implementation.html`) against `spec.json` and
the actual diff.

- Does it describe what was **built**, not what the spec said would be built?
  Spot-verify its claims: file names, function/endpoint names, behavior —
  grep the diff.
- Check `changes_from_spec` against the diff in both directions: a deviation
  the diff shows but the section omits is a blocker; a deviation it claims but
  the diff doesn't show is a major.

### `package`

The whole run. Its distinctive job is the **scope check**:

```
git diff main...HEAD --name-only            # vs spec.json .expected_files
```

Any changed file the spec did not name is scope creep — report it as a finding
**and** set `scope_check.pass` to `false` (a PASS verdict with a failed scope
check is invalid per the schema). Also confirm the run is coherent: the gates
were actually run (re-run `checks.sh` — do not trust `checks.json`), and there
is no `QUESTIONS.md` sitting unanswered.

**Run integrity — check this first, in the repo root; each violation is a
blocker.** The package audit judges the run, not just the change:

1. Branch: `jq -r .branch <run-dir>/run.json` is not `main`, and the run branch
   exists in git with the working tree on it (`git branch --show-current`).
2. Commits: the run branch has at least one commit beyond main
   (`git rev-list --count main..$(jq -r .branch <run-dir>/run.json)` ≥ 1) — a
   PR needs something to push.
3. Bookkeeping: every `end` line in `<run-dir>/steps.jsonl` has a matching
   `start` at the same attempt (join on `step` and `attempt`), and no attempt
   is closed twice.
4. Consistency: `run.json` `status` matches the recorded steps — a `halted`
   status with all steps ended PASS is inconsistent, and a completed status
   with a `QUESTIONS.md` left at the run dir root is a stale halt.
5. Verdict file naming: every file under `<run-dir>/verdicts/` matches
   `<target>.attempt-N.json` for one of the four targets (`spec`, `impl`,
   `doc`, `package`). A verdict under a different name (a step name or other
   spelling) is invisible to the driver — the run is treated as if the audit
   produced no verdict at all, so `run.json` may sit `halted` while a passed
   audit file sits uncounted in `verdicts/` next to it. Report as a
   run-integrity blocker.
6. Verdict file presence: **expect verdict files only for the audit steps the
   run's tier actually ran** (read `tier` from `run.json`: `small` runs
   `audit-impl` and `audit-package` but not `audit-spec`/`audit-doc`). An
   authoring step (`spec`, `implement`, `doc`, `pr`) records its verdict on
   the `end` line in `steps.jsonl` and writes **no file in `verdicts/`** —
   an absent verdict file for an authoring step, or for an audit step the
   tier skipped, is **not a finding**. Only an audit step the tier ran whose
   verdict file is missing (when `steps.jsonl` shows it finished) is one.

These checks exist because real runs have failed these exact ways: one
BEAN-125 run ran entirely on `main`, committed nothing, and shipped unpaired
`end` lines — and both audits looked straight past it judging only the diff.
A later BEAN-125 run wrote its PASS implementation audit as
`audit-implementation.attempt-1.json` (the step name, not the target `impl`);
the driver counted no verdict, the run halted, and its `QUESTIONS.md` read as
if no audit had run.

## Severity guidance

- **blocker** — contract violated: untestable criterion, tautological or fake
  test, claimed-but-absent implementation, deviation without disclosure.
- **major** — real problem, bounded: missing test evidence, thin verification,
  doc drift that could mislead.
- **minor** — polish: naming, wording, ordering.

A `blocker` forces FAIL; a FAIL requires at least one finding (see the schema).
