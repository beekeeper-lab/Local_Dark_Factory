# Resume here — Phase 1

Phase 0 closed 2026-09-14 (tag `phase-0-complete`). Branch `factory/phase0-prep-and-bean-set-v1`.

## State: Phase 0 closed. Phase 1 is built end to end, and one real run has now finished — PR #1 is open.

**Test coverage as of 2026-09-15 evening: 940 assertions across 26 suites, all green.**
Nine of those suites are new that evening, written against the scripts that had no
tests at all — the CLI, judge.sh, claims-check.py, preflight.sh, new-run.sh,
policy-preview.sh, telemetry-report.sh, lib.sh and the new sync step. Every one of
them found a live defect in the first hour, which is the argument for writing them:
see "What the untested scripts were hiding" below.

All six `phase_0_exit` predicates hold — and, as of the audit, they are *computed*
rather than asserted (`bench/phase0-audit.sh`), which they were not before:

```yaml
residency_recorded: true      swap_time_measured: true     harmony_conformance: pass
pi_drives_both_models: pass   regime_decision: "serial"    figures_have_provenance: true
```

The audit found 10 things (2 blocker, 5 major, 3 minor); all were corrected and the
re-run is green. Report: `audits/PHASE-0-AUDIT-20260914.md`. The two that matter most
for anything downstream:

- **Evidence is now committed.** `bench/results/` was gitignored, so every Phase-0
  figure lived only on Forge's disk. The cited artifacts are tracked by name now.
- **Run conditions are observed, not declared.** `run-step.sh` used to stamp
  `conditions.num_ctx` and `conditions.thinking` from `roles.json`. pi has no
  `num_ctx` flag at all, so that number was fiction whenever the server disagreed.
  Both are now read back (pi's session file, ollama `/api/ps`), with the declared
  value kept beside the observed one and a `declared_matches_observed` flag.

Marker convention, set here and binding on every later phase: a commit whose subject
begins `PHASE-N-COMPLETE`, plus an annotated tag `phase-N-complete`. Tags are local until
pushed.

**All 20 seating-planner beans are `status: approved`** (2026-09-14, bulk approval delegated
by the owner — recorded as such in `bean-sets/v1/manifest.json`, because a set-level
approval is not the per-bean human read §04 describes). Run order is bean id order, which
is a checked topological order.

## Sandbox — what is contained

`factory/pipeline/sandbox.sh` implements the §08 contract for verification and refuses
rather than degrades. Proven by attempting each escape (`tests/test-sandbox.sh`, 36 cases):
read-only outside the one writable tree, no network, no capabilities, no host environment,
no container socket, no SSH agent, limits on memory/cpu/pids/wall-clock/output, image pinned
by digest and checked against it, no git binary in the image, no `.git` in the tree.

**The worker is contained too, as of 2026-09-15.** `factory/worker-image/` (node pinned by
digest, pi pinned by version) + `worker-sandbox.sh` + `model-gateway.sh` + `model-bridge.py`,
pinned in `factory/worker.lock.yaml`.

The network story was the easy half once looked at properly. There is no route:
`--network=none` removes every one, and the model arrives on a unix socket bridged on the
host to exactly one address and port. Stronger than an allow-list, because there is no
interface to widen. Two things worth keeping in mind:

- The bridge runs under `runcon -t container_t`. SELinux checks a unix socket connection
  against the peer *process's* context, not the file's label, so a container may not connect
  to a socket held by an ordinary user process however the file is relabelled. This took
  three attempts to see; `factory doctor` now checks `runcon` is present.
- `.git` is masked with an empty read-only mount rather than removed, so edits land in the
  real tree where the change scan reads them, while `git` inside reports "not a git
  repository". The controller makes every commit.

**Everything that can quietly stop containing now says so.** Not decoration: a pipeline
snapshot silently turned worker containment off for a whole run, found only by noticing a
session file path in a log. Every uncontained developer session now prints why,
`FACTORY_VERIFY_SANDBOX` governs every verification sandbox in one place, and the snapshot
refuses to start if it is missing anything the line resolves paths against.

## Six ways a check goes wrong, all found on 2026-09-15

Every one of these was in code written here, most of it written the same day, and
each was found by a real run rather than by a test. They are listed because the
next check written will be able to have one of them.

Three of the six, the model being checked said so in its own report, and was
right.

**1. Measuring something other than what it claims.** doclint reported a
three-thousand-character section as empty: it started a new section at every
heading, including deeper ones, so a `## Proposed change` written as `### task-N`
subsections measured only the empty gap before the first. The comment above the
code described the correct rule; the code did something else. doc-check had the
same bug in its walkthrough coverage. Both were refusing the shape the authoring
skill explicitly asks for, so the only document that could pass was one nothing
asks for. **The model said so in its own retry report and was right.**

**2. Failing open.** `contain.py || true` swallowed exit 2 — "I could not run" —
alongside exit 1 — "violations found". Both print nothing, so a crashed
containment check reported a clean diff and the gate recorded `contained: true`.
Also: spec-check skipping schema validation with a `note`, preflight's bean lookup
finding nothing and reporting nothing, sync-tree asserting its no-.git guarantee
only at the top level. **A check that can decline to run must say so in a way that
fails, because silence is indistinguishable from a pass and will be read as one.**

**3. Truncating before measuring.** The secret scan's `head -20` sat inside the
pipeline that produced the match list, so fifty leaked credentials reported as
twenty. audit-check's quote haystack was `-maxdepth 2`, so a quote from an attempt
log four levels down was refused as invented — the one accusation that script must
never make wrongly.

**4. Overruling the thing being measured.** A `definition_of_done` check I wrote
would have failed all twenty beans for using the field the way the schema
permits — prose rather than criterion ids. Caught before commit only because the
corpus was checked first. The claims check went through three versions of this,
each firing wrongly on a real spec, before the rule was inverted to require
positive evidence of a claim rather than inferring one from the absence of a
denial.

A fifth, adjacent: **a diagnostic that points at the wrong cause.** "child exit 1"
for a doc step that wrote nothing, and a "terminated" line from the container's
own forwarder that read like an external kill and cost a real diagnosis session
looking for a signal nobody sent.

**6. Asking whether a thing exists when the question is who made it.** Added
2026-09-15 evening, and it is category 1 wearing a different hat. run-step
reported "its output IS present, so this is a failure after the work" for a doc
attempt that wrote nothing — the file on disk was byte-for-byte a previous
attempt's, four hours old. Orchestrate's doc retry had the same test
(`[ ! -s impl-detail.md ]`), which on any resumed run is always false, so the
retry that exists precisely for this failure never fired and the run halted for a
human. Both now hash the file before the session and after. **Existence is not
authorship, and on a resumed run every output of every earlier attempt is sitting
right there to be mistaken for this one's.**

## Deterministic checks — what used to be the judge's job

Four rubric items moved out of the judge into the controller, each with tests. A deliberate
response to measuring the judge, not a tidying exercise:

| check | settles | was |
|---|---|---|
| `spec-check.sh` verify precheck | a task whose every check already passes cannot be demonstrated | spec rubric |
| `claims-check.py` | files the spec says exist, against the filesystem | spec rubric |
| `test-integrity.sh` | do the tests fail with the source reverted | impl rubric |
| `package-check.sh` | every arithmetic bullet — pairs, status, naming, tier | the whole package rubric |

`bench/controller-fitness.sh` runs the judge's own six seeded cases through these.
**Re-measured 2026-09-16 against a clean base** (`controller-fitness-20260916T003558Z.json`):
the clean control passes, **1 of 5** caught by name, 0 false alarms, ~6 seconds a case, no
variance. The other 4 are the judge's actual job.

The earlier figure of 2 of 5 was measured with the target repo on a bean branch — the work
already committed, so every verify already passed and the clean control failed. The harness
refuses that state now. **1 of 5 is the honest number**, and the drop is a measurement
improving, not a check regressing.

The one that moved is worth naming, because the claim in the table above is narrower than it
reads. The `tautological-verify` case replaces *one* of task-1's verifies with `test -d .`.
verify-precheck names it — *"each task has a check that fails first; these do not, which may
be fine: task-1[0] …"* — and passes, because its rule is that each task needs **at least one**
check that can fail, and task-1 still has three. That rule is right: a task legitimately
carries always-passing checks (`ruff check .` passes on a clean tree), and failing on them
would make the check untrustworthy on good specs. So the precheck **surfaces** a single
tautological verify and does not **catch** it. Whether one planted among several real ones
should fail the spec is a judgement call, which is the definition of the judge's job.

Three lessons are baked into those checks and are worth not relearning:

- **A one-sided check is unsound.** test-integrity first ran the tests only on the reverted
  tree and called any failure "the tests pin the change" — so a missing binary read as
  success. It now requires a control run on the unreverted tree first.
- **A fuzzy signal belongs on the forgiving side.** claims-check reads English negation so
  "there is no `src/a.py`" is not reported as a false claim. Using the same signal to *fire*
  a failure was wrong twice in one section of the first real spec it met. Suppress on a
  maybe; never accuse on one.
- **Only fail on what is decidable.** test-integrity exits 2 — undecided — for "no tests
  written" and "the tests do not pass to begin with", because a change with no tests may be
  a config bump. A check that fails runs on judgement calls gets switched off, and takes the
  decidable one with it.

## The three ranked gaps in the forked pipeline are closed

1. ~~No task loop~~ — `build-loop.sh`, 83 assertions.
2. ~~Sandbox — half~~ — the worker is contained as of 2026-09-15; see above.
3. ~~The model declares its own tier~~ — `tier.py` + `gate.sh`. The tier comes from the
   paths the diff touched; bean and judge can only raise it.

## The stages, as they stand

| Stage | Model half | Controller half | Tested |
|---|---|---|---|
| preflight | — | `preflight.sh` | via full-line |
| specify | `factory-spec` writes `spec.md` + `tasks.yaml` | `spec-check.sh`: sections, schema, paths, claimed criteria, budget, **verify precheck, current-behaviour claims, byte budget**, renders HTML | 31 |
| spec audit | `factory-audit` writes a *judgement* | `audit-check.sh` stamps provenance, validates, amends the step | 48 |
| build | `factory-build-task`, one task per session, **contained** | `build-loop.sh`: contain → reject+reset → verify in the sandbox → commit | 83 |
| gate | — | `gate.sh`: whole-diff containment, tier, budget, secrets, gates, ACs, invariants, **test integrity** | 44 |
| document | `factory-doc` | `doc-check.sh` + `doclint.sh`: sections, diff coverage both ways, renders HTML | 13 + 33 |
| pre-PR audit | `factory-audit` | **`package-check.sh`** settles the whole arithmetic rubric first | 24 |
| sync | — | **`sync.sh`**: rebases a branch the base has moved past, files the now-stale results, and sends the line back to the gate | 48 |
| PR | — | `pr.sh`: refuses without an accepting verdict, a clean tree, a gated diff, a base that has not moved | 25 |

`sync` is the only step that can run the line backwards. It writes `rewind.json`,
the orchestrator's loop reads it at the top of each iteration, and gate,
audit-impl and audit-package run again against the new candidate. The spec audit
does not: it judged the plan, and a rebase does not change the plan.

Supporting: `sandbox.sh` (36), `test-integrity.sh` (22), invariants (9), role routing (38).

**`tests/run-all.sh` runs every suite** — 455 assertions, ~64s; `--fast` skips the
end-to-end ones. `tests/test-full-line.sh` drives preflight → pull request with pi, the
judge and gh stubbed, in about twenty seconds. It exists because the two worst bugs this
project has had both lived past `build` and neither needed a model to reproduce.

## OPEN: the judge is measured, and the measurement is that it is not reproducible

This section previously said the judge "works in principle" and laid out a hypothesis about
schema complexity. The hypothesis was never the problem. **Ask the same question five times
with identical input at temperature 0 and you get two different verdicts.**

`bench/judge-variance.sh`, gpt-oss:120b, one seeded defect, byte-identical input each run:

```
revise   9 findings   confidence 0.99   232s
revise   1 finding    confidence 0.90   168s
revise   1 finding    confidence 0.95   137s
none     —            —                 449s
revise   4 findings   confidence 0.95   197s
```

The defect was named in an earlier fitness run and in none of these five.

**The consequence lands on this project's own conclusions.** Every judge finding here came
from comparing single runs: fenced artifacts against unfenced, one message per artifact
against one blob, gpt-oss against gemma4, 4000 tokens against 12000. One sample per arm
against a spread at least this wide. Those comparisons are withdrawn.

What survives on other evidence:

- The format fixation was real — "the document is not valid JSON" in several logs across
  runs. **One message per artifact stopped it appearing at all**, which is a different kind
  of evidence from a rate moving.
- **gemma4 is a rubber stamp**: three false accepts in the three cases it judged, 17s each.
  Strong even at n=1 per case. gpt-oss:120b stays.
- Two of the five seeded defects in `bench/judge-fitness.sh` were **not the defects they
  claimed to be** until 2026-09-15. `tautological-verify` mutated the task list with a regex
  that stopped at a `]` inside a Python string, leaving a syntax error. The judge read it,
  reported a syntax error, and was scored as having missed the defect — three times. Part of
  the "format fixation" it was accused of was, on that case, the judge being right.

**So the judge is advisory for now.** `--advisory-audits` lets it run, write a judgement and
have a verdict stamped, without a verdict short of accept stopping the run. Only the model's
opinion is softened; every deterministic check stays blocking. The advisory is written into
`failed-attempts/` with its reason and `pr.sh` lists it in the pull request, so "advisory"
cannot quietly become "ignored".

**The productive direction is not prompting.** It is moving what is decidable into the
controller — see the deterministic checks section above — and leaving the judge the part
counting cannot reach. `bench/judge-fitness.sh --repeat N` exists now; anything you intend
to compare against another number needs it, and the harness says so in its own output.

Also settled today: `repeat_penalty` 1.1. Two audits in a row hit the token cap, and neither
was thinking hard — one spent its last few hundred tokens repeating a single sentence inside
a string it never closed. temperature 0 makes that worse, not better: with no sampling noise
a model that starts a loop has nothing to break it.

## The judge does not run as an agent

`audit-*` does not go through `run-step.sh`. gpt-oss:120b under pi calls a
`repo_browser.*` tool namespace that does not exist here — twelve calls, empty
arguments, no result, and then a confident audit of a document it never read.
`judge.sh` puts the artifacts in the question instead, constrains the answer,
and writes the file itself. A system message denying tools is load-bearing:
without it the model emits those tool calls even against the raw API with the
documents already in the prompt.

It is also the only place in the line where the declared context is the served
context, because `/api/chat` takes `options.num_ctx` and pi does not.

## The worker's harness surface is closed

`run-step.sh` passed pi `--model`, `--thinking`, `--skill` and nothing else, so pi
discovered the rest on its own: every file in `~/.pi/agent/extensions/` — 24 on this
box, among them `github-mcp.ts`, `trello.ts`, `obsidian.ts`, `team-lead.ts` and two
`posttooluse-edit-write` hooks — plus the prompt-template directory, plus any
`AGENTS.md`/`CLAUDE.md` in the target repo, prepended silently. None of it was in the
run record. That is the skill collision one directory over, on a line whose invariant
is "no credential near a model".

Now: `--no-extensions --no-prompt-templates --no-context-files --tools read,write,edit,bash`,
and `conditions.harness` records the flag set and the four tool names, so two runs
with different surfaces are not mistaken for comparable. `factory-spec` still tells
the worker to *read* the repo's context files if present — a recorded act — which is
why turning off the silent injection loses nothing.

Not done, and why: `--no-skills` alongside the explicit `--skill` would make the
global-skill collision impossible rather than alarmed, but whether pi 0.85.1 still
honours `--skill` under `--no-skills` needs a live smoke step to prove; the stub
cannot. The collision check stays as the defence until then.

## Queued for an idle pipeline

The judge setting its own `options.num_ctx` changes what `OLLAMA_CONTEXT_LENGTH` has to
do: it no longer has to express two roles, only the developer's. These wait for no run
in flight, and the first one restarts ollama:

- `zz-factory.conf`: add `OLLAMA_CONTEXT_LENGTH=32768` (or 49152, the co-residency
  probe's figure), `daemon-reload`, restart. Then `conditions.num_ctx` observed should
  equal declared for the developer too, and the 262144 default that made the spec step
  take eight minutes cannot recur.
- Smoke step with `--no-skills --skill "$FACTORY_SKILLS"`; if the skill loads, add
  `--no-skills` to `HARNESS_FLAGS` and demote the collision check to a regression test.
- Spike `pi --mode json` on a smoke step. If model, thinking level and tool calls arrive
  as events on stdout, `run-step.sh` reads them there and the session-directory search
  (`pi_sessions_dir()`, ~100 lines) goes; a pi update that changes the session format
  stops being a silent risk.
- `handle_audit_failure` hands the re-entered authoring step the whole verdict file,
  which after `audit-check.sh` names the judge's `model_digest`. The worker needs the
  findings, not the provenance block.
- One benchmark arm with `--append-system-prompt` for the developer — four lines: scope
  only what was asked; four tools exist and no others; the controller decides done, do
  not claim it; if blocked, write `QUESTIONS.md` and stop. `judge.sh` found the system
  message load-bearing for gpt-oss; whether it moves the 27B's containment-violation or
  `BLOCKED.md` rate is a measurement, not a prescription.

## What the first real runs taught

Four runs of bean-001 against the real models. Every one failed, each for a
different reason, and three of the four were **the line catching itself**:

1. The developer followed **another project's skill** — `~/.pi/agent/skills` has
   its own `pipeline-spec` and pi loads both. Fixed by prefixing every skill
   `factory-`, with a collision check that stops the run.
2. `.gitignore` was called a containment violation. The bean allows it; the
   matcher used `lstrip("./")`, which strips *characters*. Every dotfile was a
   false violation.
3. The judge wrote nothing usable — `factory-audit` was still the forked skill.
   That is what forced the judgement/verdict split.
4. `ac1` could never have passed: it imports a package the gate container never
   installs. **The developer model found this, refused to write a spec around it,
   and said so** — then `halt()` overwrote its report with a generic one. Fixed
   both: `sandbox_env`, and worker questions are now preserved.
5. The judge audited a document it never read — a fluent review of sections that
   do not exist in this format — and printed it instead of writing it. Forced the
   `quote` requirement: every criterion cites text the controller then looks for.

Six runs, six halts, nothing false let through. The halts are the product.

The conditions record has been the most useful single thing: on run one it
reported `num_ctx: 262144` observed against `32768` declared, which is true, was
invisible before, and explains the eight-minute spec step.

## What the untested scripts were hiding

Written 2026-09-15 evening. Ten pipeline scripts had no test of their own; nine now
do. Each of these was found by the first few assertions written against the script,
and none of them would have failed a run loudly:

| script | what it was doing |
|---|---|
| `factory` (CLI) | the help named steps `specify` and `document`; `--stop-after` refuses both. The two names a person was most likely to copy were the two that could not work. |
| `factory runs` | printed an empty table and exited 0 when the runs directory existed but held nothing — "no history" and "you pointed me somewhere wrong" were the same output. |
| `judge.sh` | on an empty answer it printed the first 300 bytes of the raw response, which for this model is 300 bytes of the *thinking* field: a fluent paragraph about a different task, presented as the error. |
| `new-run.sh` | "roles.json has no usable 'judge' role" could not fire — `.roles["judge"]` on a file with no judge builds `{"model":null,...}`, which is neither empty nor `"null"`. Run records were written full of nulls. |
| `telemetry-report.sh` | the orchestrator row read **0 on every run** since child steps started recording their own sessions: the attribution branch produced an empty assignment and dropped every driver event. Totals were short by the whole driver cost. |
| `policy-preview.sh` | cut the reason a bean got its tier off mid-word on sixteen of twenty rows, losing exactly the part that says whether the POLICY or the bean set it. |
| `claims-check.py` | the source comment overstated what the 48-character window does. Measured: a negation in the previous sentence still reaches; ten more characters and it does not. |
| `preflight.sh` | exercised only through the full line, where it passes. Nothing had ever asserted that it REFUSES — the wrong half to leave untested. |

**The common shape, again:** none of these fails a run. They produce a plausible
record of something that did not happen, or a diagnostic pointing somewhere else.
That is the fifth and sixth entries in the defect taxonomy above, and it is what
"the check is the product" actually costs.

Also removed that evening: `checks.sh` and the `factory-implement` skill — a
pre-build-loop path that ran the gates on the host with unpinned tools and told a
model to report success from them, which is the opposite of the rule the rest of
the line is built on. Nothing reachable used them.

## A full temp filesystem is invisible from inside the line

`/tmp` here is a 63G tmpfs — RAM. The gate tree, the pipeline snapshot, every
worker's agent directory and the model gateway socket all live in it. When it
filled, the contained worker's write failed with `Unknown system error -122`
(errno 122, EDQUOT), pi exited 1, and the run correctly recorded a doc step that
produced nothing. Every part of that chain is true and none of it says "the disk
is full".

Three fixes: `factory run` prunes its own abandoned snapshots (it `exec`s into the
copy and cannot delete the ground it stands on, so twelve had accumulated);
`factory doctor` reports free space on the temp root and fails below 2 GB, with the
`-122` string in the message so a search for that error finds the cause; and the
test that caused it refuses to `cp -r` a path that is not the pipeline.

Two things behaved well under it, and both are worth keeping in mind as the
standard: the model gateway **refused** rather than falling back to running the
worker on the host — the containment guarantee held during a resource failure,
which is when guarantees usually do not — and the run halted rather than recording
a pass.

## OPEN: something SIGTERMs the doc worker at ~1000 seconds

Not identified as of 2026-09-15 evening. A doc session wrote a complete
18,626-byte document, printed its report, and its container died at 1022 seconds
with code 143 — well short of the 3600-second `timeout` in `worker-sandbox.sh`.

It is **not** this project's test suite, which killed a live build once before and
was the first suspect: a sentinel container and a sentinel process were run
alongside all 26 suites in sequence and both survived every one. `podman events`
is the place the death is visible; nothing in the pipeline's own logs names a
source.

The line no longer loses the work to it. `run-step.sh` already held the rule that
a `pi -p` exit status is fallback evidence rather than an override of a verdict the
child stamped; that now extends to a step whose output is a file. Every expected
output freshly written by this attempt — verified by hash, not by existence — is a
PASS regardless of the exit code, and the checks that read the file run next, so a
half-written one still fails on its contents.

## DONE: one real run reached a pull request

`bean-001-20260915T192025Z`, 2026-09-15, ~2h35m of step time across eleven steps.
**https://github.com/beekeeper-lab/seating-planner-py/pull/1** — +64/−0 across four
files, opened by the line, merged by nobody.

What it took, and what each halt was: the doc step failed five times before it
passed, and only the first was the model — attempt 1 narrated and wrote nothing;
attempt 2 was killed by this project's own test suite; attempt 3 looped on "now
writing the full document"; attempt 4 died when a full tmpfs made every write fail
with `Unknown system error -122`; attempt 5 wrote a complete document and was
SIGTERMed at 1022 seconds by something still unidentified. Attempt 6 passed. Three
more halts came after it, and all three were the line's own rules disagreeing about
advisory audits — package-check, pr.sh and phase1-audit each assumed a verdict
that advisory mode is defined not to produce.

**Every one of those halts is now a test.** That is the whole product: nine of the
eleven steps passed on the first attempt, and the two that did not stopped the run
rather than letting anything through.

Phase-1 exit as computed from that run:

```yaml
seven_stages_completed: pass              every_handoff_is_commit: pass
allowed_path_enforced_task_and_bean: pass docs_rendered_and_read: pending_human
three_verdicts_schema_valid: not_exercised   (advisory: the judge reached no verdict)
task_retry_with_evidence: not_exercised      (no task needed a retry)
independent_invariant_ran: not_applicable    (bean-001 declares none; bean-006 is the first)
```

Three pass, one waits on a person (`factory read <run>`), three are not-exercised
or not-applicable and say which. None failed.

## Next action

**Two decisions for the owner, then Phase 2.** See "Still open" below for
`required_checks`, and the Phase-1 invariant item in the plan for the
run-002-through-006 versus re-read-the-predicate choice — both have a
recommendation attached.

The instructions below still stand for the next bean. Everything is built,
every step has been exercised, and no single real run has yet gone the whole way. Six
defects stopped the first five attempts; all are fixed and all have tests.

```
cd /home/gregg/workspace/seating-planner-py
FACTORY_ADVISORY_AUDITS=1 /home/gregg/workspace/Local_Dark_Factory/factory/bin/factory run bean-001
```

`factory run` is the entry point — it finds the config, snapshots the pipeline and runs from
the copy, so editing the repository mid-run is safe. `factory doctor` says whether the
target is ready. `factory status` shows what the newest run did, stage by stage.

Between runs the repo must be back on `main` with the bean branch deleted, and
`factory/runs/` cleared if you want a clean record — preflight refuses a dirty tree,
correctly, and that is the most common way a re-run stops in its first ten seconds.

**Advisory audits are on deliberately** while the judge is unreliable; drop the environment
variable to make its verdicts blocking again.

### What today's six defects have in common

Worth reading before adding anything to the line, because the pattern will recur. Every one
was **silent** — no error, no warning, just a plausible record of something that had not
happened:

| what happened | what it looked like |
|---|---|
| a pipeline snapshot omitted `worker.lock.yaml` | a contained run, recorded as contained, running pi on the host |
| the task loop read its work list from stdin and the worker ate it | `BUILD COMPLETE, 1 task verified` for a bean that was a third built |
| the verify sandbox was a flag nobody passed | the worker told its code failed, when it had never been run |
| the tamper check compared an absolute path to a relative one | the controller accused of altering its own `worker.log` |
| the claims check treated a denied-then-mentioned path as asserted | a true sentence reported as a false claim |
| `spec.attempt-1.judgement.json` matched a verdict glob | `integer expected` on stderr mid-step, reading like unrelated noise |

Four of the six were in the controller, not in anything a model did. Two were checks I had
just written, firing wrongly — the worst kind, because a containment check that accuses the
controller gets switched off and takes the real one with it.

**The lesson that keeps earning its place:** these were found by driving the whole line, and
none of them needed a model. `tests/test-full-line.sh` now does that in twenty seconds.
Write the end-to-end test before the next long real run, not after it.

### Operator actions the line expects

- **`factory read <run>`** — the one exit predicate a script cannot settle.
- **`factory policy`** — review risk-policy.yaml by what it does to each bean.
- **`failed-attempts/resolved/`** — move a step's failure records into this
  directory, with a note saying why, when the failure was caused by something
  outside the model: a killed container, a controller bug since fixed. The
  attempt limit stops counting them and the evidence stays. A delete would do the
  first and lose the second.

### Still open

- **`risk-policy.yaml` has not had a human read.** Marked `[~]` since Phase 0. It governs
  what tier a path change lands in, so a wrong rule here is a review that never happens.
- **The byte budget on audit artifacts is unset.** `spec-check.sh` counts and reports; the
  number should come from a repeat-measured size sweep, not taste. The first sweep was
  invalidated by the variance finding.
- **`OLLAMA_CONTEXT_LENGTH` is system-wide** and affects the user's other projects. Left
  alone deliberately; the contained worker sets its own context in the mounted
  `models.json` instead.
- **Hidden tests** are in the gate's design and not built.
- **Eleven figures in `bench/results/` carry no provenance block.** They were
  measured before `bench/provenance.sh` existed, and writing one in now would be
  inventing it. The cause is fixed — every harness emits one, and a new
  `harnesses_emit_provenance` check in the Phase-0 audit keeps the next one from
  skipping it — so the standing finding is about artifacts, not about code.
  Re-measure when the GPU is free; `controller-fitness.sh` needs no GPU but does
  need the target repo on `main`, which it now refuses without.
- **CI is built and waiting on one command.** The owner chose the registry, so:
  `factory/scaffold/.github/workflows/gates.yml` runs the image `gates.lock.yaml`
  pins, by digest; `factory/gate-image/publish.sh` pushes it and refuses if the
  local digest is not the pinned one; `factory/pipeline/ci.sh` is the last step and
  sends a failing check back to `build` for the tasks its logs name.

  What is left is a token scope. `podman login ghcr.io` succeeds with the current
  gh token, and the push is refused: *"the token provided does not match expected
  scopes"*. It needs an interactive refresh, which only the owner can do:

  ```
  gh auth refresh --scopes write:packages
  gh auth token | podman login ghcr.io -u beekeeper-lab --password-stdin
  factory/gate-image/publish.sh --registry ghcr.io/beekeeper-lab
  ```

  That prints the `image:` line for `gates.lock.yaml`. Put it in
  `factory/scaffold/factory/gates.lock.yaml`, re-run `factory/scaffold.sh` against
  the target repo to install the workflow, and the required check becomes real.

  **The workflow is deliberately NOT installed in seating-planner-py yet.** It
  fails loudly when the manifest still pins a `localhost/` image — which is the
  right behaviour and would put a red X on the open PR #1 for a reason that has
  nothing to do with the change. Publish first, then scaffold.

## What to re-run to confirm nothing drifted

There is no bare `python` on this box; the interpreter is the venv's. Run one per line:

```
./factory/pipeline/tests/run-all.sh
./bench/phase0-audit.sh --with-models
.venv/bin/python bench/validate.py
.venv/bin/python bench/validate.py --corpus benchmark/seating-planner/bean-sets/v1
./bench/phase0.sh --provenance-only
```

Expected: `455 assertions, 0 failed` (~64s, and it names any suite that fails);
audit `0 findings (green)`; `8 schemas, 0 invalid`; `20 bean(s) ... 0 invalid`; GTT 96 GB.

`run-all.sh` replaces naming individual suites — it discovers them, so a suite written
after this was typed is still covered. `--fast` skips the end-to-end ones. The audit's `--with-models` flag re-runs the
12-case Harmony suite (~2 min, loads the 120b) and writes
`bench/results/harmony-<stamp>.json`; without it that predicate reports as skipped.
Note that bare `validate.py` validates **no bean at all** — the `--corpus` line is the
one that checks the 20-bean set.

## Decisions recorded last session (don't re-litigate, do revisit on trigger)

**Regime = `serial`.** Not a capacity limit. The judge and the **Q4** developer *do*
co-reside at 79–81 GiB, both 100% GPU, developer to 49152 ctx. The Q8 developer + judge
needs ~88.4 GiB and ollama refuses above roughly 81.4–88.4 GiB — it withholds 8–15 GiB
beneath the 96 GiB ceiling, so raising the ceiling further would not buy the Q8 pair.
The real trade is developer quantisation vs. swap, and swap is cheap (8.0 s judge→dev,
13.2 s dev→judge) against per-stage runtimes in minutes.
**Revisit if `swap_overhead_pct` exceeds ~15%** — then the Q4 co-resident arm goes live.

**Speed inverts the size intuition.** `gpt-oss:120b` ≈ 861–1052 prompt tok/s, ~35 gen.
`qwen3.8:27b-mtp-q8_0` ≈ 325 prompt, ~20 gen. The 120B MoE judge is ~3× faster at prompt
processing than the 27B dense developer, so **the judge is not the expensive stage** —
don't design role-batching as if it were.

**Context barely affects throughput** across 16K–49K. The old 39-minute InvTrac spec step
was the 262144 default context, not model speed.

## Two live gotchas

1. **pi silently drops `--thinking` for models its catalog doesn't mark `reasoning: true`.**
   This had the judge running with reasoning *off* while `roles.json` said `"high"`, and
   `run-step.sh` would have stamped `conditions.thinking: high` into the run record anyway.
   Fixed in `~/.pi/agent/models.json` (backup: `models.json.bak-20260914-preharmony`) and
   `preflight.sh` now refuses a run that would repeat it. **If pi ever updates or rewrites
   its catalog, re-check this** — the backup and the preflight check are the two tripwires.

   The guard itself was wrong until the audit: it was wrapped in `[ -f "$PI_MODELS" ]`,
   so a pi upgrade that *moved* the catalog would have made the tripwire vanish silently
   while preflight still printed PASS. A missing catalog is now a `FAIL`; set
   `PI_MODELS_JSON` if pi relocates it.

2. **`roles.json` `num_ctx` is an intent, not a lever — pi has no flag for it.**
   `pi --help` lists no context option, so ollama serves whatever
   `OLLAMA_CONTEXT_LENGTH` (unset on the unit → 131072 default) or the last request
   set. The run record no longer pretends otherwise: `conditions.num_ctx` is read from
   `/api/ps` and the roles.json number is kept under `conditions.declared`. **The
   remaining work is control, not honesty** — to actually hold a role at 32768 the unit
   needs `OLLAMA_CONTEXT_LENGTH`, which is a single global value and cannot express a
   per-role context. Spec §09's healthcheck is where that belongs.

## Machine config as left (already applied, survives reboot)

- Kernel cmdline `ttm.pages_limit=25165824` → GTT **96 GiB** of 125 GiB RAM.
- `/etc/systemd/system/ollama.service.d/zz-factory.conf`: `MAX_LOADED_MODELS=1`, `NUM_PARALLEL=1`.
- `keepalive.conf`: `OLLAMA_KEEP_ALIVE=-1`. Temporary probe drop-in was removed.

## Evidence

`bench/results/` — `phase0-20260914T173319Z.json` (full sweep),
`coresidency-probe-20260914.json` (the seven co-residency trials),
`phase0-eviction-log-20260914.txt` (raw scheduler lines),
`provenance-post-reboot-*.json`.
