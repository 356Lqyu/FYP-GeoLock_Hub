# Stage C.4 — Stage A 003 In-Place Upgrade Design

**Status:** Offline design only. No database connection, SQL execution, local test, migration, or deployment was performed.

**Target evidence:** User-run Stage C.1/C.3 catalog results for DEV project `rcgyuwiidqvrgbxswhqj`; reviewed Stage A forward migrations; Stage C.2 assessment; Stage B.2 and B.4.3 reports.

## Executive decision

### Direct deployment verdict: NO-GO

Do not execute Stage A 003 directly on DEV at this checkpoint. The verified 001/002 source parity is strong evidence that the existing `routing_private` schema matches the reviewed baseline, but the Stage A README explicitly says an existing `routing_private` requires a separately designed upgrade (`docs/stage8/stage-a/README.md`, “Review artifacts and changes”). The application migration history remains unknown, some 003 runtime/session preconditions are not established, and the reviewed 003 artifact is still a forward-review file rather than an approved in-place upgrade package.

The design direction is a **separately reviewed in-place upgrade package** based on the reviewed Stage A 003 operations and guarded against the now-verified 001/002 baseline. Local testing should first determine whether the reviewed 003 SQL can be reused verbatim against that exact baseline or whether a narrowly scoped compatibility delta is required. Either way, it must not replay 001 or 002, rebuild existing tables, infer migration history, or weaken current coordination authority. No executable SQL is prepared in this document.

### Local testing recommendation: GO for a separate approval checkpoint

The current evidence is sufficient to design and request disposable local PostgreSQL testing of the compatibility-upgrade approach. This is not authorization to begin that testing, deploy Stage A 003, or access DEV. Local tests must first reproduce the reviewed baseline and must retain every precondition and authority guard.

## 1. Reviewed evidence and baseline

| Evidence | Result | Design consequence |
|---|---|---|
| C.3 Query 1: 28 Stage A 001/002 functions | **PASS, 28/28** for signature, body MD5, return type, owner, security mode, volatility, hardened configuration, and ACL against the reviewed phase definitions. Assignment is checked at its post-002 fail-closed body. | The function baseline used by the proposed upgrade is now evidenced by supplied catalog output. This is source parity, not a migration ledger or runtime test. See `docs/stage8/stage-c3/RESULTS.md`, Query 1. |
| C.3 Query 2: 11 `routing_private` tables | **PASS, 11/11** for the reported structure; 75 columns, 21 indexes, 35 validated constraints, RLS enabled, FORCE RLS disabled, and expected application triggers. | The earlier 19-index count was a recount error; complete JSON contains 21 expected indexes with matching names/definitions. See C.3 Query 2. |
| C.3 Query 3 and 4 | **PASS within inspected role/object scopes** for private-table DML and reconciliation ACL/membership findings. | These support guards, but do not cover every role, grant source, or database object. |
| C.3 Query 5 | **PASS, point-in-time only:** all ten operational counts were zero. | No active legacy dispatch/route state was observed then. Recheck at any future approved cutover; counts can change and do not predict future state. |
| C.3 Query 6 | Alternate migration-relation discovery completed; GeoLock migration history **UNKNOWN**. Returned `auth`, `realtime`, and `storage` component history objects are not GeoLock migration evidence. | Determine upgrade eligibility from a fresh, reviewed object/state preflight as well as any available release records. Do not read or treat the component ledgers as GeoLock history. |
| C.1 findings retained in C.3 results | 14/17 expected Stage A 003 signatures were absent; the three existing pickup/reconciliation functions were still at their pre-003 bodies; `routing_task_authority` was absent. Stage B.2 and Stage B.4.3 Candidate 2 functions remained at pre-correction fingerprints. | Consistent with the recorded pre-003/pre-correction state. It does not alone prove no manual or partial deployment occurred. |

The Stage A 001 first-install migration explicitly rejects an existing `routing_private` schema (`docs/stage8/stage-a/forward-migrations/20261101_routing_authority.sql:9,46-48`). The reviewed 001/002 files therefore must not be replayed against this DEV schema. Stage A 002 depends on 001; the schema and function parity now confirmed supports that baseline comparison, but missing application migration history remains unresolved.

## 2. Stage A 003 prerequisites and cutover transaction

Reviewed source: `docs/stage8/stage-a/forward-migrations/20261103_routing_pickup_and_reconciliation.sql`.

### Preconditions

The current migration begins a transaction, sets a 5-second `lock_timeout` and 90-second `statement_timeout`, then acquires `SHARE ROW EXCLUSIVE` on `public.pickup_tasks` before running its initial source guard (`:4-10`). It requires:

1. `current_user='postgres'` and `session_user='postgres'` (`:10-11`). The previously reported SQL Editor role does not independently prove both values for a future execution session.
2. Exact pre-replacement body MD5, owner, `SECURITY DEFINER`, volatility, search path, and return type for `start_pickup`, `complete_pickup`, `submit_claim_reconciliation`, `recover_expired_claims`, and `claim_listing` (`:12-23`). C.1 source fingerprints match the pre-003 values. The future upgrade preflight must repeat these checks immediately before execution.
3. Exact six-argument `geolock_transition_listing_donations` body and metadata, with no EXECUTE to the six inspected roles (`:24-34`).
4. `assign_task_to_route` at the post-002 fail-closed MD5, owner, security mode, and hardened configuration (`:35-40`). C.3 confirms the reviewed post-002 definition.
5. Singleton coordination values: 360-minute lease, 10 kg threshold, and 20,000 m radius (`:42-44`).
6. Stage A 001/002 dependencies, role/object contracts, and a `READ COMMITTED` session. The transaction rechecks isolation after installation (`:341-368`); the current session isolation has not been evidenced for a future run.
7. No unexpected partial 003 installation. `CREATE FUNCTION` and `CREATE TRIGGER` statements are not generally idempotent. A detected subset of 003 objects must stop for manual review rather than be silently accepted or overwritten.
8. At cutover, the `DISPATCHED` task set can be inserted into `routing_private.legacy_inflight` without a primary-key collision. The migration's `INSERT ... SELECT` has no conflict-ignore behavior (`:129-132`); a duplicate fails and rolls back the transaction. Query 5 saw zero dispatched and zero legacy rows only at its inspection time.

The post-install guard checks the reconciliation and recovery bodies, the exact `task_guard` body and enabled trigger, and absence of table-level INSERT/UPDATE/DELETE access for six roles on `routing_private.items` and `legacy_inflight` (`:339-368`). C.3 Query 3 supports the inspected privilege predicate. A new preflight must re-evaluate the same predicate on the actual target roles and tables.

### Transaction contents and authority changes

| Operation | Reviewed behavior | Risk/validation focus |
|---|---|---|
| Lock and drain task writers | The transaction's `SHARE ROW EXCLUSIVE` lock conflicts with task writers and remains held through commit (`:7-9`). | Existing writers can make lock acquisition wait; exceeding 5 seconds aborts. No process/session should be terminated to force the lock. Establish a maintenance window and measure lock duration in local tests. |
| Legacy task capture | Inserts every currently `DISPATCHED` task into `routing_private.legacy_inflight` before installing the authority trigger (`:129-132`). | Preserves already-dispatched pickups so they can complete; does not grant new legacy starts. Verify exact capture count, uniqueness, and completion path. Any overlap/insert failure rolls the whole transaction back. |
| New private functions | Creates route locking/closure, cancellation, task guard, remaining-route feasibility, and reconciliation participant/scope/permit/bookkeeping helpers (`:45-71`, `:83-178`, `:371-490`). | These functions are part of the authority boundary. Check body fingerprints, ownership, `SECURITY DEFINER`, search paths, and private EXECUTE isolation. |
| Task-state trigger | Installs `routing_task_authority` on `pickup_tasks.task_status` (`:110-132`). It requires transaction-bound dispatch/completion permits and constrains reserved-task transitions. | Test direct unauthorized transitions, valid route permits, captured legacy completion, release/cancel transitions, and rollback. Verify enabled status and trigger function identity after commit. |
| Pickup function replacements | Replaces `start_pickup`/`complete_pickup` so a start requires managed route authorization, while completion handles a managed item or previously captured legacy task (`:179-209`). | Public function signatures remain unchanged. Check authorized NGO, listing/task/vehicle/route binding, active lease, schedule, capacity, time window, order and repeated-call outcomes. |
| Pickup/route ACLs | Revokes PUBLIC/anon/authenticated/service_role and grants `start_pickup`, `complete_pickup`, route close/cancel only to `authenticated` (`:210-212`). New routing read RPCs are also authenticated-only (`:215-266`). | This intentionally removes the reported `anon` and `service_role` pickup EXECUTE grants. Verify effective access and role inheritance, not only direct ACL text. |
| Legacy bodies | Copies current pickup bodies into hardened `routing_private.legacy_*` functions, retaining business transitions and audit writes, while changing function name/schema and execution settings (`:267-336`). | Confirm exact body equivalence to the current source apart from the documented schema/name/config transformation; verify audit events and legacy completion are atomic. |
| Reconciliation replacement | Adds participant scope locking, request replay, transaction-bound collection permit, route/legacy collection bookkeeping, and private helpers; preserves the current reconciliation body/audit contract outside reviewed additions (`:371-708`). | `CREATE OR REPLACE` preserves the existing reconciliation function ACL; the observed `authenticated` and `service_role` boundary should remain as separately approved. Verify two-party evidence, same-key replay, route binding, legacy completion and all-or-nothing custody updates. |
| Commit | One `COMMIT` ends the migration (`:710`). | Pre-commit errors should roll back all DDL, grants, trigger creation, and captured rows. Test this on a disposable database. Post-commit rollback must be a separately designed forward repair, not dropping the trigger or restoring unprotected functions. |

No `routing_private` business tables are recreated or cleared. The planned cutover data change is additive legacy-task capture. Donation, claim, lease, route, binding, item, history and audit rows must remain intact. The zero-count result lowers the observed cutover payload but does not remove the capture path or its concurrency requirements.

## 3. Ordering and compatibility with later corrections

| Artifact | Effect and source precondition | Relationship to Stage A 003 | Recommended order in a future, separately approved local package |
|---|---|---|---|
| Stage A 001/002 | First-install authority schema and publication; Query 1/2 now match the inspected existing baseline. 001 refuses an existing `routing_private`. | Do not replay on an existing schema. Use as local baseline/reconstruction only. | Existing baseline is treated as 001/002; never replay them in DEV. |
| Stage A 003 | Pins the pre-Stage-B.4.3 `claim_listing` MD5 `2c1f60c876797c61b44b3cb43591bab8` in its source guard (`20261103...sql:12-23`). | Candidate 2 changes `claim_listing` to MD5 `c8d324772b12c843fba231e7ea733914`. Running B.4.3 first causes the 003 source guard to reject the new body. | **003 before B.4.3 Candidate 2** unless a separate compatibility revision deliberately recognizes and verifies both approved bodies and their lock behavior. Do not change the authority guard without separate review. |
| Stage B.2 spatial correction | Replaces `geolock_resolve_road_node` and `geolock_road_costs`; requires exact pre-correction body/metadata, policy/config, an approved operational road snapshot, and a supported pgRouting overload (`docs/stage8/stage-b2/forward-migrations/20261104_spatial_endpoint_validation.sql:13-42,56-132`). | Stage A 003 does not replace or pin these helpers; no direct source-hash conflict is identified. DEV reports the original bodies and five pgRouting overloads including the polymorphic many-to-many signature. But DEV's PostGIS 3.3.7/pgRouting 3.4.1 differs from B.2 local test PostGIS 3.6.2/pgRouting 4.0.1; current parity for the required operational snapshot and runtime compatibility remain unknown. | Treat B.2 as a separate, guarded correction after the 003 compatibility test, then verify its own preconditions/runtime on matching disposable extension versions. A source-level order before 003 appears independent, but should not be bundled into the first 003 upgrade test. |
| Stage B.4.3 Candidate 2 | Replaces only `claim_listing` and `geolock_lock_listing_donations`; Candidate 2 uses `FOR NO KEY UPDATE` in both relevant lock sites (`docs/stage8/stage-b4-3/migrations/20261105_b43_claim_and_donation_lock_no_key_update.sql:1-5,30-219`). | `claim_listing` hash conflict with 003 precondition as above. 003 does not replace either claim function. | Apply/test after 003. Candidate 2's local 2/5/10 actor and 18/18 regression evidence remains local evidence, not DEV deployment evidence. |

**Recommended logical order for a future local composition:** verified 001/002 baseline → Stage A 003 compatibility upgrade → Stage B.2 correction (independent but separately guarded) → Stage B.4.3 Candidate 2. B.4.3-before-003 is explicitly rejected by the known source pin. This is a test/dependency recommendation, not a deployment schedule.

## 4. Missing migration history

No `supabase_migrations.schema_migrations` relation was observed; Query 6 found only Supabase internal component history relations. Therefore the repository cannot establish whether the forward package, a prior variant, or operator-run SQL was applied and later changed. The observed 003 absence and 001/002 fingerprints are strong state evidence, but they do not replace a GeoLock release ledger.

For the design, maintain two separate proofs:

1. **Artifact/release record:** exact migration artifact hash, reviewed manifest, approval and execution record kept with release evidence.
2. **Database postcondition record:** source/catalog fingerprints and state invariants after commit.

Do not insert fabricated historical entries into Supabase component ledgers. Do not create a new application ledger inside this design; any future migration tracking mechanism is a separate governance choice. Before deployment approval, perform a fresh read-only object-state and privilege preflight. If any partial 003 object exists, stop and design repair for that exact state; do not mark it applied or replay blindly.

## 5. Proposed non-destructive upgrade approach (design only)

1. **Reconfirm the baseline immediately before any future local or DEV execution.** Verify exact 28-function phase fingerprints/metadata/ACLs, all 11 private table definitions and indexes, required public dependencies/columns/triggers, worker roles/memberships, coordination configuration, and 003 object absence/presence as a complete set. Reject unexpected objects rather than trying to normalize them automatically.
2. **Reconfirm operational cutover state.** Obtain fresh aggregate counts for dispatched tasks, existing legacy rows/overlap, active bindings/items, in-progress routes, and unresolved reconciliation cases. Preserve the exact result and timestamp. A nonzero state is not automatically unsafe, but each case must be represented in local fixtures and satisfy the migration's insertion/authority invariants.
3. **Use a separately reviewed upgrade artifact.** Derive a distinct, explicitly approved compatibility-upgrade package from the reviewed 003 contents. It must retain the transaction, source guards, writer-drain lock, capture-before-trigger ordering, postconditions, all authority checks and intended ACL boundaries. It must not replay 001/002 or recreate tables. No idempotent “skip existing” clauses should conceal partial state.
4. **Protect the execution window.** Require PostgreSQL 17-compatible behavior, `postgres` as current and session user, `READ COMMITTED`, maintenance coordination with active pickup writers, the existing 5-second lock timeout and 90-second statement timeout unless a separately reviewed change is approved. Abort cleanly on lock contention or any source/data guard failure.
5. **Commit only when the entire postcondition set passes.** Keep task capture, trigger installation, function replacements, privileges and reconciliation bridge atomic. Do not permit shadow writes, worker activation, or client status writes as a shortcut.
6. **Keep later patches separate.** After 003's postflight, validate/apply B.2 separately under its own spatial source and extension guards; then apply Candidate 2 only after its pre-correction source guard still matches. No combined blind bundle.

## 6. Disposable local PostgreSQL test plan (not run)

The following is the proposed scope for a **separate approval checkpoint**. Use fresh disposable databases only, loopback/random-port connections, synthetic data, no DEV exports, and versions matching DEV where available: PostgreSQL 17.11, PostGIS 3.3.7, pgRouting 3.4.1. If those extension builds are unavailable, report the difference and do not claim extension parity. No final Chapter 5 runs belong in this stage.

### A. Baseline assembly and compatibility

- Compose the current historical schema through 20261031 plus the reviewed Stage A 001/002 forward artifacts in a fresh database, preserving the exact migration order and recording hashes. Apply the reviewed Stage A 003 source unchanged as the first candidate to determine whether it works verbatim after the verified baseline; do not modify it to make a failure pass.
- Confirm the 28 function body/metadata/ACL contracts, 11 private table definitions, 21 indexes, 35 constraints, enabled triggers, RLS flags, worker grants, and required public dependencies before Stage A 003.
- Build an additional “already-existing 001/002 schema” scenario by applying the same approved source baseline once and adding only synthetic routing records; never copy DEV records. It should model the observed catalog state, including an empty legacy table and zero active route state, plus synthetic nonzero cutover cases.
- If 003 runs unchanged, local evidence supports considering verbatim reuse inside the separately reviewed in-place upgrade package. If it rejects or behaves differently, preserve the failure and design a minimal guarded compatibility delta for separate review; do not weaken or bypass the guard. Compile/execute only after a separate local-testing approval. Do not run this plan as part of Stage C.4.

### B. Precondition failures and atomic rollback

In independent disposable databases, deliberately violate one precondition at a time: source-body drift, metadata/config drift, wrong installer identity, non-READ-COMMITTED isolation, private-table DML grant drift, incomplete/partial 003 objects, and a legacy-task capture collision. Confirm each attempt fails with its intended guard and leaves no new functions, trigger, ACL changes, legacy rows, or other partial state. Restore by recreating the disposable database, not by automatic repair.

### C. Lock ordering and legacy capture races

- **Writer commits first:** hold a transaction that changes a synthetic confirmed task to `DISPATCHED` using the pre-003 test path; start migration and verify the committed task is captured exactly once in `legacy_inflight`.
- **Migration locks first:** hold the migration's task lock while an old writer attempts a task-state update. Verify it waits; after commit the task guard rejects an unauthorized new dispatch. No old start may commit between capture and trigger activation.
- **Lock timeout:** hold a conflicting writer lock beyond the configured bound; verify 003 aborts and rolls back. Measure lock wait and total transaction duration with representative synthetic volume.
- **Legacy completion:** verify a captured dispatched task can complete only through the legacy completion path with active claim/lease and participant checks; reject legacy start, uncaptured completion, duplicate completion, expired lease and unauthorized actor.
- Verify all rows inserted into `legacy_inflight` correspond exactly to the pre-lock DISPATCHED snapshot and no unrelated task is captured.

### D. Route authorization, pickup, cancellation and closure

Use direct-pickup synthetic fixtures first, then separate whole-batch fixtures only if the local full-schema harness supports them. Verify:

- no direct assignment or task-status update bypasses the authorized route binding;
- correct NGO, task, listing, vehicle, route, validation reference, active lease, schedule, capacity, time window, stop order and maximum route-duration checks;
- permitted first pickup changes route/task/donation state atomically and consumes a transaction-bound dispatch permit;
- completion requires a prior start, valid handover and live authority; repeated requests do not duplicate transitions/audits;
- completion does not release route reservations; close requires explicit depot-return confirmation and releases only that route's reservations;
- unstarted cancellation archives stops and safely releases planned items; started or stale routes require reconciliation;
- foreign NGO/vehicle/route, expired lease, forged route/candidate, incomplete batch, invalid capacity/window/duration, duplicate permit and injected audit/business write failure all reject or roll back without partial state.

### E. Reconciliation and security

- Exercise positive and negative two-party reconciliation for captured legacy and managed-route tasks; verify same-request replay, request-ID misuse, mismatched evidence, partial batch states, manual-review routing, source donation/inventory updates, permits and route-item bookkeeping.
- Assert every error leaves evidence, donation, inventory, claim, lease, listing, task, route, audit and routing-item state transactionally consistent.
- Compare effective EXECUTE and DML grants before/after for PUBLIC, anon, authenticated, service_role, three workers and any fixture roles. Specifically confirm pickup RPCs become authenticated-only and reconciliation retains its approved authenticated/service_role boundary.
- Ensure RLS, private schema access, owner, SECURITY DEFINER search paths, triggers, worker grants and existing task/route guards remain intact.

### F. Correction ordering and post-upgrade checks

- Apply Stage A 003 first, then verify Stage B.2's original source guards still match and run its correction only in a separate disposable test database using the DEV extension versions.
- Apply B.4.3 Candidate 2 after 003. In a separate test, apply Candidate 2 first and confirm Stage A 003's original claim-source guard rejects it; do not loosen the guard in the test.
- Postflight exact signatures, function body hashes, metadata, ACLs, table privileges, trigger function identity/enabled state, and counts/invariants. Confirm route data and all existing donation/claim/lease/task/route/audit rows are preserved, except the expected additive legacy capture in its synthetic case.
- Re-run targeted current-schema regressions and retain raw SQL, server logs, lock/process evidence, before/after catalogs, fixture manifest, operation ordering and checksums. Do not represent these engineering checks as Chapter 5 experiments.

## 7. Rollback, recovery and deployment gates

- **Before commit:** PostgreSQL transaction rollback should undo all DDL, function replacements, grants, trigger creation and capture inserts. Verify this for every precondition/error case in the disposable database.
- **After commit:** There is no safe automatic inverse. Dropping `routing_task_authority` or restoring the old public pickup functions would reopen unauthorized task transitions. Any production rollback requires a separately reviewed forward-repair/containment plan that preserves the new authority boundary and all data.
- **Before any future DEV deployment review:** resolve the unknown application migration history as far as possible; repeat a complete read-only current-state preflight; confirm actual session identity/isolation; refresh cutover counts; review exact postflight predicates; establish maintenance/lock timing and backup/restore plans; approve the exact artifact hash and order. This design itself grants none of those approvals.
- **After any separately approved future deployment:** manually verify the deployed artifact hash, source functions, route trigger, function ownership/security/config, role grants and membership, private DML boundary, legacy capture counts, and state/audit invariants. Reconcile any difference before enabling workers or relying on routing UI.

## 8. Remaining blockers and approval recommendation

| Blocker | Classification | Required resolution |
|---|---|---|
| Application migration history | **UNKNOWN** | Obtain a trusted GeoLock release/execution record or accept an explicitly state-based, fully guarded upgrade process in a separately approved design. Supabase component ledgers do not resolve it. |
| Public dependency/runtime compilation | **NOT VERIFIED** | Local full-schema compile and execution using PostgreSQL/extension versions matching DEV, including all public tables, triggers, helper functions and deferred PL/pgSQL call paths. |
| Session identity/isolation and lock feasibility | **NOT VERIFIED for a future run** | Test in disposable local DB and re-confirm in any later approved preflight; do not assume SQL Editor's prior role snapshot applies to future execution. |
| Cutover data freshness | **PASS only at prior inspection time** | Recount immediately before any future approved deployment; exercise nonzero and conflict cases locally. |
| Stage B.2 runtime compatibility | **UNKNOWN** | The expected pgRouting overload was observed but local B.2 used newer extension versions. Verify on equivalent disposable versions. |
| Stage B.4.3 order | **Known hard dependency** | Keep Candidate 2 after 003 or separately review a source guard that accepts and verifies the candidate body. Recommended order is after 003. |
| In-place upgrade artifact and rollback | **DESIGN ONLY** | Review and approve a separate compatibility-upgrade package, operational plan, pre/postconditions and forward-repair strategy before any execution. |

**Recommendation:** **NO-GO for direct Stage A 003 execution or DEV deployment. GO to request a separate approval for the disposable local PostgreSQL test plan above.** If tests pass, prepare a distinct compatibility-upgrade artifact and deployment-parity review; do not execute the reviewed 001/002 first-install chain on the existing DEV schema.

## Sources reviewed

- `docs/stage8/stage-a/README.md`, `SYSTEM_VERIFICATION.md`, `ROADMAP.md`, `CHAPTER5_READINESS.md`.
- `docs/stage8/stage-a/forward-migrations/20261101_routing_authority.sql`, `20261102_routing_publication.sql`, `20261103_routing_pickup_and_reconciliation.sql`.
- `docs/stage8/stage-c2/ASSESSMENT.md`, `REPORT.md`; `docs/stage8/stage-c3/RESULTS.md`.
- `docs/stage8/stage-b2/REPORT.md`, `forward-migrations/20261104_spatial_endpoint_validation.sql`.
- `docs/stage8/stage-b4-3/REPORT.md`, `migrations/20261105_b43_claim_and_donation_lock_no_key_update.sql` (Candidate 2; Candidate 1 explicitly rejected).
