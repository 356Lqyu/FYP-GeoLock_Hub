# GeoLock Hub Stage 1 to 4 Seven Day Gap Analysis

**Prepared:** 21 October 2026  
**Scope:** Read-only review of Stage 1–4, revised NGO and Hub Admin registration policies, Profile editing, and the seven-day completion plan.  
**Database boundary:** Isolated DEV project `rcgyuwiidqvrgbxswhqj` only. No Supabase connection or SQL execution was performed for this report. The original shared project `mffccmlimmbrgasgfnnq` was not accessed.

## Executive summary

The repository and user-provided DEV catalog/function results show substantial Stage 1–4 implementation, but none of the critical workflows has been demonstrated end to end in this review. The strongest verified evidence is structural: V3 donation/claim tables and constraints exist in the supplied DEV inventory; `claim_listing()` was inspected and has a listing lock, request replay checks, transactionally written claim artifacts, and a unique active-claim index; the DEV road snapshot and configuration were reported active with PostGIS/pgRouting installed. Runtime concurrency, lease recovery, eligibility boundaries, and complete audit behavior remain untested.

Three registration/profile policies are not implemented as now requested:

1. **NGO registration:** the local registration RPC deliberately saves a self-selected location with no trusted node and no `location_verified_at`. The NGO remains ineligible until a service-role verifier runs. The new policy requires automatic technical road-node validation during registration, without implying NGO identity verification.
2. **Hub Admin registration:** the role-selection screen blocks the Hub Admin route as provisioned-only, `register_role_profile()` rejects `HUB_ADMIN`, and `register_community_hub()` requires an existing Hub Admin profile. The current schema does not enforce one hub per admin.
3. **Edit Profile:** the current Profile screen is read-only and the repository has no protected profile-update RPC. A location/capacity edit cannot safely be added as a client table update.

The most urgent security configuration concern is the user-provided DEV privilege matrix. `anon` and `authenticated` have broad explicit table ACLs—including `TRUNCATE` and `TRIGGER`—on the same 29 public tables, and broad public default ACLs exist for tables created by `postgres` and `supabase_admin`. RLS prevents unqualified row access where no matching policy exists, but it does not constrain `TRUNCATE`. This is an excessive-privilege finding, not proof that a normal Flutter/PostgREST request can currently truncate a table. Before changing privileges, confirm every Flutter data operation is through an authorized RPC and verify deployed function owners/EXECUTE grants. The Flutter source reviewed here uses RPCs for public data and the Storage API for photos; it contains no direct public-table query.

The revised Coordination Authority Contract and the current DEV evidence support the requested donation terminology and authority boundary: `SUBMITTED` remains the hub-selection state, direct donations start at `READY_FOR_PICKUP`, `CLAIMED` is a listing state, and `COLLECTED` is the terminal donation state. `VALIDATED` and `DELIVERED` are not persisted donation states. Older PDF/checklist language and older local migration definitions must not override these decisions.

**Readiness conclusion:** Stage 1–4 are **partially implemented**, **not fully tested**, and **not yet ready for supervisor sign-off**. A seven-day demonstration plan is possible only if DEV access, synthetic eligible identities, teammate coordination on route-sensitive updates, and a recovery worker are available immediately. The full verification list cannot be guaranteed in seven days if any of those prerequisites slips.

## Evidence and source handling

The pasted request is the current policy authority for automatic NGO location validation, self-service Hub Admin registration, and Edit Profile. The revised Coordination Authority Contract supplies the transaction and state authority rules, except where the new request explicitly changes the location trust policy. The FYP PDF and checklist are project references. The checklist is dated 19 October 2026 and contains older manual NGO approval and straight-line eligibility notes; those notes are superseded by the current request and the newer DEV road-function evidence.

Evidence labels used below:

- **DEV inspected:** reported by the user from isolated DEV catalog/function queries and recorded in the existing audit. I did not independently connect to the database.
- **Repository verified:** read from checked-in Flutter or SQL source. A local migration is not proof it is deployed.
- **Runtime tested:** executed against DEV or the app. No new runtime tests were run for this read-only review.
- **Unknown:** the required DEV body, data, worker, or outcome was not present in the supplied results.

The DEV `supabase_migrations.schema_migrations` lookup returned `NULL`. The only similarly named relations found were `auth.schema_migrations`, `realtime.schema_migrations`, and `storage.migrations`; these do not provide GeoLock application migration history. Therefore, deployment provenance must be inferred from actual DEV objects, never from local migration filenames alone.

## A. NGO automatic location validation

### Current behavior

| Layer | Current evidence | Gap against the new policy |
|---|---|---|
| Flutter registration | `auth_pages.dart` requires a confirmed map location and stores its address/coordinates in pending Auth metadata. It tells the user the location is “awaiting trusted location verification.” | The text and flow still represent third-party approval as a required step. |
| Auth onboarding | `auth_controller.dart` only permits pending self-registration for DONOR or NGO and checks `geolock_app_capabilities().ngo_location_registration == 'UNVERIFIED'` before registering an NGO. | This capability gate encodes the old workflow and must be changed with the backend contract; it should indicate automatic resolver availability instead of “unverified pending approval.” |
| Local `register_role_profile()` | `20261017_registration_compatibility.sql` preserves the V3 signature, rejects client roles other than DONOR/NGO, ignores `p_road_node_id`, and inserts NGO coordinates with `road_node_id = NULL` and `location_verified_at = NULL`. | A newly registered NGO cannot pass the current verified-location claim precondition without a separate trusted operation. |
| Road resolver | The supplied DEV definition of `geolock_resolve_road_node()` is SECURITY DEFINER, fixed-search-path, service-role-only among checked roles, and resolves the nearest active node in approved operational coverage within configured snap distance. DEV reports an active approved OPERATIONAL snapshot with `max_snap_distance_m = 500`. | Successful resolution is not currently part of NGO self-registration. Exact 500 m behavior has not been runtime-tested. |
| NGO verification | The supplied DEV `verify_ngo_location(uuid,boolean,text)` definition requires service-role/database-owner authorization, locks the NGO row, resolves a node before approval, updates verification/node fields, refreshes eligibility, and writes an audit event. | It is a manual decision surface and does not meet “no third person needs to approve” if registration depends on it. |
| Discovery/claim | User-provided DEV function results show discovery and `claim_listing()` require an active verified NGO and use the road eligibility helper; `claim_listing()` revalidates eligibility. | The registration change must preserve these checks. A successful map selection alone must never confer eligibility. |

### Minimum safe target behavior

1. In the authenticated `register_role_profile()` transaction, validate coordinate ranges, call the trusted road resolver on the server, and reject with a clear correction message if there is no approved-coverage match within 500 m. Resolve the node before writing profile rows so a failed validation leaves no partial role profile. Ignore any client-supplied road-node ID, as today.
2. On success, persist the resolved node and record that the location is **technically routing validated**. Do not describe this as identity, NGO legitimacy, or physical-presence verification. The contract and Profile wording should distinguish these concepts.
3. Keep the backend’s active NGO role, verified/technically valid node, and 20 km directed road-distance checks in discovery and claim. Preserve claim-time eligibility revalidation.
4. Recompute or invalidate the NGO/listing eligibility cache in the same transaction after changes that affect eligibility. Existing claims and leases remain authorized by their claim/lease ownership, not by a client-selected node. Coordinate any change that affects an assigned vehicle depot or active route with the teammate who owns route work.
5. Revalidate existing pending DEV NGOs through the same resolver. Do not bulk-mark them valid from stored coordinates alone; unresolved points stay unable to claim and get an actionable location-correction path.
6. Retain a trusted operator function only for controlled revalidation/repair if still needed. Do not make a human approval decision a prerequisite for a valid self-selected location.

### Contract sections to update

Clarify in the contract’s **Scope / invariants**, **Geofence service authority**, **Failure ownership**, and **acceptance tests** that road-node resolution is an automatic technical check, not third-party NGO identity approval. Specify coordinate correction, no-node failure, cache refresh, and how a location change interacts with active claims/routes. No contract file was modified.

## B. One Hub Admin to one hub

### Current behavior

| Layer | Current evidence | Gap |
|---|---|---|
| Role selection | `AccountRole` includes `hubAdmin`, but the Continue handler displays “Hub Admin accounts must be provisioned by a trusted administrator” and does not open registration. | Direct conflict with self-registration without another user’s approval. |
| Auth pending metadata | `_isValidPendingProfile()` accepts DONOR and NGO only. | Hub name, location, and capacity cannot be resumed after email verification. |
| Role-profile RPC | The local V3-compatible `register_role_profile()` rejects `HUB_ADMIN` with `ROLE_NOT_SELF_SERVICE`. | No self-service Hub Admin role creation. |
| Hub RPC | V3 `register_community_hub()` requires an existing `hub_admin_profiles` row, enforces 50–250 kg, inserts the hub and an audit event, and relies on the road trigger for node assignment. | It cannot create an Auth user’s role profile and hub as one onboarding operation. It also has no one-hub-per-admin guard. |
| Schema | `community_hubs` has `admin_user_id NOT NULL`, a foreign key to `hub_admin_profiles`, and 50–250 kg capacity constraint. The repository has a composite unique constraint on `(hub_id, admin_user_id)`, not a unique constraint on `admin_user_id`. | One admin can own multiple hub rows. The composite uniqueness does not enforce the requested one-to-one rule. Existing duplicate ownership rows have not been inspected. |
| Road trigger | The supplied DEV trigger inventory says hub coordinates are matched on insert/update. The local `geolock_assign_road_node()` sets the node to the resolver result; it does not itself raise when the resolver returns no row. | A hub can risk being inserted with a null node unless another deployed constraint/function rejects it. New registration must fail atomically when validation fails. |
| Hub UI/profile | `RegisterHubPage` calls the existing `register_community_hub()` and sends a null road-node value. Hub Profile iterates over a list of hubs. | The existing management path should remain for an authorized existing hub only, but onboarding should create exactly one hub and the Profile/dashboard assumptions should become single-hub. |

### Minimum safe target behavior

1. Add a dedicated authenticated onboarding RPC that validates the full Hub Admin + hub payload, resolves the hub node, enforces 50–250 kg, and creates `user_profiles`, `hub_admin_profiles`, `community_hubs`, and registration audit evidence in one transaction. If any validation fails, no role/hub profile rows commit. Supabase Auth user creation remains a separate operation; pending metadata must allow safe retry after email verification.
2. Add a unique constraint/index on `community_hubs(admin_user_id)` after a read-only duplicate preflight. Do not delete or merge any existing hubs automatically. If duplicate ownership rows exist, stop and resolve them explicitly before adding the constraint.
3. Keep the existing `register_community_hub()` RPC for authorized operations only if it is still needed, but the uniqueness constraint must reject a second hub. It must not be exposed as a way around onboarding validation.
4. Require server-side resolver success before any registration writes. Validate address/name and capacity in the RPC, not just Flutter. A resolver failure returns a specific error and leaves no partial hub profile/hub row.
5. Keep reservations, stored inventory, and capacity authority unchanged. Hub recommendation and aggregation remain teammate-owned and are not prerequisites for testing unrelated Stage 1–4 claim/recovery behavior.

## C. Edit Profile and location changes

### Current profile/edit support

- `RoleProfilePage` calls `get_my_profile()` and, for HUB_ADMIN, `get_my_hubs()` plus authorized dashboard reads. It displays full name, Auth email, phone, role, and Auth account-created time. NGO registration number is explicitly unavailable from the profile RPC; NGO organization/address/location status are displayed. Hub information comes from the authorized hub reads.
- The Profile Settings panel says details are read-only and that secure editing is unavailable. No protected profile-update RPC was found in the checked-in migrations. The app does not directly update the role/profile tables.
- The local `get_my_profile()` response contains NGO name, address, coordinates, `location_verified_at`, and `location_status`, but omits `registration_number`. Email and account creation date come from the authenticated Supabase Auth user, not that JSON.
- The present UI supports a list of hubs. The requested one-admin/one-hub policy changes that assumption.

### Recommended minimal secure implementation

1. Keep role, email, created date, trusted node ID, and system IDs read-only. Add a protected self-profile RPC for full name/phone and role-specific allowed fields. Do not add direct PostgREST updates.
2. For NGO location edits, use the existing Google Maps picker and submit address/coordinates only. In one database transaction: lock the NGO profile; resolve a node using approved coverage and the 500 m rule; reject invalid points **before** altering the old row; update address/coordinates/node/technical-validation timestamp atomically; invalidate/recompute affected eligibility; and write audit evidence. Preserve the previous valid location on failure and show the reason. This is safer than storing a new unresolved point that could make the UI disagree with the old node.
3. Do not accept `road_node_id` from Flutter. A successful location change affects future discovery/claims only; it must not transfer an existing claim, lease, or task. For safety, block location changes while the user has active claims, pickup tasks, or route assignments until the teammate-owned route contract confirms a safe update rule. This is a compatibility question, not a reason to modify route code.
4. For hub information edits, expose only the current owner’s single hub through a protected RPC. Re-resolve new coordinates on the server. A capacity decrease must be rejected if stored inventory plus active reservations/commitments exceed the proposed capacity, using the same authoritative accounting and lock order as reservation/receipt operations. Do not change those existing workflows.
5. Extend the secure profile read to include the allowed NGO registration number if the product still needs to display it. Do not include trusted road-node IDs in client JSON.
6. Write append-only audit records for successful material changes and authorized rejections where supported. Never fabricate a successful location validation in Flutter.

The exact RPC return contracts and update lock order need a separate review against the deployed functions before implementation. No update functions or migrations were created in this review.

## D. Stage 1–4 status matrix

Statuses are based on repository source and user-provided DEV inspection results in the existing audit. **No tests were executed for this report.** “Implemented but untested” means the mechanism exists in source/inspected DEV definition but the required behavior has not been demonstrated at runtime. `BLOCKED BY TEAMMATE` is used only where a teammate-owned route contract is needed to safely change in-flight route data.

### Stage 1 — Donation state machine

| Requirement | Status | Evidence and exact gap |
|---|---|---|
| Donation creation, description, items, weights, required photos | PARTIALLY IMPLEMENTED | Image-backed creation RPC and Flutter form exist; one earlier DEV 4 kg donation/photo metadata smoke path was reported. Full 1–3 photo enforcement, required description, 9.9/10/10.1 kg boundary and atomic photo reference behavior still need a fresh isolated-DEV test. |
| Direct/hub classification and availability | IMPLEMENTED BUT UNTESTED | DEV config reports 10 kg; direct creation is `READY_FOR_PICKUP` with a listing, hub creation is committed `SUBMITTED`; verify all boundary values and persisted rows. |
| Legal donation, listing, claim transitions | IMPLEMENTED BUT UNTESTED | DEV donation check excludes `VALIDATED` and `DELIVERED`; active claim partial unique index and listing state are reported. Invalid transition tests have not run. |
| Claim attempt, success and conflict | IMPLEMENTED BUT UNTESTED | Deployed `claim_listing()` body was supplied; it returns JSON outcomes and writes normal result/audit. No controlled 2/10-way test has run. |
| Pickup started/completed | IMPLEMENTED BUT UNTESTED | `start_pickup()` and `complete_pickup()` are used by Flutter and defined in V3; lease/state race and cross-role display remain untested. |
| Donor cancellation / claim release | IMPLEMENTED BUT UNTESTED | Safe cancellation and `cancel_claim()` implementations exist; user-provided deployed cancellation definition was corrected for the ambiguous join. Races against claim, reservation reassignment and receipt have no reported passing test. |
| Lease expiry and safe release/reconciliation | PARTIALLY IMPLEMENTED | Recovery/reconciliation migration is reported installed in DEV; automatic scheduler is not evidenced. Worker, stale holder, custody uncertainty and repeated execution need runtime tests. |
| Lease renewal | NOT APPLICABLE BY APPROVED DESIGN | Renewal is disabled for this FYP scope. Do not implement it. Confirm no active client action can extend a lease. |
| Delivery-confirmed transition / DELIVERED | NOT APPLICABLE BY APPROVED DESIGN | `COLLECTED` is terminal; no separate `DELIVERED` donation state. Physical handover remains evidenced by pickup completion/reconciliation. |
| Audit retrieval and completeness | PARTIALLY IMPLEMENTED | Audit table/RPC and role-scoped reads exist in source/DEV results. Not every required field has been verified for every operation. Claim exceptions and changed-payload idempotency errors do not leave a durable same-transaction audit row; needs an approved trusted failure-logging design. |
| Illegal transition rejection and item immutability | IMPLEMENTED BUT UNTESTED | Latest local migration removes persisted `VALIDATED` and freezes submitted items; deployed constraints/triggers are reported enabled. Forbidden direct updates and reparenting need tests. |
| Flutter/backend status consistency | PARTIALLY IMPLEMENTED | `SUBMITTED` is the official hub state and `CLAIMED` is listing-only. UI still contains legacy `VALIDATED`/`DELIVERED` labels/mappings; ensure they are historical-only and never shown as current state. |
| No false success on transaction failure | IMPLEMENTED BUT UNTESTED | Flutter calls protected RPCs and has error paths. Fault-injection and unknown-commit retry have not been exercised end to end. |

### Stage 2 — Atomic claim management

| Requirement | Status | Evidence and exact gap |
|---|---|---|
| Single atomic claim transaction | IMPLEMENTED BUT UNTESTED | Supplied DEV body commits claim, lease, listing, task, request result and audit in one function transaction. Fault cases have not run. |
| Listing row lock | IMPLEMENTED BUT UNTESTED | Supplied `claim_listing()` body locks the listing before claim ownership writes. No live competing requests have tested the lock behavior. |
| At most one active claim per listing | IMPLEMENTED BUT UNTESTED | DEV reports a valid unique partial index on `donation_claims(listing_id)` for ACTIVE/RECONCILIATION_REQUIRED. No concurrency test has confirmed its operational result. |
| Explicit SUCCESS/CONFLICT outcome | IMPLEMENTED BUT UNTESTED | Function response includes `outcome` and `reason_code`; confirm all losers return `CLAIM_CONFLICT`, not only HTTP errors. |
| Same request UUID replay | IMPLEMENTED BUT UNTESTED | Request digest/result replay is in the inspected body and a prepared test; not executed. |
| Changed payload with same UUID rejected | PARTIALLY IMPLEMENTED | Function rejects changed listing/NGO payload, but raises before creating separate durable failure audit evidence. Tests assert original committed state remains unchanged. |
| Two simultaneous NGOs | IMPLEMENTED BUT UNTESTED | Prepared concurrency runner has a 2-way barrier and committed-state/audit assertions. Not run. |
| Ten simultaneous NGOs | IMPLEMENTED BUT UNTESTED | Prepared runner has a 10-way case and requires ten eligible sessions. It is not run; synthetic users must pass real location and route eligibility. |
| Fifty simultaneous NGOs | MISSING | The FYP report’s development schedule calls for 2/10/50 client tests. Current runner executes only 2 and 10. Add the 50 case only after 10-user behavior is stable and adequate isolated fixtures exist. |
| Artificial delay / contention | IMPLEMENTED BUT UNTESTED | Prepared test holds the listing row and correlates waiters with `pg_blocking_pids()` and the test PID. An inconclusive run may still consume the listing; not run. |
| Required-write rollback / audit failure | IMPLEMENTED BUT UNTESTED | Test-only failpoint SQL is separate and request-scoped; not installed or run. It validates rollback but cannot persist an audit insert in a transaction that rolls back. |
| Claim versus cancellation race | IMPLEMENTED BUT UNTESTED | Relevant cancellation and claim locking are present; use dedicated fixtures and assert committed rows for both outcomes. No run reported. |
| Duplicate claim/lease/task prevention | IMPLEMENTED BUT UNTESTED | Unique constraints, request replay and one transaction protect the expected artifacts; no post-race database assertion has been run. |
| Durable rejected-attempt audit | PARTIALLY IMPLEMENTED | Normal returned CONFLICT/INELIGIBLE results have transactional audit evidence. Exceptions (changed payload and required-write rollback) roll back their audit attempt; an out-of-transaction trusted logger/outbox is not established. |

### Stage 3 — Lease and recovery

| Requirement | Status | Evidence and exact gap |
|---|---|---|
| 360-minute claim lease | IMPLEMENTED BUT UNTESTED | DEV singleton reports 360 minutes and claim function reads config. Verify actual committed expiry timestamps and boundary behavior with DB time. |
| Renewal disabled | NOT APPLICABLE BY APPROVED DESIGN | Contract disables automatic renewal. Confirm no RPC or UI extends it; do not add renewal behavior. |
| Database-time expiry policy | IMPLEMENTED BUT UNTESTED | Local recovery/pickup functions use database timestamps; expiry-versus-completion behavior has not been run under concurrency. |
| Recovery function | IMPLEMENTED BUT UNTESTED | `recover_expired_claims(integer)` is part of the reported installed Stage 1 recovery migration and is service-role protected. No runtime recovery result was provided in this review. |
| Automatic worker/scheduler | MISSING | DEV reports no `pg_cron` extension or cron relations. No DEV Edge Function/scheduler result is in the current evidence. An external worker is unknown. Without a verified worker, claims can remain expired until an operator invokes recovery. |
| Safe release vs reconciliation | IMPLEMENTED BUT UNTESTED | Recovery/reconciliation logic and tests exist in local source; test that pickup/route activity or uncertain custody leaves RECONCILIATION_REQUIRED. |
| Expiry versus pickup completion | IMPLEMENTED BUT UNTESTED | Contract requires serialization by database state/locks. The prepared test plan covers it; no concurrent run reported. |
| Concurrent/repeated recovery workers | IMPLEMENTED BUT UNTESTED | Idempotent recovery is designed in SQL; two worker and repeat execution tests have not run. |
| Stale holder rejection | IMPLEMENTED BUT UNTESTED | Protected pickup functions are intended to check active claim/lease. Must verify old holder is rejected after release/reassignment. |
| Duplicate release / restart recovery | IMPLEMENTED BUT UNTESTED | State and request checks are present in design; duplicate recovery and restart tests remain pending. |
| Worker logging/failure visibility | PARTIALLY IMPLEMENTED | No scheduler exists in the inspected DEV catalogs, so execution logs/alerts and retry visibility are not demonstrated. |

### Stage 4 — Deterministic geographic eligibility

| Requirement | Status | Evidence and exact gap |
|---|---|---|
| Automatic NGO 500 m node matching | PARTIALLY IMPLEMENTED | Resolver exists and approved 500 m graph is reported, but NGO registration still persists unverified/no node in the local compatibility body and uses a service-role verification step. New policy requires automatic registration validation. |
| Automatic hub/donation node assignment | IMPLEMENTED BUT UNTESTED | DEV trigger metadata and road helper definitions were supplied. Hub resolver failure may yield null in the local trigger; registration must fail closed. Runtime cases absent. |
| Approved operational graph coverage | IMPLEMENTED BUT UNTESTED | DEV reports active approved OPERATIONAL snapshot `OSM-OPS-20261018`, 926,414 active nodes, and 2,145,828 edges with declared/actual counts matching. This does not prove graph connectivity or correct route costs. |
| 20 km directed road-distance eligibility | IMPLEMENTED BUT UNTESTED | Supplied DEV functions use pgRouting/directed costs and 20,000 m config. No route-distance boundary or directed asymmetry test has run. |
| Valid nodes and connectivity | PARTIALLY IMPLEMENTED | Node/edge counts and one component ID were reported. A single component label does not prove every directed pair is reachable; disconnected and reverse-direction cases need tests. |
| Missing, invalid, zero coordinates | IMPLEMENTED BUT UNTESTED | Resolver/preview are designed to fail closed; verify no zero-distance/default-eligible behavior in DEV. |
| Exactly 500 m snapping boundary | IMPLEMENTED BUT UNTESTED | Resolver uses configured `ST_DWithin`; inclusive/precision behavior needs inside/exact/outside synthetic tests. |
| Exactly 20 km road eligibility boundary | IMPLEMENTED BUT UNTESTED | Current 20 km configuration is verified, but inclusive/exclusive behavior and road-distance precision are not tested. |
| Disconnected/unavailable path | IMPLEMENTED BUT UNTESTED | pgRouting helper has fail-closed outcomes in source; test null/unknown route outcomes and verify discovery/claim agree. |
| Multiple and zero eligible NGOs | IMPLEMENTED BUT UNTESTED | Discovery and claim filters are present; test overlapping eligibility and no-eligible outcomes. |
| Discovery/claim consistency | IMPLEMENTED BUT UNTESTED | Claim revalidates the road eligibility helper at attempt time. Confirm stale cache is refreshed or rejected and cannot grant a claim. |
| Location-change cache invalidation | PARTIALLY IMPLEMENTED | Trusted `verify_ngo_location()` refreshes cache; no user-owned location-edit RPC exists. New edit path needs atomic node update and cache refresh. Route/task effects require teammate agreement. |
| No client-supplied road-node IDs | IMPLEMENTED BUT UNTESTED | Registration RPC ignores `p_road_node_id`; road triggers overwrite nodes. Test direct table/RPC attempts under actual RLS/grants. |

## E. Security priority: broad public-table ACLs

### DEV evidence already provided

- Both `anon` and `authenticated` have effective SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, and TRIGGER privileges on 29 public tables. The other seven tables in the returned matrix were the cancellation/reconciliation tables and road-eligibility/network tables.
- The follow-up ACL query reported explicit grants on those 29 tables with owner/grantor `postgres`, plus public-schema default ACLs granting broad table privileges to both roles for future tables created by `postgres` and `supabase_admin`.
- `anon` and `authenticated` have USAGE but not CREATE on `public` and `storage`. Both have USAGE/SELECT/UPDATE on `public.road_network_edges_edge_id_seq`.
- Public RLS is enabled. The supplied policy inventory had no direct policies on most lifecycle tables; image metadata has role-aware SELECT policies. RLS does not filter TRUNCATE.
- Flutter data access found in this repository uses RPCs for public data and the Supabase Storage API for image objects; no direct `.from('public_table')` operation was found. The bucket’s own Storage RLS is a separate permission plane.
- Checked-in local definitions for all 36 Flutter-called RPC names were SECURITY DEFINER. This does not prove every current DEV overload/owner/grant is identical; the exact deployed definition/grant for each call must be checked before any revoke.

### Recommended narrow DEV-only correction (not executed)

1. First capture exact current ACL/default-ACL output and confirm all Flutter-called DEV RPCs are SECURITY DEFINER with trusted owners and authenticated EXECUTE grants. Confirm no application consumer relies on direct public-table access.
2. In a reviewed DEV-only forward migration, revoke unnecessary table privileges from only `anon` and `authenticated` on public tables and sequences, preserving owners and `service_role`. Revoke corresponding public default table ACLs for both object-creating roles (`postgres`, `supabase_admin`). Sequence default ACLs were not supplied and must be checked before finalizing that part.
3. Do not touch `storage.objects`, the private bucket, Storage policies, `service_role`, Supabase Auth, table ownership, or SECURITY DEFINER function bodies in this ACL correction. Public-schema grant removal does not change a SECURITY DEFINER function’s owner privileges or Storage policy evaluation, provided the deployed function owner and function grants are verified.
4. After change, verify effective privileges are false for clients on protected public tables/sequences, intended RPC EXECUTE remains true for authenticated, anon has no protected RPC EXECUTE, Storage upload/list/read/delete still follows bucket policies, and donor/NGO/hub RPC flows work.
5. Before deployment, save a schema/ACL snapshot and generated restoration statements. If rollback is required after commit, restore the exact captured ACL/default-ACL entries, not blanket `GRANT ALL`. Do not apply a rollback that recreates broad grants without reviewing the original state.
6. Correct the local schema-with-grants restore source after approval so a future DEV rebuild does not reintroduce the same broad ACLs. Do not rewrite already-applied historical migrations.

This issue should be resolved before broad client runtime testing. It does not prove current row disclosure or a reachable TRUNCATE endpoint; the practical exploit surface must be assessed with PostgREST/RPC capabilities. No grant changes were made.

## F. Seven-day implementation and test plan

The schedule assumes seven consecutive workdays after approval. Use only isolated DEV and synthetic accounts. Do not use imported benchmark users as trusted organizations; each NGO must be eligible through the operational resolver. Hub recommendation and aggregation stay teammate-owned.

| Day | Focus and exact code/SQL areas | Essential tests and evidence | Dependencies / acceptance |
|---|---|---|---|
| **1 — Security baseline and policy freeze** | Reconcile `geolock-v3-public-schema-with-grants.sql`, `geolock-v3-permissions-dev.sql`, actual DEV ACL/default ACLs; compare all Flutter RPC calls in `auth_controller.dart`, `dashboard_pages.dart`, `donation_pages.dart` to deployed signatures/owners/grants. Update the authority contract in review only for automatic technical location validation and profile updates. | Save preflight ACL/function-grant output; confirm no direct public table calls; after separate approval, apply only reviewed DEV ACL correction and verify RPC, Storage upload/list/read. Record before/after outputs. | Must not revoke before exact deployed RPC privilege/owner check. This is the first actionable task. |
| **2 — Automatic NGO technical validation** | Prepare an additive replacement for `register_role_profile()` preserving signature/authorization, using `geolock_resolve_road_node()`; update `auth_controller.dart` and NGO registration text/capability handling in `auth_pages.dart`; preserve the shared map picker and `road_routing.dart`. | Valid coordinate within coverage/500 m registers with server node; just inside/exact/outside snap tests; out-of-coverage/invalid coords produce clear error and no partial profile; client node spoof ignored; existing pending synthetic NGO is revalidated only through resolver. Capture audit and eligibility rows. | Teammate must confirm active route/depot behavior before changing existing NGO coordinates. Do not modify road graph or routing code. |
| **3 — Hub Admin onboarding and one-hub invariant** | Add an atomic authenticated Hub Admin + hub onboarding RPC; update pending metadata and role flow in `auth_controller.dart` / `auth_pages.dart`; update `RegisterHubPage`/dashboard entry in `donation_pages.dart` and `dashboard_pages.dart`; prepare unique `community_hubs(admin_user_id)` constraint after duplicate preflight. | Valid 50/250 kg registrations; 49.99/250.01 rejected; invalid/out-of-range/unresolvable location commits no profile/hub; exactly one admin+hub; second hub rejected; unauthenticated/foreign role rejected. Verify all four rows and audit evidence. | Existing duplicate admin→hub data must be reviewed manually before unique index. Hub reservation/capacity accounting remains unchanged. |
| **4 — Secure Profile edits** | Add self-owned profile update RPC(s) and safe Profile read fields; update `RoleProfilePage` and forms in `dashboard_pages.dart`; reuse location picker. No direct table updates. | Donor/NGO/admin own-field updates; foreign user rejected; role/email/node/status edits rejected; invalid NGO location update preserves prior valid values; valid update atomically changes node/cache; capacity decrease below inventory+reservations rejected. Verify active claim/route update policy with teammate before allowing location changes during operations. | Route/active-task compatibility is a gate. Conservative default: block location edits while active claim/task/route assignment exists. |
| **5 — Stage 1 lifecycle proof** | Check the installed versions of `create_donation_with_images()`, `create_and_validate_donation()`, `reserve_hub_capacity()`, `confirm_hub_receipt()`, `cancel_donation()`, `cancel_claim()`, pickup RPCs and transitions; current Flutter pages in `donation_pages.dart`, `status_timeline.dart`, `donation_status.dart`. | 9.9/10.0/10.1 kg; nonblank description; mandatory photo count/type/size; Hub reservation/expiry/reassignment; receipt vs cancellation race; cancellation vs direct claim; transitions and item immutability; donor history/details; committed state and audit assertions. | Use dedicated fresh synthetic fixtures; no reuse of a consumed listing. Preserve `SUBMITTED`, nullable direct listing expiry, 360-minute claims, 120-minute reservations. |
| **6 — Stage 2 claim correctness** | Use `claim_concurrency_test.py`, `claim_fault_injection_dev_test.py`, `claim_write_failpoints_dev.sql` only after separate DEV approval and fixture readiness. Do not modify `claim_listing()` for the tests. | Two and ten simultaneous eligible NGOs; 50-way FYP schedule case if enough sessions; exactly one winner; loser reason `CLAIM_CONFLICT`; request replay; changed payload; delayed lock; seven write failpoints; claim/cancellation race; verify committed claims/leases/listing/tasks/audits. Preserve evidence; cleanup only test-owned failpoint schema. | Need 10 (prefer 50) distinct authenticated, actually eligible NGOs and isolated fresh listings. Changed-payload/rollback errors need a separate durable failure logger if full rejection audit is required. |
| **7 — Stage 3 recovery + Stage 4 geographic integration** | Review `recover_expired_claims()`, recovery migration, scheduler configuration, road preflight and actual route helpers; set up the approved DEV scheduler/worker only after authorization. Exercise `location_picker_page.dart` → preview RPC → discovery → claim. | Expired idle claim safe release; active route/uncertain custody → reconciliation; lease expiry vs pickup completion; two recovery workers and repeat invocation; old holder rejected; automatic schedule logs/failure alert. Stage4: 500 m and 20 km boundaries, directed asymmetry, disconnected/no route, missing coords, multiple/no eligible NGOs, cache invalidation, discovery/claim consistency. Save DB rows/audit and app screen recording. | Current DEV catalog shows no pg_cron. A worker/scheduler is therefore still a deployment prerequisite; no automatic recovery can be claimed until a worker is configured and invocation evidence exists. |

### Essential sign-off evidence

For each test, save the isolated DEV project reference, migration/object versions compared, synthetic fixture IDs (not personal data), authenticated role, request UUID, expected/actual response, committed donation/listing/claim/lease/task/reservation/inventory rows, and audit rows. Record UTC server timestamps and config version. Save app build identifier and screenshot/video for the demonstrated flow. Never include JWTs, API keys, service-role credentials, or donor addresses in the report.

## G. Remaining blockers and decision points

1. **ACL/default ACL excess:** the actual client grants and default grants need a reviewed DEV-only correction. The current Flutter client appears not to need direct public table writes, but exact deployed function grants/owners should be captured first.
2. **Registration trust-policy change:** automatic technical validation is not the current Flutter/local compatibility behavior. The existing `location_verified_at` field’s meaning must be explained to prevent it being mistaken for NGO identity/presence verification.
3. **Hub Admin onboarding:** no self-service atomic role+hub registration exists; a one-hub unique constraint is absent. Existing duplicate admin assignments have not been counted.
4. **Edit Profile backend:** no authorized update RPC exists. NGO location updates affect cached road eligibility and may interact with teammate-owned vehicle/route assignments; hub capacity/location updates must respect active reservation/inventory commitments.
5. **Recovery scheduler:** DEV has no pg_cron or cron catalog relations. Whether an external worker exists is unknown. No worker means no unattended lease recovery.
6. **Runtime proof:** no Stage 1–4 test runs were performed for this report. Prepared Python and SQL tests may be used only against isolated DEV with explicit allowlisting and approval.
7. **Legacy terminology:** `status_timeline.dart` still maps `VALIDATED` and `DELIVERED`; local recovery/older hub migrations also retain these strings. The latest status check excludes these persisted states, but the final deployed function bodies and historical audit display need a final consistency pass. Do not rewrite historical audit records.
8. **No migration ledger:** cannot identify the exact applied migration sequence from a ledger. Use actual DEV object definition comparisons and preserve separate forward-only migrations.

## H. Recommended first actionable task

**Prepare a DEV-only least-privilege ACL correction package**: verify deployed owner/SECURITY DEFINER/EXECUTE grants for every Flutter RPC, capture exact current relation/sequence/default ACLs, and draft a narrowly scoped correction plus post-check and exact rollback statements. Do not execute it until reviewed and separately approved. This addresses the broadest immediate security concern and establishes a safe baseline for the registration and lifecycle integration tests.

No code, SQL migration, Supabase object, or data was modified or executed for this report. Wait for approval before starting that first task.
