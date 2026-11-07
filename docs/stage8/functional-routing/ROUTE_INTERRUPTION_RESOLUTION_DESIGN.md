# Route interruption and custody resolution — DESIGN ONLY

29 October 2026. NOT APPROVED FOR IMPLEMENTATION OR DEPLOYMENT.
No SQL, permissions, records, scheduler, graph, algorithm or lease expiry is
changed by this document. Proposed RPC names and states below do not exist yet.

## Purpose and existing boundaries

Permit reporting and evidence-based resolution of a started route that cannot
finish. Abandoning a plan must never mean asserting that all food was collected,
reopening uncertain goods or deleting routing history.

Reviewed sources: Stage A 002/003 publication, lock/remaining-route checks,
complete_pickup, cancel_my_unstarted_route, close_my_collected_route,
submit_claim_reconciliation, recovery, C.1 fleet/route guards and current Flutter
operation reconciliation. This is a source/evidence review, not a new live DEV
catalog inspection. Exact deployed definitions must be pinned before a migration.

Current contract gaps:

- Started routes cannot use the unstarted cancellation RPC.
- Normal closure requires every task COLLECTED and claim/lease COMPLETED.
- Recovery does not close routes or clear reservations.
- No-handover reconciliation cannot release PLANNED/reserved tasks or a dispatched
  no-handover task through its ordinary CONFIRMED/unassigned branch.
- The task-authority trigger, fleet terminal guard and vehicle-hold helper must
  all agree on a new resolution path; merely changing route_status is unsafe.

## 1. Report interruption; fence ordinary execution atomically

Proposed NGO action: Report route cannot continue, with an enumerated reason and
optional bounded note. Reasons include EXECUTION_BUDGET_EXCEEDED, VEHICLE_FAILURE,
PICKUP_UNAVAILABLE and OTHER_REQUIRES_REVIEW. A reason is a report, not proof of
custody or release authority.

Proposed report_my_route_interruption(p_route,p_reason,p_request) derives the NGO
from verified auth.uid(), checks ownership and captures the entire immutable
bound task set. The caller cannot supply replacement tasks, owners or timestamps.
Under the same NGO/route/source lock order as Start and reconciliation, it:

1. Creates or reuses one open route-resolution case and snapshots observations.
2. Leaves completed/collected claims and leases terminal and untouched.
3. Moves unresolved ACTIVE claim/lease pairs into RECONCILIATION_REQUIRED and
   opens/links existing claim-reconciliation cases, even if not expired. Already
   reconciliating pairs are linked; inconsistent/released pairs require review.
4. Leaves PLANNED/DISPATCHED tasks, donations, assignments and vehicle holds intact.
5. Preserves original lease issued/expires timestamps; no extension or clock reset.
6. Records an atomic interruption audit and receipt.

Moving unresolved claims out of ACTIVE fences existing Start/Complete paths as
well as the UI. A private open-resolution guard must additionally prevent old
write entrypoints from bypassing the fence; this is a separately reviewed future
contract change, not permission to weaken existing RPCs. Check ordering/races
before deploying any new entrypoint. A late Start/Complete either commits before
the report and is captured, or observes the fence and fails.

Public route status stays IN_PROGRESS while evidence is pending. Display a
separate resolution status such as Awaiting custody evidence. Do not prematurely
mark ABANDONED and accidentally make the vehicle available.

## 2. Per-item classification and evidence

Classification is derived server-side from task/item/claim/donation evidence,
including consumed_at, collected_at and original dispatch/collection transactions.

| Class | Minimum evidence | Permitted disposition |
|---|---|---|
| Already collected | Committed COLLECTED task/donation, completed claim/lease and corresponding item/audit evidence | Keep collected forever; account for NGO custody. Never reopen/reclaim |
| Dispatched, not collected | DISPATCHED/consumed_at; no collected_at | Determine actual custody; do not assume handover from Start |
| Never started | PLANNED, no consumed_at/collected_at | Confirm no handover and donor/hub retains goods; do not infer merely from task status |
| Inconsistent | Contradictory rows, missing sources, mismatched owners or timestamps | MANUAL_REVIEW; no settlement/release |

Statements are distinct assertions, not one ambiguous abandonment checkbox:
NO_HANDOVER_SOURCE_RETAINS_GOODS, HANDOVER_TO_NGO_CONFIRMED, UNKNOWN_CUSTODY,
and VEHICLE_RETURNED_TO_NGO_CONTROL. Assertions are proposed vocabulary.
Evidence about goods physically returned after actual collection requires a
separate return-of-custody design; it is not NO_HANDOVER and not in initial scope.

The NGO and authoritative source counterpart submit their own statements:
direct donation -> donor; hub batch -> authorized hub administrator. Derive these
participants from protected source relationships and bind them to the case.
Separate authenticated identities are required; one actor cannot count as both.
An operator cannot impersonate a donor or manufacture agreement.

- Matching no-handover statements plus confirmed source possession support a
  no-handover settlement, subject to current validity and the finalizer's checks.
- Matching handover statements only support collection if dispatch/custody checks
  permit it. Reuse the guarded existing reconciled-collection machinery for an
  actually started item; do not collect a never-started task to simplify closure.
- Missing, conflicting, unknown or stale assertions retain the hold and enter
  MANUAL_REVIEW. A claim with digital COLLECTED but disputed physical custody also
  requires review; never erase its terminal history to hide the discrepancy.
- Confirmation is participant evidence, not GPS/physical proof. Attachments, if
  added later, need private storage/access/retention rules; no public photo URLs.

## 3. Active/expired leases and reopening decisions

Reporting does not wait for expiry. Active and expired unresolved leases enter
the same evidence process; original deadlines remain immutable. Expiry is never
proof that the source still has the goods. Completed leases remain completed.

The proposed no-handover finalizer ends the old claim/lease as RELEASED, records a
specific ROUTE_INTERRUPTED_NO_HANDOVER reason, and ends its old task as STALE.
Do not return a released claim's old task to CONFIRMED. A later protected claim
creates a new claim/lease/task with a new identity and its normal deadline.

Reopen the listing and donor-owned donation only when all source members are
accounted for, no handover is confirmed by the required parties, listing validity
still permits it and current custody is compatible with the approved lifecycle.
Revalidate discovery/claim eligibility normally; release does not promise that
every NGO can discover or claim it.

Expired/ineligible listing or ambiguous donation lifecycle: default MANUAL_REVIEW,
not AVAILABLE. Before implementation choose and approve an explicit donor-side
withdrawal/expiry disposition using allowed states, or leave such items blocked.
Do not invent an EXPIRED donation state or silently change availability windows.
Hub batches are atomic over the immutable member set; mixed custody blocks them.

## 4. Terminal route and release transaction

Recommend one new public route terminal state ABANDONED, with the case recording
RESOLVED and counts/dispositions. It means original itinerary not completed,
custody and reservations reconciled. It must never be reported as COMPLETED or
count as a successful route experiment. Do not reuse CANCELLED or STALE to disguise
a started route. A separate RECONCILED route enum is unnecessary initially.

Terminal prerequisites, checked under locks against current rows:

- Every bound task has a permitted final disposition: retained collected or
  evidenced no-handover released/withdrawn. No PLANNED/DISPATCHED/unknown item.
- All relevant cases/evidence are consistent, current and bound to exactly this
  route/task set. Every disputed item is resolved, not merely labelled reviewed.
- Collected goods are accounted for in NGO custody and source goods remain with
  their source. Proposed NGO vehicle-return/control confirmation is present;
  conflicting vehicle/custody statements block closure. Do not assert an actual
  return that has not occurred. Synthetic tests need explicit simulation scope.
- Vehicle owner/version, binding and assignment relationships match. Other routes'
  assignments/holds are never deleted or overwritten.
- Required events and the idempotent result can be persisted in the same commit.

One finalization transaction performs all no-handover settlements and authority
permits, archives assignment membership, removes only this route's active
assignments, marks its items released, closes its binding/case and sets ABANDONED.
Keep pickup_route_stops, snapshots, candidate, validation and existing timestamps.
Do not fabricate collected_at for released items. Ensure the task guard's permit
is transaction-bound and inaccessible to client SQL/GUC spoofing.

The transaction must leave no PLANNED/DISPATCHED stop that would keep C.1's
vehicle_has_hold true. After commit evaluate the normal hold/availability helper;
do not blindly set vehicle.available_for_planning=true. Another hold or inactive
vehicle may still make it unavailable. Before commit no reservation is freed.

Existing legitimate two-party reconciled collections may settle a dispatched item
before finalization, retaining all evidence and holds. If finalization fails,
those earlier committed collections remain; its own partial releases roll back.
Initial implementation should not support arbitrary per-item release before the
entire no-handover manifest can safely finalize.

## 5. Proposed schema and RPC contract

Private schema additions (names illustrative):

- route_resolution_cases: route/NGO, case version/status, reason, observation
  digest, immutable task-manifest digest, reporter/time and final disposition.
  Partial unique constraint: at most one open case per route.
- route_resolution_items: case/task, original authoritative observations,
  derived classification, approved disposition and evidence-version digest.
- route_resolution_evidence: immutable actor/role/assertion/task/version/time,
  supersession link and optional private evidence reference. Never overwrite past
  statements; an amendment invalidates the prior ready-to-finalize digest.
- route_resolution_requests: actor/request UUID, operation, canonical payload
  digest and committed response. Unique actor/request; conflict on changed payload.
- assignment_release_history or equivalent immutable resolution ledger: preserve
  this route's former active membership and reason for its final release.

Link to existing claim cases/evidence rather than inventing an independent truth
system. Existing evidence may be reused only when its scope, version and meaning
match. Review existing fixed Boolean API before introducing typed assertions.

| Proposed RPC | Caller and effect |
|---|---|
| report_my_route_interruption(route,reason,request) | Owning NGO; report/fence/open cases; no release |
| get_my_route_resolution(route) | Owner-scoped READ ONLY; status, own scope and allowed actions |
| get_my_route_resolution_receipt(request) | Actor-scoped STABLE READ ONLY; committed outcome only |
| submit_route_resolution_evidence(case,task,assertion,version,request) | Derived authorized participant; append own evidence only |
| finalize_route_resolution(case,expected_version,request) | Dedicated restricted resolver identity; validate all evidence and settle atomically |

Recommendation for first release: trusted operator explicitly finalizes after
independent participant submissions. Do not repurpose HUB_ADMIN as a global route
administrator or expose service-role credentials to Flutter. The resolver cannot
override missing evidence; disputed exceptions need an additional approved design.
Ordinary planner/validator/graph worker/anon cannot execute write-resolution RPCs.

Security: owned schemas/tables have no direct client DML; SECURITY DEFINER owner,
pinned search_path, explicit schema qualification and narrow ACLs. Do not trust
caller actor IDs, success flags, case status or proposed transition timestamps.
Read-only readers must not call locking helpers (regression for the prior defect).

Locks: preserve the existing NGO advisory lock, stable ordered claim/lease/
listing/custody locks, vehicle, route, tasks/binding; append case/evidence locks
in one documented order across report, submission, recovery and finalization.
Use current committed evidence, expected case version and exact payload digests.
No long network/participant interaction while database locks are held.

Idempotency: persist request UUID before sending, reuse identical payload only,
return the original committed result on replay, reject payload/actor conflicts.
Uncertain responses are reconciled by receipt read; NOT_FOUND while a write may
be in flight is not rollback proof. No automatic different-ID retries or new case.

Audit events, proposed: ROUTE_INTERRUPTION_REPORTED,
ROUTE_RESOLUTION_EVIDENCE_SUBMITTED/SUPERSEDED, ROUTE_RESOLUTION_REVIEW_REQUIRED,
CLAIM_RESOLVED_NO_HANDOVER, ROUTE_ASSIGNMENTS_RELEASED and
ROUTE_ABANDONED_RECONCILED, plus existing lifecycle/reconciliation audits.
Include actor, route/case/task/claim/lease, request, before/after, reason, case/
evidence versions, transaction and simulation provenance where approved. Required
success audit/receipt failures roll back the transaction. Rejected requests must
not leave false success events. No secrets or unrestricted private attachments.

## 6. Required forward schema/contract changes

Pin deployed route-status representation (enum/check) before choosing DDL. Add
ABANDONED safely; do not modify historical migrations. Update every terminal-set
consumer: C.1 route guard/vehicle-hold invariants, route authority reader, active
assignment/task trigger permits, finishRouteOperation terminal checks, receipt/
history UI and audit analytics. Preserve existing explicit/automatic authorization.
Update claim-resolution scope without weakening existing normal completion or
safe-release checks. Recovery must recognize linked open cases and retain all
unresolved route holds; it must not race the new resolver into duplicate cases.
Review applicable constraints/indexes, FK consistency, privileges and storage RLS.

Coordination Authority Contract amendments needed:

1. Route interruption is separate from cancellation, collection and depot return.
2. Define item classification, custody assertions, participants and disagreement.
3. Define the active/expired lease-to-reconciliation transition without extensions.
4. Define no-handover release, expired-listing disposition and retained collection.
5. Define terminal ABANDONED, all-item closure conditions and reservation release.
6. Define resolver authority, concurrency, idempotency and uncertain outcomes.
7. Explicitly separate synthetic test confirmations from physical handover proof.
8. Define audit retention and read visibility, including no false success metrics.

The local addendum references original report/supervisor/contract material, but
the authoritative original documents were not supplied for this review. Exact
clause numbering and formal supervisor acceptance remain review prerequisites;
this document does not claim either. Proposed objectives, research algorithms,
graph provenance and route planning/validation contracts remain unchanged.

## 7. Applying the design later to the preserved route

Route db1b455e-92d0-4d58-9fa1-5de07d7ab0f9: last verified IN_PROGRESS, V2 held;
Test 10 DISPATCHED/PICKUP_IN_PROGRESS; test c and Test 42 PLANNED. No collection
was performed by Codex. No physical food handover was reported by the operator.

After implementation, isolated tests, separate DEV deployment and exact-operation
approval: fresh reads first, then report interruption. Link any cases already
created by cron; never reset claims/leases to ACTIVE or erase expiry evidence.
Obtain separate authorized participant statements for each item. Test 10 needs
explicit no-handover/source-possession evidence despite its dispatch marker.
Never-started items also need source confirmation before reopening. A synthetic
classification itself requires owner approval/evidence; titles are not proof.

If every no-handover/custody/validity/vehicle condition is satisfied, finalize as
ABANDONED, release old claims/tasks through approved transitions, clear only its
assignments and release its binding hold. Preserve original route/stop/candidate/
snapshot/audit records. If any evidence conflicts or a listing lacks a safe
disposition, keep MANUAL_REVIEW and all required holds. No promise of automatic
resolution is made from the current partial evidence.

## 8. Disposable PostgreSQL acceptance plan — NOT RUN

Use a PostgreSQL 17 isolated cluster/database with disposable synthetic fixtures,
the exact pinned DEV-baseline function/schema contract and required extensions.
Assert local target/port/database, use no DEV secrets/network URLs or live IDs as
action targets, disable production cron and use fake auth adapters only in the
isolated lane. Run true READ ONLY reader tests as well as real SQL transactions.

Required tests:

- Never-started, dispatched/no-handover, real collected and inconsistent mixtures.
- Active, expired, completed and already-reconciliating leases; unchanged deadlines.
- Both no-handover, both handover, one party, conflict, different source participant,
  self-counterparty, replay and amended evidence invalidating a finalization.
- Expired listing, missing source, mixed hub custody and changed member manifest.
- Wrong NGO, donor, hub admin, anon, planner/validator and unprivileged resolver;
  no direct DML/GUC permit forgery; owner-scoped read/receipt leakage tests.
- Report vs Start/Complete/recovery, participant submission vs finalize, two
  finalizers, two claim attempts after release, and conflicting request payloads.
- Lost HTTP/commit response; same-request replay produces one outcome/audit set;
  no second route/case/release; NOT_FOUND during in-flight request stays uncertain.
- Failure injection after each finalization stage/audit/receipt: atomic rollback,
  retained holds, no false collection, and no partial assignment deletion.
- Terminal guard/hold consistency, preserved history, completed-task immutability,
  other-route holds, normal cancellation/closure/authorization regression.
- Synthetic-specific test authorization cannot operate on real/unlabelled fixtures.

Count and verify source custody, donation/listing/claim/lease/task states, every
active assignment and item timestamp, vehicle hold, terminal status, receipts and
audit linkage before/after. Contract failure is not a reason to weaken tests.

## 9. Decisions, approvals and implementation sequence

Required design decisions: ABANDONED naming; restricted operator finalization;
minimum two-party/source-possession evidence; expired-listing disposition;
vehicle-return/accountability assertion; amendment/escalation and retention policy;
whether synthetic operations are allowed and how records are labelled.

Recommended sequence:
1. Approve this design and amend/review the authority contract; resolve open choices.
2. Approve LOCAL implementation only: one forward migration, protected reads/
   writes, operator interface and Flutter reporting; no DEV deployment.
3. Pass disposable SQL, concurrency, security and Flutter/API tests; review diffs.
4. Separately review DEV migration fingerprints, backup/recovery, writer controls,
   postflight and compatibility with active recovery. No blanket scheduler changes.
5. Approve exact DEV deployment; deploy and verify without resolving this route.
6. Approve current-route report/evidence/finalization individually after fresh reads.
7. Approve and bind the independent synthetic pilot manifest; run its staged test.

Before finalizer writes exist, schema/code rollback can leave tables inert and
permissions disabled. After dispositions commit, down-migration or restoring old
code is not a custody rollback: preserve records and use an approved forward fix.
No automated reset, uncollect, history deletion or clock manipulation is permitted.
