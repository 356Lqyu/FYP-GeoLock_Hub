# Protected unstarted route cancellation — local implementation

Date: 2026-11-04 (MYT). Scope: approved local route fix and tests only; DEV investigation read-only. No deployment, existing-record repair, Food Can fix, worker activation, formal E2/E4 experiment or GitHub push.

## Deliverables

- Forward migration: `supabase/migrations/20261104130000_unstarted_released_route_cancellation.sql` (unique migration version).
- Flutter source: `frontend/geolock_hub_app/lib/routing/ngo_routes_page.dart` and `route_card_view.dart`.
- New tests: `supabase/tests/unstarted_released_route_contract_test.py`, `unstarted_released_route_isolated_test.py`, and `frontend/geolock_hub_app/test/unstarted_released_route_test.dart`.
- Existing test fixture correction: `frontend/geolock_hub_app/test/route_cards_test.dart` now supplies fresh active claim-card lease evidence for its synthetic direct-pickup lifecycle. Production privacy/lease gates are unchanged.
- Separate investigation: [Food Can root cause](FOOD_CAN_PICKUP_IN_PROGRESS_ROOT_CAUSE.md). Food Can is not released; its different route recorded a pickup start and false/false reconciliation requires MANUAL_REVIEW. No Food Can source was changed.

## SQL behavior

The migration extends existing `cancel_my_unstarted_route(uuid)` rather than adding a new route state or automatic recovery mechanism. Existing unchanged-plan cancellation, owner locks and already-CANCELLED replay remain intact. A narrowly scoped additional branch uses `routing_private.can_cancel_released_unstarted(uuid)` after `lock_route`. The same observational helper drives the reader's new `no_collection_cancellation_eligible` flag. It performs no writes and is not executable by client roles.

Eligibility requires an owned, open AUTHORISED binding; no route/item recorded start or collection; nonempty complete manifest/member correspondence; STALE tasks and RELEASED claims/leases; released private items and RESOLVED_UNCOLLECTED deferral history with matching owner/claim; no active assignment, pending/manual claim or route case, route incident, positive handover evidence or contradictory successful start/collection audit. Missing task/claim/lease/listing/manifest/source associations fail closed. Source goods and, for hub batches, inventory must be consistent with safe release.

Accepted release evidence is either:

1. RECONCILED_NO_HANDOVER on both claim and lease, with a resolved no-handover case and exactly two matching false statements from the owning NGO and actual distinct donor/hub participant; or
2. EXPIRED_SAFE_RELEASE on both claim and lease, a lease already expired when closed, no reconciliation case, and the corresponding successful protected LEASE_RECOVERY safe-release audit. This branch represents authoritative automatic no-start recovery evidence; it does not manufacture participant statements.

The additional cancellation updates only the route to CANCELLED and closes its binding in the locked transaction. Existing released items/tasks/claims/leases, public route stops, deferred events and reconciliation records remain unchanged. The partial unique open-vehicle booking is thereby released; no released task is reset to CONFIRMED. Audit records CANCEL_UNSTARTED_ROUTE / ALL_MEMBERS_RELEASED_NO_COLLECTION, cancellation_outcome=NO_COLLECTION, preserved history, and depot_return_required=false. It makes no depot-return confirmation assertion. Repeated requests return through the existing terminal replay path without duplicate audit entries.

`get_my_authorized_route` adds safe cancellation eligibility and reads the no-collection cancellation outcome only from its successful authoritative audit marker. It overrides can_cancel for eligible routes. For a never-started route with resolved-uncollected history, can_close is false and closure_outcome is cleared. It does not cancel during reads. `close_my_resolved_route` independently rejects never-started routes under its existing locks, before accepting a depot assertion; its earlier durable request receipt replay remains untouched. Started/mixed/collected routes retain their existing return/accountability checks.

All three modified public functions retain their signatures, security-definer settings and existing ACLs through CREATE OR REPLACE. The migration verifies the enabled task authority guard and exact normalized baseline function fingerprints before patching. Missing baselines, source drift or ambiguous patch anchors abort the single transaction. It does not rewrite the pre-deferral reader, donor history, recovery functions, triggers, grants/policies on existing application functions or workers.

## Flutter behavior

The detail page shows “No active pickups remain” and “Cancel Route — No Pickups Completed” only with the new authoritative eligibility flag. It explains preservation of released outcomes and vehicle reservation release in the confirmation dialog. It hides the depot-return instruction/action for this case. After a successful cancellation, “Route cancelled — no pickups completed” requires CANCELLED plus backend cancellation_outcome=NO_COLLECTION. Generic old cancellations retain generic wording.

Route cards use the same authoritative wording. They no longer interpret can_close=true as proof that pickups were collected: mixed closure says “Pickups resolved,” while other closure readiness is phrased neutrally. The production repository remains unchanged: it rereads protected detail before mutation; the existing freshness, auth/owner change, in-flight execution and durable mixed-closure request/receipt handling remain in force. Cancellation uses the existing route-keyed idempotent RPC; no replacement mutation or fabricated depot confirmation was introduced.

## Verification

Final executed results:

| Check | Result |
|---|---|
| `flutter analyze --no-pub` | PASS, no issues, 10.3 seconds |
| `flutter test --no-pub test/unstarted_released_route_test.dart test/route_cards_test.dart test/route_details_presentation_test.dart test/route_execution_test.dart test/route_execution_widget_test.dart test/route_resolution_test.dart --reporter expanded` | PASS, 89 tests |
| `.venv-stage8/Scripts/python.exe supabase/tests/unstarted_released_route_contract_test.py` | PASS, 4 tests |
| `.venv-stage8/Scripts/python.exe supabase/tests/claim_scoped_reconciliation_static_test.py` | PASS, 5 tests |
| `.venv-stage8/Scripts/python.exe supabase/tests/unstarted_released_route_isolated_test.py --run-isolated --runtime .tmp/geolock-spatial-runtime-safe-cancel` | PASS, 15 tests, 179.242 seconds, zero DEV connections |
| `git diff --check` | PASS |

PostgreSQL evidence: [final result](../../results/automatic-routing-local/20261104T130253Z-8464f0/safe-cancellation-result.json), [cluster stop](../../results/automatic-routing-local/20261104T130253Z-8464f0/cluster-stop.json), plus that directory's SQL inputs, audit/state snapshots and concurrent retry/expiry race results. Flutter logs: `.tmp/safe-route-flutter-tests.log` and `.tmp/safe-route-analyze.log`. The tested migration SHA256 is `656e21a79158fe048e141d74a17fef369ce9b7a09b6932aa811bbff954920a6e`.

The PostgreSQL suite covers two-party release/cancel/replay/history, active work preservation, unchanged ordinary cancellation, started no-collection hold, collected mixed closure and depot requirement/receipt replay, pending/conflicting reconciliation, missing participant evidence, contrary start audit, foreign ownership/private privileges, rejection of false depot closure, three-way expiry/cancel/start, read-only readers and source-drift rollback, missing lease joins, pending route cases, and hub no-handover/inventory preservation. Concurrent same-route cancellation produces one accurate no-collection audit. The Flutter additions cover exact labels, authoritative terminal wording, neutral closure wording, confirmation/refresh, stale permission reread and page freshness expiry.

Earlier diagnostic runs exposed an outdated Flutter mock missing lease evidence and a test expectation that used RuntimeError instead of the harness's AssertionError for intentional source-drift rejection; both test issues were corrected. The final run is the result reported above. Initial sandbox/runtime setup failures ran zero database tests and are not counted as passes.

These are local regression results, not hosted Supabase or live UI parity. The private PG17.11/PostGIS 3.6.2/pgRouting 4.0.1 runtime uses a newly initialized loopback-only cluster and synthetic auth/Storage/cron adapters; no existing service data directory is used. The missing spatial binaries were rebuilt from local PG binaries and the checksum-verified [official PostGIS bundle](https://download.osgeo.org/postgis/windows/pg17/). Local fixture planning uses the existing synthetic validator harness, without activating any DEV routing worker.

## Security, concurrency and remaining limits

- The mutation retains the established READ COMMITTED actor/source/vehicle/route/task/binding lock order. Claim recovery and pickup dispatch serialize on the same NGO/source scope. Reader eligibility is advisory until rechecked under those locks.
- Successful retry, three-way expiry/cancel/start and collected mixed-closure scenarios exercise real protected SQL in a fresh loopback PG17 cluster. This is bounded regression coverage, not a proof over every possible schedule.
- The predicate deliberately fails closed when current source goods/listings have moved into another claim or changed participant/source state. Such reused-source routes need fresh protected review rather than weakening old no-handover evidence checks. This conservative limitation can retain a vehicle hold; it never releases custody or cancels another route.
- Start timestamps alone are not treated as physical proof: successful start/collection audit, participant evidence, incidents, source states and unresolved cases are also checked. There is no independent GPS proof of departure/return in this contract.
- Audit-based terminal wording relies on existing protected audit write permissions. No new client audit write access was granted.
- The previously reported deployed base-reader privacy drift remains a separate issue. This migration preserves any pre-deferral reader changes already present, including the local released-history changes; it does not deploy or replace them.

## Deployment readiness and required future DEV checks

This is a local review candidate, not deployed code. Deployment and repair of the affected route require subsequent explicit approval. Do not infer deployed parity from the local migration filename.

Before any approved deployment:

1. Reconfirm the project URL/ref and capture current functions, owners, ACLs, enabled guards and source fingerprints in READ ONLY transactions ending ROLLBACK. Recheck route `24c9a21a-a5fd-4ff4-8fb4-e04779b292e9` and its complete custody evidence; the investigation is a snapshot.
2. Review the forward migration against the then-current contract. If preflight fingerprints differ, stop and reconcile the change; do not remove drift guards. Confirm private helper ownership/search_path and preserved existing grants. Review the conservative source-reuse limitation above.
3. Deploy only the reviewed migration using the authorized deployment process. No batch recovery, hidden cleanup, scheduler or automatic cancellation is required.

After a separately approved deployment:

1. In READ ONLY inspection transactions, verify the new helper definitions, revoked client execute privileges, public function security/ACLs and enabled guards. Confirm old start/complete/collected-close and donor-history functions remain unchanged. Finish ROLLBACK.
2. Through a fresh normal owning-NGO session, verify the affected route's authoritative flags: no_collection_cancellation_eligible=true, can_cancel=true, can_close=false, no executable pickup. Inspect the detail/card labels and confirm there is no depot-return action. Verify a foreign session cannot read or mutate the route. Do not impersonate users through admin SQL.
3. Do not cancel the actual route merely as a deployment smoke test. If the owner separately authorizes its real cancellation, use the protected action, then inspect CANCELLED, closed binding, one no-collection audit, preserved manifest/terminal task/claim/lease/evidence history, and no depot confirmation. Retrying the same RPC must not create a duplicate transition.
4. Confirm started/collected routes retain the return workflow, and unresolved cases remain protected. Use disposable fixtures for destructive/negative/concurrency checks rather than real DEV goods.
5. Food Can must remain PICKUP_IN_PROGRESS / RECONCILIATION_REQUIRED / DISPATCHED / MANUAL_REVIEW on its own started route unless a separately approved protected resolution is completed. This route fix must not release it or its vehicle hold.

No DEV post-deployment checks were executed because nothing was deployed.
