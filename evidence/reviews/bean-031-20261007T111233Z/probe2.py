import re, time
from seating_planner.domain import Event, Guest, RsvpStatus, Table
from seating_planner.solver import solve_event
T=lambda i,c: Table(id=i,name=i,capacity=c,shape="round",position=(0.0,0.0))
G=lambda i: Guest(id=i,name=i,status=RsvpStatus.CONFIRMED,reserved_seat=False)
def EV(tabs,n,locks): return Event(id="e",name="e",tables=tabs,guests=[G(f"g-{i}") for i in range(n)],groups=[],rules=[],locks=locks)
def follow(ev,recs,only=None):
    locks=dict(ev.locks); caps={t.id:t.capacity for t in ev.tables}
    for r in recs:
        if only and r.kind!=only: continue
        if r.kind=="unlock": locks.pop(re.search(r"Guest (\S+) ",r.message).group(1),None)
        if r.kind=="add_capacity":
            m=re.search(r"Table (\S+) .* add (\d+) seats",r.message); caps[m.group(1)]+=int(m.group(2))
    return Event(id="e",name="e",tables=[T(t.id,caps[t.id]) for t in ev.tables],guests=ev.guests,groups=[],rules=[],locks=locks)
def show(tag,ev,cur,unl=None,tl=10.0):
    t0=time.time(); r=solve_event(ev,mode="event_day",current=cur,unlocked=unl,time_limit_s=tl); dt=time.time()-t0
    rep=r.infeasibility_report; print(tag,r.status,f"{dt:.2f}s")
    if rep is None: return
    for x in rep.recommendations: print("   ",x.kind,"|",x.message)
    for only in ("unlock","add_capacity",None):
        print("   follow",only or "all","->",solve_event(follow(ev,rep.recommendations,only),mode="event_day",current=cur,unlocked=unl).status)
# N1 ac2 shape + 4 chart-consistent locks at t-2 (cap ample) + 1 new guest locked at roomy t-3
show("N1 ac2 + bystander locks:", EV([T("t-1",3),T("t-2",6),T("t-3",4)],12,{"g-3":"t-1","g-4":"t-1","g-5":"t-1","g-6":"t-2","g-7":"t-2","g-8":"t-2","g-9":"t-2","g-10":"t-3"}), {"g-0":"t-1","g-1":"t-1","g-2":"t-2","g-6":"t-2","g-7":"t-2","g-8":"t-2","g-9":"t-2"})
print("N1 drop only g-3,g-4:", solve_event(EV([T("t-1",3),T("t-2",6),T("t-3",4)],12,{"g-5":"t-1","g-6":"t-2","g-7":"t-2","g-8":"t-2","g-9":"t-2","g-10":"t-3"}),mode="event_day",current={"g-0":"t-1","g-1":"t-1","g-2":"t-2","g-6":"t-2","g-7":"t-2","g-8":"t-2","g-9":"t-2"}).status)
# N2 mixed: chart overfills t-1 AND a lock contradicts the chart
show("N2 chart overfill + contradicting lock:", EV([T("t-1",2),T("t-2",3),T("t-3",3)],5,{"g-3":"t-3"}), {"g-0":"t-1","g-1":"t-1","g-2":"t-1","g-3":"t-2"})
# N3 mixed, contradicting lock to a 1-seat table holding a chart guest
show("N3 overfill + contradiction into full table:", EV([T("t-1",2),T("t-2",3),T("t-3",1),T("t-4",3)],6,{"g-3":"t-3"}), {"g-0":"t-1","g-1":"t-1","g-2":"t-1","g-3":"t-2","g-4":"t-3"})
# N4 several tables chart-overfilled + locks; unlocked chart guest
show("N4 two overfull charts + unlocked:", EV([T("t-1",2),T("t-2",2),T("t-3",6)],8,{"g-6":"t-1"}), {"g-0":"t-1","g-1":"t-1","g-2":"t-1","g-3":"t-2","g-4":"t-2","g-5":"t-2"}, unl={"g-2"})
