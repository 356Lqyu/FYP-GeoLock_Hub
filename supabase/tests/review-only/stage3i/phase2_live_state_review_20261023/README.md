# Stage 3I Phase 2: live-state guarded activation proposal

Preparation only. This package has NOT been executed in DEV. DEV project is
`rcgyuwiidqvrgbxswhqj` only. Supabase MCP remains read-only. The human operator
executes approved activation/pause SQL in that project's SQL Editor as postgres.
No new execution approval is inferred from earlier packages' approvals.

**Verdict: CONDITIONAL GO for review; execution approval remains pending.**

## Previous rejection

The baseline copied from the actual failed SQL was `2026-10-23 11:26:29.48348+00`.
That exactly matches package `112629`, whose external readiness deadline was
19:29:29.483480 MYT. It does not match package `113154`, whose baseline was
11:31:54.423718 UTC and deadline 19:34:54.423718 MYT. The files differ only in
baseline_at. At the reported approximate 19:32 attempt, the older baseline was
about 5m30s old and failed the original three-minute freshness condition.

This establishes an outdated manifest in the executed text. Complete pasted bytes
and an exact failure timestamp were not independently logged; file attribution
also relies on the operator's confirmation that the pasted text was unedited.
The postgres/UTC diagnostic and populated operator fields do not indicate another
unmet requirement. The original guard correctly stopped before activation.
Later read-only checks found no persistent activation/recovery effect: job 3
inactive, the same 12 historical runs and unchanged fixture state.

## Exact fixture and latest SELECT-only evidence

| Object | Approved ID |
|---|---|
| Claim | 8161392c-e1e1-4723-a954-c80b6b61a8c7 |
| Lease | 11b7d48e-a459-4b47-b1db-b43f98d0d474 |
| Listing | 95d6cd51-866b-4eec-8a36-36dc24296aec |
| Donation | 3a012ba4-25cc-4054-897e-008e11da3e9e |
| Pickup task | 270caa8b-5a6d-481c-b199-c9a47156dda2 |

Read-only target snapshot: 2026-10-23 11:58:49.076988 UTC (19:58:49.076988 MYT).
Health snapshot: 11:59:17.931344 UTC. The target alone is overdue ACTIVE/ACTIVE;
task CONFIRMED, listing/donation CLAIMED, version 2, generation 1, NULL listing
expiry. Natural lease expiry remains 2026-10-23 02:33:13.441725 UTC. There are
no unresolved cases, assignments, stops, inventory, batch membership, reservations
or receipts. Exactly the original four successful target audit events remain.

Job 3 is inactive with the same 12 succeeded historical runs and no unfinished
runs. Jobs 1/2 are active, each with 60 succeeded runs in the preceding hour.
The approved recovery body fingerprint, owner, search_path and ACL are unchanged.
Other 85 public functions' combined source/ownership/ACL hash is unchanged.
See `read_only_evidence.json`; these observations are evidence, not a substitute
for the execution-time guards.

## What changes in this procedure

The original safety checks remain: clean postgres session; explicit present
operator and maintenance confirmation; exact target IDs, identities, lease length,
natural expiry, source type, lifecycle states, version/generation and title;
sole nonterminal claim/lease; no reconciliation, route, inventory or batch evidence;
source fingerprint and exact ACL; inactive job 3, exact command/schedule/owner,
unchanged historical run IDs; healthy eligibility workers; no other active client
transactions; unchanged scoped outside-business snapshot; unchanged jobs 1/2;
transactional activation postconditions and fixed 300-second supervised maximum.

The replacement obtains EXCLUSIVE NOWAIT locks on 16 explicitly named public
tables and SHARE ROW EXCLUSIVE NOWAIT on cron.job before reading live state.
These short DEV maintenance locks prevent row writers, SELECT FOR UPDATE,
route/reconciliation insert phantoms and concurrent cron configuration changes
from invalidating the checks before COMMIT. Ordinary SELECT remains possible.
READ COMMITTED sees the latest committed state after acquiring the locks.
Conflicts abort without waiting; stop and investigate rather than removing locks.
Idle-in-transaction and statement timeouts are 10s; lock_timeout is 5s.

The internal baseline_at is assigned only AFTER a real locked database read.
The existing freshness sanity check then measures that internal read; it no longer
depends on the age of an external file. The embedded reference timestamp is for
read-only monitoring/history, not an external expiration deadline. Expected IDs,
outside-business hash, versions and reviewed target audit hash are NOT refreshed
or accepted automatically. Drift aborts and requires review. Reservation/receipt
checks and a target-audit-history fence supplement the original checks.

Activation changes only job 3's active flag and appends a one-use comment to its
command. The actual SQL remains `recover_expired_claims(1)` with 5s lock and 50s
statement timeouts, once per minute. Pausing retains the marker, so replay of this
activation package rejects even if no scheduler tick occurred. No recovery
function, migration, grants, fixture or routing implementation is changed.

This is one activation transaction, NOT a guarantee of exactly one scheduler
invocation. The approved worker selects its candidate again under its own locks.
Activation locks end at COMMIT and cannot pin a later asynchronous cron tick.
Keep competing claim/pickup/donation/route/recovery/admin actions stopped for the
entire supervised window. An independently privileged session could still change
function definitions or data later. No unconditional target-isolation guarantee
is claimed. Strict unattended or adversarial isolation would need a separately
approved worker design; that is outside this package.

## Files and operator parameters

`01_preflight.sql`, `02_health.sql`, `02b_custody.sql`, `04_monitor.sql`, and
`05_verify.sql` are SELECT-only. `03_activate.sql` and `06_pause.sql` mutate only
cron configuration if a human executes them. Keep pause in its own SQL Editor tab.

`03_activate.sql` deliberately contains `execution_approved: false`. It rejects
before locks or cron changes if accidentally executed now. Operator is
`DEV Test Operator (myself)`; maintenance_confirmed is true based on the operator's
recorded commitment, and operator_confirmation is
`SUPERVISE_AND_PAUSE_WITHIN_300_SECONDS`. Reconfirm these commitments at execution.
The software can validate explicit parameter values, not prove human presence.

After separate explicit approval for THIS procedure, prepare a final execution
copy by changing only execution_approved to true and approval_ref to that approval
reference in the manifest, then rerender with the supplied generator. Confirm the
SQL diff contains only those two parameter changes, calculate its new checksum,
and review that checksum before execution. Do not hand-edit safety predicates,
the pinned hashes, source fingerprint, history, candidate IDs or worker command.
No new three-minute external package cycle is required.

## Exact supervised execution steps (after separate approval only)

1. Confirm DEV project and postgres role in SQL Editor. Keep application and other
   maintenance writes stopped; do not stop jobs 1/2. Open the entire approved
   execution copy of 03_activate.sql in a NEW tab and verify its SHA-256.
   Prepare 06_pause.sql in a separate tab. Never reuse an old activation tab.
2. Run SELECT-only files 01, 02 and 02b for operator review. Stop on drift,
   unexpected evidence, failed health checks, pending operations or another
   candidate. These queries do not authorize any state change.
3. Start a five-minute timer BEFORE Run, then run the entire approved 03 file
   once, including BEGIN and COMMIT. It reruns all safety guards against locked
   live state. If rejected, do not alter guards or retry blindly. If a transaction
   remains aborted, issue ROLLBACK in the same tab before further work.
4. Save activation_receipt and confirm COMMIT plus job 3 active with a SELECT.
   Receipt includes activation_statement_utc and absolute pause_deadline_utc/MYT.
   Its anchor is immediately BEFORE cron.alter_job; deadline is anchor +300s,
   conservatively no later than COMMIT +5m. Receipt's committed=false correctly
   states that it is produced before COMMIT; it is not commit proof. If any error,
   unclear commit, missing receipt or missing deadline occurs, pause immediately.
5. Run 04_monitor.sql roughly every 5-10 seconds. Pause on the FIRST recovery
   outcome (including reconciliation), scheduler error, unexpected state or
   missing evidence. Otherwise pause at the earlier of the receipt deadline and
   the timer started before Run. Do not wait for Codex or for eligibility refresh.
6. Execute the COMPLETE 06_pause.sql and confirm COMMIT plus job 3 inactive.
   Then check unfinished runs: pause prevents new scheduling but does not cancel
   an already running transaction or undo committed recovery. If pause fails,
   retry the reviewed pause immediately and inspect the blocker. Any cancellation
   or remediation needs a separately verified backend and separate approval.
7. Run 05_verify.sql and health queries after pause. Eligibility jobs remain active;
   allow generation 2 to complete while recovery stays paused. All verification
   flags must be true. Verify Flutter shows History -> Released after read-only
   refresh; do not start pickup or other claim actions. Retain fixture and audits.

Expected result: claim and lease RELEASED with EXPIRED_SAFE_RELEASE, task STALE,
donation/listing AVAILABLE, listing version 3, eligibility generation 2, exactly
the expected target-scoped recovery and donation-status audit events, no new
reconciliation case, unrelated snapshot unchanged, generation-2 refresh COMPLETED.
A successful activation command alone proves none of those recovery outcomes.

Stop on any unexpected reconciliation/custody/route evidence, extra candidate,
source/permission drift, failed or repeatedly rolled-back runs, missing/duplicate
target audit events, wrong status/version/generation, unrelated changes, unhealthy
eligibility workers or unavailable operator. Do not repair or retry recovery
automatically. Pause first, retain evidence and investigate read-only.

## Validation and limits

Actual final results: 99 offline contracts PASS; 19 dedicated isolated PostgreSQL
tests PASS (56.468s). The rendered SQL bytes match the generator, all SQL SHA-256
checksums are independently verified, and git diff --check passed. Initial test
failures exposed the local cluster's Etc/UTC-versus-UTC default; the disposable
fixture is now explicitly UTC like DEV. Negative tests assert the actual rejecting
safety guards. No safety condition was removed to make tests pass.

Review-copy activation SHA-256:
`CD7DDAEF41529A99AB996AFCF9C35637066D67294D5104A41E29B33AD9799632`.
Immediate-pause SHA-256:
`834CA3455873EBF494A6D3F94D0357BB1F9DD22C5C6EEEC525BB74AB3E90DE86`.
All seven SQL hashes are in SHA256SUMS.txt. A later approved execution copy with
execution_approved=true will necessarily have a different activation checksum.

The dedicated isolated suite installs the approved actual recovery definition in
a new disposable loopback PostgreSQL 17 cluster. It exercises the complete
activation/COMMIT, rejection/rollback, NOWAIT conflicts, blocked writers, approval,
source, audit, candidate/case/custody guards, five-minute receipt and one-use replay.
It also invokes the actual recovery on an isolated simulated tick, repeats it,
pauses and executes post-verification. No DEV recovery is invoked.

cron.alter_job is a transactional table double; scheduler ticks and eligibility
completion are simulated. Tables are reduced fixtures, auth/routing have explicit
doubles, and reservation/receipt tables are minimal guard fixtures. This does not
prove live pg_cron scheduling, all production triggers, routing behavior, network
delivery or human timing. Supabase/real worker integration remains the supervised
test's purpose. UTC fixture defaults align with DEV; a different starting session
timezone is tested and normalized transaction-locally for activation.

There is NO automatic pause job or autonomous emergency operator. Manual pause is
mandatory within five minutes, preferably after the first outcome. Continuous
unattended recovery remains NO-GO. No readiness timestamp needs extension: the
execution-time checks either pass on current state or roll back fail-closed.
