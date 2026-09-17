# pad-neutral — the control for the size finding

`bench/size-sweep.sh` pads a spec to a target size and asks whether the judge
still catches a seeded defect. It padded with the other beans of the corpus, and
that padding is **not neutral for the defect being seeded**.

The seeded case is `contradicts-non-goal`: the spec plans an OR-Tools CP-SAT stub
at `src/seating_planner/solver/cpsat.py`, which bean-001's non-goals forbid.
Seventeen of the twenty beans mention the solver, and **bean-006 — "CP-SAT table
assignment satisfying hard constraints" — owns `src/seating_planner/solver/**`**.

So padding put a bean that owns the path the defect writes, on exactly the
defect's subject, into the same prompt, next to a spec saying the stub is there
"so later beans have somewhere to build from". A judge calling that legitimate
groundwork has not been diluted by volume. It has been told.

These are the same nineteen beans with the domain vocabulary substituted:

    solver -> exporter        CP-SAT  -> CSV-BATCH
    ortools -> chardet        optimization -> serialisation
    seating -> shelving       seating_planner -> shelving_planner

Zero mentions of the solver, the same schema, the same shape, and within 1% of
the same bytes. Nothing else differs, so a difference in the result is the
padding's CONTENT and not its size.

**Do not "fix" these to match the corpus.** They are a control: their whole value
is that they are the corpus with one property removed.

## It is padding, not a bean set, and does not validate as one

`validate.py --corpus` reports one failure here: bean-002 declares
`dependencies: [bean-001]` and bean-001 is not in this directory.

That is correct and must stay. The real padding excludes the bean under test too
— `size-sweep.sh` skips it so a spec is never padded with its own bean — so the
corpus padding has exactly the same dangling dependency. **Adding bean-001 back
to make the validator happy would make the control differ from the treatment in a
second way, which is the entire mistake this directory exists to correct.**

Nineteen beans, as the real padding is nineteen beans.
