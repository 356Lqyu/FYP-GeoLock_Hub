# Generate and authorize routing workflow

28 October 2026. LOCAL IMPLEMENTATION ONLY. Supabase DEV was not contacted,
services were not restarted, no APK was built/installed, and no DEV snapshot,
candidate, route, pickup or recovery operation was executed.

## User workflow and authority

NGO selects its vehicle(s), then presses **Generate & Authorize Route**. The
application preserves a single operation before requesting a snapshot. The worker
plans with the unchanged four-method research pipeline and publishes only the
Proposed result to the NGO. A separate validator must attest the Proposed
candidate. The combined orchestrator then requests PostgreSQL authorization using
the verified NGO JWT, not a worker/service-role identity. Only a committed database
receipt followed by an owned route read opens the authorized route screen.

There is no time picker or second manual authorization button. Opening an old
saved candidate remains advisory and cannot authorize it. The earlier physical
Android demonstration and its candidate/evidence remain historical, unchanged.
The new combined workflow has LOCAL test evidence, not physical DEV pilot evidence.

Start Pickup invokes the existing protected start_pickup for the first eligible
stop only. The next stop cannot start while a pickup is unresolved. Each actual
handover uses complete_pickup with confirmation; closure requires confirmed depot
return through close_my_collected_route. Generation/authorization do not change
donation custody. Authorization reserves tasks/vehicles and marks tasks PLANNED.

## Time contract

New forward migration:
`docs/stage8/stage-a/forward-migrations/20261104_routing_automatic_departure.sql`.

The existing authorize_my_routing_candidate(uuid,uuid,timestamptz) signature stays.
An explicit non-null departure retains its original checks, request hash and
two-field receipt. Explicit NULL now means AUTO_NOW: the database chooses its
clock_timestamp after source and vehicle locks, before constructing route rows.
The same chosen time is used for all routes in that authorization transaction.
This is a declared new contract, not a client-clock estimate or tolerance bypass.

The automatic request hash binds candidate + AUTO_NOW semantics; it does not hash
a new timestamp on every retry. Replaying the same request returns the original
committed receipt and departure. Changing candidate/mode under that request is a
conflict. Automatic receipts add snapshot_id, departure_mode and planned_departure_at.
Historical candidate plans remain nominal at snapshot cutoff; PostgreSQL retimes
only its bound authorized route copy. Display authoritative retimed route totals.

Actual first start remains routing_private.bindings.started_at. Per-stop start
remains items.consumed_at. These are not set by authorization and are not replaced
by planned departure. Existing start_pickup revalidates the remaining ordered
route against current task/claim/lease/vehicle/depot state, windows, return, duration
and dispatch margin. Waiting cannot extend a claim or snapshot horizon. The first
actual start anchors route-duration consumption; subsequent delays consume it.

## API contract

All planner operations require the real NGO bearer JWT and existing Supabase
verification. Worker database roles gain no new permissions.

| Endpoint | Body | Effect |
|---|---|---|
| POST /v1/plan | request_id, snapshot_id | Existing planning only; never auto-authorizes |
| POST /v1/planning-result | request_id, snapshot_id | Existing owned saved advisory read |
| POST /v1/authorize | request_id, candidate_id, departure_at | Existing explicit-departure request |
| POST /v1/authorization-capabilities | request_id | Owned read; confirms SQL contract and combined activation flag before snapshot creation |
| POST /v1/plan-and-authorize | request_id, snapshot_id, authorize_on_success=true | Explicit combined action; disabled by default |
| POST /v1/authorization-result | request_id, snapshot_id | Read-only receipt reconciliation; never plans or authorizes |

An authorized envelope has kind DATABASE_AUTHORIZATION_RECEIPT, NGO/snapshot/root
request IDs, stable authorization_request_id and the exact database authorization
receipt. Flutter independently reads each returned route ID and checks its owner,
candidate and snapshot binding before display. A displayed receipt is not itself
a Start Pickup permission: current owned read flags and the protected RPC govern.

An infeasible response remains ADVISORY_CANDIDATE/INFEASIBLE with no authorization.
An absent receipt returns AUTHORIZATION_UNCONFIRMED. NOT_FOUND is not proof of
rollback: an earlier transaction might still be in flight. A durable known
rejection or infeasible result may supply operation_terminal REJECTED/INFEASIBLE.
Timeouts and transport/uncertain commit failures are never converted to that proof.

get_my_routing_authorization_receipt(p_request uuid) is a new STABLE, owner-scoped
read-only RPC. It requires an active NGO and exposes only that NGO's request row.
PUBLIC, anon, service_role and worker roles cannot execute it. It returns contract
geolock.routing-auto-now.v1, ngo_id, request_id and FOUND/result or NOT_FOUND.

## Persistence, concurrency and recovery of responses

Flutter stores request/policy/vehicle IDs, phase and status in the per-NGO
ngo_route_operation key before business requests. It does not store JWTs/passwords.
The legacy saved-planning key remains intact. Repeated taps share the in-flight
operation. An app restart cannot mint a replacement while one is unresolved.

The backend derives its authorization UUID with uuid5(snapshot UUID,
"geolock-worker-v1:authorize-auto-now"). A cross-process operation lock prevents
parallel orchestration. Intent and the exact NULL-departure payload are persisted
before authorization. PostgreSQL actor locks, request ledger and reservation
checks remain the final cross-process/database idempotency boundary.

After a lost response, use **Check authorization outcome (read only)**. A found
receipt loads the existing routes. An absent receipt retains uncertainty. Only
the explicit **Resume same operation** action can resend the identical operation;
it reads first and never creates a different authorization UUID or silently
regenerates a completed candidate. Known terminal rejections are not resubmitted.

**Start another operation after reconciliation** archives local context only when
all authorized routes are COMPLETED/CANCELLED, or the backend proves a terminal
rejection/infeasibility with no committed receipt. An unresolved snapshot/commit
cannot be cleared. A known preflight failure before any snapshot can be archived.
This does not delete database/journal evidence, cancel a route, release a hold,
recover a claim or extend any lease.

The pipeline is intentionally multi-stage. An authorization failure rolls back
its routes/items/assignments/request/audit transaction, not earlier immutable
snapshots, matrices, candidates or attestations. Preserve those artifacts.

## Authorized screen and map

The owned route read adds snapshot/candidate binding, snapshot vehicle label,
assigned load, pickup/location counts, validation status, immutable depot and
pickup coordinates, and separate actual start timestamps. Current authority flags
and task states remain live. Names/addresses are display metadata; map coordinates
and planned weights are from the immutable source. A source drift disables start.

The existing Google Maps marker component is reused: blue depot/start/return,
numbered ordered pickups, one selected route screen per vehicle. Other authorized
vehicles remain available in Database Routes. No polyline or Google Directions
request is introduced. The interface retains Road geometry unavailable.

## Activation guard and compatibility

Combined writes default OFF. Even an ACTIVE planner rejects the combined action
unless GEOLOCK_COMBINED_ROUTE_ENABLED=APPROVED. Start-Worker.ps1 exposes the explicit
-EnableCombinedWorkflow switch only with planner -Activate and ApprovalRef. This
switch was NOT run. Read-only saved results and reconciliation remain available
with the combined switch off. Capabilities prevent snapshot creation when either
the SQL contract or write activation is absent.

Old planning-only clients remain advisory. Old explicit-departure callers remain
compatible. No historical migration, solver objective, research algorithm, graph
data, import provenance or current DEV candidate is changed by these sources.

## Test evidence and boundaries

See results/automatic-routing-local/verification.json for final commands, counts,
hashes and local scope. The disposable test lane applies exact A001/A002/A003 plus
A004 to a fresh PostgreSQL 17 cluster bound to random loopback ports. It uses real
SQL/roles/OR-Tools and a separate validator process. Auth JWT-GUC, Storage and cron
are explicit adapters; local GIS versions differ from DEV. This is not Supabase
or Android runtime parity. Production SupabaseAuth verification remains unchanged;
no real DEV JWT/credential was used in these tests.

Do not deploy, enable combined routing, build/install a replacement DEV APK or run
a real business operation from this document without the relevant separate approval.
