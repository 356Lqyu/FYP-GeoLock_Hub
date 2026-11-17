# GeoLock Hub routing

## Windows planner and validator

The selected deployment runs the native planner and validator as separate Python services on Windows. PowerShell launches them through [Start-Worker.ps1](worker_service/windows/Start-Worker.ps1). The services use native PostgreSQL connections and scoped Supabase RPCs, with a local SQLite journal for recovery. Render and Docker are unnecessary for this workflow. For setup, startup, and shutdown, follow the [Windows Routing + Android Flutter Quick Start](../../docs/LOCAL_ROUTING_WINDOWS.md#quick-start-windows-routing-android-flutter-app). The seven-folder routing release remains undeployed pending DEV validator compatibility and cutover approval.

## Architecture overview

| Path | Responsibility |
| --- | --- |
| [contract.py](contract.py) and [contracts/](contracts/) | `contract.py` implements the schema and freezes routing inputs. `contracts/` exposes the public input contract. |
| [planner/](planner/) | Builds directed road matrices, prepares planning inputs, and evaluates the operational routing methods. |
| [optimizers/](optimizers/) | Holds the [method registry](optimizers/methods.py), canonical solver, constructive baselines, and planning models. [cp_sat.py](optimizers/cp_sat.py) implements the proposed optimizer, which maximizes pickup coverage before minimizing road distance. |
| [validator/](validator/) | Exposes independent plan validation and stored work-item validation. The route checks are implemented in [validator/validation.py](validator/validation.py). |
| [integration/](integration/) | Converts sealed database snapshots and graph exports into planning inputs and formats results for the Flutter client. |
| [worker_service/](worker_service/) | Runs the planner and validator HTTP services, authenticates requests, calls scoped RPCs, and journals progress. |
| [worker_service/windows/](worker_service/windows/) | Holds the Windows setup, launch, and operator checks. |
| [Versioned benchmark adapter](../../experiments/routing_research/benchmark_v32/README.md) | Bridges frozen benchmark data and baseline planners into the shared routing contract for E4. |
| [Routing research tools](../../experiments/routing_research/README.md) | Contains the synthetic demo and offline reproducibility diagnostics. Historical evidence tools retain their original inputs and verification paths. |
| [Historical routing archive](../../docs/investigations/routing-archive/README.md) | Inactive Render and Docker implementation, hosted tests, and a historical worker test receipt. |
| [tests/fixtures/](tests/fixtures/) and [tests/](tests/) | Synthetic scenario fixtures and regression checks for the contract and package layout. |

## From request to authorised route

```text
Flutter request
  → Windows planner service
  → Read the PostgreSQL snapshot, prepare the directed graph matrix, and seal the inputs
  → CP-SAT produces a route candidate
  → Independent Windows validator checks the stored candidate and attests its digest
  → PostgreSQL checks the authorisation request and grants route authority
```

Planning and validation are advisory. A candidate and its attestation support the authorisation decision. PostgreSQL alone grants route authorisation through the authenticated `authorize_my_routing_candidate` RPC.

## How E4 uses routing

[Experiment E4](../../experiments/e4/README.md) runs offline. Its [test harness](../../experiments/e4/test_harness/e4_shared.py) reuses the shared `proposed()` CP-SAT wrapper and independent `validate_plan()` function. E4 supplies its own [Nearest-Next](../../experiments/e4/baseline/source_code/nearest_next_baseline.py) and [FCFS](../../experiments/e4/baseline/source_code/fcfs_baseline.py) implementations and reads the frozen benchmark dataset.

## Where to start reading

1. [Windows launcher](worker_service/windows/Start-Worker.ps1) and [native worker](worker_service/native_worker.py) for how the two services start.
2. [Worker orchestration](worker_service/orchestrator.py) for snapshot preparation, candidate submission, validation, and authorisation.
3. [Input contract](contract.py) and [planning orchestration](planner/orchestration.py) for what the planner receives and how it compares methods.
4. [Public solver wrapper](optimizers/methods.py) and [CP-SAT implementation](optimizers/cp_sat.py) for how the proposed plan is computed.
5. [Independent route checks](validator/validation.py) and [validator service](worker_service/validator.py) for the distinction between checking a plan and attesting a stored candidate.

## Maintenance

Check dependencies and provenance before removing or moving a compatibility module or historical diagnostic. Older imports, tests, and evidence tools use their existing paths. Published E4 manifests record exact source paths and hashes, including some hosted and diagnostic files outside E4's execution path.

## Offline routing checks

Use the Python 3.12 Windows dependency lock in
[worker_service/requirements-lock.txt](worker_service/requirements-lock.txt) for
solver-only checks. The worker requirements include that lock and pin the
PostgreSQL driver. The [Windows routing guide](../../docs/LOCAL_ROUTING_WINDOWS.md)
covers installation and operation.

```powershell
& .\.venv-stage8\Scripts\python.exe -B -m unittest discover -s backend/routing -t . -v
& .\.venv-stage8\Scripts\python.exe -B -m unittest discover -s experiments/routing_research/algorithms/tests -t . -v
```

The operational registry runs FCFS, nearest neighbour, and the proposed CP-SAT
method. The research registry also exposes the distance-only entry point.
CP-SAT maximises pickup-task coverage before minimising total directed road
distance. One direct pickup or one indivisible hub batch counts as one task.
Independent validation recomputes service windows, route duration, loads,
capacity and distance from the sealed input without calling the solver.

The planner builds directed matrices by shortest road distance, with travel
time measured on the same path. Missing or unreachable arcs remain explicit.
The [research guide](../../experiments/routing_research/README.md) documents the
synthetic graph demo and separate research comparisons.

## Routing scenario input contract

Stage 8 Phase A supplies an offline Python input boundary for later routing
methods. It does not connect to Supabase, run a solver, persist a planning run,
validate a proposed route, publish routes, or grant dispatch authority.

Python was selected because the backend directory was empty and the existing
benchmark/baseline/test tooling is Python. The Phase A contract tools use only
the standard library and require Python 3.10 or later. They are separate from
research simulations and import no synthetic fleet into the operational application.

Run from the repository root:

```powershell
python -m unittest discover -s backend/routing/tests -v
python -m backend.routing backend/routing/tests/fixtures/mixed.json
python -m backend.routing.generate_examples --check
```

The CLI returns 0 for READY_FOR_PLANNING, 1 for a valid input with a blocking
business outcome, and 2 for malformed input or a file error. Readiness does not
assert feasibility, optimality, current ownership, or dispatch permission.

## Version and immutable representation

`schema_version` is exactly `geolock.routing.scenario.v1`. `contract.py` is the
executable field/type contract; every object rejects missing and unknown fields.
There are no implicit capacity, cost, service-time, time-window or matrix defaults.
Unknown versions fail closed. All timestamps have explicit timezone offsets;
numbers must be finite and booleans cannot substitute for numeric values.

`freeze_scenario(dict)` returns `FrozenScenario`, a frozen dataclass holding a
canonical JSON string, SHA-256 of the complete envelope, matrix SHA-256,
admitted IDs, typed exclusions, eligible vehicle IDs and unavailable arcs.
`to_dict()` returns a fresh copy. The three operational methods consume copies of this
identical sealed problem, identified by the same digest; method identity and
method-specific output belong in a separate execution record. Reordering task
or fleet records does not change the digest. Matrix node order remains explicit.

Hashes detect changes; they are not signatures or proof of database authority.
The contract validates supplied assertions. The Windows planner obtains canonical
records, trusted node mappings and source tokens through the operational snapshot
integration.
`dispatch_authority_issued` is always false in the output envelope.

## Required fields

| Object | Required data and semantics |
|---|---|
| Scenario | schema_version, planning_run_id, scenario_id, source, ngo_id, ngo_active, ngo_location_verified_at, ngo_location_generation, cutoff, configuration, depot, route_start_location_id, route_end_location_id, vehicles, tasks, matrix, solver |
| Source | kind (`SYNTHETIC_BENCHMARK` or `OPERATIONAL_SNAPSHOT`), project_ref, provenance, evidence_ref. Synthetic project_ref is null; operational scope is DEV rcgyuwiidqvrgbxswhqj only. |
| Configuration | version, currency/cost-unit label, positive planning_horizon_minutes, nonnegative dispatch_margin_minutes, objective, time_window_policy |
| Objective | `MIN_UNSERVED_THEN_FIXED_PLUS_DISTANCE_COST`: primary admitted-task coverage, then sum of used-vehicle fixed costs plus vehicle-specific distance cost times km. This declares the proposed method/evaluation priority; comparator strategies are recorded separately. |
| Time-window policy | `SERVICE_COMPLETION_WITHIN_WINDOW`; each service must finish within its pickup window. Waiting is allowed in later route validation. |
| Location | location_id, road_node_id, network_snapshot_id, latitude, longitude, state_token. Depot and admitted pickups must use the matrix network version. Routes start and return to the one NGO depot. |
| Vehicle | vehicle_id, ngo_id, vehicle_type, capacity_kg, active, available_for_planning, fixed_cost, distance_cost_per_km, max_route_minutes, depot_location_id, state_token |
| Task identity | task_id, ngo_id, claim_id, claim_ngo_id, lease_id, listing_id, source_type (`DIRECT_DONATION` or `HUB_BATCH`) |
| Task authority | task_status, claim_status, lease_status, listing_status, created_at, lease_issued_at, lease_expires_at, nullable listing_expires_at, listing_version, task_state_token, claim_state_token, lease_state_token, has_route_assignment, reconciliation_blocked |
| Task operational data | pickup, authorized_pickup, weight_kg, listing_weight_kg, time_window, service_minutes, mandatory, donations, nullable batch |
| Time window | start, end, provenance. Operational sources/policy must be explicit; missing windows are not silently replaced with an all-day window. |
| Donation member | donation_id, donation_status, state_token. Exactly one member for direct pickup; the complete immutable member set for a batch. Duplicate originals across tasks are rejected. |
| Batch | batch_id, hub_id, batch_version, batch_status, inventory_status, member_count, state_token. Authorized pickup location_id equals hub_id. A batch is one task/stop with its aggregate listing/task weight, never one stop per original member. |
| Solver | engine=OR_TOOLS, explicit version, time_limit_seconds, workers=1, seed, first_solution=PATH_CHEAPEST_ARC, local_search=GUIDED_LOCAL_SEARCH, tie_break=TASK_ID_THEN_VEHICLE_ID, timeout_policy=VALIDATED_INCUMBENT_ONLY |

Locations and source tokens must come from the future trusted producer, not a
client assertion. `authorized_pickup` is the canonical donor pickup or selected
hub location; `pickup` also reflects the persisted task node. A mismatch excludes
the task. An operational producer must separately reject stale node mappings.

The deployed database has listing_version, batch_version and NGO location_generation,
but no native task/claim/lease/donation version counters. Their `state_token`
fields represent SHA-256 of a documented canonical source-field projection, not
invented version numbers. The Phase B producer must freeze that projection and
recompute tokens during dispatch. Lease timestamps use database time. Task
created_at can precede lease issued_at slightly because DEV uses transaction
`now()` and wall-clock `clock_timestamp()` respectively.

All vehicle costs in one scenario use configuration.currency. Costs may be
explicitly zero; capacities and maximum durations must be positive. A vehicle's
maximum duration cannot exceed the scenario horizon. Fleet ownership/depot
inconsistency rejects the input. Inactive/unavailable vehicles remain in the
frozen evidence but are absent from available_vehicle_ids. No synthetic fallback
is generated for an empty fleet.

## Admission

Admission collects all applicable typed exclusion reasons for each structurally
valid candidate. Malformed records reject the input instead of being silently
discarded. The future producer should retain malformed-source diagnostics in its
separate acquisition log; this package does not invent absent source evidence.

1. NGO is active and has a verified depot at or before cutoff.
2. Task owner and claim owner both equal the requesting NGO.
3. Task is CONFIRMED, listing is CLAIMED, claim and lease are ACTIVE.
4. Task/lease were not created after cutoff. Lease interval is valid.
5. Lease expiry is strictly after cutoff + planning horizon + dispatch margin.
   Equality is rejected because DEV considers expiry at current time invalid.
   A finite listing expiry must also exceed this conservative authority horizon.
6. No unresolved reconciliation or existing route assignment.
7. Task pickup equals authorized pickup and task load equals listing load.
8. Every original donation is CLAIMED. Hub batch is PUBLISHED with BATCHED
   inventory and an exact member set. No obsolete donation states are accepted.
9. Source window has enough remaining time for service, even before travel.
10. Matrix covers depot and all admitted pickup nodes on one graph version.

The cutoff+horizon policy is deliberately conservative. Later independent route
validation additionally checks actual arrival, service completion and return,
cumulative load, per-vehicle duration, mandatory tasks, exactly-once accounting
and current authority. READY_FOR_PLANNING does not perform those checks.

The producer must derive reconciliation_blocked from OPEN/MANUAL_REVIEW cases
for the claim/listing and relevant batch members, not just a lease status string.
It must derive has_route_assignment from active assignments/relevant route stops.
Current source consistency, complete membership, verified nodes and no foreign
records must be established by protected joins before accepting the snapshot.

## Matrices and unavailable arcs

Each matrix supplies matrix_id, version, network_snapshot_id, source_kind,
provenance, method, edge_speed_profile, path_policy, unavailable_policy,
node_order, distance_km, travel_minutes and arc_status.

Distance and time are square directed arrays in km/minutes, indexed by node_order.
The fixed path policy is DIRECTED_SHORTEST_DISTANCE_WITH_TIME_ON_SAME_PATH.
Distance and time for one OD cell describe the same path; independently minimizing
distance and time and pairing the two results is invalid. The parser can validate
the declaration and shape; acquisition must prove path provenance.

Each cell is AVAILABLE with finite positive off-diagonal distance/time (zero
self arcs), or explicitly UNREACHABLE/MISSING with paired JSON nulls. An omitted
row/cell is malformed. Null never becomes zero, infinity, straight-line distance
or a guessed speed. MISSING records incomplete/failed acquisition; UNREACHABLE
requires an actual no-path result on the declared graph. Operational matrices
require OSM-OPS identifiers and positive numeric OSM node strings; benchmark
matrices cannot be silently relabelled as operational.

- FAIL_SCENARIO returns ROUTE_UNAVAILABLE for any unavailable required OD arc.
- FORBID_ARC retains the arcs as forbidden for every future method/validator;
  READY_FOR_PLANNING does not promise that a feasible route exists. Neither
  missing nor unreachable arcs may be traversed. The operational policy still
  needs approval; examples explicitly use FAIL_SCENARIO.

Outcome precedence is NO_VALID_TASKS, NO_FEASIBLE_PLAN for no eligible fleet,
ROUTE_UNAVAILABLE under FAIL_SCENARIO, then READY_FOR_PLANNING. Invalid structure
raises ContractError before readiness. Empty tasks/fleet remain visible in input.

## Synthetic fixtures

Every fixture is explicitly SYNTHETIC_BENCHMARK and project-free. All task,
vehicle, location, token, capacity, cost and timestamp values are fictional;
there is no operational fleet or service policy implied by these fixtures.

`generate_examples.py` declares a three-vertex directed line graph:

| Directed edge | km | minutes |
|---|---:|---:|
| TOY-DEPOT -> TOY-DONOR | 2 | 4 |
| TOY-DONOR -> TOY-DEPOT | 2.5 | 5 |
| TOY-DONOR -> TOY-HUB | 3 | 6 |
| TOY-HUB -> TOY-DONOR | 3.5 | 7 |

The unique directed path between each pair is the sum of those edges. Coordinates
are fictional labels and are never used to estimate roads. Forward depot-to-hub
is 5 km/10 minutes; reverse is 6 km/12 minutes. The unreachable fixture removes
both directed edges incident to the hub, gives the graph its own version and
records all four disconnected OD pairs as UNREACHABLE. The missing-data fixture
keeps the connected graph but masks one acquisition cell as MISSING. Both
derivations are recorded in provenance.

Nine checked-in fixtures cover mixed/direct/hub tasks, zero vehicles, no tasks,
expired authority, reconciliation, unreachable and missing matrix data. The
240-minute horizon, 10-minute service, 10-minute margin and example costs are
explicit toy parameters. The margin and fleet values are not approved defaults.
Solver version is NOT_INSTALLED_PHASE_A; no OR-Tools dependency was installed.

Regenerate deliberately with `python -m backend.routing.generate_examples`;
`--check` verifies exact reproducibility without writing. Unit tests exercise
positive and adversarial cases, hashes, immutability, exclusions and CLI outcomes.

Architecture, evidence and proposed database/dispatch integration are recorded in
`docs/stage8/2026-10-24-phase-a-architecture.md`.
