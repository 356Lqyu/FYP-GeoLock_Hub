# Existing route pickup test: preparation only

29 October 2026 MYT. Route db1b455e-92d0-4d58-9fa1-5de07d7ab0f9.
No pickup, completion, closure, cancellation, recovery or other business write
was approved or executed during preparation. No app rebuild/install occurred.

## Fresh protected reads

At database server time 01:53:57 MYT the signed-in test NGO's existing phone
session returned AUTHORISED, authorization_confirmed=true, ATTESTED, V2, 77kg,
8.107km and 44.405 minutes. Actual route and stop starts are null.

| Stop | Claim | Claim/lease/task | Remaining minutes at read | can_start | can_complete |
|---|---|---|---|---|---|
| Test 10, 15kg | 73f345b8-c293-454e-8bea-16d91019fc3c | ACTIVE/ACTIVE/PLANNED | 260.23 | true | false |
| test c, 12kg | 7d5838a7-efd7-406e-9af7-5f71ea91b92c | ACTIVE/ACTIVE/PLANNED | 260.13 | false | false |
| Test 42, 50kg | 305d3708-43ca-4776-af9f-ee5afe67e9b8 | ACTIVE/ACTIVE/PLANNED | 260.31 | false | false |

can_close=false; dispatch_block_reason=null. V2 is active, available_for_planning
true but eligible_for_planning=false, consistent with its existing binding.
The successful protected remaining-route check verifies matching route/vehicle,
matrix/candidate references, stop correspondence, active task assignments,
vehicle version/depot, source observations and current remaining-route timing.
This is protected-reader evidence, not an independent private-table audit.

Overall preflight remains HOLD: get_my_reconciliation_cases() failed with
SQLSTATE 42702 (ambiguous column); absence of cases is NOT established. A combined
capture subsequently timed out; no receipt result from that capture is claimed.
Core reads were captured separately and successfully. Recovery scheduler state,
exact private binding/assignment rows and audit baseline still require the
companion read-only SQL. Supabase SQL connector is unavailable; no alternate
credentials were used. No SQL fix is proposed/applied in this preparation.

Evidence: results/pickup-lifecycle-preflight/20261028T175125Z-d2abe6/.
Original failures, diagnostic logs and core-reads.json are preserved separately.
Null receipt/reconciliation fields in core-reads.json mean NOT QUERIED in that
capture, not NOT_FOUND/no cases. JWTs remain inside the existing app clients.

## Timing and execution rules

Past planned arrivals are estimates, not permission or a reason to rewrite the
plan. Start rejects execution before departure; afterward check_remaining uses
the current server clock and re-evaluates all remaining stops, actual service,
windows, leases, return travel, the 60-minute V2 limit and original snapshot
horizon. After the first start the duration limit runs from binding.started_at.
Claim expiry must also cover the projected finish plus dispatch margin. The
255-minute admission rule for a NEW snapshot is not re-applied as a fixed minimum
to every pickup. Waiting can invalidate this route without changing its status.

Completion additionally requires ownership, ACTIVE claim and lease, an unexpired
lease, CLAIMED listing, DISPATCHED task, and explicit truthful handover=true.
An expired lease can block completion even after start. Never extend/reset it or
force release custody. Recovery may move uncertain custody/routing to
reconciliation; it is not a test-unblocking operation.

## One approval per state-changing operation

1. Approve only Test 10 Start. Immediately re-read protected detail/claims. Invoke
   the existing Flutter Start action once only if its fresh authority and flag
   permit it. No candidate regeneration or route reauthorization.
2. Read back route/task/claim/lease and audit baseline. Expect route IN_PROGRESS,
   first task DISPATCHED, donation PICKUP_IN_PROGRESS, item consumed_at and first
   route started_at set. Claim/lease stay ACTIVE, listing CLAIMED. Other stops
   stay PLANNED; vehicle and assignments remain held.
3. Request separate Test 10 Complete approval. Only confirm an actual controlled
   test handover of the approved DEV fixture; approval is not evidence of a
   physical handover. Expect task/donation COLLECTED, listing CLOSED,
   claim/lease COMPLETED, item collected_at set; route stays IN_PROGRESS.
4. Independently read and approve test c Start, then independently read and
   approve its Complete. Repeat for Test 42. Never batch or skip stops. Each
   Start must be the first uncollected stop with no unresolved DISPATCHED task.
5. After all three completions, verify can_close=true and every task/claim/lease
   resolved. Separately approve truthful depot-return confirmation. The existing
   single close_my_collected_route(route,true) RPC both confirms return and
   closes the route; there is no separate invented depot-arrival RPC. Expect
   route COMPLETED, binding closed_at, item released_at, active assignments
   cleared and vehicle no longer held by this route. Other eligibility checks
   still determine vehicle availability. Preserve all historical evidence.

Each Start records START_PICKUP SUCCESS (plus transition audit); each Complete
records COMPLETE_PICKUP SUCCESS (plus transition audit); closure records
CLOSE_COLLECTED_ROUTE SUCCESS. Verify only events added since the baseline and
correct route/claim IDs. Re-run the companion SQL after each approved operation
and use protected detail/claim reads to verify action flags.

## Uncertainty, atomicity and stop conditions

Start/completion have no caller request UUID or authorization-receipt mechanism.
They use ownership, route/source locks and single-consumption/status guards;
duplicate execution is rejected rather than promising a replayed success.
Closure supports already-completed replay, but this protocol never retries
automatically. Every RPC transaction rolls back its own partial changes on an
error; it does not roll back earlier committed pickups.

On timeout/transport loss, stop and read authoritative route/task/claim/lease,
item timestamps and audits. Do not retry until outcome and a new explicit
approval are established. Cancellation is not an undo for a started route or
completed handover. Stop on expiry, reconciliation, drift, wrong owner/order,
unexpected writes or unavailable evidence. No recovery/settings changes.

Use only approved test donations/accounts and the real verified NGO session.
Agree whether a genuine controlled physical fixture handover/depot return is
being demonstrated before approvals; never label simulated custody as physical
collection. Do not operate on unrelated records. Keep evidence private.

Next: run existing_route_pickup_preflight.readonly.sql with the already approved
owner-export profile and hidden native password prompt. Resolve the missing
read-only evidence, refresh time-sensitive flags, then request FIRST Start only.

## Subsequent operator evidence and refresh limitation

The operator reports the companion SQL completed READ ONLY / ROLLBACK at
01:58:36 MYT: route AUTHORISED, V2 active with matching version, no actual start
or closure, three PLANNED assigned tasks, ACTIVE claims/leases, zero open cases,
active recovery cron, and six baseline claim/donation audit events. Remaining
minutes: Test 10 255.57, test c 255.47, Test 42 255.65. These are operator-reported
SQL results, not a second independent catalog inspection by Codex.

Requested subsequent phone-session refresh could not compile the fixed
read-only expression: VM error 113, "_compileExpression: No compilation service
available; cannot evaluate from source." This occurs before the RPC expression
executes. No current can_start/can_complete/can_close result is claimed from
those failed refresh attempts. Evidence refresh-0200.log, refresh-vm-check.log
and refresh-compiler-check.log is preserved in the original preflight directory.
No app/service restart, rebuild or installation was performed to work around it.

The operator has been asked to refresh the existing route page without any
business action and report protected flags/blocking messages, plus a new native
read-only SQL result. HOLD until these current observations are available. The
previous direct SQL resolves the earlier missing reconciliation evidence at its
timestamp, but it cannot grant a timeless Start permit or prove future completion.
See RECONCILIATION_READER_42702_REVIEW.md for the separate, undeployed proposal.
