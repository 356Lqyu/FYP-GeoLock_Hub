# Current-state supervised recovery session

**VALIDATION PASS: execution-ready copy prepared at the user's request.**
The user supplied passing fresh DEV health. No DEV activation was executed by
Codex. This permits only the human's bounded supervised session under the stated
conditions; permanent unattended operation remains unauthorized.

This replaces only the spent fixture-specific activation wrapper. It preserves
the approved function, existing cron command/schedule/role and the previously
tested permission-compatible lock/API strategy. It creates no object, fixture
or new cron job and invokes no recovery function. Only job 3's active flag would
change after approval. There is no external three-minute readiness deadline.

## Exact steps

1. The user has supplied passing fresh results from the existing SELECT-only
   [operational status query](../claim_recovery_dev_operational_status.sql).
   query (see FRESH_HEALTH_USER_REPORT.json). Required: approved recovery body/security,
   correct inactive job 3, healthy active jobs 1/2, no unfinished recovery,
   failed run requiring investigation, unresolved cases or integrity alarms.
   This untargeted session also requires no overdue ACTIVE/ACTIVE backlog at
   activation; any existing candidates need explicit ID/custody review first.
   No new fixtures or business tests are needed.
2. The user requested an execution-approved file after validation. Run it only
   when personally ready to supervise this session; no further rendering is needed.
   Verify the DEV project in the SQL Editor UI; all Supabase databases can be
   named postgres, so current_database() alone is not project identity proof.
   The operator must stay present, stop competing application/admin/recovery
   actions and keep jobs 1/2 running. No DDL or cron edits by other operators.
3. Open the approved [emergency pause](../stage3i/phase2_permission_compatible_execution_approved_20261023/06_pause.sql)
   in a second SQL Editor tab **before activation**.
4. Open **01_activate_EXECUTION_APPROVED.sql**. Operator confirmation is already
   filled; execute it unedited. The only SQL-body difference from the review
   copy is that explicit confirmation, exactly as exercised in the isolated tests.
   Keep every safety check unchanged. Start a five-minute timer BEFORE Run, then execute the
   complete BEGIN-to-COMMIT file once as a clean postgres/session_user postgres
   session. Do not prepend SELECTs inside its transaction or run selected lines.
   If the operator label differs, review that change before execution.
5. Save the receipt and successful COMMIT. Confirm job 3 active using 02_monitor.sql.
   The receipt gives an absolute UTC/MYT pause deadline anchored immediately
   before enabling. **No automatic pause exists.** Missing receipt, unclear
   commit status, failed guard/lock or any error means stop and use the pause
   procedure; never retry or edit a guard to force it through.
6. Poll 02_monitor.sql every 5-10 seconds. Pause immediately on the first new
   completed recovery invocation (including an empty successful tick), any
   recovery event/error/unexpected state, or the earlier of the receipt deadline
   and your five-minute timer. Do not wait for Codex or eligibility completion.
7. Execute the ENTIRE existing 06_pause.sql and confirm COMMIT. Run 02_monitor.sql
   and the operational status query again: job 3 inactive, no unfinished run,
   jobs 1/2 unchanged/healthy, no unexpected audits/cases/integrity changes.
   If recovery actually affected a newly expired claim, inspect its IDs/audits
   using the existing detailed claim_recovery_canary_monitoring.sql; do not use
   the old Stage 3I fixture-specific verifier. Retain evidence and data unchanged.

If a transaction is left aborted, ROLLBACK in that tab before further work.
Pause prevents new scheduling; it does not cancel queued/in-flight work or undo
a committed release. Inspect unfinished runs until completion; no cancellation
of backend sessions or correction of data is authorized by this package.

## Guards and limits

The file independently repeats fresh source/owner/SECURITY DEFINER/search_path/
ACL/signature checks, cron command/role/schedule checks, worker health, 360-minute
policy, absence of unresolved cases/unreviewed backlog and audit/integrity checks.
It uses no fixed fixture or 0/12/17-run baseline. Retained failed executions stop
for review rather than being silently acknowledged. No backlog at entry does not
guarantee no claim expires afterward; the approved recovery algorithm remains
the authority under locks during the actual tick.

Public NOWAIT locks are acquired before the REPEATABLE READ snapshot. Job 3 is
locked through the supported no-op cron.alter_job API with MVCC/lock assertions,
then enabled without rewriting any configuration. No unsupported cron table lock
is requested. All guards run before enabling, and errors abort the transaction.
Jobs 1/2 are compared before/after. All locks end at COMMIT. Advisory locks fence
only participating wrappers; concurrent unrelated DDL/admin/scheduler changes
are not globally prevented. The maintenance agreement and human supervision are
essential. There is no permission to leave job 3 active after this session.

## Validation

**19/19 isolated PostgreSQL wrapper tests PASS**, including full COMMIT, supported
API row locking, concurrency/rollback, command preservation and the exact pause
file. See VALIDATION.md and CHECKS.json/SHA256SUMS.txt. The execution-copy SQL body
is identical to the tested approved body. No Stage 3I business tests were repeated;
no donation/claim rows were created and no recovery function was invoked.
Only disposable loopback PostgreSQL cron metadata changed during tests.

The local pg_cron API is an explicitly documented owner-privileged behavior
double, not the native C scheduler. Native API use previously succeeded in Stage
3I; the present wrapper independently checks API permissions and supported-lock
postconditions at execution. Actual fresh DEV grants were not re-queried by MCP
because MCP is unavailable. Any drift aborts before activation commits.
Fresh health is user-reported and is repeated by runtime guards. Stop on failure.
