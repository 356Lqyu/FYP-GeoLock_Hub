# Offline benchmark v3.2 bridge

This reads the supplied CSVs and original standalone FCFS/Nearest-Next modules.
It does not call their `main()` functions or overwrite their result folders.
No Supabase, worker, graph-freeze or dispatch integration is included.

`proposed_settings.json` is **unapproved**. Its 20 km admission, 360 minute lease,
240 minute route, 10 minute service and zero safety margin are the supplied baseline
defaults. Fixed cost 5/trip and distance cost 1/km are their documented benchmark
cost-index constants, **not observed RM costs**. CP-SAT still minimises unserved
first, then fixed-plus-distance cost; distance-only remains a separate comparison.
Seed 42, one worker, 30 wall seconds total / 0.25 deterministic seconds per pass
reuse Stage 8 execution settings. Its legacy RoutingModel-named metadata fields
are required by the unchanged Phase A schema; execution remains CP-SAT.

## Policies requiring review

* Nonmandatory tasks; unavailable arcs forbidden individually, not scenario-wide.
* Routing windows are `[cutoff, cutoff+240 min]`, making the window redundant with
  route duration. Original baselines do not model donor availability windows.
  This comparison therefore cannot establish donor-window feasibility.
* Stage 8's existing admission requires listing expiry beyond the full horizon.
  Original baselines check expiry only at claim time. COMMON_STAGE8_ADMISSION
  explicitly removes TASK-LST000005 in scenario 0066 from **all** methods, leaving
  499 admitted tasks across 100 scenarios. Its source task and exclusion stay in
  FrozenScenario evidence. REJECT_DIFFERENCES instead blocks preparation.
* Baselines permit equality at lease expiry with a float tolerance; Stage 8 uses
  strict expiry and exact scaled integers. Required lease slack makes the lease
  boundary unreachable for these settings. Independent validation rejects any
  remaining float-boundary mismatch; it never repairs an emitted route.
* No active/available fleet flags are supplied: AVAILABLE_FLEET membership is the
  synthetic planning fleet declaration, not authenticated operational eligibility.

## Commands (repository root, existing Stage 8 Python environment)

```powershell
.venv-stage8/Scripts/python.exe -m unittest backend.routing.benchmark_v32.test_adapter -v
.venv-stage8/Scripts/python.exe -m backend.routing.benchmark_v32.runner --output results/stage8-v32-preflight.json
```

Preflight reads all scenarios and validates contracts without running a routing
method. Output paths must be new. After user review, make a separate reviewed
settings copy, set `approved` to true, and run:

```powershell
.venv-stage8/Scripts/python.exe -m backend.routing.benchmark_v32.runner --settings <reviewed-settings.json> --output results/<new-run-directory> --execute-reviewed-config
```

Do not run that command before approval. It calls the original FCFS and
Nearest-Next functions, then Stage 8 distance-only and proposed CP-SAT; both
baselines receive the same sealed shared input and every plan is also checked by
Stage 8's independent validator. Original emitted timing is preserved, not repaired
by rescheduling. Invalid output stops execution. There is no claim of optimality
without recorded CP-SAT status/bound evidence.

Each new run preserves input/source hashes, settings, solver version, full inputs,
per-method routes, validation metrics, runtime, timeout and supported objective
bounds/gaps. Semantic hashes exclude timing. Only `completion.json` certifies that
all planned evaluations finished; partial outputs are not a successful experiment.
Existing teammate baseline results are historical outputs, not paired results
under this newly proposed common admission policy.
