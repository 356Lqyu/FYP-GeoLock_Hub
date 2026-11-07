# Simplified reconciliation: current-baseline capture and recovery preparation

Prepared locally, 2026-11-04. **No capture, restore, DEV mutation or worker operation was executed.** Commands below require separate approval. This supplements the historical backup documents; their older baseline pins and scope-specific risk acceptances do not approve this capture or release.

## Operator and control ownership

The existing `results/reconciliation-operator-recovery-review-20261031/DEV_PRIORITY_EXECUTION_RECORD.md` identifies the project owner/user as the self-declared DEV deployment operator, recovery operator and backup-control decision-maker. That is the incumbent operator identified by the available record, not independently verified delegated authority. At the separate approval, record their current name/identity, the recovery executor if different, approval reference, current baseline review and maintenance/write-gap plan. Do not reuse the October waiver as acceptance of current restoration risk.

Target is only `rcgyuwiidqvrgbxswhqj`. Export uses the existing `geolock_dev_owner_export` service and password-free TLS verify-full profile. Installer and export services serve different purposes. Enter passwords only at native hidden prompts. No transcripts, command-line passwords or credentials in reports.

## Smallest capture adaptation

`backup_pre003.ps1 -PreSimplifiedReconciliation` selects a new mode. It retains native PostgreSQL 17.11 tools, unfiltered custom database export, roles/memberships without passwords, identity/TLS/BYPASSRLS and table/sequence read coverage checks, private directory ACL, Git-ignore/nontracking checks, full payload decode, TOC coverage, original artifact checksums and scoped offline archive comparisons. The prior modes and their pins remain separate.

The new helper uses `simplified_reconciliation_backup_baseline.json`: 31 inspected deployed function signatures/body hashes/owners/definer modes/ACLs (29 from the final preflight plus the snapshot and claim-detail privacy entry points). It requires task/fleet guards, the observed absent app ledger and absent coordination package. It inventories all nine existing routing recovery tables. It does not insist that old business-route counts/statuses or graph IDs still match an October scenario. Actual routing metadata is compared against the captured archive. It does not change source security, create roles, create a ledger or run application RPCs.

The baseline is a reviewable snapshot, not automatic trust in future DEV definitions. A mismatch is a stop: inspect and review provenance rather than auto-repinning. If a privacy/history migration, ledger or coordination package has been installed before capture, this mode intentionally fails until a separately reviewed current-baseline manifest is supplied.

After approval, from project root:

```powershell
# Local prerequisites/profile/tool validation only; does not connect or capture.
& '.\docs\stage8\stage-a\deployment-preparation\backup_pre003.ps1' -PreSimplifiedReconciliation -ValidateOnly
# Separately approved read-only source capture (three native password prompts).
& '.\docs\stage8\stage-a\deployment-preparation\backup_pre003.ps1' -PreSimplifiedReconciliation
# Offline re-verification of the actual newly created directory:
& '.\docs\stage8\stage-a\deployment-preparation\backup_pre003.ps1' -PreSimplifiedReconciliation -VerifyArchiveDirectory 'C:\Users\User\Downloads\FYP-GeoLock_Hub\backups\stage-a003\pre-simplified-reconciliation\ACTUAL-UTC-SUFFIX'
```

No command above was executed during this task. Synthetic guard tests dot-source only definitions and pass synthetic objects. The destination is a fresh `backups/stage-a003/pre-simplified-reconciliation/<UTC>-<suffix>` directory. Do not reuse failed attempts. The profile, CA, ignore rules, exact tool versions and destination permissions are checked by the existing runner before export. Encrypted trusted storage and enough space for archive plus decoded extracts are operator prerequisites; the runner does not encrypt files.

## Verification gates

1. Record approved target, operator, baseline manifest and script hashes; check no package markers/version ambiguity before capture. Confirm TLS identity and read coverage through the runner, without widening permissions.
2. Database and role exports must both exit zero. Verify `capture-record.json`, complete TOC/payload decoding, schema extraction, all inventoried relation/data coverage, 31 body matches and nine routing metadata sections. Fail closed on a missing section, changed fingerprint/ACL/owner or any unexpected snapshot difference.
3. Verify `sha256.json` against immutable archive, role export, capture/inventory and manifest files; retain regenerated extraction hashes separately. Protect all raw schema/role/data exports and diagnostic extracts. Share only sanitized receipts/hashes.
4. `VERIFIED LOGICAL EXPORT / RESTORABILITY NOT VERIFIED` is not recovery approval. Inventory and roles use separate snapshots from pg_dump. An approved no-writer/DDL capture/cutover window or a reviewed reconciliation/data-loss-gap plan is required. No writer/worker was paused by this preparation.
5. Capture references/coverage for external Storage bytes, Auth/signing/service configuration, worker journals/credentials and extension binaries through the approved platform process. Logical DB files do not restore these.

## Isolated restore procedure (prepare/review, then separate approval)

1. Provision a brand-new disposable environment with PostgreSQL 17.11 and DEV-compatible PostGIS 3.3.7/pgRouting 3.4.1 plus the captured Supabase extension/platform baseline. It must have no DEV/production credentials, no outbound worker/scheduler integrations and no link to existing data directories. The current synthetic test runtime (PostGIS 3.6.2/pgRouting 4.0.1) is not restore parity.
2. Use the verified archive checksum and full `pg_restore --list` output. Review roles, memberships, ownership, extensions and managed Auth/Storage/cron schemas against this empty platform. Prepare a reviewed bootstrap/TOC plan for pre-existing managed objects; do not blindly replay roles over postgres/provider roles, suppress errors or silently exclude failures. Account explicitly for every provider-owned omission. Passwords must be provisioned separately and are absent from the role export.
3. Start the isolated target only on loopback, choose a fresh explicit port/database, and clear PG service/password/options environment variables. Validate `inet_server_addr()`/port, target database and roles before restoration. The restore executor must use an explicit loopback connection, never either DEV service. Apply the reviewed role/bootstrap SQL, then restore the reviewed TOC with `--exit-on-error --single-transaction`, preserving reviewed ownership and ACLs. Example, after those checks, with operator-supplied **local** port and reviewed files:

```powershell
# These are isolated-target operations only, not part of the source capture runner.
$restorePort = '<verified-isolated-loopback-port>'
if ($restorePort -notmatch '^\d+$') { throw 'Verified local port required' }
$localTarget = "host=127.0.0.1 port=$restorePort dbname=geolock_recovery_check user=postgres"
& 'C:\Program Files\PostgreSQL\17\bin\psql.exe' -X --set ON_ERROR_STOP=1 --dbname $localTarget --file '.\reviewed-local-role-bootstrap.sql'
if ($LASTEXITCODE -ne 0) { throw 'Bootstrap failed' }
& 'C:\Program Files\PostgreSQL\17\bin\pg_restore.exe' --exit-on-error --single-transaction --dbname $localTarget --use-list '.\reviewed-restore.toc' '.\verified-dev-pre-simplified-reconciliation.dump'
if ($LASTEXITCODE -ne 0) { throw 'Restore failed: no recovery PASS' }
```

4. Compare source-capture/restored inventories: all application/private tables and sequence values, exact function definitions/signatures/config/owners/ACLs, enabled and deferred triggers, constraints, evidence/receipt/history rows and graph/policy manifests. Perform full application-table data comparisons from a consistent approved capture point, not merely the runner's nine-table metadata check. Explain all platform differences and compare role memberships explicitly. On the isolated copy only, verify owner/foreign/anon API access and route/custody guards. Do not activate outbound workers or process real goods.
5. Record archive/TOC/bootstrap hashes, tool/extension versions, sanitized restore log, comparison results, exclusions, recovery duration, operator and approval. Stop/drop only the named disposable target after verification. Never issue an automatic restore against DEV. Any failed or unaccounted step remains NOT VERIFIED.

If parity cannot be provisioned locally, obtain a separately approved provider-supported disposable recovery exercise; do not call the synthetic test suite a restore test. Provider backup/PITR entitlement and external-service recovery remain operator checks.

Before migration COMMIT, an installation error rolls back. After COMMIT, there is no safe automatic down migration collapsing new evidence rounds and receipts. A forward fix or a separately approved restore with explicit write-gap/data-loss handling is required. The recovery operator makes that decision against the actual installed state.
