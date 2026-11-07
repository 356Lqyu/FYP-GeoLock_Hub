# Current DEV backup — operator commands

## Approved current-state pre-automatic-departure capture (28 October 2026)

The new mode below uses ONLY the existing geolock_dev_owner_export service,
PostgreSQL 17.11 tools, verify-full CA, and native hidden password prompts. It does
not pause writers, restore, deploy or activate anything. Older procedures below
remain historical references; do not select -PreFreeze for the frozen graph.

Run in your own PowerShell terminal from the repository root:

```powershell
Set-Location -LiteralPath 'C:\Users\User\Downloads\FYP-GeoLock_Hub'
& '.\docs\stage8\stage-a\deployment-preparation\backup_pre003.ps1' -PreAutomaticDeparture
```

Enter the approved DEV owner database password only in native hidden prompts
(normally three: catalog, database archive, roles). Do not use a transcript or
paste a password into chat/arguments. If execution policy blocks the script, stop;
do not bypass it. The script does not reset or fall back to any other credentials.

Each attempt allocates backups/stage-a003/pre-automatic-departure/<UTC>-<suffix>/.
Only this new directory gets a private Windows ACL (operator, SYSTEM and local
Administrators); the runner verifies Git-ignore/nontracking before any export.
It does not encrypt backups: use an encrypted trusted local disk and do not force-add
artifacts to Git. All previous backup directories are preserved.

The new archive is dev-pre-automatic-departure.dump, purpose
PRE_AUTOMATIC_DEPARTURE_CURRENT_DEV. roles-no-passwords.sql includes memberships
and settings, omits role passwords, and remains sensitive. The runner validates
TLS/identity/BYPASSRLS, table/sequence SELECT coverage, role-catalog access, A003
function presence, protected fingerprints and pinned policy/graph/saved artifacts.
It exports an unfiltered custom archive and roles using the unchanged validated
native argument builder. It then checks TOC, complete payload decode, schema,
catalog-to-TOC coverage, protected function body fingerprints and six routing
tables' archived record metadata (plus exact policy JSON) against the inventory.
It does not rehash road data or rerun the graph probe.

Outputs include capture-record.json, capture-manifest.json, source-inventory.json,
schema.sql, routing-recovery-data.sql, current-state-verification.json,
sha256.json, verification-sha256.json, verification.json and backup-status.json.
Only a successful final backup-status plus all PASS reports makes this a verified
logical export. Any failure stops without another connection attempt and leaves
FAILED / NOT A VERIFIED BACKUP evidence; never reuse partial exports for recovery.

For local verification only (no connection or password), use the same mode:

```powershell
& '.\docs\stage8\stage-a\deployment-preparation\backup_pre003.ps1' -PreAutomaticDeparture -VerifyArchiveDirectory 'C:\Users\User\Downloads\FYP-GeoLock_Hub\backups\stage-a003\pre-automatic-departure\ACTUAL-DIRECTORY'
```

Original immutable capture hashes remain pinned. verification-sha256.json records
this verification's files, including regenerated pg_restore extracts whose restrict
tokens can differ. Do not confuse decoded SQL files with executed restore commands.

The database archive has one consistent snapshot. Catalog and roles snapshots are
separate; writers are NOT paused by this approval. Observed routing-state changes
between inventory/export fail that scoped comparison; unchanged comparisons do not
prove complete row equivalence or eliminate a later cutover data-loss gap.
Exact overload/ACL/trigger equivalence and restorability remain NOT VERIFIED.
Extension/platform prerequisites, external Storage bytes, signing/service secrets,
worker state and provider recovery require separate handling. No isolated restore
test is authorized or run. Share only the directory path and sanitized reports;
never paste archive, role, schema or routing-data contents.

---

## Historical pre-003 procedure

**Service-connection correction:** PostgreSQL 17.11 pg_dumpall distinguishes `--dbname=CONNSTR` from `--database=DBNAME`. The former accepts `service=geolock_dev_owner_export`; the latter treats it as a literal database name. The shared argument builder and all examples now use `--dbname` for the roles export. Local tests check installed help semantics and force psql/pg_dump/pg_dumpall to resolve an intentionally absent service in isolated empty service configuration: all three fail locally before network/password access, as expected. No DEV connection occurs in these tests.

The second attempt `20261026T122109Z-d69215` is preserved unchanged. Its 39,332,317-byte database archive passes TOC parsing, full payload decoding and schema decoding; all 88 catalog-inventoried relation definitions/data entries are present. Archive SHA-256: `42e60ba46ab5593a8d1f6b609366f327edd1b46e6fa342e0a6539f4dbdc35214`. No roles export or capture receipt exists there, so that backup set is incomplete and not recovery-ready. Retry without reusing this directory.

**Argument-handling correction:** the original `--file=(Join-Path ...)` form passed an empty `--file=` argument plus a separate path. The runner now uses `backup_native_arguments.ps1` to build/splat arrays with separate option/value tokens for psql, pg_dump, pg_dumpall and pg_restore. Native argv echo tests pass for paths with spaces on PowerShell 7.6.5 and Windows PowerShell 5.1.22621.4249 (inline native checks plus syntax parsing on 5.1; its script-file execution policy was not changed). The failed `20261026T121101Z-c333b8` directory is retained unchanged. Retry the runner without `-VerifyArchiveDirectory`; it creates a new timestamp/GUID directory. No export was executed during validation.

26 October 2026, Asia/Kuala_Lumpur. The user reports successful `export_connection_check.sql` through approved `geolock_dev_owner_export`: postgres/postgres on PostgreSQL 17.11, READ ONLY on, SSL/TLSv1.3, BYPASSRLS true, no missing SELECT/sequence/RLS coverage, readable role/member catalogs and zero large objects. These are **user-reported successful connection results**, not an archive validation or new connection by Codex.

The existing password-free profile is approved for **this DEV backup only**. Older placeholders `geolock_dev_backup`/`geolock_dev_readonly` in historical examples are not the profile for this capture. No credential is stored in the repository. No 003 or initialization operation is authorized.

## Run locally

Open your own PowerShell terminal, then run:

```powershell
Set-Location -LiteralPath 'C:\Users\User\Downloads\FYP-GeoLock_Hub'
& '.\docs\stage8\stage-a\deployment-preparation\backup_pre003.ps1'
```

The script validates the exact profile/DEV host/project username, port 5432, verify-full TLS, CA path and PostgreSQL 17.11 client tools. It sets the process-local PGSERVICEFILE to the existing profile. It prompts separately for the approved password during catalog capture, database export and roles export. Enter it only at the **native hidden PostgreSQL prompt**, never in chat, a command argument, repository file or transcript. If local script execution policy prevents execution, stop and report that; do not bypass security policy. The equivalent native commands below can be run individually after the setup/identity checks.

Each capture creates a fresh, non-overwriting directory:

`C:\Users\User\Downloads\FYP-GeoLock_Hub\backups\stage-a003\<UTC timestamp>-<random suffix>\`

Files:

| File | Contents |
|---|---|
| `dev-pre003.dump` | Complete unfiltered custom-format pg_dump database archive; includes archived application schema/data/ACLs/ownership and extension declarations/configuration as pg_dump supports |
| `roles-no-passwords.sql` | Global role definitions/attributes, membership grants and role settings from pg_dumpall; role passwords deliberately omitted; treat settings as sensitive too |
| `source-inventory.json` | Source identity/version, extensions and non-extension table/partition/materialized-view catalog inventory; no application records |
| `capture-record.json` | Exact DEV/service, start/end times and successful native database/role export exit codes |
| `toc.txt` | Archive table of contents |
| `schema.sql` | Archive-derived schema-only extraction; sensitive local file, not executed |
| `sha256.json` | File lengths and SHA-256 digests |
| `verification.json` | Checks actually completed; explicitly separates archive readability/coverage from unverified exact-content/restore/provider recovery |
| `coverage-missing.txt` | Present only if expected coverage checks detect a gap |

The script prints only the destination and a short result. Never share raw archive, roles SQL, schema SQL, credential files or table-data contents in chat. Give Codex the local output directory or the non-secret `verification.json` results for further verification. Files inherit your filesystem permissions; use an operator-private encrypted location and verify access. Git ignore is not encryption. The old `geolock_dev_before_lifecycle.backup` is never opened for writing, replaced or removed.

## Exact export commands used

Inside the script, `$stage003Dir` is the newly created private destination and PGSERVICEFILE points to the approved profile. The export commands are:

```powershell
$stage003ArchivePath = Join-Path $stage003Dir 'dev-pre003.dump'
& 'C:\Program Files\PostgreSQL\17\bin\pg_dump.exe' --password --dbname 'service=geolock_dev_owner_export' --format custom --lock-wait-timeout 5s --file $stage003ArchivePath
if ($LASTEXITCODE -ne 0) { throw 'Database export incomplete: STOP' }
$stage003RolesPath = Join-Path $stage003Dir 'roles-no-passwords.sql'
& 'C:\Program Files\PostgreSQL\17\bin\pg_dumpall.exe' --password --dbname 'service=geolock_dev_owner_export' --roles-only --no-role-passwords --file $stage003RolesPath
if ($LASTEXITCODE -ne 0) { throw 'Role export incomplete: STOP' }
```

Neither command issues migration/business DML/DDL. `pg_dump` uses a consistent database snapshot and normal read/ACCESS SHARE locks; a 5-second lock-wait bound avoids waiting indefinitely for relation locks. Default READ ONLY is compatible with export and pg_dump's session settings, including its row-security setting under the approved BYPASSRLS account. No table RLS/policy/security setting is altered. Do not use `--enable-row-security` to accept a partial filtered export, or suppress ownership/ACL/private schemas on error.

The full database archive is one snapshot. Roles and source catalog inventory are separate snapshots. Prevent concurrent deployment/role/schema changes while capturing; final cutover needs an agreed writer pause/fresh recovery point or an explicitly documented data-loss gap. Do not stop jobs, terminate sessions or alter security automatically. A business write after capture does not corrupt that snapshot, but moves the recovery point farther behind deployment.

## Verification the runner performs

1. Validates the saved database/session/version/read-only identity before exporting. Stops on foreign tables/large objects pending an explicit coverage plan rather than excluding them.
2. Requires both pg_dump and password-free-role pg_dumpall to return zero and records that result. Stops on partial export; no retry with different permissions/filters.
3. `pg_restore --list` parses TOC; `pg_restore --file=NUL` reads/decompresses the complete archive without connecting to any database.
4. `pg_restore --schema-only --file=...` extracts schema without executing it.
5. Compares captured non-extension regular/partitioned/materialized-view relations to schema/data entries (partition parents have no own data entry), requires auth/storage/routing_private/fleet_private schema entries and baseline function-name presence. Checks all expected baseline signatures via the existing source reference at the **name-presence** level only: TOC names do not prove exact overload/body/ACL equality.
6. Generates SHA-256/length records. On verification-only rerun, compares immutable archive/role/inventory digests to the recorded baseline; never overwrites a changed capture's digest baseline.

Extension-owned/configuration tables, exact function/trigger/policy/default-ACL definitions, sequences and row contents still need full schema/catalog review and restored-copy comparisons before a complete recoverability claim. pg_dump's successful unfiltered archive is substantial export evidence; TOC presence is not row-content equivalence or a tested restore. Exact 001/002/003 phase fingerprints remain in `expected-functions.json` and the existing preflight evidence.

To let Codex check an existing capture **without a password/database connection**:

```powershell
& '.\docs\stage8\stage-a\deployment-preparation\backup_pre003.ps1' -VerifyArchiveDirectory 'C:\Users\User\Downloads\FYP-GeoLock_Hub\backups\stage-a003\ACTUAL-CAPTURE-DIRECTORY'
```

Replace ACTUAL-CAPTURE-DIRECTORY with the output printed by the capture. The verifier checks existing immutable checksums, reads/extracts the archive and refreshes local verification metadata; it never restores or modifies DEV.

## Limits and isolated restore-only validation

The archive/roles export is not a platform backup of physical extension binaries, server config, database passwords, custom role passwords, decrypted Vault key material, Storage object bytes, Auth service configuration/signing keys, Edge Function code/secrets, external scheduler/worker journals/secrets, TLS certificates or provider infrastructure. Extension declarations and database metadata are not those external dependencies. Record any custom tablespace/provider-specific configuration separately. Supabase-managed schemas may be present but replaying their objects into a different managed baseline can fail on reserved ownership/privileges. Do not blindly replay roles SQL or suppress restore errors.

Use the existing **BACKUP_AND_RECOVERY.md → Safe isolated restore validation** procedure: independently provision/identify a fresh isolated restore-only database with PostgreSQL 17.11, matching extensions and a reviewed Supabase-compatible baseline; prove it cannot target DEV/shared/production and contains no existing data; map approved application roles while accounting for managed identities; restore with `--exit-on-error --single-transaction`; compare exact schema/owners/ACLs/RLS/triggers/configuration/constraints/sequences and row counts/content digests against a snapshot-consistent source baseline. No 003 is applied to that copy. No isolated database is created by this runner. On any failure keep recovery NOT VERIFIED and retain diagnostics. This is restore validation, not a migration-compatibility TEST environment.

Never restore over DEV without separate explicit approval naming the exact recovery point, target, data-loss window and provider recovery method. Successful isolated restoration only proves the tested scope; external-service recoverability remains separately documented.

## Actual status at preparation time

| Check | Result |
|---|---|
| Approved profile connection, permissions, TLS, READ ONLY | PASS **as reported by user** |
| Installed four PostgreSQL client binaries | Previously verified 17.11, matching DEV |
| Backup runner PowerShell syntax | PASS, locally parsed without executing |
| New database archive and global-role export | **NOT RUN — awaiting local password prompts** |
| Archive integrity/checksum/coverage | **NOT VERIFIED — no new capture supplied** |
| Isolated restore or successful restore record | **NOT VERIFIED** |
| 003 / routing / lease mutations | **NOT EXECUTED** |

After a successful capture and archive review: resolve scoped recovery validation/limitations → record P11 state-based migration-history acceptance and C.5 residual risk → approve maintenance/fresh cutover preflight and exact pinned 003 command → execute 003 only after explicit final approval → read-only postflight → separately approved lease recovery if needed, policy/graph initialization, worker activation and Flutter pilot. This backup task authorizes none of those database modifications.
