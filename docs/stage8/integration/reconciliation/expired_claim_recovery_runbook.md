# Supervised expired-claim recovery — proposal only, NOT EXECUTED

DEV `rcgyuwiidqvrgbxswhqj` only. Migration 003 remains **HOLD**. No database access or SQL execution was performed to prepare this runbook. Separate explicit approval is required for any recovery invocation or transactional locks. Keep `geolock-expired-claim-recovery` disabled; do not freeze graphs or activate workers.

## Scope and source

Targets: claim `b4bea793-9755-470a-95bb-6b02bc0c4443`, task `521ad842-5d79-4157-97f9-9fb1c73ca632`; claim `dd1be70f-0e42-4b75-9124-cac3702d76f6`, task `bbbf6b10-cb79-42ed-82cc-8b2246bf8bcb`.

Historical claim `8161392c-e1e1-4723-a954-c80b6b61a8c7` and task `270caa8b-5a6d-481c-b199-c9a47156dda2` must remain unchanged. Its listing was legitimately reclaimed by the second target. Recovering that newer claim can legitimately change the shared listing and donation; those shared rows are not historical-row invariants.

Inspected repository sources: `supabase/migrations/20261030_fix_claim_recovery_unresolved_reconciliation.sql` and the listing-donation lock/transition helpers in `20261027_persisted_donation_lifecycle.sql`. The earlier reported DEV fingerprints support compatibility; fresh catalog verification remains mandatory. No local migration is being proposed or executed here.

## 1. Read-only preflight, immediately before separately approved execution

1. Confirm DEV project in the dashboard; database name alone does not prove project identity. Use the SQL Editor postgres session. Confirm a usable recent recovery point, its location, restoration limitations and permissions. Export all preflight results outside Git if they contain personal data.
2. Stop application pickup/claim/planning writers for a supervised maintenance window. Leave the scheduler disabled. Do not assume the scheduler being disabled stops manual calls or other workers.
3. Run `expired_claim_recovery_preflight_readonly.sql` P01–P06 and `three_claims_diagnostic_readonly.sql` D01–D06. P06 requires `cron.job`. Save observation times, all target/source rows, listing versions, historical row hashes, and audit event IDs.
4. Require exactly two P03 rows, every boolean true. Stop on source/security drift, missing or changed targets, prior recovery, new cases/references/holds, competing ownership, expired listings, source custody mismatch, or a scheduler that is active. Do not restore already-recovered claims to ACTIVE.
5. P03 mirrors source data checks without calling the locking helper; it cannot guarantee lock-time results. Hub checks include published nonempty batch, exact member count, member donation custody and hub-matching BATCHED inventory. Listing expiry is checked again by recovery after locks; a listing expiring during execution can cause reconciliation instead of release.

## 2. Batch limitation and approval boundary

The exact existing protected invocation is **NOT EXECUTED**:

```sql
SELECT public.recover_expired_claims(p_limit => 2);
```

This statement WRITES despite starting with SELECT. Never include it in read-only diagnostics.

The function selects all ACTIVE claims with ACTIVE expired leases, orders by lease expiry then claim UUID, locks claims `FOR UPDATE SKIP LOCKED`, and clamps the limit to 1–1000. A limit of 2 does **not** select these IDs. Older unrelated claims, locked targets or new expiries can change the batch. Its integer return counts both safe releases and reconciliation outcomes; `2` alone proves neither target identity nor successful release.

P02 inventories the entire ACTIVE/ACTIVE population, including future expiries. Any unrelated expired claim could be processed; any unrelated unexpired claim could become eligible before/during a later call. Read-only preflight and a maintenance request alone cannot mathematically eliminate this race.

**Do not execute the bare statement under exact-two-only approval.** The function cannot accept a claim-ID filter. Approval-safe alternatives, without changing it:

- Obtain separate approval for the fully enumerated possible batch and its reconciliation outcomes, with a fresh queue export and controlled writer window; do not describe this as exact targeting.
- For exact-two-only scope, separately review a short-lived transactional execution wrapper: acquire bounded table locks on claims and leases, reject unless the complete ACTIVE/ACTIVE population consists of exactly these two claims (including unexpired unrelated rows), recheck both task mappings/expiry, then call the existing function. Reject/roll back unless both expected claims/leases are RELEASED with STALE tasks and safe-release reasons, and historical claim/lease/task snapshots match. Locks prevent another caller from creating/updating queue rows; rejecting ALL unrelated ACTIVE/ACTIVE pairs prevents clock-driven new eligibility. No new persistent function, trigger, bypass or direct record edit is needed. This wrapper is an execution design requiring its own review, **not supplied as executable SQL in this package**. If unrelated ACTIVE/ACTIVE pairs exist, this conservative option must stop.

Do not use client filtering, SELECT WHERE around the RPC, limit=2, ID ordering, or locking unrelated rows in another session as a substitute. Do not alter the function or manually release claims. The immediate next approval request must specify which alternative and exact execution transaction is approved; this package does not authorize either.

## 3. Supervised execution after separate approval

1. Refresh all preflight immediately; confirm the approved population, historical hashes and disabled scheduler. Reconfirm DEV identity and recovery point.
2. Use only the separately reviewed execution transaction. Set bounded lock/statement timeouts in that transaction; abort rather than waiting indefinitely. Record start/end times, returned count and any error. For a guarded exact-two transaction, use a single SQL Editor execution containing all guards, invocation, verification and commit; never depend on session continuity between editor runs.
3. The existing function locks claim → lease → listing → task, then source donation/batch/inventory rows. Other writers can cause waits, skipped claims, deadlocks or timeouts. Do not retry automatically or relax checks. An exception rolls back the invocation within its transaction; explicitly end/roll back an aborted explicit transaction before further work.
4. Safe branch: claim/lease RELEASED with EXPIRED_SAFE_RELEASE reasons and closed timestamps; task STALE; listing AVAILABLE with version +1; direct donation AVAILABLE or hub-member donations BATCHED. Hub batch stays PUBLISHED and inventory BATCHED. Recovery creates a SUCCESS/RELEASED audit event.
5. Uncertain branch: claim/lease RECONCILIATION_REQUIRED; task is not made STALE by this branch; listing/custody are retained; an OPEN case is inserted if absent and audit records reconciliation. Missing inventory/cases or expiry races must not be "fixed" by direct SQL. Under exact-safe-release-only scope, postconditions must abort the transaction; broader batch approval must explicitly permit and retain these outcomes for review.

## 4. Read-only postflight and stop conditions

Run `expired_claim_recovery_postflight_readonly.sql` R01–R03, then its listed D01–D06 and P02/P04/P06 checks. Compare exported pre/post rows and audit event IDs, not just counts. Require both target safe-release flags true, expected custody/version changes, no new target routing references or unresolved cases, historical claim/lease/task hashes and counts unchanged, and scheduler still disabled. Check the entire queue for unrelated effects.

Any remaining ACTIVE target, reconciliation outcome, count mismatch, unexpected custody change, audit mismatch, timeout, skipped claim or historical-row change means STOP. Do not call recovery again blindly. Capture fresh diagnostics and request review. A committed call should be atomic, so apparently partial results may indicate skipped selection, another writer or an observation race; investigate rather than repair automatically.

Before commit, an approved transactional wrapper can roll back the complete operation. After commit, do not reverse statuses, decrement versions, erase audit events, or reactivate the historical claim. Escalate for a reviewed state-aware correction. Restoring a full backup can discard unrelated changes and is not a routine claim-level undo; rehearse restoration separately if needed. Neither recovery success nor this runbook lifts migration 003 HOLD: remaining security/cutover/graph-worker readiness checks and explicit deployment approval still apply.
