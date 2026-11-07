# V2 interrupted route: preparation only

30 October 2026. No connection or business operation authorized by this document.
Target: db1b455e-92d0-4d58-9fa1-5de07d7ab0f9. Preserve completed V3 route
7dd2d00a-ff03-4021-994f-155bbfc8e12c and all evidence.

## Prepared capture

Run-V2ResolutionPreparation.ps1 defaults to local validation. -ExecuteReadOnly
also requires a ConnectionApprovalRef after separate approval. It reuses validated
native argument construction and only geolock_dev_owner_export, PostgreSQL 17.11,
session pooler 5432, approved CA, verify-full and a native hidden password prompt.
No password argument, transcript, stored password, fallback or retry is used.
Evidence goes to a new results/v2-resolution-preparation/<UTC>-native-<suffix>.

v2_resolution_preparation.readonly.sql uses SELECT-only inspection inside
REPEATABLE READ READ ONLY, identity/TLS guard, statement/lock/idle limits, ROLLBACK.
It reads only the target items/cases/statements/source identities/windows,
route/binding/assignments, bounded audits, relevant function definitions/settings/
ACLs/effective grants, resolver roles and optional installed capability/config/
operators/statements/registry. A small V3 preservation snapshot is included.
Optional tables are inspected only if present. No protected business RPC is called.
Missing schema/column or denied permission stops capture; never repair or retry.
Local SQL structural validation is not server compilation or DEV compatibility.

## Existing LOCAL prototype assessment

Migration: 20261106_route_interruption_resolution.sql, unchanged SHA-256
a8fc83b18da4ae13d771ae7ce513d5596a24cfbfdd8633d049da7da4db424020.
The later ROUTE_RESOLUTION_RELEASE_GATE.md supersedes the earlier audit-identity
security hold; its isolated results are existing evidence, not rerun here.

report_my_route_interruption accepts a started open IN_PROGRESS owned route.
Uncollected ACTIVE or RECONCILIATION_REQUIRED claims/leases are supported: expired
lease timestamps are not extended and do not by themselves disqualify resolution.
It classifies consumed/uncollected as DISPATCHED, unconsumed as NEVER_STARTED and
preserves consistent COLLECTED items. Existing assignments/vehicle hold remain.

submit_route_resolution_evidence is authenticated participant-only, versioned and
append-only. No-handover means no transfer and source retains the complete goods;
it is not a substitute for unknown custody. Current source actor derives from DB.
NGO vehicle-accountability statement is also required. finalize_route_resolution
requires the enabled gate, mapped restricted native resolver, no mixed JWT
context, current case/manifest/evidence/source/binding/vehicle versions and exact
assignments. Ordinary NGO/donor/service calls cannot finalize. Synthetic provenance
comes only from a trusted registry; names/client assertions do not grant it.

## Per-item path, conditional on capture and truthful evidence

- Test 10: DISPATCHED/PICKUP_IN_PROGRESS is not proof of collection. If both NGO
  and authoritative donor truthfully confirm no handover and source possession,
  restricted finalizer can use private transaction-bound authorization for
  PICKUP_IN_PROGRESS -> AVAILABLE. Unknown/conflicting or prior positive handover
  evidence prevents this. Actual collection must be established through its
  supported protected reconciliation path, never simulated to unlock the vehicle.
- test c and Test 42: PLANNED/CLAIMED, never started only if consumed_at confirms
  that classification. With truthful matching no-handover/source-possession
  statements and safe windows, restricted finalizer uses CLAIMED -> AVAILABLE.
  Existing submit_claim_reconciliation(false) cannot release these route-bound
  PLANNED tasks; its release branch requires CONFIRMED and unassigned.
- Already genuinely COLLECTED donations remain terminal, with completed claims/
  leases and closed listings. The new finalizer does not fabricate collection.

Successful no-handover finalization atomically makes uncollected direct donations
AVAILABLE, listings AVAILABLE, old claims/leases RELEASED, tasks STALE and claim
cases RESOLVED_RELEASED. It archives assignment evidence, removes active
assignments, releases route items, closes the binding, sets route ABANDONED,
resolves the interruption case and retires this route's vehicle hold. Preserve
old IDs, snapshots, stops, receipts and audit history. Subsequent discovery still
requires normal location/listing/claim eligibility.

## Unsafe expiry is a hard blocker

If any listing has expired or donation availability ended, the finalizer records
MANUAL_REVIEW/UNSAFE_LISTING_VALIDITY before its release loop. It performs no partial
item release, no route abandonment and no vehicle release. Existing claim cases
and custody holds remain; the interruption case enters MANUAL_REVIEW. It does not
extend, withdraw, force-republish or replace records. Resolving genuinely unsafe
listings requires a separately approved contract/design and tested protected path,
not merely operator permission to override. Mixed/unknown custody also blocks.

## Approval gates

1. Approve ONE operator-run native read-only capture only. Review actual cases,
   participant identities/statements, windows, assignments, definitions/grants and
   installed capabilities before deciding whether release is possible.
2. Reconciliation case-reader 42702 correction remains separate: prepare an exact
   baseline-guarded forward correction and isolated tests before any deployment.
   It is useful for participant visibility but not required for this native capture.
3. If resolution is absent, separately refresh deployment controls and review the
   existing pinned migration, immediate guard/audit-trigger effects, current backup,
   recovery risks, installer and maintenance plan. Do not weaken baseline guards.
4. Obtain separate migration execution, restricted operator identity/mapping,
   workflow activation and synthetic-provenance decisions. Deploy disabled first.
   Local contract drafting is not supervisor acceptance; retention is provisional.
5. Approve one interruption report, then exact truthful participant statements with
   explicit versions/request IDs. Reconcile uncertain writes read-only; no retries.
6. Only when all items and vehicle accountability pass, separately approve one
   restricted finalization. Check actual receipts and postflight before any new
   claim. Any unsafe listing or disputed custody stops this execution path.

Current readiness: preparation package locally validated; database capture and
resolution execution NOT AUTHORIZED and NOT RUN. No backend source changed.
