import sys, time
from seating_planner.domain import Event, Guest, RsvpStatus, Table
from seating_planner.rules import Hardness, Rule, RuleType
from seating_planner.solver import solve_event
S, D = RuleType.SAME_TABLE, RuleType.DIFFERENT_TABLE
def T(i,c): return Table(i, i, c, "round", (0.0,0.0))
def G(n): return [Guest(f"g{i}", f"g{i}", RsvpStatus.CONFIRMED) for i in range(n)]
def H(i,t,g): return Rule(id=i, rule_type=t, hardness=Hardness.HARD, weight=None, guest_ids=g)
def ev(tables, n, rules): return Event(id="e", name="e", tables=tables, guests=G(n), groups=[], rules=rules)
def solve(e, mode="planning"):
    kw = dict(current={"g0":"t1"}, movement_limit=100) if mode=="low_disruption" else {}
    return solve_event(e, mode=mode, time_limit_s=10.0, seed=0, num_search_workers=1, **kw)
def rep(e, mode="planning"):
    r = solve(e, mode); ir = r.infeasibility_report
    return r.status, ir and ir.conflict_rule_ids, ir and ir.capacity_shortfall, ir and [x.kind for x in ir.recommendations]
def drop(e, ids, cap=None):
    return Event(id=e.id, name=e.name, tables=[T(t.id, (cap or {}).get(t.id, t.capacity)) for t in e.tables],
                 guests=e.guests, groups=[], rules=[r for r in e.rules if r.id not in ids])
case = sys.argv[1]
if case == "shortage_harmless":
    # 5 guests, 4 seats, one satisfiable hard rule: pure shortage (bean-010 case)
    e = ev([T("t1",2),T("t2",2)], 5, [H("r-ok", S, ("g0","g1"))])
    for m in ("planning","low_disruption"): print(m, rep(e, m))
    print("fix = add 1 seat to t1, keep all rules:", solve(drop(e, set(), {"t1":3})).status)
    print("is r-ok part of any conflict? drop it, no extra seat:", solve(drop(e, {"r-ok"})).status)
if case == "three_conflicts":
    rules = []
    for k in range(3):
        a, b = f"g{2*k}", f"g{2*k+1}"
        rules += [H(f"s{k}", S, (a,b)), H(f"d{k}", D, (a,b))]
    e = ev([T("t1",6),T("t2",6)], 6, rules)
    for m in ("planning","low_disruption"): print(m, rep(e, m))
    st, named, *_ = rep(e)
    print("after removing named", named, ":", solve(drop(e, set(named))).status)
    print("after removing s0,s1,s2 :", solve(drop(e, {"s0","s1","s2"})).status)
if case == "shortage_group":
    # 5 guests, 2 tables of 2, hard same_table on g0..g3 (needs a table of 4)
    e = ev([T("t1",2),T("t2",2)], 5, [H("big", S, ("g0","g1","g2","g3"))])
    print(rep(e))
    st, named, sf, _ = rep(e)
    for cap in ({"t1":2+sf}, {"t2":2+sf}):
        print("named removed", named, "+", sf, "seat(s)", cap, ":", solve(drop(e, set(named), cap)).status)
if case == "perf":
    n = int(sys.argv[2]); rules = []
    for k in range(3):
        a, b = f"g{2*k}", f"g{2*k+1}"
        rules += [H(f"s{k}", S, (a,b)), H(f"d{k}", D, (a,b))]
    rules += [H(f"by{i}", D, (f"g{6+i%30}", f"g{6+(i+1)%30}")) for i in range(n)]
    e = ev([T(f"t{i}",8) for i in range(6)], 40, rules)
    t=time.time(); print(len(rules), "rules", rep(e)[:2], f"{time.time()-t:.1f}s")
