# Stage B.4.1 — Current Full-Schema Race Verification

**Status: PARTIAL.** Full current-package assembly and several authority/race cases passed on fresh disposable local PostgreSQL clusters. Claim contention exposed reproducible `40P01` deadlocks for 5 and 10 simultaneous NGOs, and one pickup-start/recovery ordering could not be exercised because test-fixture SQL lacked permission to manipulate `claim_leases`. No production implementation was changed. This is engineering verification, not Chapter 5 experimentation.

## Scope and environment

The runner in [stage8_stage_b4_1_isolated_test.py](../../../../supabase/tests/stage8_stage_b4_1_isolated_test.py) uses the existing Stage B full-schema builder in [stage8_stage_b_isolated_test.py](../../../../supabase/tests/stage8_stage_b_isolated_test.py). Successful operations used pinned `.venv-stage8` dependencies and fresh temporary PostgreSQL 17.11 clusters bound to loopback. The package is a composed current schema snapshot plus selected current lifecycle migrations and reviewed forward routing/C1 SQL, not a chronological replay of every repository migration. Exact inputs and SHA-256 pins are recorded in each successful run's `applied.json`. No Supabase endpoint was used.

The full-schema catalog run found six expected RPC signatures owned by `postgres`, 28 enabled triggers, 183 public constraints, route guard present, and RLS declarations enabled on seven authority/audit tables. This is a catalog check, not proof that every RLS policy is correct under authenticated Supabase roles.

## Results matrix

| Case | Result | Evidence / interpretation |
|---|---|---|
| Full composed schema and authority catalog | PASS | `current-composed-schema-run-03/full-schema-catalog.json`; package input hashes in `applied.json`. |
| Claim, 2 simultaneous NGOs | PASS | `claims-focused-run-04/claim-contention-2.json`; one winner, one conflict, one active task/claim/lease. |
| Claim, 5 simultaneous NGOs | FAIL | `claims-focused-run-04/claim-contention-5-attempt.json`; one success, one conflict, three `ERROR` outcomes; SQLSTATE `40P01`. |
| Claim, 10 simultaneous NGOs | FAIL | `claims-focused-run-04/claim-contention-10-attempt.json`; one success, one conflict, eight `ERROR` outcomes; SQLSTATE `40P01`. |
| Claim request replay and request-id reuse | PASS | Both captured contention summaries report original request replay as same successful claim with `replayed=true`; reuse against another payload is rejected and rolled back. |
| Claim exclusive state and rollback/audit consistency | PASS for invariants; loser contract FAIL | No duplicate active task, claim or lease; failed operations rolled back and emitted failure audit entries. However normal contention returned transaction errors instead of conflict results. |
| Route authorization negatives: capacity, schedule/window, duration | PASS | `route-authorization-negative-run-01/route-authorization-negative-cases.json`; all three rejected with no committed route/task assignment or pickup transition. |
| Reconciliation vs pickup completion | PASS | `reconciliation-focused-run-02/reconciliation-completion-race...json`; serialized outcome preserved collected state; competing completion returned `PICKUP_NOT_STARTED` after reconciliation closed the task. |
| Recovery wins vs pickup start | PASS | `pickup-recovery-races-run-02/pickup-start-recovery-recovery-first.json`; start rejected after recovery authority won, custody stayed reconciled. |
| Pickup start wins vs recovery | BLOCKED | Same run's start-first fixture could not advance: test-only direct `UPDATE claim_leases` failed `permission denied`. This ordering is unverified; it is not evidence of a production defect. |
| Other pickup/recovery and legacy supporting cases | PASS in selected suite | `current-composed-schema-run-03/console.log`; includes direct workflow, expiry, repeat pickup, rollback, route forgery, reserved recovery and related cases. Initial suite also had one incorrect reconciliation expectation; corrected isolated rerun passed. |

Case counts across the final focused evidence: 2 claim-size cases PASS / 2 FAIL; route-negative subcases 3/3 PASS; reconciliation race 1/1 PASS; recovery-first ordering 1/1 PASS; start-first ordering BLOCKED. The comprehensive initial suite ran 15 methods with 13 passing and two non-passing outcomes (claim failure and an initially incorrect harness expectation, later corrected separately). These counts are not a statistical experiment and runs are not pooled as Chapter 5 trials.

## Confirmed defect and lock evidence

**CONFIRMED — claim contention can deadlock.** `claim_listing(uuid,uuid)` in `supabase/migrations/20261031_claim_audit_and_failure_capture.sql:198-326` returned failure audit rows with SQLSTATE `40P01` under simultaneous claims. The captured PostgreSQL wait samples show a transaction-ID wait cycle at both 5 and 10 actors. Five actors: one NGO waits on a second, which waits back on the first; remaining actors queue behind the cycle. Ten actors also show an xid cycle. The test raised `deadlock_timeout` locally within the disposable transaction solely to capture wait samples.

Atomic exclusivity remained intact: every contention fixture ended with a single winner and no duplicate active claim, lease or task. But expected loser behavior did not hold: three of four 5-actor losers and eight of nine 10-actor losers were `ERROR` / `CLAIM_TRANSACTION_ROLLED_BACK`, not `CONFLICT`. `claim_concurrency_test.py`'s normal race contract likewise expects losers to conflict. The failure handler records SQLSTATE and rollback in migration 31, but the sampled wait graph does not identify the nested statement/relation responsible for the cycle. Therefore the precise lock-order correction is **not yet established**. Preserve this failing test and investigate exact lock ordering before proposing a production patch; do not weaken the lease, audit, or authorization guards.

## Limitations and status of requested coverage

- Pickup start vs recovery is covered only recovery-first. Start-first remains blocked by fixture permission; a later harness should coordinate through an authorized trigger/barrier or another non-invasive synchronization hook, without relaxing production grants.
- Pickup start vs claim release/cancellation, pickup completion vs recovery, repeated pickup, retry/uncertain outcomes, route expiry/release/unauthorized actor permutations, and valid vehicle/NGO/task cross-binding were not all independently exercised against the composed package in this continuation. Existing Stage B/legacy tests are supporting evidence only and are not substitutes for these requested full-schema race cases.
- RLS flags, ownership, signatures, trigger presence and constraints were catalog-inspected. Full authenticated-role policy behavior was not independently validated.
- First attempts using system Python lacked the pinned OR-Tools dependency; they are setup failures, not source findings. The first reconciliation run had an incorrect expected error and was corrected. A first pickup race fixture set a route-incompatible short lease and was correctly rejected by authority. Raw logs remain in the separate run directories.

## Chapter 5 readiness

This stage did not run any formal Chapter 5 experiments. Current full-schema package assembly and focused authority checks provide useful engineering evidence, but claim concurrency is not ready for a final experiment because reproducible deadlock errors contaminate loser outcomes. The blocked start-first ordering and other full-schema omissions also prevent treating the race/recovery track as complete. Use existing Chapter 5 readiness documents for the other tracks; this report does not upgrade their readiness.

## Recommended checkpoint

**Do not mark B.4.1 complete or begin DEV deployment.** Next approval should cover only root-cause analysis of the `claim_listing` lock cycle and design of an authorized start-first pickup/recovery barrier fixture. Preserve current failed evidence. Once a separately approved correction is made, rerun bounded full-schema claim contention and complete the missing authorized race permutations on fresh local clusters, then request review before any DEV work. No production function, route contract, Stage B.3 artifact, Flutter source, or hub algorithm was changed in this stage.
