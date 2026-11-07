# Physical Android routing request failure and corrections

27 October2026. Implemented local fixes and built the debug APK. No authenticated
planning request, claim, snapshot, matrix storage, candidate, attestation, route
authorization, pickup, recovery or graph/permission change was performed by Codex.
Actual full Flutter/DEV demonstration remains unverified pending phone access and
separate approval for a fresh planning attempt.

## Confirmed failure and remaining uncertainty

The exact source of the displayed sentence is the fallback in routingError:
exceptions other than StateError, FormatException or PostgrestException became
`Request was not confirmed. Check your connection and refresh.` The original
transport exception/status was not retained by the old app. Do not pretend that
this sentence proves a specific errno, expired JWT or a capacity failure.

Available evidence isolates the failed boundary to snapshot response / phone-to-
planner entry, before journaled planning:

- User says error was almost immediate, not after the150s response deadline.
- Supabase edge logs11:25–11:40UTC show four begin_my_routing_snapshot HTTP200
  responses from Dart, plus successful fleet/overview reads. No /auth/v1/user
  request is present in the available edge log result for that window. This
  supports a failure before planner-side JWT verification, but is not a guarantee
  that every possible request is captured by those logs.
- Initial11:35UTC inspection found2unsealed snapshots; later inspection found a
  third with11:38UTC cutoff. Every snapshot selected V2. All have matrix_idNULL,
  sealed_atNULL. Matrices/candidates/validations/routes/assignments remain0.
- Actual protected local journal was opened query_only/read-only:0jobs,0steps.
- Both host /health endpoints ACTIVE, correct DEV project. A deliberately
  unauthenticated empty POST/v1/plan returned401 AUTHENTICATION_REQUIRED; it could
  not enter planning or cause a business write.
- Both ADB inspections returned an empty device list. Current USB/reverse/logcat
  access therefore could not verify the historical phone socket exception. This
  does not prove the phone was disconnected at the original failure time.
- Existing debug merged manifest includes INTERNET and the loopback network
  security configuration. Source accepts127.0.0.1 HTTP only in debug mode.

**Conclusion:** two app defects are confirmed: opaque exception handling and lost
planning IDs across Refresh/rebuild. The evidence points to the phone/planner
transport boundary, not an executed solver/capacity/validator rejection. The exact
underlying historical OS/network cause is NOT RECOVERABLE from the old message
without the missing phone log. No arbitrary timeout, TLS, lease or permission
relaxation was applied to mask it.

## Existing DEV requests preserved

| Request ID | Snapshot ID | Cutoff UTC |
|---|---|---|
|41475476-df33-4f57-bcdc-08801558b6ac|2aa2c13b-091f-49fc-81c1-891f6d414676|11:26:23.828900|
|d61f4966-937d-43a8-b753-5d91f580fa94|d761e0a1-6bd6-4c75-a7da-de40aa973dd7|11:27:12.501769|
|20407d86-3372-4ba4-81f5-44ab8fcefcf5|d0e82ff8-40cd-4199-99cd-e3330e97e690|11:38:02.831791|

All are past the unchanged300s freshness limit; do not blindly replay them or
delete/reset them. They never produced authority. The additional client attempt
appeared during inspection; Codex sent no authenticated planning request.
Old app IDs cannot be reconstructed into its prior local state automatically;
these DEV records/evidence retain them. New attempts now persist IDs locally.

Evidence: `results/routing-failure-diagnosis/20261027/`: failure_inspection.json/sql,
failure_final.json/sql, edge-http-summary.json/sql and offline-costs.json.

## Actual pilot data and modeled feasibility

- NGOtest ngo8e50bc66-7a8d-4791-bc6b-640682daa496, active verified depot1755847853.
- Claimca8eb131-6ca0-4256-9a8c-c8f781fcbf05, taskdaa38fdb-ce05-4ca2-aca2-b808cfeb5216,
  listing2d06b504-d2dd-4121-8840-c8bf893f8a60, Test42,50kg, pickup5724643871.
  Claim/leaseACTIVE, taskCONFIRMED, donation/listingCLAIMED, no listing expiry.
  Lease expires2026-10-27T17:23:40.741031Z. Current240+15minute admission needs a
  new cutoff before13:08:40.741031UTC /21:08:40MYT. Do not extend authority to test.
- V2c5c1836c-9d55-4004-8851-0f4ecf6d0f32, same NGO/depot,500kg,60min, active and
  available. No routes or assignment holds. Select V2, not20kg V1.
-50kg fits500kg. Road nodes for depot and all3snapshot observations are active in
  OSM-OPS-20261018. Recorded location eligibilityELIGIBLE,3.389889978km within20km.
- Reused the checksum-pinned sealed local cache to calculate only offline travel
  costs, not a planner result or performance probe. Exact6-decimal distance/time
  arithmetic and the existing C2 distance/time/edge-ID tie rules were preserved.
  All4×4directed costs are available. All9overlapping costs match the previous
  successful C2 diagnostic matrix exactly.
- For the actual50kg stop: outbound3.38989km/6.4586min, return3.4886km/6.0912min,
  service10min: **22.5498min <60min**. Modeled frozen-road time only, no live traffic
  or physical handover claim. The two old20kg/150kg observations remain captured
  but are excluded by expired authority; no recovery is needed or performed.

## Implemented corrections

1. Direct Flutter planner now performs bounded GET/health (5s, correct ACTIVE DEV
   project) before a new snapshot RPC. Broken phone/ADB connectivity cannot create
   another orphan snapshot first. Health is not JWT or route authorization proof.
2. New **Check planner connection (read only)** button does only this GET. No JWT,
   snapshot, matrix or business operation. It is the next phone-side diagnostic.
3. HTTP errors now carry sanitized phase/code/status and request/snapshot IDs.
   Socket reason categories distinguish refused/reset/closed, DNS, network permission
   or cleartext denial, without logging raw exceptions, URLs, headers or tokens.
   Timeouts remain150s and are UNKNOWN outcomes, never infeasibility or success.
4. Planning IDs, policy/vehicle selection and confirmed snapshot ID are saved BEFORE
   writes in per-NGO SharedPreferences. Refresh/new repository instances reuse the
   saved context. Known snapshot IDs skip begin_my_routing_snapshot on retry.
   Unknown outcomes cannot silently be cleared/replaced; changed vehicles/policy
   require reconciliation. No automatic retry is introduced.
5. UI shows pending/rejected/infeasible/candidate outcomes and safe IDs. Four-method
   comparison and proposed ordered stops are preserved. Authorization requires
   CANDIDATE_READY + candidate ID + ATTESTED + chosen departure. Database routes
   still come from get_my_routing_overview bindings/public routes; detail/start/
   complete/close operations remain protected database RPCs.
6. Worker emits safe UUID-correlated HTTP/JWT/read-snapshot/matrix/optimization/
   independent-validation stages and response status. RPC failures record phase,
   exception class and SQLSTATE only. No payload/JWT/DSN/secret logging. Existing
   write-worker retry/commit semantics and activation guards are unchanged.

## Tests and build actually run

-37focused Flutter tests PASS, including real saved LOCAL PostgreSQL lifecycle
  capture; no live HTTP/RPCs. Transport timeout/rejection/redaction, read-only
  preflight, pending ID persistence, replay, cross-owner and ATTESTED gating tested.
-103worker tests PASS; then28focused worker/event tests PASS after adding logging
  assertions. These use synthetic transports/real local solver and validator,
  not live Supabase planning or handover.
- Dart analysis on all3modified production files: **No issues found**.
- Debug Android APK build PASS,83.4s, exact DEV/127.0.0.1 flags. Artifact:
  `frontend/geolock_hub_app/build/app/outputs/flutter-apk/app-debug.apk`
  SHA256816f721f4e113b0c08141b7185042e725566ed6f8e0cc254450871b8987f8e6c.
- Offline cost check PASS with no DEV connection/route creation. No full graph
  performance/export probe rerun. Frozen graph/cache/policy/DB permissions unchanged.

## Install the already built corrected app — no planning approval implied

Reconnect/authorize the physical USB phone first. From repository root:

```powershell
$adb='C:\Users\User\AppData\Local\Android\Sdk\platform-tools\adb.exe'
$phones=@(& $adb devices | Select-String '^\S+\s+device\s*$' | ForEach-Object {($_.Line -split '\s+')[0]} | Where-Object {$_ -notlike 'emulator-*'})
if($phones.Count -ne 1) { throw 'Connect exactly one authorized physical phone; stop here.' }
& $adb -s $phones[0] reverse tcp:8787 tcp:8787
if($LASTEXITCODE -ne 0) { throw 'ADB reverse failed; stop here.' }
& $adb -s $phones[0] install -r '.\frontend\geolock_hub_app\build\app\outputs\flutter-apk\app-debug.apk'
if($LASTEXITCODE -ne 0) { throw 'Install failed; do not uninstall or clear app data.' }
& $adb -s $phones[0] shell am start -n com.example.geolock_hub_app/.MainActivity
```

This preserves app data; do not uninstall/clear preferences. If rebuilding later:

```powershell
Set-Location '.\frontend\geolock_hub_app'
& 'C:\flutter\src\flutter\bin\flutter.bat' --no-version-check run --debug --no-pub -d '<physical-device-serial>' --dart-define=GEOLOCK_SUPABASE_ENV=dev --dart-define=GEOLOCK_ROUTING_API_URL=http://127.0.0.1:8787
```

Open Pickup Routes, Refresh, then **Check planner connection (read only)** while
fresh. Capture only its sanitized result/code, not JWTs. This needs no business-write
approval. If failed, its fixed transport category identifies the next narrow fix
without a planning write. No original socket error is invented from that new check.

To load backend event logging, restart the EXISTING services while idle, validator
first then planner, using the same actually approved activation reference and native
hidden password prompts. No additional instance/scheduler is needed. Codex did not
stop/restart services. In separate terminals AFTER stopping each old instance:

```powershell
$ref=Read-Host 'Existing approved service-activation reference'
.\backend\routing\worker_service\windows\Start-Worker.ps1 -Mode validator -Activate -ApprovalRef $ref
```

```powershell
$ref=Read-Host 'Existing approved service-activation reference'
.\backend\routing\worker_service\windows\Start-Worker.ps1 -Mode planner -GraphId 'eab1f7ee-a8e0-4bed-a0e1-2c4bff024936' -Activate -ApprovalRef $ref
```

## Next explicit DEV write approval

After phone read-only health PASS, authorize ONE fresh planning attempt for the
existing50kg claim and V2. This covers a new snapshot, matrix/seal, candidate and
independent attestation only. Existing stale snapshots are preserved. Authorization,
pickup start, actual handover completion and depot return remain separately approved
business actions. No new claim, fabricated data, recovery or lease extension.
Live authenticated planning and the first phone E2E demonstration remain NOT RUN
by Codex under the present read-only boundary.

## Requirement sources reviewed unchanged

- Downloads/RSW_LimQianYu_LowSusan_FullText.docx: post-claim valid task scope,
  constrained routing and baseline comparisons; optimizer cannot create ownership.
- Downloads/第6组_Lim Qian Yu与Low Susan_GeoLock Hub.pdf: provided supervision analysis,
  deterministic authority, capacity/time validity, independent route validation,
  idempotency and no unconfirmed-success presentation (not an inferred write approval).
- Downloads/GeoLock_Hub_Coordination_Authority_Contract_v3_2_DEV_Aligned_Draft.docx,
  especiallySection12. Its October24 dispatch-gap note predates approved003;
  current deployed003 routing authorization/lifecycle SQL governs execution.
  Do not rewrite historical wording or claim independent two-party handover evidence.

Changed production files: Flutter routing_worker_client.dart,
ngo_routing_repository.dart, ngo_routes_page.dart; backend server.py,
orchestrator.py, transport.py. Tests: routing_worker_client_test.dart,
ngo_routing_test.dart, new routing_pending_request_test.dart, test_worker_flow.py,
new test_request_events.py. Only diagnosis evidence/docs added otherwise.
