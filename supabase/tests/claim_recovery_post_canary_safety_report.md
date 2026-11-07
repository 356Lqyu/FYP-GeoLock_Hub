# Stage 3H Post-Canary Safety Report

**Later evidence, 23 October 2026:** Stage 3I Phase 2 now verifies one real
supervised automatic direct recovery with real eligibility completion. See
[Stage 3I closure](review-only/stage3i/closure/RESULTS.md). Its functional PASS
closes the original no-real-recovery evidence gap below. Unattended operation
remains NOT YET APPROVED; job 3 stays inactive. This Stage 3H report is retained
as its historical empty-backlog-canary snapshot, not current Stage 3I status.

Overall canary verdict: PASS for the supervised empty-backlog canary and current
post-canary health. This does not establish successful automatic recovery of an
expired claim, hub performance, or readiness for unattended continuous operation.

Next stage: CONDITIONAL GO for separately approved supervised end-to-end testing;
NO-GO for continuous unattended DEV recovery until the acceptance conditions below
are met. Keep job 3 inactive. No new recovery-function defect was observed.

## Scope and observation times

Only DEV rcgyuwiidqvrgbxswhqj was inspected using its bound read_only=true Supabase
MCP. SELECT statements only; current_user=supabase_read_only_user and
transaction_read_only=on. Shared project was not accessed.

Read-only observations span 2026-10-22 19:58:06 through 20:01:56 UTC
(2026-10-23 03:58:06 through 04:01:56 MYT). The relevant reported canary minutes
are 2026-10-22 19:44 through 19:55 UTC inclusive.

Executed existing Stage 3F postdeploy and Stage 3G monitoring queries plus all
24 SELECT statements in the new fixed-window verification file. No validator,
recovery, state-changing RPC, DDL, DML, cron alteration or migration was executed.
No isolated mutation tests were necessary for this observation-only stage.

## Actual cron execution history

| Result | Count |
|---|---:|
| Total retained job-3 executions | 12 |
| Succeeded | 12 |
| Failed | 0 |
| Other statuses | 0 |
| Unfinished | 0 |
| Outside the reported 19:44 <= start < 19:56 UTC window | 0 |
| At or after 19:56 UTC, through final observation | 0 |

Exactly one succeeded run was present in each expected minute:

| Start minute UTC | runid |
|---|---:|
| 19:44 | 3104 |
| 19:45 | 3107 |
| 19:46 | 3110 |
| 19:47 | 3113 |
| 19:48 | 3116 |
| 19:49 | 3119 |
| 19:50 | 3122 |
| 19:51 | 3125 |
| 19:52 | 3128 |
| 19:53 | 3131 |
| 19:54 | 3134 |
| 19:55 | 3137 |

First start: 19:44:00.074560 UTC. Last start: 19:55:00.343714 UTC.
Last completion: 19:55:00.369905 UTC. Observed execution durations ranged from
5.887 to 26.191 milliseconds. This is a no-op timing observation, not a recovery
or large-hub load benchmark. Every recorded command uses limit 1 and the approved
5-second lock / 50-second statement timeouts, with execution role postgres.

Job 3 is inactive and remains configured as:

```sql
-- Stored command, shown for identification only. DO NOT EXECUTE HERE.
set lock_timeout = '5s'; set statement_timeout = '50s'; select public.recover_expired_claims(1);
```

Name geolock-expired-claim-recovery; schedule * * * * *; username/database postgres;
localhost:5432. No unfinished job-3 run, live recovery invocation, unexpected
open client transaction or relevant claim/listing/donation/batch lock was returned.

Pause timing limitation: cron.job has no pause COMMIT timestamp. The user reports
pausing after the canary; the retained history confirms no execution outside its
12 reported minutes and none in the following observed minutes. An exact
transaction-level statement that a run did/did not start after the pause COMMIT
cannot be independently reconstructed from these catalogs alone. No historical
log completeness beyond the retained cron history is claimed.

Jobs 1 and 2 remain active with unchanged names, schedules, commands and roles.
Each had 60 succeeded runs and zero failed/other runs in the latest one-hour
snapshot; latest completions were 20:01:00.168698 and 20:01:00.166020 UTC.
No unfinished eligibility run was returned.

## Recovery definition and authorization

The complete deployed function matches the approved 20261030 migration, allowing
only CRLF-to-LF normalization and PostgreSQL's omission of the final statement
semicolon. Body fingerprint 5ff6d8719db9681aae6f444b89dfbaee matches.

Verified exactly:

- recover_expired_claims(p_limit integer DEFAULT 100) RETURNS integer.
- Owner postgres; SECURITY DEFINER true.
- search_path=pg_catalog, public, extensions, pg_temp.
- Explicit ACL {postgres=X/postgres,service_role=X/postgres}, no added grant option.
- anon/authenticated EXECUTE false; service_role EXECUTE true. PostgreSQL
  administrative/superuser capabilities are not revoked by this ACL statement.
- Applicable unresolved OPEN/MANUAL_REVIEW cases fence safe reopening by claim
  OR listing; existing uncertainty/reconciliation behavior remains intact.
- Source includes the Stage 3A post-lock listing expiration evaluation and final
  restoration-failure exception.

The 85 other public-function definition/owner/ACL aggregate remains
6991083a881075cdf0e75d0c266396f0, matching the reviewed baseline. No source drift
of those lifecycle, reader, security, eligibility or teammate-owned functions was
found. This is source evidence, not a new test of every routing/security path.

## Lifecycle, custody, audit and eligibility results

Current stored totals: 9 donations, 5 listings, 4 claims, 4 leases and 4 pickup
tasks. All four claim/lease pairs are RELEASED/RELEASED and all four tasks STALE.
There are zero ACTIVE claims or leases, zero expired ACTIVE/ACTIVE pairs, zero
reconciliation cases of any status, zero active route assignments and zero route
stops.

| Donation state/path | Count |
|---|---:|
| AVAILABLE / DIRECT_PICKUP | 4 |
| CANCELLED / DIRECT_PICKUP | 1 |
| CANCELLED / HUB_COLLECTION | 2 |
| SUBMITTED / HUB_COLLECTION | 2 |

The five direct listings are four AVAILABLE and one CANCELLED, matching their
donations. No claimed donation/listing or unexpected reopened-state inconsistency
was returned. Pure SELECT equivalents of the deployed donation-validator checks
returned zero classification/finalization, missing listing, whole-hub set,
available, collected or claimed-coordination violations. No helper was invoked.
There is no current active hub recovery path to exercise; that part of the check
is vacuous on current data and supplemented only by prior isolated evidence.

The donation status CHECK is validated and contains the approved nine lifecycle
states. donations_lifecycle_at_commit is enabled, deferrable, initially deferred.

Exactly three historical LEASE_RECOVERY audits remain. There are no duplicate
pair-scoped recovery audits or missing successful recovery audits for terminal
EXPIRED_SAFE_RELEASE claims. The detailed three-target checks also confirm the
corresponding donation transition audits. No audit event of ANY type was recorded
at or after 19:44 UTC through inspection. In particular there were no canary
LEASE_RECOVERY events, reconciliation events or donation transition events.

Queue health: 8 listing refresh jobs and 1 NGO refresh job, all COMPLETED; no
non-COMPLETED row or last_error_code was returned. No listing or NGO refresh job
was requested at/after 19:44 UTC. Empty recovery therefore had no observed business
audit, case, recovery transition or refresh-enqueue effect.

The cron return_message '1 row' means one SQL result row, not one recovered claim.
This report infers no actual recovery count from that message. Current state,
audits and before/after evidence support an empty-backlog/no-op canary.

## Three controlled recoveries and snapshot comparisons

Every detailed check passed for:

| Claim | Claim/lease/task | Listing/donation | Version / generation |
|---|---|---|---|
| 323ca3b3-7d7f-438e-8ed7-415f61b3a567 | RELEASED / RELEASED / STALE | AVAILABLE / AVAILABLE | 3 / 2 |
| aa3cd6d2-e5b3-4369-a41f-ec9a0eaae716 | RELEASED / RELEASED / STALE | AVAILABLE / AVAILABLE | 3 / 2 |
| 9a2ab42b-52c6-4c3a-99fb-b5c95d41e63f | RELEASED / RELEASED / STALE | AVAILABLE / AVAILABLE | 5 / 3 |

Checks cover exact claim/lease/task/listing/donation identities, terminal reason
EXPIRED_SAFE_RELEASE and closure timestamps, lifecycle/version/generation, absence
of route/hub/case conflicts, exactly one correct recovery and donation transition
audit per target, and expected eligibility refresh. Latest refreshes are completed.

Full joined row/audit/refresh JSON snapshots for these three match the saved Stage
3G pre-canary snapshots exactly, comparing object keys independently of order.
All four claims' full joined snapshots also match the earlier Stage 3F 19:01:06 UTC
snapshot, including the older NGO-cancelled historical claim. These comparisons
preserve all captured columns, not merely the selected status fields.

Historical evidence limitations: those joined snapshots cover three distinct
donations/listings; they are not a pre-canary full-row snapshot of the other six
donations or two listings. Their present integrity is verified, but exact absence
of changes to every historical column in those other records is NOT proven.
Matching endpoint snapshots/audits also do not prove that no privileged transient
write occurred and was later reversed, or prove unrecorded physical custody.
No unexpected database change was detected in the inspected evidence.

## Remaining risks and approval conditions

| Severity | Risk or readiness gap | Required mitigation |
|---|---|---|
| High readiness gap | No real automatic expired-claim recovery occurred | Approved, supervised scheduler-driven end-to-end direct recovery with before/after evidence; hub evidence before permitting hub workloads |
| High operational | Continuous monitoring/alert ownership is not established by this review | Named primary/backup operator, durable run/error/backlog alerts and tested response/pause access; unattended activation remains blocked |
| High liveness | Persistently failing oldest candidate can starve subsequent candidates | Alert/pause on first worker error, identify candidate/blockers, investigate; never silently skip evidence or increase batch size to bypass it |
| Medium | Large hub is one claim but many locked/mutated rows | Preserve limit 1 and timeouts; separately test representative hub workloads and atomic audit/refresh results before expanding scope |
| Medium | Deadlocks, waits, SQL/constraint errors roll back the entire invocation | Preserve atomic rollback; inspect cron failure history, use controlled retry only after diagnosis; no durable failure audit is guaranteed inside a rolled-back transaction |
| Medium | Live concurrency/full RLS/storage/routing coverage is incomplete | Preserve coordination writers/lock protocol; targeted separately approved integration testing; no teammate routing changes |
| Evidence limit | Exact pause timestamp and complete historical row coverage unavailable | Preserve activation/pause timestamps and full scoped snapshots in the next test |

Limit 1 every minute with 5s/50s timeouts remains appropriate for the NEXT
supervised DEV test, not as a proven continuous-operation configuration. It is
one candidate per invocation, not a strict global wall-clock rate guarantee.
No batch redesign or larger timeout is justified by the empty-load canary.

Immediate incident action for a future separately approved run: pause ONLY job 3
using the existing reviewed pause file, inspect all unfinished runs and blockers,
verify jobs 1/2 unaffected, and wait for recovery quiescence. Pausing does not
cancel an in-flight run or reverse committed claims. A failed recovery transaction
rolls back its business writes; a committed recovery has no generic safe undo SQL.
Never restore ACTIVE leases, overwrite audit history or manually force reopening.

Stop a future supervised test for any worker error/timeout/deadlock, unexpected
reconciliation/custody transition, missing/duplicate target audit, partial lifecycle
restore, eligibility failure, oldest-candidate starvation or lost supervision.
Continuous operation requires durable detection and an owner who can actually act.

## Next-stage proposal and files

A controlled end-to-end automatic recovery test IS required before approval of
continuous unattended DEV activation. See the separate review-only test proposal.
It requires explicit authorization for any DEV fixture creation, lease/claim action
or cron change; none is authorized or performed by this report.

The initial Stage 3G activation file requires zero prior executions and the original
paused limit-100 command. DEV now has 12 runs and paused limit 1, so that script
must NOT be reused unchanged. A future guarded activation must be prepared and
reviewed against the new baseline; do not bypass its rejection.

Created ONLY these files under C:/Users/User/Downloads/FYP-GeoLock_Hub/:

1. supabase/tests/claim_recovery_post_canary_safety_report.md (this report).
2. supabase/tests/claim_recovery_post_canary_verification.sql (24 SELECTs, executed
   successfully through read-only MCP; fixed historical window).
3. supabase/tests/review-only/claim_recovery_automatic_e2e_test_proposal.md
   (review-only proposal; no executable state-changing SQL).

No existing file, migration, Flutter code, deployed function, grant, data record,
cron schedule or teammate-owned implementation was modified by this stage.
Existing activation/pause/Stage 3F migration file hashes remain unchanged.
Wait for explicit approval before any further DEV recovery or cron operation.
