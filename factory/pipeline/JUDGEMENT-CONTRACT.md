# What the judge writes, and what the controller writes

`schemas/verdict.schema.json` requires fifteen fields. Ten of them are facts the
controller already knows and the judge could only guess at: `base_sha`,
`candidate_sha`, `diff_sha256`, `gate_run_id`, `gate_manifest_digest`,
`invariants_digest`, `policy_version`, `effective_risk_tier`, `model_digest`,
`prompt_version`.

Asking a model to fill those in produces a verdict whose provenance is invented.
It would look identical to a real one — a plausible hex string is indistinguishable
from a true one — and it would be *worse* than a verdict with the fields missing,
because it carries a claim nobody made. This repository has already been burned
once by exactly that shape of thing: `conditions.thinking` was stamped from
`roles.json` while the model ran with reasoning off, and the record asserted a
setting the run never used.

So the split is the same as it is for conditions:

**The judge writes a judgement.** Its own opinion, with the evidence for it, and
nothing it cannot see:

```json
{
  "schema_version": "judgement/1.0.0",
  "stage": "spec_audit",
  "target": "spec",
  "verdict": "accept | revise | block",
  "criteria": [
    { "id": "ac1", "met": true, "evidence": "tests/test_scaffold.py::test_package_imports names the import the criterion describes; it fails on the current tree because the package does not exist yet." }
  ],
  "findings": [
    { "severity": "blocker | major | minor",
      "summary": "one sentence",
      "evidence": "a command's output, a quote, or a file:line that proves it",
      "where": "path or section" }
  ],
  "feedback_to_worker": "what to change, addressed to the model that will do it",
  "suggested_tier": 1,
  "suggested_human_review": false,
  "confidence": 0.8,
  "document_quality": {
    "risk_called_out": true, "blast_radius_called_out": true,
    "code_blocks_teach": true, "no_assumed_stack_knowledge": true,
    "matches_diff": true
  },
  "test_integrity": { "deleted_tests": 0, "new_skips": 0, "weakened_asserts": false },
  "security_findings": []
}
```

Written to `<run-dir>/verdicts/<target>.attempt-<n>.judgement.json`.

**The controller writes the verdict.** `audit-check.sh` takes that judgement,
stamps every provenance field from what it can observe — the SHAs from git, the
digests from the manifest and the invariants file, the tier from `tier.py`, the
model digest from ollama, the prompt version from the skill's own content hash —
validates the result against `verdict.schema.json`, and writes
`<run-dir>/verdicts/<target>.attempt-<n>.json`. That file is the verdict. The
judgement beside it is the evidence of what the judge alone said.

## Rules that survive from the fork, because each was written after a real failure

- **No evidence, no finding.** Every finding carries a command's output, a quote,
  or a file:line. A vague finding costs a retry and is worse than a PASS.
- **A `blocker` forces `block` or `revise`, never `accept`.** A verdict of
  `accept` with a blocker in it is self-contradicting and the controller rejects it.
- **The file name comes from the target.** `impl` → `impl.attempt-1.json`, never
  `audit-impl.attempt-1.json`. A verdict under another spelling is invisible to the
  driver: a passed audit then looks exactly like a missing one, and the run halts
  on a phantom failure. That happened, to a real run, and cost a day.
- **Fresh context is the point.** The judge did not see the work being produced.
  If it finds itself assuming "they must have meant X", the assumption is wrong —
  it cannot know.
