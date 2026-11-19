# GeoLock Hub routing

This folder plans pickup routes for an NGO's vehicles and makes sure no route is driven unless it has been checked.

The route itself is built by **Google OR-Tools CP-SAT**. It first collects as many pickup tasks as possible, then keeps the road distance as low as possible. A separate **validator** process re-checks every route on its own. **PostgreSQL (Supabase) alone** decides whether a checked route may start.

```
Flutter "Generate Route"
   → planner service     reads the sealed database snapshot, builds road matrices, runs FCFS,
                         nearest-neighbour and CP-SAT, stores the CP-SAT candidate
   → validator service   rebuilds the input from the database and checks the candidate again,
                         then attests its digest
   ← attested candidate, valid for 60 minutes (advisory only: nothing is reserved yet)

Flutter "Start Route"    authorize_and_start_my_route (database RPC, one transaction):
                         authorises the candidate at "now" and dispatches the first stop
Each stop                start_pickup → complete_pickup (database RPCs)
Close                    close_my_collected_route / close_my_resolved_route
```

## Folders

```
backend/routing/
├── README.md               this file
├── CONTRACT.md             full specification of the sealed routing input (fields, admission rules, matrices)
├── requirements.txt        worker dependencies (psycopg) + the lock file below
├── requirements-lock.txt   pinned Python 3.12 environment, including OR-Tools 9.15.6755
├── __main__.py             python -m backend.routing <scenario.json>: check one scenario file
├── contract.py             the routing input contract: schema, admission rules, freeze and digest
├── route_plan.py           Plan / Route / Stop / ExecutionConfig, shared by the planner and the validator
├── snapshot.py             sealed database snapshot → planner input; decodes stored plans
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
│   └── validation.py       recomputes windows, loads, capacity, duration and distance from the sealed input
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
│   ├── exact_pilot.py      opt-in exact-scope pilot workflow
│   ├── exact_pilot_client.py  operator client for that pilot (used by scripts/Run-ExactV3Pilot.py)
│   ├── flutter_response.py   shapes results for the Flutter app (never a dispatch response)
│   ├── route_resolution.py   default-disabled route-resolution adapter
│   ├── journal.py          crash-resumable local SQLite journal (safe retries and recovery)
│   ├── errors.py           WorkerError and check()
│   └── safe_failure.py     redacted failure reports (no secrets or raw error text)
├── diagnostics/            read-only connection checks and probes; they never start a service
├── windows/                Windows setup, launch and operator checks (PowerShell)
│   ├── Save-WorkerConfig.ps1   save encrypted planner/validator profiles (once)
│   ├── Start-Worker.ps1        start, check config or check connection
│   ├── Prepare-WorkerCache.ps1, Test-LocalRoutingSetup.ps1, Update-PlannerPublishableKey.ps1, ...
│   └── create_worker_logins.manual.sql, verify_worker_roles.readonly.sql
├── worker_service/windows/Start-Worker.ps1   forwarder kept so the old command still works
└── tests/                  offline tests (no Supabase connection)
    ├── fixtures/           9 synthetic scenarios; tests/generate_fixtures.py makes them
    ├── test_*.py           contract, planner, validator, road matrices, snapshot, Flutter shape
    └── service/test_*.py   services, database adapters, diagnostics, Windows helpers
```

## How the parts work together

| Part | Runs as | Database login (role) | Allowed RPCs |
|---|---|---|---|
| Planner service | `Start-Worker.ps1 -Mode planner` (port 8787) | `geolock_planner_login` | `read_pending_routing_snapshot`, `read_routing_snapshot_bundle`, `seal_routing_snapshot`, `submit_routing_candidate` |
| Road network (inside the planner) | same process | `geolock_graph_login` | `read_frozen_routing_graph`, `store_routing_matrix` |
| Validator service | `Start-Worker.ps1 -Mode validator` (port 8788) | `geolock_validator_login` | `read_routing_work_item`, `attest_routing_candidate` |
| Authorisation, dispatch, detach, recovery | **database only** (called by Flutter as the NGO) | NGO JWT | `authorize_and_start_my_route`, `start_pickup`, `complete_pickup`, `detach_my_unstarted_stop`, `recover_expired_claims` (cron) |

Further rules:
- **No dispatch from the worker.** The planner never grants route authority, and no worker endpoint can dispatch, claim, pick up or write tables directly.
- **Attestation only after validation.** A candidate is `ATTESTED` only after the validator, with its own login, re-reads the work item and checks it.
- **Validator fingerprint.** The validator signs its report with `validator_build`, a SHA-256 of `contract.py` + `validator/validation.py` + `snapshot.py`.
- **Per-task lease admission (Phase 2).** Under policy v2, a task is admitted when its lease outlasts the time needed to reach and serve it, plus the margin. The rule is identical in Python (`contract.py`, scenario v2) and SQL.
- **Detachment.** A future stop whose lease becomes too short can be detached with `detach_my_unstarted_stop`. The claim stays active and can be planned again.

## Start the planner and validator (Windows)

Full setup, USB and shutdown steps are in [docs/LOCAL_ROUTING_WINDOWS.md](../../docs/LOCAL_ROUTING_WINDOWS.md). Start from the repository root:

```powershell
# once: Python 3.12 environment and encrypted profiles
& .\.venv-stage8\Scripts\python.exe -m pip install -r .\backend\routing\requirements.txt
.\backend\routing\windows\Save-WorkerConfig.ps1

# safe checks (no activation)
.\backend\routing\windows\Start-Worker.ps1 -Mode validator -CheckConfig
.\backend\routing\windows\Start-Worker.ps1 -Mode planner   -CheckConfig
.\backend\routing\windows\Start-Worker.ps1 -Mode validator -CheckConnection
.\backend\routing\windows\Start-Worker.ps1 -Mode planner   -CheckConnection

# start (validator first, each in its own window)
.\backend\routing\windows\Start-Worker.ps1 -Mode validator -Activate -ApprovalRef $validatorApproval
.\backend\routing\windows\Start-Worker.ps1 -Mode planner -GraphId $graphId -Activate -ApprovalRef $plannerApproval -EnableCombinedWorkflow
```

The old path `.\backend\routing\worker_service\windows\Start-Worker.ps1` forwards to the new one with the same parameters. Profiles and worker state stay in `%LOCALAPPDATA%\GeoLockHubRoutingDev`.

## Run the offline tests

```powershell
& .\.venv-stage8\Scripts\python.exe -B -m unittest discover -s backend/routing -t . -v
python -m backend.routing backend/routing/tests/fixtures/mixed.json        # check one scenario
python -m backend.routing.tests.generate_fixtures --check                  # fixtures are reproducible
```

Some tests need Windows (the native libpq 17 client, the pinned CA file, Windows SQLite behaviour). On Linux they fail or are skipped.

## Retries and failures

- **What the planner accepts.** `POST /v1/plan` takes only `{request_id, snapshot_id}` with the NGO's bearer token. Client-supplied plans, NGO IDs and success flags are rejected.
- **Journal first.** The journal saves exact matrix and plan payloads **before** any database write. Deterministic request IDs and OS locks handle duplicates, crashes and lost replies.
- **What to retry.** Repeat the same request after a retryable error. After a stale or conflict error, create a new snapshot.
- **Infeasible results** contain the real engine comparisons and no candidate.
- **Missing or unreachable road arcs** fail closed before a matrix is stored.
- **Database failures stay failures.** An authorisation failure in PostgreSQL is returned as a failure or as an unknown outcome, never as a success.

## Where things moved (20 Nov 2026 restructure)

Only file locations and import lines changed; routing behaviour did not. Older documents under `docs/` still use the old paths.

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

`python -m` module names follow the file moves. For example, `backend.routing.worker_service.readonly_pilot_probe` is now `backend.routing.diagnostics.pilot_benchmark_probe`.

The exact source bytes that the published E4 results recorded are kept in `experiments/e4/experiment_result/published_provenance/e4_sources/`.
