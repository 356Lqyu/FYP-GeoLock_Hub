# Stage A 003 — verified backup and final deployment approval checklist

**Superseded by installed-state assessment:** 003 is **DEPLOYED / POSTFLIGHT PASS** within [POSTDEPLOYMENT_ASSESSMENT.md](POSTDEPLOYMENT_ASSESSMENT.md)'s scope. This historical deployment checklist/command is retained as evidence, not a request to replay 003. Routing remains uninitialized; see [ROUTING_INITIALIZATION_PROCEDURE.md](ROUTING_INITIALIZATION_PROCEDURE.md).

**Latest final-control refresh:** [EXECUTION_APPROVAL.md](EXECUTION_APPROVAL.md) records the fresh 20:48 MYT preflight, unchanged profiles/hashes/backup, your nomination of yourself as operator, event-bounded maintenance requirements and the exact one-shot commands. Risk acknowledgement is not execution approval; no maintenance start time or writer pause is assumed.

26 October 2026, Asia/Kuala_Lumpur. **GO for final approval review of the exact single-file operation. HOLD / NO-GO to execute until the checklist below is explicitly resolved and the final command approved.** No deployment, restore, routing initialization, lease recovery or worker activation was executed. No new migration TEST environment was created. Backup contents and source data were inspected locally; one explicit READ ONLY MCP query compared current source aggregates/catalogs.

## Backup verdict and actual results

Successful capture directory:

`C:\Users\User\Downloads\FYP-GeoLock_Hub\backups\stage-a003\20261026T123006Z-fb09b6`

Capture receipt records DEV `rcgyuwiidqvrgbxswhqj`, approved `geolock_dev_owner_export`, read-only source, database and roles export exit codes **0**, capture **20:30:14–20:33:39 MYT**. Its database archive and password-free global role/member export are **complete for the inspected logical-export scope**, with the exclusions and validation limits below. This is not a whole-platform or tested-recovery PASS.

| Artifact/check | Actual result |
|---|---|
| `dev-pre003.dump` | 39,332,771 bytes; custom-format PostgreSQL 17.11 archive |
| Archive SHA-256 | `1d00e5a807078b2d51d2e63cbf89c89ca2626135d95f34e7dfb2af5c30e918a2` |
| `roles-no-passwords.sql` | 7,770 bytes; 21 role definitions, 30 membership grants, dump completion marker; no password literals found |
| Roles SHA-256 | `4e3f1db4c0daa3c20ff1ef166693d25baa055568bb2173eeec145e3f15bb19ef` |
| All six entries in `sha256.json` | Recomputed and matched: archive, roles, source inventory, capture receipt, TOC and schema extraction |
| Local archive decoding | TOC parsing, full payload decode to NUL, and schema-only decode to NUL all returned 0; no DB connection or restore |
| Relation/data-entry coverage | All 88 source-inventoried non-extension relations present with expected schema/data entries; no gaps |
| 001/002 baseline in archived schema | **28/28 PASS**: normalized body MD5, result, security mode, volatility, configuration (including quoted TimeZone), postgres owner and direct EXECUTE grantees |
| Pre-003 lifecycle inputs | All six expected pickup/reconciliation/claim/recovery/audit-helper body hashes match |
| 003 presence in archive | All 14 added signatures absent; `routing_task_authority` absent. Existing three public replacements have pre-003 bodies |
| Private data | All 11 `routing_private` table data sections present and empty |
| Extension configuration data | `vault.secrets`, `extensions.spatial_ref_sys`, `cron.job`, `cron.job_run_details` table-data entries and cron job/run sequence SET entries present; secret row values were not printed |
| Roles and worker memberships | Three worker roles and their expected dedicated-login grants present, including membership options; managed role definitions are evidence, not safe-to-replay portable SQL |
| Extra tablespace requirement | Fresh DEV catalog lists only built-in pg_default/pg_global; no custom tablespace export is indicated by this observation |

Archive source totals: 7 claims, 7 leases, 7 pickup tasks, 58 audit events, 10 donations, 6 listings; zero routes/stops/active assignments/reconciliation cases. Claims/leases: 2 ACTIVE and 5 RELEASED; tasks: 2 CONFIRMED and 5 STALE. Coordination singleton matches 360 minutes / 10 kg / 20000 m.

At **20:40:54 MYT**, fresh DEV READ ONLY MCP comparison (`supabase_read_only_user`, read_only on) returned the same ten source counts, no authority trigger and no application ledger. Therefore this is a valid observed **pre-003 recovery capture**, and selected current aggregates still agree. Equal counts do not prove no intervening updates or exact current row-content equivalence; the dump, role export and source inventory are separate snapshots, with no recorded exported-snapshot ID/LSN. It must not be represented as an exact PITR timestamp or proof that the entire current database is byte-equivalent. Refresh cutover evidence and account for any writes since capture.

Detailed non-secret findings: `results/stage-a003-direct-preparation/successful-backup-inspection.json`, `backup-live-comparison.json` and its exact read-only query. Backup artifacts and original `verification.json` were read, not rewritten. Failed earlier attempts and the old pre-lifecycle archive remain untouched.

## Recovery feasibility and limitations

An isolated **restore-only** test is possible in principle and requires no DEV modification. It is not yet available as a verified/approved compatible target. Passive local inspection found the retained runtime has PostgreSQL 17.11 with PostGIS **3.6.2** and pgRouting **4.0.1**, differing from archived DEV **3.3.7 / 3.4.1**. That runtime cannot establish exact spatial-version parity. Prior sandbox startup limitations also remain untested; no server was started or troubleshooting attempted here.

Other captured extensions: plpgsql 1.0, pg_stat_statements 1.11, uuid-ossp 1.1, pgcrypto 1.3, supabase_vault 0.3.1, pg_cron 1.6.4. A plain PostgreSQL server lacking the platform-compatible Auth/Storage/Vault/cron/managed identities and extension binaries is not a full restoration target.

To validate: separately approve/provide a fresh owned isolated restore-only instance, matching necessary versions/platform prerequisites; verify its endpoint, ownership, empty target and blocked external job/webhook/network effects; review application versus managed role mappings; restore only there with exit-on-error and an atomic transaction; compare schema, roles/memberships/grants/default ACLs/RLS/triggers/configuration/constraints/sequences and source data counts/digests/invariants. Run **no 003** on that copy. Full procedure remains `BACKUP_AND_RECOVERY.md`, Safe isolated restore validation. No isolated database or restore is created/executed by this task.

**Restorability remains NOT VERIFIED.** The exported role SQL includes Supabase-owned identities and settings; blind replay into a different managed baseline can fail or be inappropriate. Full logical dumps preserve source evidence but are not automatically portable Supabase restore packages. Do not suppress ownership/grants/errors to turn an incomplete test into PASS.

Not covered as recoverable external dependencies: role/database passwords and dedicated worker login secrets; database server/extension binary files; provider infrastructure/network configuration; decrypted Vault key material; Storage object bytes; Auth signing keys/service configuration; Edge Function code/secrets; external worker journals, certificates, service secrets/configuration and external schedules. Database-stored auth/storage/cron/vault metadata is not equivalent to recovery of those services. Retain secure separate recovery procedures/exports. No actual provider recovery/PITR entitlement or successful restore record was verified.

You can choose a direct-DEV approval without a compatibility TEST environment, but must either supply scoped restore evidence or **explicitly accept the unverified-restoration/data-loss/provider-recovery risk** and name the fallback operator/method. C.5 runtime risk acceptance does not automatically cover this distinct recovery risk. A future destructive DEV restore needs its own exact approval.

## Final checklist — resolve explicitly before execution

- [x] Approved read-only export connection passed, database/global role export exit 0, new archive/role hashes match, defined local coverage/readability checks passed.
- [x] Exact unchanged 003 file pinned; archive contains expected 001/002 and pre-003 inputs, not a partial 003 install in the checked inventory.
- [ ] Confirm private/encrypted storage and access to this exact capture, plus recovery operator, method, external dependencies and intended recovery/data-loss point.
- [ ] Supply successful scoped restore validation **or explicitly accept that restoration is NOT VERIFIED** and the fallback limitations. No automatic restore/fix is authorized.
- [ ] Explicitly accept **P11 application migration history UNKNOWN** and the state-based guarded upgrade/release record. Auth/realtime/storage component ledgers are not GeoLock migration proof; do not invent ledger entries.
- [ ] Confirm accepted **C.5 runtime compatibility NOT VALIDATED** for this direct DEV execution. No new migration TEST environment is imposed. Document postflight and containment/pilot scope.
- [ ] Approve a writer/DDL maintenance window and name who stops/drains claim/pickup/planning/reconciliation/recovery writers and concurrent deploy/role/function changes. Keep source security controls intact; do not kill blockers to force progress.
- [ ] Refresh full read-only preflight immediately at cutover: exact source/metadata/privileges, 003 absence, P07/legacy/active lifecycle counts, config/extensions and current recovery gap. Any drift/partial state/lock conflict stops; no automatic repair or 001/002 replay.
- [ ] Approve **installer use** of the prepared password-free `pg_installer_service.conf` for this exact DEV migration. Backup-only approval of the export profile is not installation authorization.
- [ ] Explicitly approve the exact hash/file and one-shot deployment command below. Keep workers/new pickup starts paused through postflight and routing readiness decisions.

## Exact migration and commands — prepared, NOT executed

File: `C:\Users\User\Downloads\FYP-GeoLock_Hub\docs\stage8\stage-a\forward-migrations\20261103_routing_pickup_and_reconciliation.sql`

SHA-256: **`6541f0a002ea56ad77c023e33ad1500ab2273cc821f87fa43d38e633bd6724ea`**.

The separate prepared installer service targets exactly the supplied DEV session pooler/port/owner and verify-full CA, contains no password, and sets **only its own connection** default_transaction_read_only=off. The existing approved export service stays read-only. This is necessary for an approved migration session, not a persistent source setting/grant/RLS change. The profile exists locally for review but has not been used to connect. Preserve READ COMMITTED and postgres/postgres; the migration's own guards enforce them.

After the checklist and separate final approval, from the repository root in your own PowerShell terminal:

```powershell
Set-Location -LiteralPath 'C:\Users\User\Downloads\FYP-GeoLock_Hub'
$stage003Psql = 'C:\Program Files\PostgreSQL\17\bin\psql.exe'
$stage003File = (Resolve-Path -LiteralPath 'docs\stage8\stage-a\forward-migrations\20261103_routing_pickup_and_reconciliation.sql').Path
$stage003Expected = '6541f0a002ea56ad77c023e33ad1500ab2273cc821f87fa43d38e633bd6724ea'
if ((Get-FileHash -LiteralPath $stage003File -Algorithm SHA256).Hash.ToLowerInvariant() -ne $stage003Expected) { throw '003 artifact drift: STOP' }
$env:PGSERVICEFILE = (Resolve-Path -LiteralPath 'backups\stage-a003\pg_installer_service.conf').Path
& $stage003Psql -X --password --dbname 'service=geolock_dev_installer' --set ON_ERROR_STOP=1 --command "SELECT current_database(),current_user,session_user,current_setting('transaction_isolation'),current_setting('transaction_read_only');"
if ($LASTEXITCODE -ne 0) { throw 'Installer identity check failed: STOP' }
# Review postgres DB / postgres user and session / read committed / read_only off.
# Stop unless target, fresh preflight, backup/recovery and final approval all match.
$stage003Stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$stage003ExecutionLog = Join-Path (Get-Location) ('results\stage-a003-execution-' + $stage003Stamp + '.txt')
& $stage003Psql -X --password --dbname 'service=geolock_dev_installer' --set ON_ERROR_STOP=1 --file $stage003File --output $stage003ExecutionLog
if ($LASTEXITCODE -ne 0) { throw '003 failed or commit outcome ambiguous: STOP; no retry' }
```

Passwords go only to native hidden prompts. Do not use --single-transaction: 003 owns BEGIN/COMMIT, 5s lock timeout, 90s per-statement timeout, task writer-drain lock, capture-before-trigger order and embedded guards. Do not change guards/timeouts, run bulk migration discovery, replay 001/002, apply B.2/B.4.3 first or restore unprotected pickup functions to make it succeed.

Immediately afterward, while maintenance remains in force, reset to the read-only export profile for local catalog postflight (or have Codex use the approved read-only MCP):

```powershell
$env:PGSERVICEFILE = (Resolve-Path -LiteralPath 'backups\stage-a003\pg_service.conf').Path
$stage003Postflight = (Resolve-Path -LiteralPath 'docs\stage8\stage-a\deployment-preparation\postflight.sql').Path
$stage003PostflightLog = Join-Path (Get-Location) ('results\stage-a003-postflight-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '.txt')
& $stage003Psql -X --password --dbname 'service=geolock_dev_owner_export' --set ON_ERROR_STOP=1 --file $stage003Postflight --output $stage003PostflightLog
if ($LASTEXITCODE -ne 0) { throw 'Postflight incomplete: keep maintenance; STOP' }
```

Review **all returned rows**, not just zero process exit code: 17 exact new/replaced function checks and 28 preserved baseline checks PASS; one enabled BEFORE UPDATE OF task_status ROW trigger with correct function; intended direct/inherited permissions/RLS unchanged except approved delta; private/source definitions and counts preserved; legacy capture exactly matches fresh cutover. The current zero-dispatch lane should retain empty legacy capture. Business/Auth/route tests remain separate; postflight is not end-to-end proof.

## Failure handling and next feature steps

Pre-commit failure: a failed one-shot psql disconnect rolls back its open transaction; an interactive aborted transaction requires ROLLBACK in that same session. Lost COMMIT response: inspect fresh read-only state before any rerun. Confirmed commit with failed postflight: keep maintenance/workers paused, preserve diagnostics and separately approve a state-specific forward repair or provider recovery. Do not automatically drop authority, delete data, replay the file or restore DEV from any archive.

After successful 003/postflight, the routing enablement gates remain: separately reviewed exact-pair expired-lease recovery if reusing those donations, legitimate new claims with live leases, approved explicit policy and operational graph freeze, verified independent worker credentials/TLS/journal and activation, real matrix/candidate/independent validation, NGO database publication authorization, then Flutter route/pickup/depot-return/cancel/reconciliation/negative/rollback/regression pilot under approved records. All routing_private data was empty in this backup; 003 does not create a policy/graph or activate workers. Existing 49 Flutter tests are local mocked evidence only. `ACTION_SEQUENCE.md` and `POST_DEPLOYMENT_TESTS.md` remain the scoped procedures.

**Current stop:** backup scope/integrity verification is PASS with explicit limits. Restore validation is NOT VERIFIED. Exact deployment and postflight commands are ready for review; execute only after final checklist acceptance and explicit approval. Nothing has been deployed or restored.
