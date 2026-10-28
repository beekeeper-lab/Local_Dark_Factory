# Rebuild timing comparison — generated 2026-10-28T04:46:00+00:00

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
| bean-005 | completed | 128.6 | not started | — | — | — |
| bean-006 | completed | 240.5 | not started | — | — | — |
| bean-007 | completed | 140.3 | not started | — | — | — |
| bean-008 | completed | 146.6 | not started | — | — | — |
| bean-009 | completed | 101.0 | not started | — | — | — |
| bean-010 | completed | 185.5 | not started | — | — | — |
| bean-011 | completed | 196.8 | not started | — | — | — |
| bean-012 | completed | 160.8 | not started | — | — | — |
| bean-013 | completed | 153.9 | not started | — | — | — |
| bean-014 | completed | 139.2 | not started | — | — | — |
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
**v2 total so far (4 beans with at least one run): 6.3 hours**

## Per-step totals, beans v2 has run so far (minutes)

| step | v1 (same beans) | v2 | delta |
|---|---|---|---|
| spec | 176.6 | 168.3 | -8.3 |
| build | 127.5 | 64.4 | -63.1 |
| gate | 0.8 | 0.8 | -0.1 |
| audit-spec | 26.3 | 15.3 | -11.0 |
| audit-impl | 20.4 | 20.6 | +0.2 |
| audit-doc | 90.8 | 3.8 | -87.0 |
| audit-package | 19.4 | 5.2 | -14.2 |
| doc | 342.6 | 99.2 | -243.4 |
| ci | 2.1 | 0.6 | -1.6 |
