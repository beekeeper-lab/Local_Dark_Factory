from seating_planner.domain import Event, Guest, RsvpStatus, Table
from seating_planner.rules import Hardness, Rule, RuleType
from seating_planner.solver import solve_event
T=lambda i,c: Table(id=i,name=i,capacity=c,shape="round",position=(0.0,0.0))
G=lambda i: Guest(id=i,name=i,status=RsvpStatus.CONFIRMED,reserved_seat=False)
H=lambda i,t,gs: Rule(id=i,rule_type=t,hardness=Hardness.HARD,weight=None,guest_ids=gs)
def EV(tabs,n,locks,rules=(),extra=()):
    return Event(id="e",name="e",tables=tabs,guests=[G(f"g-{i}") for i in range(n)]+[G(x) for x in extra],groups=[],rules=list(rules),locks=locks)
def show(tag, ev, mode="event_day", **kw):
    try: r=solve_event(ev, mode=mode, **kw)
    except Exception as e: print(tag, "EXC", e); return
    rep=r.infeasibility_report
    if rep is None: print(tag, r.status); return
    print(tag, r.status, "rules:", rep.conflict_rule_ids, "short:", rep.capacity_shortfall, "n_recs:", len(rep.recommendations))
    for x in rep.recommendations: print("   ", x.kind, "|", x.message)
# P1 chart overfills t-1 AND a new guest is locked there (ac3 shape + one lock)
show("P1 chart 3@cap2 + new lock:", EV([T("t-1",2),T("t-2",4)],4,{"g-3":"t-1"}), current={"g-0":"t-1","g-1":"t-1","g-2":"t-1"})
# P2 two chart guests at t-1 locked to empty one-seat t-2
show("P2 two chart-contradicting locks to t-2:", EV([T("t-1",2),T("t-2",1),T("t-3",2)],2,{"g-0":"t-2","g-1":"t-2"}), current={"g-0":"t-1","g-1":"t-1"})
# P3 unlocked chart guest counted as pinned: t-1 chart 3@cap2 but g-2 released; two contradictions elsewhere make it infeasible
show("P3 unlocked chart guest + 2 contradictions:", EV([T("t-1",2),T("t-2",4),T("t-3",4)],5,{"g-3":"t-3","g-4":"t-3"}), current={"g-0":"t-1","g-1":"t-1","g-2":"t-1","g-3":"t-2","g-4":"t-2"}, unlocked={"g-2"})
# P4 locks overfill two tables
show("P4 locks overfill t-1 and t-2:", EV([T("t-1",1),T("t-2",1),T("t-3",6)],6,{"g-2":"t-1","g-3":"t-1","g-4":"t-2","g-5":"t-2"}), current={"g-0":"t-1","g-1":"t-2"})
# P5 hard rule present plus lock overfill
show("P5 bystander hard rule + lock overfill:", EV([T("t-1",3),T("t-2",3)],6,{"g-3":"t-1","g-4":"t-1","g-5":"t-1"},rules=[H("r",RuleType.SAME_TABLE,("g-0","g-1"))]), current={"g-0":"t-1","g-1":"t-1","g-2":"t-2"})
# P6 no tables
show("P6 no tables:", EV([],2,{}), current={})
# P7 ac2-style lock overfill where 2 of 3 unlocks suffice ("needed" wording)
show("P7 ac2 scenario:", EV([T("t-1",3),T("t-2",3)],6,{"g-3":"t-1","g-4":"t-1","g-5":"t-1"}), current={"g-0":"t-1","g-1":"t-1","g-2":"t-2"})
# P8 single-fix cases main already advised (regression)
show("P8a single lock fix:", EV([T("t-1",2),T("t-2",2)],4,{"g-3":"t-1"}), current={"g-0":"t-1","g-1":"t-1","g-2":"t-2"})
show("P8b shortfall:", EV([T("t-1",2),T("t-2",1)],4,{}), current={"g-0":"t-1","g-1":"t-1","g-2":"t-2"})
show("P8c rule fix:", EV([T("t-1",2),T("t-2",2)],4,{},rules=[H("r",RuleType.DIFFERENT_TABLE,("g-2","g-3"))]), current={"g-0":"t-1","g-1":"t-1","g-2":"t-2"})
show("P8d joint rules:", EV([T("t-1",2),T("t-2",2)],3,{},rules=[H("a",RuleType.DIFFERENT_TABLE,("g-0","g-1")),H("b",RuleType.DIFFERENT_TABLE,("g-1","g-2")),H("c",RuleType.DIFFERENT_TABLE,("g-0","g-2"))]), current={})
show("P8e planning:", EV([T("t-1",2),T("t-2",2)],3,{"g-0":"t-1","g-1":"t-1"},rules=[H("r",RuleType.DIFFERENT_TABLE,("g-0","g-1"))]), mode="planning")
# P9 unlocked locked guest off-chart with lock overfill
show("P9 unlocked off-chart + overfill:", EV([T("t-1",1),T("t-2",4)],4,{"g-1":"t-1","g-2":"t-1","g-3":"t-1"}), current={"g-0":"t-1"}, unlocked={"g-3"})
