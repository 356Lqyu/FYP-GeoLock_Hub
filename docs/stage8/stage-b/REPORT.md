# Stage B disposable verification and RoutingModel integration

**PARTIAL.** The forward routing package compiles and executes in disposable
PostgreSQL; one authorized direct pickup reaches COLLECTED and depot closure.
Full geospatial/Supabase integration, actual Flutter-to-backend acceptance and
formal solver reproducibility remain open. No Supabase connection, deployment,
live fixture, actual cron change or Chapter 5 experiment was performed.

## Environment and scope

Windows 11 build 22621; PostgreSQL 17.11 x64; Python 3.12.14; pinned OR-Tools
9.15.6755; Flutter 3.44.9, Dart 3.12.2 and DevTools 2.57.0. PostGIS and pgRouting
control files are absent from the installed PostgreSQL 17 extension directory.
Neither extension was installed or verified; test-cluster extension: plpgsql 1.0.

Each run creates a fresh temporary cluster: trust authentication, loopback only,
random port, separate cloned database per test, stripped connection environment
and restricted local subprocess arguments. Cleanup stops/removes its owned
cluster; raw evidence remains. The full public business-schema snapshot produces
183 public constraints and 28 non-internal triggers. Auth identity GUCs, Storage
catalog, road resolution/eligibility and cron catalog are explicit **doubles**.
The graph is a fictional two-node directed fixture, with 1 km/1 minute edges
both ways. The existing graph worker builds its matrix from the frozen database
export. This verifies plumbing, not geographic accuracy. No real scheduler runs.

Storage policies, JWT verification, PostgREST and extension-backed geographic
behavior remain unverified. The harness explicitly grants authenticated local
creation/discovery/claim RPC access; that is fixture setup, not deployed-ACL
evidence. Private-role/direct-table denial tests use actual PostgreSQL permissions.

## SQL installation and confirmed defect

Exact order in `supabase/tests/stage8_stage_b_isolated_test.py`:

1. Local Auth/Storage/bootstrap doubles.
2. `geolock-v3-public-schema.sql` (psql restrict directives removed).
3. Explicit synthetic road/eligibility/cron prerequisites and generation columns.
4. `supabase/migrations/20261019_stage1_claim_recovery_and_reconciliation.sql`.
5. `supabase/migrations/20261027_persisted_donation_lifecycle.sql`.
6. `supabase/migrations/20261029_fix_claim_recovery_listing_expiration_race.sql`.
7. `supabase/migrations/20261030_fix_claim_recovery_unresolved_reconciliation.sql`.
8. `supabase/migrations/20261031_claim_audit_and_failure_capture.sql`.
9. Captured vehicle-depot prerequisite/trigger and exact captured
   `assign_task_to_route` prerequisite from existing preparation evidence.
10. `docs/stage8/phase-c1/proposed_migration_v2.sql`.
11. `docs/stage8/stage-a/forward-migrations/20261101_routing_authority.sql`.
12. `docs/stage8/stage-a/forward-migrations/20261102_routing_publication.sql`.
13. `docs/stage8/stage-a/forward-migrations/20261103_routing_pickup_and_reconciliation.sql`.

This is snapshot-plus-current-lifecycle compatibility installation, **not** a
chronological replay of every migration. The scheduler migration is not applied.
`results/stage-b/attempt-07/applied.json`, operations.jsonl and postgresql-server.log record
file/statement hashes, errors, timings and server execution. The harness source
contains the exact fixture SQL and grants. Claim/recovery source pins remain
equal to reviewed 20261031 bodies. The six-argument transition helper and pickup/
reconciliation audit contracts execute successfully. Historical migrations were
not edited.

Actual PostgreSQL found a Stage A dependency bug: 003 checked the old assignment
fingerprint after 002 replaced that function. The builder now checks the original
exact DDL in 001 and the expected source/security derived from unchanged 002 in
003. No observed database hash was adopted. An offline regression checks both
guards. Old manifest/003 are retained under `results/stage-b/stage-a-v1`;
historical Stage A 192-test evidence remains unchanged. Current offline evidence
is saved separately under Stage B.

## Actual direct workflow

`results/stage-b/attempt-07/direct-workflow.json` records fixture UUIDs, creation/
claim request IDs, committed rows, audit IDs/details and transaction linkage.
One participating NGO, donor, direct 20 kg donation, task, vehicle, depot and
route are used. A second synthetic NGO exists for negative authorization tests.

Protected photo-backed creation makes AVAILABLE; discovery and atomic claim
create CLAIMED, one ACTIVE claim/360-minute lease and a CONFIRMED task. Claims,
leases and tasks in this path come from the protected RPC, not direct inserts.
Graph freeze/export, matrix construction, snapshot seal, actual four-method
planning, independent validation and attestation precede NGO authorization.
Planning alone creates no route or task permit. Authorization creates the route
and exclusive holds. Fresh authorized route detail precedes pickup start and
completion. Donation becomes PICKUP_IN_PROGRESS then COLLECTED; listing CLOSED,
claim/lease COMPLETED, task COLLECTED. Explicit depot-return confirmation changes
route to its actual terminal enum COMPLETED and releases the vehicle hold.
Three donation-status events contain correct claim/lease IDs and transaction IDs.
No operation renews the lease.

Negative/reconciliation tests manipulate only fresh disposable fixture state.
The expiry/recovery fixture preserves CHECK constraints and the six-hour lease
duration; it is not evidence of waiting six real hours.

## Security, rollback and concurrency

The 31 actual database tests cover unrouted pickup, forged identifiers, cross-NGO
route access, private-helper denial, invalid attestation binding, tampered
schedule despite trusted attestation, stale vehicle/source, absent/expired lease,
direct task-write denial, repeated start/complete, changed request replay,
exclusive holds, immutable artifacts and required-audit rollback. They exercise
publication idempotency, both cancellation/start lock orders, reconciliation
serialization, duplicate final evidence, cancellation/completion during
reconciliation and depot closure waiting for reconciliation commit.

Resolved reconciliation replays saved responses without duplicate audits;
conflicting evidence cannot mint collection authority; planned tasks cannot be
collected through reconciliation. Recovery retains reserved tasks and requires
reconciliation. Audit failure rolls back business and permit changes together.

These tests do not establish exhaustive deadlock freedom. Recovery-versus-pickup
race, released-claim negatives, whole-batch/legacy cutover, all SQL-level capacity/
window/duration negatives, deployed ACL parity, real JWT and actual crash/network
loss remain open. Solver/validator capacity/window/duration/missing-arc tests do
not replace the unexecuted SQL authorization negatives.

## RoutingModel

The exported primary `proposed` now uses `phase_b/routing_model.py` with actual
OR-Tools RoutingModel, PATH_CHEAPEST_ARC and GUIDED_LOCAL_SEARCH. Native CP search
is single-threaded; CP-SAT/generalized fallback is disabled. The pinned API has
no supported RoutingModel random-seed parameter. Legacy CP-SAT seed/deterministic
work budgets are not translated; `deterministic_seconds_per_pass` is explicitly
unused by this engine. Original `optimizers.py` remains intact, including its
historical proposed method and distance-only baseline. FCFS/Nearest-Next remain.

Snapshot, Plan, candidate, validator and authority schemas are preserved. A shared
per-snapshot wall budget covers model construction/search: coverage first, then
fixed-plus-distance cost at the found coverage. Partial coverage is not proven
maximum. Full coverage proves the count optimum; GLS does not claim a secondary
optimum/gap. Actual native statuses and runtime are recorded. No-incumbent failure,
timeout and proven infeasibility are distinguished by status, timeout,
infeasibility_proven and solver_statuses. Missing arcs are removed, never assigned
fictitious costs. Directed travel, capacity, windows, lease margin, service,
vehicle duration and depot return are enforced. Unsupported precision is rejected.
Independent validation remains mandatory; solver output grants no authority.

Unit tests use explicit 0.1/0.2-second profiles; database tests use one second.
`results/stage-b/routingmodel-report-profile.json` separately records an actual
synthetic one-task run with the report's 30-second upper bound, 240-minute maximum
and 10-minute service. Early termination is allowed; actual runtime is recorded.
These runs are not formal Chapter 5 samples.

Fixed toy replay passes, but broader short-budget benchmark replay exhibited
NONREPRODUCIBLE_RESULT. That hard guard remains unchanged. Historical CP-SAT
proof/repeat tests explicitly retain that engine and do not prove RoutingModel
determinism. The report-compatible repeat/seed/configuration policy is a formal
experiment blocker. Benchmark manifests now identify each method's actual engine
instead of labelling every method CP-SAT. No approved baseline was rewritten.

## Flutter

Inspected `lib/routing/ngo_routing_repository.dart`, `ngo_routes_page.dart`,
session/fleet/worker components and claim navigation. Existing RPC names,
parameters and response shapes align with the locally exercised SQL contracts.
The worker regression spies on actual RoutingModel SolveWithParameters and checks
the returned wire plan; its transport is mocked, not Flutter calling PostgreSQL.

67 Flutter tests pass for routing/worker/claim/status/road screens and repository
behavior. Analyzer: no issues. Coverage includes backend missing/fail-closed,
unvalidated/unauthorized candidates, stale or expired/session-invalidated actions,
meaningful errors, retries, authoritative refresh and depot confirmation. Route
detail reloads after both successful and uncertain actions and retains errors.
No Flutter production file needed a Stage B change.

No local Auth/PostgREST/Storage gateway links a running Flutter app to this cluster.
Real device/browser UI, tokens, worker/validator HTTP/TLS, CORS and process-restart
recovery remain unverified.

## Results and reproduction

Final suites: **372 passed, 0 failed, 0 skipped**: 193 offline contracts, 81 Python
routing/worker, 31 real PostgreSQL and 67 Flutter. Analysis also passes. Commands,
source hashes and counts are in `results/stage-b/verification.json`. Earlier
attempts are retained and not added to the final total: token87 startup blockage,
captured prerequisite mismatch, guard-order defect, fixture expiry/timestamp/lead
time errors and invalid CP-SAT-specific expectations on RoutingModel.

Run from repository root (use a new evidence directory each database run):

```powershell
.venv-stage8/Scripts/python.exe -B docs/stage8/stage-b/run_offline.py
.venv-stage8/Scripts/python.exe -B -m unittest backend.routing.phase_b.tests.test_algorithms backend.routing.phase_b.tests.test_validation backend.routing.phase_b.tests.test_routing_model backend.routing.worker_service.tests.test_solver_invocation -v
.venv-stage8/Scripts/python.exe -B supabase/tests/stage8_stage_b_isolated_test.py --run-isolated --output-dir results/stage-b/NEW-UNUSED-DIRECTORY
```

Windows pg_ctl required permission to start a fresh loopback child process.
Flutter used installed Dart/flutter_tools.snapshot with --no-version-check
--suppress-analytics, analyze --no-pub and test --no-pub --reporter expanded on
ngo_routing, routing_worker_client, claim_request, claim_card, donation_status and
road_routing test files. This bypassed a hanging launcher/cache lock; no packages
were downloaded.

## Remaining work and Stage C

First complete local PostGIS/pgRouting and real gateway acceptance, current
whole-batch/legacy/recovery race coverage, remaining SQL negatives and the formal
RoutingModel repeat/configuration policy. Then a separately approved Stage C
could perform **read-only DEV inventory/comparison only**: functions, roles,
graph/depot prerequisites, cutover tasks and unresolved historical records.
No deployment, fixture, worker activation, recovery or experiment is authorized.
Existing zero-overdue guards and historical evidence remain unchanged. Stop here.

`CHAPTER5_READINESS.md` updates all eight tracks; `changed-files.json` lists exact
Stage B files/hashes. Stage A runtime-unverified statements are superseded only
within this report's explicitly limited local scope.
