# Stage A 003 — exact execution approval packet

**Historical approval packet — 003 is now DEPLOYED / POSTFLIGHT PASS in the scope documented by [POSTDEPLOYMENT_ASSESSMENT.md](POSTDEPLOYMENT_ASSESSMENT.md). Do not rerun the migration commands below.** The user reported execution; the retained database postconditions independently match. No retrospective approval or migration-history row is fabricated. Next exact-operation approvals are separate routing initialization/activation decisions.

26 October 2026 (Asia/Kuala_Lumpur). **Recommendation: conditional GO for this controlled DEV installation based on refreshed technical evidence. Execution remains HOLD / NO-GO until you explicitly accept the remaining risks, declare maintenance active and approve the exact operation below.** No installer connection, migration, restore, lease recovery, routing initialization or worker activation was performed. Your current statement is willingness to consider risks, not execution approval.

## Verified controls

* Installer profile: `C:\Users\User\Downloads\FYP-GeoLock_Hub\backups\stage-a003\pg_installer_service.conf`. Session-pooler host `aws-0-ap-northeast-2.pooler.supabase.com`, port 5432, database postgres, owner username `postgres.rcgyuwiidqvrgbxswhqj`, TLS verify-full using supplied `prod-ca-2021.crt`. These match the endpoint/account used by the successful approved export. No password is in the profile. Its only intentional export-profile difference is connection-local default_transaction_read_only=off. Source RLS/grants/security are not altered by preparing this profile. Actual installer postgres/postgres, READ COMMITTED, read_only off must still be checked at the final password-prompted connection; that connection was not made here.
* Exact migration: `C:\Users\User\Downloads\FYP-GeoLock_Hub\docs\stage8\stage-a\forward-migrations\20261103_routing_pickup_and_reconciliation.sql`.
* Recomputed SHA-256: **`6541f0a002ea56ad77c023e33ad1500ab2273cc821f87fa43d38e633bd6724ea`**. Unchanged. No replay of 001/002, guard edits or B.2/B.4.3 application.
* Backup: `C:\Users\User\Downloads\FYP-GeoLock_Hub\backups\stage-a003\20261026T123006Z-fb09b6`. All six recorded artifact checksums freshly match. Database archive remains 39,332,771 bytes, SHA-256 `1d00e5a807078b2d51d2e63cbf89c89ca2626135d95f34e7dfb2af5c30e918a2`; role/member export remains available and unchanged. No backup artifact was overwritten.

## Fresh read-only cutover evidence

Main refresh at **20:48:42 MYT**, 26 October, using `supabase_read_only_user`, explicit READ ONLY, READ COMMITTED. Grouped queries/results are `results/stage-a003-direct-preparation/final-approval-preflight.sql/.json` and `final-approval-security.sql/.json`. Security and scheduler checks ran immediately after the main refresh. No business RPC or lock-taking migration was invoked.

| Check | Actual result |
|---|---|
| Required 001/002 functions | **28/28 PASS**, including exact body, signature resolution, result/security/volatility/config/owner/direct grants |
| Lifecycle/helper inputs | **5/5 lifecycle + audit-helper PASS**; post-002 assignment included above |
| 003 absence | All 14 additions absent; authority trigger absent; existing pickup/reconciliation bodies pre-003 |
| P07 | **All ten counters zero**: no DISPATCHED tasks, legacy capture/overlap/unmatched dispatch, active managed route state, in-progress routes or unresolved reconciliation cases |
| Structure | 11 private tables, 75 columns, 21 valid/live indexes, 35 validated constraints; full nested catalog and trigger definitions captured |
| Security | 74/74 inspected table/column write predicates false; all 12 scoped permit-table DML predicates false; six-role private audit-helper EXECUTE denied; worker role attributes remain restricted; effective EXECUTE/membership evidence captured |
| Application triggers | All 16 in selected public/private scope enabled; C.1 route guard retained; 003 guard not installed |
| Recovery scheduler | `geolock-expired-claim-recovery` exists and **active=false**; leave disabled |
| Configuration/runtime | Single coordination policy matches 360/10/20000; PostgreSQL 17.11, PostGIS 3.3.7, pgRouting 3.4.1; overload/fleet metadata captured |
| Existing expired claims | Two ACTIVE leases are expired; task/claim/lease totals and all ten saved public source counts still match backup observations. No recovery performed; these claims remain ineligible for routing |
| P11 | Application ledger absent; historical execution remains **UNKNOWN**, not cleared by present-state parity |

These checks are a point-in-time preflight, **not evidence that maintenance is already active**. No-writer/DDL control must be confirmed by the operator. Refresh these checks if activity intervenes or the actual cutover is deferred; object existence or matching counts alone cannot prove exact row equivalence.

## Maintenance window and recovery operator

**Operator: you**, as explicitly nominated. You own deployment monitoring, the backup location/password-prompt access, Dashboard/provider recovery access, and coordination of any external-service recovery. Confirm you can actually invoke the chosen provider restore/support route; no PITR entitlement or working restore facility is assumed. Codex can inspect read-only evidence and assist with a separately approved repair; that is not an independent recovery operator.

No clock start time was supplied, so none is invented. The exact event-bounded window is:

1. **M0 — start:** after final approval, you explicitly declare claim/pickup/planning/reconciliation writers and concurrent deploy/role/function changes paused and drained. Keep the recovery job disabled and workers/new routing authorization inactive. No automatic job/session termination or RLS/security disablement is authorized.
2. **M1:** immediately refresh final preflight, verify backup hashes/access and record any writes/data-loss gap since the 20:30–20:33 MYT capture. If the gap is unacceptable, capture a new approved recovery point rather than assuming equality.
3. **M2:** run the exact one-shot 003 only if identity/hash/source/absence/security/cutover checks match. Migration retains 5s lock timeout and 90s **per-statement**, not total, timeout. Abort on lock contention; do not terminate blockers or extend/bypass guards.
4. **M3 — successful end:** confirmed COMMIT plus reviewed postflight with every expected check passing, preserved source/capture state and documented deviations. Normal pickup/routing remains gated by subsequent initialization/activation approvals.
5. **Failure end:** do not automatically reopen writers. End only after read-only confirmation of rollback/actual state and the operator's containment decision, or after a separately approved repair/recovery with accepted postconditions.

There is no measured guaranteed duration. The SQL timeouts do not prove a fixed-length maintenance window. Before execution, you must confirm the window is active; naming yourself does not assert writers have been stopped.

## Exact command proposed for approval — NOT executed

After you explicitly approve this exact DEV/hash/operation and the controls above, run from your own PowerShell terminal. Passwords are entered only at native hidden prompts; no stored/exposed credential is used.

```powershell
Set-Location -LiteralPath 'C:\Users\User\Downloads\FYP-GeoLock_Hub'
$stage003Psql = 'C:\Program Files\PostgreSQL\17\bin\psql.exe'
$stage003File = (Resolve-Path -LiteralPath 'docs\stage8\stage-a\forward-migrations\20261103_routing_pickup_and_reconciliation.sql').Path
$stage003Expected = '6541f0a002ea56ad77c023e33ad1500ab2273cc821f87fa43d38e633bd6724ea'
if ((Get-FileHash -LiteralPath $stage003File -Algorithm SHA256).Hash.ToLowerInvariant() -ne $stage003Expected) { throw '003 hash drift: STOP' }
$env:PGSERVICEFILE = (Resolve-Path -LiteralPath 'backups\stage-a003\pg_installer_service.conf').Path
& $stage003Psql -X --password --dbname 'service=geolock_dev_installer' --set ON_ERROR_STOP=1 --command "SELECT current_database(),current_user,session_user,current_setting('transaction_isolation'),current_setting('transaction_read_only');"
if ($LASTEXITCODE -ne 0) { throw 'Installer identity check failed: STOP' }
# Manually verify postgres database / postgres user+session / read committed / off.
# Stop unless maintenance, fresh preflight and exact execution approval are recorded.
$stage003ExecutionLog = Join-Path (Get-Location) ('results\stage-a003-execution-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '.txt')
& $stage003Psql -X --password --dbname 'service=geolock_dev_installer' --set ON_ERROR_STOP=1 --file $stage003File --output $stage003ExecutionLog
if ($LASTEXITCODE -ne 0) { throw '003 failed or commit outcome ambiguous: STOP; do not retry' }
```

003 owns its BEGIN/COMMIT. Do not add --single-transaction, run migration discovery or apply another migration. Its source guards and task-writer drain/capture-before-trigger ordering remain unchanged. Keep console error evidence without recording passwords.

## Immediate postflight — still inside maintenance

Use the original READ ONLY export profile, or have Codex use approved read-only MCP after the separately approved deployment:

```powershell
$env:PGSERVICEFILE = (Resolve-Path -LiteralPath 'backups\stage-a003\pg_service.conf').Path
$stage003Postflight = (Resolve-Path -LiteralPath 'docs\stage8\stage-a\deployment-preparation\postflight.sql').Path
$stage003PostflightLog = Join-Path (Get-Location) ('results\stage-a003-postflight-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '.txt')
& $stage003Psql -X --password --dbname 'service=geolock_dev_owner_export' --set ON_ERROR_STOP=1 --file $stage003Postflight --output $stage003PostflightLog
if ($LASTEXITCODE -ne 0) { throw 'Postflight incomplete: keep maintenance; STOP' }
```

Zero exit status means the queries ran, not that returned checks passed. Require **17/17 exact 003 function checks + 28/28 preserved baseline checks PASS**; exactly one enabled correct `routing_task_authority` trigger; intended direct/inherited EXECUTE/DML/RLS boundaries; preserved old triggers/private definitions/source counts and exact expected legacy capture. The refreshed zero-dispatch lane expects legacy_inflight to stay empty. New pickup/cancel/close/read RPCs are authenticated-only outside owner; reconciliation retains its approved authenticated/service_role boundary. No UI/worker success is inferred from these catalogs.

## What failure recovery can and cannot do

* **Before COMMIT:** the migration uses transactional function/trigger/ACL changes and capture inserts. A failure with ON_ERROR_STOP closes the one-shot session and rolls back its open transaction. In an interactive aborted session, ROLLBACK must be issued in that same session. This is PostgreSQL's expected behavior; full C.5 failure/rollback/concurrency behavior was not tested.
* **Unknown COMMIT outcome:** connection loss or missing response is ambiguous. Inspect read-only before any rerun. This migration is not idempotent.
* **After COMMIT:** no approved automatic inverse exists. Keep writers/workers paused, preserve evidence and separately review a state-specific forward repair or provider-supported restoration. Do not drop the authority trigger or restore bypass pickup functions as a rollback.
* **Backup scope:** database schema/functions/triggers/RLS/grants/data and password-free role/member metadata are present and readable for the verified scope. A compatible successful restore may recover that capture point, but this has not been demonstrated. Managed identities/extensions may prevent blind replay.
* **Not assured:** exact current row-content equivalence, writes after capture, exact PITR recovery, usable provider restore access, role passwords, physical extension/server/provider files, external Storage object bytes, service/Auth signing configuration, decrypted Vault key material or external worker/service secrets and journals. Full-DEV restoration may discard post-backup activity and needs a new explicit approval naming target, recovery point, data-loss window and service reconciliation plan.

## Explicit acceptance still required

Your review statement acknowledged unresolved risks and willingness to consider them. It did **not** authorize execution or declare final acceptance. The approval must cover:

* Restore validation and exact row equivalence NOT VERIFIED, P11 UNKNOWN, C.5 NOT VALIDATED, managed/external recovery exclusions and the accepted backup-to-cutover gap.
* Yourself as operator with a named fallback method/provider access and maintenance declared active at M0.
* Installer-profile use for the exact DEV project and exact migration hash above, executed once, followed immediately by read-only postflight; no routing initialization, recovery mutation, other migrations or activation.

Suggested approval wording, to send only if it accurately reflects your decisions: “I accept the listed DEV recovery/history/runtime risks and backup gap; I am the deployment/recovery operator and confirm maintenance is active and the fallback method is [name method]. I approve one execution of Stage A 003 on DEV rcgyuwiidqvrgbxswhqj at SHA-256 6541f0a002ea56ad77c023e33ad1500ab2273cc821f87fa43d38e633bd6724ea using the reviewed installer command, followed by read-only postflight. No other migrations, restore, lifecycle recovery, routing initialization or worker activation are approved.”

If maintenance is not yet active, approve a proposed window first and do not claim it is active. **Current action: stop at review. No execution performed.** After successful postflight, prepare policy, graph freeze and worker activation as separate exact approvals, as requested.
