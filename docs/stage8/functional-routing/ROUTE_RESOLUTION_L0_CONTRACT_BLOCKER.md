# L0 contract contradiction — implementation stopped

29 October 2026. LOCAL source inspection only. No DEV access, database startup,
migration, account/fixture creation, service activation, APK build or business
operation occurred. No implementation SQL or application code was changed.

The user approved D01-D10 and L0-L6 subject to stopping on any contract
contradiction, required scope expansion or authorization issue. L0 reviewed the
dirty Git working tree, existing disposable PG17 harness, C.1 terminal/hold guards,
Stage A source locks and the persisted donation lifecycle. Prior work is untouched.

## Contradiction

The approved resolution design requires a dispatched-but-not-collected donation
to be safely returned to source availability after validated two-party no-handover
and source-possession evidence. The existing Start path changes the donation to
PICKUP_IN_PROGRESS. However, public.enforce_donation_transition() permits only
PICKUP_IN_PROGRESS -> COLLECTED; it has no no-handover return edge.

Source: supabase/migrations/20261027_persisted_donation_lifecycle.sql,
public.enforce_donation_transition(), approximately lines 203-227. It is attached
as trg_donation_transition to public.donations. Repository search found no later
migration replacement of that function. This is source/baseline evidence, not a
new live DEV function-definition observation.

Thus a finalizer that tries to return the existing Test 10-style donation to
AVAILABLE would fail INVALID_DONATION_TRANSITION. Updating only claim/lease/task
or route state would instead leave donation/listing/custody inconsistent. Merely
granting permissions or calling the private transition helper does not bypass
the row trigger. The normal existing CLAIMED -> AVAILABLE/BATCHED edges cover
never-started items, not this dispatched case.

The conceptual no-handover outcome was approved, but its required additional
donation-lifecycle edges were not explicitly specified in the approved transition
matrix. Under the express stop-on-contract-contradiction condition, implementation
has stopped before adding those edges or silently treating dispatch as collection.

## Recommended narrow contract amendment for approval

Permit the following LOCAL prototype transitions ONLY inside the restricted,
transactionally guarded route-resolution finalizer:

- DIRECT_DONATION/DIRECT_PICKUP: PICKUP_IN_PROGRESS -> AVAILABLE.
- HUB_BATCH/HUB_COLLECTION members: PICKUP_IN_PROGRESS -> BATCHED, atomically
  over the complete approved immutable member set.

Both require current two-party no-handover/source-possession agreement, exact
case/item/evidence version, no collection evidence, compatible source state,
safe listing validity, the finalizer's private transaction-bound permit and
required custody/lifecycle/resolution audits in the same transaction. No direct
client update, client GUC, service-role shortcut or public general-purpose reverse
transition is permitted. The transaction must also settle old task/claim/lease
and assignments consistently; source status alone is not a release operation.

Retain these boundaries:

- COLLECTED remains terminal; no uncollect or fictional handover.
- Expired/unsafe listing stays MANUAL_REVIEW under D04. No withdrawal mechanism.
- Original issue/expiry timestamps, frozen graph, optimization and scheduler remain
  unchanged. No change to recovery's function body is proposed.
- Reporting, evidence capture and finalization still require the approved actors,
  locks, idempotency, receipts and audit rules. No real-world evidence is invented.

This would explicitly add public.enforce_donation_transition() to the forward
migration's guarded source-change list and amend D03/D09/D10 and the LOCAL test
matrix. It is not authority to change DEV or the preserved route.

Required additional tests: ordinary and privileged non-finalizer attempts at both
new edges rejected; wrong/expired permit rejected; missing/conflicting/amended
evidence rejected; complete hub member atomicity; audit/receipt failure rollback;
never-started release unchanged; COLLECTED reverse transitions rejected; all
normal lifecycle edges and rejection cases unchanged. No trigger disabling.

## Alternative

Keep the existing donation lifecycle unchanged and classify every dispatched
no-handover case as MANUAL_REVIEW in version 1. This is fail-closed, but cannot
resolve the preserved Test 10 scenario or release its route/vehicle. Do not claim
the route-abandonment acceptance requirement is fulfilled with this limitation.

## Actual progress and result

- L0: source inventory and contradiction identified; STOP.
- L1-L6: not implemented; no new migration file/SHA-256 or new function/ACL matrix.
- Disposable acceptance/regression suites: NOT RUN. The 58 checks are still plans.
- Static inspection confirms the sole explicit PICKUP_IN_PROGRESS successor is
  COLLECTED. It is not a simulated SQL PASS or a fresh deployment fingerprint.
- Changed file for this implementation attempt: this report only.
- Status: NOT READY for implementation continuation or DEV deployment until the
  contradiction is resolved by an explicit contract decision.

Next decision: approve the two narrowly guarded LOCAL lifecycle edges above, or
choose the fail-closed/manual-review-only alternative. After that decision, resume
L0-L6 from existing work; do not restart the design or create duplicate migrations.

## Subsequent LOCAL decision — 29 October 2026

The user explicitly approved both narrow reverse-custody edges for LOCAL source
implementation and disposable PostgreSQL testing. The stop recorded above is
historical; that specific contract blocker is resolved for the local prototype.
It does not authorize DEV deployment or resolving the preserved route. Current
progress and actual test results are recorded separately in the implementation
review, rather than rewriting the historical stop evidence.
