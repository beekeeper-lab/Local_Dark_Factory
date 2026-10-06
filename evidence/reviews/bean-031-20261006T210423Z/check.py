from seating_planner.domain import Event, Guest, RsvpStatus, Table
from seating_planner.solver import solve_event
T=lambda i,c: Table(id=i,name=i,capacity=c,shape="round",position=(0.0,0.0))
G=lambda i: Guest(id=i,name=i,status=RsvpStatus.CONFIRMED,reserved_seat=False)
EV=lambda tabs,n,locks: Event(id="e",name="e",tables=tabs,guests=[G(f"g-{i}") for i in range(n)],groups=[],rules=[],locks=locks)
print("P1 follow advice (drop g-3 lock):", solve_event(EV([T("t-1",2),T("t-2",4)],4,{}),mode="event_day",current={"g-0":"t-1","g-1":"t-1","g-2":"t-1"}).status)
print("P2 follow add_capacity (t-2 cap 5):", solve_event(EV([T("t-1",2),T("t-2",5),T("t-3",2)],2,{"g-0":"t-2","g-1":"t-2"}),mode="event_day",current={"g-0":"t-1","g-1":"t-1"}).status)
print("P3 follow only the unlock advice, no capacity added:", solve_event(EV([T("t-1",2),T("t-2",4),T("t-3",4)],5,{}),mode="event_day",current={"g-0":"t-1","g-1":"t-1","g-2":"t-1","g-3":"t-2","g-4":"t-2"},unlocked={"g-2"}).status)
