# DEV expired-claim recovery activation review

28 October 2026, read-only DEV observations at 13:40–13:46 MYT.
Project rcgyuwiidqvrgbxswhqj verified through project URL; database postgres,
session supabase_read_only_user, READ ONLY transactions ended with ROLLBACK.
No recovery invocation, scheduler activation, migration, business write or service
restart occurred. All SQL files ending PROPOSAL require separate approval.

## Current status

Recovery is available but automatic execution is PAUSED. pg_cron 1.6.4 is installed;
cron.launch_active_jobs and cron.log_run are on. Job 3 is the only direct recovery
job: geolock-expired-claim-recovery, postgres/postgres, every minute, inactive.
Its exact command is:

```sql
set lock_timeout = '5s'; set statement_timeout = '50s'; select public.recover_expired_claims(1); -- STAGE3I_ONE_USE_8b4a48ed-97e4-41a9-aa1f-b588ae850b4f
```

Jobs 1/2 (NGO/listing eligibility refresh) are active and are not recovery jobs.
Job 3 has 22 retained successful runs, zero failed/unfinished; latest end
2026-10-23T18:14:00.098413Z. A succeeded run/"1 row" does not prove a release.
No active recovery query was visible at inspection. External schedulers cannot
be exhaustively ruled out by database catalogs; operator must confirm none.

No recovery-enabled flag exists in the inspected coordination_config or recovery
body. The gate is the inactive cron job plus restricted execution and operational
approval. SECURITY DEFINER owner postgres, pinned search_path, normalized prosrc
MD5 89e01f42d5ec23bfcbcdc47c1f4fd4e5. Explicit ACL only postgres/service_role;
anon/authenticated/planner/validator effective EXECUTE denied. Function additionally
requires session_user=postgres OR auth.role()=service_role. Never grant Flutter
recovery execution or ship a service-role key to the phone.

The current fingerprint matches the A003 authority prerequisite. Older runbooks
expect 5ff6d871... and pre-003 state, and some require zero historical cron runs:
those execution guards are obsolete. Do not rerun them or spent Stage3I scripts.
The old migration creates batch 100; the actual reviewed job is batch 1. No new
migration, cron job, extension or replacement recovery function is needed.

## Current population and safety

Six expired ACTIVE claim/ACTIVE lease pairs are present. Read-only preflight
classified all six as conservative release candidates: CONFIRMED tasks, CLAIMED
listings and DIRECT_PICKUP donations, no listing deadline, no competing owner,
open case, assignment, route stop or unreleased private routing item. They are:

- dd1be70f-0e42-4b75-9124-cac3702d76f6
- b4bea793-9755-470a-95bb-6b02bc0c4443
- ca8eb131-6ca0-4256-9a8c-c8f781fcbf05 (old Test 42)
- 988b92f7-10d5-4471-ae72-cf1a37d53e0f
- 26265510-e487-4587-9557-f1a8bee6cc19 (test c)
- 84879ced-16b5-441e-9e3b-308283edf7be (Test 10)

The last two claims expired at 08:34 MYT today; they are no longer fresh pilot
claims. No lease was extended. A recovery call is not a targeted-ID operation.
Limit 1 chooses the oldest unlocked expired claim; locked claims can be skipped.
Approval must cover the possible batch and reconciliation outcomes, not promise
to release a named claim. All six can be processed over future scheduler ticks.

Recovery selects ACTIVE/ACTIVE expired pairs and locks claim -> lease -> listing
-> task -> source custody. It rechecks expiry after locking. Route stops of ANY
status, active assignments, a non-CONFIRMED task, pickup/collected custody,
expired listing or unresolved OPEN/MANUAL_REVIEW case fence automatic reopening.
The donation/batch helper also validates paths, immutable member counts and
hub-matching inventory under locks. Uncertainty moves claim/lease to
RECONCILIATION_REQUIRED, retains custody/listing and creates an OPEN case if
absent. A missing listing cannot receive a case and needs operator investigation.
Successful safe release sets claim/lease RELEASED, task STALE, listing AVAILABLE
with version increment and direct donation AVAILABLE (hub donations BATCHED).
Audit failure or other exception rolls back the entire call.

Important qualification: recovery does NOT inspect snapshots, candidates or
attestations. The first three claims above occur in all four historical snapshots.
Snapshots are observations, not reservations. Recovery preserves their contents;
the authorizer compares snapshot task digests/current status and leases under
locks, rejecting stale plans. The enabled routing_task_authority trigger prevents
releasing a reserved private item through a STALE task transition without the
required reconciliation state; inconsistent orphaned state can therefore abort
the call rather than release. The function does not close routes or clear holds.

A genuinely uncertain client authorization/snapshot outcome must be reconciled
before the operator approves execution. Snapshot presence alone cannot establish
uncertainty or authorize custody release. If the requirement is an unconditional
"never release any snapshot-referenced task", this implementation does not meet
it: that stricter rule needs a separately approved design change. No such change
was made. Database observations cannot prove physical handover did not occur.

Preserved baseline: 4 snapshots, 1 candidate, 1 validation, 0 routes, 0 assignments,
0 OPEN/MANUAL_REVIEW cases. No new runtime/isolated lifecycle tests were run;
this assessment reuses the existing Stage3F/Stage3I tests and current source.
Old pre-A003 test results are not claimed as full current-routing integration PASS.

## Exact operator procedure (not executed)

1. Select DEV rcgyuwiidqvrgbxswhqj in Supabase Dashboard. Open SQL Editor as
   postgres; verify current_database/session_user/current_user. Database name alone
   cannot prove project identity. Confirm recovery point and restoration limits.
2. Run recovery_activation_20261028.preflight.sql. Save queue rows, function
   fingerprint, audit event IDs, snapshot/candidate/validation counts and latest
   cron run ID. Resolve any truly uncertain routing request through existing
   owner-scoped read-only receipt reconciliation. Check no competing recovery
   runner. For the first manual call, use a supervised quiet writer window.
3. Choose ONE separately approved action:
   - Manual once: run the complete manual.PROPOSAL.sql transaction. It calls
     recover_expired_claims(1), with 5s lock / 50s statement limits, and leaves job
     3 paused. It permits either safe release or reconciliation; the integer is
     processed claims, not released claims. Do not repeat automatically.
   - Scheduled: after monitoring/operator approval, run the complete
     enable.PROPOSAL.sql transaction. It guards current function/job identity and
     enables ONLY existing job 3; cadence and batch remain unchanged. The old
     comment marker is historical text, not an automatic one-use stop: enabling
     this job runs continuously until paused. Do not create another cron job.
4. Run recovery_activation_20261028.postflight.sql immediately. This file was
   executed read-only before activation to validate its queries, NOT as evidence
   that recovery succeeded. Save after-state for exactly approved targets and new
   audits after the preflight watermark. Check each release's claim/lease reasons,
   task STALE, listing version +1 and donation lifecycle audit. For reconciliation,
   require retained custody, expected case and recovery audit. Check unrelated
   records and immutable evidence unchanged. Later legitimate reclaims can change
   listing state, so compare transition/audit chronology, not stale global equality.

## Schedule, monitoring and stop policy

Recommend existing '* * * * *', batch 1 for low-volume DEV (nominal one claim/minute).
Retain 5s lock and 50s statement limits. Do not increase these to bypass an error.
SQL Editor or Cron dashboard activation is a write requiring explicit approval.
Read-only monitoring can reuse supabase/tests/review-only/
claim_recovery_dev_operational_status.sql for data, BUT its old expected source
fingerprint is not the current A003 fingerprint. Current approval pins 89e01f42...
Use cron.job_run_details and target-scoped LEASE_RECOVERY audits together; cron
history is not alert delivery. Keep eligibility jobs 1/2 running normally.

For a supervised first run: watch each tick, retain run/event watermarks, stop on
first SQL error, unexpected transition or missing audit/case. For unattended use:
name an operator and pause-before-unavailability policy (or fallback), independent
one-minute read-only monitoring, failure/dead-man alert delivery and an offline
alert drill. Existing permanent-readiness review did not establish those controls;
this inspection found no new evidence that they now exist. Treat unattended
activation as HOLD until supplied, not as a missing SQL function.

Pause on first failed run or integrity alarm; investigate a run unfinished >75s,
no scheduled start >3min, same oldest overdue claim across 3 completed ticks or
monitor heartbeat missing >3min. Reconciliation is an intended fail-closed outcome,
but unexpected custody/evidence requires pause and investigation. Batch 1 avoids
rolling back multiple claims together; a repeatedly failing oldest claim can
still starve later work. Never set p_limit=0 to disable: it clamps to at least 1.

## Pause, disable and recovery limitations

After separately approved activation, supported pause/disable is:

```sql
SELECT cron.alter_job(3, active := false);
```

Use the guarded existing supabase/tests/review-only/claim_recovery_pause.sql for
the full operator transaction. Verify active=false and inspect unfinished runs;
pausing does not cancel an already running transaction. Do not cancel broad
postgres sessions. If permanent removal is desired, cron.unschedule(3) deletes
the job configuration (separate approval); prefer leaving it paused to preserve
configuration. Neither action reverses committed recoveries.

Before COMMIT, errors roll back; after commit there is no safe generic status
undo. Do not reactivate old claims, decrement versions, delete audits or blindly
restore over newer data. Inspect committed events if response was lost, then use
reviewed state-aware correction. Whole-database restore can discard later work;
backup restorability/exact row equivalence/external Supabase dependencies remain
unverified as previously accepted for DEV, not proven by this review.

## Reconciliation is a different protected operation

get_my_reconciliation_cases() is a participant-scoped reader for NGO, donor or
hub admin. submit_claim_reconciliation(claim,boolean,stable_request_uuid) writes
truthful handover evidence under the authenticated participant JWT. First report
normally returns AWAITING_COUNTERPART. Two matching no-handover reports release
only if current custody, listing and routing checks permit. Two matching handover
reports complete only when task/custody and protected managed/legacy-route hooks
permit. Conflicting reports/mixed batch/invalid custody remain MANUAL_REVIEW.
Do not manufacture confirmations to clear the backlog. Stable IDs preserve replay;
never submit a different statement under the same ID. A recovery tick does not
resolve RECONCILIATION_REQUIRED claims (they are no longer ACTIVE candidates).

## Recommendation and sources

READY FOR REVIEW of one supervised manual batch-1 call after fresh queue/outcome
approval and uncertain-request review. Automatic unattended activation HOLD for
monitoring/response evidence and explicit ongoing approval. No database changes
have been authorized by this report.

Reviewed SQL: migrations 20261019,20261026,20261027,20261028,20261029,20261030;
A003 authority migration and deployed automatic-departure authorizer; current
recovery/helper/task-guard/reconciliation definitions. Coordination requirements
were checked against the existing Stage3J requirements-to-contract matrix and
authority SQL; original report/supervisor documents were not newly available in
this task. Prior runbooks describe historical state and are not current activation
instructions. Current function/queue evidence is in the adjacent evidence.json.

Official Cron activation/history/pause APIs:
https://supabase.com/docs/guides/cron/quickstart
