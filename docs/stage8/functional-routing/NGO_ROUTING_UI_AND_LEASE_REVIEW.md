# NGO routing UI and lease review — 28 October 2026 MYT

Status: Flutter implementation, focused tests, analysis and DEV APK build PASS.
Database activity was READ ONLY. No planning, authorization, pickup, recovery,
request clearing, retry, service restart or APK installation occurred in this task.

## Blocked request and historical result

The requested account resolves to active NGO8e50bc66-7a8d-4791-bc6b-640682daa496.
Phone preferences were filtered ON DEVICE to routing XML elements only, before
crossing ADB. No authentication preference/token/password was read or printed.
The worker journal was opened with SQLite mode=ro and query_only=ON.

- Current local request cde7b517-e23a-478c-9188-b05e4e5a6ca0 belongs to that owner's
  preference key. Status blocked, phase preflight, selected V2, approved policy;
  snapshot_id absent. The client records phase snapshot BEFORE invoking the
  snapshot RPC, so this state identifies a stop during capability/health checks.
- Authoritative backend inspection found no snapshot for that request and no
  authorization receipt for this NGO; routes/assignments remain0. The owner
  predicates match the deployed receipt lookup. No NGO JWT was impersonated.
- The existing authorization-result endpoint needs a known snapshot ID, so it
  cannot reconcile this no-snapshot record directly. No uncertain write was
  retried to obtain one.
- The exact old preflight exception was not saved by the old client. It is
  unproven whether capability, activation or health caused it; no new connectivity
  investigation was performed. Future known typed failures now retain safe codes.
- A nonempty route-operation record intentionally blocks another Generate. It is
  preserved, not evidence of an authorized route. The existing explicit finished-
  operation archive guard permits a known blocked preflight to be archived locally;
  no archive was invoked here. Unknown snapshot outcomes remain protected.
- d184df24-3e54-4935-80a9-5efe9392f1ab is a PLANNING REQUEST ID, not a candidate ID.
  It points to snapshot f597018e-e068-486f-a99b-4e194a2c57dc and candidate
  a00bc45c-33f9-4193-8cb6-f313d92e4b5c. Both belong to the same NGO.
- The backend attestation/digests remain valid historical evidence. The snapshot
  cutoff12:40UTC27Oct plus4h horizon ended00:40MYT28Oct; it is stale for dispatch.
  The journal has computed/matrix/result, no automatic-authorization intent. Merely
  viewing it cannot authorize it. Both local pointers and backend evidence remain.

Two fresh claims, test c12kg and Test10 15kg, were ACTIVE/CONFIRMED with expiries
08:34:51 and08:34:55MYT28Oct. At02:58MYT the server-reported remaining times were
about336min. Older expired claims for the same NGO remain ACTIVE pending approved
recovery, despite elapsed expires_at. None was substituted, extended or recovered.

## Actual lease/authority rules

Sources: captured deployed admissible/task_window/get_my_claim_cards_v2/
recover_expired_claims definitions; approved A003/A004 SQL; actual Python
integration, phase_b/routing_model.py, validation.py, problem.py and validator service.
This is contract inspection, not live execution of expiry or handover scenarios.

| Scenario | Actual contract |
|---|---|
| Expired before generation | Excluded from the admitted pool by SQL. ACTIVE labels alone do not make an elapsed lease eligible. No automatic lease extension/recovery. |
| Valid but too short | SQL admission requires expires_at STRICTLY AFTER cutoff + horizon + margin, currently240+15=255min. Listing expiry has the same bound. Thus even a short possible route is excluded when less than this remains. A360min claim generally has only its first105min as an admission window under current policy. |
| Optional versus mandatory | For admitted tasks, optional tasks may be unserved in a feasible partial plan; mandatory admitted tasks cannot be omitted from a feasible plan. mandatory does not override SQL exclusions: excluded tasks are outside the admitted unserved complement. Current mandatory=false. |
| Later authority failure | A served task failing stale-source, route duration, lease or margin checks causes the entire authorization transaction to fail/roll back; SQL does not silently delete that stop or publish other routes partially. |
| Expires after authorization before Start | Protected route read/start rechecks current source, first unresolved stop, windows, elapsed duration/horizon and whole remaining return+margin. Start is blocked; reservations are not silently released. |
| Expires after Start before Complete | Ordinary complete_pickup still requires active, unexpired authority and confirmed handover. Its attempted transaction rolls back on expiry; read can_complete=false. Route/custody evidence requires approved reconciliation rather than automatic release. |
| Expired uncollected, no route/custody uncertainty | Approved trusted recovery can release claim/lease, mark task STALE and reopen a still-valid listing/donation as appropriate. Scheduler is currently disabled, so expired status can remain ACTIVE. |
| Expired with active assignments/route stops or uncertain custody | Existing recovery fences release and sets reconciliation-required/open review. It does not automatically release active-route donations or cancel reservations. |
| Already collected with COMPLETED claim/lease | Past expires_at does not undo custody or make goods claimable. Recovery selects ACTIVE leases, so completed records are not reopened. Protected depot closure still requires all pickups resolved; it does not require completed leases to remain future-dated. Abnormal COLLECTED + ACTIVE expired authority is fenced for reconciliation. |

Important validation distinction: Python planning/independent validation check each
served stop's service completion plus margin against its lease. PostgreSQL adds
whole-route return plus margin at authorization and remaining-route Start checks.
Current strict255min admission and240min horizon bridge that difference for normal
fresh inputs, but attestation is not permission to skip later database checks.
No objective, solver, mandatory setting,360min lease policy or backend was changed.

## Flutter changes

- Vehicle selection precedes claimed-donation review. The page always reads the
  existing owner-scoped get_my_claim_cards_v2, even when overview succeeds.
- Claim cards show title/weight/state and lease evidence. Remaining duration is
  expires_at minus that RPC's server_now, explicitly labelled at last refresh.
  No phone-clock eligibility decision or invented required-coverage value.
- Expired/pending recovery, reconciliation, assigned and completed states have
  distinct messages. Exact current routing eligibility still comes from overview.
- Normal flow retains Generate & Authorize and protected authorized-route actions.
  A concise request-review card explains blocking without exposing raw IDs.
- Worker checks, operation/request/snapshot/phase/failure IDs, manual read-only
  outcome checks, explicit same-operation resume/archive and historical candidate
  view are inside collapsed Advanced / troubleshooting. Recovery actions remain
  accessible through Review request, not ordinary happy-path controls.
- Detail route/candidate/snapshot/depot node IDs move to collapsed Route diagnostics;
  normal stop and vehicle summaries omit technical identifiers.
- Friendly errors cover expiry, lease coverage, capacity, infeasibility, stale
  inputs, validation/authentication/authorization rejection and blocked pickups.
  Unknown responses remain uncertain; no request IDs are discarded.
- Future failures save safe typed failure_code where available. The historical
  missing error is not guessed or backfilled.
- Explicit cleanup of a known finished advisory context now archives its exact
  JSON under an owner/request history key before removing the active pointer.
  Current local records were not cleared or edited by this task.
- Generate retains all freshness/owner/policy/vehicle/eligible-task/operation gates.
  Start/Complete retain fresh protected read and per-stop backend flags/RPC checks.

Modified production files:
frontend/geolock_hub_app/lib/routing/ngo_routes_page.dart
frontend/geolock_hub_app/lib/routing/ngo_routing_repository.dart
frontend/geolock_hub_app/lib/routing/routing_feedback.dart (new)

Tests:
frontend/geolock_hub_app/test/routing_feedback_test.dart (new)
frontend/geolock_hub_app/test/routing_connection_visibility_test.dart
frontend/geolock_hub_app/test/ngo_routing_test.dart

## Tests and preservation

Final analysis: no issues in6 selected changed files.
60 focused Flutter tests PASS,0 failed,0 skipped, including the existing disposable
SQL capture replay; no new PostgreSQL fixture or live business call was used.
Cases cover collapsed diagnostics, exact server-relative lease display, friendly
errors without IDs, preserved unknown operation, archived historical context,
duplicate/replay gates, Proposed/maps, authorization and stop action gating.

An initial local encoding mistake and two moved-widget test expectations were
corrected before final passing analysis/tests/build. No failing code was installed.

Final READ ONLY preservation check03:08MYT28Oct: snapshots4,candidates1,
attestations1,routes0,assignments0,owner receipts0; no snapshot for cde7...
Both current fresh claim IDs remain ACTIVE under the same NGO.
No backend schema/RPC/migration/graph/algorithm/configuration change was made.

## Backend limitations / separate decisions

- Overview returns eligible tasks but no excluded-task reasons or policy horizon/
  margin metadata. Claim cards return server time/expiry but not required route
  coverage. The client cannot truthfully label every exclusion insufficient lease
  or display exact per-donation required coverage before a plan exists.
- Some worker database failures are translated to generic rejection/stale codes,
  losing a precise task/lease reason. Frontend messages are specific only when
  backend evidence supports it. No exception message is treated as fabricated
  per-donation timing evidence.
- Reducing the conservative255min admission rule to actual route coverage would
  require a separately reviewed policy/backend decision. It was not changed.
- A root-request-only read-only snapshot lookup would improve reconciliation for
  unknown snapshot outcomes with no snapshot ID. No new RPC was invented.
- Historical preflight failure is not recoverable from the old saved fields.
  Current evidence confirms no backend snapshot/authorization, not the old exception.

## Rebuild / install (installation not performed)

A new named APK with the explicit DEV URL and advanced UI was built/verified:
build/verified-dev-routing/geolock-dev-routing-ui-20261027T190809Z.apk
SHA256 6aea899b4d78a27e8518259592fea4268db9ace641d541f9c0a0d5e8a3758aca.
Artifact filenames use UTC; this build was03:08MYT28October.

~~~powershell
Set-Location -LiteralPath 'C:\Users\User\Downloads\FYP-GeoLock_Hub\frontend\geolock_hub_app'
& 'C:\flutter\src\flutter\bin\flutter.bat' build apk --debug --no-pub --dart-define=GEOLOCK_SUPABASE_ENV=dev --dart-define=GEOLOCK_ROUTING_API_URL=http://127.0.0.1:8787
~~~

To install the already verified named artifact while preserving app data/session:

~~~powershell
$adb = 'C:\Users\User\AppData\Local\Android\Sdk\platform-tools\adb.exe'
$apk = 'C:\Users\User\Downloads\FYP-GeoLock_Hub\frontend\geolock_hub_app\build\verified-dev-routing\geolock-dev-routing-ui-20261027T190809Z.apk'
if ((Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash.ToLowerInvariant() -ne '6aea899b4d78a27e8518259592fea4268db9ace641d541f9c0a0d5e8a3758aca') { throw 'APK hash mismatch' }
& $adb install -r $apk
if ($LASTEXITCODE -ne 0) { throw 'Install failed' }
& $adb reverse tcp:8787 tcp:8787
& $adb reverse tcp:8788 tcp:8788
& $adb shell am start -n com.example.geolock_hub_app/.MainActivity
~~~

Do not uninstall, clear app data or press Generate/Resume/Archive as part of merely
reviewing this UI. The current operation remains intentionally blocking until its
explicit operator resolution. A future rebuild must get its own hash/artifact.

