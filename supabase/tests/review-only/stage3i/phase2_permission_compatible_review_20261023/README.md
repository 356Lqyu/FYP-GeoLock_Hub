# Stage 3I permission-compatible activation: review only

**CONDITIONAL GO for a supervised DEV test after separate execution approval.**
This copy has execution_approved=false. No executable-approved copy was prepared.
Do not run activation now. All earlier activation packages containing a direct
cron.job lock are NO-GO and must not be reused.

DEV project: rcgyuwiidqvrgbxswhqj only. No DEV writes, cron calls, advisory locks,
recovery calls, grants, ownership changes, deployments or fixture changes were
performed. Supabase MCP was used only for SELECT diagnostics.

## Cause and scope

DEV postgres is NOSUPERUSER, INHERIT, BYPASSRLS, CREATEDB and CREATEROLE. The
supabase_admin-owned cron.job has RLS enabled and grants postgres only SELECT
(with grant option). There is no INSERT/UPDATE/DELETE/TRUNCATE/MAINTAIN privilege.
Direct SHARE ROW EXCLUSIVE locking and SELECT FOR UPDATE therefore fail.
The supported cron.alter_job API is executable by postgres, and pg_cron 1.6.4
internally executes its UPDATE as the extension owner while checking job ownership.

The existing approved recovery function is NOT changed. Its body fingerprint
remains 5ff6d8719db9681aae6f444b89dfbaee, owner postgres, SECURITY DEFINER, default
100, integer result, protected search_path, and postgres/service_role EXECUTE ACL.
The worker command remains batch 1/minute, 5s lock_timeout and 50s statement_timeout,
with only the previously reviewed harmless one-use comment appended on activation.

## Replacement locking protocol

1. BEGIN REPEATABLE READ; SET LOCAL timeouts/search_path/UTC.
2. Acquire the same 16 public business-table EXCLUSIVE NOWAIT locks BEFORE the
   first DO/SELECT establishes the transaction snapshot. Do not prepend queries
   inside this transaction or move locks into DO. The snapshot therefore contains
   committed business state observed after the locks are held. Staged-client tests
   verify no snapshot exists before DO and that intervening commits are seen.
3. Validate clean postgres identity, explicit operator/approval parameters, and
   REPEATABLE READ. Obtain pg_try_advisory_xact_lock(1936288105,3). A busy protocol
   aborts. This key is only a cooperative activation/admin convention.
4. Run all existing source/security, cron/history/health, exact fixture, sole
   candidate, custody/reconciliation, target-audit and outside-snapshot guards.
   Runtime freshness follows a real locked read; no external three-minute deadline
   is introduced. Pinned IDs/hashes/versions are never accepted anew automatically.
5. Call cron.alter_job(3,active:=false). This supported no-op UPDATE locks job 3's
   row. It does not touch jobs 1/2. Compare unchanged job metadata and assert our
   xmin plus a granted RowExclusiveLock. If the API does not provide the expected
   transactional UPDATE behavior, abort before activation.
6. If another transaction changed job 3 since the snapshot, PostgreSQL rejects
   our UPDATE with serialization error 40001. This avoids READ COMMITTED's risk of
   silently overwriting an intervening change. Once our row lock is held, other
   job-3 UPDATEs wait until our transaction ends, even without the advisory key.
7. Capture the real activation-statement timestamp and +300s deadline; activate
   using the original supported API. Run preserved postconditions, return receipt
   and COMMIT. Both cron updates are one atomic transaction: no intermediate
   inactive configuration is published. Any exception rolls back both updates.

The supported no-op is NOT a live diagnostic and must never be sent through MCP.
It exists only in this review-only future human activation script. Public locks
now precede the approval check to obtain a fresh RR snapshot: accidental execution
of the false copy may briefly lock business tables, but cannot call either cron
API or commit any cron change. This ordering is intentional and tested.

Advisory-only locking was rejected as insufficient. Simply weakening/removing
the unsupported cron lock was rejected. A no-op API UPDATE under READ COMMITTED
was rejected because it could overwrite an intervening admin change. New grants,
SECURITY DEFINER helpers or role escalation would broaden deployment scope and
are not proposed.

## Explicit limits and required operator ownership

This DOES NOT replace a global cron.job table lock. A nonparticipant can create
another job or alter jobs 1/2. The test suite deliberately demonstrates a new job
can be inserted during this transaction. Advisory locks do not stop those sessions.
The job-3 row lock prevents overlapping changes to that row only until COMMIT.
All public locks and the advisory lock also end at COMMIT, before the async tick.

REPEATABLE READ catalog, run-history and business guards describe the initial
execution-time snapshot; repeating those queries does not independently prove
that an administrator made no later catalog/function/grant changes. No absolute
protection against privileged nonparticipants or future changes is claimed.

CONDITIONAL GO requires the DEV Test Operator to own the cron/admin maintenance
window: no other operator/tool may create/alter recovery schedules, replace
functions, change grants or mutate claims/pickup/custody/routing/donations. Keep
application writes stopped. Jobs 1/2 keep running. If exclusive admin coordination
cannot be confirmed, the recommendation is NO-GO. This remains a supervised
canary, never permission for unattended recovery.

## Exact pinned fixture and live evidence

| Object | ID |
|---|---|
| Claim | 8161392c-e1e1-4723-a954-c80b6b61a8c7 |
| Lease | 11b7d48e-a459-4b47-b1db-b43f98d0d474 |
| Listing | 95d6cd51-866b-4eec-8a36-36dc24296aec |
| Donation | 3a012ba4-25cc-4054-897e-008e11da3e9e |
| Pickup task | 270caa8b-5a6d-481c-b199-c9a47156dda2 |

SELECT-only checks at 2026-10-23 12:40:24.739386 UTC and 12:41:00.984587 UTC
(20:40/20:41 MYT) confirm only one overdue ACTIVE/ACTIVE claim/lease, the exact
target. Task CONFIRMED, donation/listing CLAIMED, DIRECT_PICKUP, NULL listing expiry,
version 2/generation 1. No route assignment/stop, unresolved case, inventory,
membership, reservation or receipt. Natural lease expiry is unchanged:
2026-10-23 02:33:13.441725 UTC. There are no unfinished worker runs or other active
client transactions in that health snapshot. Job 3 is inactive with its original
command and unchanged 12 succeeded historical runs. Jobs 1/2 are active; each has
60 succeeded runs in the preceding hour.

Outside-business hash stays 070bb28ff5737477d6d91ec9e36feb02, preserving the scoped
records including previous controlled recoveries. Target audit hash remains
62681c4f345b496c07666036ce9263b6. All original audit/lifecycle/security assertions
remain. The reference baseline_at is intentionally not an external readiness timer.

## Operator steps after separate approval only

1. Reconfirm personal supervision and exclusive cron/admin/application maintenance.
   Render a separately approved execution copy; verify its new checksum and diff.
   This review file remains false and is not permission to execute.
2. Use a clean DEV SQL Editor session as postgres, with no existing transaction.
   Open the complete approved activation file in a new tab and 06_pause.sql in
   another ready tab. If a previous transaction is aborted, ROLLBACK first.
3. Review SELECT-only 01_preflight, 02_health, 02b_custody and 02c_permissions.
   Stop on drift, unexpected candidates/custody/cases, worker failures or unavailable
   admin ownership. Do not alter safety predicates to get a pass.
4. Start a five-minute timer BEFORE Run. Run the whole approved 03 file once,
   including standalone locks, DO and COMMIT. No short external readiness cutoff
   exists. A lock timeout or serialization failure requires read-only investigation,
   not an automatic retry.
5. Save activation_receipt and confirm COMMIT. It supplies activation_statement_utc
   and absolute pause_deadline_utc/MYT, exactly 300s later. The anchor is immediately
   before final ALTER, conservatively earlier than COMMIT. committed=false denotes
   receipt creation before COMMIT, not commit proof. If uncertain, pause immediately.
6. Poll 04_monitor.sql every 5-10s. It is ONE SELECT result containing target rows,
   audits, refresh queue, new runs, ALL recovery schedules, active transactions,
   reconciliation and eligibility health. 07_schedule_monitor.sql is a separate
   quick schedule check. Expect exactly one recovery schedule, job 3.
7. Execute the COMPLETE 06_pause.sql immediately after the FIRST outcome/error or
   at the earlier of the saved deadline and timer. Do not wait for Codex or refresh
   completion. Pause intentionally does NOT use the advisory lock; another protocol
   holder must not prevent emergency pause. Its API can still wait on a real row
   lock, bounded by 5s lock/10s statement timeout. If pause fails, retry the reviewed
   pause immediately and investigate the blocker; no new cancellation SQL is supplied.
8. Confirm pause COMMIT, job 3 inactive, and no unfinished run. Pause prevents new
   scheduling but does not cancel an in-flight run or undo committed recovery.
   Run 05_verify and health queries. Recovery stays paused while eligibility
   generation 2 completes. Refresh Flutter read-only and preserve fixture/audits.

Expected: claim/lease RELEASED with EXPIRED_SAFE_RELEASE, task STALE, donation and
listing AVAILABLE, listing version 3, eligibility generation 2, correct target-
scoped recovery/status audit events, no new reconciliation, outside records
unchanged, and generation-2 eligibility refresh COMPLETED. The strengthened final
reader also requires the marked paused command, exactly one recovery schedule,
and active jobs 1/2. Success of activation alone proves no recovery outcome.

Pause/stop on any unexpected reconciliation, custody/route evidence, extra recovery
schedule/candidate, worker error, repeated rollback, source/permission drift,
missing/duplicate audits, wrong state/version/generation, unrelated change,
unhealthy eligibility worker, missing receipt or lost supervision. Pause only
job 3; investigate unrelated schedules without automatically modifying them.
No automatic pause is installed. Five minutes is a human maximum, not a lease
on unattended execution. Do not clean up, run manual recovery or change migrations.

## Test boundaries and source references

Actual final results: **30 restricted-role PostgreSQL tests PASS (85.379s)** and
**106 offline contracts PASS**. The old 42501 is reproduced in isolation. Tests
cover all preserved live-state guards, real stored-command recovery/repeat/pause,
rollback after the supported no-op and after activation, protocol contention,
real row-lock blocking, concurrent job-3 change -> 40001, latest snapshot ordering,
monitor parsing, and emergency pause despite an advisory holder. One intentional
limitation test proves a nonparticipant can insert another schedule. SHA-256 files
are independently checked against rendered SQL and the generator; whitespace
checks pass. No real pg_cron scheduling is claimed by these tests.

Review activation SHA-256:
`F9E6DF96252CC6E763FF45839D478DFAD03263A8897F2B5E373F0E889A59AD0F`.
Pause SHA-256:
`834CA3455873EBF494A6D3F94D0357BB1F9DD22C5C6EEEC525BB74AB3E90DE86`.
All nine SQL checksums are in SHA256SUMS.txt. Changing approval parameters later
will require a newly verified execution-copy checksum; this file stays review-only.

The fixture uses a distinct postgres LOGIN with NOSUPERUSER/BYPASSRLS/INHERIT/
CREATEROLE/CREATEDB, owns the business tables, and has only SELECT on admin-owned,
RLS-enabled cron.job plus EXECUTE on the supported API. Tests use real independent
postgres sessions, not SET ROLE masking a superuser session_user. A separate
fixture_admin handles only fixture setup. PostgreSQL's bootstrap superuser cannot
be demoted, so it is renamed and a NEW restricted postgres role is created.

Actual approved recovery/lifecycle functions execute in the isolated database.
The exact stored marked worker command is used for simulated ticks. Scheduling,
cron permissions internals and eligibility completion remain explicit doubles.
The API double is SECURITY DEFINER SQL owned by fixture supabase_admin, emulating
the real C API's internal owner-context switch; real cron.alter_job is C and NOT
SECURITY DEFINER. No real pg_cron scheduler/binary is installed locally. No real
road algorithm, full production RLS/storage/photo integration or network delivery
is tested. The live API's owner-privileged UPDATE semantics are reviewed against
installed version 1.6.4 source; the live API has NOT been invoked for validation.

The production wrapper asserts its row-update/lock postconditions before activation
to fail closed if that assumption does not hold. Future live integration remains
a separately approved supervised test. No production helper or grant is installed.

Sources: [pg_cron 1.6.4 AlterJob implementation](https://raw.githubusercontent.com/citusdata/pg_cron/v1.6.4/src/job_metadata.c),
[PostgreSQL 17 LOCK privileges and snapshot ordering](https://www.postgresql.org/docs/17/sql-lock.html),
[PostgreSQL advisory locking semantics](https://www.postgresql.org/docs/17/explicit-locking.html#ADVISORY-LOCKS).
