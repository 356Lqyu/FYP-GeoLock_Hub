# Stage B.4 — Claim, Pickup and Recovery Race Verification

**Status: PARTIAL.** This stage adds two focused current-migration race tests and
preserves raw local evidence. It does not close the broader Stage B.4 matrix or
authorize DEV deployment. No source migration, Flutter app, Stage B.3 artifact,
or coordination authority implementation was changed.

## Scope and environment

All executed PostgreSQL tests used harnesses that initialize a new temporary
cluster with `initdb`, choose an available port, bind `pg_ctl` to `127.0.0.1`,
connect only as the local `postgres` user, stop the server and clean the temp
directory. The runtime reports PostgreSQL 17.11. The fixtures use synthetic
users and reduced schemas; `auth.uid`, road checks and other external Supabase
services are doubles. No Supabase URL, credentials, gateway, DEV database or
production target was used. The initial sandbox-only `pg_ctl` failure and the
first B.4 fixture setup failure are retained in the raw evidence folders; the
successful runs used the permitted local process execution after review.

## Results

| Evidence | Result | What it establishes | Limits |
|---|---:|---|---|
| [B.4 current-migration race tests](../../../results/stage-b4/b4-races-current-migrations-run-03/console.log) | **2/2 passed** | Competing completion/recovery lock orders against the exact `start_pickup`, `complete_pickup`, `recover_expired_claims`, and donation transition function bodies extracted from `20261031_claim_audit_and_failure_capture.sql`. Completion-first ends COMPLETED/COLLECTED with no recovery audit. Recovery-first after pickup ends RECONCILIATION_REQUIRED, preserves PICKUP_IN_PROGRESS, and rejects later completion. | Reduced recovery fixture; no actual Auth/PostgREST gateway, routing authorization trigger, or full production schema. The tests establish these transaction/state outcomes only. |
| [Two-actor/current claim contract suite](../../../results/stage-b4/two-actor-run-01/console.log) | **8/8 passed** | Actual local PostgreSQL contention: delayed two-actor race, a ten-distinct-NGO race (one SUCCESS, nine CONFLICT), idempotent claim/replay, lifecycle/audit checks, seven failure points and rollback/receipt behavior. The local catalog matched all nine revised claim function definitions. | Synthetic actors and REST/RPC adapters; no real JWT verification, RLS through PostgREST, or deployed database. Ten-actor case is a single race, not 50 independent trials at each prescribed size. |
| [Recovery characterization suite](../../../results/stage-b4/recovery-automatic-run-02/console.log) | **23/23 passed** | Earlier reduced-harness expiry boundary, concurrent recovery/reclaim, cancellation ordering, completion non-recovery, authorization ACL checks, rollback and hub/direct fixture cases. | It installs the 20261027/20261029 recovery implementation and captured RPC fixture, not the final 20261031 recovery body. Count it as supporting historical evidence, not current migration acceptance. Its expected-pass characterization of the old open-case anomaly does not describe the 20261031 body. |

The B.4 test entry point is [stage8_stage_b4_isolated_test.py](../../../supabase/tests/stage8_stage_b4_isolated_test.py). It installs exact current function definitions only inside its disposable local cluster. It does not modify or activate any source migration.

## Required race and invariant matrix

| Area | Status | Evidence / remaining gap |
|---|---|---|
| A — Claim contention and idempotency | **PARTIAL** | Current two-actor and single ten-NGO races passed; replay/payload and audit assertions are present in the two-actor suite. Required 2/5/10 NGO sizes across 50 independent trials per worker count were not run. No formal schedule/seed manifest or per-trial raw committed-state package exists. |
| B — Lease expiry and recovery | **PARTIAL** | Boundary, no-renewal 360-minute claim lease, repeat recovery, bounded recovery, and rollback cases pass in earlier harnesses; current 20261031 race tests establish the two completion/recovery outcomes. Current migration 31 recovery has not been exercised against the full composed schema across all safe/uncertain direct and hub custody strata. |
| C — Pickup/recovery/lifecycle lock ordering | **PARTIAL** | Current migration 31 completion-first and recovery-first races passed. Earlier harnesses cover start/recovery, cancel/recovery, assignment/recovery, and recovery workers but are not current-migration acceptance. Release-vs-start, cancel-vs-start, current reconciliation-vs-lifecycle, whole-batch interactions, crash/timeout interleavings, and full-state snapshots remain open. |
| D — Authorization negatives | **PARTIAL** | The two-actor harness tests current claim actor ownership, stale/non-holder rejection and protected function catalog; the older recovery suite tests recovery ACL denial. Current 20261031 start/complete versus the routing-task authority trigger, current recovery role grants under realistic roles, and database-level RLS through a real gateway were not jointly verified. |
| E — Final state, audit and atomicity | **PARTIAL** | Existing claim suite verifies rollback for audit/failpoint failures and confirms no duplicate claim authority. New B.4 tests verify key final statuses and recovery-audit counts. They do not snapshot every related row/table or inject failures at each current 20261031 race point. |

## Findings

### Confirmed

- Current 20261031 pickup/recovery code serializes the tested completion path on
  the claim row. If completion commits first, recovery sees no active expired
  claim to release. If recovery processes an already-started pickup first, it
  moves the claim/lease to reconciliation and a subsequent completion is
  rejected. See `start_pickup`, `complete_pickup`, and
  `recover_expired_claims` in
  [20261031_claim_audit_and_failure_capture.sql](../../../supabase/migrations/20261031_claim_audit_and_failure_capture.sql)
  and the two B.4 test methods.
- The current recovery function checks open/manual-review cases, task/listing
  state, route references, and donation/batch custody before reopening. The
  characterization of an open-case recovery anomaly in the older 20261029
  harness is historical and was addressed by later migration logic; it is not
  evidence that the current 20261031 function has that behavior.
- Existing Stage B evidence remains intentionally separate: [Stage B report](../stage-b/REPORT.md)
  records a reduced local PostgreSQL lifecycle suite and explicitly leaves
  recovery/pickup races and broad SQL negatives incomplete. B.2 likewise records
  those remaining items in [its report](../stage-b2/REPORT.md).
- Stage B.3 remains a proposal/diagnostic workstream. Its
  [reproducibility policy](../stage-b3/REPRODUCIBILITY_POLICY_PROPOSAL.md)
  is marked proposal-only; no B.3 file or evidence was changed here.

### Not established by these tests

- Full production schema and all migrations applied together with current B.4
  concurrency cases.
- The live Auth/PostgREST/RLS path, actual JWT claims, real road-network
  eligibility, active routing authority trigger, or deployed cron invocation.
- Full claim/lifecycle schedules and all rollback/failure points required by
  the eight-track Chapter 5 protocol.

No production defect was confirmed by this bounded run. The test harness itself
had two setup defects during development (the shared fixture initially supplied
an expired lease; then a current transition helper dependency was missing).
Those were corrected only in the new B.4 runner; successful runs used fresh
temporary clusters.

## Chapter 5 readiness

All eight formal tracks remain **PARTIAL**; B.4 provides limited additional
evidence only to Tracks A, B, and indirectly H. No final experiment was run.
The controlling protocol remains
[CHAPTER5_READINESS.md](../stage-b2/CHAPTER5_READINESS.md).

| Track | B.4 contribution | Final experiment ready? |
|---|---|---|
| A Atomic claims | Two-actor plus one ten-actor race, idempotency and audit/rollback support. | **No** — lacks required 2/5/10 × 50 independent current-version trials and frozen controller. |
| B Lease/recovery | Current two-order completion race; earlier recovery boundary/custody tests. | **No** — full current-migration strata, 100 declared cases and outstanding race/whole-batch cases remain. |
| C Road eligibility | None. | **No** — formal oracle, trusted OSM coverage and performance protocol remain. |
| D Deterministic hub baseline | None. | **No** — common evaluator and frozen baseline outputs remain. |
| E AI hub ranking | None. | **No** — trainer/search/controller and grouped experiment remain. |
| F Hub aggregation | No new current whole-batch acceptance. | **No** — matched scenarios and protected batch lifecycle remain. |
| G Route optimization | None; no solver repetitions were run. | **No** — Stage B.3 repeatability policy is proposal-only and required route trials remain. |
| H Independent feasibility validation | Only claim/pickup authority boundaries touched indirectly. | **No** — full paired route corpus, negative corpus and real role/gateway separation remain. |

## Recommended next steps

1. Before treating B.4 as closed, build a full-schema disposable runner that
   applies the current migrations and runs the claim, recovery, pickup,
   reconciliation, route-authority, and audit races together without invoking
   the solver.
2. Add the missing current-migration schedules: start/recovery both orders,
   cancel/start both orders, current reconciliation versus start/complete,
   route assignment versus recovery, and direct/hub whole-batch recovery with
   full table snapshots and injected rollback failures.
3. Run the declared independent 2/5/10-actor contention protocol only after the
   current-version fixture, schedule, worker-count, and evidence controller are
   reviewed and frozen. Preserve every trial, including errors and timeouts.
4. Separately establish local Auth/PostgREST/RLS integration and independent
   worker/validator-role coverage before relying on these results for DEV.

## DEV deployment sequence

Do not deploy from this evidence alone. The next approved checkpoint should be
current full-schema isolated verification and review of raw evidence. Then
separately prepare a read-only DEV fingerprint/health preflight; obtain explicit
approval for any DEV mutation; deploy only the reviewed additive migration
package; run post-deployment fingerprint, ACL, audit, custody, and rollback
checks; and retain an operational pause/rollback plan. B.4 made no DEV access or
deployment attempt.
