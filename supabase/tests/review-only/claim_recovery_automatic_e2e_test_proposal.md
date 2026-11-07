# Review-only proposal: supervised automatic recovery end-to-end test

Not approved, not executed. DEV rcgyuwiidqvrgbxswhqj only. No state-changing SQL
is included. Keep job 3 inactive until a separate reviewed activation is approved.

## Purpose

The Stage 3G 12-run canary proved actual scheduler invocation on empty backlog.
Next prove one actual expired claim is safely processed by job 3, with real DEV
triggers, audit, asynchronous eligibility refresh and Flutter classification.

## Conditions before preparing executable SQL

1. Name the present primary/backup operators and confirm immediate-pause access.
2. Explicitly authorize the precise test records and any needed creation actions.
   Prefer a suitable naturally expiring DEV claim. If none exists, separately
   authorize a dedicated test donation/claim through protected normal workflows.
   Do not reuse the three historical recoveries or directly rewrite their rows.
3. Preserve the existing 360-minute lease duration and let the chosen test lease
   expire normally. Do not silently shorten expiry, disable constraints, inject
   audit rows, modify recovery source or bypass road/NGO authorization.
4. Immediately before testing, inspect ALL overdue candidates and exact IDs,
   expiry/order, custody/task, route stops/assignments, open cases, direct/hub states,
   current source/security, cron health, locks and eligibility generation.
5. Prepare new guarded activation SQL for the post-canary baseline: approved body
   5ff6d8719db9681aae6f444b89dfbaee, job 3 inactive/limit 1, exactly the reviewed 12
   historical successes and no extra runs. Existing Stage 3G script is not reusable.

## Scope and isolation

First use a DIRECT_PICKUP / DIRECT_DONATION claim with expired ACTIVE/ACTIVE lease,
CONFIRMED task, CLAIMED donation/listing, NULL or safely future listing expiry,
no route/custody/reconciliation evidence and a valid complete record set.

There must be exactly the reviewed candidate, or a separately approved bounded
candidate set. Oldest-first/SKIP LOCKED alone does not isolate a target; new/locked
candidates and concurrent authorized workers can change selection. Establish an
agreed maintenance window with no competing claim/recovery actions and take fresh
snapshots. Do not claim target isolation from an earlier snapshot or hold the
candidate row locked while expecting cron to select it.

Activation schedules limit 1 per minute, 5s lock timeout and 50s statement timeout.
Scheduler execution is asynchronous; an operator cannot promise exactly one run
merely by pausing quickly. Review additional no-op ticks and prohibit unattended
continuation. Keep eligibility jobs 1/2 enabled and prevent manual recovery calls.

## Evidence and acceptance

- Save full scoped business-row/audit/queue/source/security snapshots and server
  timestamps, cron runid baseline and actual activation/pause COMMIT timestamps.
- Let cron invoke recovery; do NOT manually call recovery to substitute for this test.
- Observe target RELEASED/RELEASED with EXPIRED_SAFE_RELEASE, task STALE, direct
  listing/donation AVAILABLE, one correct pair-scoped recovery audit and one correct
  donation transition audit. Check expected version/generation increment, real
  refresh enqueue then successful eligibility processing; no new reconciliation.
- Confirm all non-target records unchanged within the agreed snapshot scope.
- Refresh NGO My Claims and confirm Expired -> History / Released without a Flutter
  recovery RPC. Review donor/listing visibility and normal authorization as approved.
- Pause job 3 immediately after observing outcome, verify no unfinished run, inspect
  all retained new executions and show jobs 1/2 healthy. Stop immediately on error,
  custody uncertainty, unexpected case, missing audit, partial restore or extra target.

Follow with separately approved whole-hub tests before permitting automatic hub
workloads; verify all member donations, inventory, locks, audits and refresh atomically.
Existing isolated tests are useful evidence but not a live hub concurrency/load test.

Failure/rollback/custody fault injection should remain isolated unless explicitly
authorized in a dedicated DEV test plan. Never damage live claim evidence to test
monitoring. Continuous activation requires successful end-to-end evidence PLUS
durable alert ownership and response procedures; no single happy-path test is
sufficient on its own. Do not increase batch size as a remedy for starvation.
