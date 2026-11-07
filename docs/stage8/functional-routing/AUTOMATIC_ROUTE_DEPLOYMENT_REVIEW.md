# Automatic departure deployment review

28 October 2026. LOCAL PREPARATION ONLY. This is a proposed execution/recovery plan,
not approval to access or modify DEV. Stage A 003 remains closed and is not rerun.

## Artifact and installer contract

Apply exactly one forward file:
docs/stage8/stage-a/forward-migrations/20261104_routing_automatic_departure.sql.
The final SHA-256 is in results/automatic-routing-local/verification.json.

The migration begins/commits its own transaction, uses a 5-second lock timeout and
120-second statement timeout, requires postgres session identity and READ COMMITTED,
checks normalized original authorization/owned-reader function fingerprints and
security-definer ownership, and requires the enabled A003 authority trigger.
Replay or unexpected source drift fails closed; do not bypass a guard. It replaces
two protected function bodies and creates one owned read-only receipt function.
It adds no table/column/index, performs no data migration and changes no graph,
worker/table permissions, leases, custody or existing route assignments.

## Prerequisites for separate DEV approval

1. Review the final manifest and all local results; retain the previous verified
   APK and a release snapshot of deployed code. Most relevant source directories
   are currently untracked in Git; do not assume git checkout can restore them.
2. Authorize fresh read-only DEV preflight separately. Confirm project
   rcgyuwiidqvrgbxswhqj, unchanged A003 baseline/security, function guard hashes,
   execution privileges and current policy/graph/candidate records. Identify and
   reconcile in-flight operations before cutover. No such DEV preflight ran here.
3. Create/verify a fresh recovery capture of the actual current DEV state with the
   approved export profile, including frozen graph manifest and saved candidate.
   Do not assume a pre-freeze/pre-003 backup captures these later records or that
   an old backup mode's guards fit the current state. Preserve all earlier backups.
   Restorability still requires evidence or explicit scoped risk acceptance.
4. Resolve/accept the application migration-ledger uncertainty through a truthful
   release record. Do not invent or backfill history automatically.
5. Confirm the approved writable installer service, SSL verify-full/session-pooler
   identity, maintenance window and recovery operator. Keep credentials out of
   commands/logs/Git. The owner export's read-only service is not an installer.
6. Explicitly approve the exact migration/hash. Pause relevant writers through the
   approved maintenance procedure; do not stop/kill sessions or schedulers silently.

## Proposed execution sequence after approval

From the repository root, after the selected native PostgreSQL 17 service has been
verified against the approved DEV target and its password is entered locally:

```powershell
$migration = '.\docs\stage8\stage-a\forward-migrations\20261104_routing_automatic_departure.sql'
Get-FileHash $migration -Algorithm SHA256
$installerService = Read-Host 'Separately approved DEV installer service name'
& 'C:\Program Files\PostgreSQL\17\bin\psql.exe' -X -W --dbname "service=$installerService" --set=ON_ERROR_STOP=1 --file $migration
if ($LASTEXITCODE -ne 0) { throw 'Migration failed. Stop; preserve evidence.' }
```

This file supplies its transaction. Do not add another BEGIN/COMMIT or run db push,
001/002/003, B.2/B.4.3, repairs, grants or test fixtures along with it.

Postflight uses READ ONLY transactions: verify function signatures/source hashes,
owner/security settings, authenticated-only receipt privilege, preserved historical
function/data invariants, A003 triggers and unchanged graph/policy/candidate digests.
Do not call authorization(NULL) as a smoke test, even with intended ROLLBACK.
Confirm the new RPC is visible through PostgREST; any required platform schema-cache
reload must use its approved procedure, not permission/security changes.

Then separately approve loading the reviewed planner code, initially WITHOUT the
combined switch. Existing validator credentials/protocol stay unchanged. Use only
read-only health, saved-result and capability checks with the real NGO session.
The capability check should identify the SQL contract but report combined writes
disabled. A subsequent explicitly approved activation uses the existing launcher:

```powershell
$ref = Read-Host 'Approved combined-workflow activation reference'
.\backend\routing\worker_service\windows\Start-Worker.ps1 -Mode planner -GraphId 'eab1f7ee-a8e0-4bed-a0e1-2c4bff024936' -Activate -ApprovalRef $ref -EnableCombinedWorkflow
```

Native hidden prompts, dedicated graph/planner identities, TLS verify-full and
original password bytes remain unchanged. Do not start a duplicate port-8787
process. No startup/restart/activation command was executed during local testing.

Only after separate approval, build a uniquely named and checksum-verified APK with
GEOLOCK_SUPABASE_ENV=dev and GEOLOCK_ROUTING_API_URL=http://127.0.0.1:8787. Preserve
the existing named working APK and preferences. The new combined UI has not been
demonstrated on the phone. A real business pilot needs explicit approval and fresh
eligible claims/vehicles; do not reuse the historical candidate as an automatic
authorization trigger or silently extend/recover claims.

## Failure, rollback and reconciliation

- Before migration COMMIT: an error/timeout aborts its transaction. Preserve logs,
  inspect state read-only, and stop. Never patch a guard or suppress an error.
- After COMMIT: the preferred operational rollback is to disable combined writes
  by restarting the planner WITHOUT -EnableCombinedWorkflow, only with approval.
  Keep read-only reconciliation and owned-route reads available. Preserve the
  compatible SQL, ledger, routes and immutable artifacts. Revert the UI to the
  preserved release if approved. This is not permission to restart now.
- Do not replay historical migrations as a down migration. If a SQL defect needs
  correction, prepare a separately reviewed forward fix; preserve existing receipts
  and active route semantics. A destructive restore needs distinct exact approval.
- On an uncertain response, first read the owner's original authorization receipt.
  FOUND identifies the existing route(s); load them rather than replan. NOT_FOUND
  can mean a transaction is still in flight. Preserve IDs and wait/recheck or use
  explicit same-operation resume; never mint a replacement UUID.
- A blocked/expired started route is not automatically cancelled or recovered.
  Use the existing protected lifecycle/reconciliation procedures with separate
  approval and truthful handover evidence. Do not delete routes or release holds.
- A backup restore is not a substitute for reconciling a possible committed
  authorization: it could erase valid claims/audits and requires its own approval.

## Remaining limitations

Local auth/Storage/cron adapters and GIS versions are NON-PARITY; no Supabase DEV
JWT/PostgREST/Android end-to-end combined run has occurred. Receipt reconciliation
requires an active owning NGO and available database/platform authentication.
Loss of local app/journal state requires read-only investigation, not guessed IDs
or automatic regeneration. The map remains markers-only. Existing physical Android
evidence verifies the earlier saved-result UI, not this new automatic workflow.

Local test success makes this package eligible for separate DEV deployment review,
not execution. No deployment, service restart, APK installation, recovery or live
business operation is authorized by this document.
