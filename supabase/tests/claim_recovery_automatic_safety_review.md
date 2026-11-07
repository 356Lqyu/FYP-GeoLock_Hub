# Stage 3E Safety Review Report

**Recommendation: NO-GO for activating the currently deployed recovery job.**

One fail-closed gap was reproduced against the exact deployed recovery function:
an overdue ACTIVE/ACTIVE claim with an existing OPEN or MANUAL_REVIEW case is
released and its donation/listing reopened while that case remains unresolved.
The combination is absent from current DEV and no supported normal RPC path was
found that creates it. It is an inconsistent-data contingency, permitted by the
current independent FK/CHECK constraints. An explicit unresolved-case release
fence is required before unattended execution. This is not a regression caused
by the Stage 3A expiration patch or evidence that the three manual releases were
unsafe. Leave job 3 inactive pending approval, a forward-only fix and fresh review.

## Scope and live evidence

SELECT-only Supabase MCP, DEV rcgyuwiidqvrgbxswhqj only. MCP remained read-only;
observed user supabase_read_only_user, transaction_read_only=on. No shared project
access, live recovery, cron changes, data changes, stateful DEV tests or deployments.

DEV and isolated server versions: PostgreSQL 17.11; DEV pg_cron 1.6.4. Final
catalog snapshot: 2026-10-22 18:50:51 UTC. Final detailed claim snapshot:
2026-10-22 18:51:40 UTC (2026-10-23 02:51:40 MYT).

- All three controlled claims: RELEASED/RELEASED, EXPIRED_SAFE_RELEASE, STALE task,
  AVAILABLE direct listing/donation, correct recovery/donation audit records.
- Listing versions/generations: first 3/2, aa3cd6d2... 3/2, 9a2ab42b... 5/3.
  Each latest refresh generation COMPLETED without errors.
- Zero overdue ACTIVE/ACTIVE claims, zero reconciliation cases, three recovery
  audits. Full three-claim rows/audits/refresh-job snapshots unchanged during review.
- Job 3 inactive, zero runs, exact expected command and one-minute schedule.
  Jobs 1/2 active; latest inspected runs at 18:50 UTC succeeded. No duplicate
  recovery schedule was found. No unexpected relevant locks in the earlier snapshot.
- All 86 public definitions, owners and ACLs match the saved Stage 3A verified
  baseline; before/after Stage 3E source/security/configuration comparison unchanged.
  Routing, road-network, hub recommendation/aggregation, photo security, v2 reader,
  eligibility workers and October audit/cancellation functions were not overwritten.

Current recovery signature: public.recover_expired_claims(p_limit integer DEFAULT
100) RETURNS integer, owner postgres, SECURITY DEFINER, search_path pg_catalog,
public, extensions, pg_temp. Normalized deployed prosrc MD5 remains
50110ff20115c4e5d46380e8e3f8b94c. Explicit ACL postgres/service_role EXECUTE only;
anon/authenticated cannot execute, even with a forged role-setting test locally.
Supabase's trusted superuser supabase_admin has implicit access, as expected.
Client roles cannot CREATE in public/extensions/auth/cron and lack cron schema USAGE.
postgres has CONNECT, owns relevant public tables, and has public sequence USAGE.

## Findings by severity

| Severity | Finding | Evidence and required disposition |
|---|---|---|
| Critical | None confirmed in the inspected supported workflow paths | This is bounded evidence, not proof of all integrations or physical custody. |
| High H1 | Existing unresolved reconciliation is ignored for an ACTIVE pair | The deployed function tests task/route/donation/listing evidence but never existing case state before the safe branch. Two isolated fixtures with OPEN and MANUAL_REVIEW cases returned count 2, RELEASED/RELEASED, STALE, AVAILABLE, and retained both unresolved cases. Production case constraints have no cross-table state coupling. Require the minimal guard proposal before activation. No such rows exist in DEV. |
| Medium M1 | A single error can roll back every candidate in a batch and repeatedly starve recovery | No per-candidate exception/savepoint isolation. An injected second-candidate audit error twice rolled back the first release and all audits. Removing the fault allowed successful retry. Existing tests likewise prove second-candidate lock/statement failures roll back earlier work. This preserves atomicity; it requires alerts and operator intervention, not an unreviewed batch redesign. |
| Medium M2 | Logging exists, operational alerting is not established by these three jobs | cron.log_run and cron.log_statement are on, but these are records, not notifications. Failed calls have no committed failure audit because their transactions roll back. cron return_message can be only "1 row" and processed counts also include reconciliation. Monitor history, oldest overdue age, cases and postconditions together; assign an operator before rollout. |
| Medium M3 | Scheduler and full production integration/load remain untested for job 3 | Zero real cron executions; local pg_cron and full routing/storage/RLS production graph are unavailable in the fixture. Three successful manual direct recoveries do not benchmark 100 claims or large hub batches. Use an approved no-op canary, then observed real expirations, representative hub validation before broad rollout, and gradual limits. |
| Low L1 | Zero/negative limits do not disable recovery | Executed tests show 0 and negative limits process one claim; NULL uses 100 and values cap at 1000 in source. Disable through cron.alter_job, never by choosing limit 0. |
| Low L2 | Reconciliation reason codes are intentionally coarse | Expired listing, bad batch, route evidence etc. can share HANDOVER_OR_ROUTE_ACTIVITY_UNCERTAIN; SUCCESS means accepted processing, including reconciliation, not release. Join audit details to the case/listing/task. No unrelated audit refactor is proposed. |
| Low L3 | History retention needs an explicit policy | cron history is useful evidence; no cleanup/notification job is among the three configured jobs. Define retention/export separately, preserving investigation evidence. No retention SQL was executed or added. |

## Correctness, concurrency and security assessment

Candidates require BOTH stored statuses ACTIVE and expires_at <= clock_timestamp()
on PostgreSQL; future leases and terminal/reconciliation pairs are excluded. A
missing lease cannot be selected and must be detected by the readiness anomaly
query. The locked lease is rechecked after any wait; an isolated concurrent
extension caused recovery to return 0 with no release/audit.

The candidate cursor locks claims FOR UPDATE SKIP LOCKED, ordered by expiry then
claim ID. The writer prefix is claim -> lease -> listing -> task, then direct
donation or immutable parent batch, member donations in UUID order, inventory in
UUID order. Helpers revalidate whole membership, counts, inventory and collection
paths under locks. Healthy direct recovery restores CLAIMED -> AVAILABLE; whole
hub recovery restores every active member CLAIMED -> BATCHED in one transaction.

Actual deployed start_pickup, complete_pickup, cancel_claim, assign_task_to_route
and claim_listing source was captured via pg_get_functiondef and installed into
the isolated fixture. Concurrent real RPC tests verified: pickup wins before
expiry -> later recovery keeps PICKUP_IN_PROGRESS/CLAIMED and reconciles; recovery
wins -> start is rejected; valid cancellation wins -> no duplicate recovery;
recovery wins -> cancellation rejected; route assignment crossing expiration ->
PLANNED task/route retained and reconciliation; two concurrent new claim attempts
after reopening -> one winner with a 360-minute lease, other conflicts. The
production partial unique index fences ACTIVE/RECONCILIATION_REQUIRED claims per
listing. Road eligibility was an explicit ELIGIBLE test double in these RPC tests.

Two simultaneous recovery(1) sessions processed different candidates without
duplicate recovery audits. This does not create a global single-worker mutex;
manual calls/different cron jobs can still run together. The configured pg_cron
version serializes the same job ID, queueing later scheduled runs; different job
IDs/manual invocations are outside that scheduler guarantee. [pg_cron 1.6.4 docs](https://github.com/citusdata/pg_cron/blob/v1.6.4/README.md)

Task locking serializes supported route/custody writers. Arbitrary privileged
SQL bypassing the application's lock protocol is outside any tested guarantee.
Opposite-order or shared dependency locks can deadlock or time out; PostgreSQL
aborts one complete transaction, preventing partial committed transitions.
[PostgreSQL locking documentation](https://www.postgresql.org/docs/17/explicit-locking.html)

Stage 3A's expiration fix remains intact: evaluate expiration after donation/batch
locking; if a deadline crosses after that decision but before final restoration,
raise RECOVERY_LISTING_REOPEN_PRECONDITION_CHANGED and roll back. Direct and hub
lock-wait boundary tests and a late-after-decision rollback test all passed again.
Time can naturally pass after the final guard; this is not a promise that a finite
deadline remains in the future at COMMIT. Expiry still fences discovery/claiming.

Release updates, listing publication, lifecycle transition audits, eligibility
cache invalidation and refresh enqueue share the transaction. Actual deployed
listing generation/enqueue triggers and actual deferred lifecycle checks run in
the fixture. Exceptions and timeouts roll back claim/lease/task/listing/donation,
audits and enqueue/cache changes. No automatic reopening follows pickup progress
in tested supported paths. H1 is the explicitly reproduced exception for existing
unresolved case evidence with inconsistent ACTIVE statuses.

## Tests executed in this review

| Suite | Final result | What actually ran |
|---|---|---|
| Existing offline source contracts | 71/71 PASS | No database access. |
| Existing expiration/lifecycle isolated suite | 17/17 PASS, 44.142 seconds | Entire Stage 3A migration, actual recovery/helpers/triggers; direct/hub race, idempotency, rollback, route and custody scenarios. Includes old-source race reproduction as a characterization test. |
| New automatic safety suite | 23/23 PASS, 65.192 seconds | Actual approved recovery plus captured real RPCs, concurrent sessions, configured 100-of-101 batch followed by remaining one, 0/negative/NULL limits, future/exact boundary, mixed direct/hub safe/unsafe, retries, permissions, H1 reproduction and review-only guard/package tests. |
| Exact proposal package targeted rerun | 4/4 PASS, recorded separately | Complete BEGIN/preflight/CREATE OR REPLACE/postflight/COMMIT, case fencing, safe direct/hub behavior, source and ACL drift rejection. |
| Read-only readiness SQL | Executed successfully against DEV | SELECT-only catalogue, backlog, cases, audit, queue, cron history and lock queries. No recovery invocation. |
| Whitespace and protected artifact checks | PASS | git diff --check; approved migration hashes unchanged. |

PASS on a characterization test means the unsafe behavior was reproduced, NOT
that safety acceptance passed. H1's two input cases violate the desired property
on the deployed source. The proposed guard passes those safety assertions locally.
The SQL proposal is not approved or deployed. Earlier exploratory 19/21-test runs
are superseded by the final 23-test run and not added to these totals.

All mutation tests used newly initialized loopback clusters with stripped PG*
connection settings; no external URL/DSN is accepted and clusters are stopped and
deleted. PostgreSQL 17.11 matches the DEV major/minor, but Windows/local execution
does not reproduce DEV Linux performance. Authentication functions, cron tables,
road-node resolution/eligibility and reduced dependency tables are explicit
fixtures. Real PostGIS/pgRouting, real pg_cron runtime, complete production RLS,
photo/storage policies, batch immutability triggers and the full FK/constraint
graph are not integrated. Their deployed code was not modified. The real mutation
RPC bodies, recovery, six lifecycle helpers and two listing triggers are not mocked.

## Required fix and review-only SQL

Proposed function change, before existing uncertainty predicates:

```sql
v_uncertain := exists(select 1 from public.claim_reconciliation_cases rc
    where rc.claim_id=v_c.claim_id and rc.case_status in ('OPEN','MANUAL_REVIEW'))
  or v_l.listing_id is null
  -- existing predicates continue unchanged
```

This conservatively uses the existing reconciliation branch, leaves an existing
case unchanged via ON CONFLICT, sets claim/lease RECONCILIATION_REQUIRED, retains
CLAIMED custody and records the existing accepted-reconciliation audit. It does
not reopen, change routing, invent statuses or rewrite recovery/batch semantics.
Normal case writers take the same claim lock first. It does not protect against
arbitrary administrators bypassing the protocol after checks.

Complete SQL proposal: review-only/claim_recovery_open_case_guard.sql. It includes
atomic boundaries, paused-unused-cron precondition, exact old source/security drift
guards, CREATE OR REPLACE only, preserved owner/ACL/default/search_path, and new
postconditions. No temp relations, transaction-end cleanup or cron mutation.
SHA-256 0B91526DAA19F57BC14445D5249FD7EC33792CC86EA39A100AC148CF233F826C.
Candidate normalized body MD5 805c8b8eb070dc8c3ee50d5699ed033d; it is NOT an approved
deployed fingerprint. Do not edit deployed migrations; after user review, prepare
a separately approved forward-only migration and conduct fresh live source review.
Existing Stage 3B/3D scripts deliberately reject a changed fingerprint and must
not be reused unchanged after a future fix.

## Recommended cron settings after the blocker is resolved

| Setting | Recommendation | Rationale |
|---|---|---|
| Schedule | Keep * * * * * | Up to approximately one-minute scheduling delay plus work/contended waits; queued/load delays can be longer. |
| Execution role | Keep postgres | Current trusted scheduler boundary; tables/sequence privileges and existing eligibility cron connections verified. No client grants. |
| Initial batch | 1 | Smallest rollback/lock footprint and clear first-event monitoring. Then 5/10; consider 100 only after representative timings and backlog evidence. |
| lock_timeout | Keep 5 seconds | Bounded per-lock waits without hiding contention. It is per acquisition, not a whole-run budget. |
| statement_timeout | Keep 50 seconds | Function cancellation below one-minute cadence; rollback verified. This excludes connection/startup/commit overhead. Large hub member sets can exceed it even at low claim counts. |

An executed 100-claim fixture is a correctness bound test, not a production load
benchmark. Claims per call do not bound member donations, routing lookups or audit
work per hub batch. Do not increase timeouts to hide a poison candidate. A batch
of 1 can still starve behind a persistently failing oldest claim: alert and
investigate rather than silently skipping records or changing custody.
[PostgreSQL timeout semantics](https://www.postgresql.org/docs/17/runtime-config-client.html)

## Pre-activation checks and controlled future rollout

All SELECT-only final checks and monitoring queries are in
claim_recovery_automatic_readiness.sql. They include source/ACL metadata, duplicate
schedules, job status/history, all overdue claims, unresolved-case status mismatches,
missing lease/task coordination, case age, recovery audits, eligibility queue and
blocking PIDs. Run the file before any separately approved activation and compare
against a freshly approved source fingerprint; neither old nor candidate hash
alone constitutes approval.

1. First obtain approval for the H1 fix, prepare/deploy its forward-only migration
   manually, and verify complete source/security preservation and lifecycle data.
   Leave job 3 inactive throughout that work. No migration was deployed here.
2. Assign a named operator and alert destination. Snapshot readiness output; verify
   DEV selection, healthy jobs 1/2, no duplicate workers, no unexpected transactions,
   missing coordination or mismatched unresolved cases. Begin with empty backlog.
3. After separate activation approval, use review-only/claim_recovery_canary_activation.sql.
   It changes only job 3, lowers batch 100->1 and activates atomically; it requires
   the candidate guard fingerprint, original paused job, zero execution history
   and empty overdue backlog. It therefore rejects today's deployed source.
   This is a future template contingent on fresh approval, not a recommendation
   to execute it now. Jobs 1/2 are snapshotted and asserted unchanged.
4. Observe several no-op scheduled runs for connection/identity/runtime errors.
   A no-op proves cron connectivity, not business recovery. Later observe a real
   permitted expiration through ordinary approved app workflows; do not create
   test data, force deadlines or run recovery now.
5. Inspect each early LEASE_RECOVERY event: RELEASED requires expected reasons,
   lease/task/listing/donation transitions and donation audit; reconciliation
   requires retained custody and an open case. Verify refresh enqueued then
   COMPLETED, and My Claims moves safely to History or Needs Reconciliation.
6. Stop rollout on any failed run, duplicate/missing audit, inconsistent state,
   expired backlog not clearing, unexpected case, long wait or worker regression.
   During initial DEV operation alert on the first failed run; investigate any
   ACTIVE/ACTIVE claim >5 minutes overdue, no successful heartbeat >3 minutes,
   and any case unassigned >1 hour. These are proposed operational thresholds,
   not new persisted business rules. Inspect all new cases immediately at rollout.
7. Check job 1/2 latest successes and refresh queues independently. Only consider
   larger batches after successful direct and representative whole-hub scenarios
   and observed execution times comfortably below 50 seconds (e.g. p95 <40 seconds).
   No unsupervised expansion or activation is authorized by this report.

The activation/pause files were statically checked against live cron.alter_job's
signature and official API, not executed against DEV or a real pg_cron extension.
Actual scheduling/overlap and disable behavior require controlled runtime checks
after explicit approval. [pg_cron API](https://github.com/citusdata/pg_cron)

## Disable and incident procedure

Review-only emergency pause SQL is in review-only/claim_recovery_pause.sql. It
checks postgres and job identity, calls cron.alter_job(3, active := false), and
verifies inactive state. No jobs 1/2 changes. It has NOT been executed.

Pausing is not proof an in-flight run stopped, nor does it undo committed work.
Inspect run_details and pg_stat_activity afterward. If additional cancellation is
approved, correlate the exact current job-3 run/job_pid to its current backend,
database/user/query/start time to avoid PID reuse; cancel only that verified
backend, never broad postgres sessions or eligibility workers. No cancellation
SQL is automatically executed or included with activation. An aborted function
transaction rolls back; successful past recoveries require business review and
forward reconciliation, not automatic inverse updates. Preserve audit/history
evidence, diagnose the oldest affected claims and obtain explicit approval for
any correction. Do not recreate the job or rerun old migrations as rollback.

## Exact local files created

Under C:/Users/User/Downloads/FYP-GeoLock_Hub/:

1. supabase/tests/claim_recovery_automatic_safety_review.md (this report)
2. supabase/tests/claim_recovery_automatic_readiness.sql (SELECT-only queries)
3. supabase/tests/claim_recovery_automatic_isolated_test.py (new opt-in suite)
4. supabase/tests/fixtures/claim_recovery_automatic_live_rpcs.sql (isolated captured RPCs)
5. supabase/tests/fixtures/claim_recovery_open_case_proposal_function.sql (isolated proposal source)
6. supabase/tests/review-only/claim_recovery_open_case_guard.sql (full unapproved fix proposal)
7. supabase/tests/review-only/claim_recovery_canary_activation.sql (future unapproved activation)
8. supabase/tests/review-only/claim_recovery_pause.sql (unexecuted pause procedure)

No existing migration, application file, routing implementation, grant or cron
definition was modified. Protected local migration hashes still match:

- 20261027: A3A06DF1CF551F6F8A92B03D85167EFA0828C8F1ABDD47E309D4F01D2CBFBF63
- 20261028: 4E02DC1E1F34FF10E343B15AE23E0B236FF2FC8E9DCECB13BA6E32C199EE70DC
- 20261029: 064B1E4CD5B5CD38E1F77B91364AF5ED99221926455D5D64AE7A4B70C1C31E7D

DEV remains on source 50110ff20115c4e5d46380e8e3f8b94c. Job 3 remains inactive
with zero executions. Stop here and wait for explicit approval.
