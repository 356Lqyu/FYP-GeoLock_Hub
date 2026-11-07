# Final supervised wrapper validation

**GO for one human-operated supervised DEV session**, conditional on continuous
operator presence, maintenance coordination and all execution-time guards.
Permanent/unattended activation is not approved. No live activation occurred.

## Actual tests

19/19 wrapper-only tests PASS in 28.735 seconds on a newly initialized local
PostgreSQL 17 cluster, bound only to 127.0.0.1. No external DSN is accepted. The
cluster is stopped/removed after testing. Windows sandbox prevents pg_ctl's
restricted token, so the isolated command used approved escalation. No existing
server or DEV connection was used.

```powershell
& '.venv-dev-fixtures/Scripts/python.exe' -B supabase/tests/supervised_recovery_current_isolated_test.py --run-isolated --pg-bin 'C:/Program Files/PostgreSQL/17/bin'
```

- Managed-role model: actual LOGIN postgres, NOSUPERUSER/BYPASSRLS, public-table
  ownership, cron.job owned by supabase_admin with RLS and SELECT-only access.
  Direct cron table UPDATE, SELECT FOR UPDATE and unsupported table LOCK fail.
- The exact approved recovery definition is installed for real pg_proc metadata
  and fingerprint comparisons, but NEVER invoked. No scheduler is installed.
  All donation/claim/lease/task/audit/custody tables remain empty. Only configuration
  and synthetic cron metadata are populated; no business fixtures are created.
- Full approved wrapper, inline PL/pgSQL and COMMIT execute successfully; the
  resulting cron.job data differs ONLY at job 3 active=false->true. Jobs 1/2,
  history, recovery source and empty business tables remain unchanged. The API
  double also records its two calls transactionally for assertion purposes.
- Both allowed worker command strings (canonical and exact historical comment
  variant) are accepted and preserved byte-for-byte. No command is reconstructed
  or rewritten. The comment is inert worker metadata, not the old script's
  execution approval. No spent fixture-specific script or manifest is reused.
- Review-only default confirmation rejects before either API call.
- Wrong identity, function source/ACL drift, revoked API permission, changed
  command, already-active job, failed/unfinished history and unhealthy worker stop
  without committed changes.
- A conflicting business lock rejects NOWAIT before the API. Concurrent job-3
  update after the RR snapshot causes SQLSTATE 40001. The supported no-op API
  update retains the job-3 row lock; another writer times out until commit.
- A forced exception after enabling rolls back both API calls and the active
  flag. This is transaction behavior, not a simulated business-recovery test.
- 02_monitor.sql executes in READ ONLY. The existing unchanged 06_pause.sql
  commits successfully as the managed role, restores inactive and leaves jobs
  1/2/configuration/source unchanged. The five-minute receipt interval is exactly
  300 seconds and is generated before activation COMMIT.

The 16-test first pass also succeeded. Three concurrency/lock checks were then
added and the complete final 19-test suite passed. Only the final total is used.
No Stage 3I recovery scenario was replayed and no new donation/claim was created.

## Native pg_cron limitation and current permissions

Native pg_cron is not installed in the local fixture. cron.alter_job is a narrow
SECURITY DEFINER SQL behavior double owned by the cron owner. It models the
native API's privileged metadata update, owner restriction and transaction locks.
It is NOT evidence that a new native scheduler tick ran.

The API's six-argument/defaulted signature and active flag operation are documented
in the [upstream pg_cron README](https://github.com/citusdata/pg_cron/blob/main/README.md#altering-a-cron-job).
The [upstream C implementation](https://github.com/citusdata/pg_cron/blob/main/src/job_metadata.c)
implements the metadata update/privilege handling. Earlier Stage 3I proved the
supported API on actual DEV; the user's fresh result reports unchanged healthy
job/function state. Current EXECUTE grants and function ACL/settings are checked
again by the wrapper, not assumed from the model. MCP is unavailable, so no new
independent live permission query is claimed here.

Read-only status/candidate checks are current at execution under business locks.
Administrative changes by nonparticipants are not globally prevented; no other
DDL/cron/recovery activity is allowed during the short supervised window.
Pause does not undo commits or cancel running/queued work. Monitor and verify
in-flight completion; no blanket backend cancellation is authorized.

## Approved rendering

01_activate_EXECUTION_APPROVED.sql differs from the reviewed file only in header
comments and the v_confirmation literal. Its BEGIN-to-COMMIT SQL body equals the
isolated-tested approved body exactly. It does not change the operator, approved
function, API parameters, guards, transaction, worker command or pause procedure.
The file is for this supervised session only, not permission to leave the worker
active or to reuse it without fresh readiness and supervision.
