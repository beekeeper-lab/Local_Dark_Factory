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

The spec cost two attempts, and the first failure was the controller's fault:
doclint reported a three-thousand-character section as empty because it treated
any heading as the end of a section. The model said so in its own retry report
and was right. See the commit "doclint called a 3000-character section empty, and
the model was right".
