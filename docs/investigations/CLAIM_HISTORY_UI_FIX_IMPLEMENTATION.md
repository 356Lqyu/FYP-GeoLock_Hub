# Claim History UI and Released NGO Claim Detail Fix — Implementation Report

## Scope and safety

This report covers local Flutter and forward-only SQL changes for the DEV-verified donor reconciliation display issue and released NGO claim-history access issue. No migration was applied to Supabase DEV or production, no DEV records were changed, and no worker or formal experiment was run. The three original investigation reports were not modified.

## Confirmed DEV findings

The read-only inspection used the configured GeoLock Hub DEV project (`rcgyuwiidqvrgbxswhqj`). The identity probe ran in an explicit `BEGIN READ ONLY` transaction and confirmed database user/session user `postgres`, PostgreSQL 17.11, and `transaction_read_only = on`; the transaction ended with `ROLLBACK`. Other inspection statements were SELECT-only. No secrets or unrelated personal data are included here.

- Claims permit `ACTIVE`, `RELEASED`, `EXPIRED`, `COMPLETED`, `CANCELLED`, and `RECONCILIATION_REQUIRED`; leases separately permit `ACTIVE`, `EXPIRED`, `RELEASED`, `COMPLETED`, and `RECONCILIATION_REQUIRED`.
- `recover_expired_claims(integer)` selects active claims with an expired active lease. The observed safe path changes claim and lease to `RELEASED`; uncertainty changes both to `RECONCILIATION_REQUIRED`. `EXPIRED` is a valid historical claim state, but elapsed lease time is normally a lease condition, not a claim-state transition. The inspected DEV aggregate had 3 `COMPLETED`, 4 `RECONCILIATION_REQUIRED`, and 32 `RELEASED` claim/lease pairs; there were no explicit `EXPIRED` claims in that aggregate.
- `get_my_claim_cards_v2()` returns claim history. `get_claimed_listing_detail(uuid)` checks authenticated NGO ownership but returned direct pickup details for owned historical claims. `get_claimed_listing_constituents(uuid)` excluded released/expired claims, causing the Claim Details page to fail despite the history card being visible.
- `get_my_authorized_route_pre_deferral(uuid)` also returned direct donor location data in route stops without checking that the claim and lease remained active. This is relevant because previously loaded route data could outlive the claim lease in Flutter.
- Direct donations store private pickup address/coordinates on the listing/donation path; hub locations come from the community hub and are public operational locations. Published donation item contents are guarded against modification, and published hub membership is immutable.

## Changes made

### Donor reconciliation UI

`DonationDetailPage` and `DonorPickupOutcomeNotice` now identify the latest relevant outcome using authoritative timestamps/state, present it prominently, and put previous claims in a collapsed history section. Entries are deduplicated/grouped by claim UUID. Null evidence renders as **No statement recorded**, explicit `false` as **Not Collected**, and explicit `true` as **Collected**. `NO_OPEN_RECONCILIATION` is presented in plain language where appropriate, while unresolved reconciliation and contradictory evidence continue to show warnings.

### Released NGO claim history

The Claim Details view first verifies the card belongs to the signed-in NGO. It loads full historical detail through a new read-only RPC only for terminal/released/expired claims or an active claim whose lease has expired. Historical views show available items, category labels, claim/lease/pickup/reconciliation history, and no claim/pickup/route/reconciliation mutation actions. If the migration is not deployed, the app shows only verified claim-card facts and an explicit temporary unavailable message; it does not claim the full history loaded. PostgREST details are mapped to safe user-facing errors.

An active valid claim continues through the existing detail and constituent readers. Reconciliation-required claims preserve their existing protected actions. Direct donor location is hidden in historical detail. Hub location remains available as community location.

The NGO routes view also redacts direct donor stop address/coordinates and start/complete affordances when the verified claim card is not currently active with a valid lease. A timer based on server time and lease expiry removes stale direct location display while the page remains open; background resume reloads the route. The database remains the authorization authority.

### Forward-only SQL migration

`supabase/migrations/20261104_released_claim_history_readers.sql` contains:

- `CREATE OR REPLACE` definitions retaining the existing contracts of `get_claimed_listing_detail(uuid)` and `get_claimed_listing_constituents(uuid)`, with ownership checks and fixed SECURITY DEFINER search paths preserved.
- Redaction of direct donor pickup location for non-active/expired claims and leases.
- A new `get_my_historical_claim_detail(uuid)` read-only RPC, restricted to authenticated callers and active NGO ownership. It returns terminal claim evidence, available constituents and item/category details without adding mutation authority.
- A replacement of the existing pre-deferral route reader that masks direct donor locations and route start/complete flags unless the owned claim/listing/lease are still active and valid.
- No changes to claim state, lease state, lifecycle RPCs, authorization workflows, RLS, or existing grants on the old readers. Only the new historical RPC receives explicit authenticated-only EXECUTE permission; it is not granted to `PUBLIC`, `anon`, or `service_role`.

The migration reads current category labels rather than snapshotting them. The published item facts and hub membership are protected as immutable by existing triggers, but category names may reflect current category metadata. Direct donation weight comes from the immutable listing weight; hub batch weight is calculated from its immutable published item membership and weights.

## Files changed for this implementation

- `frontend/geolock_hub_app/lib/donation_pages.dart`
- `frontend/geolock_hub_app/lib/routing/ngo_routes_page.dart`
- `frontend/geolock_hub_app/test/claim_history_ui_test.dart`
- `frontend/geolock_hub_app/test/route_details_presentation_test.dart`
- `supabase/migrations/20261104_released_claim_history_readers.sql`
- `supabase/tests/released_claim_history_migration_test.py`
- `supabase/tests/released_claim_history_isolated_test.py`
- `docs/investigations/CLAIM_HISTORY_UI_FIX_IMPLEMENTATION.md`

The related helper/model files and pre-existing donor status refresh tests are used but were not changed in this implementation.

## Verification

- Flutter analysis: `No issues found!`.
- Focused Flutter suite: **56 tests passed** across `claim_history_ui_test.dart`, `donor_claim_history_test.dart`, `donor_status_refresh_test.dart`, `donor_route_resolution_test.dart`, `route_details_presentation_test.dart`, and `route_execution_widget_test.dart`.
- SQL source and isolated PostgreSQL tests: **14 tests passed** (6 source-contract checks and 8 live integration tests against a test-owned disposable PostgreSQL 17 cluster). The tests exercised ownership, unauthenticated/foreign claims, released and expired history, active lease gates, direct-location redaction, hub location visibility, constituent/category data, ACLs, route stop masking, and unchanged lifecycle rows. The temporary test cluster was stopped and cleaned by the test harness.
- `git diff --check` passed for tracked changes. A direct trailing-whitespace check also passed for the new migration, tests, and report (which remain untracked until staged).
- No production/DEV migration or live Supabase write was performed. PostgreSQL integration testing is local and does not establish deployed PostgREST cache behavior.

## Deployment sequence — after separate approval only

1. Confirm the intended linked Supabase project is GeoLock Hub DEV and inspect `supabase migration list --linked`. Do not continue if the link is not DEV.
2. Confirm the only pending migration is `20261104_released_claim_history_readers.sql`. `supabase db push --linked` applies all pending migrations, so stop if any unrelated migration is pending.
3. After approval, apply with `supabase db push --linked`; this report does not authorize that command to be run.
4. Verify PostgREST has reloaded the schema, then run authenticated checks: own released/expired detail succeeds read-only; foreign and unauthenticated IDs are denied without enumeration; active valid direct claims retain appropriate detail; expired direct claims and route readers omit donor address/coordinates; hub locations remain available; active claim workflows and reconciliation-required behavior remain unchanged.
5. Do not run any state-changing claim or pickup operation as part of verification. Use disposable local integration tests or read-only queries for database state.

No rollback was attempted or prepared as an automatic action. The migration changes functions and adds one RPC without rewriting claim data. If a deployed defect is found, use a forward corrective migration; reverting the pre-migration direct-location behavior would restore the privacy exposure this migration addresses.

## Readiness recommendation

Local implementation and tests are complete. **NO-GO for deployment until explicit approval**, followed by project-link and pending-migration verification. Existing active route/claim workflows remain unchanged by the database lifecycle logic; the local integration tests verify active and historical authorization boundaries. The original DEV findings are not revalidated after deployment because deployment has not occurred.
