# Later protected route closure and vehicle release design

**Design proposal only. Not implemented, not authorized for deployment, and not part of C1 v2.** No new RPC, migration, table or lifecycle change is supplied here.

## Current operational limitation

The deployed complete_pickup RPC updates the task to COLLECTED and completes the listing, claim, lease and donation/hub custody effects. It neither marks pickup_routes COMPLETED nor removes active_task_route_assignments. Current catalog/source inspection found no deployed public route-closing writer or route-expiry cron. External workers remain unverified. Route age/lease expiry therefore cannot be treated as proof of release.

C1 v2 conservatively holds a vehicle for DRAFT/VALIDATED/AUTHORISED/IN_PROGRESS routes, any retained active assignment, or stop tasks still PLANNED/DISPATCHED. Terminal status alone cannot release an unresolved route. This can leave abandoned routes holding vehicles indefinitely; it is intentional fail-closed behavior until an authoritative closure operation exists.

## Proposed protected operations for a later route lifecycle stage

Propose separate complete-owned-route and abandon-unstarted-route RPCs, plus a restricted operator reconciliation operation. Names/signatures, route version/digest binding, idempotency storage, ACLs and any supporting migration require their own approval. They are not claimed to exist today.

- Derive NGO ownership from auth.uid(); verify owner, role and current route version/digest. A client-supplied NGO ID or success Boolean is not authority. Administrative reconciliation must use a separately granted trusted identity and recorded reason.
- Use a per-operation request key bound to actor, route, intended transition and expected version; persist the result for replay. Do not reuse the vehicle-registration request key as a route ledger.
- Define and test a global locking order with existing claim→lease→listing→task/custody operations, route assignment's route-first behavior, and vehicle locks. Do not assume a new route→vehicle sketch is compatible with every existing function. Acquire authoritative locks, recheck state/time and apply all successful closure effects in one transaction.

### Successful completion

1. Require every served source task already COLLECTED through existing protected pickup/reconciliation authority, with compatible completed claim/lease and custody evidence. Route closure must not manufacture collection, transfer ownership or mark a donation collected.
2. Verify exact route membership and no remaining unresolved stops/assignments from another route/version. Independently retain the executed plan and audit evidence when later snapshot/plan storage exists.
3. Clear only this route's active assignment rows after validation, then mark it COMPLETED. This order is necessary because the C1 route guard rejects terminal transitions while assignments remain. Persist closure/audit/request result atomically; rollback restores both hold and assignments on failure.
4. Recompute vehicle holds across all routes. Removing this route's hold does not release another route's hold, reactivate a retired vehicle or change the NGO's explicit availability choice. A still-active, available vehicle with current verified depot may become eligible again.

### Unstarted abandonment/cancellation

1. Allow safe abandonment only after proving no task started pickup, no custody/handover uncertainty, and no unresolved reconciliation or unauthorized route membership. AUTHORIZATIONS/RESERVATIONS, once implemented later, must be revoked through their protected authority before release.
2. A legitimately owned, still-active unstarted task may need a protected PLANNED→CONFIRMED deplan operation. It must retain the same claim owner and validate the lease/current listing state. Expired or uncertain custody requires the existing authoritative recovery/reconciliation path, not forced claim release by a route RPC.
3. Validate and remove/supersede only the active bindings for this exact route/version, resolve all PLANNED/DISPATCHED activity appropriately, then mark CANCELLED or STALE with a reason. Never use COMPLETED for unserved pickups. Keep terminal routes immutable; replanning uses a new route/version with approved history retention.
4. If any task already started or evidence disagrees, return a manual-review outcome and retain the hold until protected reconciliation resolves it. Do not introduce new donation statuses or silently cancel active claims.

### Important unresolved history/recovery interaction

The current recover_expired_claims treats **any** pickup_route_stops record as route activity/uncertainty, including historical terminal routes. cancel_claim has a different filter plus its active-assignment guard. Thus merely clearing assignments and setting a route CANCELLED/STALE does not guarantee ordinary claim recovery will resume.

Before implementation, explicitly approve how active route membership differs from retained historical execution evidence. Options require a reviewed historical-plan/archive model or a separately approved recovery-policy change with regression tests; deleting stops to hide custody evidence is unacceptable. C1 changes neither recovery nor cancellation. This decision is a blocker for a complete route-abandonment workflow, not a reason to weaken C1's guard now.

## Abandoned-route detection and emergency maintenance

A later worker may identify aged draft/validated routes as candidates using approved timeouts and current source state. It must call the protected operation or request operator review. No timeout currently exists in the deployed contract that safely authorizes automatic vehicle release. Do not add a silent janitor UPDATE.

For an urgent depot/graph-verification incident, a later approved workflow must stop affected dispatch through authoritative controls, reconcile in-flight custody, close/revoke affected route authority and only then change the depot. An immutable historical route snapshot should retain its original depot. Do not grant service_role permission to skip guards or use a caller-set exception flag. Exact behavior for started routes, partial collection and external outages needs separate review with the later dispatch model.

## Required later acceptance tests

Ownership/role attacks; idempotent retries; completion with uncollected members; assignment cleanup atomicity; stale/expired leases; mixed collected and unstarted tasks; active handover/reconciliation; two routes holding one vehicle; closure versus fleet edit/assignment/start/completion/recovery races; terminal reactivation; worker retries; failed audit/transaction rollback; historical-stop recovery semantics; and emergency verification with in-flight pickups.

No implementation of these operations begins with this package. Successful donation lifecycles remain direct AVAILABLE→CLAIMED→PICKUP_IN_PROGRESS→COLLECTED and hub SUBMITTED→HUB_ASSIGNED→AT_HUB→BATCHED→CLAIMED→PICKUP_IN_PROGRESS→COLLECTED.
