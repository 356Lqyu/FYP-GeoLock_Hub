# Read-only review: blocked request 20a8b059

28 October 2026, approximately 14:12–14:16 MYT. DEV rcgyuwiidqvrgbxswhqj only.
No production source changes, service restart, request retry, local dismissal,
snapshot generation, authorization, pickup, recovery or scheduler change.

## Confirmed trace and boundary

Android owner-scoped local operation for NGO 8e50bc66-7a8d-4791-bc6b-640682daa496:
request 20a8b059-63fc-40b6-bea9-0751ef1a199b; blocked/preflight;
failure_stage authorization_capabilities_read; failure_code PLANNER_HTTP_REJECTED;
intent GENERATE_AND_AUTHORIZE; V2 c5c1836c-9d55-4004-8851-0f4ecf6d0f32.
No snapshot_id, authorization_request_id or authorization recorded. Historical
local operations cde7b517... and 0ad26626... remain archived; no entries modified.

Flutter first POSTs /v1/authorization-capabilities with NGO JWT and original request
ID. Planner verifies JWT with Supabase, reads list_my_vehicles under that JWT,
then reads get_my_routing_authorization_receipt to establish auto-now capability.
Only after success and combined_generation_enabled=true does Flutter durably save
phase=snapshot BEFORE invoking begin_my_routing_snapshot. Thus this failure
preceded snapshot creation, matrix construction, optimization and validation.

DEV READ ONLY queries confirm no snapshot with request 20a8b059..., no owner
authorization receipts, 4 historical snapshots, 1 candidate, 1 validation, 0 routes,
0 assignments and no AUTHORIZE_ROUTING audits today. The old planning request
d184df24-3e54-4935-80a9-5efe9392f1ab owns snapshot
f597018e-e068-486f-a99b-4e194a2c57dc and candidate
a00bc45c-33f9-4193-8cb6-f313d92e4b5c under the same NGO. It is separate historical
advisory evidence, not an authorized route or a result of this failed request.

The blocked preflight operation is safe for explicit local archival/dismissal
with its original JSON retained: durable phase ordering AND negative backend
evidence establish no business attempt. Absence of a receipt alone is not used
to infer rollback. Do not silently clear it or generate a replacement.

## Exact rejection confirmed by operator and Supabase logs

Original planner log: 06:06:08.983848Z received/verify_ngo_jwt;
06:06:10.121861Z ngo_authenticated; 06:06:10.418852Z HTTP409
DATABASE_REJECTED_REQUEST. Both JWT verification and NGO-only vehicle read passed.
The later unauthenticated 401 was this investigation's read-only endpoint check.

Supabase postgres_logs for 06:06:00–06:06:20Z returned at 06:06:11.840000:
"cannot execute SELECT FOR SHARE in a read-only transaction". The deployed receipt
RPC is STABLE and calls fleet_private.require_ngo(), which takes FOR SHARE OF n,u
profile locks. PostgREST runs STABLE POST RPCs READ ONLY. This lock/access-mode
conflict rejects the capability read before a snapshot exists.

Smallest proposed fix: keep receipt STABLE; use auth.uid() plus the identical
non-locking active-NGO/profile-role checks ONLY inside this receipt reader.
Preserve owner scope, output contract, SECURITY DEFINER, search_path and ACL.
Leave require_ngo and all authorization/pickup writers unchanged. Exact review-only
SQL: receipt_readonly_fix.PROPOSAL.sql. NOT deployed or regression-tested yet;
requires disposable PG17 READ ONLY FOUND/NOT_FOUND, other-owner/invalid-user,
grants and PostgREST transaction-mode tests before approval. Existing local RPC
tests used read-write connections and missed this API-specific failure.

Official transaction contract: https://docs.postgrest.org/en/v13/references/transactions.html

## Diagnostic limitations established before original logs arrived

Confirmed client defect: routing_worker_client.dart maps non-allowlisted backend
codes to PLANNER_HTTP_REJECTED; ngo_routing_repository.dart persists code/stage
but not HTTP status. Android logcat has build readiness messages but no request
status. Worker request logs print sanitized routing_request JSON to the operator's
console, not a durable request-event log file. No app terminal is attached here.
The journal contains only the historical snapshot job; preflight does not enter
it. The requested original http_rejected line is needed to distinguish the
historical HTTP status/backend code. No JWT/publishable-key/database diagnosis
is proven by this generic message; do not label the live issue fixed.

Both actual GET /health responses are HTTP200 ACTIVE for the correct DEV project.
An intentional unauthenticated POST to the READ-ONLY capability endpoint, using
the same request ID and no token, returns HTTP401 AUTHENTICATION_REQUIRED. This
confirms the live endpoint and fail-closed auth guard only; it is NOT the original
authenticated rejection and is not used as evidence of an expired user JWT.
Both listening processes use native_worker mode. No graph load was performed.
Receipt RPC exists, postgres owner/SECURITY DEFINER, authenticated EXECUTE granted.
Frozen graph ID/digest still match the approved manifest. Current graph/planner/
validator credential connectivity and combined-enable flag are not established
by health alone; previously successful evidence is preserved, not rerun.

The three new claims test c, Test 10 and test b are ACTIVE/ACTIVE, owned by this
NGO and CONFIRMED, expiring at 20:01:57/20:02:03/20:02:14 MYT. Their lease states
are not evidence for this initial authenticated HTTP rejection.

## Installed APK and tests

Device checksum 425daf999b2408c3181423572ff4d2a08d8ed34aa851fbf19aeb7124ea54ef2c
matches the verified artifact geolock-dev-routing-20261028T060423Z-0b92d5.apk,
DEV URL http://127.0.0.1:8787. Latest process logged configuration=READY.
An earlier process logged URL_MISSING; it is not the current running build.
No APK was built or installed in this review.

Executed offline verification:
- Flutter test: routing_worker_client_test, automatic_route_operation_test,
  routing_resume_ui_test, routing_feedback_test: 34 PASS, 1 SKIP (optional
  disposable-PostgreSQL capture path was not supplied). No DEV API test traffic.
- Flutter analysis on ngo_routes_page, ngo_routing_repository,
  routing_worker_client and routing_feedback: no issues.
- Python unittest backend.routing.worker_service.tests.test_combined_workflow:
  9 PASS. Synthetic transports/temporary local state only; no live planning.

## Minimal implementation proposal

1. Keep the normal screen to vehicle selection, eligible claims, Generate &
   Authorize, friendly outcome, owned authorized routes/maps/ordered stops and
   protected Start/Complete/Return controls. Keep markers-only geometry disclosure.
2. Move existing advanced controls and raw IDs into a separate explicit
   developer/support diagnostics page. Do not treat a debug APK alone as operator
   authorization. Exclude planning-only candidates from normal authorized results.
3. On pending/unknown state, keep automatic owner-scoped read-only receipt lookup;
   FOUND restores the database route, NOT_FOUND retains uncertainty. Show only
   'Route setup needs attention' and a support path in the normal screen. No resume
   write or changed ID on reopening. Offer an explicit safe local dismissal only
   for evidence-confirmed preflight stops; preserve every archived record.
4. Preserve allowlisted server error codes and HTTP status in failure evidence;
   friendly messages in normal UI, fixed diagnostic metadata in support. Never
   persist response bodies, JWTs, headers or arbitrary upstream error text.
5. Retain current protected overview/detail reads on reopen. Start remains a fresh
   stop-specific protected check, separate from authorization; a candidate is never
   rendered as an authorized route unless the database receipt/read confirms it.

Likely production files: lib/routing/ngo_routes_page.dart,
lib/routing/ngo_routing_repository.dart, lib/routing/routing_worker_client.dart,
lib/routing/routing_feedback.dart; extracted diagnostics page if approved.
Tests: transport error preservation; blocked/unknown operation visibility; history
retention; no automatic write retry; protected route restoration/map/start gates.
No backend algorithm, authorization RPC, schema, graph or recovery change proposed.

The original log has now been supplied and correlated as described above. Next:
review the targeted receipt correction, verify it locally, then seek separate
approval for a guarded forward migration. Do not tap Generate to reproduce it.
