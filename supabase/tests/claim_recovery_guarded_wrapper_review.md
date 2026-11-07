# Stage 3B isolated wrapper validation

Preparation only. No recovery or state-changing SQL was sent to DEV.
DEV MCP was bound to rcgyuwiidqvrgbxswhqj with read_only=true; observed SQL
identity was supabase_read_only_user and transaction_read_only was on.
Never use the shared project. The SQL files below are review/test artifacts,
not migrations and not an instruction to execute recovery.

**Verdict: PASS for the revised wrapper in the documented isolated fixture.**
Live execution still requires explicit user approval and a fresh preflight.

**Artifacts**

- fixtures/claim_recovery_guarded_original.sql: exact prior proposed transaction,
  recovered from the preceding conversation's SQL block, stored with LF endings.
  SHA-256: 0D727F47D7BF1D3A66411C5C9B202FC8BEDA12629D29AFEA2333712E6EA2DB89.
- fixtures/claim_recovery_guarded_final.sql: complete revised transaction tested
  without substitutions in its success and most failure tests.
  SHA-256: 2D4833146341D45ECB97829A7E72AC3F2C8908561DC658C0D7605E28342D3E02.
- fixtures/claim_recovery_guarded_live_triggers.sql: SELECT-only capture of the
  deployed listing generation and asynchronous eligibility enqueue triggers.
- claim_recovery_guarded_wrapper_isolated_test.py: opt-in runner; no DSN/URL
  accepted, PG connection environment stripped, NEW disposable loopback cluster
  only, automatic server shutdown and temporary directory cleanup.

**Only wrapper correction**

Two matching SQL hunks scope the existing audit-ID snapshot and new-event count
to the three known claims and target lease/donation/listing references. Every
other SQL statement is identical to the original. A source-contract assertion
checks the complete resulting string against exactly these two substitutions.

The original global count was demonstrated to fail on a concurrently committed,
unrelated audit event. Recovery rolled back; the unrelated transaction remained.
The revised full transaction commits under the same unrelated-insert scenario,
while still demanding exactly one fully matched LEASE_RECOVERY event and one
fully matched DONATION_STATUS_CHANGED event. Extra target or other-candidate
events, wrong payloads and missing events remain failures.

**Results**

PostgreSQL 17.11, Python 3.14, final isolated run: 28/28 PASS, 63.319 seconds.
71/71 existing offline source-contract tests PASS; git diff --check PASS.
An initial run had two test-fixture failures because the service_role double
lacked USAGE on auth; the fixture permission was corrected and all tests rerun.
The original and final wrappers both compiled and committed in real PostgreSQL.

| Cases | Result |
|---|---|
| Exact original and exact revised full BEGIN/DO/assertions/COMMIT | Target alone released; other two records and links unchanged |
| Wrong current role, wrong session_user, non-NULL JWT subject | Abort before recovery |
| Source or EXECUTE ACL drift | Abort before recovery |
| Recovery cron active or has history | Abort before recovery |
| Oldest-first ordering changed; target task no longer CONFIRMED | Abort before recovery |
| Unexpected return, corrupt recovery audit, duplicate target audit | All recovery writes rolled back |
| Extra other-candidate audit; other candidate's task changed | All recovery writes rolled back |
| Missing eligibility enqueue | Claim, lease, task, listing, donation, audits and cache changes rolled back |
| Deferred constraint failure | Raised by SET CONSTRAINTS ALL IMMEDIATE; full rollback |
| Claim/lease table conflicts; target listing row conflict | NOWAIT abort, no recovery writes |
| Enqueue unique-key lock conflict after release writes | 5-second lock timeout; full rollback |
| Statement cancellation during actual recovery | Full rollback |
| COMMIT attempted after assertion error with psql ON_ERROR_STOP=0 | PostgreSQL returns ROLLBACK; recovery not committed |
| Concurrent unrelated audit insert | Original rejects; revised commits; unrelated event preserved |
| Changed pickup route snapshot | Strict task postcondition rejects and rolls back |
| Exact correction scope, recovery(1), no cron/function mutations, Stage 3A hash | PASS |

15 tests enter the actual patched recovery function; remaining tests reject
before recovery or inspect source contracts. Every setUp installs the complete
approved Stage 3A migration into the disposable database, including its own
source/header/ACL guards and COMMIT.

Two tests explicitly use test-only wrapper variants: unexpected-result injection
sets v_count=0 after the real recovery(1) call, and the cancellation test lowers
statement_timeout from 50 seconds to 100 milliseconds. The COMMIT-after-error
test uses the same return fault. They do not rewrite recovery logic. Isolated
source-drift and ACL-drift tests intentionally alter only the disposable clone.

**What is real and what is stubbed**

Real approved patched recovery source and six actual lifecycle dependencies:
geolock_lock_listing_donations, geolock_transition_listing_donations,
geolock_assert_donation_lifecycle, geolock_validate_donation_at_commit,
enforce_donation_transition, enforce_listing_transition. The actual deferred
donation validator and transition triggers run. The two exact deployed listing
trigger functions run, invalidate cache and enqueue a generation-specific job.

Reduced schema and fixture auth functions/cron tables are explicit doubles.
geolock_resolve_road_node returns one fixed valid fixture node/snapshot; no
teammate-owned routing implementation is changed or tested by this stub.
No real pg_cron scheduler, eligibility worker, PostGIS/pgRouting, Supabase SQL
Editor, storage/RLS or full production constraint graph is integrated here.
No recovery business logic is mocked on the successful path.

**Locks and strict assertions**

EXCLUSIVE locks on donation_claims then claim_leases freeze writes and exclude
other FOR UPDATE selectors (ROW SHARE). Same-transaction row locks are not
SKIP LOCKED by its own recovery call. Together with the approved oldest-first
source, exact three-candidate order, limit 1, and postconditions, this isolates
the intended target under ordinary application/recovery concurrency. Such
table locks are sufficient for this strategy, not the only theoretically
possible isolation strategy; they are deliberately broad for a one-off DEV run.

Target rows follow claim -> lease -> listing -> task -> donation order. Table
and row NOWAIT acquisition fails instead of waiting on opposite-order writers.
Later helper, cache, coverage or enqueue locks can still time out or deadlock;
PostgreSQL then aborts the complete transaction. Workers locking queue before
listing are not rewritten; the deployed enqueue trigger intentionally avoids
locking old queue rows. A maintenance window with application writes stopped
is still required. Leave eligibility jobs 1/2 active and recovery job 3 inactive.

The current DEV pickup_tasks table has no non-internal triggers and no generated
columns, confirmed by SELECT. Its complete-row comparison excluding task_status
is compatible today. The normal donation updated_at change is allowed. Actual
listing triggers yield generation+1; no strict assertion pins a road node that
legitimately resolves differently on reopening. The eligibility worker changes
queue/cache data, not the other listing rows being compared. Future triggers or
schema changes may require a fresh review; current strict guards fail closed.

**DEV read-only evidence**

Before/after JSON snapshots matched for all three full claim/lease/task/listing/
donation rows, cron definitions, recovery source fingerprint, recovery history
and reconciliation count. All three remained ACTIVE/ACTIVE, tasks CONFIRMED,
listings/donations CLAIMED with NULL listing expiration. Recovery source remained
50110ff20115c4e5d46380e8e3f8b94c. Job 3 remained inactive with zero runs;
jobs 1 and 2 remained active. Zero LEASE_RECOVERY events and zero reconciliation
cases. No relevant competing locks were observed in the inspection snapshot.
Eligibility workers can continue their normal autonomous runs.

Stage 3A migration remains byte-for-byte at approved SHA-256
064B1E4CD5B5CD38E1F77B91364AF5ED99221926455D5D64AE7A4B70C1C31E7D.
No previously deployed migration, Flutter file, deployed function, data, grants
or cron configuration was modified by this validation.

**Remaining limitations and manual execution conditions**

This is genuine isolated PostgreSQL compilation/execution, not proof of all DEV
integration paths. Confirm clean postgres current_user/session_user, NULL
auth.uid(), correct DEV project, current source/security and all preconditions
again before any separately approved execution. Run the complete final file in
one fresh SQL Editor transaction with no unrelated pending work. Do not run the
original or any test fixture/setup SQL in DEV. A NOTICE does not prove COMMIT.
On any error explicitly ROLLBACK, inspect state and investigate before retrying.

No wrapper can prevent privileged concurrent DDL, manual cron activation or
arbitrary direct audit writes after its final assertions without broader
administrative coordination. Its scoped audit check intentionally ignores
unrelated transactions. The snapshots are checks within the transaction, not a
promise that external activity cannot change rows after COMMIT. Database records
do not prove unrecorded physical custody. Post-commit read-only checks and Flutter
refresh are still required; target should be History/Released and the other two
Expired/Recovery Pending. Do not activate automatic recovery as part of this run.
