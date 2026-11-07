# GeoLock Hub — Supabase DEV Recovery, Routing Worker and Reconciliation Verification

**Review date:** 2026-11-03  
**Scope:** Read-only inspection of the authorized Supabase DEV database, checked-in SQL/source, worker configuration available to this environment, and current operational aggregates.  
**Decision:** **NO-GO for a controlled live claim-to-routing test at this time.** The deployed recovery function is behaviorally consistent with a local claim-scoped patch but its deployment provenance is unresolved; the routing worker is not configured or reachable from this environment; and DEV contains unresolved/manual reconciliation work that needs an approved operator path.

## 1. Executive summary

| Area | Result | Evidence and limitation |
|---|---|---|
| DEV identity and inspection mode | PASS | Project ref `rcgyuwiidqvrgbxswhqj`, database `postgres`, PostgreSQL 17.11. Catalog inspection ran in a read-only transaction (`transaction_read_only=on`). |
| NGO registration-number removal | PASS / expected | `ngo_profiles.registration_number` is absent, consistent with the user-confirmed manual DEV execution of the removal migration. This is not treated as unexplained drift. |
| Claim/pickup lifecycle pins | PASS | `claim_listing`, `start_pickup`, and `complete_pickup` normalized fingerprints match checked-in expected pins. |
| Expired-claim recovery | PARTIAL | DEV body differs from the Stage A pin but matches code produced by the local 2026-11-09 claim-scoped patch. No deployment record or approval evidence establishes when/how that body reached DEV. |
| Scheduled recovery health | PARTIAL | Cron job is active and has 1,440 successful invocations and 0 failed invocations in the preceding 24 hours. This proves invocation health, not that a claim was recovered; no active expired leases were present at the observed snapshot. |
| Claim reconciliation | PARTIAL | Protected participant and evidence RPCs are present. There are three existing `MANUAL_REVIEW` claim cases and no discovered operator-resolution RPC for them. |
| Route reconciliation | PARTIAL | Protected task-scoped evidence and restricted operator finalization are present. New whole-route interruption case creation is retired; one legacy route case is awaiting evidence. |
| CP-SAT routing implementation | PASS locally | Checked-in worker uses a two-stage strict lexicographic CP-SAT objective and an independent validator. This verifies source capability only. |
| Worker runtime / deployment readiness | FAIL in this environment | No configured worker URL, listener, worker process, or Supabase Edge Function was found; local worker config check reports `DISABLED`. An externally hosted worker cannot be ruled out from this environment. |
| Operational readiness | NO-GO | Unresolved recovery provenance, absent worker configuration, three manual claim cases, and one awaiting route case preclude a safe live test. No write or recovery RPC was run. |

## 2. Connection identity and inspection boundaries

The authorized Supabase DEV connection identified:

- Project API: `https://rcgyuwiidqvrgbxswhqj.supabase.co`
- Database: `postgres`
- PostgreSQL: `17.11`
- Current and session database role: `postgres`
- Server endpoint: IPv6; port `5432`
- Transaction setting: `read_only=on`

Database catalog and operational queries were executed inside `BEGIN READ ONLY` transactions. No application RPC, claim, route, scheduler recovery function, migration, or table mutation was invoked. No secrets, credentials, request identifiers, or individual user/test-data identifiers are included here. The absence of `ngo_profiles.registration_number` is expected because the user confirmed manually applying that removal migration in DEV.

The Supabase migration-list tool returned no entries. That result is not evidence that the catalog objects are absent: the current database contains the routing and reconciliation objects described below. The inspected database did not expose a dependable GeoLock deployment ledger tying the current function body to a particular approved deployment. Supabase Edge Function inventory was empty; this says nothing conclusive about an external worker host.

## 3. Recovery function and fingerprint reconciliation

### 3.1 Current DEV implementation

`public.recover_expired_claims(integer)` returns an integer, is `SECURITY DEFINER`, owned by `postgres`, and has pinned search path `pg_catalog, public, extensions, pg_temp`. Its authorization gate accepts `auth.role() = 'service_role'` or a database `session_user` of `postgres`; ordinary authenticated and anonymous callers do not have execute permission. It is intended for the trusted scheduler/service path.

The current normalized `prosrc` MD5 is **`05fe46d8b76085f71c87fcc5f6520775`**. The Stage A 003 documented pin is **`89e01f42d5ec23bfcbcdc47c1f4fd4e5`**. This is a function-body mismatch, not a line-ending or whitespace normalization discrepancy.

The DEV implementation selects only claims and leases both still `ACTIVE` whose lease expiry is due, oldest first, with a bounded limit. It rechecks locked state before acting. For each candidate, it locks the relevant route scope first when an unreleased route item exists, then claim, lease, listing, and task. This ordering coordinates with route authorization and reconciliation.

It treats uncertainty conservatively. Existing reconciliation, missing or inconsistent listing/task/donation/batch state, active pickup custody, consumed/collected route items, and other lifecycle contradictions move claim and lease to `RECONCILIATION_REQUIRED` and open a claim reconciliation case; the listing, task, and donation custody state are not released. A task-scoped protected helper may detach a safe, unstarted route stop. A safe release marks claim and lease `RELEASED`, task `STALE`, restores a still-claimed listing to `AVAILABLE`, and restores direct donations to `AVAILABLE` or hub-batch members to `BATCHED`, with audit evidence. Listing expiry is preserved. Exceptions roll back the transaction; state filtering makes subsequent runs idempotent.

The recovery path does not close a route or release a vehicle booking. That distinction preserves other work on a multi-stop route and requires the normal protected route-closure workflow to release the vehicle.

### 3.2 Why the DEV body differs from the pin

Checked-in Stage A migration `20261103_routing_pickup_and_reconciliation.sql` checks/preserves the 89… pin. The local future-dated review artifact `20261109_claim_scoped_reconciliation.sql` includes the claim-scoped route interruption handling and changed recovery behavior. The DEV recovery body and its relevant private helper definitions match the replacement/patch content in that local artifact. The local artifact is therefore a source-level explanation for the DEV body content; it is not proof of how or when that content was deployed.

The local `20261109_DEV_IMPACT_ASSESSMENT.md`, dated 2026-11-01, states that the migration had not been run as of that assessment and that DEV still had the 89… recovery pin at that time. The later local `20261106_route_interruption_resolution.sql` also requires the 89… pin. No later signed deployment manifest, postflight record, migration ledger entry, or user-provided approval record establishing installation of the claim-scoped recovery body was found in the inspected repository/DEV evidence. Since the current date is 2026-11-03 and the matching local artifact is dated 2026-11-09, its matching code must not be treated as evidence of an approved migration deployment.

**Conclusion:** this is not explainable as formatting. The current behavior matches a local claim-scoped patch, but its deployment provenance is unresolved. Do not overwrite DEV with the older pinned definition, and do not update the expected hash to accept the observed body. First obtain and reconcile the deployment record/approval and establish which source is authoritative for DEV. Any future forward migration must be reviewed against the actual current body and must not blindly apply old `89…` preconditions.

### 3.3 Other lifecycle fingerprints

| Function | DEV normalized fingerprint | Result |
|---|---|---|
| `public.claim_listing(uuid,uuid)` | `2c1f60c876797c61b44b3cb43591bab8` | Matches the checked-in pin. |
| `public.start_pickup(uuid)` | `cb306433867538804b67aa1a242867b4` | Matches the checked-in pin. |
| `public.complete_pickup(uuid,boolean)` | `26f0cd8cebe783c65b45e05649693860` | Matches the checked-in pin. |
| `public.recover_expired_claims(integer)` | `05fe46d8b76085f71c87fcc5f6520775` | Differs from Stage A pin `89e01f42d5ec23bfcbcdc47c1f4fd4e5`; provenance unresolved as above. |

The three matching lifecycle functions retain protected, database-authoritative behavior. Claiming derives the actor from `auth.uid()`, verifies active NGO state and road/network eligibility, uses request idempotency and serialized listing mutation, and is backed by an active-claim uniqueness constraint. Pickup start and completion are protected transitions tied to route/task state; direct client writes are not the intended authority path.

## 4. Scheduled recovery health

`pg_cron` contains active job `geolock-expired-claim-recovery`, scheduled every minute. Its command applies a 5-second lock timeout and 50-second statement timeout before calling `public.recover_expired_claims(1)`. The command is intentionally not reproduced because it contains a credential-like token.

Read-only `pg_cron.job_run_details` evidence showed 1,440 successful runs and zero unsuccessful runs over the preceding 24 hours; the latest successful invocation was at `2026-11-02T17:49:00.073928Z`. The recorded cron message indicates the statement returned one row, not the integer value returned by the function. At the point-in-time operational snapshot below, there were no active expired leases. Therefore this supports scheduler execution health, but not evidence that an eligible claim was released, nor evidence that the current function’s output was captured or reconciled.

## 5. Worker source, local readiness, and deployment status

### 5.1 Local implementation

The current local worker entry points are under `backend/routing/worker_service/`. The planner and validator are separate services (README defaults 8787 and 8788). The current phase-B method map selects `optimizers.proposed`, which is the CP-SAT implementation. It maximizes served pickup-task count in stage one, fixes that optimum, then minimizes directed road distance in stage two. Status distinguishes proven optimal results from `FEASIBLE_UNPROVEN`. The independent validator checks task count, eligibility/coverage, vehicle capacity, time windows/leases, and directed road arcs. Hub batches are represented as one pickup task and use the full batch weight.

The worker does not authorize routes. Supabase remains the authority: it creates a routing snapshot, receives an untrusted candidate, independently validates the submitted trusted validation record and source state, and atomically authorizes route/vehicle/task assignments through protected RPCs. Flutter calls planner endpoints configured via `GEOLOCK_ROUTING_API_URL` and then calls protected Supabase RPCs for authorization.

There is documentation drift: `backend/routing/worker_service/README.md` describes Stage B’s primary path as RoutingModel, while the active `METHODS['proposed']` mapping uses CP-SAT; `routing_model_proposed` remains a comparison method. `backend/routing/phase_b/README.md` describes the current proposed method as strict lexicographic CP-SAT. This should be reconciled before packaging a worker, but it does not change the database’s protected authority.

### 5.2 Configuration observed

The local `.venv-stage8` provides Python 3.12.14 and OR-Tools 9.15.6755. Running the documented no-network configuration check with that environment returned:

```json
{"mode":"planner","project_ref":"rcgyuwiidqvrgbxswhqj","status":"DISABLED"}
```

The current process environment had none of the worker configuration values required to activate/serve a request. The local checks found no listener on ports 8787 or 8788, no running worker process, and no configured `GEOLOCK_ROUTING_API_URL`. Flutter source reads this URL from a build-time environment define; the URL compiled into an already-installed app cannot be inferred from source. No Supabase Edge Functions were listed. No worker health endpoint was tested because no URL was configured.

Configuration required for a controlled test, without disclosing secret values:

1. `GEOLOCK_PROJECT_REF` for the approved DEV project.
2. Separate least-privilege `GEOLOCK_GRAPH_DSN`, `GEOLOCK_PLANNER_DSN`, and `GEOLOCK_VALIDATOR_DSN` logins, scoped to their documented database roles.
3. `GEOLOCK_GRAPH_ID` set to the approved frozen graph (`eab1f7ee-a8e0-4bed-a0e1-2c4bff024936`) and verified digest `5e06dab0…a04012a`.
4. `GEOLOCK_SUPABASE_PUBLISHABLE_KEY` for the planner’s Supabase request authentication.
5. `GEOLOCK_VALIDATOR_URL` to a private validator endpoint (localhost 8788 for a local paired worker, or an approved HTTPS endpoint) and `GEOLOCK_VALIDATOR_TOKEN` from a secret manager.
6. Protected persistent `GEOLOCK_WORKER_STATE` storage, plus the documented graph/policy/snapshot-age settings.
7. A controlled network/TLS path if remotely hosted, and Flutter built with `--dart-define=GEOLOCK_ROUTING_API_URL=<approved planner URL>`.
8. Activation/write flags only after explicit authorization. These were not set and must remain off during this readiness report.

Do not put secrets directly into shell history, source control, or a report. Setup should use the approved Windows secret manager or process-scoped environment configuration, then run the documented `--check-config` command and a nonmutating health check. No worker was activated here.

## 6. Coordination, reconciliation, and lifecycle authority

### 6.1 Claim and route planning

The protected `claim_listing(uuid,uuid)` path owns claim eligibility and atomicity. Routing snapshots select tasks with `pickup_tasks.task_status = 'CONFIRMED'`; already planned or dispatched tasks are not offered again. `begin_my_routing_snapshot(p_request,p_policy,p_vehicle_ids)` verifies the authenticated NGO and depot, serializes NGO planning, and snapshots owned available vehicles and eligible tasks. The candidate authorizer verifies the candidate and trusted validation record, current vehicle/depot/task/lease/road eligibility, capacity and schedule, then atomically inserts route, vehicle binding, route items/stops, and active assignments and transitions tasks to `PLANNED`.

Active unique constraints prevent multiple claims for a listing, multiple active route assignments for a pickup task, and multiple active bookings for a vehicle. Vehicle booking is per vehicle. A planned task no longer satisfies the snapshot’s `CONFIRMED` predicate, so it is excluded from subsequent routing requests. Other confirmed, unassigned, claimed tasks can be considered in a later snapshot for another available vehicle. Route authorization does not itself close or alter another authorized route.

`start_pickup(uuid)` changes the assigned task to `DISPATCHED`, starts the route as appropriate, and retains its booking. `complete_pickup(uuid,boolean)` records collection but does not release the vehicle. Normal route closure requires the protected `close_my_collected_route(route,true)` path after all tasks and claim/lease states are complete; mixed resolved routes use the protected resolved-route closure contract. Vehicle binding closes only at route closure. A stale or expired lease is not refreshed by routing and remains subject to recovery rules.

### 6.2 Claim reconciliation

The principal claimant/source evidence workflow is `submit_claim_reconciliation(p_claim,p_handover_confirmed,p_request)`, with participant/read RPCs `get_my_claim_reconciliation_receipt`, `get_my_donation_claim_reconciliation`, and `get_my_reconciliation_cases`. NGO deferral is through `defer_my_pickup_for_reconciliation`. These functions derive actor identity from JWT/database context and enforce claimant/source participation; the evidence submitter cannot directly release custody state.

Consistent handover evidence from the NGO and donor/hub administrator can resolve to collected state under the protected transition path. A safe no-handover result can release only when listing, task, lease, donation/batch state, route assignment, expiry, and evidence predicates all allow it. Contradictions, expired listings, dispatched custody, mixed hub state, or insufficient evidence remain held for manual review. A manual-review state is not equivalent to “not collected.”

Three claim reconciliation cases were `MANUAL_REVIEW` at observation. Catalog inspection found no protected public/operator RPC that resolves claim-level manual-review cases. This is a material operational gap: use an approved operator procedure or build/review one before a controlled test relies on those records. Do not resolve them with direct table updates.

### 6.3 Route reconciliation

Route-level APIs include `get_my_route_resolution`, `submit_route_resolution_evidence`, `finalize_route_resolution`, `get_my_route_resolution_receipt`, and `get_route_resolution_for_operator`. `finalize_route_resolution` is restricted to the `geolock_route_resolver` login role; authenticated NGO and service roles cannot execute it. It revalidates whole-route tasks/evidence and vehicle return before resolving a mixed/abandoned route and closing the vehicle binding. Protected route closure for fully collected routes is separate.

`report_my_route_interruption` remains a protected, idempotent RPC for compatibility/receipt behavior, but current DEV code explicitly retires creation of new whole-route interruption cases (`NEW_ROUTE_INTERRUPTION_REPORTS_RETIRED`). Existing route cases can still be read/evidenced. There was one route resolution case in `AWAITING_EVIDENCE` at the observed snapshot. The route case and claim case systems have distinct evidence/closure semantics; neither should be bypassed with client writes.

## 7. Point-in-time DEV state

At database timestamp `2026-11-02T17:49:15.799404+00` (the query snapshot; not a live guarantee):

- 5 active claims and 5 active leases; 0 active leases were expired.
- Pickup tasks: 6 `PLANNED`, 2 `DISPATCHED`, 3 `COLLECTED`, 28 `STALE`; 0 `CONFIRMED` in the reported aggregate.
- Routes: 1 `AUTHORIZED`, 2 `IN_PROGRESS`, 1 `COMPLETED`.
- 3 active vehicle bookings and 8 active task assignments.
- Claim reconciliation: 0 open cases and 3 `MANUAL_REVIEW` cases.
- Route resolution: 1 `AWAITING_EVIDENCE` case.
- Routing private requests: 4 `AUTHORIZE`, all with a stored result.
- Resolution private requests: 5 `EVIDENCE`, 1 `REPORT`; all observed request rows had results.

These are aggregate counts. They do not identify users, route owners, test actors, or whether any existing records are suitable for a controlled trial. In particular, the snapshot contained no confirmed task, so it did not provide a ready-to-use routing fixture. Existing NGO/depot/vehicle/donation ownership suitability was not established by these aggregate-only checks.

The database also reports `coordination_config` version `v2.0` with a 360-minute claim lease, 20,000-meter geofence, and direct-donation minimum of 10 kg. The current operational OSM snapshot is `OSM-OPS-20261018` (926,414 nodes; 2,145,828 edges). The frozen routing graph and policy identities are recorded in the worker section; these establish available database-side graph/policy data, not a reachable worker.

## 8. Scenarios and current disposition

| Scenario | Status | Deployed behavior and safe outcome |
|---|---|---|
| A. Lease expires before route planning | **PARTIAL** | If claim and lease remain active/expired, task is `CONFIRMED`, listing and direct/batch source states are consistent, and no reconciliation/custody evidence exists, recovery can release claim/lease, stale the task, and make the listing available. If any predicate is uncertain, it creates/retains a reconciliation hold. No eligible expired lease existed in the observed snapshot, and this path was not invoked. |
| B. Lease expires after authorization, before target pickup | **PARTIAL** | Recovery locks the route scope first. An unconsumed/uncollected planned stop may be detached through the protected deferred-stop permit when the route remains feasible; only that assignment/item is released and the rest of the route/vehicle booking remains. If the helper cannot establish safety, recovery holds claim/lease for reconciliation. No live mutation test was run. |
| C. Lease expires during an in-progress route | **PARTIAL** | A still-unstarted planned stop can be detached when the task-scoped helper proves safety. A dispatched/consumed/collected target is not automatically released; claim and lease move to reconciliation-required, preserving task/donation custody and vehicle booking. The route continues under protected lifecycle rules. |
| D. Network interruption after pickup starts | **PARTIAL** | If `start_pickup` committed, task is `DISPATCHED`, donation is in pickup progress, and route/vehicle remain active. Durable Flutter request/receipt recovery is source-supported. On uncertainty, reconcile from protected status/receipts; do not issue a new distinct operation or infer that the start failed. No fault-injection test was run against DEV in this phase. |
| E. NGO reports collected while DB is uncertain | **PARTIAL** | NGO and donor/hub source each submit protected `HANDOVER_TO_NGO_CONFIRMED`/claim-level evidence. One side awaits counterpart; consistent evidence can complete task/claim/lease/donation custody, but route and vehicle remain until route closure. Contradiction or mixed hub state goes to manual review. Existing DEV has manual-review cases; no operator claim resolver was found. |
| F. One task on a multi-stop route becomes invalid | **PARTIAL** | Task-scoped lease/reconciliation can defer/release one safe unstarted stop while preserving other route tasks. Dispatched/collected or conflicting source evidence is held. Route-level report cannot create new interruption cases in current DEV; the legacy route evidence path is available for an existing case. Route-wide resolution requires the restricted resolver and final return evidence. |
| G. Tasks complete but depot return/closure is unconfirmed | **PASS for protection; PARTIAL for workflow verification** | Completion does not free the vehicle. `close_my_collected_route(route,true)` requires depot return confirmation and all tasks/claims/leases completed; mixed routes use the resolved-route closure path. Until then, vehicle binding remains active. No closure RPC was called. |

These dispositions reflect the existence and semantics of protected code, not successful live execution of each scenario. The live database was not mutated for testing.

## 9. Flutter and worker integration

The Flutter route repository creates protected snapshots, submits candidates through the worker client, authorizes through Supabase, and maintains request/recovery state. After verified authorization receipt and durable recovery persistence, the local planning operation can be archived automatically; pending, failed, ambiguous, and unreconciled operations remain recoverable. Route history and active route management remain separate from planning-operation archival. Claim and route reconciliation repositories use protected evidence/receipt APIs.

The integration is source-capable but cannot currently be verified end-to-end against a reachable worker: `GEOLOCK_ROUTING_API_URL` is not configured in this environment and no planner/validator runtime is running. The local worker configuration check returned `DISABLED`. A `GEOLOCK_ROUTING_API_URL` build define and a reachable paired planner/validator are prerequisites before validating candidate generation and independent validation. Protected Supabase authorization remains required even after a worker is configured.

## 10. Risks and required actions before live testing

1. **Resolve recovery provenance.** Find the approved migration/deployment record for the body matching the local claim-scoped recovery patch. Compare deployed source, migration ordering, expected preconditions, and the current Stage A pin. Do not change the pin or function until that review is complete.
2. **Handle existing manual reconciliation cases.** Establish an approved, protected operator resolution path for the three claim cases. Avoid using ad hoc SQL/table edits.
3. **Resolve the route case.** Review the one awaiting-evidence route case using actor-scoped read APIs and obtain the required evidence through the supported route workflow; do not disclose or mutate case data in an audit report.
4. **Configure worker pair.** Provide the least-privilege DSNs, approved frozen graph/policy, validator token/URL, durable state path, private networking/TLS, and Flutter planner URL. Keep write activation disabled until the separate live-test approval.
5. **Reconcile worker documentation.** Update the worker README’s primary-method description to match the active CP-SAT mapping, after implementation approval.
6. **Select approved fixtures.** The aggregate snapshot has zero confirmed tasks and cannot establish a suitable test NGO, verified depot, two available vehicles, or owned eligible donations. Select fixtures by read-only, privacy-preserving queries before any write test.
7. **Run isolated integration tests first.** Exercise lease expiry before planning, after authorization, in-progress dispatched custody, ambiguous pickup response, one invalid task on a multi-stop route, route closure, hub batch weight/counting, and duplicate/conflicting claims against disposable PostgreSQL with the exact current recovery source.

## 11. Verification record and limits

- **Direct DEV evidence:** database identity/read-only state, current function definitions and ACLs, pins/fingerprints, constraints/indexes, cron schedule and run counts, graph/policy/config records, and aggregate operational counts.
- **Local-source evidence:** Flutter request/receipt recovery workflow, worker startup/configuration, CP-SAT algorithm, validator, and migration patch contents.
- **Not verified:** exact approval/deployment provenance for the current recovery body; any external worker host; installed Flutter build-time API URL; live execution of the seven scenarios; suitability of a specific NGO/depot/vehicle/donation fixture; the scalar count returned by cron recovery calls.
- **Actions not performed:** no writes to DEV or production, no state-changing RPCs, no recovery execution, no migration, no worker activation/deployment, and no application/SQL code changes.

### Source and migration references

The principal checked-in sources reviewed were:

- `supabase/migrations/20261031_claim_audit_and_failure_capture.sql` — prior recovery implementation/fingerprint and audit behavior.
- `docs/stage8/stage-a/forward-migrations/20261103_routing_pickup_and_reconciliation.sql` — Stage A recovery pin and routing/reconciliation setup.
- `docs/stage8/stage-a/forward-migrations/20261106_route_interruption_resolution.sql` — recovery fingerprint precondition and route resolution changes.
- `docs/stage8/stage-a/forward-migrations/20261109_claim_scoped_reconciliation.sql` and `docs/stage8/stage-a/forward-migrations/20261109_DEV_IMPACT_ASSESSMENT.md` — local claim-scoped recovery patch and recorded deployment status at assessment time.
- `backend/routing/worker_service/README.md`, `backend/routing/worker_service/server.py`, `backend/routing/worker_service/staged.py`, `backend/routing/worker_service/orchestrator.py`, `backend/routing/worker_service/validator.py`, `backend/routing/worker_service/transport.py` — worker startup, endpoint/configuration, orchestration, and validation.
- `backend/routing/phase_b/__init__.py`, `backend/routing/phase_b/optimizers.py`, `backend/routing/phase_b/validation.py`, `backend/routing/phase_b/contract.py` — active optimizer mapping, lexicographic objective, independent validation, and task/batch contract.
- `frontend/geolock_hub_app/lib/routing/ngo_routing_repository.dart`, `frontend/geolock_hub_app/lib/routing/routing_worker_client.dart`, `frontend/geolock_hub_app/lib/routing/route_resolution_repository.dart`, and the NGO routes/donation/status-timeline pages — Flutter authorization receipt, planning-operation recovery, route management, and reconciliation UI.

Function hashes above were computed from the deployed catalog definitions using the project’s normalized-body fingerprint convention. No expected hash was changed as part of this review.

## 12. Final decision

**NO-GO for controlled live Supabase DEV claim-and-routing testing.** The blockers are concrete: current recovery body provenance is not tied to an approved deployment record; three claim cases are in manual review with no discovered protected claim-level operator resolver; one route case is still awaiting evidence; and the planner/validator worker is disabled and unreachable from the available environment. Reassess after those items are resolved, the worker configuration is verified without write activation, and suitable fixtures are confirmed by read-only queries.
