# Stage B.4.2 — Claim Deadlock Root-Cause Investigation

**Status: COMPLETE (investigation and harness scope).** The current composed claim function has a confirmed lock-mode inversion between `claim_requests` foreign-key checks and an unnecessarily strong listing `FOR UPDATE` lock. Fresh local 5- and 10-actor runs reproduced it and captured PostgreSQL DETAIL, CONTEXT, backend PID, transaction IDs and the statement. The isolated pickup-start-first fixture was corrected without changing production grants, and both race orders passed. **No production SQL, Flutter code, migrations, Stage B.3 files, or teammate algorithms were changed.** The production defect remains and needs a separate correction approval.

## Environment and method

All runs used fresh temporary PostgreSQL 17.11 clusters bound only to `127.0.0.1`, the pinned `.venv-stage8` environment, synthetic users/listings, and the composed package from Stage B.4.1. No Supabase endpoint or external database was used. The package assembly and its hashes are preserved in each run's `applied.json`.

The diagnostic run installed the package unchanged, then replaced only the `claim_listing` definition in that disposable database with an otherwise identical copy that logs `GET STACKED DIAGNOSTICS` fields when it catches `40P01`. It did not pause or reorder the production path. This instrumentation is local-only and its raw server log is [here](../../../results/stage-b4-2/claim-deadlock-diagnostic-run-02/postgresql-server.log). The run completed the 2/5/10 actor cases: 2 actors PASS once; 5 and 10 actors reproduced the deadlock. The JSON actor outcomes, before/after states, audit/failure rows and request replay checks are in that run directory.

## Findings

### CONFIRMED — exact lock cycle

In `supabase/migrations/20261031_claim_audit_and_failure_capture.sql`:

- `claim_listing` starts at line 198.
- It inserts the new `claim_requests` row at line 225, before acquiring the listing row lock.
- It then executes `SELECT ... FROM public.listings ... FOR UPDATE` at line 237 (function-body context: line 35).
- The composed schema defines `claim_requests_listing_id_fkey` from `claim_requests.listing_id` to `listings.listing_id` at `geolock-v3-public-schema.sql:3602-3606`.

The claim-request FK check acquires a key-share row lock on the referenced listing and retains it until the transaction ends. `FOR UPDATE` conflicts with that key-share lock. When two or more transactions insert distinct request rows for the same listing before any gets to its listing lock, each retains its FK lock and asks for the incompatible listing lock. Each is then waiting for the other transaction to finish, producing the observed cycle.

Captured example from the 5-actor run:

| PostgreSQL PID | Transaction it waits for | Blocker PID | Statement/context |
|---:|---:|---:|---|
| 5988 | 782 | 14216 | `SELECT ... FROM public.listings ... FOR UPDATE`; tuple `(0,5)` in `listings` |
| 14216 | 783 | 5988 | reciprocal wait reported in the same deadlock DETAIL |

The log associates PID 5988 with actor `c3268f0b-b9b7-47d1-896f-d2dcaed44640`, request `9ceb61fc-cf2f-4ff6-bbc2-3552eed3c9c0`; PID 14216 is associated with actor `22222222-2222-2222-2222-222222222222`, request `33f75ca2-3816-4b99-b4fe-7631ef7873c9`. The DETAIL reports `ShareLock on transaction` in each direction; the CONTEXT and SQL statement locate the conflicting tuple operation at the listing `FOR UPDATE` statement. Additional cycles are in the same log. Ten actors produced repeated cycles on the same listing-lock statement (including tuple `(0,8)`).

```mermaid
sequenceDiagram
    participant A as Claim transaction A
    participant B as Claim transaction B
    participant L as listings row
    A->>L: INSERT claim_requests: FK obtains KEY SHARE
    B->>L: INSERT claim_requests: FK obtains KEY SHARE
    A->>L: SELECT listing FOR UPDATE; waits for B
    B->>L: SELECT listing FOR UPDATE; waits for A
    Note over A,B: PostgreSQL detects xid wait cycle and aborts one transaction
```

**CONFIRMED — production function, not test-fixture ordering.** The diagnostic run used distinct request IDs and actors synchronized only at the test's pre-call start barrier. The cycle is reported from the current composed `claim_listing` execution at its listing-lock statement, and the preceding FK/insert order is present in the production migration. The barrier makes overlap likely, but does not introduce a conflicting database operation or alter lock order.

**CONFIRMED — why `ERROR` appears.** The function's `EXCEPTION WHEN OTHERS` handler is at migration lines 285-327. It catches the `40P01`, rolls back the claim subtransaction, records a failure event, then returns `outcome='ERROR'` and `CLAIM_TRANSACTION_ROLLED_BACK` at lines 326-327. Transactions that arrive after the winner commits instead see the claimed listing and return the normal conflict. Thus 2 actors can pass in one run by timing, while larger groups make it more likely that multiple FK key-share locks are acquired before the first listing `FOR UPDATE`. The 2-actor PASS is one observed schedule, not evidence that two-way contention cannot deadlock.

**CONFIRMED — committed state remains exclusive in these cases.** Deadlock-aborted subtransactions left one winning claim, lease and task; no duplicate active authority was observed. The failure handler recorded rollback-confirmed failures. This limits the observed consequence to aborted/failed requests and incorrect loser outcomes, not duplicate committed claims. The operation is still a correctness/availability defect and should be fixed before broader concurrency claims.

**CONFIRMED — other suspected sources excluded for this path.** The deadlock CONTEXT identifies the listing tuple lock statement. It occurs before the successful path inserts `donation_claims`, `claim_leases`, `pickup_tasks`, transitions donations, writes claim-attempt audit, or calls routing authority. Distinct request IDs avoid an intended unique-key conflict. No user trigger or route authorization call appears in the captured context. The FK enforcement itself is part of the observed lock chain; no separate audit or route lock cycle was found.

### POTENTIAL — minimal production correction

Change only the listing lock in `claim_listing` from `FOR UPDATE` to `FOR NO KEY UPDATE` at migration 20261031 line 237. `FOR NO KEY UPDATE` still serializes competing claim writers and conflicts with another `FOR NO KEY UPDATE`, but is compatible with the FK's key-share lock. The function updates status/version fields, not the listing key. This is narrower than moving the idempotency protocol or adding a retry loop, and preserves the existing pre-insert request advisory lock, request lookup/replay, audited success/conflict/error outcomes, lease duration, lifecycle, RLS and route authority.

This is a proposed correction only. It has not been installed, even in the test harness. After separate approval, test it in a fresh disposable full-package cluster for 2/5/10 actor races, request replay/reuse, rollback/audit counts and relevant concurrent listing writers before any DEV consideration.

**NOT RECOMMENDED — generic transaction retry.** Do not turn arbitrary `ERROR` results into conflicts or automatically retry all database errors. The existing RPC response hides SQLSTATE from the caller, and transaction-level retry would need a precise 40P01-only boundary, bounded attempts, unchanged request ID and correct failure-audit semantics. The one-lock-mode change addresses the identified mechanism without retry semantics. If unrelated deadlocks remain after that change, investigate and authorize them separately.

## Pickup/recovery fixture and results

The Stage B.4.1 start-first fixture used `SET LOCAL ROLE authenticated` and then directly updated `public.claim_leases`, which is not granted to that role. The failure was an invalid test setup, not a failed production permission check. In the B.4.2 isolated harness, a test-only `SECURITY DEFINER` helper was created in the disposable schema. It is executable only by `authenticated`, checks `auth.uid()` owns the claim, and expires only that synthetic active lease. It does not modify production grants, policies or functions.

Both orders passed in `pickup-order-fixture-run-02`:

- **Pickup start first:** valid authorized route starts and holds the claim transaction; the lease is expired inside that transaction using the scoped helper. Concurrent recovery returns `0` because `recover_expired_claims` uses `FOR UPDATE OF c SKIP LOCKED` (`20261030_fix_claim_recovery_unresolved_reconciliation.sql:56`). The bounded post-commit retry returns `1`, marks claim/lease `RECONCILIATION_REQUIRED`, retains the dispatched task and pickup-in-progress donation, and writes the recovery audit. This is the expected scheduler-retry behavior, not a dropped recovery.
- **Recovery first:** the expired lease is recovered while holding the claim lock; pickup start waits and is rejected. The claim/lease remain in reconciliation and the task reservation is retained.

Raw states and operation order are in `pickup-start-recovery-start-first.json` and `pickup-start-recovery-recovery-first.json`; test summary reports 2/2 passed, zero errors, zero Supabase connections.

## Risk assessment

| Area | Assessment |
|---|---|
| Claim exclusivity | **CONFIRMED preserved in tested failing runs**; one winner and one active task/lease. |
| Idempotency | **CONFIRMED existing success replay and different-payload reuse checks passed** in Stage B.4.1; the proposed lock-mode-only correction leaves this path unchanged. It has not yet been tested against a fixed implementation. |
| Audit | **CONFIRMED** failure audits recorded transaction rollback. Normal loser audit/outcome contract is violated when deadlock occurs. |
| Authorization/RLS | **CONFIRMED unchanged in the diagnostic package**; instrumentation was owner-installed only in disposable DB. Pickup helper is test-only and scoped to own synthetic claim. |
| Donation/route authority | **CONFIRMED not reached by the claim deadlock path before listing lock**; no route authority change proposed. |
| 360-minute lease | **NOT RE-VERIFIED in B.4.2 as an independent invariant**; no lease policy was changed. |

## Next approval checkpoint

Approve or reject the proposed one-lock-mode correction as a separate, narrowly scoped production migration change. If approved, implementation should be followed by the bounded local full-schema regression matrix described above and independent review of the migration diff. Keep DEV deployment and Chapter 5 experiments unauthorized until that review passes. No final Chapter 5 trials ran during this investigation.
