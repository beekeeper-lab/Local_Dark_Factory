from seating_planner.domain import Event, Guest, RsvpStatus, Table
from seating_planner.solver import solve_event
T=lambda i,c: Table(id=i,name=i,capacity=c,shape="round",position=(0.0,0.0))
G=lambda i: Guest(id=i,name=i,status=RsvpStatus.CONFIRMED,reserved_seat=False)
def EV(tabs,n,locks): return Event(id="e",name="e",tables=tabs,guests=[G(f"g-{i}") for i in range(n)],groups=[],rules=[],locks=locks)
print("N3 follow unlock + t-1 seat only (no t-3 seat):", solve_event(EV([T("t-1",3),T("t-2",3),T("t-3",1),T("t-4",3)],6,{}),mode="event_day",current={"g-0":"t-1","g-1":"t-1","g-2":"t-1","g-3":"t-2","g-4":"t-3"}).status)
for tl in (1e-9,1e-4):
    r=solve_event(EV([T("t-1",3),T("t-2",3)],6,{"g-3":"t-1","g-4":"t-1","g-5":"t-1"}),mode="event_day",current={"g-0":"t-1","g-1":"t-1","g-2":"t-2"},time_limit_s=tl)
    print("ac2 shape tl",tl,r.status,r.infeasibility_report and r.infeasibility_report.recommendations)
