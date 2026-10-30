# Rebuild timing comparison — generated 2026-10-30T04:59:49+00:00

v1 = seating-planner-py (original build, finished). v2 = seating-planner-py-v2 
(rebuild in progress, same bean set v1 current state, same hidden tests).
Per-bean total is the sum of step durations across every attempt in that bean's
final (or current, for v2) run directory — i.e. what the bean actually cost,
retries included. 'state' is run.json's own status and can show a stale
transient halt (e.g. a CI flake) for a bean that was actually merged later out
of band via `factory reconcile`, which updates beanstate, not the old run.json;
see `factory state <bean>` for the authoritative status.

| bean | v1 state | v1 total (min) | v2 state | v2 total (min) | delta (min) | delta (%) |
|---|---|---|---|---|---|---|
| bean-001 | completed | 154.4 | halted@ci | 50.7 | -103.7 | -67% |
| bean-002 | halted@ci | 281.5 | completed | 94.4 | -187.1 | -66% |
| bean-003 | halted@ci | 183.2 | completed | 122.1 | -61.1 | -33% |
| bean-004 | completed | 187.5 | completed | 110.9 | -76.6 | -41% |
| bean-005 | completed | 128.6 | completed | 164.2 | +35.6 | +28% |
| bean-006 | completed | 240.5 | completed | 162.5 | -78.0 | -32% |
| bean-007 | completed | 140.3 | completed | 116.5 | -23.7 | -17% |
| bean-008 | completed | 146.6 | completed | 438.2 | +291.5 | +199% |
| bean-009 | completed | 101.0 | completed | 88.2 | -12.8 | -13% |
| bean-010 | completed | 185.5 | halted@ci | 185.1 | -0.4 | -0% |
| bean-011 | completed | 196.8 | halted@ci | 168.4 | -28.4 | -14% |
| bean-012 | completed | 160.8 | halted@ci | 176.4 | +15.6 | +10% |
| bean-013 | completed | 153.9 | halted@ci | 169.7 | +15.8 | +10% |
| bean-014 | completed | 139.2 | halted@ci | 185.5 | +46.4 | +33% |
| bean-015 | completed | 454.3 | not started | — | — | — |
| bean-016 | completed | 137.5 | not started | — | — | — |
| bean-017 | completed | 109.8 | not started | — | — | — |
| bean-018 | completed | 123.4 | not started | — | — | — |
| bean-019 | completed | 233.2 | not started | — | — | — |
| bean-020 | completed | 141.4 | not started | — | — | — |
| bean-021 | completed | 79.9 | not started | — | — | — |
| bean-022 | completed | 77.3 | not started | — | — | — |
| bean-023 | completed | 102.5 | not started | — | — | — |
| bean-024 | completed | 122.5 | not started | — | — | — |
| bean-025 | completed | 126.2 | not started | — | — | — |
| bean-026 | completed | 99.2 | not started | — | — | — |
| bean-027 | completed | 75.7 | not started | — | — | — |
| bean-029 | completed | 107.9 | not started | — | — | — |
| bean-030 | completed | 408.4 | not started | — | — | — |
| bean-031 | completed | 167.4 | not started | — | — | — |
| bean-032 | completed | 287.5 | not started | — | — | — |
| bean-033 | completed | 2027.0 | not started | — | — | — |

**v1 total (all 32 beans): 121.3 hours**
**v2 total so far (14 beans with at least one run): 37.2 hours**

## Per-step totals, beans v2 has run so far (minutes)

| step | v1 (same beans) | v2 | delta |
|---|---|---|---|
| spec | 799.5 | 1238.7 | +439.2 |
| build | 536.9 | 412.9 | -124.0 |
| gate | 3.6 | 2.9 | -0.6 |
| audit-spec | 93.6 | 52.5 | -41.2 |
| audit-impl | 97.5 | 48.8 | -48.7 |
| audit-doc | 148.0 | 27.0 | -121.0 |
| audit-package | 37.7 | 18.9 | -18.7 |
| doc | 673.5 | 427.9 | -245.7 |
| ci | 9.4 | 3.3 | -6.2 |
