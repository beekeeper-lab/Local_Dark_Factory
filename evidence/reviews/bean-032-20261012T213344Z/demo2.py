import sys, time
from seating_planner.domain import Event, Guest, RsvpStatus, Table
from seating_planner.rules import Hardness, Rule, RuleType
from seating_planner.solver import solve_event
S, D = RuleType.SAME_TABLE, RuleType.DIFFERENT_TABLE
def T(i,c): return Table(i, i, c, "round", (0.0,0.0))
def G(n): return [Guest(f"g{i}", f"g{i}", RsvpStatus.CONFIRMED) for i in range(n)]
def H(i,t,g): return Rule(id=i, rule_type=t, hardness=Hardness.HARD, weight=None, guest_ids=g)
def ev(tables, n, rules): return Event(id="e", name="e", tables=tables, guests=G(n), groups=[], rules=rules)
def solve(e, mode="planning", cur=None):
    kw = dict(current=cur or {"g0":"t1"}, movement_limit=100) if mode=="low_disruption" else {}
    return solve_event(e, mode=mode, time_limit_s=10.0, seed=0, num_search_workers=1, **kw)
def rep(e, mode="planning"):
    r = solve(e, mode); ir = r.infeasibility_report
    return r.status, ir and ir.conflict_rule_ids, ir and ir.capacity_shortfall, ir and [x.kind for x in ir.recommendations]
def drop(e, ids, cap=None):
    return Event(id=e.id, name=e.name, tables=[T(t.id, (cap or {}).get(t.id, t.capacity)) for t in e.tables],
                 guests=e.guests, groups=[], rules=[r for r in e.rules if r.id not in ids])
case = sys.argv[1]
if case == "mixed":   # shortage + real conflict + harmless rule
    e = ev([T("t1",2),T("t2",2)], 5, [H("r-same",S,("g0","g1")),H("r-diff",D,("g0","g1")),H("r-ok",S,("g2","g3"))])
    for m in ("planning","low_disruption"): print(m, rep(e, m))
if case == "short2":  # shortage of 2 + conflict + harmless
    e = ev([T("t1",2),T("t2",2)], 6, [H("r-same",S,("g0","g1")),H("r-diff",D,("g0","g1")),H("r-ok",S,("g2","g3"))])
    for m in ("planning","low_disruption"): print(m, rep(e, m))
    print("drop named + 1 seat each:", solve(drop(e, set(rep(e)[1]), {"t1":3,"t2":3})).status)
if case == "spread":  # shortage of 1; where the seat goes matters
    e = ev([T("t1",3),T("t2",1)], 5, [H("A",S,("g0","g1","g2")),H("B",S,("g3","g4"))])
    for m in ("planning","low_disruption"): print(m, rep(e, m))
    print("keep ALL rules, +1 seat at t2:", solve(drop(e, set(), {"t2":2})).status)
    print("keep ALL rules, +1 seat at t1:", solve(drop(e, set(), {"t1":4})).status)
    print("drop A and B, no extra seat :", solve(drop(e, {"A","B"})).status)
if case == "spread_one":  # single group rule
    e = ev([T("t1",1),T("t2",1),T("t3",2)], 5, [H("A",S,("g0","g1","g2"))])
    print(rep(e))
    print("keep A, +1 seat at t3:", solve(drop(e, set(), {"t3":3})).status)
if case == "perf":
    n = int(sys.argv[2]); rules = [H("s0",S,("g0","g1")),H("d0",D,("g0","g1"))]
    rules += [H(f"by{i}", D, (f"g{6+i%30}", f"g{6+(i+1)%30}")) for i in range(n)]
    for short in (0,1):
        e = ev([T(f"t{i}",8 if i else 8-short) for i in range(6)], 48, rules)
        t=time.time(); r=rep(e); print(len(rules), "rules short", short, r[:3], f"{time.time()-t:.2f}s")
