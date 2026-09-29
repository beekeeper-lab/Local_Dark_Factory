# Phase-2 audit — 2026-09-29

**Harness:** `bench/phase2-audit.sh` (runs the suites that hold each predicate and looks for the named assertions)
**Result:** **green**: 13 ok, 0 findings (`audits/phase2-audit-20260929T222621Z.json`)
**Plan:** `plans/phase-2.md`

| Predicate | Value | Evidence |
| --- | --- | --- |
| `controller_restart_tests` | pass | `tests/test-faults.sh`: kill mid-build and mid-document, then resume |
| `unauthorized_path_tests` | pass | task level and bean level; rejected, not stripped |
| `unclaimed_ac_test` | pass | refused before the judge is asked |
| `size_budget_test` | pass | `split_required`, blocked back to intake |
| `doc_mismatch_test` | pass | refused before the PR |
| `duplicate_pr_tests` | pass | an existing PR is recognised |
| `credential_exposure_tests` | pass | worker image: no ssh dir, no git identity, `.git` masked |
| `remote_ci_failure_tests` | **pass, for real** | seating-planner-py#18: the `gates` check went red on GitHub, and `ci.sh` exited 9 and rewound to build with task-1 and task-2 reopened. `evidence/phase2-real-ci-failure-20260929/` |
| `stale_branch_tests` | pass | re-gate and re-audit; the spec audit stands |
| `pr_head_violation_tests` | pass | blocked |
| `wrong_model_tests` | pass | absent model refused; digest re-asserted each step |
| `frontier_provider_refused` | pass | provider allow-list is `ollama` |
| `human_merge_required` | verified | no merge call anywhere in the line. Merges are made after pre-merge review, by Claude acting on the owner's standing authorisation |

The full unattended loop has run for real: `bean-021-20260929T165628Z` passed all 12 steps
including real CI, and 15 PRs written by the line have merged.

## Findings corrected during the phase

1. **The audit over-claimed.** `remote_ci_failure_tests` went from `pass_in_tests` to `pass`
   as soon as the gate image was published. Publishing makes a real run possible; it is not
   one. The audit now requires a recorded real failure under `evidence/`, and reports
   `pass_in_tests` without one. That path was checked by moving the evidence aside.
2. **The hidden-test verifier gave a false alarm and a false assurance** (task 3a).
   `mktemp -d` trees are 0700, and the gate image's non-root user cannot open them.
   - Every `--branch --image` check said "cannot pass".
   - Every `--image` empty-tree check "failed against nothing" without reading anything.

   Fixed. All 17 image-verified suites were re-checked, and each one genuinely fails against
   an empty tree, so no existing record changes. The verifier's own fixture had passed only
   because of the bug, and it was repaired.
