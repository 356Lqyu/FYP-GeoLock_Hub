# Stage 3I: supervised automatic recovery end-to-end DEV test

## Closure update 23 October 2026

**Stage 3I Phase 2 functional PASS: supervised automatic direct recovery VERIFIED.**
Final SELECT-only verification at 13:18:01.544040 UTC returned all_checks_pass=true.
Job 3 is inactive; jobs 1/2 are active and healthy. Permanent unattended recovery
is **NOT YET APPROVED**. Retain the fixture and all history; do not rerun activation.

See [closure results](closure/RESULTS.md), [evidence](closure/evidence.json), and the
[next-stage plan](../../../../docs/audits/2026-10-23-stage3i-closure-and-next-stage-plan.md).
Five scheduled test runs occurred; the first recovered the fixture, with no
duplicate effects observed later. Immediate-pause timing and five-minute deadline
compliance are not independently certified without the actual receipts.

## Original preparation record retained for history

PREPARED ONLY. CONDITIONAL GO for a separately approved supervised test using the
normal six-hour lease. NO-GO for execution of an unpopulated activation template,
direct expiry manipulation, unattended continuation or current target-free SQL.
No DEV fixture was created, no recovery was called, no cron was altered and no
migration/function/application/teammate implementation was changed by this task.

DEV ONLY: rcgyuwiidqvrgbxswhqj. Never use the shared project. The SQL cannot derive
the Supabase project reference from current_database(); the human operator must
verify the DEV project in SQL Editor and the DEV Flutter configuration.

## Current source and DEV compatibility evidence

Read-only MCP was verified bound to DEV/read_only=true. At 2026-10-22 20:06 UTC,
job 3 remained inactive with exactly 12 succeeded runs, no unfinished run, max
job-3 runid 3137, schedule every minute, limit 1, 5s lock / 50s statement timeout,
postgres execution role. Jobs 1/2 active. Zero ACTIVE/reconciliation claims and
zero unresolved cases: no test target currently exists.

The deployed recovery body remains 5ff6d8719db9681aae6f444b89dfbaee, owner postgres,
SECURITY DEFINER, approved protected search_path, exact postgres/service_role ACL.
Current claim_listing, seven-argument creation and v2 reader sources/security were
inspected. Existing RPC source has the NGO/donor authorization, protected real road
eligibility, whole-set lifecycle coordination, async eligibility and idempotency
required by this plan. The recovery definition and existing functions are not
replaced by any artifact. 360-minute coordination configuration remains unchanged.

The readonly templates were compiled/executed via SELECT-only DEV inspection with
an EMPTY manifest. They correctly identify no target and verification false. That
is SQL/schema compatibility evidence, not a successful test or authorization.

Final read-only check 2026-10-22 20:20:09 UTC: job 3 still paused/12 prior runs;
zero nonterminal claims, unresolved cases and STAGE3I-E2E fixture donations. The
13-table business snapshot hash (with no target excluded) remains
1a635cad67b4c3f1f1790599b475796e, unchanged from the first package preflight.

## Dedicated scenario and creation method

Use one donor-owned disposable donation named STAGE3I-E2E-<unique UUID>, with a
20kg valid item total, legitimate active category, valid donor-controlled location,
description and 1-3 benign test photos. Use only pre-approved DEV test accounts.
The existing Flutter photo workflow calls create_donation_with_images and its
seven-argument creation dependency; no creation availability arguments are added.
Do not bypass photo rules, authenticated ownership or actual directed-road checks.

Use the selected verified NGO's normal claim action once async listing/NGO
eligibility is ready. Claim must succeed using claim_listing and its idempotency
key. Confirm DIRECT_PICKUP/DIRECT_DONATION, NULL listing expiry, CLAIMED states,
ACTIVE claim/lease, CONFIRMED task, no route, pickup, custody or case evidence.

Leave job 3 paused and the claim untouched for its full 360-minute lease, until
PostgreSQL statement_timestamp() >= the exact stored expires_at. Device time is
not authoritative. Flutter should then show Expired - Recovery Pending and disable
lease-dependent actions. No direct SQL editing of issued_at/expires_at/config or
state is needed, offered or permitted by this proposal.

Creation instructions are in 02_fixture_workflow.md. If a six-hour wait is not
acceptable, stop for a separately justified/approved alternative; this plan does
not grant an exception. Local mutation tests use already-expired fixture timestamps
only in newly initialized disposable PostgreSQL, never in DEV.

## Expected committed transitions

| Object | Before scheduler tick | After safe recovery |
|---|---|---|
| donation_claims | ACTIVE | RELEASED; EXPIRED_SAFE_RELEASE; closed_at set |
| claim_leases | ACTIVE, deadline genuinely past | RELEASED; EXPIRED_SAFE_RELEASE; closed_at set; deadline unchanged |
| pickup_tasks | CONFIRMED | STALE; existing task snapshot fields preserved |
| listings | CLAIMED, NULL expiry | AVAILABLE; listing_version +1; eligibility_generation +1 |
| donations | CLAIMED / DIRECT_PICKUP | AVAILABLE / DIRECT_PICKUP |
| reconciliation cases | None applicable | None created |
| recovery audit | None for test pair | Exactly one SYSTEM/SUCCESS ACTIVE -> RELEASED event with exact claim/lease/listing/donation/task IDs |
| donation audit | Existing creation/claim history retained | Exactly one additional SYSTEM/SUCCESS CLAIMED -> AVAILABLE event for test claim/lease |
| eligibility | Prior generation snapshot retained | New generation enqueued by actual listing triggers; worker 2 completes successfully |
| Flutter My Claims | Expired - Recovery Pending | History / Released, after read refresh |

Recovery function result is decided under its own locks. These are expected
outcomes, not authorization to override the function if custody evidence changes.
Any unexpected reconciliation transition is a safe fence but a STOP/failing happy
path for this particular test. Never force reopening or auto-close its case.

## Artifacts and manifest handling

All paths here are under C:/Users/User/Downloads/FYP-GeoLock_Hub/:

1. supabase/tests/review-only/stage3i/01_preflight.sql -- SELECT-only target/global
   evidence, full target rows/audits/refresh, outside-business snapshot hash and
   proposed manifest. Initially `{}` yields no target and target_is_overdue=false.
2. .../02_fixture_workflow.md -- reviewed application fixture creation instructions;
   deliberately no INSERT/UPDATE, fake auth or direct-expiry fixture SQL.
3. .../03_activate.sql -- guarded transaction; ONLY cron.alter_job(3,active:=true).
   No recovery invocation or fixture creation. Empty/stale/bad manifests abort.
4. .../04_monitor.sql -- SELECT-only snapshots, new cron runs after 3137, custody/
   audit/refresh evidence, other-business hash and worker/blocker monitoring.
5. .../05_verify.sql -- SELECT-only pair-scoped audit/lifecycle/version/generation,
   completed refresh, unrelated snapshot, scheduler and paused-state assertions.
6. .../06_pause.sql -- standalone reviewed emergency pause, independent of target
   manifest freshness or recovery outcome. ONLY job 3 is disabled.
7. .../07_retention.md -- retain evidence; separately approved donor cancellation
   after verification instead of deleting history or raw Storage/database rows.
8. .../parameters.example.json -- deliberately NULL/false placeholder manifest.
9. .../SHA256SUMS.txt -- exact five canonical SQL template SHA-256 checksums.

Additional new local source/test files:

- supabase/tests/claim_recovery_e2e_package.py -- filesystem-only generator/renderer.
- supabase/tests/claim_recovery_e2e_contract_test.py -- six offline safety contracts.
- supabase/tests/claim_recovery_e2e_isolated_test.py -- 11 isolated prepared-script tests.
- This PLAN.md. No existing files were modified by Stage 3I.

After approved app fixture creation, use actual returned IDs to populate a LOCAL
manifest copy. Run rendered preflight before expiry for inspection, and again
after genuine expiry for activation evidence. Merge proposed_manifest into that
copy: expected version/generation, exact expires_at, other_business_md5, timezone
and baseline_at. Add the exact test title, account IDs, explicit approval reference,
present operator, maintenance_confirmed=true and stop_at <=5m in the future.

Rendering uses one JSON object consistently across all parameterized artifacts:

```powershell
# LOCAL FILE PREPARATION ONLY. No database connection or SQL execution.
python -B supabase/tests/claim_recovery_e2e_package.py --manifest <local-manifest.json> --output-dir <new-local-review-folder>
```

The renderer quotes JSON as a SQL literal, writes files into a NEW directory and
produces new SHA256SUMS.txt. It never connects to any DB. Canonical template hashes
do NOT apply to rendered copies: review and freeze new hashes with actual IDs.
Do not hand-edit five divergent parameter blocks or treat manifest labels as a
substitute for human authorization. Keep manifests/evidence private; they contain
account IDs and full administrative snapshots, not public artifacts.

## Activation guards and target-isolation limits

Require clean postgres session and exact approved source/signature/default/return,
owner/SECURITY DEFINER/search_path/ACL; exact paused limit-1 job configuration;
exact historical job-3 runid array [3104,3107,3110,3113,3116,3119,3122,3125,3128,
3131,3134,3137], all succeeded/finished; no duplicate recovery schedule; healthy
recent eligibility workers; no unfinished runs or other open client transaction.

Require the exact five target IDs and two account IDs, dedicated title, snapshots,
listing version/generation, deadline and approximately 21600-second lease duration
(<1 second tolerance for independently evaluated issued_at/default timestamps).
Configuration must remain 360. No applicable custody evidence, unresolved case,
preexisting recovery audit, hub membership/inventory or malformed target is allowed.
Exactly one nonterminal claim AND lease across DEV must exist, namely this target.
Fresh baseline <=3m, consistent SQL session timezone and named/present operator with
<=5m human stop deadline are mandatory. Jobs 1/2 are asserted unchanged after ALTER.

These guards DO NOT pin a future asynchronous invocation to an ID. Recovery uses
oldest-first SKIP LOCKED, and a new concurrent claim/lease extension/route or manual
worker can change the candidate set after activation COMMIT. Do not hold target
row locks across activation: the cron worker would skip/wait on them. The short
application-write maintenance window, sole-candidate checks and prohibition of
competing recovery are required conditions, not a SQL-enforced global mutex.
If exclusivity cannot be maintained, NO-GO; a target-specific worker would require
a separate design/approval and is not introduced here. Do not reuse Stage 3G's
zero-history activation script or weaken a rejection after new executions.

Snapshot scope: full rows of non-target donations/listings/claims/leases/tasks,
all hub batches/members/inventory, route assignments/stops, cases, non-target
audits and non-target listing refresh jobs (13 tables total). Target audits are
verified separately. A benign concurrent change also causes mismatch: investigate
rather than recapturing after an unexplained change to hide it. This is not a
full-database hash; auth sessions, photo/storage records, donor/NGO profiles,
donation items, eligibility caches and NGO queue updates are outside this hash.
Use application authorization/photo checks and existing source/security reviews
for those boundaries; do not claim the hash proves their complete preservation.

## Supervised run procedure, only after separate approval

1. Approve creation/accounts/location/photos separately, complete normal creation
   and claim, wait six hours with job 3 paused. No experiment is run by this task.
2. Assign primary/backup operators with verified postgres pause access. Arrange
   exclusive claim/recovery activity and keep eligibility workers running.
3. After expiry, collect fresh preflight/Stage 3H health outputs and full scoped
   snapshots externally. Render a final manifest/package, review hashes and true
   overdue evidence. Verify no new runs beyond the historical 12 and one candidate.
4. Execute the complete 03_activate.sql once in DEV as postgres. Record actual
   COMMIT timestamp. Any error requires clean-session readback; ROLLBACK an aborted
   SQL Editor transaction if needed, never blindly re-execute a partial selection.
5. Observe read-only monitoring every 10-15 seconds around the first minute tick.
   Do not call recovery manually. As soon as success, error or unexpected evidence
   is observed, execute the complete 06_pause.sql. Hard stop by manifest stop_at
   (<=5m). stop_at is NOT an installed automatic deactivation schedule.
6. Additional no-op ticks may occur before manual pause. Inspect every new run;
   do not promise exactly one scheduler invocation. '1 row' is result-row count,
   not the recovered-claim count. Do not infer success from cron alone.
7. Verify job 3 inactive/quiescent, no failed/unfinished new runs, workers 1/2 still
   active/healthy. Allow the actual eligibility worker to complete the generation;
   do not manually mark completion. Require 05_verify all_checks_pass=true.
8. Independently compare the task's full before/after snapshots: only approved
   task_status STALE and any legitimate DB trigger-maintained fields may differ;
   route/pickup snapshots must remain unchanged. Preserve item/photo records and
   check ownership/photo visibility through normal app sessions without sharing URLs.
9. Refresh NGO My Claims (v2 server time), verify History -> Released and disabled
   pickup action. Observe donor/listing state as approved. Save screenshots without
   private photo URLs. Then follow retention instructions under separate approval.

## Stop conditions, rollback and operational risks

Pause immediately on any cron error/timeout/deadlock, no run for >2 scheduled
minutes, wrong candidate, lost supervision, changed source/ACL/config, unexplained
snapshot change, unexpected case/route/custody evidence, repeated candidate or
rollback, missing/duplicate audit, partial state restoration, stale/failed refresh
or jobs 1/2 deterioration. Do not wait for repeated failures to pause.

Pause does not cancel an in-flight transaction or undo a committed recovery. Inspect
run history, backend PID/blockers and wait for termination. Separate authorization
is required for targeted backend cancellation; never cancel arbitrary postgres or
eligibility sessions. SQL/constraint failures roll back the invocation atomically,
including audits/enqueues. Retain cron failure messages; a rolled-back failure
audit is not durable. No generic undo SQL, lease resurrection or raw cleanup exists.

High residual risks: unsupported competing writers break target isolation; a
persistently failing oldest claim can starve later candidates; human absence can
leave cron enabled. Mitigate through the bounded attended window, immediate pause,
sole candidate and fresh evidence. Continuous unattended activation remains NO-GO.
Medium: actual Supabase/Storage/RLS and real scheduler/eligibility integration need
this approved DEV test; large hubs require a separate representative-load test.
Limit 1 every minute with 5s/50s timeouts is retained; a claim may represent many
hub donations, so do not infer hub performance from a direct test.

## Isolated validation and limitations

Executed 87/87 offline contracts, 46/46 existing patched recovery regressions and
11/11 new prepared-script tests in NEW disposable loopback PostgreSQL clusters.
Final isolated run durations: 132.755 seconds for the existing 46 and 42.381 seconds
for the new 11. SQL SHA manifest and artifact whitespace checks also pass.
Existing suite covers actual captured claim/start/complete/cancel/route RPC races,
whole-hub/direct restoration, case fences, repeated invocation, lease extension,
SKIP LOCKED, timeout/failure rollback, audit consistency and three prior recoveries.
The new suite executes on-disk activation COMMIT, actual patched recovery, repeat
invocation, pause COMMIT and verification; checks post-activation route/case fences,
audit failure rollback/emergency pause, unrelated drift, second candidate, empty/
stale manifests, history drift and activation postcondition rollback. It refuses
success before async completion or pause.

The first new test run failed in JSON row decoding in the test harness, not the
recovery algorithm; that harness was corrected. A preflight row-alias collision
was identified by live SELECT compilation, corrected and regression-asserted.
Only final passing results are acceptance evidence.

New fixture uses cron.alter_job table double and explicitly SIMULATED scheduler
ticks, with the real patched recovery and captured lifecycle/eligibility trigger
source. Async queue completion is explicitly stubbed. Real pg_cron, complete
production constraints/RLS/Storage, actual PostGIS/pgRouting and real eligibility
workers are not installed/exercised in the local fixture. Normal Flutter photo
creation is reviewed in source, not automated locally. No new UI change/test is
claimed. Prior actual no-op pg_cron runs prove scheduler plumbing only. A simulated
run does not meet the real DEV end-to-end acceptance criterion.

No DEV state-changing SQL, cron change, test-data creation, recovery call, deployment
or modification of previously deployed migrations was performed. Await explicit
approval before fixture creation; await fresh target-specific review and approval
before activation. This preparation does not approve continuous recovery.
