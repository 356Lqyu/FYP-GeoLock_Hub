# Stage 3D: remaining two controlled recoveries

Preparation and isolated validation only. No live recovery was executed.
DEV inspection used SELECT-only Supabase MCP for rcgyuwiidqvrgbxswhqj,
supabase_read_only_user, transaction_read_only=on. Never access shared project.

**Verdicts**

- Step 1 aa3cd6d2-e5b3-4369-a41f-ec9a0eaae716: GO for separately approved manual execution.
- Step 2 9a2ab42b-52c6-4c3a-99fb-b5c95d41e63f: GO only after step 1 COMMIT is verified.
  Running step 2 now, or after a failed step 1, is NO-GO and fails its order guard.

**Current DEV evidence**

Last snapshot 2026-10-22 18:18:09 UTC (2026-10-23 02:18:09 MYT).
Before/after complete snapshots matched for all three known claims and their
leases, tasks, listings, donations, audit rows and refresh jobs. Recovery source
and cron definitions matched. Two overdue candidates remain, in step 1/2 order.

| Record | Step 1 | Step 2 |
|---|---|---|
| Claim | aa3cd6d2-e5b3-4369-a41f-ec9a0eaae716 | 9a2ab42b-52c6-4c3a-99fb-b5c95d41e63f |
| Lease | 364102f4-a020-44a8-8e7d-e2aa1bc3a3b7 | f3a5e81d-bb3e-48c4-a317-b6987e88e0be |
| Lease expiration UTC | 2026-10-22 00:31:43.636107 | 2026-10-22 01:31:05.383307 |
| Listing | d7953dd2-7809-4cb4-87f3-52fc3294685b | 16e5b6a1-475d-4c5a-9460-d4834dd5640f |
| Donation | 3c32d1ae-ea3c-452c-8a76-9e05a0ad911a | 0c8f21b4-2e87-466c-bc29-dc15c78f4a04 |
| Task | aaa3429b-4ded-4ae2-865c-784abe41466d | a918031f-c786-4b5f-8823-86bc7a880a05 |
| Listing version/generation | 2 / 1 | 4 / 2 |

Both have ACTIVE claim/lease, expired 360-minute lease, CONFIRMED task,
DIRECT_DONATION listing CLAIMED with NULL expiration and DIRECT_PICKUP donation
CLAIMED. Zero active assignments, route stops, reconciliation cases, recovery
audits, hub inventory, memberships, receipts or reservations for either target.
No unexpected active client transactions, relevant locks or unfinished cron runs
were observed. Job 3 remains inactive with zero runs; jobs 1/2 active and their
latest observed runs succeeded at 18:18 UTC.

Claim 323ca3b3-7d7f-438e-8ed7-415f61b3a567 remains RELEASED with its lease RELEASED,
task STALE, listing/donation AVAILABLE, listing version 3/generation 2, two correct
recovery-related audits and completed generation-2 refresh. No reconciliation.

The second listing also has an older RELEASED claim
e1e0d0f5-007f-4857-b232-06d9c861b102 (RELEASED lease, STALE task). Its claimed_at
precedes the current candidate, so the lifecycle audit helper selects the current
claim. That historical claim's own rows must remain unchanged; its shared listing
legitimately changes when the current claim is recovered.

**Final files and SHA-256**

All SQL files are under supabase/tests/fixtures, not migrations.

| File | SHA-256 |
|---|---|
| claim_recovery_remaining_01_aa3cd6d2.sql | 84AD7C5E3FF60041838987D627BD611948CA4DE22683E5973FD2E8FE29BCBBBC |
| claim_recovery_remaining_02_9a2ab42b.sql | 3D7F4B08747E8755115B36AD3340A9237499C60A3C8B60D5514B644385E9DE32 |
| claim_recovery_remaining_preflight.sql | 6D02265F7651382733926870171DC044359B1B1D1A695AEC5CCF25F395ABD9A4 |
| claim_recovery_remaining_verify_0.sql | 79F5AF51FA69770EE24C47878C5F026EEA91B534172109E730FB429175F8DD63 |
| claim_recovery_remaining_verify_1.sql | 7D4BE5657D7E27B31CF387119B88E58121F5C275FE2BD37C317C64B463C77283 |
| claim_recovery_remaining_verify_2.sql | 0DF15772B4D120B4C287C08E7C48FBD75B2DF1912E6454F9C4E9BF099B343B09 |

**Adaptations from the tested Stage 3B wrapper**

Exact target IDs, original deadline, 360-minute lease duration, current version
and generation are pinned. Each file calls recover_expired_claims(1) once.
Step 1 expects overdue order [aa3cd6d2...,9a2ab42b...]; step 2 expects only
[9a2ab42b...]. EXCLUSIVE NOWAIT claim/lease locks freeze candidate writes and
competing recovery selectors; target locks follow claim/lease/listing/task/donation.
Owned row locks are not skipped by the same transaction's recovery invocation.

v_watched always contains all three original claims for scoped audit and case
checks. v_expected only controls the remaining candidate order. This preserves
the corrected scoped audit design without reverting to a global event count.
Exactly two new relevant, fully matched events are required per transaction.
Existing prior recovery audits belong to the before-snapshot and do not count.

Prior controlled recoveries must already have complete RELEASED/STALE/AVAILABLE
states, close reasons/timestamps and both successful audits. Every other known
claim's linked rows are snapshotted and compared. Added whole-database snapshots
of non-target claim/lease/task rows also protect historical claims, including
ones sharing the current target listing. No extra locks or updates to those
historical records are introduced.

Preserved verbatim: approved recovery fingerprint/security/default/return/ACL
guard, cron-state guards, source function itself, single-call limit, deferred
constraint checks, strict target task snapshot, version/generation increments,
audit payload checks, eligibility enqueue assertion, transaction/timeouts and
COMMIT. No exception handler swallows failures. One failed transaction cannot
undo an already committed separate transaction.

**Expected effects for EACH target**

- donation_claims and claim_leases: RELEASED, EXPIRED_SAFE_RELEASE, closed_at set.
- pickup_tasks: CONFIRMED -> STALE, all other task fields preserved.
- listings: CLAIMED -> AVAILABLE; step 1 version 2->3 and generation 1->2;
  step 2 version 4->5 and generation 2->3. Expiration remains NULL.
- donations: CLAIMED -> AVAILABLE; normal updated_at trigger change permitted.
- audit_events: one LEASE_RECOVERY and one DONATION_STATUS_CHANGED, correct IDs,
  actor, state transition, reason/outcome and details. Four new events across both.
- ngo_listing_road_eligibility: invalidate only target cached results.
- listing_eligibility_refresh_jobs: enqueue only target's new generation.
- No new reconciliation cases, route changes or cron changes.
- Other claim/lease/task rows, and the previous controlled recovery, unchanged.

**Tests**

PostgreSQL 17.11, Python 3.14: 43/43 isolated tests PASS (118.373 seconds).
71/71 existing offline source contracts PASS. git diff --check PASS. The expanded
SELECT-only preflight was then rerun in a new isolated read-only transaction:
1/1 targeted rerun PASS (12.321 seconds). The recovery SQL files did not change.

Each setup runs the complete approved Stage 3A patch in a fresh disposable fixture,
then the actual Stage 3B wrapper to reproduce the committed previous recovery.
The prior completed eligibility refresh is represented by fixture queue/cache
state; the real eligibility worker is not run. A historical released claim is
included to check shared-listing semantics. Both new files run whole, including
DO assertions, SET CONSTRAINTS ALL IMMEDIATE and COMMIT.

Coverage for BOTH wrappers: successful COMMIT; wrong role; source/ACL drift;
unexpected active recovery cron; changed/displaced candidates; new older candidate;
changed task/version; damaged prior recovery or missing prior audit; wrong return;
wrong/extra relevant audit; missing enqueue; deferred constraint failure; NOWAIT
table conflict; five-second enqueue lock timeout after recovery updates; mutation
of a non-target historical task. All failure cases compare complete before/after
snapshots from a separate connection to prove recovery writes rolled back.

Sequential coverage: step 1 COMMIT verified, then step 2 COMMIT verified; both
read-only postcondition query files return three true rows. Previous recovery,
its audits/cache/jobs and the first remaining claim stay unchanged during step 2.
Step 2 before step 1 is rejected; second-step failure preserves the first commit;
both files reject replay after completion. New query files are actually parsed
and executed, not merely inspected.

Nine actual function body fingerprints (recovery, six lifecycle helpers and two
listing trigger functions) match current SELECT-only DEV inspection. Actual
listing trigger code executes against reduced tables and a fixed road resolver.
Auth functions, cron tables and routing resolution are explicit test doubles;
no real pg_cron, eligibility workers, PostGIS/pgRouting, Supabase SQL Editor,
storage/RLS or complete production constraint graph is integrated. Wrong-return
tests inject v_count=0 in test-only wrapper variants after the actual recovery(1)
call. Source/ACL fault tests alter only the disposable clone, never DEV.

**Manual procedure AFTER separate approval**

1. Stop application writes briefly; verify DEV project selection, clean postgres
   current_user/session_user, NULL auth.uid(), no unrelated pending transaction.
   Leave eligibility cron jobs 1/2 active and recovery job 3 inactive.
2. Run claim_recovery_remaining_preflight.sql and verify_0.sql (SELECT-only).
   Require all three all_checks_pass flags true and exactly the two ordered
   candidates. Inspect full snapshots, custody evidence, cron health and locks.
3. Execute the COMPLETE step-1 recovery file once. Confirm actual COMMIT, then
   run verify_1.sql and the preflight/health queries again. Snapshot evidence.
4. Proceed to the separately controlled step-2 execution only after first outcome
   verified. Run the COMPLETE step-2 file once, then verify_2.sql and health queries.
5. A NOTICE is not COMMIT proof. On any error ROLLBACK explicitly, inspect records
   and investigate before any retry. Do not combine steps into one batch or auto-retry.
6. Confirm target refresh generations 2/3 subsequently COMPLETED, no queue errors,
   cron 3 inactive/zero executions, jobs 1/2 unaffected. Refresh Flutter; both
   targets should move to History/Released, previous released claim stays there.

**Risks and boundaries**

These are point-in-time GO verdicts conditional on locked guards at execution.
Broad table locks briefly block claim/lease writers. NOWAIT/5-second lock/50-second
statement timeouts can fail under legitimate worker contention. Cache, road
coverage, routing resolution, production constraints and audit triggers can abort
the transaction; actual DEV integration cannot be proven by the reduced fixture.
No script can exclude privileged concurrent DDL, arbitrary direct writes or cron
activation without operational coordination. No record proves physical custody.
Read-only verification is not a replacement for preserving the pre-execution
snapshot, and new activity after COMMIT can legitimately change later observations.
No automatic recovery activation is included or authorized.

The original Stage 3B wrapper remains at approved SHA-256
2D4833146341D45ECB97829A7E72AC3F2C8908561DC658C0D7605E28342D3E02.
The Stage 3A migration remains at approved SHA-256
064B1E4CD5B5CD38E1F77B91364AF5ED99221926455D5D64AE7A4B70C1C31E7D.
No deployed migration, function, grant, application code, DEV record or cron
setting was modified. Stop here and await explicit execution approval.
