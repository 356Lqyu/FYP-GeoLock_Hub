# Stage 3G supervised DEV canary readiness

CONDITIONAL GO for a separately approved, attended, ten-minute initial canary.
No activation was performed. This is not approval for unattended recovery or a
larger batch. A human operator must accept monitoring and pause responsibility
before activation; that operational commitment has not yet been supplied.

DEV project: rcgyuwiidqvrgbxswhqj only. Never use the shared project.

## Live read-only evidence

SELECT-only Supabase MCP, bound to DEV with read_only=true. Final readiness
snapshot: 2026-10-22 19:35 UTC / 2026-10-23 03:35 MYT.

- Current role supabase_read_only_user; transaction_read_only=on.
- Entire recovery definition matches the approved 20261030 migration after
  CRLF-to-LF normalization and omission of the final statement semicolon.
- Approved body fingerprint: 5ff6d8719db9681aae6f444b89dfbaee, computed with
  md5(replace(prosrc,E'\r\n',E'\n')), not whitespace-collapsed pg_get_functiondef.
- Claim OR listing OPEN/MANUAL_REVIEW guard present. Signature p_limit integer
  DEFAULT 100, integer return, postgres ownership, SECURITY DEFINER, protected
  pg_catalog/public/extensions/pg_temp search_path and exact ACL preserved.
- ACL {postgres=X/postgres,service_role=X/postgres}; anon/authenticated cannot
  execute. postgres can execute cron.alter_job and has cron schema USAGE.
- pg_cron 1.6.4; alter_job(bigint,text,text,text,text,boolean) available. postgres
  has no direct UPDATE on cron.job; scripts use the authorized cron.alter_job API.
- Exactly one recovery schedule. Job 3 inactive, zero retained execution records;
  schedule * * * * *, postgres, database postgres, localhost:5432, command with
  lock_timeout 5s, statement_timeout 50s and current batch limit 100.
- Jobs 1 and 2 active; each had 60 successful runs and no failures in the latest
  one-hour snapshot. No unfinished runs were returned.
- Zero overdue ACTIVE/ACTIVE pairs, zero unresolved cases, no coordination
  inconsistency rows, unexpected active transactions or relevant locks returned.
- Exactly three historical LEASE_RECOVERY events; all three completed recoveries
  pass detailed identity/state/version/generation/custody/audit/refresh checks.
  Latest refresh jobs COMPLETED. No duplicate recovery events were returned.
- All 85 other public definitions/owners/ACLs retain reviewed aggregate fingerprint
  6991083a881075cdf0e75d0c266396f0.

These are point-in-time observations, not a lock on future application activity.

## Review-only artifacts

All paths relative to C:/Users/User/Downloads/FYP-GeoLock_Hub/:

- Activation: supabase/tests/review-only/claim_recovery_canary_activation.sql
  SHA-256 D6DCD641D722E6B98B02F5C7C203FDB0023FE3F2C67FFB7C91AF9542194E483F
- Pause: supabase/tests/review-only/claim_recovery_pause.sql
  SHA-256 B590A91397D20310628E606C4BF087BF70BC8815A7866A7F24D28E0017CA9C0A
- Preflight: supabase/tests/claim_recovery_automatic_readiness.sql
- Before/during/after monitoring: supabase/tests/claim_recovery_canary_monitoring.sql
- Historical full verification: supabase/tests/claim_recovery_reconciliation_guard_postdeploy.sql

The old activation template expected superseded claim-only body 805c8b8... .
It now requires approved claim-or-listing body 5ff6d871..., retains exact security
and paused/unused original-job checks, and changes ONLY job 3's command to limit 1
and active=true through cron.alter_job. Schedule stays once per minute. Jobs 1/2
are snapshotted and asserted unchanged. BEGIN/COMMIT makes activation atomic.
No function is replaced and recovery is not directly invoked by activation SQL.

Additional conservative guards require empty overdue backlog, no unresolved cases,
no missing/inconsistent active coordination evidence, recent successful jobs 1/2,
no unfinished runs and no other open client transaction. Transient legitimate
activity may cause rejection; inspect and repeat the read-only preflight rather
than weakening a guard. The script cannot authenticate the project reference from
current_database(); the operator must verify DEV in SQL Editor explicitly.

This is an initial activation script, not a generic restart script. After any run
or pause it rejects the changed baseline. A subsequent activation needs review.

## Locking, rollback and starvation

Candidate selection is overdue ACTIVE/ACTIVE, oldest deadline then claim ID,
FOR UPDATE OF claim SKIP LOCKED, limit 1. Claim -> lease -> listing -> task ->
donation/batch locks and existing helpers remain unchanged. Claim SKIP LOCKED does
not avoid lease/listing/donation/batch lock waits. lock_timeout=5s bounds each wait;
statement_timeout=50s bounds the recovery SELECT. A large hub is still one claim
but can touch many donations; limit 1 is not a row-count or routing-work limit.

An unsafe custody candidate follows existing reconciliation handling, does not
reopen, and becomes ineligible for future automatic recovery. Actual SQL errors,
timeouts and deferred-constraint failures roll back the whole invocation,
including transitions, audit events and refresh queue writes. With limit 1 this
protects other candidates from same-call rollback but does not eliminate starvation:
a persistently failing oldest unlocked candidate can fail every minute. Pause on
the first failure and investigate; do not increase batch size, delete evidence,
auto-close cases, silently skip a bad claim or extend timeouts to bypass it.

This supervision mitigates starvation for a short DEV experiment, not continuous
operation. Unattended operation still needs a named operational owner and durable
failure/backlog alerting. No new error-catching or batch algorithm was introduced.
One-minute scheduling with limit 1 means at most one candidate per invocation;
it is not a global wall-clock throughput guarantee against queued/delayed runs
or separately authorized manual/service-role invocations. Prohibit other recovery
invocations and cron edits during this canary.

## Existing and newly executed test evidence

Reviewed existing Stage 3F evidence: 46 isolated PostgreSQL tests (45 main + one
postquery test), 17 Stage 3A and 23 Stage 3E tests previously passed. Coverage
includes safe direct/whole-hub recovery, claim/listing case fences, repeated calls,
actual captured coordination RPC races, lease extension, SKIP LOCKED, listing
deadline crossings, route/custody preservation, SQL/audit errors and timeout rollback.
These prior results were reviewed, not rerun in this Stage 3G task.

Executed now:

- 81/81 offline contract tests PASS, including five new canary contracts.
- 8/8 new disposable PostgreSQL canary-script tests PASS (22.967 seconds): full
  activation COMMIT then pause COMMIT without business-row changes; source mismatch,
  overdue backlog, unresolved case, failed eligibility worker, wrong session role,
  active-job replay and injected postcondition failure/rollback.
- Existing full readiness and Stage 3F postdeploy SELECT files executed in DEV;
  updated readiness and all 12 new monitoring queries also executed successfully.
- git diff --check PASS; prior migration SHA contracts PASS.

The initial sandbox attempt could not start PostgreSQL (restricted-token error
87) and executed zero tests. The permitted retry completed all eight tests.

The new local cron.alter_job is an explicit transactional table-update double.
It proves script PL/pgSQL execution/guards/rollback, not real pg_cron scheduling,
Supabase execution privileges or scheduler networking. Existing fixtures also use
reduced tables and auth/road/eligibility doubles and omit full production RLS,
storage, pgRouting/PostGIS and some constraints/triggers. No claim of complete
production integration or load-test coverage is made.

## Exact proposed operator procedure, after separate explicit approval only

1. Assign one present human operator, with a second reviewer if available. The
   executing postgres operator owns every-minute inspection, immediate pause and
   incident notes. If that person becomes unavailable, pause before leaving.
2. Open DEV rcgyuwiidqvrgbxswhqj in SQL Editor, verify activation file SHA and
   use a clean postgres session. Coordinate no manual recovery, cron edits or
   privileged coordination-bypassing writes during the window.
3. Run readiness, monitoring and historical postdeploy SELECT files. Save complete
   outputs, source/security, cron definitions, runid baseline, audit/case baseline,
   candidate evidence and observed server timestamp outside the database.
   Require no backlog/cases and healthy workers; abort if new evidence differs.
4. Set a human reminder for ten minutes, keep pause SQL ready, and execute the
   complete reviewed activation file once. On error do not retry blindly; issue
   ROLLBACK if the SQL Editor connection is still in an aborted transaction, then
   inspect job state from a clean session. Transaction-end errors require readback.
5. Record actual COMMIT time. Inspect monitoring every minute, confirm the approved
   source and active limit-1 command, and inspect every new job-3 run. A successful
   SQL result/return_message '1 row' does not count recovered claims.
6. Empty-backlog runs should add no business audit/case/refresh writes. If a natural
   candidate is processed, inspect it immediately: exactly one pair-scoped recovery
   audit, correct claim/lease/task/listing/donation or whole-hub states, donation
   transition audits and expected refresh generation/enqueue/completion. A new
   reconciliation transition is conservative handling, but ends this initial
   no-op canary for human review. Never create a test claim merely to exercise cron.
7. Pause at ten minutes even if healthy. Run readiness/monitoring again, ensure job
   3 is inactive, inspect all in-flight runs to terminal state, verify jobs 1/2
   remain healthy and review any affected Flutter claim cards after read refresh.
   An all-no-op canary proves scheduler/permission/timeout plumbing only, not a
   real automatic recovery path. It does not authorize unattended continuation.

## Stop conditions and immediate pause

Pause at once for ANY job-3 failure/timeout/deadlock, missing run for >2 scheduled
minutes, a run still active near/after the 50s statement budget, source/ACL/cron
drift, any unexpected case/reconciliation transition or custody conflict, missing
or duplicate pair-scoped audit evidence, partial lifecycle restoration, failed or
stuck eligibility refresh, or jobs 1/2 failing/stalling. Also pause if the same
oldest candidate persists across two completed runs or any lease is >5m overdue.
Repeated rollback is a hard stop, not a reason to tolerate the first error.

After explicit incident-action approval/use within the approved canary procedure,
execute the complete review-only pause file as postgres. Its only cron mutation
is cron.alter_job(3,active := false). Inspect cron.job_run_details return_message,
start/end/status and pg_stat_activity blockers; capture affected claim/lease and
audit evidence. Pause does not cancel an in-flight invocation or undo committed
recoveries. Observe it until termination before declaring quiescence. If a backend
does not terminate, identify its exact PID and obtain separate approval for targeted
cancellation; never cancel eligibility workers or arbitrary postgres sessions.

For a failed recovery PostgreSQL transaction, business writes roll back atomically;
failed-run evidence is in cron history, not a durable in-transaction failure audit.
For a committed recovery there is no safe generic undo SQL: use existing protected
coordination/reconciliation procedures only after a new incident review. Do not
recreate ACTIVE leases, force listings CLAIMED or edit audit history manually.
Do not restore the original limit 100 automatically when pausing.

No DEV state-changing SQL, recovery invocation, cron mutation, migration deployment,
application change or teammate-owned implementation modification was performed.
Only review-only operational SQL, local tests and this review were prepared.
