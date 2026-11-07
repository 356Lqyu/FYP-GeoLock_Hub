# Stage A 003 — definitive read-only postdeployment assessment

**Milestone CLOSED by owner instruction; closure recorded 27 October 2026 MYT.** Existing verdict and scope remain unchanged. Routing initialization has a separate approval package; no migration replay is required.

**Verdict: DEPLOYED / POSTFLIGHT PASS** for the approved catalog, source/security contract, trigger/structure delta and aggregate preservation scope. **Routing is NOT initialized or operationally accepted.** No failed postflight invariant or unexpected change was detected in the inspected scope.

DEV: `rcgyuwiidqvrgbxswhqj`. Operator reports executing 003 and collecting postflight. Independent read-only observation: **26 October 2026, 21:11:28 MYT**; initialization-state observation **21:13:32 MYT**. Assessment completed from these retained artifacts after the conversation interruption; no new SQL was needed on resumption. The interruption was not a reported database failure.

Migration: `docs/stage8/stage-a/forward-migrations/20261103_routing_pickup_and_reconciliation.sql`, unchanged SHA-256 **`6541f0a002ea56ad77c023e33ad1500ab2273cc821f87fa43d38e633bd6724ea`**. Current database postconditions match its reviewed definitions. This records user-reported deployment plus independently visible installed state; it does not invent an execution/COMMIT log, approval timestamp or application migration ledger entry.

## Evidence and comparison

Original full operator capture/execution files were not located in the scoped workspace search. The user's supplied summary was therefore checked against fresh, comprehensive explicit READ ONLY queries using the existing DEV-bound `supabase_read_only_user` connection. No installer credentials, business RPCs, fixtures, recovery, worker activation or source changes were used. The grouped query preserves raw result arrays locally, not only PASS counts.

| Contract/invariant | Verified result | Classification |
|---|---|---|
| POST01 | **17/17 PASS**: 14 additions + 3 replacements; exact signatures, normalized body MD5, return types, postgres owners, security/volatility, exact configuration and direct EXECUTE grantees | PASS |
| POST02 | **28/28 PASS** for preserved 001/002 phase definitions, including the post-002 fail-closed assignment function | PASS |
| RPC named arguments/defaults | **45/45 PASS**, derived from exact 001/002/003 declarations; argument names, positional signature resolution, modes/default count and values match. No unexpected overloads for the inspected private/public contract names | PASS |
| POST03 | `claim_listing=2c1f60c876797c61b44b3cb43591bab8`; `recover_expired_claims=89e01f42d5ec23bfcbcdc47c1f4fd4e5`; audit helper `67f27a85fb9129c9017bb0e9178f8ba1`. Supplementary metadata checks verify expected owner/security/volatility/return/config as well as body hashes | PASS |
| POST04 | Exactly one inspected `routing_task_authority`: enabled O, non-internal, tgtype 19, BEFORE UPDATE OF task_status, FOR EACH ROW, correct attribute and `routing_private.task_guard()` identity | PASS |
| Existing triggers | All **16** preflight application trigger records unchanged; only the expected task authority trigger added, giving **17** within the same inspected table scope | PASS |
| Private structure/RLS | Full nested table catalogs equal preflight: 11 tables, 75 columns, 21 valid/live indexes, 35 validated constraints and expected private application triggers/RLS settings | PASS |
| Schemas/role memberships | Private/fleet schema ownership, ACLs and seal comment unchanged; captured global membership edges equal preflight | PASS within recorded scope |
| Direct/effective execution | **192/192** six-role/function pairs meet expected boundaries: 25 private helpers denied to all six inspected roles; six pickup/route/read public functions allow authenticated only; reconciliation allows authenticated/service_role. Owner/provider administration is outside that six-role denial model | PASS |
| Permit-table DML | All **12** six-role/two-table combinations deny INSERT/UPDATE/DELETE/TRUNCATE and the migration's combined DML predicate | PASS |
| Table/column writes | All **74** returned protected public/private table/column write predicates false; no forbidden write permission found | PASS |
| Audit helper/worker roles | Audit-helper EXECUTE denied to all six inspected roles; existing NOLOGIN worker role attributes remain restricted | PASS |
| P07 | All ten cutover/active routing counters remain **0**, including DISPATCHED, legacy capture/overlap, active bindings/items, in-progress routes and unresolved reconciliation cases | PASS |
| Public source preservation | Exact captured aggregate lists equal preflight: 7 pickup tasks, 7 claims, 7 leases, 10 donations, 6 listings, 58 audit events, and zero routes/stops/active assignments/reconciliation cases | PASS for counts only |
| P10 | One coordination singleton matches 360/10/20000; PostgreSQL 17.11, PostGIS 3.3.7 and pgRouting 3.4.1 in extensions; overload inventory captured | PASS for observed contract |
| Fleet protection | Fleet fingerprint function metadata and schema seal comment equal preflight; no full fingerprint invocation was performed | PASS for metadata; full recomputation NOT VERIFIED |
| Recovery state | `geolock-expired-claim-recovery` is still active=false; no recovery invocation made | PASS / retained disabled state |
| P11 | Expected application ledger still unavailable; no historical entry fabricated | UNKNOWN, retained risk, not a failed 003 postcondition |

The six inspected role principals are anon, authenticated, service_role, geolock_graph_worker, geolock_planner and geolock_validator. Broader provider/admin privileges and real JWT behavior are not equated with this scoped matrix. Every expected pair was compared, not merely counted.

## Expected changes versus unexpected changes

The observed delta is the reviewed 003 change set: 14 added functions; hardened pickup/reconciliation replacements; authenticated-only pickup/route/read grants; preserved authenticated/service_role reconciliation grant; one new global task-state authority trigger. The 28 baseline definitions remain unchanged. No unexpected overload, missing function, table recreation, prior trigger modification, schema/role-membership change or aggregate business-data change was detected.

Zero legacy rows are correct: preflight had zero DISPATCHED tasks, so 003's capture INSERT had no source population. Zero route counters do **not** mean pickup_tasks is empty: seven tasks still exist. Audit count 58 is not a failure: this reviewed migration does not require a new business audit event merely for installing its DDL.

Two leases remain ACTIVE but expired; five are RELEASED. Tasks remain two CONFIRMED and five STALE. This is inherited lifecycle state, not evidence that 003 failed. The expired pair cannot be routed until the existing protected lifecycle is resolved or a separately approved valid claim path is used. No renewal, forced release or reconciliation change is authorized by this assessment.

All **11 routing_private tables remain empty** in the retained initialization-state capture. Approved operational coverage `OSM-OPS-20261018` exists, but no policy/frozen-graph manifest/matrix/snapshot/candidate/validation/binding has been initialized. No operational route or dispatch success is claimed.

## Failed checks, missing evidence and outstanding risks

**Failed scoped postflight checks: none.** Missing evidence is not silently marked PASS:

* The original operator's exact command, execution timestamps, COMMIT/transaction identifier and raw postflight file were not available in the inspected workspace. Independent committed catalog visibility supports installed-state confirmation but cannot reconstruct that historical execution. Preserve operator logs outside the application ledger if available; do not rerun 003 to recreate them.
* Matching counts/status aggregates do not establish exact before/after row-content equivalence or absence of every possible same-count update. No row-digest baseline existed for full equality.
* The fleet fingerprint was not recomputed. Its function metadata, schema ownership/ACL and stored seal comment are unchanged; no full live fleet schema proof is inferred.
* Authenticated PostgREST/schema-cache discovery, real NGO/donor/hub JWT access, planner/validator transport, positive/negative pickup/cancel/close/reconciliation paths, whole-batch behavior, concurrency and failure rollback remain **NOT VALIDATED**. C.5 did not run database compatibility tests. No business-operation test was invoked here.
* Backup restoration, exact row equivalence, managed/provider recovery, external Storage bytes, passwords/service secrets and the previously stated logical-backup exclusions remain unverified. Catalog PASS does not clear those recovery risks.
* P11 historical application migration sequence remains UNKNOWN. Source-file match and current state are not a migration ledger. No production/shared assessment is implied.
* External worker process/activation state was not independently inspected. The recovery scheduler's disabled state was observed, and Codex performed no activation. Empty tables do not prove every external service is stopped.

These limits prevent a claim of **routing operational readiness**, not the scoped **DEPLOYED / POSTFLIGHT PASS** status now supported by the database evidence.

## Release record and stop point

Authoritative local assessment record: `results/stage-a003-postdeployment/deployment-record.json`. It records the user as execution source, actual read-only observation time, source artifact hash, checks and limitations. It is a filesystem release record only; no database migration-history rows were inserted.

Raw/supplemental evidence: `readonly-postflight.sql/.json`, `argument-and-overload-checks.sql/.json`, `expected-argument-contracts.json`, `initialization-state.json`. Preflight comparison sources: `results/stage-a003-direct-preparation/final-approval-preflight.json` and `final-approval-security.json`.

**Do not rerun 003.** The next separately approved procedure is `ROUTING_INITIALIZATION_PROCEDURE.md`. Policy values, graph-freeze inputs and worker activation each require exact review/approval; the assessment authorizes none of them. Recovery remains disabled, existing data unchanged by Codex, and no other migration is executed.
