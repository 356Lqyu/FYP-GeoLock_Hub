# Persisted donation lifecycle deployment checks

Prepared only. No database checks or stateful tests in this plan were executed.
Target: isolated DEV rcgyuwiidqvrgbxswhqj. Use dedicated disposable fixtures only
after approval. Never use the shared project.

## Execution order

1. Capture function definitions/ACLs and donation/listing/claim/lease/task/batch
   evidence before deployment. Run the SELECT-only readiness file; inspect missing
   signatures, helper-name collisions and ambiguous backfill cases.
2. Pause application writers and wait for running claim/worker transactions to
   finish. Apply 20261027 as postgres in its single explicit transaction. Lock
   acquisition has a five-second limit: retry the whole transaction after resolving
   contention. Do not remove preflight failures or manually skip individual rows.
3. Run SELECT-only post-deployment checks. Deploy the matching Flutter build.
4. Run the approved stateful acceptance cases below before opening normal traffic.

## Required acceptance matrix

| Case | Required committed result |
| --- | --- |
| Direct creation, exactly 10 kg and above | Donation AVAILABLE, listing AVAILABLE, items and 1–3 images committed together; trusted snap <=500 m; pending eligibility hidden |
| Hub creation below 10 kg | Donation SUBMITTED; no direct listing; donor selects hub; active reservation is 120 minutes |
| Creation failure after staging/items/images | No donation, item, image metadata, listing, request success or audit success survives |
| Direct claim / same UUID replay / changed payload | One CLAIMED donation/listing, one ACTIVE claim and 360-minute lease, one CONFIRMED task; exact cached replay; changed payload rejected |
| Hub receipt and batch publication | HUB_ASSIGNED -> AT_HUB -> BATCHED; complete immutable member set; inventory BATCHED and batch PUBLISHED |
| Hub batch claim | Every active member BATCHED -> CLAIMED in one transaction; no missing/extra member or wrong-hub/missing inventory accepted |
| Start then collection, direct and batch | CLAIMED -> PICKUP_IN_PROGRESS only on Start; then COLLECTED only on confirmed collection; all members together; inventory/batch collected only at completion |
| Safe cancellation / expiry recovery | Direct CLAIMED -> AVAILABLE, hub CLAIMED -> BATCHED; claim/lease RELEASED, task STALE; listing reopened and async eligibility invalidated/requeued |
| Route activity, dispatch or expired listing at recovery | No automatic release; RECONCILIATION_REQUIRED; listing remains claimed; donations keep physical-progress state |
| Reconciliation both false | Safe CONFIRMED/unexpired/no-route case releases all members to the correct path state; unsafe case stays in manual review |
| Reconciliation both true / conflicting evidence | Valid dispatched handover completes the entire set; conflicting evidence preserves custody and manual review |
| Resolved reconciliation replay | Replay each original UUID after resolution, including a lost final response: byte-equivalent recorded response, no extra evidence/mutation; different actor, claim or boolean denied |
| Claim vs claim / donor cancel | One winner; no partial claim/lease/task/donation writes; request outcomes and audits remain linked |
| Start vs cancel / expiry vs cancel / complete vs reconciliation | Existing claim -> lease -> listing -> task lock prefix serializes; all members agree with the committed winner; no deadlock, double collection or partial release |
| Batch member mutation vs claim | Published membership remains immutable; deterministic UUID donation/inventory locks; invalid set aborts the whole operation |
| Photo/discovery | Eligible NGO pre-claim and valid claimant still receive signed private images; anonymous/ineligible NGOs denied; direct AVAILABLE predicate; neither pending/failed/stale async guard can be bypassed |
| Cancellation/republication with worker or NGO location refresh | Eligibility generations invalidate atomically; no stale discovery/claim; independent inclusive directed 20 km check and 500 m validation remain enforced |
| Backfill | Direct legacy READY_FOR_PICKUP+AVAILABLE/no active claim -> AVAILABLE; verified claimed listing+matching claim/lease+CONFIRMED/PLANNED task -> CLAIMED; claimed batch members likewise; SUBMITTED hubs, ongoing pickups and terminal history unchanged |
| Ambiguous backfill / invalid classification / partial batch | Entire migration rolls back; old functions, triggers, constraint, data and ACLs intact |
| Finalization guard | Unfinalized SUBMITTED direct staging fails at COMMIT, including forced-immediate constraints; finalized hub SUBMITTED succeeds with its required photo |

Existing stateful scripts are not part of offline unittest discovery. The hub
reservation race script now expects a successful direct claim to persist CLAIMED.
The new `persisted_donation_lifecycle_dev_test.py --run-stateful` covers direct
and hub pickup, cancellation, UUID replay and cancel/start races with six distinct
pre-existing disposable fixtures. Its exact fixture keys are documented in the
script; it uses the existing strict DEV environment/credential gate.
The recovery/reconciliation runner additionally checks persisted member states and
resolved evidence replay. Prepare valid current fixtures separately; the historical
Stage 1 fixture seeder predates trusted snapping, async readiness and the new
lifecycle and must not be used for this acceptance run. Source-contract
tests prove source invariants only; they do not establish PostgreSQL compilation,
real lock scheduling, RPC runtime behavior or Storage authorization.

## Recovery

Before COMMIT any error rolls back the complete migration. After COMMIT do not
restore old function bodies or relabel CLAIMED rows as READY_FOR_PICKUP while active
claims exist. Stop writers, capture evidence and prepare an evidence-based
forward-only repair. Historical audits and request/evidence responses must not be
rewritten. This package intentionally provides no destructive down migration.
