# Claim-scoped reconciliation: local implementation

**Status:** local forward migration and client changes; not deployed.  
**Migration:** `forward-migrations/20261109_claim_scoped_reconciliation.sql`.  
**Prerequisite:** the complete routing and reconciliation chain through `20261108_per_stop_reconciliation.sql`.

## Behavior change

| Case | Previous route-oriented behavior | Claim-scoped behavior |
|---|---|---|
| Expiry before pickup | A route assignment or route-stop row alone could force `RECONCILIATION_REQUIRED`. | Assignment alone is not custody evidence. Recovery checks task state and immutable route dispatch/collection markers. If still unstarted, it detaches and releases only that stop. It preserves the listing's expiry timestamp and lifecycle-consistent `AVAILABLE` status; claim and eligibility checks still reject the past expiry. |
| Expiry on an active route | Broad route checks could strand an unstarted stop and route. | Safe release records an auditable deferred-stop outcome; unrelated stops remain assigned when the remaining route passes feasibility checks. Vehicle/route closure still requires explicit depot return. |
| Expiry after dispatch | Donor/NGO statements could be mistaken for proof that no physical transfer occurred. | Recovery opens an individual claim case. Matching Not Collected statements after dispatch remain unresolved; no reassignment or automatic custody reversal occurs. |
| New route interruption | A participant could open a route-wide case and collect per-stop and vehicle statements. | Normal UI no longer offers route reporting. The RPC remains for compatibility but refuses to create a new case. Existing cases retain read/evidence/finalization support. |
| Existing route case | Route-wide evidence and restricted resolver provide a transition path. | Preserved unchanged for legacy records; no evidence is converted or deleted. |

## Safety and unresolved custody

The recovery transaction locks the managed route before it locks claim/task rows, matching route execution's lock order. It revalidates lease and claim after locking. A route member is detached only if it has no dispatch or collection marker, the task remains unstarted, no unresolved legacy route case holds that route, and the remaining active route passes `check_remaining`. A transaction-bound permit allows the existing task guard to accept the `STALE` transition; assignment release, immutable route-item release and deferred-stop finalization occur in the same transaction. Source-pinned patches normalize CRLF function bodies to LF before applying exact, fail-closed drift checks; unexpected SQLSTATEs from the release helper abort recovery, while known application feasibility exceptions fail closed as an uncertain claim. The donation lifecycle constraint requires an `AVAILABLE` listing whenever a direct donation is `AVAILABLE` or a batch donation is `BATCHED`. Therefore recovery preserves `listing_status='AVAILABLE'` and the original past expiry; the normal claim RPC rejects it as `LISTING_EXPIRED`, and eligibility reads exclude it.

For an already dispatched claim, insufficient or conflicting evidence remains `MANUAL_REVIEW`. The safe disposition is to keep the claim/listing unavailable for reassignment and preserve the vehicle/route hold until authoritative evidence or an authorized existing resolution path establishes an outcome. No participant UI is added for adjudication. Test 10's route case remains on its legacy path; the migration does not resolve or transform it.

## Compatibility and rollout notes

- Historical route cases, evidence, RPC signatures, restricted resolver, request receipts and audit tables remain.
- `report_my_route_interruption` can still replay/refer to an existing legacy case. It raises `NEW_ROUTE_INTERRUPTION_REPORTS_RETIRED` if no case exists; it no longer opens a new participant route case.
- The ordinary NGO route detail directs a custody hold to the affected claim. Donors retain individual claim statements. The route-case inbox and details remain available for existing cases.
- Claim, lease, listing and complete hub-batch state updates remain atomic. Vehicle assignment/return guards and route closure confirmations remain active.
- The migration is a source-pinned dynamic patch against the existing recovery/deferral/report routines. Deployment must first compare current deployed function bodies, ACLs, trigger definitions and the complete 20261101–20261108 migration chain. Any drift is a stop condition; do not edit the old migrations to force compatibility.
- Rollback is forward-only: restore the prior function definitions and ACLs in a new reviewed migration. Do not delete deferred records, claim evidence or legacy route history.

## Local validation matrix

`supabase/tests/route_resolution_isolated_test.py` contains disposable-local PostgreSQL scenarios 90–100 for safe active-route expiry, route continuation and depot closure, dispatched expiry with matching Not Collected statements, matching Collected statements, expiry/completion race, prevention of new route reports, preservation after confirmed collection, expired hub-listing/batch state consistency, and propagation of unexpected SQLSTATEs. Before applying the migration, the runner recreates all four patched functions with CRLF `pg_get_functiondef` input and confirms the resulting definitions are valid. Legacy scenarios 64–66 use synthetic pre-existing route cases to exercise evidence replay and restricted finalization after the new migration. They do not access or modify hosted Test 10 data.

Phase 2B validation ran the full local chain through this migration on PostgreSQL 17 in a fresh disposable instance. Scenarios 64–81 passed in the legacy/compatibility segment; scenarios 82–98 passed 13/13 in the final acceptance segment. Across those passing segments, 31 tests passed. Phase 2D reruns the full suite with CRLF fixtures and scenarios 99–100. This is local runtime evidence, not Supabase DEV or extension-version parity. The Flutter app completed `pub get`, the no-write formatting check, `flutter analyze`, and four reconciliation/route test files (92 passed).

