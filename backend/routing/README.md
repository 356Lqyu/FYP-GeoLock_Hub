# GeoLock Hub routing

This folder plans pickup routes for an NGO's vehicles and makes sure no route is driven unless it has been checked.

Two small Windows worker processes do the work:

- **Planner.** Builds the route with **Google OR-Tools CP-SAT** on the frozen road graph. It first serves as many pickup tasks as possible, then keeps the cost (fixed vehicle cost + road distance) as low as possible. FCFS and nearest-neighbour baselines run beside it for comparison.
- **Validator.** A separate process with its own database login. It rebuilds the input from the database and re-checks every route on its own.

**PostgreSQL (Supabase) alone** decides whether a checked route may start. No worker can dispatch a route, claim a donation, record a pickup or write tables directly.

```
Flutter "Generate Route"
   → planner   :8787   reads the sealed database snapshot, builds road matrices from the frozen graph,
                       runs FCFS, nearest-neighbour and CP-SAT, stores the CP-SAT candidate
   → validator :8788   rebuilds the input from the database, checks the candidate again,
                       then attests its digest
   ← attested candidate, valid for 60 minutes (advisory only: nothing is reserved yet)

Flutter "Start Route"  authorize_and_start_my_route (database RPC, one transaction):
                       authorises the candidate at "now" and dispatches the first stop
Each stop              start_pickup → complete_pickup                 (database RPCs)
Close                  close_my_collected_route / close_my_resolved_route
Problems               reconciliation in the app; detach_my_unstarted_stop for a stop whose lease is too short
```

## Contents

1. [Folder](#folder)
2. [Planner and validator](#planner-and-validator)
3. [Environments: KLSEL and DEV](#environments-klsel-and-dev)
4. [Start the planner and validator (Windows)](#start-the-planner-and-validator-windows)
5. [From Generate Route to reconciliation](#from-generate-route-to-reconciliation)
6. [Routing input contract](#routing-input-contract)
7. [Errors, retries and recovery](#errors-retries-and-recovery)
8. [Offline tests](#offline-tests)
9. [Troubleshooting](#troubleshooting)
10. [Protected files and safety rules](#protected-files-and-safety-rules)
11. [Where things moved (20 Nov 2026 restructure)](#where-things-moved-20-nov-2026-restructure)

## Folder

```
backend/routing/
├── README.md               this file (contract, environments, operation)
├── requirements.txt        all pinned worker dependencies (Python 3.12): OR-Tools 9.15.6755, psycopg 3.3.6, …
├── __main__.py             python -m backend.routing <scenario.json>: check one scenario file
├── contract.py             🔒 the routing input contract: schema, admission rules, freeze and digest
├── snapshot.py             🔒 sealed database snapshot → planner input; decodes stored plans
├── route_plan.py           Plan / Route / Stop / ExecutionConfig, shared by planner and validator
├── environment.py          DEV / KLSEL registry: project, frozen graph, folders (no secrets)
│
├── road_network/           road graph → directed distance and time matrices
│   ├── graph_cache.py      downloads the frozen graph through a read-only RPC; immutable local cache
│   ├── graph_export.py     turns graph pages into the matrix builder's input
│   └── matrix.py           shortest road distance, with travel time measured on the same path
├── planner/                builds route candidates (no database, no HTTP)
│   ├── planning.py         prepares the input, runs the three methods and compares them
│   ├── methods.py          method registry (fcfs, nearest_neighbour, proposed; distance_only for research)
│   ├── cp_sat.py           the proposed OR-Tools CP-SAT model
│   ├── baselines.py        FCFS and nearest-neighbour baselines
│   └── problem.py          solver-side view of the problem and schedule construction
├── validator/              independent checks; imports nothing from planner/
│   └── validation.py       🔒 recomputes windows, loads, capacity, duration and distance from the sealed input
├── database/               how the services talk to Supabase / PostgreSQL
│   ├── supabase_rpc.py     whitelisted role RPCs and NGO JWT verification; no direct table writes
│   ├── native_connection.py  libpq service connection, passwords kept as native bytes
│   ├── libpq_client.py     loads the pinned native libpq 17 before the driver
│   └── password_input.py   hidden console password read
├── service/                the two running processes
│   ├── start_worker.py     entry point used by windows/Start-Worker.ps1 (planner or validator)
│   ├── http_api.py         small loopback HTTP API (disabled unless activated)
│   ├── planner_service.py  snapshot → matrix → candidate → validation → authorisation request
│   ├── validator_service.py  separate validator process: re-reads the work item and attests it
│   ├── journal.py          crash-resumable local SQLite journal (safe retries and recovery)
│   ├── flutter_response.py shapes results for the Flutter app (never a dispatch response)
│   ├── safe_failure.py     redacted failure reports (no secrets or raw error text)
│   ├── errors.py           WorkerError and check()
│   ├── exact_pilot.py      opt-in exact-scope pilot workflow (-EnableExactWorkflow)
│   ├── exact_pilot_client.py  operator client for that pilot (used by scripts/Run-ExactV3Pilot.py)
│   └── route_resolution.py default-disabled route-resolution adapter
├── diagnostics/            read-only connection checks and probes; they never start a service
├── windows/                Windows setup, launch and operator checks (PowerShell)
│   ├── Save-WorkerConfig.ps1   save encrypted planner/validator profiles (once per environment)
│   ├── Start-Worker.ps1        start, check config, check connection or warm the graph cache
│   ├── Test-LocalRoutingSetup.ps1  offline setup check (runs local_setup_check.py)
│   ├── Prepare-WorkerCache.ps1, Update-PlannerPublishableKey.ps1, Test-PlannerPublishableKeyUpdate.ps1
│   └── create_worker_logins.manual.sql, verify_worker_roles.readonly.sql
└── tests/                  offline tests (no Supabase connection)
    ├── fixtures/           9 synthetic scenarios; tests/generate_fixtures.py makes them
    ├── test_*.py           contract, planner, validator, road matrices, snapshot, Flutter shape
    └── service/test_*.py   services, database adapters, diagnostics, Windows helpers
```

🔒 = the bytes of these three files form the validator build ID (see [Protected files](#protected-files-and-safety-rules)).

Research and results are kept outside this folder: `experiments/routing_research/`, `experiments/e4/`, `baseline implementation/`, `benchmark dataset/` and `results/`. Architecture notes and evidence from the earlier stages are in `docs/stage8/`, starting with `docs/stage8/2026-10-24-phase-a-architecture.md`.

## Planner and validator

| Part | Runs as | Database login (role) | Allowed RPCs |
|---|---|---|---|
| Planner service | `Start-Worker.ps1 -Mode planner` (port 8787) | `geolock_planner_login` | `read_pending_routing_snapshot`, `read_routing_snapshot_bundle`, `seal_routing_snapshot`, `submit_routing_candidate` |
| Road network (inside the planner) | same process | `geolock_graph_login` | `read_frozen_routing_graph`, `store_routing_matrix` |
| Validator service | `Start-Worker.ps1 -Mode validator` (port 8788) | `geolock_validator_login` | `read_routing_work_item`, `attest_routing_candidate` |
| Authorisation, dispatch, detach, recovery | **database only** (called by Flutter as the NGO) | NGO JWT | `authorize_and_start_my_route`, `start_pickup`, `complete_pickup`, `detach_my_unstarted_stop`, `recover_expired_claims` (cron) |

How the two workers divide the job:

| | Planner | Validator |
|---|---|---|
| Job | Find a good route | Prove the route is safe |
| Input | Sealed snapshot + road matrix | Rebuilds the work item from the database with its own login |
| Code | `planner/`, `road_network/`, `service/planner_service.py` | `validator/validation.py`, `service/validator_service.py` (imports nothing from `planner/`) |
| Output | A candidate route (never authority) | An attestation of the candidate's digest, signed with `validator_build` |

Rules that always hold:

- **No dispatch from a worker.** The planner never grants route authority. No worker endpoint can dispatch, claim, pick up or write tables directly.
- **Attestation only after validation.** A candidate is `ATTESTED` only after the validator, with its own login, has re-read the work item and checked it.
- **What the validator checks:**
  - actual arrival times, service completion and return to the depot;
  - time windows and cumulative load against vehicle capacity;
  - per-vehicle route duration;
  - that mandatory tasks are served and every admitted task is accounted for exactly once;
  - that distances match the sealed matrix;
  - that authority is still current.

  `READY_FOR_PLANNING` from the contract does **not** perform these checks.
- **Validator fingerprint.** Each report is signed with `validator_build`, the SHA-256 of `contract.py` + `validator/validation.py` + `snapshot.py`. The database requires a non-empty value (`TRUSTED_VALIDATION_REQUIRED` otherwise) When the same attestation is replayed, the reviewed SQL (`docs/stage8/stage-a/forward-migrations/20261101_routing_authority.sql`) compares the whole report, including the build ID, and raises `VALIDATION_CONFLICT` if it differs.
- **Per-task lease admission (Phase 2).** Under policy v2, a task is admitted when its lease outlasts the time needed to reach and serve it, plus the margin. The rule is identical in Python (`contract.py`, scenario v2) and SQL.
- **Detachment.** A future stop whose lease becomes too short can be detached with `detach_my_unstarted_stop`. The claim stays active and can be planned again.

## Environments: KLSEL and DEV

Each worker process serves **one** Supabase project. `GEOLOCK_ENVIRONMENT` selects it, and `Start-Worker.ps1` sets it from `-Environment`.

> ⚠️ **DEV is the default.** If you leave out `-Environment`, the scripts use DEV, and every DEV launch behaves exactly as before. For the new KL/Selangor project, **always pass `-Environment KLSEL`**.

| | `DEV` (default) | `KLSEL` (NEW project) |
|---|---|---|
| Project | `rcgyuwiidqvrgbxswhqj` | `ppwmdsyoesvhgmqiaoxa` |
| Frozen graph | `eab1f7ee-a8e0-4bed-a0e1-2c4bff024936` | `19c44bd2-8871-4eca-bf6b-4262f1bf766d` |
| Content digest | `5e06dab0…04012a` | `6b62b365…9edc32` |
| Snapshot, nodes / edges | `OSM-OPS-20261018`, 926,414 / 2,145,828 | `OSM-OPS-20261018-KLSEL`, 205,524 / 454,178 |
| Local folder (`%LOCALAPPDATA%`) | `GeoLockHubRoutingDev` | `GeoLockHubRoutingKLSEL` |
| libpq service profile | tracked, hash-pinned (`docs/stage8/stage-a/deployment-preparation/routing-initialization/pg_service.proposed.conf`) | `GeoLockHubRoutingKLSEL\pg_service.conf` (service `geolock_klsel_worker`). It is outside Git and password-free, is written by `Save-WorkerConfig.ps1 -Environment KLSEL`, and is checked field by field against `environment.py`. |
| Worker state (journal + graph cache) | `GeoLockHubRoutingDev\state` | `GeoLockHubRoutingKLSEL\state`. It is stamped with `environment.json`, and another environment's folder is refused. |

All identifiers live in `environment.py`, which contains no passwords, keys, tokens or DSNs.

### Frozen KLSEL graph

- The planner may use **only** graph `19c44bd2-8871-4eca-bf6b-4262f1bf766d` (snapshot `OSM-OPS-20261018-KLSEL`, digest `6b62b365…9edc32`, 205,524 nodes, 454,178 edges). `Start-Worker.ps1 -Environment KLSEL` sets it automatically and refuses any other `-GraphId`.
- `GraphCache` checks the live manifest's graph ID, digest, snapshot, counts and speed profile before using a cache.
- It refuses a cache folder that holds another graph's files (`FOREIGN_GRAPH_CACHE_PRESENT`), so DEV's cache can never be reused for KLSEL.
- KLSEL builds its own cache with `-WarmGraph`, which needs `-ApprovalRef`, is read-only and starts no server.

### Safety properties (every non-DEV environment)

- **Project and graph.** `GEOLOCK_PROJECT_REF` and `GEOLOCK_GRAPH_ID` must equal the registry values. DSNs must target that project: the pooler user suffix or the `db.<ref>` host.
- **NGO JWTs** are verified against the selected project's Supabase URL.
- **Activation flag.** It keeps its historical name, `GEOLOCK_ROUTING_ALLOW_DEV_WRITES=APPROVED`, in every environment. `Start-Worker.ps1 -Activate -ApprovalRef <ref>` sets it.
- **DEV-only tools.** These refuse or are not meant for non-DEV environments:
  - `windows/Prepare-WorkerCache.ps1` (refuses non-DEV folders);
  - `diagnostics/pilot_benchmark_probe.py` (refuses non-DEV);
  - `windows/Update-PlannerPublishableKey.ps1`;
  - `windows/create_worker_logins.manual.sql`;
  - `scripts/Run-ExactV3Pilot.py`, `scripts/Verify-ReconciliationHostedReads.py`, `scripts/Inspect-PhoneRoutingMetadata.py`.
- **Validator build ID.** The KLSEL environment change edited `contract.py` and `snapshot.py`, so the ID differs from the earlier pre-KLSEL value in both environments. The database accepts any non-empty value for a new attestation.

## Start the planner and validator (Windows)

These are the **current KLSEL commands** (NEW project `ppwmdsyoesvhgmqiaoxa`). Run everything from the repository root. Prerequisites (Python 3.12 x64, native libpq 17.11, USB and shutdown) are in [docs/LOCAL_ROUTING_WINDOWS.md](../../docs/LOCAL_ROUTING_WINDOWS.md); that guide's own command examples are DEV.

> ⚠️ `Start-Worker.ps1`, `Save-WorkerConfig.ps1` and `Test-LocalRoutingSetup.ps1` all default to **DEV**. Every KLSEL command below includes `-Environment KLSEL`; a command without it targets DEV.

**1. Install once** (Python 3.12):

```powershell
& .\.venv-stage8\Scripts\python.exe -m pip install -r .\backend\routing\requirements.txt
```

**2. Save the encrypted profiles** (once per environment; this never overwrites an existing profile):

```powershell
.\backend\routing\windows\Save-WorkerConfig.ps1 -Environment KLSEL
```

**3. Check without activating:**

```powershell
.\backend\routing\windows\Test-LocalRoutingSetup.ps1 -Environment KLSEL                     # offline
.\backend\routing\windows\Start-Worker.ps1 -Environment KLSEL -Mode validator -CheckConfig
.\backend\routing\windows\Start-Worker.ps1 -Environment KLSEL -Mode planner   -CheckConfig
.\backend\routing\windows\Start-Worker.ps1 -Environment KLSEL -Mode validator -CheckConnection   # live, read-only
.\backend\routing\windows\Start-Worker.ps1 -Environment KLSEL -Mode planner   -CheckConnection   # live, read-only
```

What the checks print:
- `-CheckConfig` makes no network call and prints `"project_ref":"ppwmdsyoesvhgmqiaoxa"` with `"status":"DISABLED"`. `DISABLED` is expected, because a check never activates the worker.
- `-CheckConnection` opens read-only database sessions with the worker logins. It writes a local receipt under `results/worker-runtime-connections/`.

**4. Build the graph cache** (optional; once per machine). This is read-only, starts no server and needs an approval reference. If you skip it, the planner downloads and verifies the graph on its first request, which is slow and memory-heavy:

```powershell
.\backend\routing\windows\Start-Worker.ps1 -Environment KLSEL -Mode planner -WarmGraph -ApprovalRef <ref>
```

**5. Start the workers**, validator first, each in its own window, and leave both windows open:

```powershell
.\backend\routing\windows\Start-Worker.ps1 -Environment KLSEL -Mode validator -Activate -ApprovalRef <validator-ref>
.\backend\routing\windows\Start-Worker.ps1 -Environment KLSEL -Mode planner   -Activate -ApprovalRef <planner-ref>
```

**6. Check health** from a third window:

```powershell
Invoke-RestMethod 'http://127.0.0.1:8788/health' -TimeoutSec 5   # validator
Invoke-RestMethod 'http://127.0.0.1:8787/health' -TimeoutSec 5   # planner
```

Each should report `status = ACTIVE` and `project_ref = ppwmdsyoesvhgmqiaoxa`. `ACTIVE` proves the listener is enabled. It does not prove graph readiness, database permissions or that a route can be found.

**7. Run the app against KLSEL.**
1. In `frontend/geolock_hub_app`, copy `klsel-config.example.json` to the git-ignored `klsel-config.json`, and put the NEW project's **publishable** key in it.
2. Connect the phone and run `adb reverse tcp:8787 tcp:8787`.
3. Run `flutter run --dart-define-from-file=klsel-config.json`.

The app refuses a planner whose `/health` reports a different project. `scripts/Run-RoutingDev.ps1` is fixed to DEV, so don't use it for KLSEL.

### What each switch does

| Switch | Needed for KLSEL? | What it does (from `Start-Worker.ps1` and `service/http_api.py`) |
|---|---|---|
| `-Environment KLSEL` | **Always** | Selects the NEW project, its folder `%LOCALAPPDATA%\GeoLockHubRoutingKLSEL`, its `pg_service.conf` and its frozen graph. Without it, everything is DEV. |
| `-Mode planner` / `validator` | Always | Which worker to run (ports 8787 / 8788) |
| `-Activate` + `-ApprovalRef <ref>` | **Yes, to serve requests** | Without `-Activate`, the worker starts **DISABLED** and answers every request with `WORKER_NOT_ACTIVATED` (503). `-ApprovalRef` is required with it and is recorded; it is not a secret. |
| `-GraphId` | No | KLSEL sets graph `19c44bd2-8871-4eca-bf6b-4262f1bf766d` automatically. Passing that same ID is accepted; any other ID is refused. Only DEV uses this switch. |
| `-WarmGraph` (+ `-ApprovalRef`) | Optional, once | Downloads and verifies the frozen graph into the local cache, then exits. Planner only; it cannot be combined with `-Activate` or the checks. |
| `-CheckConfig` / `-CheckConnection` | Recommended before starting | Offline config check / live read-only connection check. Never combined with `-Activate`. |
| `-EnableCombinedWorkflow` | **No** | Enables `/v1/plan-and-authorize`. The current app does not call it: Generate Route uses `/v1/plan` (and `/v1/planning-result` to re-read a saved result), and Start Route is the database RPC `authorize_and_start_my_route` (Option C). The combined endpoint's authorisation call (`authorize_my_routing_candidate`) is revoked under Option C, so leave this switch off. |
| `-EnableExactWorkflow` | **No** | Enables `/v1/exact-route-*` for the DEV Exact-V3 pilot (`scripts/Run-ExactV3Pilot.py`). The app never calls it. |

For DEV, leave out `-Environment`. The DEV commands are unchanged, and DEV may pass `-GraphId`. The historical DEV operator procedure is in `STARTUP_GUIDE.md`.

The old forwarder `.\backend\routing\worker_service\windows\Start-Worker.ps1` was removed on 22 Nov 2026. It could not select KLSEL. Always use `.\backend\routing\windows\Start-Worker.ps1`.

## From Generate Route to reconciliation

1. **Generate Route.** Flutter sends the NGO's bearer token with `{request_id, snapshot_id}` to the planner at `/v1/plan`, and can re-read a completed saved result through `/v1/planning-result`. Client-supplied plans, NGO IDs and success flags are rejected.
2. **Seal.** The planner reads and seals the routing snapshot through its own RPCs, and the snapshot must be fresh (at most 300 s old). `contract.py` freezes it and applies the admission rules.
3. **Matrix.** `road_network/` builds directed distance/time matrices for the depot and the admitted pickups from the frozen graph. It stores them through `store_routing_matrix`.
4. **Plan.** FCFS, nearest-neighbour and CP-SAT run on the same sealed problem. The CP-SAT result is submitted as the candidate.
5. **Validate.** The validator re-reads the work item with its own login, re-checks the candidate and attests its digest. The attested candidate is valid for 60 minutes; it is advisory, and nothing is reserved yet.
6. **Start Route.** Flutter calls `authorize_and_start_my_route`. In one transaction, the database authorises the candidate at "now" and dispatches the first stop.
7. **Pickup.** Each stop runs `start_pickup` → `complete_pickup`. A future stop whose lease has become too short can be detached with `detach_my_unstarted_stop`.
8. **Reconciliation and close.** Problems found at a pickup open a reconciliation case, handled in the app. The route closes with `close_my_collected_route` or `close_my_resolved_route`. Expired claims are recovered by `recover_expired_claims` (cron).

## Routing input contract

`contract.py` is the executable contract for the **sealed routing scenario** that the planner and the independent validator both consume. On its own it is an offline input boundary: it does not connect to Supabase, run a solver, store a planning run, validate a proposed route, publish routes or grant dispatch authority.

The contract tools use only the Python standard library (Python 3.10 or later). They are separate from research simulations and import no synthetic fleet into the operational application.

### Key rules

- **Versions.** `schema_version` is `geolock.routing.scenario.v1` or `geolock.routing.scenario.v2`. Version 2 (Phase 2) adds per-task lease admission (`configuration.lease_admission = PER_TASK_SERVICE_COMPLETION`). Unknown versions fail closed.
- **Strict fields.**
  - Every object rejects missing and unknown fields.
  - There are no implicit capacity, cost, service-time, time-window or matrix defaults.
  - Timestamps need explicit timezone offsets.
  - Numbers must be finite, and booleans cannot stand in for numbers.
- **Freezing.** `freeze_scenario(dict)` returns `FrozenScenario`, a frozen dataclass holding:
  - a canonical JSON string;
  - the SHA-256 of the complete envelope;
  - the matrix SHA-256;
  - admitted task IDs, typed exclusions, eligible vehicle IDs and unavailable arcs.

  `to_dict()` returns a fresh copy. Reordering task or fleet records does not change the digest. Matrix node order stays explicit.
- **Same problem for every method.** The three operational methods consume copies of the identical sealed problem, identified by the same digest. Method identity and method-specific output belong in a separate execution record.
- **Hashes are not authority.** They detect changes; they are not signatures or proof of database authority. The contract validates supplied assertions. The Windows planner gets canonical records, trusted node mappings and source tokens from the operational snapshot. `dispatch_authority_issued` is always false in the output envelope.

### Readiness outcomes and CLI exit codes

| Outcome | Meaning |
|---|---|
| `READY_FOR_PLANNING` | Valid input with at least one admitted task and an eligible vehicle. It does **not** assert feasibility, optimality, current ownership or dispatch permission. |
| `NO_VALID_TASKS` | No task passed admission |
| `NO_FEASIBLE_PLAN` | No eligible vehicle |
| `ROUTE_UNAVAILABLE` | A required origin–destination (OD) arc is unavailable under `FAIL_SCENARIO` |
| `ContractError` | Invalid structure; raised before readiness |

The outcomes are checked in the table's order: `NO_VALID_TASKS`, then `NO_FEASIBLE_PLAN`, then `ROUTE_UNAVAILABLE`, then `READY_FOR_PLANNING`. Empty tasks or fleet stay visible in the input.

`python -m backend.routing <scenario.json>` returns:
- **0** for `READY_FOR_PLANNING`;
- **1** for a valid input with a blocking business outcome;
- **2** for malformed input or a file error (`INVALID_INPUT`).

<details>
<summary><b>Required fields</b> (full table)</summary>

| Object | Required data and semantics |
|---|---|
| Scenario | schema_version, planning_run_id, scenario_id, source, ngo_id, ngo_active, ngo_location_verified_at, ngo_location_generation, cutoff, configuration, depot, route_start_location_id, route_end_location_id, vehicles, tasks, matrix, solver |
| Source | kind (`SYNTHETIC_BENCHMARK` or `OPERATIONAL_SNAPSHOT`), project_ref, provenance, evidence_ref. Synthetic project_ref is null. Operational scope is the active environment's project only (see [Environments](#environments-klsel-and-dev)). |
| Configuration | version, currency/cost-unit label, positive planning_horizon_minutes, nonnegative dispatch_margin_minutes, objective, time_window_policy (v2 also requires lease_admission) |
| Objective | `MIN_UNSERVED_THEN_FIXED_PLUS_DISTANCE_COST`: first maximise admitted-task coverage, then minimise the sum of used-vehicle fixed costs plus vehicle-specific distance cost × km. This declares the proposed method's priority; comparator strategies are recorded separately. |
| Time-window policy | `SERVICE_COMPLETION_WITHIN_WINDOW`: each service must finish within its pickup window. Waiting is allowed in later route validation. |
| Location | location_id, road_node_id, network_snapshot_id, latitude, longitude, state_token. The depot and admitted pickups must use the matrix network version. Routes start at and return to the one NGO depot. |
| Vehicle | vehicle_id, ngo_id, vehicle_type, capacity_kg, active, available_for_planning, fixed_cost, distance_cost_per_km, max_route_minutes, depot_location_id, state_token |
| Task identity | task_id, ngo_id, claim_id, claim_ngo_id, lease_id, listing_id, source_type (`DIRECT_DONATION` or `HUB_BATCH`) |
| Task authority | task_status, claim_status, lease_status, listing_status, created_at, lease_issued_at, lease_expires_at, nullable listing_expires_at, listing_version, task_state_token, claim_state_token, lease_state_token, has_route_assignment, reconciliation_blocked |
| Task operational data | pickup, authorized_pickup, weight_kg, listing_weight_kg, time_window, service_minutes, mandatory, donations, nullable batch |
| Time window | start, end, provenance. Operational sources and policy must be explicit; a missing window is never silently replaced with an all-day window. |
| Donation member | donation_id, donation_status, state_token. Exactly one member for a direct pickup; the complete immutable member set for a batch. Duplicate originals across tasks are rejected. |
| Batch | batch_id, hub_id, batch_version, batch_status, inventory_status, member_count, state_token. The authorised pickup location_id equals hub_id. A batch is one task/stop with its aggregate listing/task weight, never one stop per original member. |
| Solver | engine=OR_TOOLS, explicit version, time_limit_seconds, workers=1, seed, first_solution=PATH_CHEAPEST_ARC, local_search=GUIDED_LOCAL_SEARCH, tie_break=TASK_ID_THEN_VEHICLE_ID, timeout_policy=VALIDATED_INCUMBENT_ONLY |

**Locations and tokens.**
- Locations and source tokens must come from the trusted producer, never from a client assertion.
- `authorized_pickup` is the canonical donor pickup or the selected hub location; `pickup` also reflects the persisted task node. A mismatch excludes the task.
- An operational producer must separately reject stale node mappings.

**State tokens.**
- The database has listing_version, batch_version and NGO location_generation, but no native task/claim/lease/donation version counters.
- For those records, `state_token` is the SHA-256 of a documented canonical projection of source fields, not an invented version number.
- The producer must freeze that projection and recompute the tokens at dispatch.
- Lease timestamps use database time. Task created_at can be slightly earlier than lease issued_at, because DEV uses transaction `now()` and wall-clock `clock_timestamp()` respectively.

**Vehicles and costs.**
- All vehicle costs in one scenario use configuration.currency. Costs may be explicitly zero.
- Capacities and maximum durations must be positive, and a vehicle's maximum duration cannot exceed the scenario horizon.
- An inconsistent fleet owner or depot rejects the input.
- Inactive or unavailable vehicles stay in the frozen evidence but are left out of available_vehicle_ids.
- No synthetic fallback is generated for an empty fleet.

</details>

<details>
<summary><b>Admission rules</b> (which tasks may be planned)</summary>

Admission collects **all** applicable typed exclusion reasons for each structurally valid candidate. Malformed records reject the whole input instead of being silently discarded. The producer should keep malformed-source diagnostics in its own acquisition log; the contract does not invent absent source evidence.

1. The NGO is active and has a verified depot at or before the cutoff.
2. The task owner and the claim owner both equal the requesting NGO.
3. The task is CONFIRMED, the listing is CLAIMED, and the claim and lease are ACTIVE.
4. The task and lease were not created after the cutoff, and the lease interval is valid.
5. The lease expires strictly after cutoff + planning horizon + dispatch margin. Equality is rejected, because DEV treats expiry at the current time as invalid. A finite listing expiry must also exceed this conservative authority horizon. (Under v2, per-task lease admission applies; see [Planner and validator](#planner-and-validator).)
6. There is no unresolved reconciliation and no existing route assignment.
7. The task pickup equals the authorised pickup, and the task load equals the listing load.
8. Every original donation is CLAIMED. A hub batch is PUBLISHED with BATCHED inventory and an exact member set. No obsolete donation states are accepted.
9. The source window has enough remaining time for the service, even before travel.
10. The matrix covers the depot and all admitted pickup nodes on one graph version.

The cutoff + horizon policy is deliberately conservative. Later independent validation also checks actual arrival, service completion and return, cumulative load, per-vehicle duration, mandatory tasks, exactly-once accounting and current authority.

The producer must:
- derive `reconciliation_blocked` from OPEN/MANUAL_REVIEW cases for the claim/listing and the relevant batch members, not just from a lease status string;
- derive `has_route_assignment` from active assignments and relevant route stops;
- establish current source consistency, complete membership, verified nodes and no foreign records through protected joins before accepting the snapshot.

</details>

<details>
<summary><b>Matrices and unavailable arcs</b></summary>

Each matrix supplies matrix_id, version, network_snapshot_id, source_kind, provenance, method, edge_speed_profile, path_policy, unavailable_policy, node_order, distance_km, travel_minutes and arc_status.

- **Shape and path.**
  - Distance (km) and time (minutes) are square directed arrays indexed by node_order.
  - The fixed path policy is `DIRECTED_SHORTEST_DISTANCE_WITH_TIME_ON_SAME_PATH`. The distance and time for one OD cell describe the **same** path; minimising distance and time separately and pairing the results is invalid.
  - The parser validates the declaration and shape; acquisition must prove the path provenance.
- **Cells.**
  - Each cell is AVAILABLE, with a finite positive off-diagonal distance/time (self arcs are zero), or explicitly UNREACHABLE/MISSING, with paired JSON nulls.
  - An omitted row or cell is malformed. Null never becomes zero, infinity, a straight-line distance or a guessed speed.
  - MISSING records incomplete or failed acquisition. UNREACHABLE requires an actual no-path result on the declared graph.
- **Operational vs benchmark.** Operational matrices require OSM-OPS identifiers and positive numeric OSM node strings. Benchmark matrices cannot be silently relabelled as operational.
- **`FAIL_SCENARIO`** returns `ROUTE_UNAVAILABLE` for any unavailable required OD arc.
- **`FORBID_ARC`** keeps the arcs as forbidden for every later method and the validator. `READY_FOR_PLANNING` does not promise that a feasible route exists. Neither missing nor unreachable arcs may be traversed. The operational policy still needs approval; the fixtures use `FAIL_SCENARIO`.

</details>

<details>
<summary><b>Synthetic test fixtures</b></summary>

Every fixture is explicitly `SYNTHETIC_BENCHMARK` and project-free. All task, vehicle, location, token, capacity, cost and timestamp values are fictional; the fixtures imply no operational fleet or service policy.

`tests/generate_fixtures.py` declares a three-vertex directed line graph:

| Directed edge | km | minutes |
|---|---:|---:|
| TOY-DEPOT → TOY-DONOR | 2 | 4 |
| TOY-DONOR → TOY-DEPOT | 2.5 | 5 |
| TOY-DONOR → TOY-HUB | 3 | 6 |
| TOY-HUB → TOY-DONOR | 3.5 | 7 |

How the fixture graphs are derived:
- The unique directed path between each pair is the sum of those edges. Coordinates are fictional labels and are never used to estimate roads.
- Forward depot → hub is 5 km / 10 minutes; reverse is 6 km / 12 minutes.
- The *unreachable* fixture removes both directed edges incident to the hub, gives the graph its own version and records all four disconnected OD pairs as UNREACHABLE.
- The *missing* fixture keeps the connected graph but masks one acquisition cell as MISSING.
- Both derivations are recorded in provenance.

The nine checked-in fixtures cover: mixed, direct and hub tasks; zero vehicles; no tasks; expired authority; reconciliation; unreachable; and missing matrix data.

The 240-minute horizon, 10-minute service, 10-minute margin and example costs are explicit toy parameters; the margin and fleet values are not approved defaults. The fixtures' solver version is `NOT_INSTALLED_PHASE_A`, because they predate the OR-Tools dependency.

Regenerate them deliberately with `python -m backend.routing.tests.generate_fixtures`. The `--check` option verifies exact reproducibility without writing.

</details>

## Errors, retries and recovery

- **What the planner accepts.** `POST /v1/plan` takes only `{request_id, snapshot_id}` with the NGO's bearer token. Client-supplied plans, NGO IDs and success flags are rejected.
- **Journal first.**
  - The journal (`service/journal.py`) saves the exact matrix and plan payloads **before** any database write.
  - Deterministic request IDs and OS locks handle duplicates, crashes and lost replies.
  - The journal lives in the environment's `state` folder.
- **What to retry.** Repeat the same request after a retryable error. After a stale or conflict error, create a new snapshot.
- **Infeasible results** contain the real engine comparisons and no candidate.
- **Missing or unreachable road arcs** fail closed before a matrix is stored.
- **Database failures stay failures.** An authorisation failure in PostgreSQL is returned as a failure or as an unknown outcome, never as a success.
- **Safe error reports.** Failures reach the app as error codes through `service/safe_failure.py`, never as secrets or raw error text.

Error codes you may see:

| Code | Where | Meaning |
|---|---|---|
| `NO_VALID_TASKS`, `NO_FEASIBLE_PLAN`, `ROUTE_UNAVAILABLE` | contract | See [Readiness outcomes](#readiness-outcomes-and-cli-exit-codes) |
| `INVALID_INPUT` | CLI | Malformed scenario or file error (exit code 2) |
| `FOREIGN_GRAPH_CACHE_PRESENT` | graph cache | The cache folder holds another graph's files |
| `TRUSTED_VALIDATION_REQUIRED` | database | The attestation report has no `validator_build` |
| `WORKER_NOT_ACTIVATED` | worker HTTP (503) | The worker was started without `-Activate` |
| `COMBINED_WORKFLOW_DISABLED` / `EXACT_WORKFLOW_DISABLED` | planner HTTP (503) | An optional endpoint the current app does not use (`/v1/plan-and-authorize`, `/v1/exact-route-*`) was called while it was switched off |
| `VALIDATION_CONFLICT` | database | A replayed attestation differs from the stored one (for example a changed build ID) |
| `TLS_REQUIRED_FOR_EXTERNAL_BIND` | planner HTTP (503) | A non-loopback address was requested without a certificate |

## Offline tests

No Supabase connection is needed. Run from the repository root:

```powershell
& .\.venv-stage8\Scripts\python.exe -B -m unittest discover -s backend/routing -t . -v
python -m unittest discover -s backend/routing/tests -t . -v               # tests/ folder only
python -m backend.routing backend/routing/tests/fixtures/mixed.json        # check one scenario
python -m backend.routing.tests.generate_fixtures --check                  # fixtures are reproducible
```

The unit tests cover positive and adversarial cases, hashes, immutability, exclusions, CLI outcomes, the planner and validator, road matrices, the snapshot, the Flutter response shape, the services and the Windows helpers. Some tests need Windows (the native libpq 17 client, the pinned CA file, Windows SQLite behaviour); on Linux they fail or are skipped.

## Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| The worker connects to the wrong project | `-Environment` left out, so DEV was used | Pass `-Environment KLSEL` |
| `Run Save-WorkerConfig.ps1 -Environment … first.` | No profile for that mode/environment | Run `Save-WorkerConfig.ps1 -Environment KLSEL` |
| `pg_service.conf missing in …` | The KLSEL service profile was not written | Rerun `Save-WorkerConfig.ps1 -Environment KLSEL` |
| `… accepts only its own frozen graph …` | A different `-GraphId` was passed for KLSEL | Remove `-GraphId`; KLSEL sets it automatically |
| `FOREIGN_GRAPH_CACHE_PRESENT` | Another graph's cache is in the state folder | Never copy DEV's cache; build KLSEL's with `-WarmGraph -ApprovalRef <ref>` |
| `Activation requires an explicit approved change reference.` | `-Activate` without `-ApprovalRef` | Add `-ApprovalRef <ref>` |
| Every request fails with `WORKER_NOT_ACTIVATED` | The worker was started without `-Activate` | Restart it with `-Activate -ApprovalRef <ref>` |
| App says the planner is not ACTIVE for the intended project | The app build and the worker target different projects (for example a DEV worker with a KLSEL build) | Start the workers with `-Environment KLSEL` and build the app with `klsel-config.json` |
| A route is generated but cannot start | Not attested yet, failed validation, expired (60 minutes) or stale | Check that the validator is running; generate again with a new snapshot |
| Tests fail on Linux | Windows-only native client tests | Run them on Windows with `.venv-stage8` |

## Protected files and safety rules

| File | Why it is protected |
|---|---|
| `contract.py`, `validator/validation.py`, `snapshot.py` | Their exact bytes, including line endings, form the `validator_build` fingerprint recorded in every attestation. They also define what a valid input and a valid route are. Change them only as a reviewed change, and expect a new build ID. Finish or reconcile unfinished requests first, because replaying an attestation with a different build ID raises `VALIDATION_CONFLICT`. |
| `route_plan.py`, `environment.py`, `planner/`, `road_network/`, `validator/` | Imported by relative path from the protected files; moving them breaks those imports |
| `environment.py` frozen-graph registry | Changing it points the workers at a different road network |
| `windows/*.ps1`, `windows/*.sql` | Encrypted profiles, key rotation and database role templates. These are security controls, not throwaway scripts |
| `.gitignore` | Keeps `.env*`, local state, journals, lock files and SQLite files out of Git |

Never put passwords, keys, tokens or DSNs in this folder. Database passwords never pass through PowerShell variables or environment variables; they are typed at a hidden console prompt.

## Where things moved (20 Nov 2026 restructure)

Only file locations and import lines changed; routing behaviour did not. Older documents under `docs/` still use the old paths. On 22 Nov 2026, the former `CONTRACT.md` and `ENVIRONMENTS.md` were merged into this README.

| Old path | New path |
|---|---|
| `contracts/__init__.py`, `integration/__init__.py`, `optimizers/__init__.py` | removed (they only re-exported other modules) |
| `generate_examples.py` | `tests/generate_fixtures.py` |
| `optimizers/models.py` | `route_plan.py` |
| `integration/worker.py` | `snapshot.py` |
| `integration/graph_worker.py`, `planner/matrices.py`, `worker_service/graph_cache.py` | `road_network/graph_export.py`, `road_network/matrix.py`, `road_network/graph_cache.py` |
| `planner/orchestration.py` | `planner/planning.py` |
| `optimizers/cp_sat.py`, `baselines.py`, `methods.py`, `problem.py` | `planner/` (same names) |
| `worker_service/transport.py`, `native_service_connection.py`, `connection_diagnostic_native17.py`, `password_transport_check.py` | `database/supabase_rpc.py`, `native_connection.py`, `libpq_client.py`, `password_input.py` |
| `worker_service/native_worker.py`, `server.py`, `orchestrator.py`, `validator.py` | `service/start_worker.py`, `http_api.py`, `planner_service.py`, `validator_service.py` |
| `worker_service/staged.py`, `staged_client.py` | `service/exact_pilot.py`, `exact_pilot_client.py` |
| `integration/presentation.py`, `route_resolution.py` | `service/flutter_response.py`, `route_resolution.py` |
| `worker_service/journal.py`, `errors.py`, `probe_diagnostics.py` | `service/journal.py`, `errors.py`, `safe_failure.py` |
| `worker_service/connection_diagnostic.py`, `native_service_diagnostic.py`, `native_service_probe.py`, `native_readonly_session.py`, `readonly_pilot_probe.py`, `probe_resources.py` | `diagnostics/connection_check.py`, `native_service_check.py`, `graph_probe.py`, `readonly_session.py`, `pilot_benchmark_probe.py`, `probe_resources.py` |
| `worker_service/windows/*`, `worker_service/requirements*.txt` | `windows/*`, `requirements*.txt` |
| `worker_service/tests/*`, `integration/tests/*` | `tests/service/*`, `tests/*` (`test_worker.py` → `test_snapshot.py`) |
| `CONTRACT.md`, `ENVIRONMENTS.md` | merged into this README (22 Nov 2026) |
| `worker_service/windows/Start-Worker.ps1` (compatibility forwarder) | removed (22 Nov 2026); use `windows/Start-Worker.ps1` |
| `requirements-lock.txt` | merged into `requirements.txt` (22 Nov 2026; same exact pins) |

`python -m` module names follow the file moves. For example, `backend.routing.worker_service.readonly_pilot_probe` is now `backend.routing.diagnostics.pilot_benchmark_probe`.

The exact source bytes that the published E4 results recorded are kept in `experiments/e4/experiment_result/published_provenance/e4_sources/`.
