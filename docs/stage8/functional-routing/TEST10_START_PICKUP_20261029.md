# Test 10 Start Pickup: one approved operation

29 October 2026 MYT. User explicitly approved exactly one start_pickup for claim
73f345b8-c293-454e-8bea-16d91019fc3c on route
db1b455e-92d0-4d58-9fa1-5de07d7ab0f9. No other business operation approved.

The existing signed-in NGO session's read channel was available again. A fresh
protected read at 02:16:53 MYT confirmed exact route/claim/task identity,
AUTHORISED, authorization_confirmed=true, and only Test 10 can_start=true.

The local one-use operator wrapper invoked the existing Flutter repository
pickup(route,task,complete:false) once. Its existing fresh protected read and
the RPC's own transactional checks remained in force. No UI tap or physical
handover is claimed. JWT remained within the existing app clients. A new local
dispatch marker was created before invocation; no automatic retry occurred.

RPC returned success. Immediate protected read confirmed:

- Route IN_PROGRESS, ATTESTED, authorization_confirmed=true.
- Route actual start 02:18:26.641253 MYT.
- Test 10 task DISPATCHED; actual start 02:18:26.638573 MYT.
- Test 10 can_start=false, can_complete=true.
- test c and Test 42 remain PLANNED, actual starts null, can_start=false,
  can_complete=false. Block reason PREVIOUS_PICKUP_UNRESOLVED is expected.
- All three claims and leases remain ACTIVE; no recovery-pending marker.
- Test 10 listing remains CLAIMED. Its lease expiry remains 06:14:11.122793 MYT.
- V2 binding still matches route/candidate/snapshot; active, version 1,
  available_for_planning=true but eligible_for_planning=false. No vehicle release.
- can_close=false and can_cancel=false.

Read-only NGO-session SELECTs for the owned Test 10 donation and new audit rows
returned empty arrays. This does not prove donation absence or absence of audit
events: row visibility is restricted and was not independently verified with the
owner-export profile. The deployed atomic start contract transitions donation to
PICKUP_IN_PROGRESS and records START_PICKUP SUCCESS plus lifecycle audit, but
these particular rows remain NOT INDEPENDENTLY VERIFIED. Do not report full
audit/donation postflight PASS without the approved native read-only SQL result.

Evidence: results/pickup-start-attempts/20261028T181758Z-856780/approval.json,
start-once.dart, dispatch-sent.marker, execution.log, result.json, summary.json,
SHA256SUMS.txt. Successful core-state assertions ran against result.json; these
are postflight evidence checks, not a new integration test or a second write.

STOP: no Complete Pickup, second start, depot return, closure, cancellation,
recovery, lease change, graph change, migration or app installation occurred.
The next protected business action is Test 10 completion only after separate
approval and truthful confirmation of the controlled test handover. Availability
at this read does not authorize it. Re-run existing_route_pickup_preflight.readonly.sql
to independently confirm donation status and new audit events using the approved
export profile; it contains only reads and ROLLBACK. Keep the 42702 reader fix separate.
