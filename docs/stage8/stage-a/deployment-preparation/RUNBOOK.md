# Stage A 003 — accelerated DEV deployment preparation

**Current installed status: DEPLOYED / POSTFLIGHT PASS.** See [POSTDEPLOYMENT_ASSESSMENT.md](POSTDEPLOYMENT_ASSESSMENT.md) and `results/stage-a003-postdeployment/deployment-record.json`. The user executed 003; independent read-only checks verify the scoped postconditions. Historical execution commands below must **not** be rerun. Routing initialization is a new, unexecuted procedure in [ROUTING_INITIALIZATION_PROCEDURE.md](ROUTING_INITIALIZATION_PROCEDURE.md).

**Final approval checklist:** [FINAL_DEPLOYMENT_CHECKPOINT.md](FINAL_DEPLOYMENT_CHECKPOINT.md) records the verified successful backup, archived pre-003 parity, recovery limitations and exact reviewed commands. Its current findings supersede older no-backup/no-connection status in this historical runbook. No final execution approval has been given.

**Next-action checklist:** [ACTION_SEQUENCE.md](ACTION_SEQUENCE.md) separates Dashboard/local/Codex responsibilities, gives secure export-connection instructions, maps every routing table to its actual producer, and records the latest read-only lease findings. No initialization or deployment is authorized by that checklist.

**Current checkpoint:** [DIRECT_DEV_DECISION.md](DIRECT_DEV_DECISION.md) records the fresh 26 October read-only DEV inspection, accepted direct-deployment risk, Flutter changes and final command. [BACKUP_AND_RECOVERY.md](BACKUP_AND_RECOVERY.md) supplies the requested new-backup commands and restore-only validation procedure; [POST_DEPLOYMENT_TESTS.md](POST_DEPLOYMENT_TESTS.md) defines the actual RPC workflow and verification matrix. These supersede older statements below that no DEV connection has occurred or that a separate migration-compatibility environment must precede deployment. No 003 execution has occurred. Fresh P07 counts are zero, but two ACTIVE leases are expired and policy/graph infrastructure is empty. Current recovery is NOT VERIFIED.

Prepared 26 October 2026 (Asia/Kuala_Lumpur). **Decision: NO-GO for execution now. Preparation complete; no database connection or SQL execution performed.** AI ranking is outside this package.

This is a runbook and read-only evidence package, not corrective DDL or execution approval. Use only DEV project **`rcgyuwiidqvrgbxswhqj`**. The shortest path reuses the reconciled C.3 baseline and refreshes the deployment-sensitive evidence once, during a coordinated writer pause. Do not restart a general readiness audit or troubleshoot a local server as part of this runbook.

## Exact artifact and dependency order

Repository-root-relative migration:

`docs/stage8/stage-a/forward-migrations/20261103_routing_pickup_and_reconciliation.sql`

SHA-256: **`6541f0a002ea56ad77c023e33ad1500ab2273cc821f87fa43d38e633bd6724ea`**

The file remains byte-for-byte unchanged. Do not regenerate, edit, wrap in another transaction, remove guards, or substitute either historical integration 003 proposal. Existing verified 001/002 baseline → this exact 003, if separately approved as the in-place upgrade → postflight → separately approved B.2 → separately approved B.4.3 Candidate 2. Never replay 001/002. B.4.3 first changes `claim_listing` to a hash rejected by 003.

The Stage A README explicitly states: “Existing `routing_private` requires a separately designed upgrade.” C.4 designs that path but does not validate or approve execution. This runbook makes the proposed reuse of unchanged 003 concrete for review; it does not turn missing C.5 evidence into a PASS.

## Fresh preflight: two short passes, no automatic repair

1. **Before connecting**, verify the actual Supabase Dashboard project reference and credential/service endpoint are DEV `rcgyuwiidqvrgbxswhqj`. For a pooler, verify its project-bearing username against the Dashboard. Database name `postgres`, DNS reachability, SQL role, a configured service name, and the SQL output alone do not authenticate project identity. Record the verified ref, time and source without credentials. No shared or production endpoint is permitted.
2. Run `preflight.sql` through a DEV-only approved read-only MCP connection or dedicated read-only PostgreSQL credential. The existing MCP configuration observed earlier lacks `read_only=true`; do not use it as a read-only substitute. The script explicitly opens a READ ONLY transaction, uses only catalog/aggregate SELECTs and local transaction settings, and ends with ROLLBACK. It invokes no application RPC or SECURITY DEFINER business function. Permission-denied, missing relation, timeout or truncated output means UNKNOWN/STOP, never PASS. Do not elevate the inspector to make it work.
3. Review all output against the criteria below. The 11-row nested structural result deliberately reuses C.3 Query 2 so object existence/counts cannot masquerade as definition parity. Save complete output securely; do not use the Dashboard's truncated flat grid as evidence. Expected hashes, metadata and direct EXECUTE grantees are in `expected-functions.json`.
4. When execution has separately been approved, pause claim/pickup/planning/reconciliation writers, scheduled recovery and manual deployments using an approved maintenance procedure. Keep workers disabled. Refresh the same preflight immediately before cutover, then verify `current_user`, `session_user` and isolation in the approved installer session. Inspector identity is not the future installer identity. No role provisioning, permission changes, scheduler changes or session termination are authorized by this preparation.

| Output / prerequisite | PASS criterion | FAIL / UNKNOWN action |
|---|---|---|
| P01 target/session | Out-of-band DEV identity confirmed; inspection reports READ ONLY. Future installer must separately report `postgres`/`postgres`, READ COMMITTED. | Stop on unconfirmed target, wrong session or unapproved credential. |
| P02 001/002 baseline | Exactly 28 PASS rows: signatures, normalized body MD5, return types, postgres owner, security mode, volatility, exact configs and EXECUTE grantees match reviewed sources. | Any mismatch stops; never replay baseline migrations. |
| P03 lifecycle inputs | Five lifecycle rows and six-argument audit-helper row PASS; audit helper returns `void`. Assignment is covered by P02. | Stop; do not adopt new hashes or loosen guards. |
| P04 partial 003 | All 14 added signatures absent, no unexpected overload/name from 003, and authority trigger absent. Three existing public replacements remain at P03 pre-003 hashes. | A subset means partial/drift; all post-003 objects means possible existing installation. In either case inspect postconditions, do not execute/replay. |
| P05 private structure | All 11 definitions match C.3 and 001: columns/defaults, 21 valid/live indexes, 35 validated constraints, eight expected application triggers, RLS enabled / FORCE disabled. No unexpected private relation/function. | Counts alone are insufficient. Any unexplained difference stops. |
| P06/P08/P09 security | Six roles present; two permit tables deny scoped DML/column writes; routing tables deny unintended writes; audit helper denies six-role EXECUTE; no unintended function EXECUTE inheritance. Worker roles retain NOLOGIN and no elevated attributes. Schema owner is postgres; schema access, trigger definitions and membership paths match reviewed boundaries. | Missing roles, unexpected memberships/grants, disabled/changed triggers or unexplained ACL/schema changes stop. PUBLIC effective grants are included by privilege helpers; review raw ACLs and global membership edges too. |
| P07 accelerated cutover | Ten C.3 cutover counters still zero; lifecycle status/expiry summaries show no unreviewed outstanding execution/reconciliation condition. Save source table counts. Existing CONFIRMED tasks/ACTIVE leases alone are not failures; they must remain valid and preserved. | Any nonzero dispatch/legacy/route/reconciliation counter leaves the accelerated zero-state lane. Review nonzero cases separately; do not recover, delete or rewrite them automatically. |
| P10 configuration | Exactly one singleton, values 360 minutes / 10 kg / 20000 m; baseline PostgreSQL 17.11, PostGIS 3.3.7 / pgRouting 3.4.1 in extensions, expected polymorphic many-to-many overload retained. Fleet seal comment/source metadata remain as C.1. | Version/config/metadata drift requires focused review. Matching versions are not runtime proof. A catalog seal observation does not recompute the full fleet fingerprint. |
| P11 history | Inspect application ledger only if present/visible with expected columns; reconcile release records with observed baseline. Missing ledger remains UNKNOWN. | Obtain trusted release evidence or explicitly approve the fully guarded state-based upgrade with the uncertainty documented. Do not fabricate ledger entries or infer history from internal component ledgers. |
| Runtime/recovery/operations | Address the C.5 risks below; approve unchanged 003 for this in-place state, maintenance window, verified recovery point and forward-repair plan. | Fresh catalog PASS alone is not deployment GO. |

Optional history follow-up, only after P11 confirms the relation and both columns, in an approved read-only DEV session:

```sql
BEGIN READ ONLY;
SELECT version,name FROM supabase_migrations.schema_migrations ORDER BY version,name;
ROLLBACK;
```

No graph scan, AI ranking work, fixtures, worker deployment, application RPC or test mutation is needed for this preflight. Active lifecycle totals are diagnostics, not blanket requirements that the database be empty.

## Commands — preparation/inspection and future execution

These commands are instructions only; none were run against DEV. Use `psql` with SSL verification configured by a pre-existing approved libpq service and securely stored credentials. `geolock_dev_readonly` and `geolock_dev_installer` are service-name placeholders, not configured connections. Have their endpoints and credential scope verified before use. Never put a password, DSN containing credentials, access token or service-role key on the command line or into Git. A Supabase service-role API key is not the required PostgreSQL installer session.

From the repository root, verify the exact artifact locally:

```powershell
$stage003File = (Resolve-Path 'docs/stage8/stage-a/forward-migrations/20261103_routing_pickup_and_reconciliation.sql').Path
$stage003Expected = '6541f0a002ea56ad77c023e33ad1500ab2273cc821f87fa43d38e633bd6724ea'
if ((Get-FileHash -LiteralPath $stage003File -Algorithm SHA256).Hash.ToLowerInvariant() -ne $stage003Expected) { throw '003 artifact drift: STOP' }
```

Fresh read-only inspection, after the approved read-only connection is available:

```powershell
psql -X --dbname='service=geolock_dev_readonly' --set=ON_ERROR_STOP=1 --file='docs/stage8/stage-a/deployment-preparation/preflight.sql' --output='results/stage-a003-preflight.txt'
if ($LASTEXITCODE -ne 0) { throw 'Preflight incomplete: STOP and inspect the error' }
```

Use a new timestamped evidence filename for later runs; do not overwrite prior evidence. Exit code zero only establishes query completion, not that every returned criterion passed. Missing read-only grants are an access blocker, not authorization for new grants.

**STOP HERE UNTIL SEPARATE EXECUTION APPROVAL AND ALL GATES ARE SATISFIED.**

After approval, using only the separately approved DEV installer, check its identity without modifying the database:

```powershell
psql -X --dbname='service=geolock_dev_installer' --set=ON_ERROR_STOP=1 --command="SELECT current_user,session_user,current_setting('transaction_isolation');"
if ($LASTEXITCODE -ne 0) { throw 'Installer identity check failed: STOP' }
```

Review that output manually. Then recheck SHA-256 and execute **one exact file once**:

```powershell
if ((Get-FileHash -LiteralPath $stage003File -Algorithm SHA256).Hash.ToLowerInvariant() -ne $stage003Expected) { throw '003 artifact drift: STOP' }
psql -X --dbname='service=geolock_dev_installer' --set=ON_ERROR_STOP=1 --file=$stage003File --output='results/stage-a003-execution.txt'
if ($LASTEXITCODE -ne 0) { throw '003 execution failed or is ambiguous: STOP; no retry' }
```

Do not use `supabase db push`, migration discovery, `--single-transaction`, `--echo-all`, a multi-migration bundle, or an MCP DDL tool. This artifact owns its BEGIN/COMMIT and sits outside automatic migration discovery. Its guards require a real postgres/postgres session, not SET ROLE from another login. The CLI failure exit closes its session, rolling back an uncommitted transaction; a lost COMMIT response remains ambiguous.

## Transaction and lock safeguards

Unchanged 003 uses one explicit transaction, a **5-second lock timeout**, **90-second per-statement timeout**, and `SHARE ROW EXCLUSIVE` on `public.pickup_tasks`. It drains conflicting task writers before legacy DISPATCHED capture and installs the trigger before commit. The 90 seconds is not a total migration deadline. Preserve the READ COMMITTED requirement; do not change timeouts or terminate blockers to force progress. Maintenance coordination must also prevent deployments/function replacement and lifecycle writers on related tables; the task lock alone is not a global maintenance lock.

All DDL, ACL changes and legacy capture should commit atomically. The existing file has embedded guards, but they are not comprehensive postflight validation and do not exercise deferred PL/pgSQL business paths. Do not patch this transaction to make a check pass.

## Expected read-only postflight

Keep writers paused and workers disabled. Run through the approved read-only DEV connection:

```powershell
psql -X --dbname='service=geolock_dev_readonly' --set=ON_ERROR_STOP=1 --file='docs/stage8/stage-a/deployment-preparation/postflight.sql' --output='results/stage-a003-postflight.txt'
if ($LASTEXITCODE -ne 0) { throw 'Postflight incomplete: keep maintenance; STOP' }
```

Acceptance requires all 17 POST01 function rows PASS and all 28 preserved baseline rows PASS, unchanged private table definitions, and exactly one enabled `routing_task_authority` BEFORE UPDATE OF task_status FOR EACH ROW trigger calling `routing_private.task_guard()` (tgtype 19). Pickup/close/cancel/read EXECUTE must be authenticated-only outside the owner; reconciliation must retain authenticated/service_role; private helpers must have no six-role or PUBLIC EXECUTE path. Verify inherited permissions, schema boundaries and unchanged existing triggers too.

Preserved source MD5s: `claim_listing=2c1f60c876797c61b44b3cb43591bab8`, `recover_expired_claims=89e01f42d5ec23bfcbcdc47c1f4fd4e5`, audit helper `67f27a85fb9129c9017bb0e9178f8ba1`. New pickup MD5s: start `cb306433867538804b67aa1a242867b4`, complete `26f0cd8cebe783c65b45e05649693860`; reconciliation `8cd1c3c183bb1af41bebc9094556a905`. The generated JSON/SQL supplies every other expected body and metadata field.

Under the accelerated zero-state lane, all ten cutover counters remain zero, `legacy_inflight` remains empty and all saved public source counts/status aggregates remain unchanged. No existing private table is recreated; only functions, the new trigger and intended ACLs change. In a separately reviewed nonzero lane, captured legacy task IDs must equal the locked DISPATCHED set exactly, with no duplicate/extra/missing capture; counts alone cannot prove set equality. This package does not authorize that lane or output its record identifiers.

Compare the captured C.1 fleet seal metadata and all unexpected schema/function/trigger differences. Record artifact hash, target, approval, timestamps, command exit status and complete pre/post evidence externally as a release record. Do not manufacture historical migration entries. Catalog postflight does not establish authenticated route, pickup or reconciliation runtime behavior; those require separately authorized synthetic integration tests.

## Unresolved C.5 runtime and data-integrity risks

C.5 executed zero SQL: local server startup failed. It is neither a runtime PASS nor evidence of a migration defect. No environment troubleshooting is proposed here.

| Unverified behavior | Concrete failure consequence | Minimum evidence needed before treating the risk as cleared |
|---|---|---|
| Full-schema compilation and deferred SQL/PLpgSQL dependency paths | DDL-time failure, or first real pickup/reconciliation call failing on an unresolved column/type/function even after successful installation. | Focused unchanged-003 application and affected business-path execution against the reviewed baseline on a suitable approved disposable runtime. |
| Legacy capture and writer/lock ordering | Uncaptured old dispatch, capture collision, blocked cutover, or a legacy pickup unable to complete. | Zero-state fresh cutover reduces exposure; nonzero or concurrent cases need dedicated synthetic capture/rollback/race evidence. |
| Transaction-bound task permits, cancellation and closure | Legitimate transition blocked, unauthorized transition accepted, or reservations released at the wrong lifecycle stage. | Positive/negative start, completion, cancellation, depot closure and rollback checks. |
| Two-party reconciliation, replay and whole-batch paths | Custody/task/lease/donation/inventory disagreement, duplicate bookkeeping, or stranded/manual-review records. | Successful/failed/replayed direct and whole-batch reconciliation plus all-or-nothing state/audit checks. |
| Effective ACL/RLS/Auth behavior | Intended actor denied or an unintended actor can invoke protected paths. | Catalog privilege checks plus approved authenticated boundary tests; catalog evidence alone cannot prove internal actor checks. |
| Failure atomicity, contention and performance | Timeouts/deadlocks, ambiguous commit outcome, or untested recovery from a partially observed deployment. | Guard-failure rollback and lock contention checks; verified recovery procedure. |
| Spatial-version and complete baseline equivalence | Later route integration can fail despite matching catalog signatures. | Matching-runtime targeted compatibility evidence; 003 itself does not directly pin PostGIS/pgRouting versions. B.2's separate correction evidence is not a prerequisite PASS for 003. |

To accelerate, scope any further validation to these affected 003 paths; do not rebuild unrelated AI ranking, graph benchmarks or the entire audit. If such validation is unavailable, the missing evidence remains an explicit NO-GO gate for this runbook. Merely accepting a deployment command does not resolve it.

## Failure handling and recovery

* **Preflight failure, denied access, partial state or drift:** stop, retain evidence, leave database untouched. No automatic repair, permission adjustment, guard change or migration replay.
* **Lock timeout or SQL error before confirmed commit:** stop without retry. `psql` with ON_ERROR_STOP exits and disconnects, rolling back its open transaction. In an interactive SQL Editor session, explicitly `ROLLBACK;` in that same session. Refresh read-only catalogs/counters to establish actual state; do not assume the application is healthy merely because transactional DDL rolled back.
* **Lost connection or missing COMMIT confirmation:** treat outcome as unknown. Inspect both pre- and post-function inventories, trigger identity and capture state with an approved read-only session before any further execution. Never blindly rerun the non-idempotent file.
* **Confirmed commit but failed postflight/runtime:** keep maintenance and workers disabled. Preserve errors/catalogs and use a separately approved forward repair or restore. Do not drop the task authority trigger or restore unprotected pickup bodies as an automatic rollback.
* **Recovery prerequisite before execution:** record a usable, recent DEV recovery point, its exact location/time, who can restore it, restoration scope (database versus Auth/Storage/external services), expected data-loss window and an approved restoration method. A backup file without restore evidence is insufficient. Restoration is a separate destructive operation requiring approval; no invented inverse SQL is supplied here.

Backend integration consequence: after 003, new pickup starts require validated managed-route authority. Existing clients calling start directly will fail closed until the backend route publication/authorization flow is available. Approval to install 003 must explicitly acknowledge this maintenance boundary. Do not enable workers or improvise graph/policy installation to resolve it. Preserve the reconciliation grant boundary and verify consumers use the existing signatures plus the two new read RPCs under separate integration authorization.

## Final decision and shortest next checkpoint

**NO-GO now:** fresh read-only DEV evidence is not collected, C.5 runtime/data-integrity risks remain unverified, recovery and maintenance readiness are not evidenced, and the unchanged file has not been approved for this exact in-place deployment. No new SQL defect is asserted.

Next: run the prepared read-only DEV preflight with an approved read-only connection, review only differences, resolve the focused runtime/recovery gates and migration-history uncertainty, then obtain explicit approval for the pinned single-file execution. This preparation stops here. The runbook does not execute or authorize any of those operations.

Evidence reused: `docs/stage8/stage-c1-manual/RESULTS.md`; `stage-c3/RESULTS.md` and its reviewed queries; `stage-c4/UPGRADE_DESIGN.md`; `stage-c5/RESULTS.md`; exact Stage A 001/002/003 forward files. `manifest.json` pins this package's generated checks. `build_readonly_checks.py` is an offline authoring helper, not a deployment runner.
