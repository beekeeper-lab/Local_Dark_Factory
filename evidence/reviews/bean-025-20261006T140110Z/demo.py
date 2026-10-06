from seating_planner.domain import Event, Guest, RsvpStatus, Table
from seating_planner.solver import solve_event
T=lambda i,c: Table(id=i,name=i,capacity=c,shape="round",position=(0.0,0.0))
G=lambda i: Guest(id=i,name=i,status=RsvpStatus.CONFIRMED,reserved_seat=False)
def show(tag, ev, cur, **kw):
    r=solve_event(ev, mode="event_day", current=cur, **kw)
    rep=r.infeasibility_report
    print(tag, r.status, "rules:", rep.conflict_rule_ids, "shortfall:", rep.capacity_shortfall, "hard rules in event:", len(ev.rules))
    for x in rep.recommendations: print("   ", x.kind, "|", x.message)
# D1: new guest g-3 explicitly locked to full t-1; free seat exists at t-2. No rules.
ev=Event(id="e",name="e",tables=[T("t-1",2),T("t-2",2)],guests=[G(f"g-{i}") for i in range(4)],groups=[],rules=[],locks={"g-3":"t-1"})
show("D1 new guest locked to full table:", ev, {"g-0":"t-1","g-1":"t-1","g-2":"t-2"})
# D2: chart guest g-2 locked to t-2 but sits at t-1 on the chart, not unlocked.
ev=Event(id="e",name="e",tables=[T("t-1",2),T("t-2",2)],guests=[G(f"g-{i}") for i in range(3)],groups=[],rules=[],locks={"g-2":"t-2"})
show("D2 lock contradicts chart pin:", ev, {"g-0":"t-1","g-2":"t-1"})
