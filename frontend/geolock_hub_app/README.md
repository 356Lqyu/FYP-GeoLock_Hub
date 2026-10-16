# GeoLock Hub Flutter app

This Flutter client implements the screenshot-led authentication flow and the role onboarding supported by the supplied Supabase V3 schema. PostgreSQL remains authoritative for role profiles and coordination state.

## Run the app

From this directory, the shared Supabase project URL and publishable key are already
configured in `lib/supabase_config.dart`. Run:

```powershell
flutter pub get
flutter run
```

The publishable key is intended for client applications. Never put a service-role
key, secret key, or database password in this Flutter app. Configure the redirect
URL in Supabase Authentication's allowed redirect URLs.

Android and iOS register the `io.supabase.geolockhub://login-callback` app link. Email confirmation and recovery links return to the app; Supabase Auth establishes the session before profile registration or password update proceeds.

## Implemented

- Welcome, login, role selection, donor/NGO registration, email verification, forgot password, reset password, and password-updated screens.
- Supabase password authentication, generic reset confirmation, resend verification, recovery-session password update, and session-aware role routing.
- Recoverable donor/NGO onboarding. Pending registration form data is stored in Supabase Auth user metadata, then submitted through `register_role_profile` after an authenticated session is available. PostgreSQL role/profile rows remain authoritative.
- Current-profile routing, donor donation creation/history/detail, hub reservation, NGO discovery/claim/pickup/delivery actions, and authorized hub reservation/receipt/batch screens use protected RPCs. These read screens require the additive migration below.
- Reusable one-time foreground location selection for NGO, donor and authorized hub forms. It supports current GPS, address geocoding, map tap/marker drag and explicit location confirmation. GPS permission is requested only when the user chooses the current-location button; no background permission or continuous tracking is requested.
- NGO self-selected coordinates stay blocked from eligibility until trusted verification. A protected role-profile registration waits for the migration capability before calling the existing `register_role_profile` signature.
- A road-node resolver requires an explicitly approved coverage geometry and trusted graph data. No benchmark road nodes are imported. Listings without a validated road node show `PENDING_NODE` and are filtered out of NGO discovery.

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

## Current schema and service limits

- `register_role_profile` accepts DONOR and NGO only. HUB_ADMIN must be provisioned by a trusted backend; the public role picker explains this restriction.
- NGO registration collects a confirmed address and coordinates using the picker. The reviewed migration changes the existing `register_role_profile` implementation to leave the location unverified. A trusted verifier must explicitly approve it before listings become discoverable.
- The SQL has `register_community_hub` for an already provisioned hub administrator, but this registration screen does not create hubs yet.
- The base V3 SQL has RLS and revokes direct table access, but lacks read RPCs for profile, categories, donation history, claims and hub operations. The app uses those functions only after the reviewed additive migration is applied.
- `create_and_validate_donation` uses its actual V3 signature. The app resolves the selected coordinates with `resolve_pickup_road_node`; if approved road coverage or a nearby validated node is missing, creation may still succeed but the direct listing remains explicitly `PENDING_NODE` and cannot appear as claimable.
- Existing `claim_listing(p_listing, p_request)` records `SUCCESS`, `CONFLICT`, or `INELIGIBLE` outcomes transactionally for processed attempts, with a 360-minute database-clock lease. The app persists a request UUID per listing across restarts when the response is uncertain. It does not renew leases.
- Existing `start_pickup(p_claim)` and `complete_pickup(p_claim, p_handover_confirmed)` are used for pickup. The migration adds delivery confirmation, cancellation, safe pre-dispatch release, and trusted reconciliation. Uncertain handover does not automatically reopen a listing.
- Google geocoding returns the device provider's results. No independent NGO verification or road coverage is inferred from that response.
- The contract and schema use a 360-minute claim lease, 20 km straight-line eligibility radius, and fixed 10 kg classification boundary. The frontend does not decide those outcomes.

## Backend setup checklist

1. The V3 SQL is a fresh-install schema, not a migration. Do not re-run it on the shared project.
2. Review `../../supabase/migrations/20261017_stage1_location_and_read_rpcs.sql` before deploying it. It has not been applied to any database.
3. Add active donation categories using an approved administrative workflow; the base schema has no category seed data.
4. Enable intended Auth email confirmation/password settings and allow `io.supabase.geolockhub://login-callback` as an Auth redirect URL.
5. Provision HUB_ADMIN users through trusted backend/service-role operations only.
6. Populate `road_network_nodes` and `road_network_coverage` only from a trusted, licensed, operational road graph. Coverage must be explicitly reviewed and approved. The benchmark's Peninsular Malaysia subset and `OSM-DIRECTED-v3.0-NGO-REGIONS` matrix are experimental fixtures, not production coverage.
7. Deploy a trusted NGO location verification workflow and trusted failure logger. Ordinary users cannot invoke those service-role operations.
8. Schedule the existing `recover_expired_claims(p_limit)` from a trusted worker. Automatic lease renewal is disabled.
9. The shared project URL and publishable key are maintained in `lib/supabase_config.dart`.

## Stage 1 checklist

- [x] Reusable foreground location service and location picker; map location must be confirmed.
- [x] Donor create form uses the V3 creation/validation RPC and has history/detail, item, path, hub reservation, cancellation and audit controls.
- [x] NGO discovery, atomic claim request replay, lease display, pickup start/completion, release and audit controls use protected RPCs.
- [x] Authorized hub registration, reservation receipt, stored inventory and whole-donation batch publication use protected RPCs.
- [x] Proposed additive migration for missing profile/category/history/hub/claim reads, location verification, road coverage validation, cancellation, release, reconciliation, delivery and audit access.
- [ ] Review and deploy the additive migration.
- [ ] Set restricted Google Maps keys for Android and iOS.
- [ ] Provision and approve operational road-network coverage and active categories.
- [ ] Deploy the trusted NGO verification, service-role lease recovery and rollback-failure logging workers.
- [ ] Run integration and concurrency tests against an isolated development Supabase project. No development credentials/project were supplied, and the shared live project was not used as a test database.

The `service_role` key is server-only. Do not add it to Flutter assets, source, build arguments, or distributed configuration.

## Role dashboards and navigation

Authenticated users now receive a five-tab, role-specific navigation shell:

- Donor: Home, Map, Donations, Impact, Profile.
- NGO: Home, Discover, My Claims, Pickups, Profile.
- Hub administrator: Home, Inventory, Receive, Collections, Profile.

Donor statistics, search/filter status mapping, hub capacity, hub/claim reads and
image metadata require the separate reviewed
`../../supabase/migrations/20261017_role_dashboards_and_images.sql` migration.
The screens render explicit loading, retry and backend-unavailable states until
those reads are installed. The migration uses V3 status, receipt, reservation,
inventory and batch records and does not insert dashboard sample data.

Donors can optionally upload a private JPG, PNG or WebP photo (up to 5 MB) when
creating a donation. Authorized hub administrators can attach a photo to their
own batches. The proposed migration stores private object paths and ownership
metadata; the app creates short-lived signed URLs for the owner. NGO photo access
is intentionally blocked until a trusted road graph and server-side image read
path can prove that a listing is eligible. Flutter does not infer claimability.

Before using dashboard data, review and manually deploy the registration
compatibility and donation-state migrations required by the current auth and
donor screens, followed by the role dashboard/image migration. Do not run the
unresolved Stage 1 migration as part of this dashboard setup. Use
`../../supabase/tests/role_dashboards_and_images_readiness.sql` for read-only
schema and permission checks; deployment and live integration testing remain
manual.
