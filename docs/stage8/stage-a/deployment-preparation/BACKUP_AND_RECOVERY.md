# Current pre-003 backup and recovery checkpoint

**Successful capture verified:** `backups/stage-a003/20261026T123006Z-fb09b6` now passes archive/role export, recorded checksums, full decoding, 88-relation/data coverage and archived 001/002/pre-003 contract checks. See [FINAL_DEPLOYMENT_CHECKPOINT.md](FINAL_DEPLOYMENT_CHECKPOINT.md) for actual evidence, remaining restore limitations and the final checklist/commands. Statements below that no new capture exists describe earlier checkpoints. Restoration remains NOT VERIFIED; no deployment or restore is authorized/executed.

**Current operator step:** [BACKUP_OPERATOR_STEPS.md](BACKUP_OPERATOR_STEPS.md) supersedes earlier unavailable-credential placeholders below. The user has approved `geolock_dev_owner_export` and reports a successful read-only identity/TLS/export-permission check. Use `backup_pre003.ps1` locally with hidden prompts; no new archive/roles export, checksum/coverage or restore result is claimed until that run completes. This is backup-only authorization, not migration/initialization approval.

Latest connection setup and execution ownership: [ACTION_SEQUENCE.md](ACTION_SEQUENCE.md). It includes Dashboard Connect/CA instructions, password-prompt commands for a dedicated approved export login, current expiry findings and initialization order. A raw full archive is not automatically portable to a different Supabase baseline: managed internals can fail during restore; preserve complete recovery inventory and review platform-aware restoration separately. No export credential has been identified/approved for use by this session and no new backup is claimed.

Preparation only, 26 October 2026. No new backup, restore, TEST database, local database instance or migration was executed/created. Preserve `geolock_dev_before_lifecycle.backup` unchanged. The user authorizes preparing a new current DEV recovery point; an approved PostgreSQL export connection is still needed to actually capture it. The read-only MCP connection can inspect SQL but cannot stream a complete pg_dump archive or export cluster globals. No libpq service or database credential is available to this session; do not substitute a privileged credential.

## Actual observations and limits

The older archive is 38,922,879 bytes, SHA-256 `a12b3f10467c1dc39c3be39e03b1c26615f897b041d522b9061271a722d0054b`. Its TOC says created **2026-10-22 04:33:05**, PostgreSQL/pg_dump 17.11, custom format 1.16, 2,152 entries. TOC contains auth/storage schemas and public claim data/functions, but no `routing_private` or `fleet_private` entries. It cannot be treated as the current 001/002/C.1 recovery point. Archive-local timestamp has no timezone in its header. No old data or credential payload was printed. Only TOC metadata was inspected; the archive was not altered.

Repository evidence search found no successful full restore record. Earlier C.1 evidence explicitly describes the old backup as not restore-tested. **New current backup: NOT CAPTURED. Current backup contents: NOT VERIFIED. Restore/recovery validation: NOT VERIFIED.** A readable TOC, decompression success or successful pg_dump does not prove restoration.

## Exact capture commands for the operator

Execute only after approving/providing a DEV-only PostgreSQL backup connection. `geolock_dev_backup` is a placeholder libpq service, not an installed connection. Verify its actual host/project-bearing pooler username against DEV `rcgyuwiidqvrgbxswhqj` out of band, TLS with certificate validation, database `postgres`, and approved export permissions. Configure credentials securely outside Git/process command lines; never print the service contents. Prefer a dedicated export role with complete read/catalog coverage. A permission error means an incomplete backup: stop and arrange approved export access; do not silently exclude inaccessible schemas or use another project's/privileged credentials. These commands do not grant access.

Coordinate a maintenance window with all business writers, job schedulers and deployments paused under separate operational approval. A pg_dump snapshot is internally consistent, but a later deployment needs a well-defined no-write interval from the captured recovery point through postflight. Otherwise explicitly account for the gap and possible data loss. Roles are cluster-global and exported separately; no role/DDL changes may occur between captures.

From the repository root in PowerShell:

```powershell
$stage003BackupDir = Join-Path (Get-Location) ('backups\stage-a003\' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))
New-Item -ItemType Directory -Path $stage003BackupDir -ErrorAction Stop | Out-Null
# default_transaction_read_only is connection-local; there are no database writes.
$stage003BackupService = "service=geolock_dev_backup options='-c default_transaction_read_only=on'"
$stage003IdentityPath = Join-Path $stage003BackupDir 'identity.txt'
psql -X --no-password --dbname=$stage003BackupService --set=ON_ERROR_STOP=1 --command="SELECT current_database(),current_user,session_user,current_setting('server_version'),current_setting('transaction_read_only'),clock_timestamp();" --output $stage003IdentityPath
if ($LASTEXITCODE -ne 0) { throw 'Backup identity/access check failed: STOP' }
# Review identity.txt and the verified DEV endpoint before proceeding.
$stage003Archive = Join-Path $stage003BackupDir 'dev-pre003.dump'
pg_dump --no-password --dbname=$stage003BackupService --format=custom --lock-wait-timeout=5s --file=$stage003Archive
if ($LASTEXITCODE -ne 0) { throw 'Incomplete database archive: STOP; do not use for recovery' }
$stage003RolesPath = Join-Path $stage003BackupDir 'roles-no-passwords.sql'
pg_dumpall --no-password --dbname $stage003BackupService --roles-only --no-role-passwords --file $stage003RolesPath
if ($LASTEXITCODE -ne 0) { throw 'Role export incomplete: STOP; document missing recovery scope' }
pg_restore --list $stage003Archive | Set-Content -LiteralPath (Join-Path $stage003BackupDir 'toc.txt')
if ($LASTEXITCODE -ne 0) { throw 'Archive TOC verification failed: STOP' }
# Read and decompress the full archive into the Windows null device; no DB connection.
pg_restore --file=NUL $stage003Archive
if ($LASTEXITCODE -ne 0) { throw 'Archive payload unreadable: STOP' }
Get-ChildItem -LiteralPath $stage003BackupDir -File | Get-FileHash -Algorithm SHA256 | Select-Object Path,Hash | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stage003BackupDir 'sha256.json')
```

Use trusted PostgreSQL 17 tooling (installed `C:\Program Files\PostgreSQL\17\bin`) and a private encrypted location. The nested `.gitignore` prevents accidental tracking under this path, but is not encryption/access control. SQL dumps and archive payloads may include personal data, Auth secrets/tokens and sensitive configuration. Do not display them in chat or place them in ordinary tracked results. Limit file permissions to the approved operator/restore account and verify the actual ACLs; do not alter permissions automatically. Record approval, start/end times, verified ref, tooling versions, exact checksums, write-free interval and recovery owner without credentials.

Capture the roles export even though its SQL must not be replayed indiscriminately into Supabase: it includes managed role definitions/attributes that may be immutable or provider-owned. `--no-role-passwords` intentionally omits passwords; reset/reprovision dedicated login secrets separately. If global catalog access is denied, obtain the provider/operator-approved roles/membership export and classify the missing scope rather than claiming completeness. Do not add `--no-owner`, `--no-acl`, `--schema=public` or data exclusions to make the backup succeed.

## Required coverage verification

Compare the new archive's schema/TOC and a restricted schema-only extraction against the captured read-only catalogs, not the old backup. A successful command is necessary but not sufficient.

| Scope | Required evidence |
|---|---|
| Application schemas | `public`, `routing_private`, `fleet_private`; all tables, sequences, enum/types, indexes, constraints, RLS flags, policies, triggers and dependencies. Also inventory every other non-system schema; do not silently omit application objects outside these three. |
| 001/002 | All 28 exact signatures/bodies/configurations/owners/ACLs from `expected-functions.json`; 11 private tables, 75 columns, 21 indexes, 35 constraints and eight private application triggers. `legacy_inflight` exists even with zero rows. |
| Pre-003 boundary | Old pickup/reconciliation bodies present; all 14 additions and `routing_task_authority` absent. Store this as a pre-003 recovery point, never as an already-deployed 003 backup. |
| Application data | All application table-data entries. On an isolated restored copy compare exact per-table counts, PK sets and content digests, lifecycle/status invariants, coordination_config and audit preservation to a snapshot-consistent source baseline. Empty tables still need table/data coverage. Current metadata counts are observations at a different time, not proof of backup snapshot equivalence. |
| Roles and privileges | Owner identities, role attributes, memberships including inheritance/set/admin options, schema/table/column/function/default ACLs and RLS policies. Global passwords are excluded deliberately and must be reprovisioned securely. |
| Extensions | PostgreSQL 17.11, PostGIS 3.3.7, pgRouting 3.4.1 in `extensions`; inventory *all* other installed extensions/settings. pg_dump records extension declarations, not extension shared libraries/control files or provider runtime. |
| Configuration | Table configuration including coordination policy; inspect database/role settings, function proconfig, timezone/float settings. Record necessary instance settings separately; a database archive is not a server configuration backup. |
| Supabase-managed services | Inventory auth, storage, realtime, Supabase migration/component schemas and any managed vault/cron/net/extensions objects. A logical database dump is not an export of Storage object bytes, Auth service settings/signing keys, OAuth configuration, Edge Function code/secrets, scheduled external services, TLS certificates, connection settings or provider infrastructure. Arrange provider-supported recovery/export for those separately. Stored encryption keys and service secrets need their own secure recovery plan. |

## Safe isolated restore validation — procedure only

This is a **restore-only** validation, not a separate TEST environment for migration compatibility. It is not created or executed in this task. Do not run 003 on the restored copy. Never restore into DEV, shared or production, and never point pg_restore at their hosts. No destructive DEV restore approval is implied.

1. An operator provisions a fresh, owned, isolated instance with PostgreSQL 17.11, the exact required extensions and an approved Supabase-compatible managed-object baseline. Record its ownership marker, empty database, local-only/isolated address, versions and lack of external connectivity. A bare postgres image without the required extensions/platform prerequisites cannot prove full Supabase restore compatibility. Disable external jobs/webhooks/cron/network egress on this isolated instance only, preserving their backed-up definitions as evidence.
2. Name a dedicated empty database `geolock_pre003_restorecheck`. Verify its libpq service (`geolock_owned_restorecheck`) resolves only to that owned isolated instance, not any Supabase endpoint. This service name alone is not isolation proof. Allow only approved restoration roles; review `roles-no-passwords.sql` and recreate compatible **application** identities/memberships as required. Do not blindly replay managed platform roles or role passwords. Do not use `--clean`, `--create`, an existing database or ownership/ACL suppression to hide errors.
3. Restore the full archive, preserving owners/grants. For an operator-verified isolated service only:

```powershell
# INSTRUCTIONS ONLY. The isolated endpoint and fresh empty DB must be verified first.
pg_restore --no-password --dbname='service=geolock_owned_restorecheck' --exit-on-error --single-transaction $stage003Archive
if ($LASTEXITCODE -ne 0) { throw 'Restore failed: recovery NOT VERIFIED' }
```

4. Run read-only schema/function/trigger/ACL/config/data comparisons in the restored copy and compare the saved source snapshot baseline. Confirm all 28 baseline functions and pre-003 lifecycle pins, private definitions, policies, effective privileges, FK validation, sequences/identity continuity and audit/data digests. Investigate every managed-object failure with the provider-supported restore procedure. Do not count a subset schema restore as full recovery validation.
5. Record archive checksum, fresh instance identity, actual restore exit status/log, comparison results, known provider exclusions, recovery duration, data-loss point and recovery owner. Only a successful restore **and** complete comparisons support a scoped restore PASS. Separate external-service recoverability remains explicit. Destroying the owned validation instance is a separately coordinated cleanup; no deletion command is supplied.

## Deployment failure and restoration approval

Before COMMIT, let a failed one-shot psql session disconnect/roll back. In a still-open interactive aborted transaction use ROLLBACK in that same session. On a lost COMMIT response inspect read-only first; do not retry 003 blindly.

After a confirmed commit, keep writers/workers paused and prefer an approved forward repair based on actual state. Do not drop task authority or restore unprotected pickup functions automatically. Whole-DEV restoration can overwrite later claims/audit/Auth state; it requires explicit approval naming the exact backup/PITR timestamp, target ref, data-loss window, provider restore method, downtime and service reconciliation owner. Restore validation in an isolated instance is not approval to restore DEV. Never use the old pre-lifecycle archive as the new recovery point.
