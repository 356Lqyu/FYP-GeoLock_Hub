# ONE controlled DEV attempt: GENERATE / VALIDATE / AUTHORIZE PASS

29 October 2026 MYT. Approval scope: V2, Test 42 50kg, Test 10 15kg, test c 12kg,
77kg total; existing policy and frozen graph. No pickup, recovery, cancellation,
cleanup, graph modification or automatic generation retry was authorized or run.

Immediately before submission both services returned HTTP200 ACTIVE for DEV.
Authenticated protected reads admitted exactly those three claim UUIDs, all
ACTIVE/ACTIVE and CONFIRMED with >255min lease coverage, no existing routes.
V2 was active/available/eligible, 500kg capacity, 60min duration, expected depot.
The bounded operator wrapper rechecked the exact task set, total weight, policy,
claim/lease states, server-clock coverage, owner and V2 properties inside the
existing signed-in Flutter session, before calling the existing repository's
generateAndAuthorize exactly once. It did not bypass or replace any backend RPC.
The JWT remained inside the app. No physical Generate-button tap is claimed;
the approved operation used the actual Flutter repository through its debug
operator interface. Its original request persisted in the normal owner-scoped
preferences. A local one-use dispatch marker prevents wrapper reexecution.

## Committed result

- Root request: 48272246-a4ac-4ac5-8792-291f3ea2c94b
- Snapshot: 6263bde1-2aa1-481d-b7a2-cc4a6b60008d
- Candidate / attestation key: 5b46fc16-fef6-4c68-9dbb-d619e49d0c69
- Authorization request: 3b3d110e-5ac7-59e1-b324-9aeb37d22e98
- Route: db1b455e-92d0-4d58-9fa1-5de07d7ab0f9
- Departure mode AUTO_NOW; PostgreSQL departure 00:51:13.945122 MYT.
- Database-confirmed status AUTHORISED; independent validation ATTESTED.
- V2 total load 77kg; database distance 8.107km; duration 44.405min.
- Full research metrics: 8.10671km, 44.4047min, driving 14.4047min,
  service 30min, waiting 0min; includes return to depot.
- Pickup order: Test 10 (15kg) -> test c (12kg) -> Test 42 (50kg) -> depot.
- All 3 served; 0 unserved; Proposed validation reports 0 hard violations.

The solver reached its configured approximately 15-second search budget and
returned a feasible COMPLETE result. The result is independently ATTESTED and
database-authorized; secondary optimality was not proven. This is not an HTTP
timeout or a failed/uncertain authorization. All four research outputs are retained
in result.json; normal NGO UI remains Proposed-only. Road geometry remains
unavailable; the existing map is markers-only and does not fabricate a polyline.

## Read-only postflight

New authorization request receipt returned FOUND under the real NGO session.
Protected overview returns exactly the authorized route and zero eligible tasks
because all 3 tasks are now PLANNED. The 3 claims and leases remain ACTIVE, with
unchanged expiry timestamps and recovery_pending=false. V2 remains active but is
not eligible for another plan, as expected for its current route hold. Protected
route detail shows all actual_started_at values NULL, route actual_started_at
NULL, no completed pickup, can_complete=false and can_close=false. Only the first
stop was start-eligible at that read; no start RPC was invoked. Delayed starts
must always recheck protected remaining-route validity; no start permission is
promised for a later time merely because authorization succeeded.

Confirmed through protected returned bindings and the worker journal: snapshot,
sealed matrix, candidate, attestation, authorization receipt and one route.
Committed SQL contract additionally creates one binding, 3 items, 3 stops,
3 active assignments and the authorization audit in that transaction. Exact
private-table counts/audit ID/matrix UUID were not independently SQL queried:
Supabase SQL connector was unavailable; no alternate credential was used.
Do not present inferred private counts as a separate catalog verification PASS.

Evidence: results/routing-pilot-attempts/48272246-a4ac-4ac5-8792-291f3ea2c94b/
approval.json, result.json, postflight.json, summary.json, SHA256SUMS.txt,
attempt.dart and dispatch-sent.marker. Local wrapper formatted/analyzed cleanly;
no normal application source, SQL or worker configuration changed for this attempt.

## Stop boundary

One generation/authorization attempt consumed the approval. No retries or new
request IDs were sent. No pickup, return confirmation, cancellation, claim change,
recovery or cleanup was performed. Do not press Generate again. The user may
Refresh routes and open the existing authorized route for read-only UI/map review.
Pickup lifecycle and physical post-authorization UI verification remain separate
from this backend/repository success and require their appropriate next approvals.
