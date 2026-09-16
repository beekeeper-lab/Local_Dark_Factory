# Resume here — Phase 1

Phase 0 closed 2026-09-14 (tag `phase-0-complete`). Branch `factory/phase0-prep-and-bean-set-v1`.

## Read this first

Two things are waiting on you, and nothing else in this repository is blocked.

1. **Merge https://github.com/beekeeper-lab/seating-planner-py/pull/1**, or say why
   not. The two documents the line wrote are posted as comments on it; reading them
   is the review the pull request asks for. Until it lands, `factory go` has nothing
   to run — see below.
2. **`gh auth refresh --scopes write:packages`**, then the two lines under
   "CI is built and waiting on one command" in Still Open. That publishes the pinned
   gate image and makes `required_checks` real.

One more, whenever you like: `factory read <run-dir>` in the target repo records
that a human read the two rendered documents. It is the one Phase-1 exit predicate
a script cannot settle.

**What changed on 2026-09-16 that a reader should know before anything else:**
hidden tests are built and bean-001 and bean-002 have suites; the judge's response
grammar now carries the constraints that used to be prose, which produced this
line's first stamped audit verdict; and `factory reaudit` measures whether a
change to the judge does anything on a real run. The two sections that carry the
detail are *"Then three changes in an afternoon"* and *"Hidden tests"*.

## The line is blocked on one human action, and correctly

`factory go` runs the approved beans in dependency order. It ran bean-002 this
morning and stopped, because bean-001's work is in an **open pull request**, not
on `main`, and `main` is what the next bean builds against. `merge_mode:
human_required` means that is by design.

```
$ factory queue
bean-001   pr_open   Project scaffold with linting…   pull request open, not merged: …/pull/1
ready: nothing
waiting on a human to merge: bean-001
```

**Merging https://github.com/beekeeper-lab/seating-planner-py/pull/1 unblocks the
whole chain** — bean-002 becomes ready, and `factory go` will work down the
dependency order from there. Read the two documents posted as comments on it
first; that is the review the pull request asks for.

The developer model found this before the queue did: it opened bean-002's tree,
saw no `src/`, cross-checked bean-001's own spec and gate record, and stopped
rather than planning around the missing precondition
(`evidence/bean-002-worker-questions-20260916.md`).


## State: Phase 0 closed. Phase 1 is built end to end, and one real run has now finished — PR #1 is open.

**Test coverage as of 2026-09-16 evening: 1533 assertions across 36 suites, all
green, in about two minutes.** `factory/pipeline/tests/run-all.sh` runs both
directories and leaves the count where the commit-msg hook can check it — several
commit messages here have quoted a number written from memory, and each was a
small false claim in a record whose entire value is that its claims are true.
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

## Seven ways a check goes wrong, found on 2026-09-15 and 16

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

**2. Failing open.** The recurring shape, named because it keeps coming back in new
code: **a loop that skips what it cannot read reports on a subset it never names.**
`queue.sh` did `|| continue` on a bean.yaml that would not parse, so a malformed bean
vanished from the queue — twenty beans in the directory, nineteen in the queue, and the
difference visible only to someone who thought to count both. The same shape is below in
preflight's bean lookup. A skipped input needs a row saying it was skipped, or the output
is a confident answer about a question that was quietly narrowed.

`contain.py || true` swallowed exit 2 — "I could not run" —
alongside exit 1. Fixed in `gate.sh` on 2026-09-15 **and not in `build-loop.sh`,
where the same two lines sat until 2026-09-16.** The gate is the second line of
defence; the build loop is the first, and it runs once per attempt. A taxonomy
entry that names one call site is an entry that leaves the others — grep for the
pattern, not the file. The loop's startup check had a third variant: `! cmd`
treats "outside the paths" and "could not run" alike, so an unreadable pattern
list made every task look out of bounds, which is a refusal for the wrong reason
and sends the next person to edit the bean.

The original, for the record:
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

**5b. Reading a string with `jq -e` and calling it a check.** In jq only `null` and
`false` are falsy — **`""` is true.** So `jq -e '.provenance.ollama_version and ...'`
passed for a figure whose ollama_version was the empty string, and the Phase-0 audit
reported "every results JSON carries kernel + ollama version" about a field with
nothing in it. `provenance_block` fills that field from `ollama --version`, which
produces nothing on a box without ollama — the exact machine someone would re-run
these harnesses on. The same shape was in `harmony-conformance.sh`, deciding whether
the OpenAI endpoint accepts a `developer` role. **Grep for `jq -e '.field'` whenever
a check reads a string it did not write itself**; the fix is `(.field // "") != ""`.

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

**Re-measured 2026-09-16, and the verdict half changed.** Same case, same harness,
after the token cap went to 16000 and `met` was given a per-target meaning
(`judge-variance-20260916T142555Z.json`, `evidence/judge-variance-16k-met-20260916.log`):

```
revise   4 findings   confidence 0.92   382s
revise   0 findings   confidence 0.50   180s     ← a revise with nothing to revise
revise   4 findings   confidence 0.99   194s
revise   3 findings   confidence 0.85   443s
revise   1 finding    confidence 0.90   206s
```

**One verdict across five identical runs**, where the earlier run gave two. That is
the first time this judge has been reproducible on anything.

It does **not** reopen the advisory-audits decision, for three reasons stated
plainly so nobody has to reconstruct them:

1. One case. The finding above is at case level across six.
2. Three variables changed at once — cap, prompt, thinking level — so nothing here
   attributes the change to any of them.
3. **The content is still random.** Findings 4/0/4/3/1, confidence 0.5 to 0.99, and
   the seeded defect named in none of the five. A verdict that is stable while its
   reasoning is not is a coin that has landed the same way five times.

Run 2 is why `audit-check.sh` now refuses a `revise` or `block` carrying zero
findings: orchestrate routes a failed audit back into the authoring step *with the
findings*, and with none attached the step is asked the identical question again,
burns an attempt, and halts the run for a human whose only information is "the
judge said revise".

The honest next step is a repeat of the **case-level** measurement at the new cap
and prompt — `judge-fitness.sh --repeat 3`, about 75 minutes — which is what would
actually bear on the decision.

**Confirmed at case level, 2026-09-16** (`judge-fitness-20260916T001225Z.json`,
`--repeat 3`: the same six cases, three times, byte-identical input, temperature 0):

```
clean                       revise   revise   abstain     ← never once passed a clean spec
contradicts-non-goal        revise   revise   revise
criterion-not-really-met    revise   ACCEPT   revise      ← false accept on identical input
invented-current-behaviour  revise   cut off  cut off
tautological-verify         revise   revise   ACCEPT      ← false accept on identical input
unfinishable-task           revise   revise   revise

15 seeded defects: rejected 11 · NAMED the actual defect 2 · false accepts 2 · cut off 2
```

Three things, and the third is the one that decides the question:

1. **The clean control is rejected every time.** Not variance — a consistent false
   rejection. In one pass it named the defect; in three passes it has never once said a
   clean spec is clean.
2. **It rejects for the wrong reason.** 11 rejections, 2 of which named the seeded defect.
   A verdict that is right by accident is not a check.
3. **Two cases flipped to `accept` on identical input.** The same bytes, the same
   temperature, and a seeded defect passed. That is the failure the line exists to prevent,
   and it is invisible from the outside — a `revise` costs a retry, an `accept` costs
   everything after it.

A judge that rejects what is good, rejects what is bad for reasons that are not the reason,
and sometimes accepts what is bad, cannot be a gate. The advisory decision stands on
measurement, not caution.

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

## The judge has been running at the one thinking level that does not work

Measured 2026-09-16 (`format-support-20260916T111754Z.json`), under a **real 18KB
payload** rather than a short probe — the distinction the harness exists for:

```
gpt-oss:120b      thinking=low      HOLDS the schema   110s
gpt-oss:120b      thinking=medium   spends the whole budget thinking, writes nothing
gpt-oss:120b      thinking=high     spends the whole budget thinking, writes nothing
gpt-oss:20b       every level       empty content, 3s — it simply fails
gemma4:26b        thinking=false    holds — and is the measured rubber stamp
devstral:24b      —                 does not support thinking; non-JSON with it off
```

**The only eligible judge configuration on this box is `gpt-oss:120b` at
`thinking=low`, and `roles.json` says `medium`.** That is very likely most of what
"the judge produced no judgement" has meant all along: five of bean-001's audits
ended that way, and "spent the whole budget thinking and wrote nothing" is exactly
the shape.

roles.json's own note already carried the revisit condition — *"Revisit if the
judge's catch rate on bench/judge-fitness.sh is poor at medium"* — and it is poor.
A fitness run at `low`, three passes, is the comparison; `judge-fitness.sh
--thinking low` exists for it and stamps the level into the artifact.

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

- **The next judge measurement is not comparable with the ones before it.**
  `met` now carries a per-target meaning (judge.sh, 2026-09-16). Every fitness and
  variance figure taken before this asked the judge a question with an undefined
  field in it; a spec audit answering `met: false, evidence: "No source files were
  provided for analysis"` was the model reading `met` as "the code satisfies this"
  and saying, correctly, that there is no code. Re-measure before comparing.

## The judge's token cap is 16000, and that is the only number this measurement earned

`JUDGE_NUM_PREDICT` went 12000 → 16000 on 2026-09-16, in `judge.sh` and in the two
bench harnesses that record it (test-judge.sh asserts the three agree — three copies
of a number is two copies that will eventually be wrong, silently, in an artifact
nobody can check afterwards).

Everything else judge-fitness reports is a verdict, and this judge gives different
verdicts to the same question at temperature 0. So a catch rate at one cap against a
catch rate at another measures the weather. **"Was the answer truncated by the token
cap" is not a verdict** — `done_reason` says `length` or it does not — and that is the
one comparison the non-reproducibility does not poison:

```
              cut off   false accepts   named   abstained   no answer
12000, low     4 / 18         1           4         0           ?
16000, low     0 / 18         0           2         4           2
```

Only the first column is a claim. The others are in the table because leaving them
out would be picking the column that moved.

What 16000 did **not** fix: two cases still return no judgement at all
(`criterion-not-really-met`, `tautological-verify`), now with `done_reason=stop`
rather than `length`. That is a different failure, and the diagnostics added the same
day — the whole answer kept at `verdicts/<target>.unparseable.json`, with jq's own
parse error and the real `done_reason` — say which one it is next time. Both are
reported as `unmeasurable_cases`, so the run is an incomplete measurement and says so.

Evidence: `evidence/judge-fitness-low-16k-20260916.log` beside
`evidence/judge-fitness-low-20260916.log`, and
`bench/results/judge-fitness-20260916T130042Z.json`.

## Why bean-001 has no binding audit verdict, specifically

`bench/phase1-audit.sh` reports `three_verdicts_schema_valid: not_exercised` —
"6 audits ran advisory and reached none". That is true and it does not say what
happened, and what happened is now known per audit:

- **spec** produced a judgement: `accept`, and `confidence: 100` against a
  contract of 0..1. `audit-check.sh` refuses it, correctly — "certain" and
  "percent" cannot be told apart afterwards and guessing which was meant would
  invent a claim the model did not make.
- **doc** produced a judgement: `accept`, **0 findings and 0 criteria**, for a
  bean with four acceptance criteria. A judgement that reports on none of them is
  not a judgement.
- **impl, package** produced no judgement file at all. At the 12000 cap that is
  most likely the token cut-off; it could also be the unparseable-answer path,
  which until 2026-09-16 kept nothing and so cannot be told apart retrospectively.

All three causes have had work done on them since: the cap is 16000 (0 of 18 cut
off, where 12000 gave 4 of 18), `met` now says what it means per target, and the
unparseable path keeps the whole answer with `done_reason` and jq's own error.

**Run 2026-09-16** against a copy of that run directory, at the new cap with the
new prompt (`evidence/reaudit-bean-001-20260916.log`):

```
TARGET    JUDGE-RC  VERDICT   STAMPED   why not
spec      1         -         no        reasoned 20,417 chars, ended its turn without an answer
impl      1         -         no        tried to call repo_browser.open_file
doc       0         accept    no        reported on 2 of the bean's 4 criteria
package   0         accept    no        reported on 2 of the bean's 4 criteria
```

**Two of four now produce a well-formed judgement, where none did before.** That
is real progress and it is not enough: none of the four is stampable.

Three things worth keeping from it:

1. **The criteria-coverage check earned its place on day one.** doc and package
   both returned `accept` at confidence **0.99** over half the bean's criteria.
   Without that check both would have been stamped.
2. **Size is not the variable.** The largest payload is the one that worked (doc,
   36,731 bytes over 3 artifacts); the failures were 25,428 and 30,514. The
   obvious hypothesis is dead and does not need measuring.
3. **What the two failures share** is the bean and the task list — the two
   artifacts written in the imperative and addressed to a different model, which
   the preamble already warns about once, thousands of tokens earlier. The spec
   judge's reasoning trace is the evidence: it read `claims-check.json` as a
   confusing set of statements about its own task, invented a response shape
   (`{"verdict": false, "reasons": [...]}`), and finished with *"Could you clarify
   what exactly you'd like me to do?"*.

   `judge.sh` now puts a `read as:` line on each artifact header — "written in the
   imperative and addressed to a DIFFERENT model", "a measurement the controller
   already took... not a question for you" — rather than saying it once in the
   preamble.

**Measured, three passes × four targets** (`evidence/reaudit-bean-001-3pass-20260916.log`).
The `read as:` change cannot be called either way — which targets answer moves
between passes, spec going 0/1 → 3/3 and doc going 1/1 → 0/3 — and that movement
is itself the more important result.

**Twelve real audits of a real run at the best configuration this project knows,
and not one produced a verdict the controller will stamp.**

```
 6  no judgement at all   tool calls into a repo_browser namespace that does not
                          exist (×3), reasoned then stopped (×2), unparseable (×1)
 4  wrong criteria        see below
 2  revise, zero findings
```

The criteria column is the finding. What it put in `criteria`:

```
task-1, task-2                          the task list's ids
artifact-1 .. artifact-5                the numbering of the prompt's own delimiters
test_files_presented                    invented
importable-modules, module-docstrings   invented
```

One answer of six used a real id, and only one of the bean's four. The prompt has
said, in bold, *"the criteria you report on are these, and only these — using
exactly these ids"*, followed by the list, since the day the judge first invented
`C001`. The model is not defying the instruction so much as filling the field from
whatever enumerable thing is nearest, and prose cannot stop that.

**So the ids are in the grammar.** `criteria[].id` carries an enum of the bean's
ids and `minItems` is their count, built from the same jq that builds the prose
list so the two cannot drift. Constrained decoding makes `task-1` unemittable
rather than discouraged — and `bench/format-support.sh` already measured that this
model holds a schema at `low`. A re-measurement against the baseline of zero is
the next thing to do here.

**What this meant for the decision, as of that measurement**: advisory audits were
not a temporary accommodation while the judge was tuned. The audit stage did not
produce a binding verdict on this line's artifacts at all.

## OPEN and important: the grammar work improved conformance and the fitness numbers are the worst on record

`bench/judge-fitness.sh --repeat 3`, 2026-09-16 evening, on fixtures that are
actually seeding their defects for the first time
(`evidence/judge-fitness-grammar-20260916.log`):

```
of 15 seeded defects: rejected 5, NAMED the actual defect 2
false accepts 9 · abstentions 0 · no answer 1

clean                        revise ×3          ← the control, rejected every time
tautological-verify          accept ×3
contradicts-non-goal         accept ×2 revise ×1
invented-current-behaviour   accept ×1 revise ×2
unfinishable-task            accept ×2 revise ×1
criterion-not-really-met     accept ×1 none ×1 revise ×1
```

**Nine false accepts in fifteen, and the clean control rejected three times out of
three.** That is not noise around the truth, it is anti-correlated with it.

**It is not a measured regression, and saying so would be the same mistake this
project keeps writing down.** Two things changed at once: the response grammar,
and two of the six fixtures — which were not seeding the defects they claimed, so
no earlier fitness figure was measured against these cases at all. The honest
statement is that this is a **new baseline** and that every number before it is
uncomparable.

What it does say on its own terms:

- **Conformance and judgement are not the same thing.** Every case that answered
  carried all four criterion ids, in the right shape, with a valid confidence. The
  grammar work did exactly what it was measured to do and none of it is evidence
  about whether the judge is right.
- Answers are much faster — 21 to 56 seconds, against 100 to 700 before. A judge
  that used to spend minutes now answers in half a minute and accepts broken
  plans.
- **Advisory audits are more justified than before, not less.**

What would separate the two causes, and it is the obvious next work: re-run
`judge-fitness --repeat 3` with the fixed fixtures and the grammar changes backed
out one at a time. `tools: []` and the `maxLength` caps are the two candidates —
the first forces an answer where the model used to reach for a tool, the second
forces a short one. Each is ~75 minutes. `git log` has each change as its own
commit, so reverting one at a time is a `git revert` and a measurement.

**Do not take the grammar changes as settled improvements.** They are settled
improvements to *conformance*, which is what the controller needs to stamp
anything at all, and an open question about everything else.

## Then three changes in an afternoon, and they are all the same change

**The first stamped audit verdict this line has produced**:
`evidence/first-stamped-verdict-20260916.json` — an impl audit of bean-001,
`accept` at confidence 0.9, all four criteria, two quotes verified against the
artifacts, the controller's measured `test_integrity`, tier 2.

```
enum on criteria[].id    criterion compliance: 1 of 6 answers partly right
                         → 5 of 5 answers exactly right
tools: []                the field was ABSENT, not empty. The system prompt has
                         said "you have NO tools" for days; the model called
                         repo_browser.open_file 9 times out of 9. With an empty
                         list declared: 0 out of 8
maxLength on free text   `evidence` was arriving with a unified diff and a whole
                         Python module in it, or the model's own reasoning
                         followed by a nested ```json answer. It fills the field
                         with everything it would otherwise have said, runs long,
                         and the string never closes
```

**On this model a constraint in the grammar is a rule and the same constraint in
prose is a suggestion.** Three for three, against a 12-attempt baseline of zero.
That is the transferable finding; the three fixes are the illustration.

Two things made it findable rather than guessable:

- `prompt_eval_count` and `eval_count`, read off the response for the first time.
  "It stopped without finishing" was a choice between the token cap, the context
  window and the model simply stopping, and `35% of 32768 with 84 generated
  tokens` rules out two of them in one line. Every judge call logs it now, and a
  request that fills the window says which knob is not the lever.
- `verdicts/<target>.unparseable.json`, which keeps the whole answer. The
  `evidence`-contains-a-Python-module finding is unavailable without it.

And a contract that could not be satisfied: `verdict.schema.json` REQUIRES
`test_integrity` on an impl audit, and judge.sh's response schema does not contain
the field — so the judge was never asked for it and an impl verdict could never
validate. `audit-check.sh` fills it from `test-integrity.json`: the controller
measured it, the verdict is the controller's document, and the judge should never
have been asked to restate a number it was handed.

**Still true**: one stamped verdict in three passes is not a working audit stage,
and the other two refusals were right (one quoted nothing long enough to prove
anything; one quoted a `SeatingPlanner` import and a poetry dev-dependencies block
that exist in neither file — the quote check catching invented evidence, which is
what it is for). `merge_mode: human_required` still carries the weight. What has
changed is that the failures are now specific and the lever that moves them is
known.

`factory reaudit <run-dir>` is the harness for all of this: a finished run's
audits, N times, against a copy, never writing to the run.

## OPEN: the snapshot launcher died on its own last line, after succeeding

That 75-minute run finished, printed its whole summary, wrote its results file, and
then `bench/snapshot.sh` exited 2 with

```
bench/snapshot.sh: line 61: unexpected EOF while looking for matching `"'
```

on a file that is sixty lines long and passes `bash -n`. bash reads a script by byte
offset as it executes — the reason the launcher exists — and something rewrote the
bytes between the read that started the harness and the read that should have
followed it. **Nothing in that session edited this file**, and a short probe harness
does not reproduce it. Cause not identified.

The consequence is closed: everything after the harness call is now on one line, so
bash has already read it before running the first command on it and there is nothing
left to read afterwards. A successful measurement can no longer be reported as a
failed launcher. If this recurs, the thing to catch is what is writing to
`bench/snapshot.sh` — `inotifywait -m bench/snapshot.sh` during a long run.

- **`minLength` on `quote`, for the same reason as everything else in that list.**
  The quote check counts a quote only at 12 characters or more — anything shorter
  proves nothing and matches everything — and refuses a judgement where none
  qualifies. The first pass of the measurement that produced the first stamped
  verdict was refused for exactly that: quotes of 10, 14, 23 and 24 characters,
  and the ten-character one was not the problem, the *absence of a long one* was.
  A `minLength` of about 20 makes a too-short quote unemittable rather than
  refused afterwards. Measure it the same way — `factory reaudit --passes 3`.

- **Re-run `bench/size-sweep.sh` now that `tools: []` is declared.** Its standing
  finding is that at exactly 10,000 bytes of padding the judge produces no
  judgement, reproducibly, answering `{"path": "", "depth": 3}`. That is a
  file-browsing tool call leaking into content, and the same shape as the
  `repo_browser.open_file` calls that stopped when the empty tool list was
  declared. The sweep may now measure something different, or nothing at all.

- **Re-run `bench/judge-fitness.sh --repeat 3`.** Now doubly needed. Every fitness
  figure predates the enum, the empty tool list, the field length caps, the keyed
  criteria and the confidence enum — *and* two of its six fixtures were not seeding
  the defects they claimed. It is ~75 minutes and it is the case-level measurement
  the advisory-audits decision actually rests on.

- ~~**`confidence` as an enum**~~ — **done 2026-09-16.** The keyword finding stands
  and is the transferable part: the schema carried `{"minimum":0,"maximum":1}` for
  days and the judge returned **100**. llama.cpp's grammar conversion honours
  `enum` and `maxLength` and does **not** honour numeric bounds — worth knowing
  before reaching for any other numeric constraint. It is `[0, 0.1, … 1]` now, and
  one decimal place is the honest precision for a number a model produces by feel.
  **Unmeasured**; the next `factory reaudit --passes 3` says whether it took.

- **The quote is the remaining blocker, and it is the one field a JSON schema
  cannot constrain.** Of the seven answers in the keyed-criteria run, five failed
  on it: four quoting text that is on disk nowhere, one with nothing long enough
  to prove anything. No keyword says "this string must appear in that other
  string", so "put it in the grammar" does not directly apply.

  The move that would: **number the lines of every artifact in the prompt and ask
  for an artifact+line reference instead of a string**, with the controller
  resolving it and writing the real text into the judgement. An invented quote
  becomes unrepresentable, and the verdict ends up carrying actual artifact text
  rather than the model's approximation of it — which is more useful to a human
  reader, not less.

  What it costs: `quote` currently proves "a judge that read the artifact can copy
  from it". A line reference proves something weaker — the judge picked a line
  that exists. Worth doing anyway, on the evidence that the current field is
  refusing five answers in seven, but worth doing deliberately rather than at the
  end of a long session. `factory reaudit --passes 3` is how you would find out.

## The tautological-verify fixture was not seeding the defect, for the second time

`bench/controller-fitness.sh` has reported "1 of 5 seeded defects named by a
check, 4 not decidable" and closed with *"the ones marked not decidable are the
judge's actual job"*. One of those four was not.

The mutation is supposed to replace the first task's whole `verify:` block with a
check that cannot fail. It skipped the existing items with

```
while lines[i].strip().startswith("-"): i += 1
```

and the line after the first item in this task list is a **comment**. So it
skipped nothing: the mutation *prepended* one tautological verify to four real
ones, which is not a tautological task — it is the case `spec-check` documents as
legitimate ("a lint that is green on an empty directory"). The controller
correctly did not flag it, and was scored as having missed a defect that was never
seeded.

That is the second time this one mutation has been silently wrong in a different
way; the first, a regex that stopped at a `]` inside a Python string, ran for
months. Both times the number it produced looked exactly like a measurement.

Fixed by skipping on **indentation** rather than on a leading `-`, and the
mutation now **asserts its own post-condition** — the first task has exactly one
verify and it is the tautological one. A mutation that has been wrong twice does
not get a third chance to be wrong quietly.

**What it changes**: `tautological-verify` is decided by `spec-check`'s verify
precheck and always was. Controller fitness is **2 of 5 named by a check, 3 not
decidable, 0 false alarms** (`controller-fitness-20260916T171328Z.json`).

**And what it invalidates**: every `judge-fitness` figure involving this case
scored the judge against a fixture that was not the defect. That is one of six
cases in every run since the rewrite.

**A second one was wrong too**, found by applying every other mutation and reading
what came out. `contradicts-non-goal` spliced a block list item after
`write_paths:`, which in this task list is followed by an inline flow list on the
same line:

```yaml
write_paths:
  - src/seating_planner/solver/** [pyproject.toml, .gitignore]
```

One nonsense string, with the two real paths swallowed into it. Parsed and
rewritten with yaml now.

**Every mutation asserts its own post-condition**, and one assertion holds for all
of them: a non-control mutation that changed nothing is an error. Driven against a
renamed heading to prove they bite. This one fixture has been silently wrong three
times in three different ways and the assertions are the only thing that makes a
fourth different from the first three.

## Queued for an idle pipeline

- ~~**`run-step.sh`'s `audit-*` branch is dead and should go.**~~ **Done 2026-09-16.**
  Gone with everything it fed: the `TARGET` variable, the `is_audit` verdict-file
  branch that read `verdicts/<target>.attempt-N.json`, the `is_audit` exit path, and
  the four `audit-*` entries in `roles.json`'s `step_roles` (plus `implement`, which
  had outlived `factory-implement` by days). The step name is now a refusal that
  names judge.sh, and `test-role-routing.sh` asserts the refusal rather than the
  branch — the frontier-provider and absent-model refusals moved onto the developer
  role, which is what a reachable step resolves to, and test-judge.sh already held
  the same two for the judge on the path an audit actually takes.

  Found on the way out: the suite had one contained invocation, and it was calling
  the **real** `ensure-loaded.sh` — every pass put a 27b on the GPU and threw it
  away seconds later when the stub sandbox refused, on a box where a measurement
  wanted the same GPU. Now stubbed, and the stub is what proves the contained path
  preloads at all. The preload also moved to after the gateway opens: a run whose
  gateway will not open no longer pays for 64GB first.

The judge setting its own `options.num_ctx` changes what `OLLAMA_CONTEXT_LENGTH` has to
do: it no longer has to express two roles, only the developer's. These wait for no run
in flight, and the first one restarts ollama:

- ~~`zz-factory.conf`: add `OLLAMA_CONTEXT_LENGTH`~~ — **superseded 2026-09-16 and
  deliberately not done.** That is one number for every role and every other project
  on this machine, which is why it sat here unactioned. `factory/pipeline/ensure-loaded.sh`
  does it per role instead: the API takes `options.num_ctx` per request and the loaded
  instance keeps it — which is why `/api/ps` has always reported the judge at exactly
  the number judge.sh asks for — so the controller loads the developer's model at its
  declared context before the step and pi reuses what is loaded. run-step calls it for
  contained steps only.

  **Unproven in one respect**: whether pi's own request keeps the loaded context, or
  makes ollama reload at its default. The next real bean answers it —
  `conditions.declared_matches_observed` is exactly where it shows up, and that flag
  started including num_ctx this morning. If it turns out pi forces a reload, the
  global setting comes back onto this list.
- Smoke step with `--no-skills --skill "$FACTORY_SKILLS"`; if the skill loads, add
  `--no-skills` to `HARNESS_FLAGS` and demote the collision check to a regression test.
- Spike `pi --mode json` on a smoke step. If model, thinking level and tool calls arrive
  as events on stdout, `run-step.sh` reads them there and the session-directory search
  (`pi_sessions_dir()`, ~100 lines) goes; a pi update that changes the session format
  stops being a silent risk.
- ~~`handle_audit_failure` hands the re-entered authoring step the whole verdict
  file~~ — **done 2026-09-16.** `audit-findings.sh` renders the part a worker can
  act on: the verdict word, the findings, the feedback, and the criteria the audit
  says are not met. Not base_sha, candidate_sha, diff_sha256, model_digest,
  gate_manifest_digest, invariants_digest, policy_version, prompt_version or the
  artifact hashes — a worker that can see the judge's model digest can start
  theorising about the judge instead of fixing the artifact, and most of its
  25 assertions check what is absent. A verdict with no findings says so out loud
  rather than rendering a blank section, which in a prompt reads as "nothing was
  wrong".
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

**The line is blocked on one human action and it is the right one.** PR #1 is open
and unmerged, so `factory queue` reports `pr_open` and nothing is ready. Merge it
(or say why not) and `factory go` picks up bean-002, which now has hidden tests
waiting for it.

Three things the owner alone can do, each with the command:

1. **Merge** https://github.com/beekeeper-lab/seating-planner-py/pull/1
2. **Publish the gate image**, which is all that stands between the line and a
   real CI step — see "Still open".
3. **`factory read <run-dir>`** for bean-001, the one Phase-1 exit predicate a
   script cannot settle.

Then, for the next bean:

```
cd /home/gregg/workspace/seating-planner-py
/home/gregg/workspace/Local_Dark_Factory/factory/bin/factory go
```

`factory go` runs the approved beans in order and stops at the first halt.
`factory run bean-002` is one bean of it. Both snapshot the pipeline and run from
the copy, so editing the repository mid-run is safe. `factory doctor` says whether
the target is ready; it currently says ready.

Advisory audits are **still off by default and still need the flag**:

```
FACTORY_ADVISORY_AUDITS=1 factory go        # or --advisory-audits
```

The default stays strict on purpose — a default that quietly weakens a gate is
the fail-open shape this project keeps finding. What changed is that every audit
halt now says the option exists and what today's measurement says about it, so an
operator who hits one does not have to come here to learn that zero stampable
verdicts is the normal outcome rather than a surprise.

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
- **The byte budget on audit artifacts stays unset, and now for a stronger reason.**
  `spec-check.sh` counts and reports. The number was meant to come from a repeat-measured
  size sweep; the sweep has now been run three times at each of four sizes
  (`size-sweep-20260916T100658Z.json`) and **it cannot answer the question**:

  ```
  padding      0      5000    10000   20000      (bytes of real padding)
  pass 1     revise  revise   none   revise
  pass 2     revise  revise   none   revise
  pass 3     revise  revise   none   revise
  named        no      no      -       no
  ```

  Two findings, neither of them a budget:

  1. **The judge never named the defect, at any size, including none.** The case was
     chosen as "the one the judge has actually caught and named before, so a fall-off is
     legible" — and there is nothing to fall off from. A size sweep needs a baseline where
     the judge succeeds, and on three passes at zero padding there is no such point.
  2. **At exactly 10,000 bytes of padding it produces no judgement, reproducibly.** All
     three passes, and not the token cap: it answered `{"path": "", "depth": 3}` — valid
     JSON, not a judgement, the shape of a file-browsing tool call leaking into the
     content. `judge.sh` refused it and kept it beside the run, which is the only reason
     this was findable. The sweep now records *why* a point produced nothing, because
     "the judge gets worse with size" and "the judge falls out of the schema at this size"
     are different claims and the second is the more interesting one.

  A budget set from this data would be a number with nothing behind it.
- **`OLLAMA_CONTEXT_LENGTH` is system-wide** and affects the user's other projects. Left
  alone deliberately; the contained worker sets its own context in the mounted
  `models.json` instead.
- ~~**Hidden tests** are in the gate's design and not built.~~ **Built 2026-09-16.**
  `factory/pipeline/hidden-tests.sh`, wired into `gate.sh` as section 7, 34
  assertions. Configure with a `hidden_tests` block in the pipeline config:

  ```json
  "hidden_tests": {
    "dir": "/somewhere/outside/the/repo",
    "command": ["pytest", "-q"],
    "mount_at": "/hidden",
    "results_dir": "<default: a hidden-test-results dir beside dir>"
  }
  ```

  Two properties, and the second is the one that is easy to lose:

  1. **Where they live.** The worker mounts the whole tree at `/work`, so a test
     in the repo is a test it can read, and code written against visible
     assertions satisfies exactly those. A `dir` inside the repo is refused —
     twice, once here and once by `sandbox.sh --mount-ro`, which also refuses a
     target over `/work` or a system path.
  2. **What comes back.** The run directory is *also* in the repo. So the full
     output goes to `results_dir`, outside it, and `hidden-tests.json` carries
     counts only: no names, no assertions, no output. That bounds the judge too,
     whose findings reach the worker as `feedback_to_worker`.

  Exit 3 (not configured) is a note, never a pass. Exit 2 (could not run) is a
  gate FAILURE — a missing directory, an empty suite, or a sandbox refusal
  arriving as silence is the fail-open this project keeps finding.

  **bean-001 and bean-002 both have suites** (11 and 9 assertions), checked twice
  before committing: against a plausible correct implementation, where they pass,
  and against one with the constraints violated, where they bite. bean-001's
  eleven pass against what the line actually built, which it wrote without ever
  seeing them.

  **They cannot run in CI, and that is structural.** `required_checks` names checks
  GitHub reports, and a GitHub runner has only the repository — which is exactly
  where the hidden suite is not. So it is a local gate result: it appears in
  `gate.json`, in the pull request body and in the halt summary, and
  `required_checks` must not name it. A merge gated only on CI is a merge that did
  not consider them, which is why the pull request body carries the line. Putting
  them somewhere a runner could fetch would turn "the worker cannot read it" from
  a fact about the filesystem into a claim about credentials — a weaker guarantee,
  and one that should be chosen rather than arrived at.
- **Eleven figures in `bench/results/` carry no provenance block**, and
  `bench/results/INDEX.md` now says, per artifact, whether a claim still rests on
  one. That was the missing half: "eleven files lack provenance" is not
  actionable, and "these two still carry a conclusion" is.

  Of the eleven, **two** are load-bearing:
  - `judge-fitness-gemma4-20260915T025711Z.json` — the gemma4 rejection, which has
    a second independent measurement behind it (`format-support-20260916T111754Z`),
    so the decision stands on something that does say where it was measured.
  - `judge-variance-20260915T134814Z.json` — **and this is the uncomfortable one.**
    The entire "the judge is not reproducible" finding rests on it, and advisory
    audits plus `merge_mode: human_required` rest on that. Five identical runs at
    temperature 0, two verdicts. ~25 minutes of GPU to re-measure; worth doing
    precisely because the conclusion is load-bearing.

  The rest are experiments whose conclusions were superseded. They are kept, not
  deleted: a measurement records what was true, and the later work is only legible
  next to it. `controller-fitness` was re-measured 2026-09-16 (needs no GPU) —
  1 of 5 seeded defects named by a check, 4 not decidable, 0 false alarms.

  The Phase-0 audit now also checks that INDEX.md covers the directory, because a
  ledger that silently stops covering new files turns back into twenty timestamps.
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

And the phase exits — phase 1 needs a finished run to point at, phase 2 runs the
fault-injection suites and takes about two minutes:

```
./bench/phase1-audit.sh <run-dir> --repo <target-repo>
./bench/phase2-audit.sh
```

Expected as of 2026-09-16: **`1111 assertions, 0 failed`** (~115s, and it names any
suite that fails); phase-0 audit `1 finding` — the eleven figures that predate
`bench/provenance.sh`, which is an artifact finding and not a code one;
`8 schemas, 0 invalid`; `20 bean(s) ... 0 invalid`; GTT 96 GB. phase-1 on the
bean-001 run: 4 ok, 4 findings, none of them `fail`. phase-2: 13 ok, 0 findings,
with `remote_ci_failure_tests` at `pass_in_tests` until the gate image is published.

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

## Decisions recorded 2026-09-16 (same rule: don't re-litigate, do revisit on trigger)

**The judge stays advisory**, and it is not a holding position. Twelve audits of a
real run at the best configuration this project knows produced eight judgements
and zero stampable verdicts. The three grammar changes moved the failures down a
layer rather than removing them. **Revisit when a `factory reaudit --passes 3`
stamps the majority of its rows**, which has not happened once.

**`thinking: low` stands.** Two measurements agreed when it was set, and a third
on 2026-09-16 found `medium` produced *fewer* generated tokens on a real impl
audit (45–64 against 84) rather than more. Revisit only with a measurement.

**`JUDGE_NUM_PREDICT` = 16000, and it is not the lever for anything currently
failing.** The cut-offs it fixed are gone; every remaining failure sits at
35–45% of the context window with a few hundred generated tokens. Raising it
again would be changing a number that is not binding.

**Constraints on the judge go in the grammar, not the prompt.** Three for three in
one afternoon against a baseline of zero. This is the one to apply *first* next
time something in a judgement is wrong, before writing another paragraph of
instruction. Revisit if a grammar constraint ever measurably makes an answer
worse — `reaudit` is how you would find out.

## Five live gotchas

**Matching a process by pattern, the sixth time.** `reaudit.sh` printed "a bench
harness is running" when none was. `pgrep -f` matches whole command lines, so a
bare `judge-variance.sh` matched two shells that merely *mentioned* it — including
`until ! pgrep -f 'judge-variance.sh'; do sleep 30; done`, a watcher that matches
itself and therefore never exits. Both had been spinning for an hour. The pattern
is `bench/(judge-fitness|judge-variance|...)\.sh` now, specific enough that only a
real invocation matches. The rule stays: **by pid, never by pattern** — and where
a pattern is unavoidable, it has to be narrow enough that the thing looking for
the process cannot be the thing it finds.

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

3. **A run record is evidence about a version of the line that may no longer exist.**
   `factory run` copies the pipeline at launch and runs from the copy, so editing the
   repository mid-run cannot derail it — that is the point, and it has saved two runs.
   The corollary catches people reading the record afterwards: bean-001's build steps
   recorded `0s` durations, and reading that against today's code produced a confident
   wrong explanation about the contained worker. The actual cause was that the fix
   landed at 20:37 and those steps ran at 20:06, under a snapshot taken at 19:20.

   **Check `conditions.pipeline_version` in the run record before explaining anything
   about an old run.** `bench/phase1-audit.sh` does this now for step coverage —
   a step that did not exist when a run was made reports `pass_for_its_version` rather
   than failing — and it is the same question every time.

4. **Never `pkill -f` anything in this repository.** The pattern matches the shell
   that invoked it, and the command dies mid-sentence with no indication why. It has
   happened **five times** — four while chasing stray pipeline processes, once on
   2026-09-16 while cleaning up a probe — and each time the first symptom is a tool
   call returning a bare non-zero exit. `kill <pid>` only. The same rule is written
   into `model-gateway.sh`, `test-faults.sh` and `build-loop.sh`, because each of
   them had to learn it separately.

   The related one: **`pgrep -f` finds you too.** A guard looking for other
   processes matches its own wrapper shell and any subshell a command substitution
   forks. `bench/inflight.sh` excludes both the process group and the ancestor
   chain, and the comment there explains why neither alone is enough.

## Machine config as left (already applied, survives reboot)

- Kernel cmdline `ttm.pages_limit=25165824` → GTT **96 GiB** of 125 GiB RAM.
- `/etc/systemd/system/ollama.service.d/zz-factory.conf`: `MAX_LOADED_MODELS=1`, `NUM_PARALLEL=1`.
- `keepalive.conf`: `OLLAMA_KEEP_ALIVE=-1`. Temporary probe drop-in was removed.

## Evidence

`bench/results/` — `phase0-20260914T173319Z.json` (full sweep),
`coresidency-probe-20260914.json` (the seven co-residency trials),
`phase0-eviction-log-20260914.txt` (raw scheduler lines),
`provenance-post-reboot-*.json`.
