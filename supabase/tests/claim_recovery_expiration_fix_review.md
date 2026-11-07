# Stage 3A preparation: listing-expiration race fix

DEV only: `rcgyuwiidqvrgbxswhqj`. No deployment, recovery execution or cron
changes are authorized by this preparation. Keep job 3 inactive.

Artifact: `../migrations/20261029_fix_claim_recovery_listing_expiration_race.sql`.
SHA-256: `064B1E4CD5B5CD38E1F77B91364AF5ED99221926455D5D64AE7A4B70C1C31E7D`.

## Confirmed defect and minimal fix

The exact deployed recovery source was inspected through SELECT-only MCP with
`transaction_read_only=on`. Its normalized source matches the existing local
20261027 migration: MD5 `be8361aeb5989fa694c6760a48d4c3f3`.

Previously, listing expiry was assessed before the lifecycle helper acquired
the donation/batch/inventory locks. If the listing expired during that wait,
the function could mark claim/lease RELEASED and task STALE, skip the guarded
listing/donation restoration, then insert a SUCCESS recovery audit. Donation
commit validation was not triggered by the skipped donation update.

The new migration makes only two recovery-body changes:

1. Move the existing listing-expiry decision immediately after the existing
   lifecycle lock helper, before any claim/lease/task state changes. A listing
   already expired at this point follows the unchanged reconciliation branch.
2. Add ELSE + RAISE EXCEPTION `RECOVERY_LISTING_REOPEN_PRECONDITION_CHANGED`
   to the existing final restoration guard. If the deadline crosses after the
   decision but before this guard, the complete recovery call rolls back.
   It cannot commit the partial release or a misleading SUCCESS audit.

The final wall-clock expiry guard is retained rather than being replaced by an
unconditional reopening. Expiry is checked at the post-lock decision and final
reopen guard; this is not a promise that a finite deadline stays future through
transaction commit. A deadline can naturally elapse after a valid reopening;
existing discovery/claim expiry checks remain authoritative.

There is no routing, lease-duration, reconciliation algorithm, return-value,
batch-processing or audit-payload redesign. Normal direct releases restore
AVAILABLE; whole hub releases restore all member donations to BATCHED while
retaining published batch/BATCHED inventory custody. Existing route, task and
pickup-progress checks remain byte-for-byte unchanged.

## Security and deployment guards

Signature remains `public.recover_expired_claims(p_limit integer DEFAULT 100)`
returning integer. The existing postgres owner, SECURITY DEFINER, fixed
`search_path=pg_catalog,public,extensions,pg_temp`, and postgres/service_role
EXECUTE grants are preserved. The trusted-scheduler guard is unchanged.

CREATE OR REPLACE preserves the function identity, owner and ACL. No GRANT,
REVOKE, DROP or ALTER FUNCTION OWNER is issued, and no temporary ACL table is
used. Preflight rejects unexpected source/header/ACL drift instead of replacing
teammate changes; postflight checks the replacement source/security. The MD5
values serve as drift checks, not cryptographic provenance. The artifact's
SHA-256 identifies the reviewed file. The entire migration is transactional.

The migration does not invoke recovery, modify business rows/configuration, or
read/write cron tables. It must not be blindly replayed: the old-source guard
rejects an already patched function.

## Tests and actual PostgreSQL execution

Commands used:

```text
python -B -m unittest discover -s supabase/tests -p '*contract_test.py'
python -B supabase/tests/claim_recovery_expiration_isolated_test.py --run-isolated --pg-bin "C:/Program Files/PostgreSQL/17/bin"
```

- 71 offline source contracts PASS, including exact minimal-diff comparison,
  unchanged header/audit tail, preserved locks/guards and drift fingerprints.
- 17 isolated PostgreSQL 17 tests PASS. They execute the COMPLETE new migration
  including its pre/postflight guards and COMMIT, plus the actual patched
  recovery body. The disposable cluster binds loopback on a chosen port,
  accepts no target URL/DSN, clears PG* connection settings and is stopped and
  removed after execution. No DEV SQL other than SELECT inspection was run.
- The original function reproduced the precise defect under an actual row-lock
  wait and committed RELEASED/RELEASED + STALE with CLAIMED listing/donation
  and a recovery audit. This reproduction occurred only in the disposable DB.
- The patched function passed expiration while waiting for direct-donation and
  hub-batch locks, already-expired listings, valid and NULL deadlines, direct
  and three-member whole-batch release, route assignments/stops, PLANNED and
  DISPATCHED tasks, uncertain inventory, existing MANUAL_REVIEW cases,
  idempotency, bounded/SKIP LOCKED processing, ACL/source drift checks and audit
  payload consistency.
- An isolated AFTER UPDATE lease trigger intentionally delayed processing
  after the decision. Late expiry then raised the new exception and rolled
  back all state and audits.
- Injected audit failure on candidate two, actual lock timeout and actual
  statement timeout all rolled back the complete recovery call, including
  earlier candidate changes.

Actual dependencies used, confirmed against deployed normalized source:

- geolock_lock_listing_donations
- geolock_transition_listing_donations
- geolock_assert_donation_lifecycle
- geolock_validate_donation_at_commit
- enforce_donation_transition
- enforce_listing_transition

The listing transition guard is extracted from the existing root schema;
the others come from the unchanged deployed lifecycle migration source.

### Explicit test limitations

The fixture uses reduced tables/constraints, auth.uid/auth.role stubs, minimal
route evidence tables, and artificial delay/failure triggers. Auth/JWT behavior,
complete production RLS/FKs, photo/storage rules, published-membership guards,
real route assignment writers, pg_cron execution, road-node re-resolution and
asynchronous eligibility triggers/workers are not integrated in these tests.
No recovery helper or recovery decision algorithm is mocked. Production
deferred donation lifecycle validation and donation/listing transition guards
do execute in the isolated tests. Broad production concurrency is not proven.

## Batch failure behavior remains unchanged

There are no per-candidate exception handlers or savepoints. A failing candidate
still rolls back the entire invocation. This includes the new late-expiry
exception; on a later retry an expired listing normally follows reconciliation.
Persistent routing/constraint/audit errors can repeatedly block progress.
This patch deliberately does not redesign worker error isolation or scheduling.

## Required manual DEV review and deployment steps

1. Before any deployment approval, recheck the new SHA-256 and recapture the
   deployed recovery body/owner/header/grants. Require the reviewed old source
   or investigate drift; never remove the source guard to force deployment.
2. Confirm job 3 is still inactive, has no running invocation, and jobs 1/2 are
   unchanged. Inspect active recovery calls, transactions/locks and the current
   candidate set. Coordinate any manual/service-role recovery callers.
3. After separate approval, execute the complete new migration once as postgres
   in DEV. It replaces only the existing recovery function. Do not run recovery
   or activate scheduling as part of deployment.
4. Read-only post-deployment verification: new normalized source MD5
   `50110ff20115c4e5d46380e8e3f8b94c`, signature/default/return type, owner,
   SECURITY DEFINER/search_path and original EXECUTE ACL. Compare all unrelated
   function definitions, cron configuration and business-state/audit counts
   with their snapshots. No candidate should have changed from this deployment.
5. Obtain separate approval for a bounded one-claim recovery and verify its
   COMMITTED claim/lease/task/listing/donation state and both audit events.
   Inspect refreshed eligibility generations/jobs and Flutter History state.
   A returned count is processed candidates, not proof of safe release.
6. Keep automatic recovery inactive until that verification and a fresh
   activation safety review. Monitor cron failures/backlog and retain the
   existing 5-second lock timeout, 50-second statement timeout and bounded limit
   unless a separately reviewed operational change is needed.

During preparation, DEV still had three overdue ACTIVE/ACTIVE claims, zero
LEASE_RECOVERY audits and zero reconciliation cases. Job 3 was inactive; jobs
1/2 were active. Previously deployed migrations and Flutter/routing code were
not edited. No DEV changes were made.
