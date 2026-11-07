# GeoLock Hub Maps and DEV Integration Audit

**Date:** 21 October 2026  
**Scope:** Read-only inspection of the repository, local schema and migration sources, Flutter RPC usage, FYP report, and revised Coordination Authority Contract.

## Executive summary

**Follow-up update (21 October 2026):** the local `android/local.properties` now contains a non-empty `google.maps.apiKey` property, and Gradle reads it into the Android manifest placeholder. The key value was not printed or copied into this report. This removes the prior source-level missing-key issue in this checkout, but does not prove the key is valid or that maps render. Google Cloud API enablement, billing, key restrictions, Play Services, and runtime failures remain unverified; `adb` is unavailable in this environment.

Only the reusable location picker contains a `GoogleMap`. The Donor “Map” tab is an intentional unavailable-state card, not a map implementation. There are no NGO or Hub Admin map tabs. The FYP report requires road-network location matching and post-claim routing as system mechanisms; I found no requirement for a separate Donor map page.

The repository’s proposed `20261020_operational_road_node_resolution.sql` defines server-side 500 m node resolution and directed road-distance eligibility. Its header says it was prepared for review and **not executed against Supabase**. It defines donor/listing/hub node-assignment triggers, but no trigger on `ngo_profiles`. NGO node matching instead occurs through the trusted `verify_ngo_location()` function and the service-role backfill path. DEV deployment and current trigger definitions remain unverified.

The NGO banner is driven by `geolock_app_capabilities()['road_node_resolution']`. That boolean means an approved operational graph is configured; it does not prove that this NGO’s location is verified or that any particular listing is routable. Claim authorization is separately checked by `claim_listing()` on the server.

No Supabase database connector was available in this session. I did not connect to either project. The DEV inventory below is therefore **blocked pending manual read-only execution** in project `rcgyuwiidqvrgbxswhqj`. Nothing here should be interpreted as a live DEV result.

## Findings

| ID | Severity | Finding | Verification |
|---|---|---|---|
| MAP-01 | RESOLVED LOCALLY | Android Maps key property is now non-empty in the current checkout and Gradle maps it to the manifest placeholder. | VERIFIED in local configuration without displaying the value; runtime unobserved |
| MAP-02 | MEDIUM | The package ID is still `com.example.geolock_hub_app`; Google Android key restrictions must match the actual package and signing certificate(s). | VERIFIED in source; Cloud restrictions unverified |
| MAP-03 | MEDIUM | Donor Map is a placeholder, not a Google map. | VERIFIED in Flutter |
| ROAD-01 | HIGH | No NGO-profile road-node assignment trigger exists in the checked-in road migration. Trusted verification calls the resolver directly. | VERIFIED in repository proposal; DEV unverified |
| ROAD-02 | HIGH | The road-network migration is repository-only and says it was not executed. Flutter calls `preview_location_routing()`, which this migration defines. | VERIFIED in local sources; DEV deployment unverified |
| NGO-01 | MEDIUM | The “Trusted route validation configured” banner reflects graph capability, not the signed-in NGO’s verification state. | VERIFIED in Flutter and local capability definition |
| DB-01 | HIGH | A complete live DEV object inventory cannot be confirmed without executing the read-only queries below in DEV. | BLOCKED; user-provided catalog results are being reviewed incrementally |
| DB-02 | CRITICAL | The effective privilege matrix reports `anon` and `authenticated` with SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, and TRIGGER on the same 29 public tables. RLS does not constrain TRUNCATE and cannot be relied on to constrain trigger creation. | USER-PROVIDED DEV QUERY; catalog grant source still unknown; do not infer row access without policy evaluation |
| SYS-01 | HIGH | End-to-end Flutter/RPC compatibility and atomic-claim behavior have not been verified against the live DEV database in this audit. | UNVERIFIED |

## A. Google Maps diagnosis

### Source configuration

- `frontend/geolock_hub_app/pubspec.yaml` includes `google_maps_flutter`, `geolocator`, and `geocoding`.
- `android/app/src/main/AndroidManifest.xml` declares coarse/fine location permission and the `com.google.android.geo.API_KEY` metadata placeholder.
- `android/app/build.gradle.kts` fills that placeholder from `google.maps.apiKey` in `android/local.properties`; its default is empty. The property is now present and non-empty in the current checkout. Its value was not printed. This only confirms local configuration wiring, not Google Cloud validity.
- Android `applicationId` is `com.example.geolock_hub_app`. The README asks for an Android-restricted key in the ignored local properties file and the matching iOS key in Xcode settings.
- `ios/Runner/Info.plist` contains a `GoogleMapsApiKey` build-setting reference. The inspected `AppDelegate.swift` has no explicit Maps SDK bootstrap call; actual iOS behavior was not runtime-tested.
- The `GoogleMap` is placed inside an `Expanded` child in the location picker, so source layout constraints do not explain a blank map there.
- The map picker uses a fixed Malaysia overview initially. Current-location selection uses a one-time Geolocator request; `myLocationEnabled` is false intentionally. Address search uses the native geocoding package and an explicit Search action; the README correctly says there is no autocomplete.

### Root cause and unverified causes

**Verified source defect:** the current Android build configuration supplies an empty Maps API key unless the developer has configured the ignored `google.maps.apiKey` property. This can make the native map fail to load tiles even though the Flutter widget is present.

**Not verified:** Google Cloud project selection, Maps SDK for Android enablement, billing status, API restrictions, package/SHA-1 restrictions, daily quota, emulator/device Google Play Services, Android runtime errors, and whether the key used by a different teammate’s local checkout is valid. Google requires billing and an API key for Maps SDK for Android requests; Android key restrictions use package name plus signing-certificate fingerprint. See [Google Maps SDK usage and billing](https://developers.google.com/maps/documentation/android-sdk/usage-and-billing) and [Google Maps Platform credential restrictions](https://developers.google.com/maps/faq).

No Android device logs were available in this session (`adb` is unavailable). No runtime map error is claimed. A full rebuild/reinstall is recommended after adding or changing the manifest-injected key so the merged manifest and native configuration are refreshed.

### Map widgets and role destinations

| Role/screen | Purpose and access | Map/data implementation | FYP relationship | Finding |
|---|---|---|---|---|
| Shared Location Picker | Opened from NGO registration, donor donation pickup, and authorized hub registration. | The only `GoogleMap` widget; user can tap/drag a pin, search an address, or use GPS, then confirm. It does not display donation or route data. | Location capture and road-node mapping support the system workflow. | Functional widget source; Android tiles are blocked by missing local key; backend preview depends on an unverified RPC deployment. |
| Donor Map tab | Donor bottom navigation → Map. | `_UnavailableTab` explains a privacy-safe map feed is unavailable; it displays no GoogleMap or donation records. | No standalone Donor map screen requirement was found in the report. | Honest placeholder, but a tab-shaped dead end. Prefer integrating map use into location selection/hub selection or removing/replacing the tab after product approval. Never expose private donor pickup points in a public map. |
| NGO map/routing page | No role-specific Map tab/page found. NGO has Home, Discover, My Claims, Pickups, Profile. | No GoogleMap or route visualization found. | Report requires post-claim route planning over valid confirmed tasks, but does not establish a required in-app map page in the sections reviewed. | Route visualization is absent from Flutter; backend claim eligibility is not itself a route-optimization UI. |
| Hub Admin map page | No map tab/page found. Hub Admin has Home, Inventory, Receive, Collections, Profile. | Hub address selection uses the shared picker; no operational hub map. | Hub location is part of the coordination model, but a separate map screen was not required in the reviewed report. | No duplicate operational map found. |

The FYP describes road-network mapping of donor, hub, NGO, and depot points and post-claim pickup routing. Those are system requirements, not evidence that a dedicated Donor map tab is required. The Coordination Authority Contract keeps road eligibility, claim ownership, and route-planning authority separate.

## B. Road-node matching and eligibility

All findings here describe the checked-in proposal `supabase/migrations/20261020_operational_road_node_resolution.sql`, not the live database.

### Trigger and resolver inventory in the proposed migration

| Trigger | Table | Event/timing | Behavior |
|---|---|---|---|
| `trg_donation_road_node` | `public.donations` | BEFORE INSERT | Calls `geolock_resolve_road_node()` and overwrites `pickup_road_node_id`. It does not fire on location UPDATE. |
| `trg_listing_road_node` | `public.listings` | BEFORE INSERT | Resolves listing pickup coordinates and overwrites `pickup_road_node_id`. It does not fire on UPDATE. |
| `trg_hub_road_node` | `public.community_hubs` | BEFORE INSERT or UPDATE OF latitude, longitude, road_node_id | Resolves hub coordinates and overwrites `road_node_id`. |
| NGO profile | `public.ngo_profiles` | **No assignment trigger defined** | Trusted `verify_ngo_location(uuid,boolean,text)` resolves the NGO coordinates and updates `road_node_id` and `location_verified_at`; service-role/database-owner path only. Backfill also iterates verified NGOs. |

The resolver is SQL `ST_DWithin` over geography, with a 500 metre distance argument from `road_network_coverage.max_snap_distance_m` (the table CHECK pins it to 500), constrained by active approved `OPERATIONAL` snapshot coverage via `ST_Covers`. It orders candidates using the geography KNN `<->` operator and returns the first active node. Its distance output is `ST_Distance` on geography, in metres. These are source-code observations; no actual trigger execution was tested.

If the point is invalid/null or outside coverage, or there is no active node within 500 m, the resolver returns no row. Assignment triggers therefore set the node to NULL rather than fabricating one. Table coordinate CHECK constraints reject out-of-range persisted coordinates where present. The matching query filters active nodes and an approved operational snapshot; the snapshot, not an individual node row, carries `approved_at`.

The migration enables RLS and revokes client table access on its graph tables. Its trigger function is SECURITY DEFINER with a fixed search path and overwrites client-supplied node IDs for the covered tables. NGO self-selected coordinates do not become trusted: the trusted verification RPC must approve them and resolve a node. No NGO trigger means a claim that a trigger automatically matches all user locations is not supported by this repository migration.

### Eligibility and claim enforcement in the proposal

- `geolock_ngo_listing_road_check()` first requires verified NGO coordinates, an active operational graph, and both NGO/listing nodes. It uses straight-line geography distance only as a safe prefilter, then reads or recomputes directed NGO→listing shortest road distance and compares it with configured `geofence_radius_m` (the expected 20 km).
- `geolock_road_costs()` calls `pgr_dijkstraCost()` with directed costs (`reverse_cost = -1`) and the current operational snapshot.
- Discovery RPCs return only listings with non-null eligible road distance and valid source/listing states. `claim_listing()` calls the authoritative eligibility check again inside the protected claim transaction, in addition to role, listing, expiry, and source-state checks.
- Missing/unconnected nodes yield route-unavailable or eligibility-undetermined outcomes and do not become eligible. The claim function does not accept a client-supplied road node.
- `preview_location_routing(double precision,double precision)` is used by Flutter for picker previews. Donor pickup and hub location pickers set road access to required; NGO registration does not require a preview, consistent with trusted verification remaining a separate step.

**Integration risk:** if `20261020_operational_road_node_resolution.sql` is not deployed in DEV, the picker’s `preview_location_routing()` call is absent and the required-road-access confirmation can remain disabled. The migration header explicitly labels itself prepared/not executed, so deployment status must be checked in DEV.

## C. NGO route-validation banner

`NgoHomePage._loadTrustedRouting()` calls `geolock_app_capabilities()` and tests only whether `road_node_resolution == true`. If true, the UI displays “Trusted route validation configured” and “The server remains authoritative for every claim.” The text is source-code-controlled, but the enabling value is backend capability data—not a per-NGO verification result or an eligibility result for a particular listing.

The checked-in `20261017_registration_compatibility.sql` capability function returns true only if the road tables exist and it finds an active node in an approved active operational coverage snapshot. It does not check whether the current NGO is verified or whether a claimable route exists. `claim_listing()` remains the authority and should reject unverified or unroutable cases. The banner’s second sentence is correct about authority; the first can be misread as saying this NGO is already verified. A clearer future message should distinguish “graph configured” from “your location pending trusted verification.” No UI edit was made.

## D. Flutter/Supabase integration snapshot

The repository README itself says Supabase end-to-end behavior has not been verified from this workspace. The table below is a source-level compatibility map only.

| Workflow | Flutter path | Repository backend reference | Status |
|---|---|---|---|
| NGO registration/location | `auth/auth_pages.dart`; `auth/auth_controller.dart` | `register_role_profile`; proposed trusted `verify_ngo_location` | Coordinates selected; client sends no trusted road node. Verification path is server/service-role only. DEV availability unknown. |
| Donor creation/photos | `donation_pages.dart` | `create_donation_with_images` → creation/validation RPC; photo/storage migrations | Atomic RPC workflow exists in source. Road-preview RPC is a dependency of the picker. DEV signatures, Storage policy, and successful transaction were not tested here. |
| Donor history/details/cancel | `donation_pages.dart`, `dashboard_pages.dart` | `get_my_donation_dashboard_v2`, `get_my_donation_detail`, `get_donation_images`, `get_donation_audit`, `cancel_donation` | Calls match local migration declarations at source level; DEV grants/return shapes unknown. Current official state remains `SUBMITTED` per the latest contract and active Flutter mappings. |
| Hub selection/receipt/inventory/batches | `donation_pages.dart`, `dashboard_pages.dart` | `get_eligible_hubs`, `reserve_hub_capacity`, `confirm_hub_receipt`, `get_my_hub_inventory`, `publish_whole_donation_batch`, hub dashboard reads | UI uses protected RPCs. Reservation and physical receipt remain distinct. Route-aware hub eligibility depends on operational graph deployment. DEV not verified. |
| NGO discovery/claim/pickup | `donation_pages.dart`, `dashboard_pages.dart` | `discover_eligible_listing_cards`, `claim_listing`, `get_my_claim_cards`, `start_pickup`, `complete_pickup` | `claim_listing` is re-called by backend; route-aware behavior exists in the proposed road migration. No live concurrent-claim test was run. |
| NGO claim cancellation/reconciliation | `donation_pages.dart` | `cancel_claim`, `get_my_reconciliation_cases`, evidence/reconciliation RPCs | Local Stage 1 migration and UI calls exist. DEV definitions, grants, scheduler, and actual audit records are unknown. |
| Hub admin registration/ops | `donation_pages.dart`, `dashboard_pages.dart` | `register_community_hub`, `get_my_hubs`, receipt/inventory/batch RPCs | Local protected flows exist. No live role or capacity validation was performed. |
| Standalone role map/routes | `dashboard_pages.dart` | No map-feed RPC for Donor; no Flutter route-optimization RPC/UI found | Donor tab is placeholder; NGO route planning/map screen is not integrated. |

### FYP and contract alignment notes

- The FYP report’s Section 3.3.5.1 specifies nearest drivable-node mapping within 500 m for donor, hub, NGO, and depot points; points without a suitable connected node are not routable. It defines road distance from the fixed road map, not latitude/longitude.
- The FYP treats geofence eligibility, atomic claim ownership, hub recommendations, and post-claim route planning as separate decisions. A map or AI recommendation must not grant claim ownership.
- The latest Coordination Authority Contract says `SUBMITTED` remains valid, `COLLECTED` is the terminal physical donation state, and `VALIDATED`/`DELIVERED` are not persisted donation states. This report does not propose a state rename.
- Live migration history cannot be inferred from local filenames. The repository includes baseline schema restores and forward migrations, but no live `supabase_migrations` result was retrieved. The operational road migration is explicitly unexecuted in its header.

## E. DEV inventory status and read-only query pack

### What is known locally

- Local V3 schema restore files: `geolock-v3-public-schema.sql`, `geolock-v3-public-schema-with-grants.sql`, and `geolock-v3-public-schema-dev-restore.sql`.
- Forward migrations under `supabase/migrations/` include registration, dashboards/images, photos, hub lifecycle, claim recovery/reconciliation, permission correction, and a proposed operational road-network migration.
- Local road-network build/import assets and `road_network_preflight.sql` exist.
- These files establish repository intent and expected definitions only. They do not prove which functions, grants, policies, triggers, road data, schedules, or Edge Functions are currently deployed in DEV.

### Live inventory: BLOCKED

No Supabase connection or SQL query was made. The original shared project was not accessed. Run the inventory sections in order in the SQL Editor after visually confirming the project reference is exactly `rcgyuwiidqvrgbxswhqj`. Do not run them in `mffccmlimmbrgasgfnnq`. **Run only section 1 first and send its result before proceeding; subsequent sections are intentionally deferred until that result is reviewed.**

**User-provided query result update (21 October 2026):** the pasted response parses to 100 rows across 11 `auth` relations. It contains no `public` application relations, so it is incomplete for GeoLock compatibility review (likely the first result page or truncated output). The response is schema metadata only; no table data or credential values were used. Request a narrowed `public` relation inventory next. This remains user-provided evidence, not a direct database connection by this audit.

**DEV public relation inventory update (user-provided result, 21 October 2026):** 36 public relations were returned. All are owned by `postgres`, all report RLS enabled, and none report FORCE RLS. The list includes the expected lifecycle tables and road/route relations: `road_network_coverage`, `road_network_nodes`, `road_network_edges`, `ngo_listing_road_eligibility`, `pickup_routes`, `pickup_route_stops`, `active_task_route_assignments`, and `vehicles`. Local V3 restore files define the route/vehicle relations; the operational road migration defines the four road-network relations. This confirms relation presence and RLS flags only. It does **not** prove policy correctness, grants, deployed definitions, migration provenance, graph contents, or that the local migration body matches DEV.

**Core lifecycle column metadata (user-provided result, 21 October 2026):** the nine requested tables returned 98 columns. `donations.donation_status` has default `SUBMITTED`; description, collection path, coordinates, total weight and availability endpoints are nullable; `listings.listing_expires_at` is nullable; `pickup_tasks.pickup_road_node_id` is NOT NULL. `coordination_config` columns have defaults of 20,000 m geofence, 10 kg direct threshold, 360-minute claim lease, 120-minute hub reservation, 3–5 donation batch size and 30 kg batch maximum; these are defaults only, not proof of the actual singleton row values. `audit_events` contains actor/entity/event/request/claim/lease/correlation/state/reason/outcome/details/version/time fields, but column metadata alone cannot establish required audit semantics or durable event behavior. Constraints, indexes, and deployed function logic remain pending.

**Core lifecycle constraints (user-provided result, 21 October 2026):** 64 constraint rows were returned. The donation status CHECK includes `SUBMITTED`, `READY_FOR_PICKUP`, `HUB_ASSIGNED`, `AT_HUB`, `BATCHED`, `PICKUP_IN_PROGRESS`, `COLLECTED`, and `CANCELLED`; it excludes `VALIDATED` and `DELIVERED`. `claim_leases` allows ACTIVE/EXPIRED/RELEASED/COMPLETED/RECONCILIATION_REQUIRED and has a unique `claim_id`; claim requests permit SUCCESS/CONFLICT/INELIGIBLE/ERROR, and claim rows have unique request IDs. Pickup-task ownership is protected by a composite FK to claim/listing/NGO. Audit outcome CHECK permits SUCCESS/REJECTED/ERROR. The required-photo trigger constraint is deferrable and initially deferred. Donation title and description length CHECKs are `NOT VALID`; this does not establish whether existing rows violate them, though PostgreSQL still enforces a NOT VALID CHECK for new or updated rows. These facts do not establish atomic RPC behavior, active-claim partial-index validity, or actual configuration row values. Indexes and function bodies remain pending.

**Lifecycle and road index metadata (user-provided result, 21 October 2026):** 43 index rows were returned, all `is_valid=true` and `is_ready=true`. `ux_active_claim` is a unique btree on `donation_claims(listing_id)` with predicate `claim_status IN ('ACTIVE','RECONCILIATION_REQUIRED')`; this enforces at most one such claim per listing. `ux_active_reservation` similarly enforces one ACTIVE reservation per donation. `ux_active_batch_member` enforces one ACTIVE batch membership per donation. The direct and hub batch listing indexes are unique by source. Road coverage/nodes have GiST indexes, and `road_network_one_active_operational` enforces one active operational snapshot. The active lease expiry index is non-unique. These definitions closely match checked-in V3/proposed road migration index definitions, but no data-level check or function behavior is implied; deployed index definitions remain user-provided metadata.

**Location and lifecycle trigger metadata (user-provided result, 21 October 2026):** eight enabled triggers were returned for the inspected tables. `trg_donation_road_node` and `trg_listing_road_node` are BEFORE INSERT only; `trg_hub_road_node` is BEFORE INSERT or UPDATE OF latitude/longitude/road_node_id. No NGO-profile road-node trigger appeared in the returned set. The attached `geolock_assign_road_node()` is SECURITY DEFINER with fixed `public, extensions, pg_temp` search path and delegates resolution to `geolock_resolve_road_node()`; the resolver body is still pending. `trg_vehicle_depot_node` copies the verified NGO profile node into the vehicle. Donation and listing lifecycle triggers are enabled; the donation trigger permits the submitted/direct and submitted/hub transitions in the returned body. The required-photo constraint trigger is AFTER INSERT, DEFERRABLE INITIALLY DEFERRED. Listing eligibility refresh is AFTER INSERT or pickup-node UPDATE and catches exceptions as warnings; whether discovery and claim independently fail closed must be verified in their deployed definitions. Trigger metadata does not prove trusted execution outcomes or grants.

**Road resolver and trusted verification functions (user-provided definitions, 21 October 2026):** six definitions were returned. The deployed `geolock_resolve_road_node(double precision,double precision)` is SECURITY DEFINER, owned by `postgres`, fixed to `public, extensions, pg_temp`, and executable only by `service_role` among the checked client/service roles. It rejects out-of-range coordinates by producing no point, requires an active approved OPERATIONAL coverage that covers the point, filters active nodes within `c.max_snap_distance_m`, uses geography (`ST_DWithin`/`ST_Distance`, metres), and chooses the nearest via geography KNN. The deployed `verify_ngo_location(uuid,boolean,text)` is SECURITY DEFINER with the same fixed path, service-role-only among checked roles, explicitly checks `auth.role()`/`session_user`, locks the NGO row, requires a routable resolver result for approval, updates `location_verified_at` and `road_node_id`, clears vehicle depot nodes, refreshes road eligibility and writes a system audit event. Thus NGO assignment is approval-driven, not a self-registration trigger. `preview_location_routing()` is authenticated/service-role executable and validates coordinate bounds before calling the resolver; it reports `max_snap_distance_m=500`. `geolock_assign_road_node()` is trigger-only among checked roles and overwrites client node fields for its attached rows.

The deployed `geolock_app_capabilities()` is SECURITY DEFINER and returns `road_node_resolution=true` when it detects at least one active node covered by an active, approved OPERATIONAL coverage. It does **not** check edge presence/connectivity, the current NGO’s verification, or any listing’s route eligibility. Its EXECUTE privilege is also true for `anon`, although the function immediately raises `UNAUTHENTICATED` when `auth.uid()` is null; this is an unnecessary grant to review, not evidence of anonymous data disclosure from the inspected body. The NGO banner is therefore too broad: a clearer message would say road-network coverage is configured while account verification and listing eligibility are checked separately. No graph row counts or live claim/discovery function bodies have been reviewed yet.

**DEV road snapshot and coordination values (user-provided result, 21 October 2026):** one snapshot was returned: `OSM-OPS-20261018`, OPERATIONAL, active and approved, `max_snap_distance_m=500`. Declared and actual counts match at 926,414 node rows (all active) and 2,145,828 directed edge rows; the count query reported one distinct active `component_id`. The singleton configuration values returned were geofence 20,000 m, direct threshold 10.000 kg, claim lease 360 minutes, hub reservation 120 minutes, config version `v2.0`. This verifies installed metadata/count consistency as pasted by the user. It does not independently prove graph path correctness, edge costs, coverage geometry, PostGIS/pgRouting runtime success, or correct eligibility for particular users/listings.

**DEV discovery and atomic claim RPCs (user-provided definitions, 21 October 2026):** `claim_listing(uuid,uuid)` returns `jsonb`, is SECURITY DEFINER owned by `postgres`, fixed to `public, extensions, pg_temp`, and grants EXECUTE to authenticated/service_role but not anon. It requires an active NGO, checks verified location, locks the listing row, checks listing expiry/source state, calls `geolock_ngo_listing_road_check()`, then creates claim + lease + CLAIMED listing + pickup task + request result + CLAIM_ATTEMPT audit in one RPC transaction. It reads the 360-minute value from `coordination_config`, and returns `outcome`, `claim_id`, `reason_code`, `replayed`. The checked-in road migration replacement has the same general call path and signature. Normal returned conflict/ineligible attempts persist their request and audit row atomically; changed-payload request-ID reuse raises before the audit insert, so that rejected misuse is not durably logged by this body. Exceptions during writes roll back transaction state and audit together. No concurrency or fault-injection test was run. Listing row locking plus `ux_active_claim` gives strong structural protection against double ownership, subject to runtime tests.

`discover_eligible_listing_cards()` and legacy `discover_eligible_listings()` return expected listing discovery shapes and call the road-distance helper; both are SECURITY DEFINER and report EXECUTE to anon as well as authenticated/service_role. The card function requires `auth.uid()` and returns no rows for an unverified NGO; the legacy function returns no rows when its NGO lookup is empty. The anon grants appear unnecessary and should be reviewed, though the bodies shown do not disclose anonymous listing results. The card function performs lateral joins for donation/batch images but selects `null::text` for `primary_image_path`; therefore NGO listing cards from this RPC cannot display an image path even when metadata exists. The body also returns hard-coded `routing_status='READY'` for rows selected through a non-null eligibility distance; route-specific helper semantics remain to be inspected. This RPC signature is source-compatible at a basic field-name level, but its primary image field is always empty in the deployed definition shown.

**DEV road eligibility helpers (user-provided definitions, 21 October 2026):** `geolock_ngo_listing_road_check(uuid,uuid)` and its refresh/cost helpers are SECURITY DEFINER, fixed-search-path, and service_role-only among the checked roles. The check requires a verified active NGO with coordinates, an active road snapshot, and both road-node IDs; otherwise it returns `ELIGIBILITY_UNDETERMINED` or `ROUTE_UNAVAILABLE`. It uses geography `ST_DWithin` as a straight-line prefilter against the configured radius, then uses stored road eligibility or refreshes it. Refresh considers active verified NGOs and uses `geolock_road_costs()` with `pgr_dijkstraCost`, directed edges (`reverse_cost=-1`), and stored `road_km`; eligibility is based on road distance times 1,000 <= configured radius. Missing paths are classified using component IDs. `geolock_road_eligible_km()` exposes only cached rows marked ELIGIBLE for the active snapshot and matching current NGO/listing node IDs and verified active NGO. Thus discovery uses cached eligible rows; claim-time checking can refresh a missing/stale row and independently reevaluate. These definitions support road-distance enforcement in source and pasted DEV function bodies, but do not replace runtime tests for disconnected nodes, stale cache races, or 20 km boundary behavior.

**DEV RLS policy inventory (user-provided result, 21 October 2026):** 17 policies were returned. Public image metadata has SELECT-only permissive and restrictive policies for authenticated users, both delegating to role-aware image-read helpers. `storage.objects` has authenticated upload/read/delete policies plus restrictive guards for the private donation-image bucket; UPDATE is guarded from that bucket, and anonymous access to that bucket is guarded. All other public relations in this query had no row policies. With RLS enabled on all 36 public relations, direct client table access is therefore denied unless another policy exists outside the pasted result; app access should be through privileged, ownership-checked RPCs. The policy predicates call SECURITY DEFINER helpers whose exact authorization must be inspected before judging photo privacy. Table/sequence grants and Storage bucket settings are still pending.

**DEV photo authorization helper definitions (user-provided results, 21 October 2026):** all six expected helpers exist. `can_read_geolock_donation_image(text)` permits the donor owner, owning hub admin with an active unexpired reservation or inventory record, or an active verified NGO with a qualifying claim and cached current road eligibility; for hub-batch constituents it also requires active membership and a PUBLISHED batch. `can_read_geolock_batch_image(text)` permits the owning hub admin or an active verified NGO with a qualifying batch claim and road eligibility. Both are SECURITY DEFINER with fixed `pg_catalog, public, extensions, pg_temp` search paths, but report EXECUTE to anon as well as authenticated/service_role; their bodies require `auth.uid()` and return false without it. These are unnecessary anonymous grants to review, not observed anonymous photo disclosure.

The Storage object helper functions are SECURITY DEFINER with fixed `pg_catalog, pg_temp` paths. `geolock_storage_can_read_image()` requires an authenticated caller and the private bucket, allows a caller’s own pending upload path or delegates committed-image access to the role-aware readers. Donation and batch upload helpers require the private bucket, expected path/UUID shape tied to the caller, a donor profile or owning hub admin, JPEG/PNG/WebP MIME type/extension alignment, and bucket metadata set to private, 5 MiB, and the allowed MIME list; the helper comments acknowledge Storage’s pre-insert metadata does not reliably expose final size, leaving the bucket transfer cap and creation RPC size validation as relevant controls. The delete helper allows only caller-owned unattached paths. This matches the local corrective Storage migration’s intended controls. User-provided DEV bucket metadata confirms `geolock-donation-images` is private, limited to 5 MiB, and allows JPEG/PNG/WebP. Storage API behavior, table grants, upload/retry behavior, and end-to-end NGO/hub reads remain unverified.

**DEV effective table privileges (user-provided output, 21 October 2026):** the result covers 36 tables for each role. For both `anon` and `authenticated`, 29 tables report effective SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, and TRIGGER privileges; the remaining seven are `claim_cancellation_requests`, `claim_reconciliation_cases`, `claim_reconciliation_evidence`, `ngo_listing_road_eligibility`, `road_network_coverage`, `road_network_edges`, and `road_network_nodes`. RLS is enabled on the listed public tables, but RLS does not constrain TRUNCATE and does not replace least-privilege checks for TRIGGER. Follow-up ACL output identifies stored relation ACL entries for those 29 tables with owner/grantor `postgres`, granting the same privileges to `anon` and `authenticated`. It also reports matching `public` default ACLs for future tables created by both `postgres` and `supabase_admin`, granting both roles DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, and UPDATE (no grant option). This strongly aligns with the checked-in broad default-ACL restore statements, but does not by itself prove the historical creation path for each relation. The other seven tables had no matching explicit ACL rows in the returned output. This remains a CRITICAL least-privilege issue; do not change permissions without a separately reviewed DEV correction and explicit approval.

**DEV schema and sequence privileges (user-provided output, 21 October 2026):** `anon` and `authenticated` have USAGE but not CREATE on `public` and `storage`. Both roles have USAGE, SELECT, and UPDATE on `public.road_network_edges_edge_id_seq`; other public/storage sequences were not returned. That sequence grant is an additional least-privilege item to review, though its operational impact depends on the table insert grants and RLS (which currently report no effective client table privileges for `road_network_edges`).

**DEV extension and scheduler catalog check (user-provided output, 21 October 2026):** PostGIS `3.3.7` and pgRouting `3.4.1` are installed. `pg_cron` is not installed, and neither `cron.job` nor `cron.job_run_details` exists. This does not establish whether another scheduler or external recovery worker exists; no such worker has been verified in this audit.

**DEV migration-ledger check (user-provided output, 21 October 2026):** `to_regclass('supabase_migrations.schema_migrations')` returned `NULL`. A catalog search found only `auth.schema_migrations`, `realtime.schema_migrations`, and `storage.migrations`; these track Supabase service schemas and do not establish which GeoLock application migrations were applied. Deployment history therefore cannot be reconstructed from the returned ledger objects. Treat the actual catalog definitions and configuration as authoritative evidence; absence of an application ledger does not imply that no migrations were applied.

```sql
-- 1. Non-system schemas and installed extensions.
select n.nspname as schema_name, pg_get_userbyid(n.nspowner) as owner
from pg_catalog.pg_namespace n
where n.nspname not like 'pg_%' and n.nspname <> 'information_schema'
order by 1;

select e.extname, e.extversion, n.nspname as extension_schema
from pg_catalog.pg_extension e
join pg_catalog.pg_namespace n on n.oid=e.extnamespace
order by e.extname;

-- 2. Columns, types, nullability, identity/generated expressions, defaults.
select n.nspname as schema_name, c.relname as relation_name,
       a.attnum as ordinal_position, a.attname as column_name,
       pg_catalog.format_type(a.atttypid,a.atttypmod) as data_type,
       not a.attnotnull as is_nullable, a.attidentity as identity_kind,
       a.attgenerated as generated_kind,
       pg_catalog.pg_get_expr(ad.adbin,ad.adrelid) as default_or_generation
from pg_catalog.pg_attribute a
join pg_catalog.pg_class c on c.oid=a.attrelid
join pg_catalog.pg_namespace n on n.oid=c.relnamespace
left join pg_catalog.pg_attrdef ad on ad.adrelid=c.oid and ad.adnum=a.attnum
where a.attnum>0 and not a.attisdropped
  and c.relkind in ('r','p','v','m','f')
  and n.nspname not like 'pg_%' and n.nspname<>'information_schema'
order by 1,2,3;

-- 3. Primary/foreign/unique/check/exclusion constraints, validation, predicates.
select con.connamespace::regnamespace as schema_name,
       con.conrelid::regclass as relation_name, con.conname,
       con.contype, con.convalidated, pg_catalog.pg_get_constraintdef(con.oid,true) as definition
from pg_catalog.pg_constraint con
join pg_catalog.pg_class c on c.oid=con.conrelid
join pg_catalog.pg_namespace n on n.oid=c.relnamespace
where n.nspname not like 'pg_%' and n.nspname<>'information_schema'
order by 1,2,3;

-- 4. Full index expressions and partial predicates.
select schemaname, tablename, indexname, indexdef
from pg_catalog.pg_indexes
where schemaname not like 'pg_%' and schemaname<>'information_schema'
order by 1,2,3;

-- 5. RLS flags, force-RLS, policies, and triggers with attached definitions.
select n.nspname as schema_name, c.relname as table_name,
       c.relrowsecurity as rls_enabled, c.relforcerowsecurity as force_rls
from pg_catalog.pg_class c
join pg_catalog.pg_namespace n on n.oid=c.relnamespace
where c.relkind in ('r','p') and n.nspname not like 'pg_%'
order by 1,2;

select schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check
from pg_catalog.pg_policies
where schemaname not like 'pg_%'
order by 1,2,3;

select n.nspname as schema_name, c.relname as table_name, t.tgname,
       t.tgenabled, pg_catalog.pg_get_triggerdef(t.oid,true) as trigger_definition,
       p.oid::regprocedure as trigger_function,
       pg_catalog.pg_get_functiondef(p.oid) as trigger_function_definition
from pg_catalog.pg_trigger t
join pg_catalog.pg_class c on c.oid=t.tgrelid
join pg_catalog.pg_namespace n on n.oid=c.relnamespace
join pg_catalog.pg_proc p on p.oid=t.tgfoid
where not t.tgisinternal and n.nspname not like 'pg_%'
order by 1,2,3;

-- 6. Application functions/RPCs: signatures, return types, owners, security,
--    search_path settings, definition, and effective execution rights.
select n.nspname as schema_name, p.oid::regprocedure as signature,
       pg_catalog.pg_get_function_result(p.oid) as return_type,
       pg_catalog.pg_get_userbyid(p.proowner) as owner,
       p.prosecdef as security_definer, p.provolatile as volatility,
       p.proconfig as function_settings,
       has_function_privilege('anon',p.oid,'EXECUTE') as anon_execute,
       has_function_privilege('authenticated',p.oid,'EXECUTE') as authenticated_execute,
       has_function_privilege('service_role',p.oid,'EXECUTE') as service_role_execute,
       pg_catalog.pg_get_functiondef(p.oid) as function_definition
from pg_catalog.pg_proc p
join pg_catalog.pg_namespace n on n.oid=p.pronamespace
where n.nspname='public'
order by 1,2;

-- 7. Views/materialized views and table/sequence grants.
select schemaname, viewname, definition from pg_catalog.pg_views
where schemaname not like 'pg_%' order by 1,2;
select schemaname, matviewname, definition from pg_catalog.pg_matviews
where schemaname not like 'pg_%' order by 1,2;
select table_schema, table_name, grantee, privilege_type, is_grantable
from information_schema.role_table_grants
where table_schema not like 'pg_%' and table_schema<>'information_schema'
order by 1,2,3,4;

-- 8. Storage bucket metadata and Storage policies; do not select object paths.
select id, name, public, file_size_limit, allowed_mime_types
from storage.buckets order by name;
select * from pg_catalog.pg_policies where schemaname='storage' order by tablename,policyname;

-- 9. Relevant coordination settings and road-network operational counts.
select singleton, donation_direct_min_kg, geofence_radius_m,
       claim_lease_minutes, hub_reservation_minutes, config_version
from public.coordination_config order by singleton;
select to_regclass('public.road_network_coverage') as coverage_table,
       to_regclass('public.road_network_nodes') as nodes_table,
       to_regclass('public.road_network_edges') as edges_table,
       to_regclass('public.ngo_listing_road_eligibility') as eligibility_table,
       to_regclass('cron.job') as cron_job_table,
       to_regclass('cron.job_run_details') as cron_run_table;
select network_snapshot_id, dataset_kind, node_count, edge_count,
       max_snap_distance_m, approved_at, active_flag, provenance
from public.road_network_coverage order by created_at;
select network_snapshot_id, count(*) as active_node_count
from public.road_network_nodes where active_flag group by network_snapshot_id order by 1;
select count(*) as edge_count from public.road_network_edges;

-- 10. Migration ledger presence. Only run the second statement if the first
-- result says the relation exists; SQL Editor has no safe conditional relation.
select to_regclass('supabase_migrations.schema_migrations') as migration_ledger;
-- If present:
-- select * from supabase_migrations.schema_migrations order by version;
```

`cron.job` and `cron.job_run_details` are optional: query them only after `to_regclass` confirms their presence. Supabase Edge Functions are not reliably inventoried from PostgreSQL; check the DEV Dashboard’s Edge Functions section. A live migration ledger, if present, is not by itself proof that manually applied SQL matches the checked-in body; compare `pg_get_functiondef`, constraints, triggers, grants, and policies.

## F. End-to-end integration and security review

This is a source-level review only. No deployed RPC signature, RLS policy, or state transition was queried in DEV, and no Flutter workflow was run against Supabase during this audit.

| Workflow | Local integration evidence | Gap / risk | Status |
|---|---|---|---|
| Donor registration and pickup location | Auth onboarding uses the shared picker; donor location is collected with the donation. Client does not supply a trusted road-node ID. | Android key is absent locally. The road preview RPC and INSERT trigger are only in a migration marked unexecuted. | PARTIAL; DEV UNVERIFIED |
| Donation creation and classification | Flutter calls the image-backed donation RPC; the checked-in lifecycle migration applies the 10 kg direct/hub threshold and exposes donor history/detail/cancel reads. | Storage permissions, deployed signatures, 10 kg boundary, atomic photo/database behavior, and history responses were not tested against DEV. | SOURCE PRESENT; RUNTIME UNVERIFIED |
| Hub recommendation and reservation | UI uses authorized hub reads and the reservation RPC; receipt is a separate hub-admin action. | Current road-based hub availability depends on graph data and deployed functions. Reservation expiry and capacity invariants were not exercised. | SOURCE PRESENT; RUNTIME UNVERIFIED |
| NGO registration and trusted location | Self-registration does not set trust; local road proposal restricts `verify_ngo_location()` to the service-role path and resolves NGO coordinates there. | The exact deployed verification workflow and whether a trusted operator process is operational are unknown. | PARTIAL; DEV UNVERIFIED |
| NGO discovery and claim | Flutter discovers listings and invokes `claim_listing()` with a request UUID. The proposed road migration invokes server-side road eligibility from discovery/claim. | Whether DEV has the route-aware function, approved graph snapshot, eligible NGO rows, and the intended grants is unknown. No two- or ten-way concurrency test was run. | SOURCE PRESENT; RUNTIME UNVERIFIED |
| Lease, pickup, recovery, reconciliation | Flutter has claim/pickup/reconciliation screens and the repository contains claim recovery/reconciliation SQL. | Scheduler/Edge Function status and actual DEV grants, audit evidence, lease-expiry behavior, and uncertain-handover handling were not inspected live. | SOURCE PRESENT; RUNTIME UNVERIFIED |
| Hub receipt, inventory, batches, NGO pickup | Hub screens call receipt, inventory, and batch RPCs; NGO screens expose pickup actions. | Live authorization, reservation-expiry behavior, capacity accounting, atomic batch publication, and cross-role state display are unknown. | SOURCE PRESENT; RUNTIME UNVERIFIED |

### Coordination and security conclusions

- **Claim ownership:** the local road migration retains a protected `claim_listing()` definition and calls its route check before committing claim writes. This is a proposal-level observation, not proof of deployed atomicity or grants. Existing unique indexes and transaction behavior must be confirmed by the read-only DEV inventory and then concurrency-tested separately.
- **Eligibility:** the proposed location layer does not equate node snapping with eligibility. It requires verified NGO location, graph coverage/nodes, and directed road distance. Missing graph connectivity is fail-closed in the source proposal. DEV graph approval, node coverage, and result rows remain unknown.
- **Audit and state:** the latest contract keeps donation, listing, claim, lease, hub reservation, inventory/batch, and pickup as separate authorities. The Flutter UI consumes RPC responses; it must not infer a committed transition from a button press. Live audit completeness and append-only enforcement remain unverified.
- **Potential integration blocker:** the picker requires a successful road-preview result for donor/hub selections. If the operational migration/RPC is absent or the selected point cannot resolve within the approved graph, confirmation is unavailable; this should be surfaced as unavailable routing, not bypassed with a client node ID.
- **No evidence of a route-optimization interface:** the repo has route preview/eligibility support, but no role-specific route map/optimization screen was found. This is a UI feature gap, separate from atomic claim eligibility.

## G. Prioritized follow-up

1. **Fix the local Android key configuration first:** supply a restricted Android Maps SDK key through the documented ignored `android/local.properties` property. In Google Cloud, confirm Maps SDK for Android is enabled, billing is active, and the Android restriction matches `com.example.geolock_hub_app` plus the debug/release signing SHA-1 fingerprints. Never paste the key into this report or commit it.
2. **Run the read-only DEV inventory** above and capture results, especially the actual road-node triggers, capability RPC, claim function, role verification, and active graph snapshot.
3. **Verify road migration deployment state.** If not installed, donor/hub location picker confirmation may fail because the required preview RPC is unavailable. Do not apply it as part of this audit.
4. **Verify trusted NGO verification end-to-end** with an authorized trusted operator. Confirm NGO node assignment, `location_verified_at`, active graph coverage, and road eligibility; do not create or trust client-provided node IDs.
5. **Clarify NGO banner semantics** so graph availability is distinct from the current NGO’s verified status.
6. **Decide the Donor Map tab’s future**: integrate only a privacy-safe feature or remove/replace the destination after approval. Keep donor pickup coordinates private.
7. After read-only inventory and approval, run focused DEV-only tests for map rendering, 500 m boundary/no-match/out-of-coverage cases, NGO verification, directed 20 km road eligibility, and atomic claim revalidation. Do not treat widget tests or local SQL inspection as deployed-system evidence.

## Verification boundary

No files other than this audit report were intentionally changed. No SQL, migration, code, configuration, Supabase project, or database data was modified. The original shared project was not accessed.
