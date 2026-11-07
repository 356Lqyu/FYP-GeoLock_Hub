# Local graph matrices and routing orchestration

This is the **local subset of C2**, as defined in the existing Phase C approval register: graph identity and distance/time matrices. The orchestration interface exercises the existing algorithms without implementing C3 database snapshots, C4 publication or C5/C6 dispatch.

```powershell
.\.venv-stage8\Scripts\python.exe -m backend.routing.phase_c2 --output results/stage8-phase-c2-local/synthetic-demo.json
.\.venv-stage8\Scripts\python.exe -m unittest discover -s backend/routing -t . -p 'test*.py' -q
```

Uses the existing Phase B environment/OR-Tools lock. No new dependency, server, credential or database connection. The demo is entirely synthetic and grants no dispatch authority.

- `freeze_graph`: immutable canonical graph/digest; explicit provenance, coverage snapshot, supplied completeness declaration and travel-time profile; directed edge identity and finite nonnegative costs. Operational graph declarations accept DEV only. A declaration/hash is not authenticated PostgreSQL authority.
- `build_matrix`: directed shortest distance, accumulating travel time on the same selected path. Tie order is distance, time, then stable edge-ID path. Complete graph no-path is UNREACHABLE; incomplete graphs produce MISSING for **every non-diagonal arc**, including found paths, because a cropped path does not certify the full graph's shortest distance. No straight-line estimate or invented reverse edge. Unknown nodes fail. Output uses the existing Phase A matrix vocabulary.
- `prepare_input`: copies and validates the unchanged Phase A contract; optionally projects C1 vehicle rows, requires explicit observed hold facts, binds vehicle version/update metadata into source tokens, rejects foreign/invalid fleets, and excludes inactive/unavailable/incomplete/held/stale-depot vehicles. Costs/capacities/duration are explicit. No default vehicle. Server-supplied `eligible_for_planning=false` cannot be overridden. Trusted task joins, windows, service duration and mandatory policy remain required inputs, never guessed from a claim alone.
- `evaluate`: one identical FrozenScenario through FCFS, nearest neighbour, distance-only CP-SAT and proposed CP-SAT. Each output passes the existing independent validator. Invalid output aborts; infeasibility/blocked reports do not become candidates. A proposed candidate requires independent validity **and** feasibility, actual routes and correct input/matrix bindings. `dispatch_authority_issued=false` and `source_authority=LOCAL_UNTRUSTED` always.

Limits: graph work is in-memory and bounded by supplied local exports, not a production worker over the full DEV network. No live graph export has been performed. Current SQL REAL edge precision needs an approved explicit conversion policy before operational use; this implementation rejects values beyond six decimal places rather than silently rounding them. Future matrix workers need consistent read capture, complete graph/revision attestation, operational scale limits and authenticated immutable database publication. Existing C1 remains conditionally signed off for read-only evidence only.
