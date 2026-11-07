# Stage C.2 — Stage A 003 Pre-Deployment Compatibility Review

**Scope:** offline repository analysis using the reviewed Stage A 001/002/003 files and user-supplied Stage C.1 manual DEV catalog results. No Supabase connection, SQL execution, migration run, or database change was made.

**Verdict for direct execution of reviewed 003 without replaying 001/002: UNKNOWN — not established safe.** The observed DEV state is broadly consistent with Stage A 001/002 installed and Stage A 003 not installed. The absence of 003 objects is therefore expected for a pre-003 state, not evidence of corruption. However, exact prerequisite parity, route-record cutover state, private table privileges, and the full source/dependency inventory were not established. The Stage A README explicitly says an existing `routing_private` schema requires a separately designed upgrade. Do not execute the reviewed first-install package or infer that it is safe from the matching subset of fingerprints.

## 1. Stage A dependency map

| Stage | Role | Key dependencies / outputs | DEV evidence |
|---|---|---|---|
| 001 — `20261101_routing_authority.sql` | Creates first-install `routing_private` schema, worker roles, routing authority tables, immutability/RLS guards, graph freeze triggers, worker RPCs and private helper foundation. | Requires the C.1 `fleet_private` installation seal; expected baseline lifecycle function bodies/metadata; the original `assign_task_to_route` definition; coordination config. It explicitly rejects an existing `routing_private` schema and worker-role name collisions. | Fleet seal PASS. All 11 expected private tables and the 15 reported 001/002 helper names exist; worker roles exist; all 35 reported private constraints are present by corrected count. Exact table/column/constraint/function parity remains UNKNOWN. Existing schema means 001 must not be replayed. |
| 002 — `20261102_routing_publication.sql` | Adds routing publication/authorization, snapshot and candidate operations; changes direct assignment to fail closed pending validated publication; establishes worker grants. | Requires 001. Adds functions and depends on the 001 private tables/types and worker roles. It is not a standalone first-install migration. | `assign_task_to_route` has the reported post-002 fail-closed body MD5, owner/security/configuration and restricted ACL. `authorize_my_routing_candidate` exists and has the expected authenticated boundary. Query 10b/10c confirms the ten intended worker grants and no unintended grants among six inspected roles. This supports, but does not prove, complete 001/002 installation. |
| 003 — `20261103_routing_pickup_and_reconciliation.sql` | Adds protected route close/cancel, pickup start/completion replacements, task-status trigger, route authorization reads, legacy in-flight capture, and reconciliation route bookkeeping. | Explicitly requires 001 and 002. Pins current public lifecycle function sources and metadata, private donation-transition helper and its role boundary, post-002 assignment body, coordination config, postgres session and READ COMMITTED isolation. It takes a `SHARE ROW EXCLUSIVE` lock on `public.pickup_tasks`, captures currently `DISPATCHED` tasks into `routing_private.legacy_inflight`, installs `routing_task_authority`, and validates task-guard/private-table-privilege requirements. | Three existing function fingerprints match the expected pre-003 phase. Fourteen 003 signatures and its trigger are absent, as expected before applying 003. Required private DML privilege guard and actual in-flight task capture conditions are UNKNOWN. |

The package README says these forward files are review artifacts outside normal migration discovery, not applied-history evidence. It also says not to combine the historical old 003 with this rebased 003, and that an existing `routing_private` requires a separately designed upgrade: [Stage A README](../stage-a/README.md:32). Therefore the observed schema cannot be treated as a fresh 001 target.

## 2. DEV compatibility matrix

| Requirement / observation | Classification | Assessment |
|---|---|---|
| C.1 `fleet_private` seal | **PASS** | Computed fingerprint matched the stored v2 seal. This satisfies the recorded 001 prerequisite only. |
| `routing_private` first-install state | **MISMATCH for replaying 001; not a corruption finding** | Schema already exists. 001 explicitly raises `ROUTING_INSTALL_EXISTS_REVIEW_VERSION_INSTEAD_OF_REPLAY` when it exists (`20261101...sql:9`, also checks before schema creation). |
| 001/002 private table inventory | **PASS (presence only)** | All 11 expected private tables were reported. Exact columns, indexes, ownership, policies and all constraint definitions are not fully verified. |
| Private constraints | **PASS by reported count; UNKNOWN exact remainder** | Corrected total is 35 (11 PK, 15 FK, 6 UNIQUE, 3 CHECK); all validated, and all six UNIQUE definitions match 001. The other 29 definitions were not all supplied row-by-row. |
| 001/002 helper function inventory | **PASS by reported names; UNKNOWN exact parity** | The reported 15 names align with the expected pre-003 001/002 set. Row-level definitions, signatures and metadata for every function were not supplied. |
| `assign_task_to_route(uuid,uuid,integer)` | **PASS for 002 phase** | Reported body MD5 `047f2b5d6a4483b8cef8e3b91c9dc299`, owner `postgres`, SECURITY DEFINER, expected hardened config, `void` result, and postgres-only ACL match the fail-closed post-002 function required by 003 (`20261103...sql:36-40`). The differing SHA-256 from pre-001 is an expected phase change. |
| `start_pickup` and `complete_pickup` source preconditions | **PASS for 003 precondition; MISMATCH for current final permissions** | Reported MD5s, owner, security mode, volatility and result types match 003's pre-replacement source guard (`20261103...sql:11-23`). 003 is designed to replace these bodies and set authenticated-only grants. Current `anon` and `service_role` execute access is a pre-state mismatch with the final policy, but the migration has explicit revokes/grants at lines 211-212; this alone does not prove the earlier source guard will fail. |
| `submit_claim_reconciliation` source | **PASS for 003 source precondition** | Reported MD5 `246a...d194`, owner/security/config/result match the required source guard (`20261103...sql:345-350`). Its effective `service_role` permission remains **UNKNOWN** as to direct grant versus role inheritance and is preserved by `CREATE OR REPLACE`; 003 does not establish that boundary anew. |
| Other guarded lifecycle sources | **PASS as recorded preconditions** | `claim_listing`, `recover_expired_claims`, and six-argument donation-transition helper fingerprints/metadata were reported matching the 003 source guards. The helper was reported non-executable by the six inspected roles. |
| Coordination config | **PASS** | 360-minute lease, 10 kg direct threshold, 20 km radius were reported. |
| Worker role/function grants | **PASS within inspected scope** | All three roles and all ten intended function grants are present; all 50 unintended combinations are absent among `anon`, `authenticated`, `service_role`, and the three workers. This is not global role membership or privilege proof. |
| `routing_task_authority` and `task_guard()` | **EXPECTED ABSENCE PRE-003; NOT A PRE-003 BLOCKER BY ITSELF** | Both are created by 003 (`20261103...sql:110-132`). Their absence is consistent with a pre-003 installation. The 003 postcondition will require its own newly created guard/trigger. |
| Other 14 absent 003 signatures | **EXPECTED ABSENCE PRE-003; NOT A PRE-003 BLOCKER BY ITSELF** | They are objects 003 creates/replaces. Their absence does not indicate corruption. |
| Existing routing rows and 003 capture behavior | **UNKNOWN** | C.1 did not inspect counts or overlaps for `DISPATCHED` pickup tasks and `legacy_inflight`. 003 performs a plain insert of dispatched task IDs into `legacy_inflight` (`20261103...sql:130`); existing overlap or other state may affect execution. No row-level data was inspected. |
| 003 private table privilege guard | **UNKNOWN** | 003 rejects DML access by six roles to `routing_private.items` and `legacy_inflight` (`20261103...sql:363-367`). C.1 tested worker function EXECUTE, not these table privileges. |
| Migration history | **UNKNOWN** | Supabase migration ledger was absent/not visible. User recollection that 003 was not deployed is useful context, but not database migration evidence. |
| Exact 001/002 full installation and current dependency state | **UNKNOWN** | Evidence supports a 001/002-like state, but does not prove every guard, table attribute, constraint, ACL, dependency, route binding, or trigger body. |

## 3. Stage A 003 preconditions

The migration begins a transaction, sets local lock/statement timeouts, and obtains `SHARE ROW EXCLUSIVE` on `public.pickup_tasks` before its source guard (`20261103...sql:4-10`). Its initial guard requires:

1. `current_user` and `session_user` are `postgres`.
2. `start_pickup`, `complete_pickup`, `submit_claim_reconciliation`, `recover_expired_claims`, and `claim_listing` exist with pinned owner, SECURITY DEFINER, volatility, `search_path`, result type and body MD5 (`:11-23`).
3. Six-argument `geolock_transition_listing_donations` has the pinned owner, invoker status, `search_path`, and body MD5; none of the six inspected roles can execute it (`:24-34`).
4. `assign_task_to_route` is the post-002 pinned fail-closed body with owner, SECURITY DEFINER and hardened config (`:35-40`).
5. The singleton coordination row has a 360-minute lease, 10 kg threshold and 20,000 m radius (`:42-44`).
6. Required 001/002 tables/types/functions and compatible dependencies exist. C.1 confirms presence of a subset, not complete compatibility.
7. Under READ COMMITTED and postgres installation context, post-creation checks validate reconciliation/recovery sources, the newly created `task_guard` body and enabled trigger, and absence of DML privileges on `routing_private.items` / `legacy_inflight` for six roles (`:345-368`). These are in-transaction checks, not all pre-existing requirements.
8. The current `DISPATCHED` task set can be captured safely. The migration inserts those task IDs into `legacy_inflight` after taking the table lock so old writers cannot race the capture (`:7-9,130`). This actual data-state requirement was not inspected in C.1.

The observed `anon`/`service_role` grants on the two pickup functions are not an explicit initial source-guard predicate; 003 revokes the broad grants and then grants authenticated execution at lines 211-212. However, the migration's behavior for `submit_claim_reconciliation` preserves the existing function ACL, so its observed service-role effective permission needs a separate contract decision/role-membership check rather than an assumption that 003 will remove it.

## 4. Direct-003 deployment verdict

**UNKNOWN — cannot establish safe direct execution from the current offline evidence.**

The evidence is consistent with exactly the intended pre-003 phase: 001/002-like tables, helper names, worker grants and post-002 assignment body exist; the 003 functions and trigger do not. Thus the missing 003 objects are expected additions, not proof of corruption. The current lifecycle function hashes and coordination values also match key 003 preconditions.

But a successful precondition subset is not proof that 003 can execute safely. Required unknowns include the complete 001/002 object contract, private-table DML grants, the dispatched-task/legacy-inflight cutover state, all dependencies/overloads, and the effective reconciliation service-role boundary. C.1 did not establish a complete deployed-state manifest or migration history. Further, repository instructions explicitly require a separately designed upgrade when `routing_private` already exists. Consequently, this report does not say “003 is unsafe to run under all circumstances”; it says the reviewed migration is **not proven safe for direct execution against this DEV state**, and direct execution is not recommended or approved.

## 5. Non-destructive upgrade design options (not executable)

No SQL is proposed here. Subject to separate approval, a design review should consider:

**Option A — phase-validated 003 forward upgrade.** If subsequent read-only parity proves that the existing schema is the exact reviewed 001/002 state and all data/privilege guards can pass, derive a separately named upgrade artifact from 003 with explicit baseline fingerprint guards. Preserve the current tables and data; only create/replace the 003-owned functions/trigger and apply its reviewed ACL boundary. Retain the transaction and writer-drain behavior. Do not replay 001 or 002.

**Option B — compatibility migration for a divergent existing schema.** If any existing object differs, create a separately reviewed upgrade that maps the actual schema to the approved target. It must be additive or narrowly replacing, preserve all donation/claim/lease/task/route/binding/item/audit/reconciliation records, and explicitly handle legacy `DISPATCHED` tasks. Any transformation must have exact pre/post invariants and reject ambiguous states rather than silently discard, duplicate, or reclassify records.

Both options require a read-only baseline inventory first. No decision between A and B is made here.

## 6. Additional read-only inspection needed

Before a concrete upgrade design, collect through an explicitly approved read-only process:

- Exact definitions/signatures/owners/security/configuration/ACLs for all expected 001/002 functions and all dependencies used by 003; actual role memberships and inherited grants, especially `service_role` on reconciliation.
- Full columns, types, defaults, indexes, all constraints, policies, triggers, trigger definitions, relation ownership, and table privileges for relevant public/private tables. The current C.1 results do not provide complete definitions.
- Aggregate-only counts for active bindings/items, authorized/in-progress routes, `DISPATCHED` tasks, unresolved claim/reconciliation cases, `legacy_inflight` rows, and task-ID overlap between dispatched tasks and `legacy_inflight`. No personal data or row identifiers are needed for initial planning.
- Required extensions and function overload resolution for every Stage B.2 dependency; runtime remains a separate local test concern.
- Migration/release history from an approved source because the expected DB ledger was not visible. The user's recollection should be recorded, not substituted for DB/object evidence.

The four pickup `EXECUTE` grants are already a confirmed current-state mismatch. The six-role C.1 matrix provides no evidence for roles outside that set. No state-changing test or RPC is recommended as part of this inspection.

## 7. Proposed local testing strategy

After a separate approval, use a fresh disposable local PostgreSQL database for each controlled baseline, not DEV:

1. Compose a baseline from the current historical package plus exact Stage A 001/002, recording function/body/metadata/ACL and schema fingerprints.
2. Create a second local baseline from an anonymized catalog/data-shape fixture matching the C.1-observed pre-003 state, including representative already-existing routing records and both empty/non-empty legacy-inflight cases. No DEV data should be copied.
3. Validate 003's positive preconditions and expected rejection paths (source hash drift, config drift, wrong role/isolation, table privilege drift, overlapping legacy task capture) without weakening production guards.
4. Execute 003 only in disposable local baselines. Verify transaction rollback on every rejected precondition, exact expected function/trigger/ACL postconditions, and before/after counts/invariants for donations, claims, leases, pickup tasks, routes, routing bindings/items, reconciliation and audit records.
5. Exercise concurrent pickup writers around the lock/capture boundary and authorized route/pickup/recovery/reconciliation transitions with synthetic fixtures. Confirm the trigger blocks unauthorized status transitions and legitimate old in-flight completion follows the captured legacy path.
6. Compare both fresh-install composition and existing-schema upgrade composition. Local SQL compile/test success does not establish DEV parity or deployment approval.

## 8. Rollback and validation considerations

- Stage A 003 is a single explicit transaction and has local lock/statement timeouts; pre-commit failure should roll back its DDL and capture insert atomically. This transactional property must be verified in the approved local harness, not assumed from static inspection alone.
- Before any later approved deployment, require a reviewed backup/restore point and a read-only pre-deployment snapshot of relevant counts, state classifications, function/trigger definitions, ownership and privileges.
- A post-commit rollback is not simply “drop the trigger” or restore old pickup bodies: that could reopen unprotected task transitions. Require a reviewed forward-repair or compensating migration that preserves records and maintains a safe authority boundary.
- Post-change validation must include all catalog postconditions, effective role privileges, `routing_task_authority` enabled and attached to the expected function, legacy capture reconciliation, route/task/donation/claim state invariants, and application compatibility. A catalog-only PASS is not a full integration PASS.
- No rollback script, executable migration, or deployment action is included or approved by this assessment.

## 9. Recommended next approval checkpoint

**Approve a separate read-only prerequisite-completion stage** to collect the missing exact schema/function/ACL/dependency inventory and aggregate cutover counts, and resolve the `service_role` reconciliation privilege. Then prepare a distinct, non-executable upgrade design for review. Only after that design and local existing-schema compatibility tests pass should a separate deployment-parity approval be considered.

No DEV connection, query, migration execution, or database modification occurred for Stage C.2. This report stops at offline analysis and awaits review.
