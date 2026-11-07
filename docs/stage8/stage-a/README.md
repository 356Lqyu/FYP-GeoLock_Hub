# Stage A current routing compatibility package

Stage B follow-up: `../stage-b/REPORT.md` records actual limited local PostgreSQL
verification and the reviewed assignment-guard dependency-order correction.
Historical 192-test evidence below is retained; current source has a separate
193-test offline result under `results/stage-b`. Stage B is PARTIAL and grants
no live deployment permission.

Prepared 26 October 2026, Asia/Kuala_Lumpur. **Local Stage A complete; runtime integration, deployment and Chapter 5 execution are not approved or claimed.**

This package rebases the existing routing architecture on `supabase/migrations/20261031_claim_audit_and_failure_capture.sql`. It preserves historical proposals, captured DEV evidence, Flutter pickup restrictions and existing E2 guards. No Supabase connection, SQL execution, worker activation, credential creation or fixture mutation occurred.

## Review artifacts and changes

| New file | Purpose |
|---|---|
| `build_package.py` | Deterministic standard-library-only builder. Checks independently pinned current source; never queries a database. |
| `forward-migrations/20261101_routing_authority.sql` | Existing 001 authority architecture with reviewed current lifecycle/source/security guards. |
| `forward-migrations/20261102_routing_publication.sql` | Existing 002 publication implementation, unchanged except the review banner. |
| `forward-migrations/20261103_routing_pickup_and_reconciliation.sql` | Rebased pickup enforcement and compatible reconciliation in ONE transaction. |
| `package-manifest.json` | Forward SQL hashes, authoritative source hash, permitted public replacements and explicit runtime-unverified status. |
| `preserved-inputs.json` | Hashes of the original proposals, source migrations, historical evidence and live guard inputs; drift causes build/test failure. |
| `postdeployment_catalog.sql` | Prepared SELECT-only source/permission observations, not a complete deployment verifier. Not executed. |
| `direct-pickup-manifest.template.json` | Unapproved one-NGO/one-vehicle/one-direct-task pilot specification. Contains no credentials or fixture seeds. |
| `run_offline.py`, `offline-results.json` | Fenced offline suite and actual final results. |
| `offline-attempt-01.json` | Retained first broad test attempt, including the Windows metadata-probe fence failures. |
| `SYSTEM_VERIFICATION.md` | Three-role workflow checklist with API, state, UI, positive/negative tests, audit and completion gates. |
| `CHAPTER5_READINESS.md` | Latest-report experiment matrices, fair-comparison requirements, existing runners and missing infrastructure. |
| `ROADMAP.md` | Dependencies, staged approvals and direct-pickup runtime test specification. |
| `supabase/tests/stage8_stage_a_offline_test.py` | 27 new tests of the actual rebased package, current-body equality, scoped replay/permits, preserved inputs and restrictions. |

These are **forward review migrations**, deliberately outside `supabase/migrations` to prevent automatic migration discovery. Their filenames define the proposed order, not an applied migration history. Promotion/execution needs a separate reviewed deployment decision. Do not run old 003 and this new 003 together; these are alternative first installations. Existing `routing_private` requires a separately designed upgrade.

## Changes are substantive, not hash adoption

The private `legacy_start_pickup` and `legacy_complete_pickup` implementations contain the **exact complete current 20261031 bodies**. Only function schema/name and hardened execution settings differ. Their six-argument helper calls retain the actual claim, NULL operation-request field where the API has none, and `PICKUP_STARTED` / `PICKUP_COLLECTED` reasons.

Reconciliation begins from the current 20261031 body. Only three documented additions are allowed: authorized scope locking/cached-response replay; a transaction-bound permit immediately before reconciled task collection; and route-item collection bookkeeping after successful resolution. Removing those additions reproduces the current source exactly. All existing audit INSERTs and the six-argument safe-release helper call remain exact. A saved first-party waiting response remains historical; replay does not issue fresh authority.

The first-installation enforcement file includes reconciliation compatibility before COMMIT. It does not temporarily install a guard that prevents the legitimate reconciliation writer. Recovery, claim_listing, cancellation, audit retrieval, failure ledger and donation-transition helper are not replaced. No lease renewal or new donation statuses are introduced. Public replacements are limited to assignment, start, completion and reconciliation.

Current pre-install checks pin body MD5 **and** owner, SECURITY DEFINER, volatility, return type and search path, and check the six-argument private helper and 360-minute configuration. The unchanged assignment function retains its historical exact-definition pin. These are local compatibility expectations, NOT fresh DEV or ACL approval. Actual effective ACLs, memberships, overloads, dependency/trigger state and source differences still require a future authorized review.

## Actual tests

Run from the repository root using the existing environment:

```powershell
.venv-dev-fixtures/Scripts/python.exe -B docs/stage8/stage-a/build_package.py
.venv-stage8/Scripts/python.exe -B docs/stage8/stage-a/run_offline.py
```

Final: **192 tests PASS, 0 failures, 0 errors, 0 skips**, including 27 new package checks, 103 existing claim/lifecycle/onboarding contracts, 12 historical reconciliation static checks, 4 historical SQL-package checks, 20 in-memory integration tests and 26 worker-flow tests. The latter use actual local routing algorithms/validator with synthetic in-memory database transports. They do not compile or execute the new SQL.

The runner blocks socket connections, database connections and subprocesses during tests. OS metadata is cached before the fence because Windows/pandas otherwise launches a read-only OS-version probe during import. No database server, worker service or SQL client was started. Printed mocked-race PASS messages are not actual PostgreSQL observations.

Initial new-test development found two issues: a generated blank line outside the allowed guard diff, and a test expecting a positive reconciliation helper audit call absent from the authoritative source. The builder newline was corrected; the test now proves exact preservation of all three actual audit INSERTs plus the current release linkage. No production audit behavior was invented to satisfy a test. The first broad 192-test attempt had 12 failures caused by the subprocess fence intercepting the Windows metadata probe; the retained attempt and final run distinguish this harness issue from production behavior. No failed check was skipped.

SQL grammar/PLpgSQL compilation, permissions and stateful/concurrent execution are **UNVERIFIED**. No disposable PostgreSQL or Flutter process ran in Stage A. Historical isolated/Flutter results are not promoted to current-package results.

## Remaining blockers

1. Stage B disposable full-schema compilation and integrated direct/whole-batch/legacy/reconciliation tests.
2. Real schema/ACL/role/trigger comparison, C1 authenticated prerequisites and usable recovery preparation, under separate approval.
3. Actual legacy DISPATCHED task and unresolved-case cutover inventory. The task guard is global even though the first acceptance fixture is one direct pickup.
4. Approved road graph freeze/precision/performance and explicit service/window/margin/solver/objective policy. Existing full-graph freeze blocks network maintenance.
5. Protected worker identities/TLS/persistent journal and independent validator deployment, none activated here.
6. Exact current historical overdue-pair snapshots and explanation of recovery history 17 -> 22. Existing zero-overdue guards remain unchanged; no scoped exception is approved.
7. Reviewed expected-object differences after routing replaces current pickup/reconciliation functions. Existing live harness fingerprints intentionally continue to reject changed contracts until separately reviewed.
8. Planning/authorization retry recovery across UI restarts, current participant audit completeness, handover semantics and actionable error messages need Stage B integration review. Normal handover remains the NGO's assertion, not independent physical verification.

**Next approval requested: Stage B local disposable full-stack verification only.** It would include new loopback databases, actual forward SQL, current lifecycle functions/triggers, synthetic Auth/road fixtures and Flutter tests. It does not authorize any Supabase connection, migration, worker activation or live fixture/experiment. This task stops at Stage A and planning.
