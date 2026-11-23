# NEW KLSEL donation reader deployment checklist

Deployment requires separate approval. The target project is `ppwmdsyoesvhgmqiaoxa`.
The SQL file is [20261123210000_donation_information_readers.sql](../supabase/migrations/20261123210000_donation_information_readers.sql).

## Before deployment

- Confirm the target in the Supabase project selector and deployment tool. Use an approved change window.
- Confirm a current database backup and its restore procedure. Save a restricted schema-only export of the legacy reader definitions, return signatures, owners, and ACLs. Preserve the catalog evidence and the current Flutter release identifier.
- Run the read-only catalog preflight again. Compare the four source readers and their road, photo, and claim guards against the reviewed KLSEL definitions. Resolve drift before deployment.
- Confirm the four new names are unused, including alternate overloads. Verify existing item and active membership indexes are valid and review discovery performance in an isolated environment.
- Re-run the [disposable PostgreSQL test](../supabase/tests/donation_information_readers_isolated_test.py) and the Flutter regression tests from the release revision. The disposable test uses synthetic tables and stub road and image helpers.

## Expected RPCs

| Signature | Appended column |
|---|---|
| `public.discover_eligible_listing_cards_v2()` | `listing_total_item_quantity bigint` |
| `public.get_eligible_listing_constituents_v2(p_listing uuid)` | `donation_description text` |
| `public.get_claimed_listing_constituents_v2(p_claim uuid)` | `donation_description text` |
| `public.get_my_donation_dashboard_v3()` | `total_item_quantity bigint` |

Each reader uses `SECURITY DEFINER`, a fixed search path, and the reviewed `postgres` owner. The migration grants API execution to `authenticated` and checks that `anon` and `service_role` cannot execute the functions, including through inherited privileges. The existing APIs and their grants remain available.

## Deployment and smoke tests

1. After separate approval, apply the migration to NEW KLSEL using the approved database deployment process. Verify it committed. The file requests a PostgREST schema-cache reload.
2. Inspect the new signatures, return columns, owner, search path, and effective grants. Compare the legacy definitions and grants to the backup. Use signed-in requests with the listed parameter names to confirm all four RPCs resolve through PostgREST. Verify anonymous requests are denied.
3. With approved test accounts and fixtures, verify donor ownership, eligible and ineligible NGO discovery and detail access, and claim ownership. Exercise an active claim with a valid lease, an expired or inactive lease, an expired listing, an inactive NGO, and completed, reconciliation-required, released, expired, and cancelled claims. Confirm descriptions are visible for eligible details and valid operational claims. Confirm historical views remain description-free and location and image access behave as before.
4. Check direct totals, batch totals with released constituents, missing totals, and unchanged listing and donation dates. Verify a donor donation with two item entries and eight units shows both numbers. Check that each description belongs to its constituent.
5. Release Flutter only after database checks pass. Verify the new fields and refresh behavior on NEW KLSEL with the approved accounts. Existing Flutter clients can continue calling the legacy readers.

## Rollback

- If the migration fails, verify all four new functions are absent. The migration uses one transaction.
- For a Flutter issue, restore the previous Flutter release first. Keep the new functions available until no shipped client depends on them.
- If a new reader exposes unauthorized information, revoke `EXECUTE` from `authenticated` on the affected signature immediately and verify effective denial. Roll back the Flutter release and reload PostgREST if needed.
- After confirming there are no remaining callers or dependencies, remove the four new signatures in a separate approved SQL change. Avoid cascade removal. Verify the old endpoints still resolve through PostgREST.
