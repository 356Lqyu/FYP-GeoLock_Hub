# Routing scenario input contract

**Selected default (7 November 2026): Windows laptop routing.** Start with [the Windows setup/start/stop guide](../../docs/LOCAL_ROUTING_WINDOWS.md) and `worker_service/windows/Start-Worker.ps1`. Existing Python/OR-Tools, independent validator, SQLite recovery and Supabase RPCs remain the runtime architecture. Render/cloud hosting is postponed; hosted/Docker sources are retained reference material, not prerequisites. The Phase A contract below remains historical library documentation.

Stage 8 Phase A supplies an offline Python input boundary for later routing
methods. It does not connect to Supabase, run a solver, persist a planning run,
validate a proposed route, publish routes, or grant dispatch authority.

Python was selected because the backend directory was empty and the existing
benchmark/baseline/test tooling is Python. This package uses the standard library
only. It is separate from research simulations and imports no synthetic fleet
into the operational application. Python 3.10 or later is required.

Run from the repository root:

```powershell
python -m unittest discover -s backend/routing/tests -v
python -m backend.routing backend/routing/examples/mixed.json
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
`to_dict()` returns a fresh copy. Four later methods consume copies of this
identical sealed problem, identified by the same digest; method identity and
method-specific output belong in a separate execution record. Reordering task
or fleet records does not change the digest. Matrix node order remains explicit.

Hashes detect changes; they are not signatures or proof of database authority.
The library validates supplied assertions. A future authenticated PostgreSQL
snapshot producer must obtain and join canonical records, trusted node mappings
and source tokens. No such producer or dispatch adapter is implemented here.
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
