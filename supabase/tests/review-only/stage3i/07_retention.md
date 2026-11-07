# Stage 3I retention and cleanup: review only

Default: retain the tagged disposable fixture and every audit/claim/lease/task
record as evidence. Never DELETE historical recovery records, alter their reasons,
reset ACTIVE states, erase photos through raw Storage SQL or rerun old migrations.

After the scheduler result, pause job 3 immediately. Verify quiescence, complete
05_verify.sql (all_checks_pass=true), save all scoped snapshots, run history and
Flutter screenshots before any cleanup action. Store manifests/checksums/timestamps
outside DEV; record the test accounts, title and exact IDs in the evidence bundle.

The recovered donation/listing is AVAILABLE and could otherwise be claimed again.
Keep normal test clients stopped until a separately approved retention decision.
If retiring the fixture is approved, sign in as its actual donor and use the normal
Cancel Donation action backed by cancel_donation(donation_id,request_id), with a new
stable idempotency UUID. This preserves ownership checks, audits, lifecycle and
photo rules, and retires availability while retaining recovery evidence.

Verify afterward with SELECT: only the dedicated donation/listing are CANCELLED,
the test claim/lease remain RELEASED, task STALE, recovery audits remain unchanged,
expected cancellation audit exists, jobs 1/2 are healthy and job 3 stays inactive.
Cancellation is deliberately after recovery verification; all_checks_pass for the
earlier AVAILABLE snapshot is not expected to remain true after intentional cleanup.
Never overwrite that saved successful verification with a later cleanup snapshot.

If another claim, pickup, custody evidence or reconciliation case appears, STOP.
Do not force-cancel/reopen or delete anything; retain evidence and request an
incident-specific protected coordination/reconciliation plan. Failure recovery is
not a generic rollback script. Pausing a scheduler cannot undo committed recovery.

Raw database deletion and automatic cleanup SQL are intentionally omitted. Optional
later test-account/photo purging needs a separately approved privacy/retention plan
that respects foreign keys, Storage security and audit retention.
