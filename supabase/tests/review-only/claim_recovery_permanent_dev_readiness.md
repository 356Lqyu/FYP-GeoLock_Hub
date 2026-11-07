# Consolidated permanent DEV recovery readiness

Assessment: 24 October 2026. **NO-GO for permanent activation today.**
The remaining gate is operational detection and response, not another recovery
algorithm, Stage 3I fixture, ten-account setup or 50-client experiment.
No activation, recovery call, DEV change or deployed SQL edit occurred.

Scope: low-volume controlled DEV rcgyuwiidqvrgbxswhqj only. This is not production
acceptance. Job 3 remains intended inactive until separate approval. Supabase MCP
tools were unavailable during this assessment; current health is the user's
reported recheck, not a newly independently queried snapshot.

## Reused evidence and decisions

| Safeguard | Existing evidence | Assessment |
|---|---|---|
| Real automatic direct recovery | [Stage 3I closure](stage3i/closure/RESULTS.md), exact fixture/audits/refresh and 17 retained successful scheduler runs | PASS, scoped supervised direct case. Twelve runs were prior empty-backlog canary; five were real-test ticks, recovery on the first and no duplicate effects later. Seventeen successful runs do not mean seventeen recovered claims |
| Atomicity, idempotency and safe custody fences | [Stage 3F results](../claim_recovery_reconciliation_guard_review.md), final 45-test suite plus separate read-only post-query test; current body 5ff6d8719db9681aae6f444b89dfbaee | Reuse. Direct/hub, unresolved cases, actual pickup/cancel races, repeat workers, audit failures and timeout rollback already tested in isolated PostgreSQL. No function redesign or repeat Stage 3I needed |
| Retry | Existing cron cadence + approved recovery locks/transactions | Sufficient for controlled DEV with operational stop policy. Each tick retries available candidates; a SQL error rolls back the invocation. Successful empty runs need no recovery audit. No catch-and-continue, new request UUID, automatic expiry edit or in-function failure logger is needed |
| Failure isolation | Proposed continued limit 1, lock_timeout 5s, statement_timeout 50s | Keep these settings. One bad claim cannot roll back other candidates in the same limit-1 invocation. It can still starve later candidates on subsequent ticks. Do not increase limit/timeouts to bypass failure |
| Monitoring queries | [Existing detailed SELECT monitor](../claim_recovery_canary_monitoring.sql) plus [compact status SELECT](claim_recovery_dev_operational_status.sql) | Data sources exist. A SQL file is not a running independent monitor or a delivered alert |
| Starvation | Candidate ordering, SKIP LOCKED, existing timeout tests | Known manageable DEV risk. SKIP LOCKED skips claim locks only. Track oldest candidate identity across completed ticks, not only global processed counts or backlog size |
| Emergency pause | [Existing supported pause SQL](stage3i/phase2_permission_compatible_execution_approved_20261023/06_pause.sql), successful final inactive state | Supported procedure is prepared. Exact Stage 3I pause receipt/response time was not retained, so operational response timing is not proven |
| Stage 3J and broader load tests | Independent authority acceptance work remains | Not additional prerequisites for this limited DEV operational decision. Do not create ten accounts or repeat the completed recovery experiment to close an alert-delivery gap |

## Only essential blockers

1. **Independent monitoring and alert delivery are not demonstrated.** Configure
   an always-on trusted external poller to run the existing SELECT monitor or the
   compact status query every minute. Keep recovery credentials out of Flutter.
   The monitor needs only existing authorized read access; this plan needs no new
   database grants, stored functions, migrations, cron jobs or business writes.
   A separate dead-man check must detect loss of the poller/DB connection; a
   monitor cannot reliably report its own shutdown. Persist run/event cursors and
   incidents outside the recovery transaction so rollback cannot erase evidence.
2. **Ongoing response ownership and one operational drill are not confirmed.**
   Name a primary operator (the existing DEV Test Operator is the proposed owner),
   reachable fallback or an explicit pause-before-unavailability policy. Agree a
   five-minute acknowledgement/pause response. The earlier five-minute experiment
   supervision agreement does not establish ongoing coverage. Deliver a synthetic
   failure alert to the actual operator and exercise the missing-heartbeat alarm.
   Use exported/synthetic monitor inputs; do not fail a real recovery, create a
   claim, or alter DEV to perform this drill.
3. **Fresh live sign-off remains required immediately before activation.**
   Recheck approved source/security, exact job configuration, scheduler/worker
   health and candidate/case inventory with SELECTs. The user's reported current
   health is favorable. This is a final execution-time check, not another timed
   three-minute package or another business test cycle.

Items 1/2 are one small operational integration and drill, not three new stages.
If equivalent monitoring already exists outside the repository, supply its last
successful poll, delivered alert/dead-man test, operator and incident retention
evidence instead of implementing duplicate monitoring.

## Minimal monitoring contract

Before activation save server UTC time, latest job-3 run ID (accepted reported
baseline 17 executions), recovery-event watermark and current oldest candidate.
Afterward persist cursors between polls. Do not use the old zero-execution guard.
Run monitoring independently of job 3. Poll/DB errors are critical observations,
not empty successful results. Delivery/retry failures must be visible externally.

| Observation | Minimum controlled-DEV action |
|---|---|
| New failed job-3 run, SQLSTATE/timeout/deadlock, unexpected source/ACL/command/role drift, duplicate recovery schedule or integrity alarm | Notify immediately, preserve run ID/error and request manual pause. Pause on the first worker error; do not wait for repeated failures |
| Expected-active job has no start for >3 minutes, or an unfinished job-3 run is >75 seconds old | Notify and pause/investigate. These bounds include the 50s statement timeout plus scheduling/cleanup slack; do not cancel broad postgres sessions |
| Same oldest overdue ACTIVE/ACTIVE claim remains across three completed scheduler ticks | Notify and pause for starvation/lock investigation. A growing queue whose oldest identity keeps progressing is capacity pressure, not proof of a stuck claim |
| Monitor heartbeat absent for >3 minutes or poll/notification delivery fails | Independent watchdog notifies fallback; pause recovery until observation is restored. Never regard absent evidence as healthy |
| Safe-release claim/lease/task mismatch, missing/duplicate LEASE_RECOVERY audit, missing donation release audit, or unexplained CLAIMED listing without nonterminal authority | Critical: pause immediately and inspect target-scoped committed records and subsequent audits |
| New RECONCILIATION_REQUIRED outcome | Notify for custody review. This is an intended fail-closed outcome, not automatically a worker error. Pause if the transition/evidence is unexpected, a required case/audit is absent, or reopening occurred despite uncertainty. Never auto-close cases |
| Jobs 1/2 fail; no completed success for >12 minutes; current recovery-triggered eligibility generation remains incomplete >15 minutes | Notify and inspect. Workers have 10-minute timeouts, so a running legitimate worker is not automatically a missed one-minute tick. Pause for persistent failure; do not bypass readiness to restore discovery |

Deduplicate notifications by run/event/candidate ID; retain first occurrence,
acknowledgement, pause result and resolution externally. Acknowledge only after
inspection; do not advance a watermark over an uninvestigated failure. Check
source fingerprint using md5(replace(prosrc, CRLF, LF)), not function-DDL MD5.
The cron return_message "1 row" is not a processed-claim count. Use committed
claim/lease transitions and target-scoped audits; legitimate later reclaiming can
change listing state, so global equality to old release snapshots is invalid.

## Shortest activation path after the operational gate

1. Connect the existing read queries to one independent monitor and alert route;
   verify synthetic failure delivery and monitor-death notification, assign owner.
   No new recovery/business tests are required for this step.
2. Obtain a fresh SELECT result and separate explicit activation approval. Retain
   the approved recovery body/security and one-minute, batch-1, 5s/50s command.
   Have the existing pause file open and record actual activation/pause receipts.
   Do not execute any spent one-use Stage 3I activation script. The existing
   command's historical comment marker need not be edited for correctness; use
   the new activation receipt/run watermark to distinguish ongoing runs. The
   minimum subsequent approved change is enabling job 3, not rewriting its SQL.
3. Human enables only job 3 using the supported cron API under that approval.
   Observe the first few scheduled results through normal monitoring, then leave
   it enabled only while alerting/response coverage remains operational. No test
   donation, manual recovery call or new lease-expiry experiment is needed.

No activation command is executed or execution-approved by this document.
These conditions support controlled DEV only; they do not establish production
capacity, all native hub branches or hostile-traffic acceptance.

Preparation validation: reviewed the existing source/results and supported pause
SQL; verified the approved Stage 3F migration SHA-256 remains unchanged. No
business tests were rerun. The new compact SELECT received static review only;
it has not been compiled/executed against DEV or an isolated PostgreSQL database.
Use the existing previously exercised detailed monitoring query if that new
summary has not yet been validated by a read-only execution. Whitespace, links
and artifact checksums are checked locally. No running monitor or alert delivery
is claimed by preparing these files.

## Emergency pause and restart

Use the existing 06_pause.sql as postgres in DEV; it validates the job identity
and calls cron.alter_job(3,active := false) with 5s lock/10s statement safeguards.
It uses no unsupported cron.job table lock. Do not add a wait on the cooperative
activation advisory lock. Preserve the successful COMMIT timestamp.

Then SELECT cron.job and job_run_details: confirm inactive and inspect unfinished
job-3 executions. Pause prevents new scheduling; it does not undo committed
releases, guarantee no queued/in-flight work, or cancel a running transaction.
Inspect any in-flight run until it ends. Cancel only a separately verified job-3
backend under explicit authorization; never cancel jobs 1/2 or broad sessions.
Do not revert released records to ACTIVE. Review the failed candidate/audits and
restore monitoring before separately authorizing restart.

## Remaining risks accepted only within controlled DEV

Oldest-candidate starvation, repeated automatic rollback until an operator pauses,
normal-write deadlocks, limit-1 backlog growth, and native hub integration limits
remain. Existing timeouts, fail-closed logic and monitoring response contain these
risks; this review does not redesign them. A read-only monitor cannot enforce a
pause if every operator is unavailable. Without reliable response coverage or a
separately approved automatic stop mechanism, permanent activation stays NO-GO.
