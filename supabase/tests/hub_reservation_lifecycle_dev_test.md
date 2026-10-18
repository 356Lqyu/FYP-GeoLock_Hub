# Hub reservation lifecycle development test

## Lock-order review from deployed inventory

The inventory snapshot shows the deployed `confirm_hub_receipt()` originally
locked the hub and reservation before checking/updating donation state, while
the original `publish_whole_donation_batch()` locked the hub before donation
and inventory rows. Those paths conflict once receipt/cancellation/reassignment
serialize on the donation first. The prepared migration changes receipt and
batch publication to the consistent operational order:

`donation row(s), sorted by UUID → hub row(s), sorted by UUID → reservation → inventory → batch/member rows`

Cancellation retains the existing request-row → direct listing → donation
prefix (matching direct claim serialization); for hub reservations it then
locks hub → reservation. No reservation/receipt/inventory writer takes a
cancellation request row or direct listing lock in reverse order. The donor
donation row is locked before reading the old reservation association in the
reassignment path, so all supported reassignment/receipt/cancellation writers
serialize before that association is acted on.

The deployed `complete_pickup()` locks claim/lease/listing before donation and
then changes inventory/custody, but it does not lock hub reservations or hub
capacity. It operates on a published/claimed batch after receipt and batch
publication are committed; it cannot validly overlap an assigned reservation
transition for the same donation. The deployed `start_pickup()` and claim
recovery functions do not write hub reservations or receipts. The deployed
donation-transition trigger is a row-local BEFORE UPDATE trigger; the batch
immutability trigger locks the newly published batch row when members are
inserted. The preflight emits their actual deployed definitions so changes
from the supplied inventory can be identified before staging.

The replacement `publish_whole_donation_batch(p_hub uuid,p_donation_ids uuid[])`
was compared with the deployed inventory body. It retains authenticated hub
ownership and active-hub checks, configured minimum/maximum donation count,
duplicate-ID rejection, sorted member validation (`AT_HUB` plus `STORED` in
the authorized hub), active-membership rejection, received-weight ceiling,
single-category compatibility, whole-donation membership, inventory and
donation transitions to `BATCHED`, batch publication, `HUB_BATCH` listing
creation from the hub's stored coordinates/node (with default NULL expiry),
and the `PUBLISH_BATCH` audit event/return UUID. The intentional body changes
are explicit authentication rejection and lock order: sorted donation rows,
then the hub, then sorted inventory/member work. This source comparison is not
a PostgreSQL parse or runtime proof.

A historical `RELEASED` hub reservation while the donation is still
`HUB_ASSIGNED` is rejected fail-closed. In the deployed writers represented by
the inventory, `RELEASED` is produced by successful donor cancellation, which
also changes the donation to `CANCELLED`; successful receipt instead consumes
the reservation and changes the donation to `AT_HUB`. Reassignment preserves
old records as `EXPIRED`, then creates a new `ACTIVE` row. Therefore a
`RELEASED` record paired with a currently assigned donation is inconsistent
under the known state machine, even if a later ACTIVE row exists. The migration
does not repair it. A future legitimate release workflow or manual repair
would require an explicit reviewed reconciliation rule before relaxing this
guard.

This lock-order argument assumes operational tables remain non-writable to
ordinary authenticated clients and no additional privileged trigger/job
mutates these rows outside the listed RPCs. Confirm that assumption from the
preflight table ACL, policies, trigger definitions, and full RPC bodies.

This runner performs state-changing RPC calls. Do not point it at the shared
project or production. It now requires both an explicit disposable-project
confirmation and an exact project-reference allowlist; the known shared
reference `mffccmlimmbrgasgfnnq` remains blocked as a second guard. The project
URL must be canonical `<project-ref>.supabase.co` form.

## Safe execution boundary

Run only against an isolated, disposable development project whose schema and
functions match the preflight. Set:

```powershell
$env:GEOLOCK_DEV_ISOLATED_CONFIRMATION = 'I_CONFIRM_DISPOSABLE_DEV_PROJECT'
$env:GEOLOCK_DEV_ALLOWED_PROJECT_REFS = 'your-disposable-project-ref'
```

The allowed reference is an explicit allowlist, not a substitute for checking
the URL and project in the Supabase dashboard. Keep all credentials in the
environment; never commit them. Required credentials are the development URL,
publishable key, disposable project's service-role key, donor JWT, hub-admin
JWT, and NGO JWT. The service-role credential is used only by this local test
runner to inspect committed fixture state and must never enter Flutter.

## Test fixture matrix

Provision separate synthetic records for each destructive case. Do not reuse a
fixture after the runner mutates it. Ensure no real donor data is present.

- Expired reassignment: donor-owned HUB_ASSIGNED donation, latest reservation
  expired by database time, only EXPIRED/expired ACTIVE history, no custody,
  and a compatible hub with capacity.
- Cancellation versus receipt: HUB_ASSIGNED donation with active unexpired
  reservation and authorized receiving hub admin.
- Near-capacity concurrency: two VALIDATED HUB_COLLECTION donations and a hub
  with capacity for exactly one additional reservation.
- Cancellation versus reassignment: separate expired HUB_ASSIGNED donation and
  eligible reassignment hub.
- Direct cancellation versus claim: READY_FOR_PICKUP direct donation and
  AVAILABLE listing, plus an active/verified NGO whose location and routing
  eligibility satisfy the deployed claim RPC.
- Expired receipt: expired reservation with no receipt.
- Fail-closed history: HUB_ASSIGNED donation with no reservation and a separate
  HUB_ASSIGNED donation with a RELEASED reservation (include a second ACTIVE
  row in one fixture to prove that a later valid reservation does not mask the
  inconsistent released history), and one with an EXPIRED status but a future
  expiry timestamp. All have no custody.
- Idempotency concurrency: separate cancellable donations for same-request and
  distinct-request races. Also provide an already-CANCELLED donation and a
  second donor-owned donation to test established replay/key-binding behavior.

Each fixture must have its own UUID values and be disposable. Fixture setup is
outside this runner and should be performed only in the isolated development
project. The runner does not create or repair database records.

## Required variables

In addition to the safety confirmation, allowlist, URL and credentials:

- `GEOLOCK_DEV_EXPIRED_DONATION_ID`, `GEOLOCK_DEV_REASSIGN_HUB_ID`
- `GEOLOCK_DEV_RACE_DONATION_ID`, `GEOLOCK_DEV_RACE_RESERVATION_ID`,
  `GEOLOCK_DEV_RACE_RECEIVED_WEIGHT_KG`
- `GEOLOCK_DEV_ALREADY_CANCELLED_DONATION_ID`,
  `GEOLOCK_DEV_SECOND_OWNED_DONATION_ID`
- `GEOLOCK_DEV_CAPACITY_HUB_ID`, `GEOLOCK_DEV_CAPACITY_DONATION_A_ID`,
  `GEOLOCK_DEV_CAPACITY_DONATION_B_ID`
- `GEOLOCK_DEV_CANCEL_REASSIGN_DONATION_ID`,
  `GEOLOCK_DEV_CANCEL_REASSIGN_HUB_ID`
- `GEOLOCK_DEV_DIRECT_RACE_DONATION_ID`, `GEOLOCK_DEV_DIRECT_RACE_LISTING_ID`,
  `GEOLOCK_DEV_DIRECT_CLAIM_REQUEST_ID`, `GEOLOCK_DEV_NGO_JWT`
- `GEOLOCK_DEV_EXPIRED_RECEIPT_RESERVATION_ID`,
  `GEOLOCK_DEV_EXPIRED_RECEIPT_WEIGHT_KG`
- `GEOLOCK_DEV_MISSING_HISTORY_DONATION_ID`,
  `GEOLOCK_DEV_RELEASED_HISTORY_DONATION_ID`,
  `GEOLOCK_DEV_FUTURE_EXPIRED_HISTORY_DONATION_ID`
- `GEOLOCK_DEV_SAME_REQUEST_RACE_DONATION_ID`,
  `GEOLOCK_DEV_DISTINCT_REQUEST_RACE_DONATION_ID`
- `GEOLOCK_DEV_BATCH_HUB_ID`, `GEOLOCK_DEV_BATCH_DONATION_IDS` (comma-separated),
  `GEOLOCK_DEV_BATCH_RECEIPT_DONATION_ID`,
  `GEOLOCK_DEV_BATCH_RECEIPT_RESERVATION_ID`,
  `GEOLOCK_DEV_BATCH_RECEIVED_WEIGHT_KG`,
  `GEOLOCK_DEV_BATCH_CAPACITY_DONATION_ID`

## Run order

1. Run `hub_reservation_lifecycle_preflight.sql` read-only and review every
   missing/mismatch result, table ACL, policy, trigger, and function body.
2. Stop for duplicate active reservations, a missing/invalid `ux_active_reservation`,
   or inconsistent existing HUB_ASSIGNED/custody records. No automatic repair is
   part of this migration.
3. Review and manually apply the migration to the isolated disposable project.
4. Run the read-only preflight again.
5. Populate all fixture variables and run:

```powershell
python supabase/tests/hub_reservation_lifecycle_dev_test.py
```

The runner covers expired reassignment/history preservation, near-capacity
reservation concurrency, cancellation-versus-receipt, cancellation-versus-
reassignment, direct cancellation-versus-NGO-claim, missing/released history
rejection, receipt rejection after expiry, same and different request-ID
cancellation races, already-cancelled replay, cross-donation request-ID reuse,
batch publication, and concurrent batch publication versus receipt and hub
capacity reservation. It verifies committed donation, reservation, receipt,
inventory, listing, batch/member, claim/lease, and audit rows, then checks
server-reported capacity and active-reservation uniqueness. The direct claim
contract is the deployed JSON response `{outcome, claim_id, reason_code,
replayed}`: if cancellation wins, `claim_listing()` is expected to return HTTP
200 with `outcome=CONFLICT` and `reason_code=CLAIM_CONFLICT`; if claim wins,
the listing/claim/lease must be committed and cancellation must be rejected.

The runner does not prove NGO claim/lease/recovery/reconciliation internals; it
only checks that the unchanged direct claim competes safely with cancellation.
No results are claimed until a user executes the suite against a disposable
Supabase project. PostgreSQL concurrency behavior still requires this real
integration run.
