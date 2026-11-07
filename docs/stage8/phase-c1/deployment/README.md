# C1 v2 DEV migration verification package

Checkpoint update 24 October 2026: the user manually executed v2; [all 32 post-migration checks pass](dev-postflight-report-2026-10-24.md), with conditional read-only sign-off. The predeployment instructions below are retained as history, not an instruction to execute or repeat the migration. No authenticated test writes or C2 work are authorized.

**Status: prepared; migration execution NOT AUTHORIZED.** Conditional design approval is recorded, but it does not authorize the deployment step or authenticated mutation tests. This package uses only the unchanged [proposed_migration_v2.sql](../proposed_migration_v2.sql). The original C1 migration is not an input and must not be executed.

DEV project: `rcgyuwiidqvrgbxswhqj`. Confirmed MCP URL: `https://rcgyuwiidqvrgbxswhqj.supabase.co`. Shared project access is prohibited. No DEV records or functions were modified; no migration was executed, including locally, while preparing this package. No C2 implementation is included.

## Package contents

| Artifact | Purpose |
|---|---|
| [preflight.sql](preflight.sql) | 21 individually labelled SELECT-only checks; capture again immediately before any approved deployment. |
| [Final reviewed C1 v2 migration](../proposed_migration_v2.sql) | Existing approved-design candidate, byte-unchanged; no duplicate deployment copy. |
| [post_migration_verification.sql](post_migration_verification.sql) | 32 read-only checks prepared for execution only after a separately authorized migration. |
| [protected_object_snapshot.sql](protected_object_snapshot.sql) | Standalone protected lifecycle/object fingerprint query, identical to L01 in preflight/postflight. |
| [captured-dev-preflight.json](captured-dev-preflight.json) | Current SELECT-only baseline, not a substitute for deployment-time evidence. |
| [package-manifest.json](package-manifest.json) | Exact migration and generated-check hashes and required check IDs; execution_authorized=false. |
| [verify_results.py](verify_results.py) | Offline export wrapper, package hash checker and before/after catalog comparator; no database/network connection. |
| [package-test-results.txt](package-test-results.txt) | Twelve passing offline package/comparator tests. |
| [Later route-closure proposal](route-closure-future-design.md) | Design only; no SQL, RPC or lifecycle implementation. |

The locked migration SHA256 is:

```text
f50af9705de117bdd12581f2515605c8e5c548e0fee7ae01d7ea33ecfbb0cb05
```

## Current preflight findings

The first context check was observed at 2026-10-23 20:28:01 UTC / 24 October 2026 04:28:01 MYT. Checks were separate SELECT statements, not an atomic snapshot. Subsequent checks completed during this preparation. Reconfirm all results in a quiescent deployment window.

- PostgreSQL 17.11, execution role postgres, READ COMMITTED. Six existing vehicle columns; existing keys/constraints match the reviewed baseline.
- Zero vehicles, routes, route stops, active route assignments and nonterminal routes. No invalid legacy capacity values found.
- No fleet_private schema or C1 public RPCs are deployed. No C1 migration is observed.
- Vehicle RLS enabled, FORCE false, no policies. Expanded ACL confirms SELECT/INSERT/UPDATE/DELETE/TRUNCATE/REFERENCES/TRIGGER/MAINTAIN for anon, authenticated and service_role; no column ACLs. V2 will change these as reviewed below.
- Only the original enabled vehicle depot trigger is present. The route states remain DRAFT, VALIDATED, AUTHORISED, IN_PROGRESS, COMPLETED, CANCELLED, STALE. No current route rows or route cron jobs were found.
- Three deployed public routines directly update vehicles: set_ngo_operating_location, verify_ngo_location and geolock_backfill_road_nodes. The depot trigger function reads NGO profiles and assigns NEW.depot_road_node_id. C08 also returns an extension VRP routine containing the word vehicles; that textual match is not evidence of access to public.vehicles. C15 captures the actual depot/location definitions separately.
- Catalog dependencies and source scans were captured. PL/pgSQL/dynamic SQL dependencies are not completely described by pg_depend. Hosted backend clients, service-key distribution, external workers and connection-pool settings remain unverified. A repository source search found no fleet client implementation in the current Flutter/backend application paths; this is repository-only evidence.

## Deployment review of the unchanged v2 file

| Area | Reviewed behavior / required gate |
|---|---|
| Transaction | One BEGIN/COMMIT; 5-second lock_timeout and 60-second statement_timeout; ACCESS EXCLUSIVE locks on vehicles/routes. Any statement error before commit aborts the transaction. Execute the complete file once, not selected fragments. |
| Existing records | No INSERT/UPDATE/DELETE against existing business rows. Nine fields are added; missing legacy costs/type/duration remain NULL, planning starts false, version/time are server initialized. Original six-column projections and route/assignment hashes must be unchanged before tests. |
| Defaults/constraints | No invented capacities, costs or maximum durations. Existing positive capacity retained; new finite/precision/completeness checks; availability/version/timestamp NOT NULL. Bad existing capacities cause a safe abort, not automatic repair. |
| Repeat execution | Same v2 installation is checked through its schema marker/fingerprint; unexpected schema/functions/partial installation, changed column shapes, original trigger or managed definitions abort. Client ACLs are tightened again. Prior isolated tests verified same-file repeat execution. Do not schedule or execute a DEV repeat without separate authorization. |
| Compatibility | Existing vehicles and NGO FK/route composite FK reused; original depot function unchanged. Current empty fleet/routes meet the reviewed first-install assumptions. New rows/dependencies/policies or any drift require re-review. |
| Table permissions | NGO clients lose all vehicle table/column rights. service_role keeps SELECT/INSERT/UPDATE, without grant option, and loses DELETE/TRUNCATE/REFERENCES/TRIGGER/MAINTAIN. Route TRUNCATE is removed from PUBLIC/anon/authenticated/service_role to protect holds. No global defaults or unrelated lifecycle ACLs are altered. |
| RPC permissions | Five public NGO RPCs: authenticated EXECUTE only; no client NGO/depot authority parameter. Private helpers have no client/service schema access or EXECUTE. Owner postgres; fixed pg_catalog,pg_temp path and qualified application objects. |
| Vehicle guard | Immutable identity/owner/request metadata; managed version/timestamp updates rejected; effective edits increment version. All nonterminal route holds and unresolved terminal activity block profile changes. Service writes retain constraints, guards and audit. |
| Depot behavior | Existing trusted depot derivation retained. Idle depot clearing disables planning. Held-depot changes reject the entire verifier/maintenance transaction; no privileged bypass is introduced. |
| Lifecycle boundary | No donation/listing/claim/lease/recovery/hub/NGO-registration function is replaced. C1 adds fleet and route-integrity triggers only; route closure, matrices, snapshots and dispatch enforcement remain unimplemented. |

Adding the volatile clock_timestamp() default can rewrite existing vehicle rows and constraint validation can scan them. Current zero counts do not remove the need to check table growth and plan the lock window. See [PostgreSQL table-default behavior](https://www.postgresql.org/docs/17/ddl-alter.html) and [ALTER TABLE locking/validation](https://www.postgresql.org/docs/17/sql-altertable.html). Logical record preservation is verified using the original six vehicle fields; physical row identities/storage are not promised unchanged.

## Check interpretation

Preflight C01–C05 cover context, schema, constraints, full ACL/RLS and effective privileges. C06–C07 and C17–C18 cover counts, statuses/activity and route/assignment record hashes. C08–C09/C14–C16 cover function, catalog, identity/depot and job dependencies. C10 captures original vehicle values; C11/C20 detect C1 name/schema collisions; C12–C13 inspect indexes/triggers and role capabilities; C19 checks invalid legacy capacities.

L01 records **712 protected object identities/hashes in the current DEV baseline**: public routines except the five new C1 names, all non-fleet public relation/column/constraint/trigger/index/policy definitions, public enum/domain metadata, and relevant default ACLs. This includes donation/listing/claim/lease/hub functions, constraints and policies plus NGO registration/location objects. No lifecycle records are exported by L01. Vehicle/route metadata has intentionally authorized changes, so its old definitions are separately compared through C02/C03/C04/C12; v2 is allowed only nine added columns, two new CHECKs, three indexes, three triggers and the reviewed ACL changes. No existing lifecycle function may disappear or change hash.

Postflight V01–V11 require expected column shapes, exact standard-role permissions, denied column access, five correctly owned/hardened public RPCs, private helper isolation, route-TRUNCATE denial, valid row invariants, matching installation seal, enabled intended triggers and validated CHECKs. V08 invokes only the audited SQL STABLE catalog-fingerprint helper as postgres; it does not invoke any fleet mutation RPC. Inspect C11 helper definitions before V08. The rest are direct catalog/data SELECTs. Do not run the postflight file before deployment: V07/V08 require the new columns/helper.

The comparator rejects missing/duplicate check IDs, unexpected object sets, altered old constraints/triggers/indexes, protected-object hash drift, record/count drift, unintended ACLs or failed assertion rows. Its PASS means the captured catalog/data comparison meets these checks. It does **not** prove runtime ownership enforcement, concurrency, credential secrecy or authentic provenance of manually supplied exports. Confirm project identity independently and inspect new function bodies/constraint/index definitions against the exact migration.

The comparison is for a **first installation from a pre-C1 baseline**. Do not feed an already-installed state as its before file; it rejects that case. If a future repeat is explicitly approved, use separate before/after postflight profiles and a reviewed no-change comparison appropriate to then-current data. Never replay against the saved empty baseline after test data has been introduced.

## Exact manual execution order

**Steps 1–4 are preparation/read-only. Step 5 is a hard stop until the user explicitly authorizes migration execution. No execution command in this guide has been run.**

1. From the repository root, verify the package and reviewed migration hash:

   ```powershell
   .\.venv-stage8\Scripts\python.exe docs/stage8/phase-c1/deployment/verify_results.py check-package
   ```

2. Confirm the selected project's MCP URL is exactly the DEV URL above; database_name=postgres alone cannot distinguish Supabase projects. Confirm the migration operator is postgres. Do not use the shared project, the original C1 file or an unverified connection.
3. Obtain the approved maintenance window and pause relevant fleet/route/location/graph-maintenance writers through their operational owners. Capture a secured schema/grant/function backup and an appropriate recoverable database backup using the existing approved backup process. Verify access/restore responsibility; do not rely on this package as a backup. Inventory external service consumers and pool isolation. This preparation performs none of those operational actions automatically.
4. Execute **each labelled CHECK in preflight.sql separately**, through DEV MCP SELECT-only or the same verified administrative query environment planned for postflight. Save every verification object, not merely the last result. Review zero holds/invalid data/collisions, original six fields, enabled original depot trigger and expected role/constraint/dependency state. Resolve any unexplained drift. Capture a fresh before envelope; the included capture is historical evidence only. Keep writers quiescent through immediate postflight so separate SELECTs form a useful comparison.
5. **STOP: obtain explicit authorization to execute the exact v2 digest in DEV.** Design approval and preparation of checks do not satisfy this gate. Also obtain approval for any test-record mutations that will follow; none is inferred here.
6. Only after step 5, the authorized human operator opens the verified DEV SQL editor as postgres and executes the **entire** ../proposed_migration_v2.sql file, from BEGIN through COMMIT, once. Save the complete outcome and errors. Do not split it, paste the original migration, retry blindly after errors, or run a second migration in the same review. If using an already verified administrative psql connection instead, use ON_ERROR_STOP=1 and the full file; do not add --single-transaction because the file already controls its transaction. [psql error handling](https://www.postgresql.org/docs/17/app-psql.html) explains the stop-on-error behavior. Never paste credentials into evidence files.
7. Before any fleet test writes, execute every labelled CHECK in post_migration_verification.sql in order, under the same role/search_path/server context as preflight. Capture all 32 outputs. Check error-free execution, every pass=true row and zero V07 violations. Stop on missing checks or errors; do not interpret an empty/missing result as PASS.
8. Wrap the result objects in a JSON envelope and compare the fresh before/after captures offline:

   ```powershell
   .\.venv-stage8\Scripts\python.exe docs/stage8/phase-c1/deployment/verify_results.py compare --before <fresh-before.json> --after <immediate-after.json>
   ```

   Required envelope shape is shown below. If using an approved psql connection with -X -q -A -t and ON_ERROR_STOP=1, each check emits one JSON object per line. Save that JSONL, then use `verify_results.py wrap-jsonl --input <export.jsonl> --output <capture.json> --phase preflight` (or postflight). It supports UTF-8 and BOM-marked UTF-16 exports. The wrapper labels the expected project; it does not authenticate the connection. SQL-editor/MCP exports must be normalized to the same verification-object structure. Do not invent or manually change result values.
9. Have the reviewer inspect C11 full function definitions, C03 CHECK definitions, C12 index definitions and all permission/hold assertions, in addition to the comparator. Require the protected snapshot, original vehicle values and route/assignment hashes to match. Any mismatch is a deployment incident to resolve before resuming writers.
10. Only under separately approved controlled test authorization, execute real authenticated tests below. Preserve a new post-deployment baseline before test records change counts. After successful acceptance, resume only the approved fleet-only functions. Keep live routing, route creation/dispatch and depot-emergency bypasses disabled/unapproved until their own operational design is accepted. Archive SQL digest, backups, before/after evidence, errors, comparison and actual test results.

```json
{
  "project_ref": "rcgyuwiidqvrgbxswhqj",
  "phase": "preflight",
  "migration_sha256": "f50af9705de117bdd12581f2515605c8e5c548e0fee7ae01d7ea33ecfbb0cb05",
  "results": [{"check_id": "C01_context", "rows": ["actual query objects go here"]}]
}
```

The abbreviated example is not a runnable capture; all manifest check IDs are required. Angle-bracket command arguments are operator-supplied file paths, not literal commands to execute.

## Authenticated tests that catalog SELECTs cannot prove

| Test requiring separately approved calls/data | Expected evidence |
|---|---|
| Real NGO A and B JWTs | Each lists its own records; A cannot update/change availability/deactivate B's vehicle; a foreign UUID has the same rejection as an unknown UUID. |
| Anonymous/donor/inactive/missing identity | Public NGO RPCs reject access or inactive/non-NGO identity as designed. |
| Direct client DML | Actual authenticated INSERT/UPDATE/DELETE/TRUNCATE attempts are denied. SELECT privilege functions establish the configured ACL, not an end-to-end API test. |
| Backend credential | Trusted service read/import/edit works while owner/version/hold/constraint guards still reject forbidden changes; helper/NGO RPC execution remains denied. Verify proxy authorization and key secrecy independently. |
| Registration/retry/update | Explicit valid values register once; conflicting request reuse, invalid values and stale expected versions fail; no default vehicle appears. Complete legacy fields before availability. |
| Actual NGO depot verification | Real resolver/coverage verification, unverified/outdated location rejection, idle revocation behavior and held-depot transaction rollback work with unchanged V3 functions. |
| Fleet/route races | Route binding versus edit, completion/cancellation versus edit, assignment versus closure, rollback and larger lock-order/deadlock retries behave correctly. No task/claim/lease changes are authorized by this guide. |
| Lifecycle compatibility | Actual NGO registration, pickup completion, cancellation/recovery and hub workflows retain their protected state transitions; no route-close side effects are assumed. |

Existing local evidence is 44 v2 isolated PostgreSQL tests and 117 Phase A/B tests from the previous review. They were not rerun by executing migrations in this turn. This package adds **12 passing offline checks of file integrity, SELECT-only query structure and comparison logic**, including explicitly synthetic postflight fixtures. No real post-migration result exists yet; those unit fixtures are not DEV evidence. Full postflight SQL has been prepared but not executed because C1 is absent. All 21 preflight statements were actually executed as SELECT-only against DEV.

## Rollback checklist

- Before COMMIT: any migration error aborts the transaction. Stop execution, preserve the error and SQLSTATE, roll back/disconnect the aborted session, then rerun SELECT-only preflight to confirm the original state. Do not run only the remaining tail or change the file to force success. A lock timeout is a safe failure to reschedule, not permission to remove guards/timeouts.
- Unknown commit/connection-loss outcome: inspect C11/C20, the installation seal and catalogs. Do not retry until the actual state and fingerprint are established. A completed migration must not be mistaken for an absent one.
- After COMMIT: freeze fleet/route writers, preserve evidence and decide forward repair versus controlled retirement. Revoke public fleet RPC use only through a separately approved administrative action; preserve vehicle rows, version/history, columns and audits. Inspect held routes, tasks and assignments before touching route guards or table ACLs.
- Do not restore broad anon/authenticated privileges, truncate routes/vehicles, cascade-drop the private schema, drop new fields with data, change claim ownership or rewrite lifecycle states as a rollback shortcut. Do not disable triggers to work around a held depot.
- An exact post-commit retirement SQL must be prepared against the then-current catalog/data and approved separately; no destructive down migration is included. Restore from backup only under the approved recovery procedure, with the effect on subsequent legitimate data explicitly reviewed. Verify protected-object fingerprints and ownership/ACLs again after recovery.

## Remaining blockers and risks

1. **Explicit migration execution authorization is missing.** No approval to mutate test records has been inferred.
2. Confirm external backend consumers, credential handling, administrative connection, maintenance window, backup/restore ownership and pool isolation; these are not established by catalogs.
3. Refresh preflight under quiescence immediately before deployment. Current counts, schema and the 712-object manifest can change; snapshots from separate SELECT statements are not an atomic database backup.
4. Postflight and real JWT/backend/road-resolver/lifecycle/concurrency acceptance remain pending. Catalog success cannot replace them.
5. Pickup completion does not close routes or clear assignments. Abandoned holds can persist indefinitely. Approve and implement the separately reviewed later closure/release design before live route operations; C1 alone is fleet management.
6. Emergency depot revocation with held work has no generic C1 exception. Any emergency procedure requires separate approval and must preserve custody/route evidence.
7. The existing start_pickup dispatch bypass is unchanged. C1 must not be represented as enforced production dispatch, and no C2 or dispatch integration begins here.

The package is ready for review, not deployment. Stop after this preparation until explicit authorization identifies the DEV project and exact v2 SQL digest.
