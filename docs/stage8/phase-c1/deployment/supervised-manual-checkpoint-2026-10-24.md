# Supervised manual C1 v2 DEV deployment checkpoint

**The user controls manual execution. Codex is not authorized to execute the migration through MCP or any other tool. No migration or post-migration verification has been run in this checkpoint.** Stop after these instructions until the user explicitly confirms that they manually executed the file and reports the SQL Editor result.

## Exact file and immutable digest

```text
C:\Users\User\Downloads\FYP-GeoLock_Hub\docs\stage8\phase-c1\proposed_migration_v2.sql

SHA-256:
f50af9705de117bdd12581f2515605c8e5c548e0fee7ae01d7ea33ecfbb0cb05
```

The file is byte-unchanged from the accepted v2 review. The original proposed_migration.sql must not be used. Package/check-file integrity also passes the offline hash verifier.

## Refreshed DEV preflight

Confirmed MCP URL: `https://rcgyuwiidqvrgbxswhqj.supabase.co`. All 21 labelled checks in preflight.sql were reexecuted using SELECT-only. The context observation was 24 October 2026, 18:06:48 MYT (10:06:48 UTC); queries were separate statements, not one atomic snapshot.

Comparison with captured-dev-preflight.json: **no substantive differences**. Only the observation timestamp changed.

- PostgreSQL 17.11, postgres, READ COMMITTED; same search_path.
- Six existing vehicle fields, 11 captured fleet/route constraints, unchanged keys/indexes/depot trigger/ownership and privileges.
- Zero vehicles, routes, stops, active assignments and nonterminal routes; no invalid legacy capacity.
- No fleet_private schema or new fleet RPCs installed; no C1 execution observed.
- All **712 protected object identities and SHA-256 values match exactly**, not just their count.

Evidence: [fresh capture](supervised-preflight-2026-10-24.json), [comparison](supervised-preflight-comparison-2026-10-24.json). Use this fresh capture as the before file for later read-only postflight comparison. If deployment is delayed or relevant writers run, recheck under the maintenance window before execution.

## Transaction and object scope

The file contains one BEGIN through final COMMIT, 5-second lock_timeout, 60-second statement_timeout, and ACCESS EXCLUSIVE locks on vehicles and pickup_routes. Schema/column/constraint/index/trigger/function/ACL/comment changes are transactional. Index creation is ordinary CREATE INDEX, not CONCURRENTLY. There is no VACUUM, ALTER SYSTEM, autonomous transaction, external network request or backup/restore operation. DO blocks perform precondition checks and installation metadata work; migration-time helper execution reads catalogs. Vehicle/assignment/audit DML inside stored RPC/trigger bodies is defined for future calls, not executed during deployment.

There are **no nontransactional schema/business-data operations**. Locks, time spent, errors and database/editor logging are operational effects: rollback releases transaction locks and discards transactional changes, but cannot erase logs/history or undo elapsed work. [PostgreSQL transaction semantics](https://www.postgresql.org/docs/17/sql-begin.html).

The intended changes are limited to:

| Object | Change |
|---|---|
| public.vehicles | Nine added columns, two CHECKs, two indexes, RLS enabled, reviewed table/column privileges; two new row triggers. Original six fields and existing PK/FKs preserved. |
| public.pickup_routes | One busy-vehicle index, one fleet-integrity trigger, client/service TRUNCATE revoked. Route columns, status CHECK and existing FKs unchanged. |
| fleet_private | New private schema, nine fleet/security/catalog helpers, private ACLs and installation marker. |
| Five public fleet RPCs | register_my_vehicle, list_my_vehicles, update_my_vehicle, set_my_vehicle_availability, deactivate_my_vehicle; authenticated EXECUTE only. |
| audit_events | No schema or existing-row change. Future vehicle mutations produce audit events through the new vehicle trigger. |

No existing NGO-registration/depot-verification, donation, listing, claim, lease, recovery, hub or start_pickup function is replaced. No vehicles or operational defaults are inserted. No C2, routing snapshot, matrix, route-closure or dispatch authorization implementation is included.

## Required backup and recovery preparation before Run

**Backup availability, latest recoverable time and restore access have NOT been verified by Codex. Do not click Run until these are established.** Empty fleet tables do not mean the rest of DEV is disposable.

1. In this exact DEV project's Dashboard, inspect Database → Backups. Confirm a successful usable backup/restore point and record its time. If PITR is already enabled, check its actual recoverable range. Do not assume either feature is enabled or that the latest daily backup covers recent data.
2. If no sufficiently current recoverable backup exists, have the designated administrator make a consistent backup using the approved Supabase backup process before deployment. Retain schema/functions/triggers/RLS/grants/roles plus necessary database data in a secured location. The catalog hashes and JSON evidence are not a restorable backup. Do not put credentials or sensitive backup contents into this chat/repository.
3. Confirm who can restore it, the target/permissions and a credible restore procedure. Prefer evidence of a restore rehearsal in an isolated environment. A full project restore affects unrelated post-backup changes and may require downtime; it is not the routine C1 rollback.
4. Pause relevant fleet, route, NGO-location and graph-maintenance writers for the checkpoint. Codex has not paused them. Keep the window quiescent through immediate read-only verification; otherwise record-preservation comparisons may reflect concurrent legitimate writes.

Supabase backup availability depends on the project's plan/configuration; use the actual Dashboard status and [official backup guidance](https://supabase.com/docs/guides/platform/backups), rather than assuming a paid feature exists. No backup or restore has been initiated by this review.

## Exact SQL Editor execution steps for the user

1. Confirm the backup/recovery and paused-writer prerequisites above. Open the [DEV SQL Editor](https://supabase.com/dashboard/project/rcgyuwiidqvrgbxswhqj/sql/new). Check that the URL and selected project reference are **rcgyuwiidqvrgbxswhqj**, with the intended primary database/branch, not the shared project or a replica.
2. Select the database role **postgres**. If needed, use a separate scratch query for this SELECT-only role/context check; do not prepend it to or edit the migration:

   ```sql
   SELECT current_user, current_database(),
          current_setting('server_version') AS server_version,
          current_setting('transaction_isolation') AS isolation;
   ```

   Require postgres and READ COMMITTED. The database name postgres is not proof of the correct Supabase project. [Supabase documents Dashboard queries as postgres](https://supabase.com/docs/guides/database/postgres/roles).
3. Open the exact local v2 file above. Optionally verify it again in PowerShell using `Get-FileHash -LiteralPath '<the full v2 path above>' -Algorithm SHA256`; require the exact digest. Do not regenerate, reformat, modify, or substitute the original file.
4. Create a new empty SQL Editor query. Paste the **complete file**, including its comments, BEGIN, all function bodies, installation-seal block and final COMMIT. Confirm the text has not been truncated. Do not paste preflight/postflight SQL or any test calls into this query. Do not add an outer transaction or remove timeouts/preconditions.
5. Ensure Run will execute the whole file; clear any partial text selection or select the entire script. Click **Run once**. If a warning appears, review it against the exact intended schema/privilege changes; proceed only on the verified DEV target and reviewed full script. Do not use AI-generated fixes or execute just the selected remainder.
6. Save the complete result and any error/SQLSTATE. A successful script may return “Success. No rows returned”; that does not itself prove the post-migration invariants. If it errors, times out or disconnects, stop—do not retry blindly or run test writes.
7. Explicitly report the manual execution and outcome, for example: “I manually executed proposed_migration_v2.sql in DEV rcgyuwiidqvrgbxswhqj; SQL Editor reported [exact result].” Codex will wait for this confirmation before read-only post-migration verification. Do not run authenticated fleet tests yet.

## Rollback and ambiguous outcome procedure

- **Error before COMMIT:** the transaction is aborted; transactional schema/data/ACL changes cannot partially commit. If the same connection still has an open aborted transaction, its operator must roll it back or disconnect it. `ROLLBACK;` applies only to that current session's uncommitted transaction. Do not assume a new SQL Editor tab/request uses the same pooled session. Save the error and stop for read-only diagnosis rather than modifying the migration.
- **Timeout/connection loss:** completion can be ambiguous. Report that outcome. Do not infer failure or retry. After your confirmation of the attempt, read-only catalog/seal checks must establish whether the transaction committed before deciding what comes next.
- **After successful COMMIT:** ROLLBACK cannot undo the migration. A new tab's ROLLBACK does nothing to a committed transaction. Pause fleet/route writers and obtain a separately reviewed forward repair or retirement plan against the actual state. Preserve rows, added fields and audit/history; do not drop the schema, disable guards, truncate routes or restore broad client grants as a shortcut.
- **Backup restore:** only an authorized administrator should use the approved recovery procedure, with its downtime and effect on unrelated data explicitly accepted. It is not automatic and has not been authorized for Codex.

PostgreSQL [ROLLBACK documentation](https://www.postgresql.org/docs/17/sql-rollback.html) confirms that it discards the current transaction and has no effect outside a transaction. There is no destructive down-migration in this package.

## Required read-only gate before any authenticated test writes

After your explicit execution confirmation, collect **all 32 outputs** from post_migration_verification.sql under the same catalog context as the fresh preflight. Do not treat missing checks or empty assertion sets as success.

| Assertion check | Required result |
|---|---|
| V01 expected columns | Nine rows, all pass=true. |
| V02 table permissions | 24 rows, all pass=true: anon/authenticated no direct access; service_role SELECT/INSERT/UPDATE only. |
| V03 column permissions | 120 rows, all pass=true: no residual client column privileges. |
| V04 public RPCs | 15 rows, all pass=true: correct signatures, owner, path, definer and role EXECUTE. |
| V05 private helpers | 27 rows, all pass=true: private schema/function access denied to client/service roles. |
| V06 route TRUNCATE | Three rows, all pass=true. |
| V07 row integrity | Zero violating rows. |
| V08 installation seal | One row, pass=true. Only the audited read-only catalog helper is invoked. |
| V09 intended triggers | Four rows, all pass=true, including the unchanged original depot trigger. |
| V10 new CHECKs | Two rows, all pass=true and validated. |
| V11 private function hardening | Nine rows, all pass=true. |

The other 21 outputs must show exactly the authorized v2 changes and preservation of the baseline: unchanged original vehicle values and zero counts before writes, unchanged route/assignment hashes, preserved original constraints/indexes/depot functions, unchanged role capabilities, and exact equality of all **712 protected identity/hash pairs**. The private schema/functions and new vehicle fields are expected to appear; current broad client privileges are expected to disappear. Do not require every inventory row to be unchanged indiscriminately.

Use the offline comparator with supervised-preflight-2026-10-24.json as the before capture and the real immediate postflight export as after. Require catalog_comparison=PASS and manually review new function/CHECK/index definitions against the pinned migration. A count of 712 alone is insufficient; missing/added identities or a changed hash fails the protected-object gate.

No postflight has been run yet. Catalog checks establish configured permissions and object preservation, not real JWT ownership isolation or runtime races. Authenticated/backend mutation tests still need the approved controlled test plan and explicit authorization; postflight success is not permission for Codex to perform writes.

Pickup completion still does not close routes or clear assignments. Do not create live route workloads or begin C2 at this checkpoint. The [separate later closure/release proposal](route-closure-future-design.md) remains design only.
