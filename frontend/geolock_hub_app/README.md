# GeoLock Hub Flutter app

GeoLock Hub is a Flutter client for the V3 Supabase coordination backend. PostgreSQL remains authoritative for roles, donation state, claims, leases, hub capacity, and custody.

## Run the app

The client is pinned to the DEV project URL. It deliberately refuses to start
against any other URL, including the original shared project. Obtain the DEV
project's publishable key from its Dashboard and create an ignored local file
named `.env.development.json` in this directory:

```json
{
  "GEOLOCK_SUPABASE_PUBLISHABLE_KEY": "sb_publishable_your_dev_key"
}
```

Run:

```powershell
flutter pub get
flutter run --dart-define-from-file=.env.development.json
```

Only a DEV `sb_publishable_` key is accepted. Never put a service-role key, secret
key, or database password in Flutter source, assets, or the local app config.
Configure the redirect URL in DEV Supabase Authentication's allowed redirect
URLs.

Android and iOS register the `io.supabase.geolockhub://login-callback` app link. Email confirmation and recovery links return to the app; Supabase Auth establishes the session before profile registration or password update proceeds.

## Implemented

- Welcome, login, role selection, donor/NGO registration, email verification, forgot password, reset password, and password-updated screens.
- Supabase password authentication, generic reset confirmation, resend verification, recovery-session password update, and session-aware role routing.
- Recoverable donor/NGO onboarding. Pending registration form data is stored in Supabase Auth user metadata, then submitted through `register_role_profile` after an authenticated session is available. PostgreSQL role/profile rows remain authoritative.
- Current-profile routing, donor donation creation/history/detail/cancellation, hub reservation, NGO discovery/claim/pickup/claim cancellation/reconciliation, and authorized hub reservation/receipt/batch screens use protected RPCs. Actual Supabase end-to-end behavior has not been verified from this workspace.
- Reusable one-time foreground location selection for NGO, donor and authorized hub forms. It supports current GPS, address geocoding, map tap/marker drag and explicit location confirmation. GPS permission is requested only when the user chooses the current-location button; no background permission or continuous tracking is requested.
- NGO self-selected coordinates stay blocked from eligibility until trusted verification. A protected role-profile registration waits for the migration capability before calling the existing `register_role_profile` signature.
- A trusted road-node resolver is not confirmed in the deployed V3 capabilities. Direct listings without a validated node cannot be claimed. Do not use synthetic benchmark nodes for live eligibility.

## Google Maps setup

The map view needs a restricted Google Maps API key. Create one with Maps SDK for
Android and Maps SDK for iOS enabled, then restrict it to this app's Android
application ID and iOS bundle ID. Do not use a server/service key.

- Android: keep the existing Flutter SDK entry in `android/local.properties` and
  add `google.maps.apiKey=YOUR_RESTRICTED_KEY`. The Gradle build reads this local,
  ignored file and passes the value to the Android manifest.
- iOS: in the Runner target's Build Settings, define the user setting
  `GOOGLE_MAPS_API_KEY` with the restricted key. `Info.plist` reads that setting.

The `geocoding` package uses the device's native address geocoder. It supports
address lookup and reverse lookup, but does not provide address autocomplete;
the picker therefore uses an explicit Search action. A map key is required for
Google map tiles. Do not enable background location or add a tracking stream.

## DEV backend status and service limits

- `register_role_profile` accepts DONOR and NGO only. HUB_ADMIN must be provisioned by a trusted backend; the public role picker explains this restriction.
- NGO registration collects a confirmed address and coordinates using the picker. The reviewed migration changes the existing `register_role_profile` implementation to leave the location unverified. A trusted verifier must explicitly approve it before listings become discoverable.
- The SQL has `register_community_hub` for an already provisioned hub administrator, but this registration screen does not create hubs yet.
- Per the latest project status supplied by the developer, V3, October 18 hub reservation changes, and October 19 claim recovery/reconciliation changes are installed in DEV. This has not been independently checked against a live project in this work.
- `create_donation_with_images` calls the existing V3 creation/validation transaction with 1–3 staged images. The Flutter client does not invent a road node; direct claims remain blocked until trusted routing is configured.
- Existing `claim_listing(p_listing, p_request)` is the server authority for claim outcomes and the 360-minute database-clock lease. The app persists a request UUID per listing across restarts when the response is uncertain. It does not renew leases.
- Existing `start_pickup(p_claim)` and `complete_pickup(p_claim, p_handover_confirmed)` are used for pickup. The migration adds delivery confirmation, cancellation, safe pre-dispatch release, and trusted reconciliation. Uncertain handover does not automatically reopen a listing.
- Google geocoding returns the device provider's results. No independent NGO verification or road coverage is inferred from that response.
- The project rules use a 360-minute NGO claim lease, 120-minute hub reservation, 20 km straight-line eligibility radius, and 10 kg classification boundary. The frontend does not decide those outcomes.

## Remaining DEV setup

1. Keep all functional testing on DEV. Never point this client or its fixture setup at `mffccmlimmbrgasgfnnq`.
2. Confirm the DEV Auth redirect URL `io.supabase.geolockhub://login-callback` is allowed.
3. Provision HUB_ADMIN users through trusted backend/service-role operations only.
4. Confirm whether automatic scheduling of `recover_expired_claims(p_limit)` has been configured in DEV. An installed recovery RPC alone does not run automatically.
5. Do not enable NGO claim actions for `PENDING_NODE` or `UNVERIFIED` listings. A trusted, approved road graph and NGO verification flow remain prerequisites for claim eligibility.

## Stage 1 checklist

- [x] Reusable foreground location service and location picker; map location must be confirmed.
- [x] Donor create form uses the V3 creation/validation RPC and has history/detail, item, path, hub reservation, cancellation and audit controls.
- [x] NGO discovery, atomic claim request replay, lease display, pickup start/completion, release and audit controls use protected RPCs.
- [x] Authorized hub registration, reservation receipt, stored inventory and whole-donation batch publication use protected RPCs.
- [x] Stage 1 claim cancellation, expiry recovery, reconciliation and authorized audit code is present in the local October 19 migration and reported installed in DEV.
- [ ] Run the corrected local fixture setup and critical Stage 1 integration tests in DEV.
- [ ] Confirm automatic lease recovery scheduling in DEV.
- [ ] Apply the separate `20261019_retire_delivered_state.sql` manually only after a DEV read-only check confirms no `DELIVERED` donation rows and the migration is reviewed.
- [ ] Set restricted Google Maps keys for Android and iOS.
- [ ] Provision and approve operational road-network coverage and trusted NGO location verification.

The `service_role` key is server-only. Do not add it to Flutter assets, source, build arguments, or distributed configuration.

## Role dashboards and navigation

Authenticated users now receive a five-tab, role-specific navigation shell:

- Donor: Home, Map, Donations, Impact, Profile.
- NGO: Home, Discover, My Claims, Pickups, Profile.
- Hub administrator: Home, Inventory, Receive, Collections, Profile.

Donor statistics, status filters, hub capacity, claim history and image cards
use role-scoped V3 read RPCs. They still require integration testing against the
current DEV deployment.

Donors select 1–3 private JPG, PNG or WebP photos (up to 5 MB each) when creating
a donation. The first photo is the cover; users can remove/replace photos and
promote another photo to cover. Authorized hub administrators can attach one
optional photo of their own physical batch. Constituent donation photos remain
separate; a first-constituent cover is only a visual fallback and does not prove
the batch was assembled. Private object paths and ordered metadata are stored
separately from donation rows. The app displays short-lived signed URLs and
uses secure read RPCs for donor, geographically eligible NGO, claimant, and
responsible hub-admin access. Flutter does not infer claimability.

Before using dashboard data, review and manually deploy the registration
compatibility and donation-state migrations required by the current auth and
donor screens, followed by the role dashboard/image migration. Do not run the
unresolved Stage 1 migration as part of this dashboard setup. Use
`../../supabase/tests/role_dashboards_and_images_readiness.sql` for read-only
schema and permission checks; deployment and live integration testing remain
manual.

## Donation availability and photo rollout

The donor form no longer asks for availability start/end. It keeps a required
title (80 characters maximum), an optional description (1,000 maximum), and
structured item records as the authoritative source for category, quantity, and
weight. No donor availability date is sent to the creation RPC.

New photo uploads use a request-scoped private staging path. The
`create_donation_with_images` RPC validates staged objects, invokes the existing
V3 donation creation RPC with NULL legacy date parameters, and inserts ordered
image metadata in the same database transaction. The request ID makes uncertain
responses safe to retry. If a transaction fails, uploaded files remain
unattached staging objects; cleanup must use the Supabase Storage API, not direct
deletion from `storage.objects`.

Review the migration
`../../supabase/migrations/20261018_donation_photo_and_availability_transition.sql`
after the dashboard/image migration. It preserves existing RPC signatures and
historical date columns, removes donor-date filtering from the installed
discovery/claim function bodies while preserving their other logic, and stops
copying a donor end date into new direct-listing expiry. Existing
`listing_expires_at` values are preserved so an expired historical listing is
not accidentally revived. It does not change the 360-minute lease, claim
idempotency, hub capacity, or routing safeguards.

Until a trusted operational road graph and node validation are configured, NGO
listing image paths are withheld from unclaimed discovery results. Claim-holder
image access remains subject to the server lease/custody checks. This keeps
unverified routes from being presented as fully eligible; NGO discovery cards
may show the neutral image placeholder in this state.

Required-photo enforcement is staged to avoid interrupting old clients:

1. Review and manually apply the dashboard/image migration, then the
   availability/photo transition migration in a development Supabase project.
2. Update and distribute the Flutter client using `create_donation_with_images`.
3. After verifying the new client and legacy image compatibility, apply
   `../../supabase/migrations/20261018_enforce_required_donation_photos.sql`.
   This deferred database trigger requires at least one photo for each newly
   inserted donation; existing donations are not changed. Legacy creation RPC
   signatures remain, but a zero-photo insert fails after this enforcement step,
   so do not apply step 3 while old clients remain active.

Availability columns are not dropped in these migrations. The proposed
donation-state and unresolved Stage 1 migrations still contain legacy reads, so
column removal needs a later dependency scan and coordinated cleanup. Use
`../../supabase/tests/donation_photo_availability_readiness.sql` for read-only
schema, function, permission, RLS, private-bucket, ordering, and trigger checks.
No migrations or live database changes have been executed by this work.
