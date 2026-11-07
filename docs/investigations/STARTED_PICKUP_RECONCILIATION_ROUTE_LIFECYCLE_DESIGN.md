# Started-pickup reconciliation and route lifecycle — design proposal

2026-11-04 (MYT). **Proposal only.** Reuses the three completed investigation/implementation reports and targeted local contract inspection. No new DEV queries, mutations, code/migration changes, worker activation or push were performed. Earlier test passes establish the earlier implementation only; this proposed behavior has not been implemented or tested.

## Recommended model

Keep existing donation, claim, lease, task and route states. Two consistent, authorized participant statements resolve the **claim's custody outcome**; a separate owning-NGO action resolves **vehicle accountability and route closure**. Starting pickup is evidence of dispatch, not proof that handover occurred. Preserve that start evidence even when the final outcome is uncollected.

Reuse submit_claim_reconciliation, its collection helpers, deferred-stop outcomes, transaction-scoped release permits, and the existing cancellation/closure RPCs. Do not route ordinary matching evidence through an operator role. Keep MANUAL_REVIEW as an internal existing unresolved state for disagreement/integrity conflicts, with a clear participant-facing reason; it must not imply that an administrator will arrive.

## 1. Reconciliation decision table

All successful decisions require the actual distinct NGO and donor/hub participant, the complete source/member set, current claim ownership, consistent route/item/task links, and locked revalidation. They apply equally to OPEN and eligible existing MANUAL_REVIEW cases; the latter cannot be categorically rejected.

| Effective participant statements | Decision for a started pickup | Persisted result |
|---|---|---|
| Only one response | Awaiting Counterpart | No release or collection; case remains unresolved, claim/lease RECONCILIATION_REQUIRED |
| Both NO HANDOVER; no collection, unresolved incident or other custody conflict | Protected no-handover release | Case RESOLVED_RELEASED; claim/lease RELEASED; task STALE; stop RESOLVED_UNCOLLECTED; direct goods AVAILABLE, hub goods/inventory BATCHED |
| Both HANDOVER; compatible dispatched/collected task and source states | Existing protected reconciled collection | Case RESOLVED_COLLECTED; claim/lease COMPLETED; task/donation COLLECTED; route item collected_at recorded; vehicle hold retained |
| Opposing responses | Disagreement — joint review needed | Case remains MANUAL_REVIEW/PARTY_EVIDENCE_CONFLICT; neither release nor collection |
| Matching responses but collection records, missing membership, incompatible source/batch states, participant drift or unresolved incident contradict them | Integrity/custody conflict | No automatic transition; retain existing unresolved state and explain the exact blocker |

Expiry after dispatch only opens reconciliation. It never substitutes for either participant's statement. A statement timeout never becomes consent. Participant assertions cannot reverse authoritative COLLECTED/COMPLETED history.

## 2. Route lifecycle decision table

Classify the full historical manifest with explicit missing-evidence rejection; do not infer outcomes from active-claim counts or use inner joins that hide missing members. Use shared private classification for reader flags and locked mutations.

| Route/evidence | Action | Route and vehicle outcome |
|---|---|---|
| AUTHORISED, never started, every member safely released | Explicit protected cancellation; no depot assertion | CANCELLED; cancellation outcome NO_COLLECTION; binding closed |
| AUTHORISED, valid pickups remain | Keep actionable; start only with fresh per-stop authority | Remains AUTHORISED until pickup starts; no automatic cancellation |
| IN_PROGRESS, every stop collected | Existing close_my_collected_route after vehicle/depot confirmation | COMPLETED; collected outcome; binding closed |
| IN_PROGRESS, collected plus safely released stops, every stop final | Existing close_my_resolved_route after vehicle/depot confirmation | ABANDONED; closure outcome MIXED_OUTCOME; binding closed |
| IN_PROGRESS, every stop safely released, zero collection | Existing close_my_resolved_route with explicit **vehicle** return/accountability confirmation | ABANDONED; closure outcome NO_COLLECTION; binding closed |
| Some stops resolved, valid active work remains | Continue only if check_remaining authorizes it | Route remains open; no final closure |
| Any pending statement, disagreement, unresolved incident or custody conflict | Show required participant action/blocker | Route and vehicle hold remain open |

For a started zero-collection route, confirm **“The vehicle is back at its registered NGO depot and under NGO control.”** This retains the existing depot-origin planning safeguard and the meaning of p_depot_return_confirmed. It does not assert that any goods were returned. If the vehicle is not back, leave the hold open. No new closure RPC or repurposed boolean is needed. No GPS proof is claimed.

Keep route_status separate from outcome: ABANDONED describes a started route that ended without all pickups collected; NO_COLLECTION or MIXED_OUTCOME describes what happened to its goods. Add an explicit reader closure_kind/outcome field rather than overloading the existing closure_outcome='ABANDONED' routing hint. Preserve that legacy hint during client compatibility, and audit/receipt the final outcome and counts separately. Historical member count is not collected count.

## 3. Required protected SQL changes

**Started no-handover release.** Extend submit_claim_reconciliation to delegate its false/false decision to one narrow private helper. Under the existing READ COMMITTED NGO/source/vehicle/route/task locks, require expired claim reconciliation, exactly the two effective authorized false statements, DISPATCHED task with its matching consumed route item, no collected_at or collection/completion evidence, an open owned binding, consistent source goods, and no unresolved incident/whole-route hold. The normal unstarted release branch remains supported. Legacy tasks without complete managed-route authority need separate review, not a fabricated route association.

The helper mints a task-and-transaction-bound permit using the existing release-permit mechanism. The donation transition guard currently allows PICKUP_IN_PROGRESS → AVAILABLE/BATCHED only through resolution_private.release_allowed and legacy operator permits; add an equally narrow participant-reconciliation authorization predicate. Do not broadly legalize that reversal or create a caller-settable bypass. Use geolock_transition_listing_donations for the complete locked source set and preserve its audit/eligibility side effects. Tighten the corresponding task-release authorization to accept this validated permit, not merely a RECONCILIATION_REQUIRED label.

Atomically mark task STALE, claim/lease RELEASED with a distinct started-no-handover reason, remove only its active assignment, mark its item released and its stop RESOLVED_UNCOLLECTED, resolve the claim case, and audit that dispatch occurred but no handover occurred. Preserve bindings.started_at, items.consumed_at/dispatch_xid, the manifest, original statements and audit. Reuse the existing deferred-stop table for the final outcome: create a protected DEFERRED → RESOLVED_UNCOLLECTED record inside this transaction when none exists, clearly identifying reconciliation as its origin. Do not require the NGO to “skip” an already dispatched task or relax the public deferral RPC's unstarted-only rule. Keep the vehicle binding open.

**Availability is separate from custody.** A successfully established no-handover outcome must not remain unresolved solely because the listing's time window expired. Return direct goods to AVAILABLE (hub goods to BATCHED), but reopen the listing only when currently eligible; otherwise use existing CLOSED listing semantics with an audited expiry reason. Preserve existing availability-window, road, batch and eligibility-refresh checks; AVAILABLE goods do not guarantee discovery. No new EXPIRED listing or route state is proposed.

**Both-handover completion.** The existing permit_reconciled_collection → guarded task update → finish_reconciled_collection chain already supports consistent two-party completion after expiry, including recorded collected_at and retained vehicle hold. Reuse it; do not call ordinary complete_pickup with an expired ACTIVE lease or require a third participant action. Its existing source/batch checks still apply. If evidence rounds are added, update its exact-two-evidence checks to the active round only.

**Existing cases and retries.** Submitting a repeated old evidence request returns its original receipt; it must not secretly re-run a new policy. Add a small explicit owner/participant-authorized resolve_my_claim_reconciliation(claim, request) RPC for already-submitted matching evidence, including Food Can. It invokes the same locked decision helper without changing statements or bypassing integrity checks, is idempotent, and reports either the authoritative resolved result or a precise blocker. Both participant UIs can offer it when backend can_resolve is true. New cases still resolve automatically when the second matching statement arrives. No bulk historical cleanup or hidden writes in read RPCs.

**Closure and projections.** Update close_my_resolved_route to distinguish all-uncollected from mixed outcomes, reuse its durable mixed_route_closures receipt/accountability marker, and never record goods-return evidence for NO_COLLECTION. Keep its same-request replay ahead of new eligibility checks. Update the route reader, claim/donor readers and receipt readers to project the same protected classification and action reasons. Readers do not finalize anything. Continue filtering out released stops in next-stop/remaining feasibility checks. Retain existing guard/ACL/search_path protections and lock ordering throughout.

**Remaining-route feasibility.** A started-but-uncollected stop is not an unvisited stop. The current check_remaining chooses its travel origin from the last collected stop or depot. After this new release, do not automatically authorize the next pickup using an assumed depot origin or a current listing that may have changed. The simplest conservative FYP option is an explicit NGO vehicle-at-depot checkpoint before resuming remaining work after a dispatched no-handover release: persist its assertion/time in the existing audit, retain the booking, and validate remaining travel/windows from that depot and time. Without an authoritative origin/checkpoint, keep continuation blocked with a clear reason. This checkpoint is neither goods return nor route closure. This narrow feasibility adjustment needs review and tests alongside the new release path.

## 4. Disagreement correction without an administrator

Recommend **joint review with append-only evidence rounds**, not editable statements or one-sided retries. This is the small schema extension justified by the correction requirement: the existing evidence table has UNIQUE(case_id,actor_user_id), so it cannot safely hold a replacement history today.

1. Either participant requests a review while the case is unresolved. The other participant must accept; until then existing disagreement and custody holds remain. Show both existing statements and the review request to both participants.
2. On acceptance, a protected, version-checked operation starts a new numbered evidence round on the same case. Add round/version and review-request/acceptance metadata to the existing case, and an evidence_round column to the existing evidence table. Replace uniqueness with (case_id,actor_user_id,evidence_round); keep globally unique request IDs and original rows/receipts. Record requests, acceptance and supersession in the existing audit trail. No new table or administrator role is required.
3. Both parties submit fresh statements bound to the same expected round/version and source/custody context. Old clients must fail closed on later rounds; use an explicit versioned submission endpoint for round-aware clients if necessary to avoid ambiguous RPC overloads. Existing initial-round requests keep their original receipt behavior. No actor can silently change another actor's evidence or combine a new statement with an old-round response.
4. Agreement in the new round uses the same decision table. Prior disagreement is considered superseded only through this jointly accepted review and two fresh statements; it stays visible in history. All helpers that currently reject “any true statement ever” must distinguish consensually superseded testimony from unresolved testimony. Actual collection, immutable custody events and unresolved incidents can never be superseded by this mechanism.
5. Continued disagreement, a missing counterpart or an integrity incident remains unresolved. Participants can discuss outside the app and request another joint review when they can state the facts consistently. Without a trusted adjudicator, there is no safe guaranteed unilateral release or forced completion. Display “Disagreement unresolved — contact your counterpart,” not “Awaiting administrator.” Escalation is participant-to-participant review; genuine physical/security incidents require real-world resolution and a separately approved evidence-backed contract, not an automatic timer or hidden operator.

## 5. Food Can under this proposal

Reuse the verified snapshot: donation `53448e5f-85bd-482f-8904-e1237a70769e`, claim `36ba7908-a7ab-42fc-839b-9e6fed5971a9`, case `3708432b-88a1-4b16-ae13-2b89da1d3cdd`, route `5dff9b93-1ca2-476e-a6fb-a2f790a81d92`. Both actual participants already reported false; the existing MANUAL_REVIEW reason is the old started-task restriction, not a disagreement.

After separately approved implementation/deployment, a normal participant would select the protected “Resolve matching statements” action. Revalidate the then-current records; the earlier snapshot is not permission to force today's state. If checks still pass, the new permit authorizes PICKUP_IN_PROGRESS → AVAILABLE, the claim/lease become RELEASED, the task becomes STALE and the item becomes resolved uncollected. Its genuine start timestamps remain. The case becomes RESOLVED_RELEASED without collecting new duplicate statements. Donation discovery is restored only when eligible. Its route stays IN_PROGRESS until all other stops are final and the NGO truthfully confirms vehicle accountability; then mixed or NO_COLLECTION ABANDONED closure applies as appropriate. No direct Food Can UPDATE or automatic data migration is proposed.

## 6. Canonical cancellation migration review

Local inspection found **only** `supabase/migrations/20261104130000_unstarted_released_route_cancellation.sql`; the earlier similarly named `20261104_unstarted_released_route_cancellation.sql` does not exist. Test files are not additional migrations. There is one current deployment candidate, and nothing is deployed by this proposal.

Revise this still-undeployed candidate once, after approval, into the coherent reconciliation/lifecycle package rather than stacking competing replacements of the same functions. Keep a single canonical version/file in the deployment set. Recheck actual deployment history first; if that version has been applied anywhere, preserve it and use a reviewed forward migration instead of rewriting published history.

The prior cancellation implementation is safe for its tested subset, preserves terminal task/history and protects starts, but **cannot yet promise no avoidable dead ends**. It requires today's listing AVAILABLE and goods AVAILABLE/BATCHED, and checks pending cases at listing scope. A later legitimate re-claim can therefore block cancellation of an old safely released route. Revise it to classify the original claim's immutable release/effective no-handover evidence and original source membership; a newer claim's activity alone must not invalidate that historical release. Missing or contradictory evidence about the original claim still blocks. Update round-aware checks without weakening recorded-start/collection rejection.

For an owner-requested cancellation of an entirely unstarted route with a mixture of safely released members and unchanged valid planned members, permit cancellation only if **each** member belongs to one safe class. Preserve released STALE tasks; return only still-valid unchanged planned tasks to CONFIRMED. Preserve the original manifest in the existing cancellation history when removing active planning associations, using the established ordinary cancellation behavior where required. Do not automatically cancel while active work remains. This avoids making a partial release itself a cancellation dead end.

Started-no-handover outcomes remain ineligible for CANCELLED because consumed_at/started_at are preserved. They use ABANDONED closure. A private shared classifier must distinguish historical evidence and current actionable work, and return explicit blockers. This removes the identified avoidable stuck states; genuinely unresolved custody, incomplete evidence or a nonresponding counterpart must still remain protected.

## 7. Flutter changes and minimum acceptance tests

Show Awaiting Counterpart, Disagreement — joint review needed, or the exact integrity blocker from protected readers. Keep donation badges based on persisted donation state, with reconciliation context alongside. Expose backend-authorized resolve-existing-evidence and joint-review actions; preserve request IDs, receipt recovery, owner/session checks and expected evidence versions. Refresh donation detail/Home/list, claim cards and route detail after confirmed transitions; recovery reads alone must not send writes.

Keep the unstarted cancellation wording already implemented. For a started zero-collection route, show “No goods collected — confirm vehicle return and close route”; after closure show “Route closed — no goods collected.” Mixed and collected routes retain accurate vehicle/depot wording. Route cards must use explicit outcome/count fields. The repository must route NO_COLLECTION to the resolved-route RPC, never to close_my_collected_route merely because a new outcome string differs from ABANDONED. Validate stored receipt/outcome compatibility and preserve in-flight old requests.

Minimum regression matrix, in disposable PostgreSQL plus mocked Flutter (not DEV mutations):

| Area | Required cases |
|---|---|
| Custody decisions | Started false/false direct and complete hub batch; true/true collection; opposing statements; one response; missing/foreign participant; missing member; recorded collection/incident blocks false/false |
| Existing evidence | Food Can-shaped MANUAL_REVIEW resolves explicitly without replacement statements; old request replays original receipt; new resolve retries once; unrelated hold still blocks |
| Correction | Joint acceptance, declined/missing acceptance, two fresh same-round statements, immutable old evidence, superseded testimony versus actual collection, stale/foreign/duplicate requests and old clients |
| Route/vehicle | Unstarted CANCELLED versus started ABANDONED/NO_COLLECTION; all-collected COMPLETED; mixed closure; active work/pending case blocks closure; truthful vehicle confirmation; one binding release; no goods-return assertion |
| Cancellation completeness | Original ordinary cancellation; all safely released; mixed valid-planned/released; later legitimate re-claim; expired listing; source membership drift; preserve manifest/start/terminal history |
| Concurrency/security | Second statement versus start/expiry/resolve/cancel/close; correction versus finalization; shared READ COMMITTED locks; atomic rollback; receipt payload conflict; foreign access and private-permit denial; remaining-route origin/checkpoint revalidation after a dispatched release |
| UI/read contracts | Matching projections across donor/NGO screens, precise labels/counts, refresh/stale-data revalidation, durable requests, NO_COLLECTION RPC routing, no writes from readers |

Do not implement, deploy or resolve records until this proposal is approved. Safety still prevents automatic resolution for real custody contradictions, partial batch handovers, unknown/missing authoritative associations, unresolved incidents, participant drift, or lack of two-party agreement. Removing the administrator requirement for ordinary agreement does not make those facts safe to ignore.
