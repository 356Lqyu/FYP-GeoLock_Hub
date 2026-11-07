# Stage 1 claim expiry preparation — not deployed

Target: DEV `rcgyuwiidqvrgbxswhqj` only. Never access the shared project.
Artifact: `../migrations/20261028_claim_card_expiry_and_paused_recovery.sql`.
Do not rerun or edit the deployed 20261027 lifecycle migration.

## Response contract

`public.get_my_claim_cards_v2()` takes no arguments. It retains the v1 columns,
values, ownership filtering, image authorization and descending `claimed_at`
order by delegating to `public.get_my_claim_cards()`. The first 12 fields are:

| Field | PostgreSQL type |
|---|---|
| claim_id, listing_id | uuid |
| claim_status | text |
| claimed_at | timestamptz |
| lease_id | uuid, nullable |
| lease_status | text, nullable |
| lease_expires_at | timestamptz, nullable |
| task_status | text, nullable |
| source_type | text |
| listing_weight_kg | numeric |
| title, primary_image_path | text, nullable |

Additional fields:

| Field | Meaning |
|---|---|
| server_now timestamptz | One `statement_timestamp()` value for all rows in this call. No rows means no server-time envelope. |
| lease_is_expired boolean | `lease_expires_at <= server_now`; NULL when the deadline is unknown. Also true on historical closed leases whose deadlines passed. |
| lease_recovery_pending boolean | True only when both stored statuses are ACTIVE and the deadline has passed; otherwise false. It is not a promise of safe release. |

The RPC changes no persisted statuses and invokes no recovery. It does not
promise action eligibility or supply a new persisted enum. Reconciliation and
terminal stored statuses must take precedence over the deadline flag in a UI.
Missing/inconsistent lease data needs attention; false recovery_pending does
not establish that a claim is actionable. The unmodified v1 RPC remains usable.

Owner: postgres. STABLE, SECURITY DEFINER, fixed
`search_path=pg_catalog,public,pg_temp`. Both v2 and its delegated v1 reader
require an authenticated active NGO and v1 filters by that user's ownership.
Direct v2 execution is granted only to authenticated/service_role and owner;
service_role without an active NGO JWT subject still fails the NGO check.
No table/RLS/storage policies are changed. Unexpected default ACL recipients
abort deployment instead of widening access.

## Worker configuration and safety

Name `geolock-expired-claim-recovery`; schedule `* * * * *`; database is the
deployment session's database; execution username postgres. Command:

```sql
set lock_timeout = '5s';
set statement_timeout = '50s';
select public.recover_expired_claims(100);
```

Deployment creates the job **inactive** in the same transaction as creation.
There is no committed active interval. No worker run or immediate catch-up call
is included. Recovery activation requires a separate approval after review.
No existing eligibility-refresh schedule is changed. An exact paused job can
be reused; duplicate names, different parameters/role/database/active state,
or another directly named recovery command abort the transaction. This is not
a detector for arbitrary indirect wrapper jobs or external schedulers; inspect
those separately. The entire migration is forward-only and is not a replayable
script: an existing v2 identity aborts before creation.

Run as an actual postgres session, not merely SET ROLE from another login.
The existing recovery function checks `session_user='postgres'` or a trusted
service-role JWT. SECURITY DEFINER alone does not satisfy that check. The
worker needs no new function grants: the deployed owner already can execute.
pg_cron must be installed/configured to connect as postgres in this database.
pg_cron runs at most one instance of this job at a time, but other callers of
the recovery RPC are still possible. Existing row locks/SKIP LOCKED handle
claim coordination; the new migration does not alter those rules.

### Existing recovery algorithm review

Based on the deployed definition captured during the preceding read-only
investigation and the deployed lifecycle source; NOT a fresh DEV observation:

- Selects expired ACTIVE claims/leases using database time, bounded 1–1000
  (this worker requests 100), ordered by expiration, locks claims SKIP LOCKED.
- Follows claim → lease → listing → pickup task → lifecycle donation/batch
  locking, rechecks expiration/status, validates the complete donation set.
- Safe direct recovery restores CLAIMED → AVAILABLE; safe hub member recovery
  restores CLAIMED → BATCHED, preserving batch/inventory custody. Listing
  becomes AVAILABLE with a version increment; claim/lease RELEASED with
  EXPIRED_SAFE_RELEASE and task STALE. It does not persist a new EXPIRED state.
- Missing/mismatched state, expired listings, task other than CONFIRMED,
  active assignments or ANY recorded route stops, or pickup/collection
  evidence cause RECONCILIATION_REQUIRED and an OPEN case, preserving custody.
  Even PLANNED tasks are conservative review cases. No automatic reopening
  after pickup starts, ambiguous custody, or invalid batch membership.
- Retains October audit fixes: LEASE_RECOVERY, outcome SUCCESS, entity IDs in
  supported columns/details. Reconciliation and all routing functions remain
  unchanged. No exception swallowing; an error rolls back the entire run.
- Donation/listing updates may enqueue existing asynchronous listing-eligibility
  refresh work. Recovery does not replace that worker or routing algorithms.

### Three existing candidates (previous SELECT-only evidence)

| Claim ID | Lease expiry (UTC) | Previously observed state |
|---|---|---|
| 323ca3b3-7d7f-438e-8ed7-415f61b3a567 | 2026-10-22 00:08:43.922912Z | ACTIVE/ACTIVE; direct CLAIMED; listing CLAIMED; task CONFIRMED |
| aa3cd6d2-e5b3-4369-a41f-ec9a0eaae716 | 2026-10-22 00:31:43Z | Same |
| 9a2ab42b-52c6-4c3a-99fb-b5c95d41e63f | 2026-10-22 01:31:05Z | Same |

All three previously had 360-minute leases, no route assignment/route stop,
and no listing expiration. They were potential safe-release candidates, not
guaranteed recoveries. No claims were recovered and no DEV SQL was executed
in this preparation, per the final prohibition on SQL against DEV. Their
current state is unverified. Recheck full state before activation; only the
existing locked recovery function can make the final atomic decision.

## Manual deployment and verification checklist (future approval required)

1. Recompute and approve the new artifact hash. Reconfirm DEV connection and
   `read_only=true` for the separate review connection. Do not execute this
   migration through that connection.
2. In an approved live read-only review, recapture v1 and recovery definitions,
   owners/ACLs/search paths, lifecycle helpers/constraints, 360-minute config,
   pg_cron version/API/connectivity, all existing scheduler commands, running
   jobs/transactions/locks, and current candidate state. Confirm nothing
   drifted from the reviewed deployed behavior. The SQL below is advisory
   SELECT-only inspection; it was NOT executed during preparation.
3. After explicit deployment approval, execute the COMPLETE new file once as
   postgres in DEV. It installs only v2 and a paused job. Verify commit before
   considering any retry. Investigate errors; never blindly rerun.
4. Read-only verification: v1 unchanged; v2 exact return types/owner/STABLE/
   search_path/ACL; authenticated NGO ownership and photo visibility preserved;
   exactly one paused recovery job with the approved command/role/database;
   no changes to prior schedules, existing function definitions or claim data.
   Compare all 12 original fields under the same NGO/session snapshot.
5. Obtain separate approval to activate the new job. Activation is a database
   mutation and will allow immediate state changes on the next scheduled tick.
   Review the three claims and any additional backlog first. Do not give
   ordinary Flutter clients recovery execution or service credentials.
6. After approved activation, verify cron run details and LEASE_RECOVERY audits,
   claim/lease/task/listing/donation transitions and deferred lifecycle checks,
   cases for uncertain custody, no duplicate recovery audit after a later tick,
   and resulting eligibility-refresh backlog. Pause/escalate on failed runs or
   unexpected outcomes; do not manually rewrite statuses to repair a failure.

Candidate inspection query for a future authorized read-only review:

```sql
SELECT statement_timestamp() AS server_now,
       c.claim_id, c.claim_status, le.lease_status, le.issued_at, le.expires_at,
       le.expires_at <= statement_timestamp() AS lease_is_expired,
       l.listing_id, l.source_type, l.listing_status, l.listing_expires_at,
       d.donation_id, d.donation_status, d.collection_path,
       pt.task_id, pt.task_status,
       EXISTS (SELECT 1 FROM public.active_task_route_assignments a
               WHERE a.task_id=pt.task_id) AS has_active_assignment,
       EXISTS (SELECT 1 FROM public.pickup_route_stops s
               WHERE s.task_id=pt.task_id) AS has_any_route_stop
FROM public.donation_claims c
LEFT JOIN public.claim_leases le USING (claim_id)
LEFT JOIN public.listings l ON l.listing_id=c.listing_id
LEFT JOIN public.donations d ON d.donation_id=l.donation_id
LEFT JOIN public.pickup_tasks pt USING (claim_id)
WHERE c.claim_id IN (
  '323ca3b3-7d7f-438e-8ed7-415f61b3a567'::uuid,
  'aa3cd6d2-e5b3-4369-a41f-ec9a0eaae716'::uuid,
  '9a2ab42b-52c6-4c3a-99fb-b5c95d41e63f'::uuid
);
```

## Tests and limits

Offline: `python -B -m unittest discover -s supabase/tests -p '*contract_test.py'`.
Isolated: `python -B supabase/tests/claim_card_expiry_isolated_test.py --run-isolated`;
optionally pass `--pg-bin` with the installed PostgreSQL binary directory.
The isolated runner accepts no target connection, clears PG* connection
environment, initializes its own temporary cluster, binds loopback on a chosen
port, and stops/removes only that cluster after tests. It never connects to DEV.

Real PostgreSQL tests compile/execute the exact v2 function/ACL blocks, deadline
boundary/null/history semantics, NGO guard and ownership, projection equality,
read-only transaction execution, and the exact cron DO block against explicit
cron doubles, including duplicate/mismatch checks and transaction rollback.
These tests do NOT integrate real pg_cron, deployed Supabase auth/storage/RLS,
the entire migration preflight, production v1 internals, or the recovery
algorithm. Full production compilation/recovery is not claimed.

Preparation results: 66 offline source-contract tests PASS; 9 isolated tests
PASS on PostgreSQL 17.11. Initial local startup attempts were blocked by the
Windows sandbox and then by inherited process pipe handles; the runner now
uses file-backed process output and cleans up its disposable cluster. No DEV
SQL was executed. New-file whitespace checks and `git diff --check` PASS.
The deployed lifecycle artifact's SHA-256 remains
`A3A06DF1CF551F6F8A92B03D85167EFA0828C8F1ABDD47E309D4F01D2CBFBF63`.

Remaining risks: concurrent pickup/cancel/claim/reconcile/recovery, conservative
review of route-linked tasks, batch/custody edge cases, full-run rollback if one
claim errors, backlog exceeding 100/run, worker timeouts, scheduler connectivity,
and asynchronous eligibility refresh after restored availability. Stateful
direct/hub/route/concurrency tests belong in an approved disposable integration
environment before worker activation; never run the existing stateful DEV test
harness just to validate this preparation. Flutter still uses v1/stored statuses
until a separate approved stage changes its read/display behavior.
