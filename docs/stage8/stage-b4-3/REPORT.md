# Stage B.4.3 — Claim Lock-Ordering Correction and Local Regression

**Status: COMPLETE for approved local implementation and verification.** Candidate 2 removes the observed claim-listing lock upgrade and passed three bounded 2/5/10-actor schedules plus the current composed-schema regression suite. It is **ready for a separate deployment review only**; it has not been deployed or tested against DEV/shared/production Supabase.

## Pre-change compatibility review

The current composed function is `public.claim_listing(uuid,uuid)` from `supabase/migrations/20261031_claim_audit_and_failure_capture.sql:198-327`. Its only listing write sets `listing_status='CLAIMED'` and increments `listing_version` (`:260`); it does not update `listing_id`, `donation_id` or `batch_id`. The listing primary key is `listing_id` (`geolock-v3-public-schema.sql:3305-3309`); partial unique indexes use `donation_id` and `batch_id` (`:3475-3482`). The listing transition trigger (`:940-951`, installed at `:3549-3552`) only validates allowed status transitions and returns `NEW`; it does not change key columns.

The 20261031 claim function takes the listing lock at line 237 and then calls `geolock_lock_listing_donations` at lines 250-251. That helper is defined by `supabase/migrations/20261027_persisted_donation_lifecycle.sql:126-164`; its first operation re-locks the same listing `FOR UPDATE` at line 133. Stage B.4.2 had established that request insertion first takes an FK key-share lock through `claim_requests_listing_id_fkey` (`geolock-v3-public-schema.sql:3602-3606`). The first candidate changed only the claim function lock; corrected-path diagnostics showed the helper still upgraded the row lock. Candidate 1 is preserved and explicitly rejected as insufficient.

With both claim-path locks set to `FOR NO KEY UPDATE`, PostgreSQL still serializes those claim writers against each other and against `UPDATE`/`FOR UPDATE` listing writers, while the lock is compatible with the FK key-share lock. This aligns the explicit lock with the non-key `UPDATE` of status/version fields. Claim request advisory locking, request-row locking, donation/batch locks, claim/lease/task creation, audit writes and route authorization remain unchanged. Cancellation, recovery, pickup and reconciliation retain their existing claim → lease → listing ordering; route publication retains its sorted claim/lease/listing locks (`20261102_routing_publication.sql:12-21`). Their stronger listing locks were not weakened.

## Forward migration

The deploy-review candidate is [20261105_b43_claim_and_donation_lock_no_key_update.sql](migrations/20261105_b43_claim_and_donation_lock_no_key_update.sql). It recreates only:

- `public.claim_listing(uuid,uuid)`, changing the listing read at migration line 69.
- `public.geolock_lock_listing_donations(uuid,text[])`, changing the listing read at line 170.

The second change is required: diagnostics for failed candidate 1 show `claim_listing` holding `FOR NO KEY UPDATE` and then deadlocking inside `geolock_lock_listing_donations` at its `FOR UPDATE` (`corrected-lock-diagnostic-run-01/postgresql-server.log`). Candidate 2 changes exactly those two lock clauses; the source-to-candidate comparison is [migration-diff-check.json](../../../results/stage-b4-3/migration-diff-check.json), which confirms no other function-body differences.

The migration is transaction-wrapped and fails closed on unexpected source hashes or function metadata. It snapshots and checks function ACLs. On the fresh local clusters, both functions retained their signatures, arguments, return types, owners, security-definer flags, search paths and ACLs; see `claim-function-compatibility.json` in each corrected run. `claim_listing` remains owned by `postgres`, `SECURITY DEFINER`, with its existing `search_path`; the helper remains postgres-owned, invoker-security, and owner-only.

## Results

| Run | Result |
|---|---|
| Original uncorrected function, fresh current-package cluster | Baseline reproduced: 2 actors yielded 1 success/1 conflict; 5 actors yielded 1 success/1 conflict/3 `ERROR`; 10 actors yielded 1 success/9 `ERROR`. Failure rows record SQLSTATE `40P01` and rollback confirmation. See `baseline-current-function-run-01`. |
| Candidate 1, claim function lock only | **FAIL; rejected.** Across three repetitions, three of nine size schedules still deadlocked. Detailed statement/context is in `corrected-lock-diagnostic-run-01/postgresql-server.log`; this identified the helper lock upgrade. The initial candidate remains at `migrations/20261104_b43_claim_listing_no_key_update.sql` as preserved failed evidence, not the proposed migration. |
| Candidate 2, both claim-path locks | **PASS: 9/9 listing schedules**, comprising three each at 2, 5 and 10 actors (51 claim attempts total). All yielded exactly one winner per listing and `CONFLICT` for every other claimant; zero SQLSTATE `40P01`, zero duplicate active claims/leases/tasks. Replay and request-id misuse checks, final-state invariants and audit/rollback checks passed in each schedule. See `corrected-claim-runs-03`. |
| Composed-schema compatibility and regression | **PASS: 18/18 tests**, including lease expiry/fail-closed behavior, pickup retry, required-audit rollback, route/candidate forgery, reserved-task recovery, cancellation/start ordering, schedule tampering, unauthorized entrypoints, reconciliation/completion, route capacity/window/duration negatives, and both pickup/recovery orderings. See `full-regression-run-01/results.json`. |

The composed package uses the Stage B schema snapshot, selected current lifecycle migrations and reviewed local routing forward migrations, with declared local Auth/Storage/road/cron doubles. It is current full-schema evidence, but not a live Supabase/PostGIS or DEV integration test. No formal Chapter 5 experiments ran.

## Preserved invariants and limits

- **Atomicity/exclusivity — CONFIRMED in tested schedules:** one active claim, lease and pickup task per exclusive listing; losers receive conflict.
- **Idempotency — CONFIRMED:** same request replay returns the prior successful claim; reusing the request ID with another payload is rejected and audited without creating a second claim.
- **Audit/rollback — CONFIRMED in tested suite:** claim state invariants and failure audit rollback checks pass; the existing required-audit failure regression passes.
- **Lease — CONFIRMED unchanged by migration:** the migration does not edit lease configuration or issuance logic. The composed schema constrains `claim_lease_minutes=360` (`geolock-v3-public-schema.sql:2557-2568`); lease-expiry and recovery regressions pass.
- **RLS/privileges — CONFIRMED unchanged:** no table grants, policies, role checks or function ACLs were altered; local catalog comparisons match before/after.
- **Routing, pickup, lifecycle and teammate algorithms — CONFIRMED unchanged by diff:** the only function-body changes are the two listing-lock clauses. Route/pickup authority regression cases pass.
- **Risk — POTENTIAL residual:** no finite set of schedules proves all possible deadlocks absent. The targeted contention reproduced the previously failing overlap repeatedly without deadlock after candidate 2; independent DEV compatibility and operational load review remain outstanding.

## Recommendation

**Candidate 2 is ready for a separate migration/deployment review.** Review the two-function diff, migration pre/post guards, current DEV source/ACL fingerprints and rollback approach before authorizing any deployment. Do not use candidate 1. No deployment, DEV inspection, production change, Flutter change, Stage B.3 change, candidate-hash change or hub algorithm change occurred in this stage.
