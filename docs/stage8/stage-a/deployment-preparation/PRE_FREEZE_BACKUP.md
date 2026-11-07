# Fresh current-DEV pre-freeze backup

Prepared27 October2026; NOT CAPTURED YET. Owner authorized backup preparation,
not graph freeze/worker/recovery activation. Use native PostgreSQL17.11 and approved
owner-export service only. Python authentication/export is not involved.

## Exact operator command

Run in interactive PowerShell from the repository root:

```powershell
& '.\docs\stage8\stage-a\deployment-preparation\backup_pre003.ps1' -PreFreeze
if ($LASTEXITCODE -ne 0) { throw 'Inspect failure evidence; do not claim a complete backup.' }
```

Despite its historical filename, `-PreFreeze` selects the current POST003/installed
policy checks and creates a NEW directory:

`C:\Users\User\Downloads\FYP-GeoLock_Hub\backups\stage-a003\pre-freeze\<UTC timestamp>-<random suffix>`

It never reuses previous capture directories. Native hidden prompts may occur for
catalog inventory, pg_dump and pg_dumpall. Enter the approved postgres DATABASE
owner password locally, never the graph-login password, access token or API key.
No credential arguments/file/variables required. Existing password/options environment
overrides are removed for the operator session; profile remains password-free.

Connection is pinned by existing backups/stage-a003/pg_service.conf:
geolock_dev_owner_export; aws-0-ap-northeast-2.pooler.supabase.com:5432,
postgres database, postgres.rcgyuwiidqvrgbxswhqj, sslmode=verify-full, supplied CA,
default_transaction_read_only=on. Guard checks postgres identity, server17.11,
TLS, BYPASSRLS, exact installed policy ID/request/body/digest and zero graph manifests.
Missing source SELECT rights cause failure, not exclusions/grants or role substitution.

The inherited stage-a003 .gitignore covers this directory; it is NOT encryption.
Archive/Auth data may contain personal data and secrets. Keep local access restricted;
do not print/upload raw dumps or roles/data payloads. Previous backups remain unchanged.

## Native command forms used by the script

These explain capture; use the runner above to obtain new paths and guards rather
than rerunning commands against any existing destination:

```powershell
# $archive/$roles refer only to the NEW directory created by the runner.
& 'C:\Program Files\PostgreSQL\17\bin\pg_dump.exe' --password --dbname 'service=geolock_dev_owner_export' --format custom --lock-wait-timeout 5s --file $archive
& 'C:\Program Files\PostgreSQL\17\bin\pg_dumpall.exe' --password --dbname 'service=geolock_dev_owner_export' --roles-only --no-role-passwords --file $roles
& 'C:\Program Files\PostgreSQL\17\bin\pg_restore.exe' --list $archive
& 'C:\Program Files\PostgreSQL\17\bin\pg_restore.exe' --file NUL $archive
```

Full database export: no schema/data/ownership/ACL exclusions, no --no-owner,
--no-acl, --enable-row-security or security bypass. pg_dump custom format provides
one internally consistent database snapshot and includes readable table data,
road data, routing_private/fleet_private, functions, triggers, policies, owners and
ACLs as supported by logical export. Roles/memberships are cluster globals exported
separately without passwords. Catalog inventory and globals are NOT the same
snapshot as pg_dump; coordinate no DDL/role changes during capture. For a precise
pre-freeze recovery point, pause business writers through final postflight by
separate operational agreement; otherwise record the capture-to-freeze write gap.

## Expected verification, not yet actual results

* pg_dump and pg_dumpall exit0; custom archive dev-prefreeze.dump and
  roles-no-passwords.sql both nonempty. No predetermined expected size/checksum.
* pg_restore --list, complete local decode to NUL and schema extraction exit0.
  Neither command supplies --dbname or connects to a restore target.
* TOC covers all inventoried non-extension relations/data plus routing/auth/storage
  schemas, baseline AND deployed003 function names, routing_task_authority trigger.
  This is presence/coverage, not exact body/ACL equivalence.
* Local extraction policy-data.sql contains exactly installed policy
  80db858b-93e8-4a0a-94e2-dbe14940f0a1, request0b8db479-20c8-4595-9d41-d831650cba93,
  identical observed body/digest. Full archive retains immutable source rows.
* source-inventory.json, capture-record.json, toc.txt, schema.sql,
  policy-data.sql, sha256.json and verification.json saved alongside archive/roles.
  SHA256 and exact file sizes recorded. Failures retain partial evidence and
  never qualify as a recovery backup. No automatic retries or overwritten dumps.

Optional verification-only command after success (no connection/password):

```powershell
& '.\docs\stage8\stage-a\deployment-preparation\backup_pre003.ps1' -PreFreeze -VerifyArchiveDirectory 'C:\Users\User\Downloads\FYP-GeoLock_Hub\backups\stage-a003\pre-freeze\<actual new directory>'
```

This regenerates verification derivatives in that NEW capture directory and compares
immutable capture hashes. Do not use it against old captures or partial files.

## Coverage and recovery limits

Auth schema/data readable by owner are included; this is sensitive database content,
not Auth service configuration/JWT signing keys/OAuth/provider secrets. Storage
metadata is included, NOT external object bytes. Edge Function code/secrets, runtime
configuration, external jobs/services, API keys/TLS infrastructure and provider
settings need separate recovery. Managed vault/encryption material may depend on
external keys; presence in a dump does not establish decryptability elsewhere.

Extension definitions/configuration data follow pg_dump rules. Extension-owned
objects are normally recreated from compatible extension packages, not individually
dumped; record inventory versions and provision matching packages. Provider-managed
schemas/owners/roles and managed settings may require Supabase-supported restore
steps; do not replay their role SQL indiscriminately. Role passwords deliberately
absent; application login secrets require secure reprovisioning. Tablespaces/server
configuration/physical files are outside this logical capture. Foreign tables and
large objects stop this script for a separate scope review if newly present.

Disposable restore-only validation is possible in principle, never into DEV:
use a NEW owned isolated PostgreSQL17.11/Supabase-compatible database with required
extensions, matching reviewed application roles and blocked external jobs/network
egress. Review managed-object bootstrap separately. Existing bare local routing
fixtures are not proof of full Supabase restore compatibility. Follow the isolated
procedure in BACKUP_AND_RECOVERY.md, using this NEW archive and a distinct
geolock_prefreeze_restorecheck database. Do not automatically run a restore.
Only after target-isolation verification, a reviewed restore command would be:

```powershell
# Procedure only. Service must be proven to target the owned isolated instance.
& 'C:\Program Files\PostgreSQL\17\bin\pg_restore.exe' --no-password --dbname 'service=geolock_owned_prefreeze_restorecheck' --exit-on-error --single-transaction $archive
```

No --clean/--create or ownership/ACL suppression to mask errors. Full restore,
constraint/privilege/function checks and data comparisons must complete before
scoped restorability PASS. No approved platform-compatible restore target is
identified for this capture yet. Restorability, exact source row-content equivalence,
recovery duration and complete managed/external recovery remain NOT VERIFIED.

## Actual local preparation results

PowerShell syntax and existing offline native-argument validation passed (six argv
cases and three installed-client service-lookup tests; no remote connection).
New pre-freeze archive/policy checks await a real capture. No fresh backup path,
size, checksum, export-completion or readability PASS is claimed yet.

Next: operator runs the command, then Codex inspects verification.json/sha256.json
and archive metadata without exposing data. After accepted recovery evidence,
return to FINAL_GRAPH_FREEZE_CHECKPOINT.md: quiet window/read-only refresh and
separate exact freeze authorization. No policy reinstall, export repeat, recovery
or worker activation is needed to perform this backup.
