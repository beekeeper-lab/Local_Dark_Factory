# Rebuild timing comparison — generated 2026-11-11T11:27:17+00:00

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
| bean-015 | completed | 454.3 | halted@ci | 169.9 | -284.3 | -63% |
| bean-016 | completed | 137.5 | halted@ci | 320.4 | +182.9 | +133% |
| bean-017 | completed | 109.8 | halted@ci | 120.2 | +10.4 | +10% |
| bean-018 | completed | 123.4 | halted@ci | 98.2 | -25.1 | -20% |
| bean-019 | completed | 233.2 | halted@ci | 178.6 | -54.7 | -23% |
| bean-020 | completed | 141.4 | halted@ci | 118.2 | -23.2 | -16% |
| bean-021 | completed | 79.9 | halted@ci | 70.8 | -9.1 | -11% |
| bean-022 | completed | 77.3 | halted@ci | 80.5 | +3.2 | +4% |
| bean-023 | completed | 102.5 | halted@ci | 62.2 | -40.3 | -39% |
| bean-024 | completed | 122.5 | halted@ci | 81.1 | -41.4 | -34% |
| bean-025 | completed | 126.2 | halted@ci | 159.6 | +33.4 | +26% |
| bean-026 | completed | 99.2 | halted@ci | 113.4 | +14.2 | +14% |
| bean-027 | completed | 75.7 | halted@ci | 203.8 | +128.1 | +169% |
| bean-029 | completed | 107.9 | halted@ci | 65.6 | -42.4 | -39% |
| bean-030 | completed | 408.4 | halted@ci | 259.9 | -148.5 | -36% |
| bean-031 | completed | 167.4 | not started | — | — | — |
| bean-032 | completed | 287.5 | not started | — | — | — |
| bean-033 | completed | 2027.0 | not started | — | — | — |

**v1 total (all 32 beans): 121.3 hours**
**v2 total so far (29 beans with at least one run): 72.3 hours**

## Per-step totals, beans v2 has run so far (minutes)

| step | v1 (same beans) | v2 | delta |
|---|---|---|---|
| spec | 1732.1 | 2349.0 | +616.8 |
| build | 1318.2 | 845.5 | -472.7 |
| gate | 18.2 | 7.6 | -10.6 |
| audit-spec | 146.3 | 108.2 | -38.2 |
| audit-impl | 142.2 | 103.3 | -38.9 |
| audit-doc | 204.9 | 80.3 | -124.6 |
| audit-package | 61.0 | 40.7 | -20.2 |
| doc | 1144.2 | 788.1 | -356.1 |
| ci | 31.8 | 12.6 | -19.2 |
