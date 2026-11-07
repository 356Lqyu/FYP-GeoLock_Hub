# Stage 8 Phase C1 v2 DEV post-migration verification

**Overall result: PASS. Conditional read-only sign-off is supported for the installed C1 schema, permissions and preservation checkpoint. Authenticated behavior, concurrency and production readiness are not signed off.**

DEV project `rcgyuwiidqvrgbxswhqj` was confirmed through MCP as `https://rcgyuwiidqvrgbxswhqj.supabase.co` before database inspection. All 32 prepared checks were executed using SELECT-only queries. The only application helper invoked was the audited SQL STABLE catalog-fingerprint function in V08; no fleet mutation RPC or authenticated NGO RPC was called. A supplemental SELECT inventoried the private schema. No other Supabase project was accessed. No migration, record mutation, repair, Flutter/Python service change or C2 work was performed by Codex.

The user reports manual SQL Editor execution succeeded and a PostgreSQL custom-format backup was created beforehand. Backup contents and restore readiness were not independently tested. The local migration remains byte-identical to the pinned SHA256:

```text
f50af9705de117bdd12581f2515605c8e5c548e0fee7ae01d7ea33ecfbb0cb05
```

Verification context: PostgreSQL 17.11, postgres, READ COMMITTED; first observation 24 October 2026 **18:38:30 MYT** (10:38:30 UTC). Queries are separate statements, not an atomic snapshot. Comparison baseline is the fresh supervised preflight from 18:06:48 MYT that day.

## Results for all 32 checks

Each inventory check below is assessed against the authorized v2 changes and preservation rules; it is not required to be byte-identical where C1 deliberately adds objects or removes grants. Assertion checks require the exact row counts and true flags; no empty result was accepted as a missing assertion.

| Check | Result | Evidence/result |
|---|---|---|
| C01 context | PASS | Same database, postgres role, PostgreSQL 17.11, search_path and READ COMMITTED; timestamp changed as expected. |
| C02 columns | PASS | 15 fields: original six definitions preserved, nine intended additions; defaults/nullability match v2. |
| C03 constraints | PASS | 13 captured fleet/route constraints; original 11 unchanged; two new validated vehicle CHECKs match reviewed definitions. |
| C04 ACL/RLS | PASS | Vehicle and route owners/RLS/policies preserved. Vehicle clients lose direct rights; service retains SELECT/INSERT/UPDATE. Only intended route TRUNCATE removals. |
| C05 effective rights | PASS | 24 role/privilege rows match expected permissions; no grant options. |
| C06 counts | PASS | Vehicles, routes, stops, active assignments and nonterminal routes all remain zero. |
| C07 route activity | PASS | Zero route rows and unresolved route activity. |
| C08 vehicle-access function scan | PASS | 11 textual candidates, including expected new helpers/RPCs; old public accessors preserved. Extension VRP textual match is not a public.vehicles writer. |
| C09 catalog dependencies | PASS | 35→75 rows: 40 expected new references, none removed. Added dependents are only the C1 CHECKs, defaults, indexes and triggers. |
| C10 original vehicle values | PASS | Empty before/after; no vehicles created. Preservation of nonempty legacy records is not exercised by this DEV state. |
| C11 managed fleet functions | PASS | Exact set of 14: five public RPCs and nine private helpers. Owner/path/ACLs correct; all bodies and normalized headers match pinned SQL. |
| C12 triggers/indexes | PASS | 11 objects: seven valid indexes and four enabled triggers. Original five objects preserved; exactly three indexes and three triggers added. |
| C13 role capabilities | PASS | Standard role capabilities/memberships unchanged; no new postgres inheritance or replication-trigger disabling ability. |
| C14 vehicle-bearing relations | PASS | Same two relations: vehicles and pickup_routes; no duplicate fleet/reservation table. |
| C15 depot/location routines | PASS | All four existing definitions/ACLs unchanged, including trusted depot derivation and NGO location/verifier/backfill routines. |
| C16 route cron | PASS | No route-related cron found; no automatic route closure added. External workers remain unverified. |
| C17 route row hashes | PASS | Empty before/after; no route records created or changed. |
| C18 assignment row hashes | PASS | Empty before/after; no assignments created or changed. |
| C19 invalid legacy capacity | PASS | Zero invalid rows. |
| C20 private schema | PASS | Exactly the expected fleet_private schema, postgres owner and v2 installation marker. |
| L01 protected objects | PASS | All 712 identity/hash pairs exactly match the fresh pre-migration baseline. |
| V01 expected columns | PASS | 9/9 pass=true. |
| V02 table permissions | PASS | 24/24 pass=true. |
| V03 client column permissions | PASS | 120/120 pass=true. |
| V04 public RPC assertions | PASS | 15/15 pass=true; five expected signatures × three roles, correct owner/definer/path/EXECUTE. |
| V05 private helper isolation | PASS | 27/27 pass=true; schema USAGE/CREATE and helper EXECUTE denied to anon/authenticated/service_role. |
| V06 route TRUNCATE | PASS | 3/3 pass=true. |
| V07 row integrity | PASS | Zero violating rows. |
| V08 installation seal | PASS | 1/1 pass=true; stored marker matches current installed-object fingerprint. |
| V09 trigger bindings | PASS | 4/4 pass=true; original depot trigger and all three intended C1 triggers installed/enabled. |
| V10 new CHECK assertions | PASS | 2/2 pass=true; both validated. |
| V11 private function security | PASS | 9/9 pass=true; postgres owner, SECURITY DEFINER and fixed search_path. |

## Installed definitions and permissions

The new vehicle fields are vehicle_type, fixed_cost_rm, distance_cost_rm_per_km, max_route_duration_min, available_for_planning, vehicle_version, updated_at, registration_request_id and registration_payload. Availability defaults false, version defaults 1 and timestamp defaults clock_timestamp(); the other new fields have no invented operational defaults. Existing payload capacity and ownership keys are unchanged.

The three new indexes match v2: unique owner/request registration key with nonnull-request predicate; owner/activity/vehicle lookup; and busy-route vehicle lookup limited to DRAFT/VALIDATED/AUTHORISED/IN_PROGRESS. The two CHECK definitions enforce the reviewed finite/precision/positive/nonnegative values and complete active-vehicle requirements when planning availability is true.

Vehicles still have RLS enabled, no policies, FORCE false and postgres ownership. Anon/authenticated have no direct table/column access. Service_role retains exactly SELECT/INSERT/UPDATE without grant option and loses DELETE/TRUNCATE/REFERENCES/TRIGGER/MAINTAIN. The route TRUNCATE revocation matches the reviewed scope; other route privileges are unchanged. Existing RLS/owner-bypass assumptions are preserved, not redesigned.

Public RPCs are register_my_vehicle, list_my_vehicles, update_my_vehicle, set_my_vehicle_availability and deactivate_my_vehicle, with their expected argument types. All five have authenticated-only client EXECUTE, postgres ownership and the reviewed fixed pg_catalog,pg_temp path. All nine private helpers deny client/service invocation. Supplemental schema inventory found only those nine functions, no private relations/types/procedures, and schema ACL `{postgres=UC/postgres}`.

All 14 installed function bodies match the reviewed source after newline normalization. Normalized headers/argument and return types, language/volatility and separately asserted security configuration match too. PostgreSQL omits the explicit default VOLATILE keyword in its rendered definition of vehicle_has_hold; the catalog still records provolatile=v, as intended. This is expected formatting, not a migration deviation.

The installation marker is:

```text
geolock-stage8-c1-v2:364bdf2b0f4e413ce0f43d10c56684dc
```

It matches the current installation_fingerprint() result. This is an accidental-drift consistency check, not an adversarial administrator boundary or a substitute for real JWT tests.

## Protected objects and existing data

| Comparison | Before | After | Result |
|---|---:|---:|---|
| Protected object identities/hashes | 712 | 712 | Exact equality; no missing, added or changed protected identity. |
| Vehicles | 0 | 0 | Unchanged. |
| Routes | 0 | 0 | Unchanged. |
| Route stops | 0 | 0 | Unchanged. |
| Active assignments | 0 | 0 | Unchanged. |
| Nonterminal routes | 0 | 0 | Unchanged. |

The protected scope includes existing public lifecycle routine definitions/ACLs, non-fleet public relation/column/constraint/trigger/index/policy metadata, public enum/domain metadata and relevant default ACLs. Donation/listing/claim/lease/hub/pickup routines, including start_pickup, remain unchanged within that captured scope. Authorized vehicle/route changes are checked separately rather than excluded from review. This is object-definition preservation, not a claim that every lifecycle record in the entire database was individually snapshotted.

No unexpected objects or semantic deviations were found in the inspected scopes. Catalog dependencies increased only for the intended two CHECKs, three default expressions, three indexes and three triggers; no captured dependency was removed. Hosted external consumers and arbitrary uninspected namespaces are not certified by this statement.

## Offline comparator/regression results

- Actual before/after catalog comparator: **PASS**, failures=[]; explicitly reports runtime authorization not proven by catalogs.
- Offline routing unit/integration suite: **117 passed in 7.835 seconds**, including the preserved Phase A tests and Phase B comparisons.
- Verification-package/comparator suite: **12 passed in 0.167 seconds**. Its synthetic comparison fixtures test comparator logic, not authenticated DEV behavior.
- Saved Phase B audit: **252 reports independently revalidated**, 84 reproducible scenario/method groups, source manifest verified, all 17 fingerprinted Phase A files preserved. These are saved synthetic benchmark results, not live road-network or production readiness evidence.

The Phase B non-timing digest remains `3591b206c3375792008f17e7d90fd641779c3efba742636a992bddf68ee2cc0a`. No new benchmark performance claim is made. The previous 44 local SQL migration tests were not rerun as migrations during this checkpoint.

## Evidence files

- [All 32 raw check results](dev-postflight-2026-10-24.json).
- [Machine-readable PASS summary](dev-postflight-summary-2026-10-24.json).
- [Fresh pre-migration baseline](supervised-preflight-2026-10-24.json).
- [Installed-source/default/CHECK/index/dependency review](dev-postflight-source-review-2026-10-24.json).
- [Supplemental SELECT-only private-schema inventory](dev-postflight-supplemental-catalog-2026-10-24.json).
- [Offline test outputs and saved-result audit](dev-postflight-offline-tests-2026-10-24.json).

## Remaining limitations and sign-off boundary

**Conditional read-only sign-off: YES**, limited to installed schema/security configuration, exact protected-object preservation, zero-count preservation, seal consistency and offline regression evidence.

Real authenticated NGO A/B ownership isolation, anonymous/donor/inactive behavior, fleet mutation/retry/invalid-input behavior, service-role writes, trigger execution under those calls, actual depot resolver integration and DEV concurrency/rollback races have **not** been tested. No vehicles or routes were created to exercise them. Catalog definitions and prior isolated tests are evidence of intended enforcement, not proof of live authenticated behavior or absence of races.

Pickup completion still does not close routes or clear assignments. Abandoned route holds and historical-stop recovery semantics remain later route-lifecycle work. Emergency held-depot changes have no generic bypass. start_pickup still has the previously identified dispatch-authorization gap. C1 does not establish live routing/dispatch readiness; the later closure/release design is not implemented.

The user-reported custom-format backup was not restored or inspected by Codex. The observations are point-in-time separate SELECTs; subsequent privileged changes can invalidate them. Database administrators remain trusted and able to change guards/ACLs.

Stop here. Authenticated mutation tests require a separately approved controlled test plan. No test writes, lifecycle modifications or Phase C2 work are authorized by this read-only sign-off.
