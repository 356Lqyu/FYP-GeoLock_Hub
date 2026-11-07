# Route resolution — final design-decision register

Version 1 with LOCAL approval addendum, 29 October 2026. The user approved D01–D10
defaults for LOCAL prototype source and isolated tests only. D07 retention remains
provisional pending institutional requirements; D10 is not supervisor acceptance.
No DEV roles, deployments, fixtures or business operations are approved here.

### Approved narrow D03/D09/D10 transition amendment

Only the restricted finalizer may authorize `PICKUP_IN_PROGRESS → AVAILABLE`
for DIRECT_DONATION/DIRECT_PICKUP, or `PICKUP_IN_PROGRESS → BATCHED` atomically
for the complete immutable HUB_BATCH/HUB_COLLECTION member set. Require distinct
authenticated NGO/source statements confirming no handover and source possession,
current case/item/manifest/evidence versions, safe listing validity, compatible
source state and private transaction-bound permits. All task/claim/lease/assignment,
custody, audit and receipt updates commit together. No client GUC or privileged
helper invocation alone grants this authority. COLLECTED remains terminal.
Expired/unsafe listings retain MANUAL_REVIEW and holds; no withdrawal or forced
release. D09 recovery function and scheduler remain unchanged and must be tested.

| D03/D09/D10 edge | Authority and required outcome |
| --- | --- |
| DIRECT_DONATION / DIRECT_PICKUP: PICKUP_IN_PROGRESS → AVAILABLE | Restricted finalizer, matching current no-handover/source-possession evidence, private current-transaction permit, safe listing, atomic old task/claim/lease settlement and audit. |
| HUB_BATCH / HUB_COLLECTION: PICKUP_IN_PROGRESS → BATCHED | Same gate for the complete approved immutable member set; partial release rolls back. |
| Never-started CLAIMED → AVAILABLE/BATCHED | Existing lifecycle edge, but this workflow still requires matching evidence and the full finalization gate. |
| COLLECTED → any earlier state | Forbidden, including resolver calls; actual collection history remains terminal. |
| Unsafe/expired listing → AVAILABLE | Forbidden; MANUAL_REVIEW retains the route/item/vehicle holds. |
| IN_PROGRESS → ABANDONED | Only all-item evidence-based atomic finalization; no ordinary complete/cancel shortcut. |
| ABANDONED → another route state | Forbidden; later disputes append linked incidents without resurrection. |

This register refines ROUTE_INTERRUPTION_RESOLUTION_DESIGN.md. If approved, its
specific choices take precedence over alternatives in that earlier proposal.
LOCAL implementation/test scope is specified separately in
ROUTE_RESOLUTION_LOCAL_PLAN_AND_ACCEPTANCE.md. The synthetic fixture manifest
remains unchanged and unapproved; no fixture IDs have been bound.

## D01 — Exact meaning and transitions of ABANDONED

**Recommended default.** ABANDONED means: a previously started itinerary was not
completed as planned, but every item's custody/disposition and vehicle control
have been resolved and this route's reservations safely retired. It never means
all pickups were collected or that the normal depot-return itinerary succeeded.

Only new permitted public transition: IN_PROGRESS -> ABANDONED, through the
protected finalizer with a current resolution case. Reporting leaves IN_PROGRESS;
its separate case shows pending resolution. AUTHORISED routes retain the existing
unstarted CANCELLED path. COMPLETED/CANCELLED/STALE cannot become ABANDONED or
resume. ABANDONED has no outgoing route-state transition. Preserve all genuine
collected timestamps/states; released items get no fabricated collected_at.

Before terminalization: all bound items have known final outcomes, no unresolved
PLANNED/DISPATCHED item, no contested custody, required cases resolved, vehicle
accounted for, exact current evidence/version accepted. Archive and clear only
this route's assignments and close its binding atomically with the terminal audit.
Keep original stops, snapshot, candidate, attestation and audit history.

Captured schema uses route_status TEXT with a CHECK; default is to extend that
CHECK, not introduce a new enum. Pin the current baseline before local migration
design; do not assume an old dump proves current deployed type/constraints.

**Alternatives.** Separate ABANDONED/RECONCILED route states; reuse STALE; allow
immediate terminalization with unresolved items and separate holds.

**Risks.** Reusing an existing state hides a started failure; early terminalization
can free a vehicle through old terminal-set logic. One terminal state needs clear
per-item outcomes and analytics so partial collection is not counted as success.

**Exact approval needed.** Approve the above meaning, IN_PROGRESS-only incoming
transition, terminal immutability and all-item atomic-release gate (D01).

## D02 — Finalizer identity and authority

**Recommended default.** A dedicated restricted resolver principal, mapped to a
named human operator, may call only the scoped finalization/receipt functions
needed for this work. Its database role is separate from NGO/donor principals and
is neither a general administrator nor a service-role credential in Flutter.
Audit operator identity from trusted session/auth mapping; do not trust a supplied
operator UUID. A SECURITY DEFINER function owner is not the same as an authorized
caller. Pin both ownership/config and effective caller permissions.

The owning NGO may report interruption. The derived NGO and source participants
may submit their own evidence. Neither can finalize merely by owning a case.
HUB_ADMIN is a source participant for its own hub, not a global resolver.
The resolver cannot override absent/conflicting evidence or manufacture custody.
No operator account/role or grants are created by design approval alone.

**Alternatives.** Automatic finalization after consensus; owner-NGO finalization;
two independent operator approvals; a broad privileged backend.

**Risks.** A single operator remains an operational trust point; automation can
hide disputes. Separate principals do not prove separate human control in FYP
tests; disclose when one tester operates synthetic participant accounts.

**Exact approval needed.** Approve restricted operator-only finalization and no
override capability (D02). Name/bind the operator principal in a later deployment
package; previous installer/recovery approvals do not grant this new authority.

## D03 — Minimum no-handover evidence

**Recommended default.** For each uncollected item, obtain two explicit matching
statements: owning NGO says no handover occurred; authoritative donor/hub party
says no handover occurred and the complete goods/member set remains in source
custody. Bind assertions to case, task/claim, source, current evidence version and
server timestamps. Different authenticated principals, derived server-side, must
make the statements. No response, lease expiry, a task status or a route timeout
is not evidence of source possession.

Dispatched and never-started tasks both require this gate. Dispatched tasks also
need the explicit statement that Start did not result in actual transfer.
Existing COLLECTED evidence cannot be reversed by this process; disputed physical
custody after digital collection goes to review without erasing history.

For a hub batch, verify its entire immutable member set; no partial batch release.
The finalizer rechecks evidence, current source state, conflicts and eligibility
under locks, rather than trusting a client-produced ready flag.

**Alternatives.** NGO-only or donor-only declaration; automatic release of
never-started tasks; operator substitution; optional photographic evidence.

**Risks.** Two-party statements can still be false/collusive; they are not GPS or
physical proof. Requiring both parties can delay resolution but prevents guessing.
Photos introduce privacy/storage scope and are excluded from the first release.

**Exact approval needed.** Approve two-party no-handover plus source-possession
evidence for every uncollected task, without a one-party/operator shortcut (D03).

## D04 — Expired or otherwise ineligible listings

**Recommended default.** No automatic reopening. If a no-handover listing cannot
safely return to AVAILABLE using its existing validity/lifecycle rules, retain
MANUAL_REVIEW and the required holds. Do not extend windows, revive claims or
invent EXPIRED donation states. This conservative first release does not promise
to finalize every expired-listing case.

Valid no-handover settlement ends the old task as STALE and claim/lease as
RELEASED with a route-resolution reason; it never reuses the old claim/task.
New discovery/claiming uses normal eligibility and a newly issued lease.

**Alternatives.** Add an explicit donor-confirmed withdrawal disposition
(listing CLOSED plus a separately approved compatible donation transition);
support re-publication as a new listing; preserve every expired case indefinitely.

**Risks.** Conservative review can retain vehicle holds. Automatic closing without
a defined goods disposition creates inconsistent donation/listing state; reopening
an expired listing can advertise invalid goods. A withdrawal path needs a further
contract/state-transition decision and tests before coding it.

**Exact approval needed.** Approve MANUAL_REVIEW/no-reopen for unsafe listings in
version 1 (D04), acknowledging that a future withdrawal disposition may be needed.
Approval of D04 does not approve that future disposition.

## D05 — Vehicle return and custody accountability

**Recommended default.** Require a version-bound NGO statement that the vehicle is
back under NGO control at its registered depot, and a complete goods disposition:
collected goods accounted for in NGO custody; uncollected goods confirmed with
their source. Do not assert return or collection that did not occur. No GPS proof
is implemented or implied. Resolver checks the evidence and exact vehicle/binding
before finalization; inconsistencies remain under review.

Clear this route's assignments/binding only in the final transaction. Re-evaluate
the normal vehicle-hold helper afterward. Do not force available_for_planning=true
or remove any other route's hold. Keep original vehicle owner and version history.

**Alternatives.** Allow another approved secure location; release the vehicle
while item custody remains unresolved using a separate asset/custody hold model;
require signed driver/third-party proof or GPS.

**Risks.** The default is intentionally conservative: an otherwise physically
usable vehicle can remain held. Alternative-location or early-release designs
need more state and cannot be inferred from the current reservation mechanism.

**Exact approval needed.** Approve depot/control assertion, goods-accountability
gate and no early vehicle/assignment release for version 1 (D05).

## D06 — Conflicts, amendments and escalation

**Recommended default.** Evidence is append-only. A changed assertion supersedes
but does not delete its predecessor and increments case/evidence version.
Any amendment invalidates READY_FOR_FINALIZATION and the prior accepted digest.
Conflicting/unknown evidence sets MANUAL_REVIEW and retains holds. An operator
may request clarification, not set a ready flag or waive missing evidence.

Before finalization, lock the case and compare expected version plus current
evidence/manifest digest. An amendment winning the race makes finalization stale.
Once a terminal result commits, later claims of error create an append-only linked
incident; they do not mutate history, reopen ABANDONED or uncollect goods.
V1 does not implement forced incident settlement. No automated timeout adjudication.

**Alternatives.** Editable statements; last-writer-wins; operator override;
automatic release after a response deadline.

**Risks.** Stalemates require human follow-up. Losing superseded evidence or
accepting stale consensus permits false release; a generic override is a bypass.

**Exact approval needed.** Approve append-only amendments, invalidation, no override
and linked-incident handling for post-terminal disputes (D06).

## D07 — Retention and access

**Recommended default.** V1 retains minimal structured statements, provenance,
dispositions, request receipts and audit linkage; no attachments, live GPS, tokens
or free-form personal data beyond bounded operational notes. Propose retention
through FYP assessment plus 12 months, with manual review before disposal. No
automatic purge code in this release. Unresolved cases/incident holds cannot be
purged under that ordinary schedule; review them periodically. This is a proposed
project policy, not a claim of a legal retention requirement.

Owner NGO reads its route/case. Donor/hub participant reads only its items and the
minimum linked result, not other donors' claims, route stops or contact data.
Each actor reads its own request receipts. Named resolver gets the scoped evidence
needed for finalization. Anonymous, other NGOs, graph/planner/validator workers and
unapproved operators have no resolution access. Enforce scope inside SQL as well
as table privileges/RLS; SECURITY DEFINER must not bypass participant checks.

**Alternatives.** Shorter/redacted post-assessment retention; longer institutional
retention; attachment evidence with private storage and an explicit deletion plan.

**Risks.** Excess retention increases privacy exposure; early deletion undermines
appeal/replay/audit integrity. Actual retention/access policy must be reconciled
with applicable institutional requirements before real-user rollout.

**Exact approval needed.** Approve minimal/no-attachment evidence, the access matrix
and the proposed review-based retention period (D07). No deletion is authorized.

## D08 — Synthetic DEV semantics and audit labeling

**Recommended default.** Simulation is allowed only after a separately approved
manifest binds exact DEV project, participant, vehicle, fixture and claim IDs to
a test_run_id and manifest hash. Add a private, trusted-operator-managed test
provenance registry for LOCAL implementation. It grants no eligibility exemption.
Client-supplied simulation=true or a SYNTHETIC title alone is never authority.

For subsequent simulated handover/return/resolution events, derive audit details
test_run_id, manifest_digest and simulation=true server-side from that bound
provenance. Preserve ordinary event types/outcomes and all guards. No retroactive
editing of old audits; a later declaration is a new linked annotation with its own
actor/time, not proof that an earlier action was authorized as simulation.
History/metrics must exclude these records from physical collection evidence.

Normal non-test records keep existing validation and audit behavior. A fixture
test request containing any unbound/real record fails; it cannot turn real custody
into simulation or relax evidence requirements. Existing Boolean handover RPC
semantics must be explicitly amended to permit registered synthetic confirmations;
until that amendment is approved, documentation continues to require real handover.

Test publication visibility and control of competing DEV users must be explicit
before fixtures are published. Do not assume the registry creates discovery
isolation. If approved isolation cannot be achieved with the existing protected
flow, the live pilot remains blocked pending a separate visibility design.

**Alternatives.** Disposable PostgreSQL simulation only; local manifest labels
without database provenance; a dedicated test environment; broader test-only API.

**Risks.** Ordinary success audits without provenance can be mistaken for physical
handover; a client-controlled test flag is a bypass. Registry/audit enrichment
adds reviewed schema/helper scope. Independent login accounts may still be run
by one human in an explicitly disclosed synthetic FYP test.

**Exact approval needed.** Approve registered synthetic semantics and server-derived
labels for LOCAL implementation only (D08). Exact manifest, identities, publication
visibility, fixture creation and every live operation require later approvals.
Do not classify the preserved route as synthetic automatically.

## D09 — Recovery, guards, holds and atomicity

**Recommended default.** Reporting transitions unresolved ACTIVE claim/lease
statuses to RECONCILIATION_REQUIRED atomically, opening/linking existing cases;
already-reconciling cases are linked, completed records are untouched. Preserve
lease issued/expires timestamps and all collection evidence. Reporting is a future
write requiring approval, not something performed by this register.

Use the same NGO advisory lock and stable source/vehicle/route ordering across
report, existing execution, reconciliation and finalization. Specify additional
case/evidence lock order once, test it with recovery's existing lock sequence and
avoid holding database locks during network or participant interaction.

Keep cron's schedule/limit/activation unchanged. Existing recovery must continue
to recognize cases and retain uncertain custody. Do not edit it unless LOCAL
tests establish a specific compatibility defect; that finding needs a separate
scope decision before a recovery-body change. No second cron/auto-finalizer.

Update affected route CHECK/terminal guards, task-authority permits, hold logic,
protected readers, existing reconciliation interaction and frontend terminal
handling together. Finalization archives membership, settles permitted items,
clears only this route's assignments, closes its binding/case and audits atomically.
Transaction-bound permits are private; client-set GUCs cannot forge them.

Durable actor/request IDs bind canonical operation/payload digests. Same-ID same-
payload replay returns the committed result; changed payload conflicts. Expected
versions prevent stale settlement. Check current read authorization before replay.
Unknown outcomes require receipt reads, not a new ID or automatic retry. Audit or
receipt failure rolls back that transaction, not earlier committed collections.

**Alternatives.** Pause recovery during every resolution; rewrite recovery as the
resolver; direct operator SQL; release assignments item-by-item before all custody
is resolved. These are not approved defaults.

**Risks.** Lock-order drift causes deadlocks; terminal-set drift frees or strands
vehicles; a status-only patch can lose custody. Cron may continue to change expired
claims while this proposal awaits approval; preservation does not freeze live rows.

**Exact approval needed.** Approve future status-only reconciliation transitions,
unchanged deadlines/scheduler, coordinated guard changes and atomic/idempotent
settlement (D09). No present lease, route or scheduler change is authorized.

## D10 — Coordination Authority Contract amendments

**Recommended default.** Add an explicit interruption/resolution section defining
D01-D09 before implementing their SQL. It must distinguish planned authorization,
actual start, collection, no-handover release, vehicle accountability and ABANDONED.
Include participant/resolver authority, evidence amendment and disagreement,
active/expired claims, unsafe listing disposition, transaction/lock boundaries,
audit/receipt semantics, retained history and synthetic-vs-physical evidence.

Existing route optimization, capacity/window constraints, frozen graph, independent
validation and normal explicit/automatic authorization remain unchanged. No GPS
proximity requirement is added. Original report/contract wording must be reviewed
for exact clause placement; the local addendum is not supervisor acceptance.
Update FYP diagrams/API/UI descriptions and evaluation labels without rewriting
historical results or claiming successful physical collection.

**Alternatives.** Treat abandonment as cancellation; implement first and document
later; require formal supervisor approval of all details before any local prototype.

**Risks.** Contract/code divergence undermines the authority argument. Approval
from the project owner is not automatically formal academic/supervisor approval.

**Exact approval needed.** Approve this amendment scope for a local prototype (D10),
and provide/confirm authoritative contract text for clause-level revision. Formal
academic acceptance remains a separate human process where required.

## Approval and scope boundaries

To begin coding, approve D01-D10 defaults (or name amendments) AND the LOCAL scope
in ROUTE_RESOLUTION_LOCAL_PLAN_AND_ACCEPTANCE.md. Naming a deployment operator,
choosing fixture accounts or accepting DEV recovery risk is not implicit here.

Local code/migration preparation and disposable roles/fixtures/tests would be
authorized only by that next approval. No Supabase account, vehicle or donation
creation, DEV migration, grant, writer/scheduler change, API activation, APK build/
installation, current-route report/evidence/finalization or pilot business action
would be authorized. Every such action needs its own reviewed package/approval.

Current route db1b455e-92d0-4d58-9fa1-5de07d7ab0f9 and V2 remain held/preserved.
This document does not certify their live state or promise that cron has paused.
