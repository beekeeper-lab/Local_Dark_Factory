import time
from seating_planner.domain import Event, Guest, RsvpStatus, Table
from seating_planner.solver import solve_event
import seating_planner.solver.hard as h
T=lambda i,c: Table(id=i,name=i,capacity=c,shape="round",position=(0.0,0.0))
G=lambda i: Guest(id=i,name=i,status=RsvpStatus.CONFIRMED,reserved_seat=False)
n=0; orig=h._probe_satisfiable
def cnt(*a,**k):
    global n; n+=1; return orig(*a,**k)
h._probe_satisfiable=cnt
tabs=[T(f"t-{i}",8) for i in range(30)]  # 240 seats
cur={f"g-{i}":f"t-{i%25}" for i in range(170)}  # t-0..t-24 hold 6-7 each
locks={}
for k in range(30): locks[f"g-{170+k}"]=f"t-{k%3}"  # 10 new guests locked to each of t-0..t-2 (7 chart + 10 > 8)
ev=Event(id="e",name="e",tables=tabs,guests=[G(f"g-{i}") for i in range(200)],groups=[],rules=[],locks=locks)
t0=time.time(); r=solve_event(ev,mode="event_day",current=cur); dt=time.time()-t0
print(r.status, f"{dt:.2f}s probes={n} recs={len(r.infeasibility_report.recommendations)}", r.infeasibility_report.recommendations[:1])
