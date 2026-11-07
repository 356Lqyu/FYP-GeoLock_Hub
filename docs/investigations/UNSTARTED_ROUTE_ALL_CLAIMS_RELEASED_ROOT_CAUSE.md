# Unstarted route after all claims are released — investigation

Date: 2026-11-04 (Asia/Kuala_Lumpur).

**Status: investigation complete, including read-only DEV verification on 2026-11-04. The correlated route snapshot was recorded at 12:34:55 UTC (20:34:55 MYT). One matching route was identified. No implementation or DEV changes were made.**

## Findings and confidence

The deployed SQL and persisted records confirm a lifecycle gap: route `24c9a21a-a5fd-4ff4-8fb4-e04779b292e9` never recorded pickup start or collection, and both claims were released through protected two-party no-handover reconciliation. It remains AUTHORISED with an open vehicle binding. Its all-uncollected outcomes satisfy mixed-outcome closure, which still demands depot-return confirmation. Unstarted cancellation rejects the same route because its tasks are STALE and it has deferred-stop history. Flutter follows these backend flags and presents a fixed depot-return action. The route card also incorrectly equates close eligibility with collection. This is a backend lifecycle/eligibility issue plus a Flutter presentation issue.

No collection is supported by the combined persisted evidence: null route/item start and collection timestamps, STALE tasks, both donations AVAILABLE, four no-handover participant statements, two RESOLVED_RELEASED cases with BOTH_PARTIES_CONFIRMED_NO_HANDOVER, and corroborating audit transitions. RELEASED or null timestamps alone were not used as proof. No current custody dispute, pending case, route incident or closure receipt was found. This is authoritative application evidence, not independent observation of the vehicle's physical location.

## Access boundary and live verification

Before SQL, Supabase `get_project_url` returned `https://rcgyuwiidqvrgbxswhqj.supabase.co`, matching `frontend/geolock_hub_app/lib/supabase_config.dart:12` and the intended DEV reference in the prior audit. Queries used the supported project-scoped Supabase integration, not extracted credentials. Database/current SQL role were postgres/postgres.

Every SQL inspection explicitly began READ ONLY, selected `current_setting('transaction_read_only')`, returned `on`, and ended with ROLLBACK. Correlated record/audit reads used REPEATABLE READ READ ONLY. The preliminary transaction verified read-only mode before substantive inspection. Only SELECTs and transaction controls ran: no application RPC invocation, auth impersonation, mutation, DDL, scheduler activation or SQL deployment. Route flags below were evaluated from their deployed predicates against selected records rather than by invoking route RPCs. Names, addresses, credentials and participant IDs are omitted; ownership is verified by equality and an NGO UUID fingerprint.

The previous source-only version of this report recorded an integration startup failure. That limitation is resolved in this investigation; its unverified conclusions have been replaced with live evidence.

### Affected-route verification ledger

| Requested evidence | Result in this investigation |
|---|---|
| Route ID / candidate routes | Exactly one managed route with nonempty membership and every claim/lease RELEASED: `24c9a21a-a5fd-4ff4-8fb4-e04779b292e9` |
| NGO ownership | Route, binding and both claim owners agree; NGO UUID MD5 fingerprint `9548ea4cfdc7965e908fd60c7f494619` |
| Current route status and creation time | AUTHORISED; binding created 2026-11-02 16:46:21.298011 UTC, or 2026-11-03 00:46:21.298011 MYT |
| Binding started_at / actual pickup start | NULL; both item consumed_at NULL; no contrary start audit found |
| Item collected_at / completion | Both NULL; neither task COLLECTED; both donation states AVAILABLE |
| Claims and leases | Both RELEASED with RECONCILED_NO_HANDOVER, not merely expired ACTIVE leases |
| Reconciliation | Two RESOLVED_RELEASED cases; four false handover statements; no pending claim/whole-route cases |
| Membership and tasks | Two retained private items/public stops; both tasks STALE; both items released; zero active assignments |
| Collection/custody | No collection according to consistent persisted no-handover evidence; no unresolved custody evidence found |
| Vehicle/depot | Binding closed_at NULL still reserves the vehicle. No recorded pickup/departure or goods to return. Existing mixed closure nevertheless requires depot confirmation by policy |

The route-specific evidence and deployed/local comparison are detailed below. Null timestamps were cross-checked against task, donation, handover, reconciliation and audit evidence.

## Source evidence index

Paths below refer to the current working tree, including pre-existing untracked/modified work. No application source was edited.

| Ref | Source and relevant lines |
|---|---|
| F1 | [ngo_routes_page.dart](C:/Users/User/Downloads/FYP-GeoLock_Hub/frontend/geolock_hub_app/lib/routing/ngo_routes_page.dart:562): detail loading 562–640; authorization 694; Start Route 797–819; closure/cancellation 1002–1033 |
| F2 | [ngo_routing_repository.dart](C:/Users/User/Downloads/FYP-GeoLock_Hub/frontend/geolock_hub_app/lib/routing/ngo_routing_repository.dart:828): detail 828; pickup mutation around 1040–1073; close 1116–1198; cancel 1200–1205 |
| F3 | [route_card_view.dart](C:/Users/User/Downloads/FYP-GeoLock_Hub/frontend/geolock_hub_app/lib/routing/route_card_view.dart:50): readiness and misleading collection label |
| F4 | [routing_page_support.dart](C:/Users/User/Downloads/FYP-GeoLock_Hub/frontend/geolock_hub_app/lib/routing/routing_page_support.dart:7): session freshness, reload, lifecycle invalidation |
| F5 | [route_resolution_repository.dart](C:/Users/User/Downloads/FYP-GeoLock_Hub/frontend/geolock_hub_app/lib/routing/route_resolution_repository.dart:158): DEV/build flag gate, reads, participant evidence and durable requests |
| F6 | [route_execution_controller.dart](C:/Users/User/Downloads/FYP-GeoLock_Hub/frontend/geolock_hub_app/lib/routing/route_execution_controller.dart:8): held-operation guard and current-stop selection |
| S1 | [routing authority](C:/Users/User/Downloads/FYP-GeoLock_Hub/docs/stage8/stage-a/forward-migrations/20261101_routing_authority.sql:93): bindings, items, unique outstanding bookings, history |
| S2 | [routing publication](C:/Users/User/Downloads/FYP-GeoLock_Hub/docs/stage8/stage-a/forward-migrations/20261102_routing_publication.sql:6): actor/ownership lock and source locks |
| S3 | [pickup/reconciliation](C:/Users/User/Downloads/FYP-GeoLock_Hub/docs/stage8/stage-a/forward-migrations/20261103_routing_pickup_and_reconciliation.sql:43): lock_route; close_collected 57; close RPC 72; cancel RPC 83; task guard 113; start/complete 179/193; overview 215 |
| S4 | [automatic departure](C:/Users/User/Downloads/FYP-GeoLock_Hub/docs/stage8/stage-a/forward-migrations/20261104_routing_automatic_departure.sql:124): base authorized route read and flags |
| S5 | [legacy route resolution](C:/Users/User/Downloads/FYP-GeoLock_Hub/docs/stage8/stage-a/forward-migrations/20261106_route_interruption_resolution.sql:282): protected finalization, binding/custody checks; vehicle/route guard 423 |
| S6 | [per-stop reconciliation](C:/Users/User/Downloads/FYP-GeoLock_Hub/docs/stage8/stage-a/forward-migrations/20261108_per_stop_reconciliation.sql:138): task/reconciliation permits; wrapper reader 242; mixed closure 293; route guard patch 461 |
| S7 | [claim-scoped recovery](C:/Users/User/Downloads/FYP-GeoLock_Hub/docs/stage8/stage-a/forward-migrations/20261109_claim_scoped_reconciliation.sql:37): route recovery lock; safe detachment 62; recovery patches 140–265; retiring new whole-route reports 288 |
| S8 | [released history readers](C:/Users/User/Downloads/FYP-GeoLock_Hub/supabase/migrations/20261104_released_claim_history_readers.sql:202): latest local pre-deferral reader, privacy filters, unchanged close/cancel predicates 238–253 |

The Stage A files describe themselves as local/review artifacts; dates alone were not treated as deployment evidence. Actual deployed bodies were retrieved through pg_get_functiondef. The comparison below confirms the relevant cancellation/closure/start contracts and identifies reader drift. The prior audit is background only.

## Flutter eligibility and refresh behavior

Cancel button: F1 uses `authorized && _route?['can_cancel'] == true`. Closure uses `authorized && _route?['can_close'] == true`. `authorized` requires fresh usable session state, backend `authorization_confirmed`, and no held execution request. These buttons are not derived solely from route status, claim status, lease expiry, or local timestamps.

The close label is always `Confirm depot return and close route`. Its ABANDONED confirmation explains that at least one stop was independently resolved uncollected, but still requires vehicle return. F2 rereads detail before ordinary cancellation/closure. When `closure_outcome == 'ABANDONED'`, it calls `close_my_resolved_route`, **not** `close_my_collected_route`, with `p_depot_return_confirmed=true` and a durable request UUID. Other closures call `close_my_collected_route` with true. Saved mixed-closure requests are recovered through the protected receipt and same request ID; they are not silently replaced.

The production pickup entry is route-authorized Start Route/Continue route, gated by the selected stop's `can_start`; repository pickup methods reread protected eligibility before calling `start_pickup` or `complete_pickup`. The separate `Start Pickup` claim-card button in donation_pages.dart around 1667 exists only with an injected action runner; ordinary live claim cards direct users to Pickup routes and do not grant dispatch permission from a claim alone.

The Routes page loads overview, fleet and owned claim cards, then loads each route's protected detail (F1 151–210; F3 bounds concurrency at three). The overview includes historical route bindings, up to 30, rather than filtering to active claims. Retaining a route after claims release is therefore not itself a stale-cache defect.

Detail fetch reads pending closure, protected route detail, claim cards and execution receipt state. Claim-card failures do not grant permission. Direct donation locations and stop start/complete actions are redacted when claims are not valid active; a server-derived lease timer redacts locations and reloads around expiry. This does not recompute route-level cancellation/closure flags.

F4 invalidates freshness after 30 seconds; it does not periodically reload at that timer. Resume/auth changes reload; manual refresh reloads; detail actions reload afterward. No realtime route-change subscription is present in this page flow. Stale detail can remain visible while actions are disabled. Rereads protect mutations, but cannot correct a semantically wrong authoritative flag. Refresh alone will not fix the local all-uncollected predicate.

F3 maps terminal route statuses first, then authority, executable stops, then any `can_close=true` to `Pickups collected. Confirm return to depot.` This statement is false for an all-uncollected resolved route and misleading even for mixed routes. F6 correctly skips resolved-uncollected stops when selecting work, so no current executable stop is required for the closure button to remain enabled.

## Verified SQL lifecycle

### Authorization and unstarted cancellation

S4/S8 authorization checks an open binding, owned route/vehicle, candidate validation/digest and matrix association, and route state AUTHORISED or IN_PROGRESS. Authorization can remain confirmed after claim memberships are released: it is not synonymous with executable work.

The base `can_cancel` requires authorization, `bindings.started_at IS NULL`, and no item whose consumed_at is set, whose task is not PLANNED, or whose current observation digest differs from its authorization digest. S6 additionally requires **no deferred-stop row at all**, including resolved history.

The cancellation RPC locks ownership/route/source state, is repeatable when already CANCELLED, rejects any route/item start, and requires every task PLANNED with matching observations. It archives public stops, removes public stops/active assignments, releases item reservations, sets tasks CONFIRMED, marks route CANCELLED, closes binding, and audits. It does not explicitly require ACTIVE claims, but digest/task requirements effectively preserve the original plannable claim snapshot. Relaxing only the UI would fail this RPC. Relaxing only the task predicate would incorrectly resurrect safely released STALE tasks as CONFIRMED.

### Start and collection

S3 `start_pickup` needs an unreleased route item, actor/route locks and `check_remaining`: current bindings/vehicle/depot/policy, next-stop order, source observations, assignments, time windows, active valid leases and feasible completion/depot return. It consumes a one-transaction dispatch permit, writes item consumed_at and binding started_at, marks route IN_PROGRESS and invokes the guarded legacy pickup transition. S6 excludes deferred/released stops from remaining work; S7 permits independent treatment of another unstarted stop while one is dispatched.

Completion requires a consumed, not-yet-collected item (or explicitly grandfathered legacy inflight task), a protected completion permit and successful guarded legacy handover checks; it records item collected_at. Collection does not release the vehicle booking or prove depot return.

### Collected closure versus mixed closure

`close_my_collected_route` requires true depot confirmation, the ownership lock, and every member task/claim/lease COLLECTED/COMPLETED/COMPLETED. Empty routes are rejected by its helper. Repeated completed closure returns safely; a different closed terminal outcome is rejected. The base reader additionally requires item collected_at. An all-STALE/RELEASED route fails this collected closure; do not attribute mixed-path behavior to this RPC without checking deployed drift.

S6 mixed readiness is:

1. At least one deferred stop is RESOLVED_UNCOLLECTED.
2. No joined member fails both valid outcomes: collected item + COLLECTED task + COMPLETED claim/lease, **or** resolved-uncollected deferred row + released item + STALE task + RELEASED claim/lease.
3. No unresolved active assignment remains.
4. No whole-route case awaits evidence/manual review.

`can_close = authorization_confirmed AND (base_can_close OR mixed_ready)` and mixed readiness selects `closure_outcome='ABANDONED'`.

There is **no requirement for a collected member or started binding**. With all members valid resolved-uncollected, all four tests can pass. No base collected closure is needed. The no-deferral and PLANNED-only cancellation tests simultaneously fail. This is the verified deployed predicate path producing the reported action eligibility.

`close_my_resolved_route` repeats those outcome/assignment checks under locks, accepts AUTHORISED as well as IN_PROGRESS, requires true depot return, persists an immutable mixed closure receipt/accountability marker, closes the binding, and marks route ABANDONED. It audits `depot_return_confirmed=true` and `vehicle_accountability_confirmed=true`, even for this zero-collection case. Hiding the label would leave this semantic problem and the open vehicle booking unresolved.

### Recovery, reconciliation and historical membership

S7 safe expiry recovery coordinates locks with route execution. It only detaches an unconsumed/uncollected member when its guards allow. It creates a deferred stop/transaction permit, marks the task STALE, releases claim/lease, deletes its active assignment and marks its item released and deferred stop RESOLVED_UNCOLLECTED. It preserves historical route items/public stop associations rather than erasing the plan. It does not set binding closed_at or transition route status when the last stop is released.

Unsafe/dispatched/conflicting custody remains reconciliation-required. Participant no-handover reconciliation in S6 extends the protected release branch for an unconsumed deferred stop; its release effects likewise preserve history and do not close the route. RELEASED must be tied to the actual release branch, reasons, statements and audit.

S5 whole-route finalization preserves legacy case evidence, requires a started IN_PROGRESS binding, matching participant no-handover statements for uncollected work, vehicle accountability, consistent observations and restricted operator authority. S7 retires creation of new whole-route interruption reports. This is not a general existing cancellation mechanism for a never-started route. F5 is gated by the DEV environment and build flag; it cannot be assumed active merely because source exists.

S1's unique open vehicle booking persists until binding closed_at is set. Released per-task reservations do not necessarily release the vehicle. S3 task guards, S6 single-transaction release permits/immutable deferred history and S5/S6 vehicle route guards prevent casual status edits. A proposed change must cooperate with these guards and preserve the old manifest and claims.

## Expected behavior and smallest safe recommendation

Extend the existing protected unstarted cancellation lifecycle to handle the additional all-safely-released outcome, retaining route state CANCELLED. The affected route satisfies the intended no-collection policy, but the existing cancellation RPC does not support this terminal released-task branch. Prefer an explicit owner action first. Do not introduce a new EXPIRED or NO_COLLECTION route status merely to handle this case.

The new branch must lock and recheck complete membership, ownership, no binding/item start or collection, no contradictory handover/donation/audit evidence, no uncertain custody, no open/manual claim or route cases, no active work, and valid terminal safe-release evidence for every historical member. Missing joined evidence must reject rather than disappear through INNER JOINs. Preserve STALE tasks and terminal claim/lease states; do not use the old requeue-to-CONFIRMED loop for this branch. Preserve resolved reconciliation/deferred history and archival evidence; close the booking atomically and audit the no-collection reason. Repeated same cancellation must remain safe.

Use a shared private eligibility calculation for reader flags and mutation revalidation. Narrow mixed closure eligibility for a verified never-started/all-uncollected route, rather than leaving both contradictory actions available. Preserve depot/accountability obligations for started routes, including started routes with zero completed pickups. Never infer physical vehicle departure from a route click timestamp alone; any independent vehicle obligation must be considered.

After the backend supports that authoritative transition, Flutter should show `No active pickups remain` plus an authorized cancellation action for an open eligible route; after cancellation, `Route cancelled — no pickups completed` only when an authoritative no-collection outcome/reason supports it. Otherwise retain the generic terminal label. Historical stop counts must not be described as completed pickup counts. Resolve route-card wording using explicit backend closure semantics, including mixed outcomes, rather than can_close alone. Preserve pending-operation recovery/freshness handling.

Required implementation would therefore be a reviewed forward SQL migration (helper/reader, cancellation branch and closure guards/audit as required by actual deployed bodies), matching Flutter action/presentation changes and regression tests. No implementation is included here. Existing legacy resolution should continue handling its own existing cases; do not force this unstarted case into a retired workflow.

### Automatic recovery options

Automatic cancellation is reasonable only for the fully verified safe subset, not every route without ACTIVE claims. A collected or disputed route can also have no active claims. Explicit protected cancellation is the smallest first fix and makes the lifecycle result reviewable.

| Option | Evaluation |
|---|---|
| Protected idempotent RPC | Preferred initial approach; shares locks/eligibility with authoritative reader; preserves explicit audit and repeat safety |
| Scheduled trusted worker | Possible later; calls the same guarded transition, bounded candidates, lock/recheck and audited reason; coordinate with final claim release; do not activate now |
| Trigger on claim/lease/task release | More difficult: release is a multi-table process, so a row trigger may see intermediate state or invert lock order; a deferred/transaction-safe design needs separate review |
| Lazy cleanup in route reads | Reject hidden writes. Keep reads observational; a separate explicit mutation can reconcile safely |

Deployed recovery detaches claims but does not contain this final route cleanup. Live cron.job contains active `geolock-expired-claim-recovery`, job 3, every minute (`* * * * *`), calling recover_expired_claims. The other two jobs refresh NGO/listing eligibility. No scheduled route cleanup was found. Recovery was not invoked and no worker, trigger or cleanup was activated.

## Regression plan

Use disposable PostgreSQL fixtures with deployed-equivalent functions/guards and mocked Flutter RPCs. Live DEV remains read-only.

| Case | Required assertion |
|---|---|
| 1. Never started, all safely released | Protected cancellation eligible; terminal CANCELLED; binding closed; no task resurrection; no depot-return assertion |
| 2. One valid active claim remains | No automatic all-released cancellation; active work preserved; ordinary original cancel/replan semantics tested separately |
| 3. Started, no pickups completed | New branch rejects; existing custody/accountability/resolution rules preserved |
| 4. At least one completed pickup | New branch rejects; true collected or mixed closure preserves depot confirmation |
| 5. Uncertain custody | Conflicting/unknown evidence blocks cleanup even if a claim is terminal or timestamps are null |
| 6. Pending reconciliation | OPEN/MANUAL_REVIEW or route AWAITING_EVIDENCE blocks cleanup; resolved no-handover is evaluated independently |
| 7. Concurrent expiry/cancel/start | Common lock ordering; one serialized winner; no deadlocks/partial releases/requeued released claims; start cannot consume a released item |
| 8. Repeated requests | Same cancellation/receipt has stable result; different terminal transition rejected; lost response never produces fabricated depot evidence |
| 9. Stale Flutter data | Invalidate after 30 seconds, resume/auth changes, expiry redaction; mutate only after fresh protected reread; late owner response discarded |
| 10. Unauthorized NGO | Foreign/anonymous caller denied; no details, history or existence leaked |
| 11. No false depot confirmation | Zero-collection route offers cancellation and never sends true depot confirmation; mixed card does not say all pickups collected |
| 12. Audit/history | Preserve manifest, source claims/leases, deferred events, evidence and timestamps; exactly justified transition event; release only applicable reservations |
| Missing or duplicate associations | Fail closed on missing claims/leases/tasks or conflicting historical associations; no vacuous truth through joins |

Executed locally: `python supabase/tests/claim_scoped_reconciliation_static_test.py` — **5 tests passed**. These check existing source contracts and do not execute SQL or prove the affected route. No route-card/detail/execution or isolated route-resolution suite was run against DEV. No E2/E4 experiments or feature tests were added.

## Verified route records and chronology

Candidate discovery joined all managed route bindings/items to tasks, claims and leases, requiring nonzero membership and every member claim/lease RELEASED. Starts and collection were counted, not excluded to manufacture a match. The query returned exactly one candidate; the LIMIT 30 was not reached. This identifies the persisted route matching the report, without claiming to have observed the user's screen.

The route was authorised at `2026-11-02T16:46:21.289539Z`; its binding was created nine milliseconds later. Its binding has never recorded started_at or closed_at. Both task and claim owners match the route owner. The public manifest and private membership each retain two stops, but no active assignment remains. Retained manifest rows are historical evidence, not valid active claims.

| Evidence | Stop 1 | Stop 2 |
|---|---|---|
| Task ID | `00ff005e-b8a9-43e7-9084-de46bfcdd390` | `e9f56fae-6c52-4764-8bf7-41fd87bd8144` |
| Claim ID | `1adfccce-a8f2-484b-a0a1-168018188b4a` | `633feb8e-4b8d-43b0-bba4-83d81a5a62f3` |
| Lease ID | `5520684d-ccc5-4b42-ae69-908a98b3ac04` | `0cbc59bc-1fb5-4d7c-ad6c-5eb6d2a72296` |
| Lease expiry (UTC) | Nov 2, 22:44:41.507847 | Nov 2, 22:20:37.348178 |
| Claim case opened (UTC) | Nov 2, 22:45:00.306977 | Nov 2, 22:25:00.466048 |
| Protected deferral (UTC) | Nov 3, 06:01:08.275304 | Nov 3, 06:01:13.202645 |
| Item released (UTC) | Nov 3, 06:03:13.477324 | Nov 3, 06:03:56.495966 |
| Deferred outcome resolved (UTC) | Nov 3, 06:03:13.478247 | Nov 3, 06:03:56.496733 |
| Claim case ID | `52757a35-d809-4ee3-8bdf-89a098d9598e` | `a37a5ead-ec32-4cbd-a3c1-d727069c4b31` |
| Claim case resolved (UTC) | Nov 3, 06:03:14.016845 | Nov 3, 06:03:56.666769 |
| Current state | Task STALE; claim/lease RELEASED; deferred RESOLVED_UNCOLLECTED; donation AVAILABLE | Same |
| Claim/lease release reason | RECONCILED_NO_HANDOVER | RECONCILED_NO_HANDOVER |
| Start/collection timestamps | consumed_at NULL; collected_at NULL | Same |
| Participant evidence | Two distinct actors: owning NGO and actual donor; both handover_confirmed=false | Same |

All table times above are UTC; add eight hours for MYT. Both case resolution reasons are BOTH_PARTIES_CONFIRMED_NO_HANDOVER. No conflicting positive handover statement, pending case, whole-route case/incident or mixed-closure receipt exists for this route.

The audit timeline corroborates the records: LEASE_RECOVERY initially moved both claims from ACTIVE to RECONCILIATION_REQUIRED with HANDOVER_OR_AUTHORITATIVE_STATE_UNCERTAIN; NGO protected deferrals followed; each case received a first no-handover statement and awaited the counterpart; the second statement released the claim and returned its donation from CLAIMED to AVAILABLE with RECONCILED_NO_HANDOVER. No START_PICKUP, completion, collection-state donation transition, cancellation or closure event contradicts this evidence in the inspected route/claim/donation history. Earlier unrelated claims on those donations were not treated as this route's custody evidence.

The historical generic recovery reason does not disclose which subcondition originally raised uncertainty, nor establish what exact function version ran at that earlier time. Current deployed recovery already supports guarded unstarted detachment. The important route-specific fact is that the uncertainty was subsequently resolved by both participants, not ignored.

## Live predicate evaluation

Read-only SELECTs evaluated the reader's persisted clauses without auth impersonation or application RPC calls:

| Clause | Verified result |
|---|---|
| Open binding, owner/vehicle match, candidate validation/digest and matrix association, AUTHORISED/IN_PROGRESS status | authorization_confirmed=true |
| Started or collected members | 0 / 0 |
| Non-PLANNED tasks | 2, both STALE |
| Deferred history | 2, both RESOLVED_UNCOLLECTED |
| Valid released-uncollected final outcomes | 2 of 2 |
| Active task assignments | 0 |
| Unreleased/uncollected executable members | 0 |
| Pending route resolution / incidents | 0 / 0 |

Consequently base_can_cancel=false, wrapper_can_cancel=false, base_can_close=false, mixed_ready=true, wrapper_can_close=true and closure_outcome=ABANDONED. All stop can_start/can_complete flags are false. The user-visible buttons are therefore reproducible from current backend state; a stale cache is not required to explain them. Session freshness and held-operation guards can additionally disable Flutter actions.

The decisive deployed wrapper clauses are:

```sql
-- mixed_ready permits each member to have EITHER outcome:
(i.collected_at IS NOT NULL AND t.task_status='COLLECTED'
 AND c.claim_status='COMPLETED' AND le.lease_status='COMPLETED')
OR
(d.status='RESOLVED_UNCOLLECTED' AND i.released_at IS NOT NULL
 AND t.task_status='STALE'
 AND c.claim_status='RELEASED' AND le.lease_status='RELEASED')

-- It requires some resolved-uncollected history, no unresolved assignment,
-- and no pending whole-route case, but NO collected member or route start.
'can_close', authorization_confirmed AND (base_can_close OR mixed_ready)
'can_cancel', base_can_cancel AND NOT EXISTS (
 SELECT 1 FROM routing_private.deferred_stops WHERE route_id=p_route)
```

These excerpts use descriptive aliases for the JSON expressions; they are explanatory, not executable deployment SQL. The close mutation repeats the outcome predicates, permits AUTHORISED, and explicitly rejects `p_depot_return_confirmed IS DISTINCT FROM true`. `close_my_collected_route` would reject this actual route as unresolved; Flutter routes this case to `close_my_resolved_route` instead. No closure was attempted to demonstrate it.

## Deployed/local comparison and guards

Retrieved definitions included all seven requested public functions, mixed closure, pre-deferral reader, recover_expired_claims, submit_claim_reconciliation, finalize_route_resolution, all routing_private helpers, resolution_private helpers, and route/task/history trigger functions. The public entry functions are SECURITY DEFINER, marked VOLATILE, with search_path pg_catalog/pg_temp, UTC and extra_float_digits=0; EXECUTE ACLs list postgres and authenticated, without PUBLIC/anon/service_role. Volatility is not proof of writes: inspected route readers/check_remaining only observe and calculate, and were not invoked here.

The following fingerprints are MD5 of prosrc after removing carriage returns, compared to extracted local dollar-quoted bodies. This avoids mistaking CRLF differences for semantic drift.

| Deployed function | Normalized source MD5 | Local comparison |
|---|---|---|
| cancel_my_unstarted_route | `25d5d50b727abd9cf94fd0b9c479e612` | Exact S3 match |
| close_my_collected_route | `5f83aea95b8c8971ea3bfcbcb8b3c18a` | Exact S3 match |
| start_pickup | `cb306433867538804b67aa1a242867b4` | Exact S3 match |
| complete_pickup | `26f0cd8cebe783c65b45e05649693860` | Exact S3 match |
| get_my_routing_overview | `aae6de57397515712518dcdc6c72b762` | Exact S3 match |
| close_my_resolved_route | `1de1767851ac4a68e68e3c17f8e5d421` | Exact S6 match |
| get_my_authorized_route | `167e9843e6e026df8844f441af77fded` | Exact S6 body after S7 removes the other-stop DISPATCHED deferral guard |
| release_expired_unstarted_stop | `a6abd6f8d3c96020a7e93df39483458a` | Exact S7 match |
| get_my_authorized_route_pre_deferral | `df7eb088b25c083673b223f164b7dcfd` | Exact older S4 reader body; NOT latest S8 local reader (`fe29904d170cf1bfa16f628220968bb2`) |
| recover_expired_claims | `05fe46d8b76085f71c87fcc5f6520775` | Current expanded body inspected; contains guarded detach/safe-release and uncertainty branches. Not identical to earlier standalone base migrations; do not infer full migration lineage from this comparison |

The S8 drift matters separately: its local pre-deferral reader adds released-history privacy filtering and explicit lease checks on start presentation; deployed base still emits older location fields. No addresses were requested from application RPCs or included in this report. Flutter currently redacts invalid direct-claim locations, but backend filtering should be reviewed separately. This drift does not change the cancellation/mixed-close predicates causing this incident.

Live enabled triggers include pickup_tasks.routing_task_authority, pickup_routes.c1_route_vehicle_guard, deferred_stop_transition/deferred_stop_event, routing_mark_deferred_collection and immutable history/receipt guards. The route vehicle guard rejects unresolved terminal activity, terminal state reversal, vehicle/owner reassignment, and ABANDONED without a same-transaction protected finalization or accountable mixed-closure receipt. It does not add a route-start or collected-member condition to mixed closure. The task guard requires transaction-scoped dispatch/completion/release authority. Merely changing a task status or hiding a button bypasses the intended lifecycle contract.

Constraints preserve one lease/task per claim, private item/ordinal uniqueness, manifest-to-route ownership, and foreign keys to existing claims/tasks/routes. Partial unique indexes enforce one unreleased booking per task and one unclosed binding per vehicle. Thus this route's zero active assignments do not release its still-open vehicle booking. Missing-join evidence should still fail closed in any new helper; foreign keys do not themselves guarantee every claim has a lease.

Ownership is rechecked by actor_lock (`auth.uid()` must equal route NGO), READ COMMITTED execution, NGO advisory lock and source/vehicle/route/task/binding locks. Recovery has a matching actor/source lock prefix without user impersonation. READ COMMITTED is required for future mutations; REPEATABLE READ here was used only for observational SELECT snapshots, never execution of these lock/mutation helpers.

## Remaining risks and implementation boundary

1. This report establishes application-recorded no collection; it cannot independently prove whether a vehicle physically left its depot. Future safe cancellation must consider any independently recorded vehicle obligation, not assume null timestamps alone settle custody.
2. The historical reason recovery initially required reconciliation is generic. Historical deployed function versions were not reconstructed. Current resolved evidence makes that uncertainty nonblocking for the diagnosis.
3. Deployed base-reader drift and mixed predicate inner joins/SQL NULL behavior deserve review in the forward migration. The actual route has complete, non-null associations, so neither missing joins nor NULL truth values explain this instance.
4. The proposed cancellation branch is not implemented or concurrency-tested. It must preserve READ COMMITTED lock ordering, avoid requeueing RELEASED claims, preserve receipts/audit/manifest history, and narrow mixed closure only for the verified safe never-started subset. Do not remove depot safeguards for a started route with zero completed pickups.
5. No authenticated UI session was exercised and no mutation was tested against DEV. Flags were derived from exact catalog predicates and records; Flutter source was inspected. The existing static suite passed five tests; proposed regression cases remain implementation acceptance criteria.

## Decision

The reported mismatch is confirmed in deployed DEV for the single matching route. Its safe unstarted/no-handover outcome should use a narrowly extended protected CANCELLED transition, with no fabricated depot-return assertion. Existing cancellation supports unchanged unstarted plans but not these already released members; legacy whole-route finalization requires a started IN_PROGRESS route and is not a suitable substitute. Automatic cleanup is a possible later use of the same guarded transition, not the smallest initial fix. Until approved implementation, retain the historical route and its protection rather than manually editing status or falsely confirming a return.

Stop after this report. Only this investigation document was edited. No GitHub push, SQL deployment, Flutter feature change, DEV data modification, recovery invocation, route cancellation/closure, worker activation or formal E2/E4 experiment occurred. Implementation requires the user's subsequent approval.
