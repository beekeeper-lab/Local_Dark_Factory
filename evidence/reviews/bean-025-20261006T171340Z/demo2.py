import time
from seating_planner.domain import Event, Guest, RsvpStatus, Table
from seating_planner.rules import Hardness, Rule, RuleType
from seating_planner.solver import solve_event
T=lambda i,c: Table(id=i,name=i,capacity=c,shape="round",position=(0.0,0.0))
G=lambda i: Guest(id=i,name=i,status=RsvpStatus.CONFIRMED,reserved_seat=False)
H=lambda i,t,gs: Rule(id=i,rule_type=t,hardness=Hardness.HARD,weight=None,guest_ids=gs)
S_=lambda i,t,w,gs: Rule(id=i,rule_type=t,hardness=Hardness.SOFT,weight=w,guest_ids=gs)
def show(tag, ev, mode="event_day", **kw):
    r=solve_event(ev, mode=mode, **kw)
    rep=r.infeasibility_report
    if rep is None: print(tag, r.status, r.assignments, r.score); return
    print(tag, r.status, "rules:", rep.conflict_rule_ids, "shortfall:", rep.capacity_shortfall, "n_recs:", len(rep.recommendations))
    for x in rep.recommendations: print("   ", x.kind, "|", x.message)
# E1: no rules; three new guests locked to t-1 which has one free seat; t-2 has room.
ev=Event(id="e",name="e",tables=[T("t-1",2),T("t-2",4)],guests=[G(f"g-{i}") for i in range(4)],groups=[],rules=[],locks={"g-1":"t-1","g-2":"t-1","g-3":"t-1"})
show("E1 three locks on one free seat, no rules:", ev, current={"g-0":"t-1"})
# E2: chart overfills t-1 (3 guests at cap 2), no rules, no locks.
ev=Event(id="e",name="e",tables=[T("t-1",2),T("t-2",4)],guests=[G(f"g-{i}") for i in range(3)],groups=[],rules=[],locks={})
show("E2 chart overfills a table, no rules:", ev, current={"g-0":"t-1","g-1":"t-1","g-2":"t-1"})
# E3: run-1 D1 with an unrelated chart-satisfied hard rule present.
ev=Event(id="e",name="e",tables=[T("t-1",2),T("t-2",2)],guests=[G(f"g-{i}") for i in range(4)],groups=[],rules=[H("r-by",RuleType.SAME_TABLE,("g-0","g-1"))],locks={"g-3":"t-1"})
show("E3 lock cause + bystander hard rule:", ev, current={"g-0":"t-1","g-1":"t-1","g-2":"t-2"})
# E4: unlocked new guest (not on chart) locked to full t-1 -> lock released.
ev=Event(id="e",name="e",tables=[T("t-1",2),T("t-2",2)],guests=[G(f"g-{i}") for i in range(4)],groups=[],rules=[],locks={"g-3":"t-1"})
show("E4 unlocked off-chart locked guest:", ev, current={"g-0":"t-1","g-1":"t-1","g-2":"t-2"}, unlocked={"g-3"})
# E5: planning mode with lock/rule conflict (regression check).
ev=Event(id="e",name="e",tables=[T("t-1",2),T("t-2",2)],guests=[G(f"g-{i}") for i in range(3)],groups=[],rules=[H("r-d",RuleType.DIFFERENT_TABLE,("g-0","g-1"))],locks={"g-0":"t-1","g-1":"t-1"})
show("E5 planning lock-vs-rule:", ev, mode="planning")
show("E5b low_disruption:", ev, mode="low_disruption", current={"g-0":"t-1","g-1":"t-2","g-2":"t-2"}, movement_limit=1)
# E6: timing - 200 chart-consistent locks, 30 bystander hard rules, one new guest no seat.
n=200
tabs=[T(f"t-{k}",10) for k in range(20)]
gs=[G(f"g-{i}") for i in range(n+1)]
cur={f"g-{i}":f"t-{i%20}" for i in range(n)}
locks=dict(cur)
rules=[H(f"r-{k}",RuleType.SAME_TABLE,(f"g-{k}",f"g-{k+20}")) for k in range(30)]
ev=Event(id="e",name="e",tables=tabs,guests=gs,groups=[],rules=rules,locks=locks)
t=time.time(); r=solve_event(ev,mode="event_day",current=cur); print("E6", r.status, "shortfall", r.infeasibility_report.capacity_shortfall, "secs %.2f"%(time.time()-t))
