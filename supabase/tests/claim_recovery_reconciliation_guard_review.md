# Stage 3F: automatic claim-recovery reconciliation guard

**GO for separately approved manual DEV deployment of this fix. Not deployed.**
This verdict does not authorize recovery execution or cron activation. Job 3
remains inactive and requires a separate post-deployment readiness decision.

## Artifact

Migration: C:/Users/User/Downloads/FYP-GeoLock_Hub/supabase/migrations/20261030_fix_claim_recovery_unresolved_reconciliation.sql

SHA-256: E70759E708E966BB4BCD4528BA166F40C032C298D24DDC71AF434D00C98DB7CC

Normalized function-body fingerprints:

- Expected deployed original: 50110ff20115c4e5d46380e8e3f8b94c.
- Final Stage 3F replacement: 5ff6d8719db9681aae6f444b89dfbaee.
- Superseded Stage 3E claim-only proposal: 805c8b8eb070dc8c3ee50d5699ed033d.

The Stage 3E proposal and previous deployed migrations were not edited. The new
migration is forward-only, BEGIN/COMMIT atomic, and replaces only recovery's body.
No data backfill, recovery invocation, grants, ownership changes, cron mutation,
temporary objects, transaction-end cleanup, routing edits or application edits.

## Root cause and correct behavior

Recovery selected overdue ACTIVE/ACTIVE pairs and assessed task/route, donation,
batch and listing evidence, but omitted existing unresolved reconciliation cases.
The safe branch could release and reopen even though a case retained OPEN or
MANUAL_REVIEW. Case FK/CHECK constraints do not couple its status to claim/lease
status, and DEV has no non-internal triggers enforcing that coupling. This is an
inconsistent-data contingency; no normal supported RPC path creating it was found,
and no such data is present in DEV.

The Stage 3E claim-only proposal fixes the current claim's case, but an additional
isolated test showed that an older RELEASED claim's unresolved case on the SAME
listing could still be ignored. That older case is relevant custody evidence for
the listing being reopened. The final guard therefore uses claim OR listing:

```sql
-- Unresolved custody evidence for this claim or listing fences reopening.
v_uncertain := exists(select 1 from public.claim_reconciliation_cases rc
    where (rc.claim_id=v_c.claim_id or rc.listing_id=v_l.listing_id)
      and rc.case_status in ('OPEN','MANUAL_REVIEW'))
  or v_l.listing_id is null
  -- all existing uncertainty predicates continue unchanged
```

This is the only executable recovery-body difference from the deployed original.
It runs after claim -> lease -> listing -> task locks. No new case lock or writer
lock order is introduced. Normal case/custody writers already serialize through
claim/listing locks. Arbitrary privileged SQL that bypasses that protocol remains
outside the guarantee.

For an applicable unresolved case:

| Object | Outcome |
|---|---|
| Current claim and lease | RECONCILIATION_REQUIRED; no safe-release close reason/timestamp |
| Existing OPEN/MANUAL_REVIEW case | Every field preserved |
| Current claim without its own case, but older case on same listing | Create current claim's OPEN case through existing unique-per-claim insertion; retain older case |
| Pickup task | Unchanged; no STALE transition |
| Listing | Remains CLAIMED; version and generation unchanged |
| Direct donation / whole hub member set | Remains CLAIMED; inventory unchanged |
| Audit | Existing LEASE_RECOVERY/SUCCESS accepted-reconciliation audit; requested/resulting RECONCILIATION_REQUIRED and existing uncertainty reason |
| Donation transition audit / eligibility cache / refresh enqueue | No release transition audit, invalidation or enqueue for the fenced claim |

Repeated recovery excludes the resulting reconciliation pair, so it neither
duplicates audits/cases nor later reopens it. Unrelated listings' cases do not
fence healthy recovery. The three prior RELEASED claims remain ineligible.

## Batch handling decision and tradeoffs

An unsafe candidate is handled individually by the existing reconciliation branch;
it does not abort healthy candidates in the same call. The direct/hub matrix test
processed four fenced cases plus two safe candidates in one call: four cases were
preserved and two safe listings reopened with the correct refresh jobs.

Real SQL errors and lock/statement timeouts still abort the whole invocation. A
later-candidate audit failure rolled back an earlier reconciliation transition and
all new audits/enqueues; retry after removing the injected fault succeeded.
Per-candidate savepoints/error swallowing could improve liveness, but would change
atomicity, error/audit persistence and retry behavior. It was not introduced.
An oldest persistently failing candidate can still starve a batch; operational
alerts and manual investigation remain necessary. Start any separately approved
future cron rollout conservatively, not by increasing timeouts or silently skipping
records. This task does not prepare or authorize a new cron change.

## Security, compatibility and migration guards

Preserved exactly: recover_expired_claims(p_limit integer DEFAULT 100) RETURNS
integer; owner postgres; SECURITY DEFINER; search_path pg_catalog, public,
extensions, pg_temp; ACL {postgres=X/postgres,service_role=X/postgres}; trusted
session/service-role check; no anon/authenticated grant or new grant option.

CREATE OR REPLACE preserves existing ownership/ACL. Exact original body, signature,
security and ACL drift guards reject unreviewed definitions or grant options before
replacement. Postconditions check the new fingerprint and the same metadata.
Failure after CREATE OR REPLACE was injected and proved to restore the original
function on transaction rollback. Reapplying the forward-only migration is rejected
by the original-source guard; do not rerun it after successful deployment.

Cron preconditions require exact paused job 3, postgres/current database,
one-minute schedule, original command with limit 100, zero execution history,
exactly one recovery schedule and active jobs 1/2. The migration has no cron write
statement and checks paused/active state again after replacement. Any mismatch
requires review rather than silently rewriting schedules.

Unchanged behavior includes the Stage 3A post-donation-lock listing expiry check
and restoration-failure exception; direct CLAIMED -> AVAILABLE; whole hub member
CLAIMED -> BATCHED; route/pickup/custody conservatism; SKIP LOCKED selection and
limits; 360-minute lease creation; audit statements; async eligibility triggers;
v2 claim-card reader; October audit/cancellation/reconciliation fixes; photo/storage
security; teammate-owned road/routing/hub recommendation/aggregation functions.
An offline exact-body comparison proves that everything following the new
uncertainty predicate, including all transitions and audits, is identical.

## Live read-only DEV evidence

Only rcgyuwiidqvrgbxswhqj was inspected, through read-only Supabase MCP.
current_user=supabase_read_only_user, transaction_read_only=on. Never accessed the
shared project. Initial snapshot 2026-10-22 19:01:06 UTC; final snapshot
2026-10-22 19:17:52 UTC (2026-10-23 03:17:52 MYT).

- All 86 public definitions/owners/security/search_path/ACL snapshots unchanged.
- All claim/lease/task/listing/donation rows and related audits/refresh rows in
  the captured joined snapshot unchanged, including all three controlled releases.
- Three released targets retain versions/generations 3/2, 3/2, 5/3, successful
  recovery/donation audits and completed latest eligibility refreshes.
- Zero overdue ACTIVE/ACTIVE claims, zero reconciliation cases.
- Cron definitions unchanged; jobs 1/2 active, job 3 inactive, zero job-3 runs.
- Unrelated public-function baseline: 85 functions, normalized definition/owner/ACL
  fingerprint 6991083a881075cdf0e75d0c266396f0, recorded for pre/post comparison.
- DEV recovery still has original body 50110ff20115c4e5d46380e8e3f8b94c.

No state-changing DEV SQL, migration execution, recovery call, stateful test,
cron update or deployed data repair occurred.

## Tests actually executed

PostgreSQL 17.11 in newly initialized disposable loopback clusters; no external
DSN accepted and inherited PG connection settings stripped. Full migration,
including its pre/post guards and COMMIT, runs in every new Stage 3F test setup.

| Test group | Result |
|---|---|
| All offline contracts, including five new exact-diff/security/drift contracts | 76/76 PASS |
| Final Stage 3F isolated migration/recovery suite | 45/45 PASS, 127.378 seconds |
| Complete post-deployment SQL against final source and recreated completed recoveries, BEGIN READ ONLY/ROLLBACK | 1/1 PASS, 13.686 seconds |
| Existing Stage 3A isolated expiration/recovery suite, independently rerun | 17/17 PASS, 44.241 seconds |
| Existing Stage 3E automatic safety suite, independently rerun | 23/23 PASS, 71.380 seconds |
| Whitespace and protected prior-migration SHA checks | PASS |

The Stage 3F file now contains 46 tests: the final 45-test run plus the subsequently
added, separately executed post-query test. Initial exploratory runs and test-query
typos were corrected and are superseded by these results; they are not added to
the totals. No passing result is inferred from static inspection.

The 45-test final suite includes:

- OPEN/MANUAL_REVIEW x direct/whole-hub matrix, unchanged existing case contents,
  unchanged custody rows and no release enqueue/audit for fenced candidates.
- Shared-listing historical review in direct and hub paths; original claim-only
  proposal's gap reproduced locally. That characterization test is evidence of
  the superseded proposal's failure, not a safety acceptance pass for that proposal.
- Safe direct/hub candidates continuing in the same batch; unrelated listing
  unaffected; repeated invocation/idempotency and zero-candidate behavior.
- Two concurrent recovery workers; case writer holding claim lock; lease extension;
  actual captured start/complete/cancel/claim/route-assignment RPC concurrency.
- Exact expiration boundary, future and NULL listing deadlines; direct/hub lock-wait
  expiry races; late-after-decision exception; dispatched/planned pickups and
  uncertain inventory; whole hub membership/inventory preservation.
- Configured batch 100 with 101 candidates; limit edge cases; SKIP LOCKED;
  genuine audit failure and lock/statement timeout rollback, followed by safe retry.
- Exact original IDs/versions for the three completed controlled recoveries,
  reproduced in the fixture: migration-only and repeated recovery leave their
  complete business/audit/queue snapshots unchanged.
- Metadata preservation, replay rejection, source/ACL/grant-option drift rejection,
  active cron precondition rejection, and postcondition failure rolling DDL back.

The NEW function is used for all reused acceptance/regression tests. The explicit
claim-only-proposal characterization installs the superseded source only in its
disposable clone. The independently rerun old suites retain their deliberate
old-defect reproductions. All real business transition tests use actual recovery,
six lifecycle helpers and deployed listing trigger source. Real captured claim,
pickup, cancellation and route-assignment RPC bodies are installed unchanged.

Fixture limitations: reduced tables; explicit auth/NGO profiles, cron tables and
road-resolution/eligibility doubles; no real pg_cron scheduler, full Supabase
RLS/storage policy graph, real PostGIS/pgRouting, batch immutability trigger or
complete production constraints. Router algorithms were not modified or claimed
to be validated by the doubles. Windows/local timing is not a production load
benchmark. The production metadata/source compatibility check is read-only; the
new body was compiled/executed in isolated PostgreSQL, not compiled in DEV.

## Read-only preflight and post-deployment queries

- C:/Users/User/Downloads/FYP-GeoLock_Hub/supabase/tests/claim_recovery_reconciliation_guard_preflight.sql
- C:/Users/User/Downloads/FYP-GeoLock_Hub/supabase/tests/claim_recovery_reconciliation_guard_postdeploy.sql

Both are standalone SELECT-only SQL Editor scripts. Preflight was executed via
read-only DEV MCP and passed; post-deployment script was actually executed in a
read-only isolated transaction on the new source, returning true for source/security
and all three completed-recovery checks without changing data. Neither invokes
recovery. Post-deployment script is not a claim that deployment already occurred.

Queries include full recovery definition, source/security flags, EXECUTE privileges,
cron settings/history, current overdue/case evidence, cross-claim case mismatches,
complete controlled-recovery snapshots, all-other-function fingerprint, active
transactions/locks, and detailed final-state/audit/refresh checks. Save preflight
results for comparison; do not confuse later legitimate application activity on
a reopened listing with a migration regression.

## Manual deployment conditions and remaining risks

After explicit user approval only:

1. Confirm DEV project selection and exact migration SHA-256. Use a clean postgres
   session, run preflight, inspect source/security flags and all current evidence.
2. Keep job 3 inactive; jobs 1/2 remain active. Confirm no manual recovery invocation
   is in flight. Coordinate a brief application-write maintenance window so pre/post
   data preservation comparisons are meaningful and old in-flight recovery code
   cannot continue unnoticed across function replacement.
3. Execute the complete new migration once, including BEGIN/COMMIT. Do not execute
   old migrations, recovery, test fixtures, Stage 3E activation SQL or seed data.
4. Confirm COMMIT, then run the post-deployment SELECT-only file. Require new source
   5ff6d8719db9681aae6f444b89dfbaee, unchanged security/other functions/cron/data and
   all three completed-recovery checks true. On error, ROLLBACK explicitly, inspect
   source/state and investigate rather than blindly retrying.
5. Leave automatic recovery inactive pending separate final source verification
   and operational rollout approval. Old Stage 3B/3D scripts whitelist the old
   source; Stage 3E canary template whitelists the superseded claim-only proposal.
   They intentionally fail against the final Stage 3F fingerprint and must not be
   used unchanged. No activation script was changed by this task.

Remaining risks are lock contention, whole-call rollback/starvation on actual
errors, large hub workload under timeouts, incomplete live scheduler/routing/RLS
integration coverage, and privileged writers bypassing coordination. The added
case lookup may need performance review at large case counts; no speculative
index/schema changes were introduced. Cases on unrelated listings are deliberately
not global release blockers. Cross-listing/donation linkage corruption requires
manual investigation; this is not a general data-repair migration. Database
records cannot prove unrecorded physical custody.

## Files created; no existing files modified

1. supabase/migrations/20261030_fix_claim_recovery_unresolved_reconciliation.sql
2. supabase/tests/claim_recovery_reconciliation_guard_contract_test.py
3. supabase/tests/claim_recovery_reconciliation_guard_isolated_test.py
4. supabase/tests/claim_recovery_reconciliation_guard_preflight.sql
5. supabase/tests/claim_recovery_reconciliation_guard_postdeploy.sql
6. supabase/tests/claim_recovery_reconciliation_guard_review.md

All paths are relative to C:/Users/User/Downloads/FYP-GeoLock_Hub. Previously
deployed migrations retain approved SHA-256 values verified by offline tests.
No Flutter, existing migration, teammate-owned SQL, deployed function, grant,
DEV record or cron schedule was changed. Await explicit deployment approval.
