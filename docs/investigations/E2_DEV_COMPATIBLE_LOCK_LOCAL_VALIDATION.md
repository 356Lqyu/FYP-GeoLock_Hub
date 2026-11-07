# DEV-compatible E2 lock candidate — LOCAL PASS

5 November 2026. **LOCAL PASS for the exact new candidate. Deployment remains blocked pending recovery/history prerequisites and a fresh separately approved preflight. Nothing was deployed or changed on DEV.**

## Separate forward and rollback SQL

- Forward: `docs/investigations/e2-dev-compatible-lock/proposed_migration.sql`
- SHA256: `655976ab697031c3025e78ad967db4e7f6a755e091a21031de2d3a8e441fee8c`
- Rollback: `docs/investigations/e2-dev-compatible-lock/rollback_patch.sql`
- SHA256: `3209f20240bc19bda4cac7e3cc656179247fd76640ce979d643b15ba38604cd6`

The original locally validated forward/rollback files remain unchanged under e2-shared-lock-review. These new files are outside supabase/migrations. They were applied only to fresh disposable loopback PostgreSQL databases.

## Exact differences from the original candidates

For each SQL file, only three `expected` JSON ACL strings changed. Every other byte of the SQL, including all fingerprint/caller/trigger/anchor/postcondition checks and both function patches, is identical after excluding that JSON segment. EXACT_DIFFERENCES.json records the precise field comparison.

| Function | Original expected EXECUTE grantees | New expected/captured DEV grantees |
|---|---|---|
| claim_listing(uuid,uuid) | PUBLIC, postgres, authenticated | postgres, authenticated, service_role |
| cancel_claim(uuid,uuid) | postgres, authenticated | postgres, authenticated, service_role |
| submit_claim_reconciliation(uuid,boolean,uuid) | postgres, authenticated | postgres, authenticated, service_role |

Exact new ACL string for all three: `{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}`. Grantor remains postgres, without grant option. No permission-changing SQL was added to either candidate. No PUBLIC grant is introduced and service_role is not revoked. Owner, security-definer mode, search paths, constraints and unrelated business logic are preserved.

The functional change remains one listing FOR UPDATE→FOR NO KEY UPDATE acquisition in each of claim_listing and geolock_lock_listing_donations, and no other lock change. Corrected normalized body hashes remain c8d324772b12c843fba231e7ea733914 and e97a3fd80673a827465f3eaa79b65903. All original source checks remain in place against the original 2c1f60c876797c61b44b3cb43591bab8 and 90816e7c6db3606dc8b6451a899d8036 bodies.

The captured DEV baseline is the prior read-only preflight, not a new live connection. This task made no Supabase calls. Local fixture permissions were reproduced using acl-fixture.sql inside new databases only. **That fixture file is not a DEV deployment script.**

## Fresh local validation

**43 focused checks/tests passed: 32 primary SQL checks plus 11 custody/reconciliation/route lifecycle tests.** The 32 checks were also repeated successfully in the full benchmark's fresh database before formal scenarios.

Evidence:

- Focused run: experiments/e2_atomic_claiming/results/e2-dev-acl-focused-20261105-01.
- Custody receipt: e2-dev-compatible-lock/custody-tests.json, referencing the new timestamped automatic-routing-local evidence directory. Eleven tests, zero failures/errors.
- Full run: experiments/e2_atomic_claiming/results/e2-dev-acl-full-20261105-01.

The original candidate rejected the DEV ACL fixture with `CALLER_SOURCE_OR_METADATA_DRIFT: public.cancel_claim(uuid,uuid)` before replacing either function. That expected rejection is preserved in original_candidate_rejection.json. The fixture setup was then committed separately, and the exact new candidate accepted it.

The full-run catalog comparison covered **193 functions** across public/routing_private/resolution_private/fleet_private. Exactly two prosrc fields changed, in the intended functions. All other captured source/metadata, including grants, ownership, security modes and search paths, remained unchanged. See all_metadata_preservation.json. Both corrected source hashes and metadata stayed stable through the run.

Effective permission checks verified all three protected functions deny anon execution and retain authenticated/service_role execution. The private helper remains protected under the existing guards. These are execution privileges; unchanged body-level actor/ownership authorization remains required.

Tests passed for distinct 2/5/10 NGOs, clean conflicts/single ownership, same/different/concurrent UUIDs, controlled FK interleaving, cancellation/recovery races, expired and active leases, fault rollback/receipts, ordinary-user receipt protection, unauthorized/ineligible actors, source/security/grant drift, disabled listing trigger rejection, safe repeat-application rejection and rollback/reapply. Custody tests cover matching handover/no-handover, review rounds/receipts, ownership/version checks, concurrent resolution, incident/collection/missing-lease blockers, depot/dispatch race, expired source windows and whole-batch hub collection. No trigger or constraint was disabled to make positive tests pass; deliberate negative-control changes were rolled back.

Guarded rollback restored the original bodies and forward reapplication restored the corrected bodies with identical privileges. Rollback still requires the corrected source and reviewed DEV ACL baseline, restores the original deadlock exposure, and does not undo claims, reset leases, erase evidence or perform database recovery. It is not a substitute for a verified backup/restore plan.

## Complete frozen E2 rerun

Run ID: **e2-dev-acl-full-20261105-01**. **275/275 completed**, zero fixture/execution failures and a successful cluster shutdown.

| Measurement | Result |
|---|---:|
| Contention scenarios | 150/150 |
| Exactly one successful claimant / committed active claim | 150/150 |
| Successful contention requests | 150 |
| Clean losing conflicts | 700 |
| Duplicate active claims | 0 |
| Measured 40P01 deadlock errors | 0 |
| Other measured database errors | 0 |
| Expired-lease recovery/replacement | 100/100 |
| Incorrect active-lease releases | 0/25 |

| Concurrent requests | Trials | Median ms | p95 ms |
|---|---:|---:|---:|
| 2 | 50 | 119.600 | 183.375 |
| 5 | 50 | 134.300 | 203.750 |
| 10 | 50 | 182.900 | 324.770 |

These are new measurements for this exact candidate, not copied PASS results. Raw requests, scenario/committed states, input/source/environment manifest, exact applied_candidate.sql, completion/shutdown receipts and comparison CSVs are retained in the new run. Deliberate negative-control failures are retained separately from measured benchmark error audits.

Historical comparison: the original proposed run had 150 successes, 9 clean conflicts and 691 40P01 errors with zero duplicate ownership; existing protected baseline had 150 successes/700 conflicts/zero errors; non-atomic duplicated ownership in 150 trials. Both corrected candidates produced clean contention and protected recovery in their separate complete runs. Timing differences across executions are descriptive, not significance or causal speed claims. No formal sample pooling, E4 change or new supervisor approval is inferred.

Original GEOLOCK-BM-v3.3 scenarios, request parameters, matrix, relative-age replay, driver/retry behavior and 360-minute leases are unchanged. The same documented synthetic Auth/Storage/cron/frozen-road adapters remain; this is actual protected PostgreSQL SQL execution, not hosted Auth/device/end-to-end performance or a proof against every possible future deadlock schedule.

## Remaining deployment blockers

LOCAL PASS does not establish current deployment readiness. The prior preflight's missing current backup/verified isolated restore remains unresolved. No backup or restore operation occurred here. A current-baseline capture, compatible isolated restore/comparison receipt, recovery operator and write-gap/cutover plan need separate authorization and verification. Existing historical export checks do not meet that requirement.

The app migration ledger was absent in the captured preflight; no final coordinated version was assigned. Reconcile the owner's manual history, reserve a fresh unused forward version and record project ref, final SHA256, baseline/post hashes, operator/approval, execution output and postchecks in the agreed receipt/ledger workflow. Do not reuse the failed claim-only identifier or retroactively rewrite old migration history. No ledger was created or repaired here.

Before requesting deployment approval, perform a fresh read-only DEV preflight against **this new candidate**, including all 29 source/metadata expectations, new callers, keys/triggers and the recovery/history receipts. The captured ACLs can drift after capture. The new metadata expectations should not be treated as permission to widen/revoke any DEV grant. No deployment command is authorized by this report.

## Reproduction and files

Exact local commands: docs/investigations/e2-dev-compatible-lock/REPRODUCE.md. Use new run IDs. The fresh full controller is run_dev_acl_full.py; it first proves original-candidate rejection, validates exact metadata preservation, repeats focused tests, and requires a custody pass before any frozen scenario. Optimized Python is rejected. The existing summarize_corrected.py reads historical comparisons and writes only to the new run.

Added scripts: experiments/e2_atomic_claiming/run_dev_acl.py, run_dev_acl_full.py, dev_acl_regressions.py and dev_acl_custody_tests.py. Added review package: e2-dev-compatible-lock/{proposed_migration.sql,rollback_patch.sql,acl-fixture.sql,EXACT_DIFFERENCES.json,custody-tests.json,REPRODUCE.md,VERIFICATION.json,ARTIFACT_MANIFEST.json}, this report and the new run directories. Existing SQL, frozen inputs, historical results, Flutter and routing source remain unchanged. All task-owned PostgreSQL clusters and local custody test processes were shut down; evidence was retained.

**Decision: LOCAL PASS. Not ready for DEV deployment approval until fresh preflight, recovery verification and version/history prerequisites are satisfied. Stop here and wait for explicit deployment approval.**
