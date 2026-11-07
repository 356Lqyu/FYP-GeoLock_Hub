# Reconciliation case reader: separate read-only review

No migration, function change, recovery or business operation is authorized by
this document. This is a proposed minimal source correction, NOT deployed or
database-tested SQL.

## Evidence and qualification

The authenticated NGO call on 29 October 2026 returned SQLSTATE 42702. Direct SQL
under the export profile subsequently returned zero open cases for the existing
route (user-reported at 01:58:36 MYT); a failed RPC never establishes no cases.

The captured 21 October deployed-security-snapshot definition declares RETURNS
TABLE outputs including claim_id and listing_id. Its PL/pgSQL query contains:

```sql
FROM public.claim_reconciliation_cases rc
JOIN public.donation_claims c USING(claim_id)
JOIN public.listings l USING(listing_id)
```

These unqualified USING names conflict with PL/pgSQL output variables. Also,
after the first join both rc and c expose listing_id, so the second USING has an
ambiguous left input independently of the output-variable problem. Merely
changing plpgsql.variable_conflict is therefore not an adequate source fix.

The exact currently deployed definition was selected by the operator's existing
preflight SQL, but its full output has not been supplied for this review. Do not
claim current-definition equality or apply a patch based solely on old capture.

## Minimal proposed replacement for those joins

```sql
FROM public.claim_reconciliation_cases rc
JOIN public.donation_claims c ON c.claim_id = rc.claim_id
JOIN public.listings l ON l.listing_id = rc.listing_id
                     AND l.listing_id = c.listing_id
```

This explicitly binds each case to its claim and their common listing. Keep the
existing qualified SELECT fields, case-status filter, authenticated participant
checks, NGO ownership / donor ownership / hub-admin scope, ordering and return
contract exactly. Preserve postgres ownership, STABLE, SECURITY DEFINER,
search_path and ACL. Do not change protected writes, recovery, leases, route
authority or graph. No global variable-conflict setting or grant is needed.

Before any separately approved deployment: compare the exact live definition,
owner/config/ACL and normalized body fingerprint; prepare a forward migration
with an exact-old-definition guard. Test READ ONLY calls with empty/matching
cases, repeated calls, unauthorized callers and cross-NGO/donor/hub ownership,
including claim/case listing mismatches. Verify returned rows and exact unchanged
grants. This review has not run those regression tests or prepared an executable
migration. Do not describe the proposal as deployment-ready.

The reader bug does not change Start Pickup's implementation or its feasibility
rules. Direct scoped SQL can independently establish case state while this
separate correction is reviewed; no fix or bypass is required merely to read
the case table with the approved export profile.
