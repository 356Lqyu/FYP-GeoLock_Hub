# 20261109 Claim-Scoped Reconciliation — DEV Impact Assessment

Assessment date: 2026-11-01. This is a read-only DEV assessment and local validation record. No DEV schema or data writes, recovery invocation, migration deployment, or Test 10 modification occurred.

## A. Migration correction and anchor audit

The failed migration reported `RECOVERY_CANDIDATE_LOCK_SOURCE_DRIFT` because the recovery function deployed on DEV has four spaces before its `limit` clause. The old multiline anchor did not reliably match the function body as transported to PostgreSQL. The migration now constructs the anchor explicitly from the preceding line, `chr(10)`, exactly four `chr(32)` characters, and the limit line. It continues to require exactly one occurrence and raises a named drift exception for zero or multiple matches.

CRLF is normalized to LF only in the four function sources being patched. Whitespace beyond CRLF normalization is still matched exactly. Eleven source replacements remain guarded by `position` plus exact occurrence count. Read-only DEV inspection verified each expected anchor occurs exactly once across:

1. `recover_expired_claims(integer)`: candidate lock, route-lock insertion, route-activity guard, safe-release call, task transition, listing transition, audit reason, and local declaration (8 anchors).
2. `defer_my_pickup_for_reconciliation(uuid,uuid)`: dispatched-task guard (1).
3. `get_my_authorized_route(uuid)`: deferred-stop route-read guard (1).
4. `report_my_route_interruption(uuid,text,uuid)`: legacy-case-only report guard (1).

The five-space form of the candidate lock was absent; its four-space form was present once. DEV's normalized source hashes matched the approved local Stage 8 sources for all four patched routines. The migration was not run on DEV.

Migration: `20261109_claim_scoped_reconciliation.sql`  
SHA-256: `AA073352C8B0F59E09F2784B5B072E3F748E7A9520D1B6B40D8EED3160EA57BA`

## B. Database impact matrix

| Object | Classification | Current-to-post-migration impact |
|---|---|---|
| `public.recover_expired_claims(integer)` | Directly modified | Locks route scope before claim/task rows. A target `CONFIRMED`/`PLANNED` task with no consumed/collection evidence can be released; a dispatched/uncertain task remains claim-scoped reconciliation. Only named expected route-feasibility `P0001` errors are treated as infeasibility; unexpected `P0001` and other errors propagate and roll the operation back. |
| `routing_private.release_expired_unstarted_stop(uuid,uuid,uuid,uuid)` | New restricted helper | Verifies target task, route, assignment, custody markers, other route activity and route feasibility; writes a transaction-scoped protected release permit only after eligibility. Direct execution is revoked from application and worker roles. |
| `routing_private.lock_route_for_recovery(uuid)` | New restricted helper | Locks route/NGO advisory scope, source rows, vehicle, route, ordered tasks and binding in the route execution lock order; requires READ COMMITTED. Direct execution is revoked from application and worker roles. |
| `public.defer_my_pickup_for_reconciliation(uuid,uuid)` | Directly modified | Refuses deferral of the target dispatched task; preserves stop-scoped request idempotency and authorization. |
| `public.get_my_authorized_route(uuid)` | Directly modified | Protects route display/dispatch eligibility when a deferred stop exists; authorization still relies on the server-side route checks. |
| `public.report_my_route_interruption(uuid,text,uuid)` | Directly modified | Rejects creation of new route-wide interruption reports while retaining access to existing legacy cases and their resolver path. Existing evidence is not deleted or converted. |
| `public.submit_claim_reconciliation(uuid,boolean,uuid)` | Verified unchanged | Signature, SECURITY DEFINER status, owner and grants remain as deployed. Individual claim evidence and receipt/idempotency contract remain the normal workflow. `service_role` EXECUTE exists today; this migration does not change it. |
| `public.start_pickup(uuid)`, `public.complete_pickup(uuid,boolean)` | Verified unchanged | Existing route/task custody guards remain. The new recovery lock serializes expiry against pickup start/completion. |
| `public.close_my_collected_route(...)`, `public.close_my_resolved_route(...)`, route authorization/planning, claim/lease functions, listing/donation transition functions, hub batch functions | Verified unchanged by migration | No source replacement, grant change, or direct DDL. Their existing constraints and transition guards remain in force. `check_remaining` is used to validate route feasibility after a release. |
| `routing_private.items`, `deferred_stops`, `deferred_release_permits`, `resolution_private.cases` and evidence | Data touched only by future recovery calls | No migration-time data rewrite/backfill/deletion. A recovery invocation can detach an eligible expired stop and record deferred-stop/release-permit/audit state. Legacy route cases continue to hold their route until the existing authorized resolution path completes. |
| Existing triggers, constraints, RLS policies and grants | Verified unchanged | Relevant task authority, donation/listing lifecycle, fleet vehicle, evidence immutability and deferred-stop guards were enabled. RLS is enabled on the reviewed operational relations; direct client operations remain subject to the current policy/RPC boundary. Migration changes no RLS, table grants, trigger, constraint or function ACL. |
| `get_eligible_hubs` and hub discovery | Verified unchanged / outside migration | Not referenced or patched. Historical body/ACL drift was not approved by this migration and should continue to be tracked separately. Hub atomicity remains covered by local tests. |
| `geolock-expired-claim-recovery` scheduler | Indirectly affected after deployment | DEV has an enabled cron job running every minute with batch size 1. After deployment, the next scheduled invocation can use the new recovery behavior without a manual RPC call. Do not deploy until current backup/recovery prerequisites are met. |

All deployed function identities and definitions were inspected by exact signature. Fresh read-only transaction identity: project URL `https://rcgyuwiidqvrgbxswhqj.supabase.co`, database `postgres`, PostgreSQL `17.11`, role `postgres`, `transaction_read_only=on`. The normalized DEV MD5 values for the four patched sources were `recover_expired_claims` `89e01f42d5ec23bfcbcdc47c1f4fd4e5`, `defer_my_pickup_for_reconciliation` `1433b2a3e76d68b188fcaa4d6a2e5085`, `get_my_authorized_route` `d2e9e87bda5611f0a4afe2013a8f9235`, and `report_my_route_interruption` `52819df2234b131a52633ad63d2f51a4`. The other exact signatures, owners, SECURITY DEFINER flags and grants were checked; the migration does not alter those ACLs.

## C. Current DEV data impact snapshot

Counts below are read-only observations from DEV on the assessment date, not predictions of later state:

| Record group | Current state counts |
|---|---|
| Claims / leases | 24 RELEASED, 3 COMPLETED, 3 RECONCILIATION_REQUIRED in each table; no ACTIVE+expired candidates |
| Pickup tasks | 24 STALE, 3 COLLECTED, 2 PLANNED, 1 DISPATCHED |
| Donations | 6 AVAILABLE, 3 COLLECTED, 3 SUBMITTED, 2 CLAIMED, 1 PICKUP_IN_PROGRESS, 3 CANCELLED |
| Listings | 6 AVAILABLE, 3 CLOSED, 3 CLAIMED, 1 CANCELLED |
| Routes / assignments | 1 COMPLETED, 1 IN_PROGRESS; 3 active route assignments; one open legacy route case |
| Deferred stops | 0 |
| Claim reconciliation cases | 2 OPEN, 1 MANUAL_REVIEW |
| Hub batch members | 0 active members |

The three already `RECONCILIATION_REQUIRED` claims are not active-expired candidates and will not be automatically released by this recovery function. Their tasks consist of one DISPATCHED and two PLANNED; the route has a legacy route-level case. The migration preserves that whole-route legacy hold and does not convert legacy evidence to claim evidence. Test 10's records/evidence were only inspected; no change or resolution was performed. Because active-expired candidates are currently zero, the scheduler has no currently eligible claim to process at the snapshot time. Future candidate state can change before deployment; repeat the preflight immediately before applying the migration.

An expired listing can be transitioned by the recovery workflow only alongside the safe claim release and existing listing/donation transition guards. The migration does not directly make closed listings claimable. Hub batch member consistency remains protected atomically.

## D. Flutter compatibility

No Flutter source was changed for this assessment.

- Individual donor/NGO claim statements use `submit_claim_reconciliation` in `frontend/geolock_hub_app/lib/routing/route_resolution_repository.dart` and donor claim actions in `frontend/geolock_hub_app/lib/donation_pages.dart`. Existing request IDs, receipt checks and actor scoping are retained.
- `frontend/geolock_hub_app/lib/routing/ngo_routes_page.dart` renders per-stop reconciliation and expiry-recovery states. `STALE` displays as “No Longer Active” in `frontend/geolock_hub_app/lib/status_timeline.dart`; RELEASED displays as “Released” in `frontend/geolock_hub_app/lib/claim_card.dart` and the timeline.
- Normal UI has no caller for `report_my_route_interruption`; the legacy route-case entry remains available at `donation_pages.dart` (“Open legacy route case”). The repository still retains `report()` and saved-operation receipt compatibility in `route_resolution_repository.dart` (around lines 392 and 515). If an old client with no existing case calls `report()`, the new backend intentionally raises `NEW_ROUTE_INTERRUPTION_REPORTS_RETIRED`; `_write` persists the local request before the RPC and leaves it pending after an error. This is a compatibility risk for stale clients or saved operations, although no normal current screen exposes the action. Preflight should confirm the deployed clients have no pending route-report requests or provide an explicit client message/recovery path in a separately approved change.
- Route-stop cards use backend `task_status` and deferred/reconciliation flags. A released stop can remain in route history, which is desirable for audit. The card's ordinary status-label fallback does not explicitly label every STALE/released combination; verify actual route payload presentation in postflight and treat the canonical claim/timeline status as authoritative.

RPC signatures and response payload contracts consumed by the current normal claim flow remain unchanged. Backend guards remain authoritative; a displayed stale/available state does not grant pickup or release permission.

## E. Validation and risks

Focused static validation: **5 passed, 0 failed** (`claim_scoped_reconciliation_static_test.py`).

Flutter legacy-retirement regression: **42 passed, 0 failed** in `frontend/geolock_hub_app/test/route_resolution_test.dart`, including the new `NEW_ROUTE_INTERRUPTION_REPORTS_RETIRED` case. It confirms the current repository fails closed, retains the request after the definitive P0001, and does not send a second report RPC while that request remains pending. This records current fail-closed behavior; it does not add automatic request deletion or claim that the pending-request UX is repaired.

Disposable PostgreSQL 17.11 regression suite: **105 passed, 0 failed, 0 errors** in 480.456 seconds. The run used a local disposable instance with local auth/Storage/cron adapters and explicitly recorded `dev_connections=0`; it is not full hosted Supabase parity. Its local PostGIS/pgRouting versions (3.6.2/4.0.1) differ from the documented DEV versions (3.3.7/3.4.1), so spatial extension compatibility still needs separate environment-matched verification. It exercised CRLF source fixtures, exact source drift/count guards, tests 90–109 (including the five three-donation expiry scenarios), concurrency, route return/closure, hub atomicity, legacy compatibility, and reconciliation custody protections. Evidence: `results/automatic-routing-local/20261101T120733Z-66d0aa/resolution-test-result.json`.

The first sandboxed attempt failed before running any tests because Windows `pg_ctl` could not create a restricted token (error 87). The approved disposable suite then completed successfully outside that restricted process sandbox. No hosted database writes occurred.

Backup readiness remains a blocker. Follow-up inspection identified the latest completed export as `backups/stage-a003/pre-route-resolution/20261029T124943Z-b031c5/dev-pre-route-resolution.dump`, captured 2026-10-29 for DEV `rcgyuwiidqvrgbxswhqj`. The archive is 39,607,337 bytes; its recorded and recomputed SHA-256 both equal `79393fc25bb89e90c7f3b8b1a3806c763f41aa0321b81ac58633324a1784fbc7`. All nine files in its `sha256.json` manifest recomputed successfully. `pg_restore --list` returned 2,387 TOC lines and full payload decode to NUL exited 0. The backup status is `VERIFIED LOGICAL EXPORT / RESTORABILITY NOT VERIFIED`; its capture is explicitly `PRE_ROUTE_RESOLUTION_CURRENT_DEV`, with source observation and archive on Oct 29, and it is not a current pre-20261109 recovery point.

Three newer Nov 1 backup directories (`20261101T092626Z-958d13`, `20261101T093857Z-421937`, `20261101T094446Z-ecdbde`) were inspected read-only. All stopped at `inventory`; each status says `INCOMPLETE` or `FAILED / NOT A VERIFIED BACKUP`. They contain no archive. No latest-current DEV archive is therefore available.

An isolated full restore was not attempted because no compatible isolated Supabase/PostgreSQL target is available: Docker and the Supabase CLI are absent; the local PostgreSQL extension directory lacks `pg_cron` and `supabase_vault`, both present in the archive and DEV; and the test runtime has PostGIS 3.6.2 / pgRouting 4.0.1 versus DEV's 3.3.7 / 3.4.1. The archive includes managed `auth` and `storage` schemas/owners and no Storage object bytes, auth signing/service secrets, extension binaries or role passwords. Restoring into the available plain local PG instance would fail or require masking these missing platform dependencies, so it would not verify a full restore. Only archive checks and payload decoding were run; those are not a restore PASS. A current full backup and provider-compatible isolated restore remain required.

The local PostGIS/pgRouting version difference does **not** materially affect the migration-specific release/reconciliation tests: the migration does not create or call spatial extension functions. Its route-feasibility dependency is `routing_private.check_remaining`, which uses `routing_private.arc` to read the precomputed JSON routing matrix and performs lifecycle/lease/vehicle checks; neither routine invokes PostGIS or pgRouting. The regression fixtures use these stored matrices. The version difference does mean this suite does not validate graph generation or broad spatial-query behavior, which is outside this migration's changed path.

Risk summary:

- **High:** no fresh, restore-verified recovery point; current snapshot will become stale and scheduler runs every minute.
- **Medium:** the sole current tester's device had no pending legacy route request at inspection, but the installed APK appears older than current route UI source and contains the retired report UI text; update that device to an identified current build before migration.
- **Medium:** remaining legacy route case intentionally keeps its route held; migration will not release/resolve it. Keep the legacy UI/resolver authorization intact.
- **Low:** status/history presentation may show a stale route stop alongside a released claim; validate postflight payload/UI while preserving history.
- **No identified migration safety mismatch:** all 11 DEV anchors matched exactly once after CRLF normalization; unexpected exceptions are no longer swallowed as ordinary route infeasibility; source/authorization/custody guards remain.

## F. Recommendation and deployment gates

**NO-GO at present.** The corrected SQL and local behavior are validated, and the pending-request check passed on the sole tester device. That device still runs an APK whose bundle contains legacy report UI text, and there is no current restore-verified DEV recovery point. Update and verify the sole device build and complete backup/restore readiness before deployment. This is not approval to deploy.


## G. Old Flutter client request compatibility

The user reports that GeoLock Hub is tested only by them on their own development device/emulator and that no APK was distributed to teammates or external testers. Repository-wide search confirms no current Flutter UI caller of `RouteResolutionRepository.report()` and no current `.report(...)` invocation. The retained method is at `frontend/geolock_hub_app/lib/routing/route_resolution_repository.dart:392-405`; it still calls `report_my_route_interruption` if explicitly invoked. `_write()` at lines 470-503 saves a request in `SharedPreferences` under `route_resolution_<owner>_<route>` before the RPC. A thrown RPC error leaves that key in place. `reconcile()` at lines 543-560 checks `get_my_route_resolution_receipt`; `NOT_FOUND` returns null and deliberately does not clear the key because absence is not proof the write did not commit. The reconciliation page marks any such key uncertain and blocks further actions (`route_resolution_page.dart` around lines 160-180 and 320-335). `resolutionError()` has no special handling for `NEW_ROUTE_INTERRUPTION_REPORTS_RETIRED`, so it surfaces a generic `P0001` request failure.

Read-only ADB inspection found one connected physical Android device (`M2010J19SG`; no emulator was connected at the time). Package `com.example.geolock_hub_app` is installed as a debuggable app with versionName `1.0.0` and versionCode `1`, matching the current `pubspec.yaml` version string. The installed `base.apk` SHA-256 matched the existing local `app-debug.apk`: `4865291b360e98af618a7b82a6c0a69e1f2ff734ba181f5b8dd54f4e6c2260d6`. However, that artifact timestamp predates the current route UI source timestamps, and an in-memory scan of its Flutter bundle found the legacy `Report cannot continue` string. Treat the installed APK as stale relative to the current source despite the matching version number.

The active Android user's `FlutterSharedPreferences.xml` was read through `run-as` and parsed in memory; only counts were emitted. At inspection time it contained **0 pending route-resolution entries, 0 pending `report_my_route_interruption` entries, and 0 unparsed pending entries**. No preference values or route/user identifiers were printed; no app data was modified. ADB briefly disconnected during inspection and reconnected; the final read completed successfully. This proves no saved legacy request in the inspected active profile at that moment, not that the app never used the workflow or that other profiles/devices have no state.

The added test `retired route interruption error is fail-closed and retains the request` confirms current repository behavior for P0001: the request remains saved, `NOT_FOUND` does not clear it, and a second explicit call is blocked before another report RPC. This is safe against duplicate/false route-case creation, but leaves the compatibility UX unresolved. The current user's device APK still appears to contain legacy UI and must be updated before it is used against DEV after deployment. The user's statement that no other APK was distributed removes the teammate/external-device rollout scope, but only that statement and the connected device were assessed; it is not an independently observed app-distribution inventory.

The migration's rejection is consistent with the approved removal of new route-wide interruption reports; reopening case creation or fabricating a successful route case would violate that behavior. The old-client compatibility blocker is **limited to previously built clients and saved local state**, not a normal code path in the current source. For this single-tester environment, close it by building an APK from the reviewed current source with an identifiable artifact hash, updating the sole device without clearing app data, verifying the installed APK hash matches, and repeating the read-only pending-key count. Do not auto-delete any pending request. If the app is later distributed, repeat this inventory for every recipient before migration; the current repository cannot establish that future distribution scope.

Single-tester closure checklist:

1. Build from the reviewed current source and assign a unique build name/number or record the source commit and APK SHA-256; `1.0.0+1` alone is not a sufficient build identity.
2. Before updating, retain the current read-only result of zero pending legacy report keys. Do not clear app storage or uninstall the package.
3. Install the current APK as an in-place package update so app data remains intact. This device update has not been performed by this assessment.
4. Verify the installed `base.apk` hash equals the reviewed APK hash; confirm the current app opens and its normal screens use only individual claim reconciliation.
5. Re-read only the route-resolution preference-key count. If a pending request appears, preserve it and stop; do not retry or remove it automatically.
6. Record the tester/device/build check. If additional testers receive builds later, repeat the inventory for each before migration.

Before a later approval, require: (1) a fresh full DEV backup using the approved export procedure; (2) checksum, archive coverage and identity validation; (3) a successful isolated restore and schema/data/function/role/ACL/RLS/trigger/constraint/sequence/extension comparisons, with managed Supabase limitations documented; (4) immediate read-only DEV recheck of project/database identity, all 11 anchor counts, migration dependencies, active expired candidates, route/vehicle holds, Test 10 and scheduler; (5) update the sole tester device to a source-identified current APK, verify its hash and repeat the read-only pending request check; and (6) schedule a controlled deployment window. Deployment and postflight SQL are not executed or authorized by this report.
