# Simplified NGO routing release — 28 October 2026 MYT

IMPLEMENTATION / OFFLINE TESTS / PHYSICAL ANDROID UI PASS.
No live route generation, authorization, pickup or recovery was performed.

## Confirmed root causes

1. The former main list used all active claim cards. An expired lease can remain
   ACTIVE while recovery is disabled. Main routing now starts only from the protected
   get_my_routing_overview eligible_tasks pool and enriches it with existing claim
   card server time/expiry evidence. Card expiry/recovery evidence can remove a
   task, never add an excluded task. If overview fails, no claim is called eligible.
   My Claims was not changed.
2. The installed phone APK hash ecf1d002587e650917f68bbb72748f9e4d82735165588fd2c5657b269b923319
   matched the generic build output. It was NOT the named verified UI artifact with
   hash6aea899b4d78a27e8518259592fea4268db9ace641d541f9c0a0d5e8a3758aca.
   Runtime explicitly logged PLANNER_URL_MISSING. The verified artifact did not
   lose its configuration; a different generic artifact was installed. How that
   generic build was invoked is unproven.
3. Review request only expanded a support section below the viewport and supplied
   no simple resolution for the conclusively preflight-only interruption. The new
   contextual Dismiss interrupted setup opens an explicit confirmation. It archives
   original JSON locally, then clears only the finished active pointer. No request
   is automatically replaced, and the real record remains untouched in this task.

## Operation safety and restoration

Actual request cde7b517-e23a-478c-9188-b05e4e5a6ca0 is still blocked/preflight,
intent GENERATE_AND_AUTHORIZE, no snapshot/authorization IDs or receipt. Source
ordering durably saves phase snapshot BEFORE any snapshot RPC. The backend again
confirmed no snapshot for this root, no owner authorization receipt, no route and
no assignment. This combination proves a preflight-only stop; receipt absence
alone would not. The exact old failure exception was never saved and is not guessed.

isFinishedPreflight additionally rejects records with a snapshot, authorization,
authorization request ID, wrong phase/status or missing intent. Unknown writes
remain preserved. A user must explicitly confirm dismissal; it was not pressed.

restoreRouteOperation uses existing owner-scoped read-only receipt reconciliation
on page reopening when a snapshot is known. Unknown combined responses also perform
one read-only reconciliation. FOUND restores the existing receipt/routes; NOT_FOUND
or transport failure preserves the original operation and IDs. Neither path calls
planning, authorization or same-operation resume automatically.

The normal page always loads managed routes through the protected owned overview.
Opening a route uses get_my_authorized_route; local preference presence is not
route authority. Page reopens and repository recreation are covered by tests.
DEV currently has no authorized route, so actual live route restoration is not
claimed. Historical advisory candidate/snapshot evidence is never auto-authorized.

Start/Complete keep the existing fresh route/detail read and protected stop flags;
the existing start_pickup/complete_pickup RPCs still revalidate authority. No
authorization RPC is invoked by pickup start. Unknown or expired authority blocks
the action; ordinary completion cannot silently override custody reconciliation.

## Main interface

Vehicle selection → backend-eligible claimed donations → Generate & Authorize →
owned pickup routes. Normal cards retain the authorized summary/map/stops from
the existing detail screen. Old expired/recovery-pending donations remain in My
Claims and are absent from the routing list.

Technical IDs, health checks, read-only outcome checks, explicit retries/archives
and historical candidate inspection are under collapsed Advanced / troubleshooting.
Contextual Get help now scrolls that section into view. Known preflight interruption
gets the one-time dismissal action instead of a vague Review request. Future
failure code/stage is retained using safe fixed/transport codes; no raw JWT or
upstream response is persisted.

## Actual verification

- 68 focused Flutter tests PASS,0 failed,0 skipped; analysis clean for7 selected
  changed/related files. Existing disposable SQL capture replay was reused.
- New cases cover eligible-only/expired race filtering, explicit dismissal/history,
  rejecting uncertain records as safe dismissal, repeated read-only reopening,
  committed receipt restoration without authorization, database route restoration
  without local preferences, expired Start blocking, unknown response reconciliation.
- Existing duplicate/idempotency/Proposed/maps/ownership/expiry tests remain passing.
- The dismissal test caught an overlapping freshness-timer issue when reload was
  nested inside perform. Reload now occurs after perform finishes; regression passes.
- Build/install helper AST PASS and actual build/install succeeded.
- Exact named APK:
  frontend/geolock_hub_app/build/verified-dev-routing/geolock-dev-routing-20261027T193919Z-d412cd.apk
  SHA256425daf999b2408c3181423572ff4d2a08d8ed34aa851fbf19aeb7124ea54ef2c.
  Compiled DEV URL was checked before copy/install; installed device SHA matched.
- adb install -r retained app data/session. No uninstall/clear was used.
- Independent phone UI read showed only test c12kg and Test10 15kg, with about
  293min remaining from the server read; no expired Test42/Test40 entries.
  Advanced was collapsed; Dismiss interrupted setup was visible; no URL warning.
- Runtime logged configuration=READY. User confirmed Planner ACTIVE for DEV from
  the automatic Android GET /health check after expanding support.
- Routing preferences were filtered on-device before reading. No authentication
  preference/token was read. The real cde7... record remains blocked/preflight.
- Final READ ONLY database observation03:42MYT: snapshots4,candidates1,
  attestations1,routes0,assignments0,owner receipts0. Both new claim IDs remain ACTIVE
  under the same NGO. Recovery remains disabled.

## Reproduce safely

From the repository root:

~~~powershell
Set-Location -LiteralPath 'C:\Users\User\Downloads\FYP-GeoLock_Hub'
& '.\scripts\Build-VerifiedRoutingDev.ps1' -Install
~~~

Already executed. This runs the explicit DEV/debug planner defines, validates the
compiled URL, creates a unique APK+JSON manifest, installs that SAME artifact with
-r, verifies its hash on the phone, restores ADB8787/8788 and opens the existing app.
No execution-policy bypass is used. Do not run tests/other Flutter builds concurrently
with this build or install the ambiguous generic app-debug.apk afterward.
Without -Install it only builds/verifies a named artifact.

## Files

Production: lib/routing/ngo_routes_page.dart, lib/routing/ngo_routing_repository.dart.
Helper: scripts/Build-VerifiedRoutingDev.ps1.
Tests: routing_resume_ui_test.dart(new), routing_feedback_test.dart,
routing_connection_visibility_test.dart, ngo_routing_test.dart,
automatic_route_operation_test.dart.

All Flutter paths are under frontend/geolock_hub_app. No Supabase migration/schema,
protected RPC, road graph, algorithm,360min lease policy or recovery config changed.

## Remaining limits and next pilot step

The strict >255min admission policy, unavailable per-donation exclusion/required
coverage metadata and some generic worker error codes remain backend limitations.
A truly uncertain snapshot with no ID still lacks a root-only read lookup: keep
that record for support rather than infer rollback or auto-resume. The map remains
the approved markers-only representation. No service restart or activation change
was made.

For the next controlled live test: explicitly dismiss the proven preflight-only
interruption once, confirm the dialog (history retained), refresh, verify current
eligible claims and V2, then explicitly initiate the approved Generate & Authorize
attempt. Existing protected preflight still checks NGO JWT and combined-write
capability before any snapshot. Stop on an uncertain result; do not press a new
request. No generation or local dismissal was performed during this UI task.

