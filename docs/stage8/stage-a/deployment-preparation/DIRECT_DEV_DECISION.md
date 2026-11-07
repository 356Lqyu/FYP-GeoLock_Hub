# Stage A 003 direct DEV — final approval checkpoint

26 October 2026, Asia/Kuala_Lumpur. **Final assessment: NO-GO to execute now; catalog prerequisites support considering unchanged 003 as the next migration, but current backup/recovery and operational gates remain open. NO-GO for claiming post-claim routing is enabled by 003 alone.**

The user elects direct DEV deployment and accepts the additional unvalidated C.5 runtime risk. No separate TEST/migration-compatibility environment was created or is required by this preparation. Restore-only validation is a separately prepared isolated procedure, not a migration test environment. No migration, RPC with business side effects, grant, cleanup, fixture, scheduler/worker activation or DEV data modification was executed. AI ranking is excluded.

## 1. Exact artifact/dependencies

File: `docs/stage8/stage-a/forward-migrations/20261103_routing_pickup_and_reconciliation.sql`

SHA-256 **`6541f0a002ea56ad77c023e33ad1500ab2273cc821f87fa43d38e633bd6724ea`**, rechecked unchanged during preparation. Use only this current Stage A 003, not historical integration/reconciliation alternatives. It requires the existing 001 authority schema/roles/tables/helpers and 002 validated publication contract, current lifecycle inputs and current C.1 fleet/public dependencies. 001/002 are already evidenced by catalog parity and must not be replayed. The first-install README's existing-schema warning is addressed by the C.4 in-place design plus this explicit single-file approval checkpoint; it does not prove runtime compatibility.

Order: existing verified 001/002 → separately approved exact 003 → read-only postflight → separately approved B.2 → separately approved B.4.3 Candidate 2. Do not change guards or automatically repair drift. B.4.3-before-003 changes the pinned claim source and is rejected by 003.

## 2. Fresh DEV observations and query evidence

User approved adding `read_only=true` to the MCP URL. Effective connection reports `current_user=session_user=supabase_read_only_user`, `transaction_read_only=on`, database postgres, PostgreSQL 17.11. MCP is pinned to DEV `rcgyuwiidqvrgbxswhqj`; it matches the migration, prior C.1/C.3 evidence and Flutter DEV configuration. No shared/production connection was used. Actual observation times: identity **19:22:14 MYT**, operational/history check **19:24:02 MYT**, 26 October. Evidence snapshots are point-in-time and must be refreshed inside the final coordinated maintenance window.

Saved results and exact grouped SELECT queries: `results/stage-a003-direct-preparation/`. Queries use explicit READ ONLY transactions and no business RPCs. The first grouped query failed before returning observations because the newly authored checker compared PostgreSQL `name[]` with `text[]`. The checker now casts ACL role names to text; the successful repeat below is retained. Only preparation/checker SQL changed; approved migration bytes did not.

| Area | Actual observation | Meaning |
|---|---|---|
| P02 baseline | **28/28 PASS**: signatures, source MD5, result, owner/security/volatility, exact config arrays, direct EXECUTE grantees. | Fresh definition-level evidence, not just object presence. |
| P03 source guards | **5/5 lifecycle PASS + audit-helper PASS**; post-002 assignment PASS in baseline. | Original claim/recovery/pickup/reconciliation inputs match 003. |
| P04 partial installation | All 14 added 003 signatures absent; authority trigger absent; three existing replacement functions retain pre-003 bodies. | Expected pre-003 state within this inventory, with no evidence of partial 003 in checked objects. Historical execution cannot be reconstructed from this alone. |
| P05 structure | 11 postgres-owned RLS private tables, 75 columns, 21 valid/live indexes, 35 validated constraints; eight enabled private application triggers. Full nested definitions captured. | Structure aligns with prior C.3 counts/intent; prior reviewed row-level definition comparison is reused. The result also includes 44 internal RI triggers; do not miscount those as application triggers. |
| P06 privileges | All 12 six-role/two-table DML checks false; reconciliation direct EXECUTE remains authenticated/service_role only outside owner, no observed inherited paths for those six principals. Audit helper owner-only. | Fresh scoped permit/security prerequisites satisfied. |
| P07 cutover | All ten counters **0**: dispatched, legacy rows/overlap/unmatched, active bindings/items/bound items, dispatched on active route, in-progress routes, unresolved cases. | No legacy DISPATCHED capture payload or active managed route at this snapshot. |
| Lifecycle freshness | Tasks: **2 CONFIRMED, 5 STALE**. Claims/leases: **2 ACTIVE, 5 RELEASED**. Both ACTIVE leases already expired. | The zero cutover counters are not proof that existing claims are route-eligible. Expired ACTIVE claims must not start/plan; no recovery was called. This does not itself cause the 003 DDL guard to fail. |
| P08 trigger/schema | 16 application triggers in the selected public/private scope, all enabled; expected `c1_route_vehicle_guard` present, `routing_task_authority` absent; private schema ownership/ACLs consistent. | Different scope from older wider trigger inventories; no claim that other tables have no triggers. |
| P09 refreshed scope | **74/74** returned table/column write predicates false. | User's prior 85/85 is retained as prior evidence; this is a different predicate grid, not an asserted recount of that earlier result. |
| P10 | One matching coordination singleton (360/10/20000), PostGIS 3.3.7 and pgRouting 3.4.1 in extensions; overload inventory and fleet fingerprint function metadata captured; C.1 seal comment retained. | Compatible with observed baseline assumptions. Fleet fingerprint was not recomputed; matching extension versions do not prove C.5 runtime behavior. |
| P11 | `supabase_migrations.schema_migrations` absent; version/name columns absent. Catalog discovery found only auth/realtime/storage component histories and indexes. | **Checked, historical execution remains UNKNOWN.** Cannot prove applied versions/timestamps or that an operator never ran/removed 003. Current 001/002 definitions match and checked 003 objects are absent. Do not fabricate ledger entries or treat component migrations as GeoLock history. |
| Routing service inputs | Policies **0**, graphs **0**, matrices **0**, snapshots **0**, candidates **0**, validations **0**, vehicles **1**. | 003 installs enforcement/read/pickup behavior; it does not initialize/activate a policy/graph/planner/validator or guarantee this vehicle is eligible. |

Other captured source totals: 7 pickup tasks, 7 claims, 7 leases, 0 routes/stops/active assignments/reconciliation cases, 58 audit events, 10 donations, 6 listings. These are preserved aggregate observations, not a new backup or cryptographic row-integrity proof.

## 3. Outstanding deployment/enablement gates

1. **New pre-003 backup not captured.** The old 22 October archive lacks routing_private/fleet_private TOC entries and is not the current recovery point. MCP cannot stream a full archive/globals; no approved PostgreSQL backup service/credential is available here. Exact new full-database/role-export commands, coverage checks and encrypted/private storage guidance are in `BACKUP_AND_RECOVERY.md`. No permission elevation or substitute credential was used.
2. **Recovery validation NOT VERIFIED.** No successful full restore record found. Backup readability is not restorability. Review the isolated restore-only procedure and managed-service exclusions. A destructive DEV restore requires separate explicit approval for its exact point/target/data-loss window; no DEV restore is authorized or attempted.
3. **P11 UNKNOWN requires an explicit release/state-based decision.** Historical application execution records are unavailable. Approve this exact guarded upgrade based on the fresh catalog evidence and an external release record rather than representing a missing ledger as PASS.
4. **Installer and maintenance not verified.** A dedicated approved DEV installer connection must be postgres/postgres, READ COMMITTED. No such connection was used/provisioned here. Agree who stops/drains claim, pickup, route/planner, reconciliation and recovery writers and prevents concurrent deployments/function/role changes. Refresh preflight after the pause and keep it through backup/deployment/postflight; don't terminate sessions or disable security. Scheduler/worker control is a separate approved operational step.
5. **Post-claim routing enablement has additional prerequisites.** Empty policy/graph and unknown worker/validator activation must be resolved under separate approval before calling the feature operational. Existing expired ACTIVE claims need a separately reviewed normal recovery path or must remain unavailable; no deletion/reuse/test-fixture shortcut. The older exact-two recovery proposal has different recovery-body pins; do not run it blindly against current source.
6. **C.5 runtime remains NOT VALIDATED, accepted residual risk.** No separate compatibility TEST environment is imposed. Risks include deferred SQL/PLpgSQL dependency errors, authority/reconciliation/whole-batch edge behavior, cancellation/reservation correctness, lock contention, failure rollback and Auth/RLS behavior. Catalog checks and 49 Flutter mocked tests cannot clear these. Final approval must acknowledge the accepted residual risk and planned post-deployment test/containment scope.

These are factual missing evidence/access/operational prerequisites, not an automatic approval-review rejection. No migration defect was established. The user's risk acceptance does not constitute the final execution command approval or invent recovery evidence.

## 4. Exact deployment command for final approval

The SQL is the complete unchanged migration file itself. No corrective SQL, schema recreation, prior-migration replay or bulk `supabase db push` command is prepared. `geolock_dev_installer` below is a **placeholder libpq service that must first be configured and approved**, TLS/endpoint verified for this DEV project, credentials kept outside logs/Git. The current read-only MCP role cannot install 003 and will not be elevated.

From `C:\Users\User\Downloads\FYP-GeoLock_Hub`, **only after final approval** and the reviewed maintenance/backup checkpoint:

```powershell
$stage003File = (Resolve-Path -LiteralPath 'docs/stage8/stage-a/forward-migrations/20261103_routing_pickup_and_reconciliation.sql').Path
$stage003Expected = '6541f0a002ea56ad77c023e33ad1500ab2273cc821f87fa43d38e633bd6724ea'
if ((Get-FileHash -LiteralPath $stage003File -Algorithm SHA256).Hash.ToLowerInvariant() -ne $stage003Expected) { throw '003 hash drift: STOP' }
# Endpoint is verified out of band; confirm the actual installer session first.
psql -X --no-password --dbname='service=geolock_dev_installer' --set=ON_ERROR_STOP=1 --command="SELECT current_user,session_user,current_setting('transaction_isolation');"
if ($LASTEXITCODE -ne 0) { throw 'Installer check failed: STOP' }
# Review postgres / postgres / read committed, fresh preflight and backup evidence.
$stage003ExecutionLog = 'results/stage-a003-execution-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '.txt'
psql -X --no-password --dbname='service=geolock_dev_installer' --set=ON_ERROR_STOP=1 --file=$stage003File --output=$stage003ExecutionLog
if ($LASTEXITCODE -ne 0) { throw '003 failed or outcome ambiguous: STOP; do not retry' }
```

This is not executed. No credentials are included. Review/approve the whole single-file operation, not individual statements. Do not use `--single-transaction`: the file already has BEGIN/COMMIT. Preserve 5s lock timeout, 90s per-statement timeout, SHARE ROW EXCLUSIVE task lock, capture-before-trigger order and every embedded guard. Source changes or lock timeout mean stop, not retry with bypasses.

## 5. Flutter impact and changes implemented

Claim RPC already creates pickup_task atomically. The old direct `assign_task_to_route` is intentionally blocked by 002. Route creation/assignment belongs to NGO snapshot + real worker/validator + protected `authorize_my_routing_candidate`, not client writes or automatic claim-side assignment.

003 changes pickup starts: an ACTIVE claim or CONFIRMED/PLANNED status alone no longer suffices. `start_pickup` requires a managed binding, valid next stop/departure/source/lease and transaction-bound permit. Any old client directly calling start will fail with `DATABASE_DISPATCH_AUTHORIZATION_REQUIRED`. Current production My Claims already blocked direct mutation, but displayed disabled legacy buttons and indirect route access. Completion without managed authority only has the captured legacy-inflight path; fresh P07 found no such tasks. Existing route UI cannot display a managed binding for arbitrary uncaptured legacy tasks; any future nonzero legacy population needs separate operational/UI review.

Safe local changes:

* `lib/donation_pages.dart`: actionable Pickup routes on active claim cards, refresh claims after returning from routes, clear claim-success instruction and route-planning status; production direct pickup/complete buttons removed, injected test transport retained. Claim details, cancel and reconciliation remain available under their existing rules.
* `lib/routing/ngo_routes_page.dart`: explicitly show unavailable planning policy and prevent Generate until a policy exists; show friendly dispatch-block reason from actual protected detail response. Existing assigned-route list, backend flags and fresh read before pickup remain authoritative.
* `lib/routing/ngo_routing_repository.dart`: map actual authority/ownership/reconciliation/departure/remaining-route errors to actionable text. No new RPC names/states, direct table writes, credentials or schema changes.
* `test/claim_card_test.dart`, `test/ngo_routing_test.dart`: navigation/refresh/no-policy/block-reason/completion/close/cancel regressions; existing tests adjusted for removal of production legacy buttons.

Verified actual lifecycle: claim → CONFIRMED task → independently validated NGO-authorized publication → PLANNED task / AUTHORISED route → DISPATCHED task / IN_PROGRESS route / donation PICKUP_IN_PROGRESS → COLLECTED task/donation + COMPLETED claim/lease + CLOSED listing → explicit depot-return route COMPLETED/release. Cancellation is only unstarted, returns tasks CONFIRMED and keeps claims. Reconciliation uses existing participant RPC and must not auto-close a route. Full exact payloads and tests are in `POST_DEPLOYMENT_TESTS.md`.

## 6. Verification and recovery

Actual local verification: **49 focused Flutter tests PASS; analysis of all five changed Dart files reports No issues found.** No real Supabase business calls were made by tests. The first old-button test failure was corrected to the intended managed workflow before the passing rerun. No new server/compatibility environment was created.

After separately approved 003, run `postflight.sql` via approved read-only DEV access and compare all returned conditions, source tables, ACLs, old trigger preservation and the exact new authority trigger. Then use the approved synthetic-only DEV procedure T01–T12 in `POST_DEPLOYMENT_TESTS.md` for route publication/authorization/visibility/start/completion/cancel/reconciliation/unauthorized operations/transaction rollback and donation/claim regressions. No fixture, failure-injection DDL or worker activation is authorized by the migration approval alone; scope those explicitly. Do not replay 003 to test rollback.

Before commit: ON_ERROR_STOP disconnects a failed one-shot session and rolls its open transaction back; an interactive aborted transaction needs ROLLBACK in that same session. Lost COMMIT response: fresh read-only inspection before any rerun. After commit: keep writers/workers paused, preserve diagnostics, approve a state-specific forward repair or provider-supported restoration. Never automatically drop task authority, restore bypass pickup bodies or overwrite current DEV data. Restoration requires a verified recovery point and separate explicit approval; full limitations/procedure are in `BACKUP_AND_RECOVERY.md`.

**Stop point:** command prepared, migration unchanged, read-only DEV observations retained, Flutter fixes locally verified. Await review of backup/recovery/maintenance/history decisions and separate final command approval. 003 is not executed.
