# Asynchronous listing eligibility refresh (review before manual DEV deployment)

Target: isolated DEV rcgyuwiidqvrgbxswhqj only. This change has not been deployed.
Forward migration: supabase/migrations/20261024_async_listing_eligibility_refresh.sql.
Run the separate SELECT-only readiness script before approving deployment.
No readiness SQL was executed as part of implementation, per the instruction not to execute SQL.

## Behavior and scheduling

Donation creation still atomically validates the donor, items, total weight and staged
photos; creates the donation/listing; attaches image metadata; and writes the audit.
The 10 kg threshold and routing algorithms are unchanged. Donation and listing
road nodes remain server-derived, with the listing guard explicitly enforcing the
approved snapshot and 500 m limit. The listing INSERT-only road assignment trigger
is replaced by that guard, avoiding duplicate resolution on the listing itself.

Listing INSERT, coordinate/node changes, and return to AVAILABLE increment a
server-owned eligibility_generation. The AFTER trigger deletes old cache rows
and enqueues the generation within the same transaction. This includes hub-batch
publication through its listing INSERT, and releases/republication. No routing
distance is computed by these triggers. A spoofed node is re-resolved from coordinates.

Manual deployment creates the postgres-owned cron job
geolock-listing-eligibility-refresh, once per minute:
    set statement_timeout = '10min'; select public.process_listing_eligibility_refresh_jobs();
The SET precedes SELECT, so the worker gets its own ten-minute budget instead of
PostgREST's eight seconds. The existing NGO cron job remains separate and unchanged.
One oldest pending/retryable job is handled per run, with at most three attempts.
Failed work rolls back cache writes and retains a FAILED queue row. A session crash
rolls back the whole worker transaction, leaving the prior pending/retry state.
No scheduling command has been executed by this implementation.

## Consistency and locks

The listing worker locks its queue row, the approved coverage row FOR SHARE,
all existing NGO profiles FOR SHARE in UUID order, then its listing FOR UPDATE.
This conflicts with the existing NGO worker's profile FOR UPDATE and with NGO
location writes; it is compatible with claim's NGO FOR SHARE followed by listing
FOR UPDATE. Thus the two workers cannot concurrently publish the same NGO's cache.
The listing generation/node and snapshot must still match before any routing work.
Routing and COMPLETED commit together. A new NGO profile appearing during routing
causes that refresh to roll back and retry with the expanded set of profile locks.
This avoids deleting a valid result from a concurrent NGO onboarding worker.

Listing updates do not update old queue rows: that would invert the worker's
queue-before-listing order and create a deadlock. The worker instead marks obsolete
generations SUPERSEDED when encountered. Snapshot changes fail closed; activating
a different snapshot requires an explicit refresh/requeue operation outside this
migration. Three exhausted attempts also require an operator-reviewed retry/requeue.

A listing generation is visible only after its matching node/snapshot job is COMPLETED.
The NGO readiness guard remains mandatory too. The same listing and NGO guards run
before claim-time geographic checks, including before any on-demand routing fallback.
The existing claim RPC and its locking remain unchanged. Cache readers additionally
match the current configured radius. Historical non-AVAILABLE rows keep generation
zero to preserve existing claim/history/image access; their return to AVAILABLE
always enqueues a new generation.

NGO refresh may write a cache row for a pending or changed listing, but cannot open
its readiness gate. The listing worker subsequently deletes/recomputes that listing's
cache under its profile and listing locks. Location changes atomically remove the
NGO cache and close its independent readiness gate.

## Deployment effects and remaining validation

Existing AVAILABLE listings are invalidated and queued during deployment; they
temporarily disappear from NGO discovery until processed. Bootstrap deliberately
aborts if an AVAILABLE listing lacks its trusted road node. The entire migration
(including bootstrap and cron scheduling) is transactional. Do not rerun it after
a successful deployment; it is a forward-only migration.

The worker holds NGO profile share locks while routing. NGO location/profile writes
and NGO refresh work can wait up to the worker budget. Other donation creation does
not wait for those profile locks. Throughput is one listing job per minute, plus
runtime; monitor the queue if publication volume grows.

Source-contract checks do not establish PostgreSQL compilation or concurrent runtime
behavior. After explicit approval, validate in DEV:
- Create a 12 kg direct donation with photos; verify the API returns within eight
  seconds, metadata commits, and the listing initially has PENDING eligibility.
- Verify donor retries reuse the same request and do not duplicate donations/photos.
- Run scheduled processing; verify directed <=20 km NGOs discover/claim only after
  BOTH readiness guards succeed. Out-of-range/unroutable NGOs remain denied.
- Exercise hub-batch publication, coordinate re-noding, release/republication,
  cancellation, stale snapshots, failed jobs and exhausted retries.
- Concurrently run NGO relocation/NGO refresh with listing processing and re-noding.
  Verify no stale cache becomes discoverable/claimable and no deadlock survives retry.
- Confirm pending/FAILED listings cannot be claimed even with a deliberately stale
  ELIGIBLE cache row; confirm existing claimed/history photo access still works.
- Confirm PUBLIC, anon, authenticated and service_role have no queue/sequence/worker
  access and postgres retains owner access.

These runtime checks require separate authorization and have not been executed.

