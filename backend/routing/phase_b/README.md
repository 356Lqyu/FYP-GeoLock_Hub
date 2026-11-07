# Offline Routing Algorithms and Independent Validation

The active `proposed` method uses CP-SAT's two-stage lexicographic objective:
maximize the number of served pickup tasks, then minimize total directed road km
with that pickup-task count fixed. Every direct pickup and every indivisible hub
batch is one pickup task; batch member count does not increase objective value.
The RoutingModel implementation remains available as `routing_model_proposed`
for comparison, but is not the active proposed candidate method.

Phase B adds four offline methods without changing the Phase A v1 contract,
fixtures or 54 tests. It contains no Supabase client, SQL execution, live fleet
defaults, ownership changes, HTTP service or dispatch authorisation.

## Execution

The tested environment is Python 3.12.14 on Windows with OR-Tools 9.15.6755.
Use Python 3.12 for the supplied Windows dependency lock. The user's default
Python 3.14 is not the tested environment. The existing isolated .venv-stage8
environment is ready to run from the repository root:

```powershell
.\.venv-stage8\Scripts\python.exe -m unittest discover -s backend/routing -t . -p 'test*.py' -v
.\.venv-stage8\Scripts\python.exe -m backend.routing.generate_examples --check
.\.venv-stage8\Scripts\python.exe -m backend.routing.phase_b.benchmark --output results/stage8-phase-b --repeats 3
```

For a fresh environment, use a Python 3.12 executable. In this Codex workspace:

```powershell
$phaseBPython = 'C:\Users\User\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
& $phaseBPython -m venv .venv-stage8
.\.venv-stage8\Scripts\python.exe -m pip install -r backend/routing/phase_b/requirements-lock.txt
```

Dependency download is setup only; all algorithms, tests and benchmarks run
offline thereafter. requirements.txt pins the solver; requirements-lock.txt pins
the tested transitive environment. Other platforms must record and verify their
own environment before claiming byte-identical solver replay.

The combined unittest command needs `-t .` so relative package imports resolve.
The original Phase A test command also still works unchanged. Phase B tests alone:

```powershell
.\.venv-stage8\Scripts\python.exe -m unittest discover -s backend/routing/phase_b/tests -v
```

## Methods

| API | Policy |
|---|---|
| fcfs(snapshot, config) | Fixed ascending vehicle ID; tasks ordered by actual creation instant then task ID. Append the earliest feasible task, deferring currently infeasible tasks. |
| nearest_neighbour(snapshot, config) | Same vehicle order; shortest available directed next distance, task ID tie; append only a feasible next pickup. |
| distance_only(snapshot, config) | OR-Tools CP-SAT: maximize served pickup tasks, freeze coverage, then minimize total directed road km. |
| proposed(snapshot, config) | Active CP-SAT method with the same strict pickup-task-count-first, directed-distance-second objective. |

All four receive the same FrozenScenario and ExecutionConfig; methods do not
rewrite the input, regroup original donations, change selected hubs or simulate
new claims. The proposed method optimizes the already-aggregated/direct task set.
Actual creation instants, not lexical timestamp strings, determine FCFS order.

At most one trip per available vehicle; departure at the frozen cutoff; return
to the NGO depot; pickup loads accumulate; no reload, split pickup, drop-off or
intermediate depot reset. Both heuristics check immediate depot return after each
candidate extension. They do not backtrack, reserve space for future urgent tasks
or prove global infeasibility. Remaining tasks retain the last failed-extension
reason; that reason is not a global mathematical impossibility certificate.

## Objectives and solver

For admitted tasks, mandatory tasks are hard constraints in both optimizer models.
Subject to those constraints:

1. Maximize the number of served eligible pickup tasks. Each direct donation task
   and each whole hub-batch task contributes exactly one unit.
2. Fix the achieved pickup-task count and minimize total directed road km across
   all vehicle routes, including depot departure and return.

Vehicle fixed-cost and distance-rate weights are retained in `ExecutionConfig`
for compatibility with historical experiments; they do not affect the active
CP-SAT lexicographic objective.

The historical cost-weight fields remain accepted for report/configuration
compatibility, but changing them does not change either active CP-SAT objective.
The separately exposed `routing_model_proposed` legacy comparison still uses
its historical cost model.

```powershell
.\.venv-stage8\Scripts\python.exe -m backend.routing.phase_b.benchmark --output results/stage8-phase-b-distance-weighted --fixed-cost-weight 0 --distance-cost-weight 1
```

The retained CLI options do not change the active proposed result. The formal
FYP wording says donations; this implementation explicitly counts pickup tasks,
so thesis language must be aligned before claiming those are equivalent.

CP-SAT, from Google OR-Tools, performs all optimization search. The Python model
uses optional-node circuit constraints, single assignment, cumulative pickup
capacity, conditional service-time progression, windows, return duration and
forbidden arcs. There is no handwritten VRP search or route-enumeration optimizer.
No finite penalty trades away primary coverage for cheaper travel.

CP-SAT was selected over the heuristic RoutingModel search to obtain explicit
proof status and bounds for these small offline cases. The Phase A frozen solver
fields first_solution=PATH_CHEAPEST_ARC and local_search=GUIDED_LOCAL_SEARCH are
RoutingModel-specific; CP-SAT does not apply them. They remain unchanged in the
input and are explicitly identified as unused in the execution manifest. The
actual engine/version, single worker, seed, deterministic-work budget and limits
are recorded separately. A declared solver version other than the preserved
NOT_INSTALLED_PHASE_A placeholder must match the installed version exactly.

Sorted task/vehicle/model construction plus one worker and fixed seed give stable
replay on the pinned environment. CP-SAT tie selection is engine-defined: it is
not a promise of the lexicographically smallest equally optimal tour. Heuristic
ties explicitly use IDs. The runner rejects unequal repeated non-timing results.
Wall timings and a wall-limit-terminated incumbent are not portable determinism
guarantees. Broader solver deployment requires an approved execution contract.

Each pass uses at most half the input wall-time budget and the explicit
deterministic-work budget (default .25 deterministic seconds per pass). Model
construction and extraction are included in method runtime but outside the solver
search budget. `timeout` denotes budget-limited search, not exclusively wall time.
First-pass FEASIBLE fixes its incumbent pickup-task count and still runs the
distance pass. A feasible incumbent is reported `FEASIBLE_UNPROVEN` unless both
coverage and fixed-coverage distance stages are OPTIMAL. Stage-two timeout keeps
the first-stage feasible plan when no secondary incumbent exists. First-pass
UNKNOWN yields `OPTIMISATION_TIMEOUT`, not INFEASIBLE. All incumbents require
independent checks; no unproven incumbent is described as optimal.

Integer units are microseconds for time, millionths of kg for load and millionths
of km (millimetres) for the secondary distance objective. Unsupported precision
or range is rejected explicitly; there is no silent rounding. Objective
coefficient sums and reported integers stay within 2^53-1. Timestamp arithmetic
uses Python's microsecond-resolution datetime. Sub-microsecond source timestamps
are outside the supported execution precision.

## Independent validator and output semantics

validation.py imports the Phase A parser and output data types only. It does not
call the solver-side schedule, feasibility, arc or integer-scaling helpers, and
does not import OR-Tools. It independently reads the original matrix, source
locations, weights, windows and vehicle constraints, and recomputes every leg,
service, wait, cumulative load, return and cost using Decimal arithmetic.

The validator checks input/matrix hashes, admission and ownership assertions,
one trip per vehicle, every served task exactly once, exact unserved complement,
typed unserved reasons, depot start/return, hub pickup, available arcs, service
windows, capacity throughout, route/horizon duration, lease sufficiency and no
offline dispatch-authority claim. Reported load/schedule fields cannot override
the recomputation. A solver's OPTIMAL status cannot override a failed check.

`validation.valid` means the route/report is internally consistent. It is not the
same as `validation.feasible`: a truthful INFEASIBLE, ROUTE_UNAVAILABLE or timeout
report can be valid while failing to provide a usable plan. An omitted mandatory
task must have feasible=false and an explicit failure status. Optimizers enforce
mandatory service as a hard constraint; a CP-SAT INFEASIBLE status supplies a
model-level proof. A heuristic's INFEASIBLE candidate is not an impossibility
proof. No route becomes dispatchable from either flag.

PLAN COMPLETE serves every admitted task. PARTIAL may omit only optional admitted
tasks. Excluded Phase A candidates are reported separately and are never counted
as optimizer-unserved. The original blocked readiness outcomes remain unchanged.

Pickup-task coverage and directed distance are independently recomputed metrics.
Total route duration is the sum across routes, including driving, waiting,
service and depot return; it is not makespan. Monetary costs remain diagnostic
metrics and do not affect the active CP-SAT objective.

`optimality_gap` is N/A unless a secondary incumbent and genuine CP-SAT lower
bound exist after fixing the achieved pickup-task count. It is
`(incumbent-bound)/max(1, abs(incumbent))` in scaled directed road distance.
Coverage and distance proof flags/statuses are retained separately. No global
gap is fabricated for heuristics, blocked inputs or unknown results.

## Scenarios and benchmark artifacts

The nine Phase A JSON fixtures are read byte-for-byte unchanged. Twelve additional
scenarios in scenarios.py are reproducible transformations of the same synthetic
directed line graph: cost/fleet tradeoff, urgent hub, over-capacity, duration and
window infeasibility, waiting, exact duration, co-located tasks, coverage over
large cost, forbidden mandatory/optional disconnected pickups, and no return arc.
Costs/windows/fleet edits are fictional scenario inputs. Disconnected examples
remove declared graph edges; missing data stays explicitly MISSING.

The default benchmark runs 21 x 4 x 3 = 252 executions. Solver imports are warmed
before timing. Every result must pass independent validation; each method must
reproduce its non-timing plan across repetitions. All methods use identical
snapshot/matrix hashes per case. Runtime remains measured, not deterministic.

Artifacts under results/stage8-phase-b:

- snapshots.json: exact sealed inputs, matrix provenance and hashes.
- results.json: every repetition's plan, schedules, unserved reasons and checks.
- comparison.csv / comparison.json: 84 method/scenario rows with runtime ranges,
  median solver/runtime, all requested metrics, proof/timeout and gap fields.
- comparison.md: readable comparison with infeasibility and coverage visible.
- non-timing-results.json: deterministic result content for replay comparison.
- manifest.json: Python/platform/packages/source hashes, configuration and the
  deterministic result digest. No test data is represented as live road data.

The benchmark checks the original 17 Phase A file fingerprints before/after run.
All 54 original tests remain unchanged; 63 new tests cover algorithms, integration,
infeasibility, real forced search limits and deliberately corrupt plans.

Scope, result interpretation, limitations and proposed Phase C live integration:
docs/stage8/2026-10-24-phase-b-offline-routing.md.
