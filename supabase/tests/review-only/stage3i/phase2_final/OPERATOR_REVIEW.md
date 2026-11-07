# Final target-specific operator review -- PREPARATION ONLY

Verdict: CONDITIONAL GO for a separately approved supervised test; package ready
for review. No execution approval has been given. Do not activate or invoke recovery.

## Final read-only evidence

DEV rcgyuwiidqvrgbxswhqj only; MCP read_only=true. Snapshot 2026-10-23
11:14:48.685876 UTC (19:14:48.685876 MYT), custody/cron readback 11:14:54 UTC.
All required checks passed. Exact fixture:

- Donation 3a012ba4-25cc-4054-897e-008e11da3e9e: CLAIMED, DIRECT_PICKUP, 20kg.
- Listing 95d6cd51-866b-4eec-8a36-36dc24296aec: CLAIMED, NULL expiry, version 2/generation 1.
- Claim 8161392c-e1e1-4723-a954-c80b6b61a8c7: ACTIVE.
- Lease 11b7d48e-a459-4b47-b1db-b43f98d0d474: ACTIVE, genuinely expired since
  2026-10-23 02:33:13.441725 UTC (10:33:13.441725 MYT).
- Task 270caa8b-5a6d-481c-b199-c9a47156dda2: CONFIRMED.

Sole nonterminal/overdue claim and lease; no competing candidate, route/stop,
inventory/membership, reservation/receipt or unresolved case. Original four SUCCESS
audits remain, no recovery/pickup/handover event. Unrelated-business snapshot still
070bb28ff5737477d6d91ec9e36feb02. Approved recovery body 5ff6d8719db9681aae6f444b89dfbaee,
postgres owner, SECURITY DEFINER, protected search_path and exact postgres/service_role
EXECUTE ACL preserved; anon/authenticated cannot execute. Job 3 inactive, 12 historical
successes/no failures/unfinished runs. Jobs 1/2 active, 60 succeeded runs each in the
observed last hour. Other 85 public functions retain approved fingerprint.

## Operator and maintenance acknowledgement

Responsible human: DEV Test Operator -- the user, personally operating DEV SQL
Editor. User confirmed continuous availability, immediate manual pause on result
or any error, no competing claim/pickup/donation/recovery actions, SQL Editor open
and pause SQL ready. maintenance_confirmed=true records that acknowledgement; it
does not grant execution approval or enforce a global database mutex.

## The exact five-minute deadline

A preparation-only task cannot know a future actual activation or COMMIT timestamp.
The final 03_activate.sql therefore captures clock_timestamp() immediately before
cron.alter_job(3,active:=true), computes pause_deadline = that actual statement time
+300 seconds, and returns activation_receipt with absolute UTC and MYT deadline.
The anchor precedes COMMIT, so the deadline is conservative relative to when the
job becomes visible as active. This is an explicit 300-second maximum PROCEDURAL
window, not a database-enforced automatic pause. No new scheduler job is installed.

The receipt is stored only in a transaction-local session GUC and selected BEFORE
COMMIT; it is not a persistent table/audit record, and its committed=false marker
means it cannot prove COMMIT. Verify COMMIT success and read back cron separately.
If SQL Editor hides the receipt or COMMIT is uncertain, pause immediately from a
clean session and inspect before considering another activation. No deadline is
invented from the stale readiness snapshot or from the first cron tick.

The ACTUAL absolute deadline can only be populated during separately approved
execution. Save the receipt immediately. Start a 4m30s warning timer and a 5m hard
timer BEFORE pressing Run. Pause on the first outcome or warning, whichever comes
first; verify active=false before the absolute deadline, allowing commit/network
time. If a pause fails or cannot be confirmed, treat that as an incident, inspect
the job/run and do not assume scheduling stopped. No autonomous agent can guarantee
the bound if the human/network fails; continuous supervision is a required condition.

## Files, checksums and fresh-window condition

All final SQL files are in this directory; exact SHA-256 values in SHA256SUMS.txt.

1. 01_preflight.sql: exact fixture, server time, other candidates, state and hashes.
2. 03_activate.sql: guarded single transaction; only cron job 3 active flag changes,
   plus transaction-local timeout/receipt settings. No migration or recovery call.
3. 04_monitor.sql: exact target, audits, refresh and new runs after runid 3137,
   blockers and jobs 1/2. Its deadline field is NULL until a receipt is copied;
   the SAVED RECEIPT and operator timer remain authoritative for pausing.
4. 05_verify.sql: exact recovery/audit/version/generation/refresh/paused assertions.
5. 06_pause.sql: independent complete pause transaction; only disables job 3.

The rendered manifest contains the confirmed operator/maintenance arrangement,
max_activation_seconds=300 and server_clock_immediately_before_activation mode.
stop_at is intentionally computed at the activation event, not guessed here.
All canonical source/security/candidate/history/snapshot guards are preserved.
Three-minute snapshot freshness guard is preserved: this package baseline expires
at 2026-10-23 11:17:48.685876 UTC / 19:17:48.685876 MYT. If separate approval comes
later, fresh SELECT checks and rerendered SQL/checksums are REQUIRED. Never bypass
or extend the guard by simply editing a timestamp without new evidence.

## Proposed actions ONLY AFTER separate explicit execution approval

1. Verify DEV selection, current package/checksums and a clean postgres session.
   Keep maintenance restrictions and jobs 1/2 running. Open the complete pause file
   in a separate ready SQL Editor tab. Keep the operator continuously present.
2. Run fresh 01 plus the prior detailed supplemental SELECT checks; inspect source,
   security, all candidates, custody/cases, health and transactions. Refresh/render
   the package if its snapshot is stale or any relevant evidence differs. Stop on
   any failed check. Reconfirm hashes of the exact files to be executed.
3. Start timers BEFORE Run. Execute COMPLETE 03 once, including BEGIN/COMMIT. It
   preserves * * * * *, limit 1, 5s lock and 50s recovery statement timeout. Record
   absolute receipt deadline and COMMIT outcome. Do not call recovery manually.
4. Use 04 every 10-15 seconds around the next cron tick. Pause immediately once an
   outcome is observed or on error, and no later than the warning/hard deadline.
   Do not assume one scheduled invocation only; further ticks may be NOOP.
5. Execute COMPLETE 06 as postgres. Read back job 3 inactive and inspect all runs
   to completion; check jobs 1/2 unaffected. Pause does not cancel an in-flight run
   or undo a committed recovery. Any targeted cancellation needs separate approval.
6. Allow real eligibility worker completion; require 05 all_checks_pass=true and
   inspect saved snapshots. Refresh Flutter: Expired -> History / Released. Preserve
   all fixture/audit evidence. No cleanup or continuous reactivation is approved.

## Expected results and stop conditions

Claim RELEASED and lease RELEASED, both EXPIRED_SAFE_RELEASE with closure times;
task STALE with remaining snapshot fields preserved; donation/listing AVAILABLE;
listing_version 3, eligibility_generation 2; one correct pair-scoped SYSTEM/SUCCESS
LEASE_RECOVERY ACTIVE->RELEASED and one donation CLAIMED->AVAILABLE audit; generation
2 refresh enqueued by real trigger then COMPLETED without error; no new case, route
or custody evidence and no unexplained unrelated-business changes.

Pause at the first worker error/timeout/deadlock, wrong candidate, unexpected
reconciliation/custody/route evidence, missing or duplicate audit, partial restore,
snapshot/source/ACL drift, stalled/failed eligibility or loss of supervision. Stop
for no tick after two scheduled minutes or repeated retained oldest candidate; do
not increase batch size or bypass evidence. A conservative reconciliation outcome
fails this safe-release test and requires incident review, not forced reopening.
Real errors roll back the invocation, but poison-candidate starvation remains a
liveness risk; limit 1 and manual pause mitigate this short supervised test only.

## Validation and restrictions

91/91 offline contracts and 6/6 NEW isolated deadline/rollback wrapper tests PASS
(26.905s). The six tests did NOT invoke recovery; they used a transactional cron
table double in newly initialized loopback PostgreSQL. Exact 300s UTC/MYT receipt,
COMMIT/pause, unchanged business rows, wrong window/operator, stale baseline and
postcondition/deadline rollback were exercised. Prior recovery tests remain prior
evidence; real scheduler execution is still future work after approval.

Immediate pause SQL reviewed: clean postgres/session identity, exact job-3 name/
role guard, cron.alter_job(3,active:=false), paused postcondition, atomic COMMIT;
independent of target receipt/freshness. No blind data rollback or cleanup SQL.

No DEV activation, recovery invocation, fixture/data modification, grant/function
change, migration deployment, cleanup or shared-project access occurred. New local
wrapper/tests/final package only; original migrations and canonical SQL preserved.
WAIT for separate explicit approval before any state-changing DEV SQL.
