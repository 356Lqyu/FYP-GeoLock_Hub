# Claim audit corrections: focused DEV compatibility review

Target: rcgyuwiidqvrgbxswhqj, via project-scoped read-only MCP.
The shared project was not accessed. Catalog inspection used SELECT only.
No migration, recovery call, reconciliation call or cancellation call was executed.

## Cancellation correction: PASS

File: supabase/migrations/20261025_fix_cancel_claim_audit_columns.sql.

Live contract: cancel_claim(p_claim uuid,p_request uuid) -> jsonb,
owner postgres, SECURITY DEFINER, fixed search_path pg_catalog/public/pg_temp.
EXECUTE is granted to postgres, authenticated and service_role, not anon.
The migration preserves the signature, result, owner, settings and ACL.

DEV audit_events has neither donation_id nor listing_id columns. All 17
explicit audit columns used by the corrected RPC exist with compatible types.
Its SUCCESS/REJECTED audit outcomes satisfy the deployed outcome constraint.
An append-only BEFORE UPDATE/DELETE trigger prevents history mutation; no
INSERT trigger or policy change is needed for the postgres-owned function.

The corrected function body matches deployed source except for:
- Removing donation_id/listing_id from the final audit column list.
- Removing the corresponding positional values.
- Adding donation_id to the existing details JSON, retaining listing_id/task_id.

Request UUID uniqueness, ownership precheck, fingerprint conflict rejection,
request-row lock and cached response replay are unchanged. So are claim ->
lease -> listing -> task locks, safe release, active/unexpired lease checks,
custody/route guards and transaction rollback on failure. No stronger replay
guarantee than the existing RPC's preconditions is introduced.
The existing listing triggers still revalidate/requeue a reopened listing.
No confirmed deployment blocker was found for this cancellation correction.

## Separate recovery/reconciliation column correction: prepared

File: supabase/migrations/20261026_fix_claim_recovery_reconciliation_audit_columns.sql.

Live contracts:
- recover_expired_claims(p_limit integer DEFAULT 100) -> integer; postgres owner;
  SECURITY DEFINER; pg_catalog/public/extensions/pg_temp; postgres/service_role
  EXECUTE only, plus the existing trusted-scheduler guard.
- submit_claim_reconciliation(p_claim uuid,p_handover_confirmed boolean,p_request uuid)
  -> jsonb; postgres owner; SECURITY DEFINER; pg_catalog/public/pg_temp;
  postgres/authenticated/service_role EXECUTE, not anon.

The new migration replaces only those two functions, preserving their metadata
and ACLs via CREATE OR REPLACE. It removes the unsupported columns/values from
one recovery and all three reconciliation audit INSERTs. Both IDs are kept
inside each event's details. Existing task IDs, case IDs, handover evidence,
claim/lease/request/correlation IDs, software/config versions and audit event
subjects remain intact. The real donation_id/listing_id columns on
claim_reconciliation_cases remain untouched.

The deployed function bodies were captured immediately before preparation.
Full-body source-contract comparisons against the matching historical source
allow only these audit substitutions and the approved audit-outcome mapping
described below. No lifecycle, locks, participant checks,
replay behavior, batch member synchronization, safe-release decisions or
reconciliation decisions are changed. No audit columns, tables, policies,
triggers, permissions or historical rows are added or modified.

## Audit-outcome blocker corrected locally

DEV audit_events_outcome_check permits only SUCCESS, REJECTED and ERROR.
The deployed submit_claim_reconciliation forwards v_result->>'outcome' into the
audit column. AWAITING_COUNTERPART and RECONCILIATION_REQUIRED violate that CHECK,
which would cause SQLSTATE 23514 after correcting the missing columns.

The undeployed migration now records SUCCESS for accepted evidence operations,
including waiting/manual-review outcomes. Both early rejection audit INSERTs
remain REJECTED. The exact business result is preserved in details under
reconciliation_status, alongside donation_id, listing_id, case_id and the
handover flag. The RPC return value and cached response remain v_result.
Recovery's existing SUCCESS audit outcome is unchanged.

No case states, claim/lease states, participant checks, locks or UUID behavior
change. Exceptions still abort the transaction; no exception swallowing or
separate audit transaction was introduced. The audit constraint, columns,
history and grants remain unchanged. No additional blocker is known from the
existing DEV catalog review and updated local source checks.

## Local validation and deployment status

- cancel_claim audit contracts: 4 passed.
- New recovery/reconciliation audit contracts: 7 passed.
- Full SQL source-contract suite: 36 passed.
- Audit INSERT column names and value counts checked for all four new statements.
- Existing lifecycle/locking/idempotency body equality checked.
- No workflow_status changes, Flutter changes or routing changes implemented.
- Database compilation and stateful/concurrency execution remain untested.

The passing source tests establish audit-only changes and validate the three
reconciliation audit outcomes as REJECTED, REJECTED and SUCCESS, while preserving
authoritative workflow results and all non-audit function behavior. Both audit
corrections are prepared for manual DEV deployment review as postgres. Neither
has been executed; PostgreSQL runtime and concurrency tests remain outstanding.

