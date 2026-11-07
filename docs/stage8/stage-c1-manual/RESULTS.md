# Stage C.1 Manual DEV Parity Inspection — Results

**Project:** `rcgyuwiidqvrgbxswhqj`  
**Execution mode:** User-run manually in Supabase Dashboard SQL Editor. Codex does not connect to Supabase.  
**Status:** Manual inspection evidence recorded through Query 11d-2. Codex did not connect to Supabase or execute SQL. The inspected state is not ready for deployment; see the closure summary below.

| Query | Scope | Status | Evidence / notes |
|---|---|---|---|
| 1 | PostgreSQL and extension versions | PASS (platform discovery) | User-provided Dashboard result: PostgreSQL 17.11; database `postgres`; SQL Editor role `postgres`; PostGIS 3.3.7 in `extensions`; pgRouting 3.4.1 in `extensions`; five `pgr_dijkstraCost` overloads, all `SETOF record`, volatility `v`. Exact signatures are recorded below. Stage B.2 version/overload compatibility remains UNKNOWN until its guards and supported contract are compared. |
| 2a | Migration ledger relation/columns | PASS (query execution); UNKNOWN (ledger) | User-provided result: `ledger_relation=NULL`, `has_version=false`, `has_name=false`. Expected ledger is absent or not visible. |
| 2b | Migration inventory | UNKNOWN — unavailable | Skipped because Query 2a found no visible ledger/columns. Historical migration sequence through 20261031 remains UNKNOWN; do not infer migrations were never applied. |
| 3 | `fleet_private` schema/seal/function presence | PASS | Schema, v2 marker and function presence/metadata supplied by user. |
| 4 | Computed C.1 fingerprint | PASS | User supplied computed fingerprint equal to stored v2 seal. |
| 5 | `routing_private` functions/metadata | PASS (schema/inventory summary); MISMATCH (Stage A first-install guard and Stage A 003 helper inventory); UNKNOWN (full parity/upgrade state) | User reports schema owner `postgres`, 15 functions, all owners `postgres`, ACLs `{postgres=X/postgres}`, and consistent session configs. Names match the Stage A 001/002 helper set; Stage A 003's additional private helpers are absent from the reported complete inventory. |
| 6 | `assign_task_to_route` fingerprint/definition | PASS (phase-appropriate body/signature/ACL); MISMATCH only against pre-001 definition hash; UNKNOWN (full Stage A install) | User-reported function signature and source MD5 match the Stage A 003 guard for the post-002 fail-closed body. SHA mismatch is expected across installation phases, not evidence of unexpected modification. |
| 7 | Stage A source and policy prerequisites | PASS (reported lifecycle fingerprints/policy except inspection-query result-type typo); CONFIRMED permission finding; MISMATCH (anonymous pickup grants vs reviewed final contract); UNKNOWN (full Stage A install) | User supplied results below. The Query 7 expected result type for the six-argument donation transition helper was erroneous; repository source declares `void`. |
| 8 | Stage B.2 spatial functions and prerequisites | MISMATCH (correction and service_role ACL); UNKNOWN (extension/runtime compatibility) | Both spatial helper bodies match pre-correction hashes; Query 8 reports service_role EXECUTE, which conflicts with B.2's private-helper guard. |
| 9 | Stage B.4.3 Candidate 2 functions | PASS (presence/metadata); MISMATCH (Candidate 2 bodies absent); UNKNOWN (DEV concurrency behavior) | Both actual hashes equal original pre-correction MD5s; Candidate 2 has not been confirmed in DEV. No live concurrency test was performed. |
| 10 | Effective EXECUTE privileges | MISMATCH (pickup functions); PASS (reported claim/reconciliation/helper boundaries); MISMATCH (Stage A 003 read functions absent); PASS (10/10 intended worker grants and 50/50 unintended grants absent within six-role scope) | Query 10b/10c confirm all three worker roles and all ten expected functions; global isolation beyond these six roles remains UNKNOWN. |
| 11a | RLS flags, constraints, schema markers | PASS (reported schema/table/RLS and corrected count); UNKNOWN (full 35-row exact constraint parity; policy/trigger parity) | User corrected the earlier aggregate summary after Query 11a-3: 11 PK, 15 FK, 6 UNIQUE, 3 CHECK = 35. The six unique names/definitions match Stage A 001. |
| 11b | RLS policies and triggers | OBSERVED (zero policies); PASS (repo policy intent); MISMATCH (`routing_task_authority` absent); PASS (27 returned triggers enabled); UNKNOWN (full definition parity/application effects) | User reports zero policies and Query 11b-2 returns 27 application triggers, none `routing_task_authority`; all 27 are enabled. |
| 11c | Stage A 003 expected function inventory | MISMATCH (14/17 signatures absent); PASS (3 existing functions match expected phase metadata/fingerprints); UNKNOWN (final replacement bodies and privilege boundaries pending) | Ten private helpers and four public functions absent; `start_pickup`, `complete_pickup`, and `submit_claim_reconciliation` present. |
| 11d | Stage A 003 function EXECUTE matrix | TRUNCATED (100/102 rows); MISMATCH (four pickup grants); PASS (13/18 comparisons); UNKNOWN (one preserved reconciliation boundary; two task_guard role checks pending) | Absent functions have NULL privilege results and are classified separately. Query 11d-2 checks all six `task_guard` role combinations. |
| 11d-2 | `routing_private.task_guard()` focused continuation | PASS (6/6 rows returned); MISMATCH (function absent); UNKNOWN (effective EXECUTE for absent function) | No NULL privilege result is classified as a permission mismatch. Together 11d and 11d-2 cover all 102 expected matrix combinations while preserving the original 100-row truncation record. |
| 12 | Coordination policy and aggregate road metadata | UNKNOWN — not run | No coordinates or personal records requested. |

## Query 1 actual result

User-reported output for DEV project `rcgyuwiidqvrgbxswhqj`:

- PostgreSQL `17.11`; database `postgres`; SQL Editor role `postgres`.
- PostGIS `3.3.7`, schema `extensions`.
- pgRouting `3.4.1`, schema `extensions`.
- Five `pgr_dijkstraCost` overloads were found. Each reports `SETOF record`, volatility `v`:
  1. `pgr_dijkstracost(text,anyarray,anyarray,boolean)`
  2. `pgr_dijkstracost(text,anyarray,bigint,boolean)`
  3. `pgr_dijkstracost(text,bigint,anyarray,boolean)`
  4. `pgr_dijkstracost(text,bigint,bigint,boolean)`
  5. `pgr_dijkstracost(text,text,boolean)`

**Classification detail:** PostgreSQL/extension presence and overload discovery are PASS. This is not a Stage B.2 parity PASS: its migration permits either the exact `bigint[],bigint[]` overload or the polymorphic `anyarray,anyarray` overload, but the supplied list includes `anyarray,anyarray`; exact schema signature resolution and all other Stage B.2 source, privilege, road-snapshot and policy guards remain UNKNOWN. The result does not establish whether Stage B.2 was deployed.

## Query 2a actual result

User-provided result: `ledger_relation = NULL`, `has_version = false`, `has_name = false`.

- **PASS:** Query 2a executed and returned the stated catalog visibility result.
- **UNKNOWN:** The expected Supabase migration ledger was not found/visible. The historical sequence through `20261031` remains unverified. Do not infer that migrations were never applied; obtain the relevant release history through an approved evidence source if needed.
- **Query 2b:** skipped because its prerequisite ledger/columns are unavailable; migration inventory remains UNKNOWN.

## Query 3 actual result

User-provided result:

- Schema: `fleet_private`.
- Seal comment: `geolock-stage8-c1-v2:364bdf2b0f4e413ce0f43d10c56684dc`.
- `fleet_private.installation_fingerprint()` exists; owner `postgres`; SECURITY DEFINER; volatility `s` (STABLE); `search_path=pg_catalog, pg_temp`; ACL `{postgres=X/postgres}`.
- Function `prosrc` MD5: `d5164138c28a4dab30e1bfd49c2210e1`.

Classifications:

- **PASS:** `fleet_private` schema presence.
- **PASS:** expected `geolock-stage8-c1-v2` seal marker format.
- **PASS:** fingerprint function presence.
- **PASS:** computed installation fingerprint: `364bdf2b0f4e413ce0f43d10c56684dc`.
- **PASS:** computed fingerprint matches the stored v2 installation seal.
- **PASS:** Stage C.1 `fleet_private` fingerprint prerequisite.
- **UNKNOWN:** function-body parity until its reported MD5/definition is compared against the approved C.1 baseline.

## Query 4 safety review

The prepared Query 4 is a `SELECT` that calls `fleet_private.installation_fingerprint()` twice and reads the schema comment via `obj_description`. The reviewed local function definition in `docs/stage8/phase-c1/proposed_migration_v2.sql` declares it `LANGUAGE sql STABLE SECURITY DEFINER` with `search_path=pg_catalog,pg_temp`. Its body computes an MD5 from read-only catalog queries over `pg_class`, `pg_attribute`, `pg_constraint`, `pg_index`, `pg_proc`, `pg_namespace`, and `pg_trigger`, using catalog description helpers. It contains no DML, DDL, dynamic SQL, or application RPC call and does not read or modify application rows. On the supplied role metadata, the function ACL is owner-only and Query 3 reports the SQL Editor role as `postgres`. **Safety review: PASS for the intended C.1 fingerprint inspection.** The user manually executed Query 4; Codex did not.

## Query 4 actual result

User-provided result:

- Computed fingerprint: `364bdf2b0f4e413ce0f43d10c56684dc`.
- Stored seal comment: `geolock-stage8-c1-v2:364bdf2b0f4e413ce0f43d10c56684dc`.
- `seal_matches = true`.

Classifications:

- **PASS:** computed `fleet_private` installation fingerprint.
- **PASS:** computed fingerprint matches the stored v2 installation seal.
- **PASS:** Stage C.1 fingerprint prerequisite for Stage A.
- **UNKNOWN:** full Stage A deployment readiness; its other migrations, functions, privileges, policies, triggers, and dependencies remain uninspected.

## Query 5 actual result

User-provided inventory summary:

- `routing_private` exists; owner `postgres`.
- 15 functions found: `actor_lock`, `admissible`, `append_only`, `arc`, `freeze_network`, `hash`, `lock_sources`, `network_digest`, `ngo_observation`, `observe_task`, `snapshot_guard`, `snapshot_task`, `task_digest`, `task_window`, and `worker`.
- All reported function owners are `postgres`; all reported ACLs are `{postgres=X/postgres}`.
- Function configurations consistently include `search_path=pg_catalog, pg_temp`, `TimeZone=UTC`, and `extra_float_digits=0`.

Comparison and classifications:

- **PASS:** The reported schema/function-name inventory matches the helper set created by the reviewed Stage A 001 authority and 002 publication artifacts. This is inventory/name-level parity only.
- **MISMATCH:** Stage A 001's documented first-install precondition rejects an already-existing `routing_private` schema. The approved Stage A first-install package is therefore not directly applicable to this state.
- **UNKNOWN:** Exact per-function signatures, result types, volatility, `proconfig` arrays, body MD5s, dependencies and full ACL details were not supplied row-by-row. Ownership and ACL summary alone do not establish parity.
- **UNKNOWN:** Whether this is an exact completed 001+002 installation or an older/partial/modified installation. The 15 names align with 001+002; Stage A 003 introduces additional `routing_private` functions (`lock_route`, `close_collected`, `task_guard`, `check_remaining`, legacy pickup wrappers and reconciliation helpers), none of which appear in the reported inventory. This strongly suggests 003 is absent or incomplete, but the exact package phase is not proved without full catalog results, table/type/trigger state and migration/release evidence.
- **Blocker:** Stage A README states that an existing `routing_private` schema requires a separately designed upgrade. Do not rerun the first-install package or assume 003 can safely be applied without a phase-specific upgrade review.

## Query 6 actual result

User-provided result:

- Signature `assign_task_to_route(uuid,uuid,integer)`; identity arguments `p_route uuid, p_task uuid, p_stop_order integer`; return `void`.
- Owner `postgres`; SECURITY DEFINER; volatility `v`.
- Configuration: `search_path=pg_catalog, pg_temp`, `TimeZone=UTC`, `extra_float_digits=0`.
- Body MD5 `047f2b5d6a4483b8cef8e3b91c9dc299`.
- Definition SHA-256 `18a5d20d86c6e1cf70beafab30356c1323cfaa5086b691c292b2553b56488dcd`.
- ACL `{postgres=X/postgres}`.
- Body raises `VALIDATED_ROUTE_PUBLICATION_REQUIRED`.

Comparison:

- **PASS:** function exists with expected signature and the reported owner/security/configuration contract; ACL is restricted to `postgres` in the supplied output.
- **PASS:** body rejects direct task assignment, matching the Stage A 002 fail-closed replacement in `docs/stage8/stage-a/forward-migrations/20261102_routing_publication.sql` around line 180.
- **PASS (phase-appropriate MD5):** actual body MD5 `047f2b5d6a4483b8cef8e3b91c9dc299` is the post-publication source fingerprint guarded by Stage A 003 at `docs/stage8/stage-a/forward-migrations/20261103_routing_pickup_and_reconciliation.sql` around line 36.
- **Expected phase difference, not unexpected modification:** Stage A 001's SHA-256 `0341fd334439b319b0bc78b8910ce2de5e2f51b5803ab4a53d0e0e89b50e11cf` is a pre-001 definition guard in `20261101_routing_authority.sql` around line 33. Stage A 002 intentionally replaces that body, so the deployed SHA-256 `18a5...` should differ. The post-002 body text, MD5, metadata, and restricted ACL are consistent with the reviewed phase. The evidence does not indicate an unexpected hash drift.
- **MISMATCH against Stage A 003's expected function inventory:** Query 5's reported exhaustive 15-function list does not include the 10 private functions created by Stage A 003: `lock_route`, `close_collected`, `task_guard`, `check_remaining`, `legacy_start_pickup`, `legacy_complete_pickup`, `reconciliation_participant`, `lock_reconciliation_scope`, `permit_reconciled_collection`, and `finish_reconciled_collection`.
- **UNKNOWN:** Overall Stage A completion and exact 001/002 function-body parity. Query 6 shows the post-002 assignment replacement and Query 7 shows expected pre-003 lifecycle bodies, jointly supporting that 001/002 are present and 003 is absent/incomplete. Table/type/trigger inventory and per-function hashes are still needed to establish the precise existing state.

## Query 7 actual result

### Part A — Lifecycle functions

User-reported fingerprints:

| Function | Expected MD5 | Actual MD5 | Result/notes |
|---|---|---|---|
| `public.claim_listing(uuid,uuid)` | `2c1f60c876797c61b44b3cb43591bab8` | same | `matches_stage_a_precondition=true`; reported ACL: `postgres`, `authenticated`, `service_role`. |
| `public.complete_pickup(uuid,boolean)` | `ae1b885377292281da17951cb18afd55` | same | `matches_stage_a_precondition=true`; ACL includes `anon EXECUTE`. |
| `public.geolock_transition_listing_donations(uuid,text,text,uuid,uuid,text)` | `67f27a85fb9129c9017bb0e9178f8ba1` | same | `matches_stage_a_precondition=false` only because the prepared Query 7 incorrectly expected result type `boolean`; actual result is `void`, which is what the source migration declares. |
| `public.recover_expired_claims(integer)` | `89e01f42d5ec23bfcbcdc47c1f4fd4e5` | same | `matches_stage_a_precondition=true`; reported ACL: `postgres`, `service_role`. |
| `public.start_pickup(uuid)` | `e89b650c83713b04e8310f4c372f10f4` | same | `matches_stage_a_precondition=true`; ACL includes `anon EXECUTE`. |
| `public.submit_claim_reconciliation(uuid,boolean,uuid)` | `246a33d552da2ac4e229fa79c357d194` | same | `matches_stage_a_precondition=true`; reported ACL: `postgres`, `authenticated`, `service_role`. |

All six were reported owned by `postgres`; the expected source hashes match. The actual configs/security settings were not repeated row-by-row in the supplied summary, so retain the user's reported `matches_stage_a_precondition` values while treating exact per-function metadata as only as complete as the pasted result.

### Result-type investigation

**CONFIRMED — inspection-query defect, not a database prerequisite mismatch.** The six-argument helper definition in `supabase/migrations/20261031_claim_audit_and_failure_capture.sql:137-140` declares `RETURNS void`. The Stage A 001 and 003 guards in `docs/stage8/stage-a/forward-migrations/20261101_routing_authority.sql:23-27` and `20261103_routing_pickup_and_reconciliation.sql:24-29` check its signature, owner, invoker mode, `search_path`, body MD5 and ACL restrictions; they do not require a boolean return type. The prepared Query 7 had the wrong expected result type and falsely made `matches_stage_a_precondition` false. [READ_ONLY_QUERIES.sql](READ_ONLY_QUERIES.sql) has been corrected for future reference; no database object was changed. This helper's actual return type is therefore **PASS** against the reviewed source/guard.

### Pickup EXECUTE grants

**CONFIRMED — current permission-contract mismatch:** the user reports that both `public.start_pickup(uuid)` and `public.complete_pickup(uuid,boolean)` grant `EXECUTE` to `anon`, and both are SECURITY DEFINER. Stage A 003 explicitly revokes from `PUBLIC`, `anon`, `authenticated`, and `service_role`, then grants these functions only to `authenticated` (`docs/stage8/stage-a/forward-migrations/20261103_routing_pickup_and_reconciliation.sql:211-212`). The reported grants therefore do not meet the reviewed final authorization contract. **NOT VERIFIED:** whether an anonymous invocation could change state; no RPC was executed, and this inspection does not establish internal `auth.uid()` rejection behavior. Treat the callable SECURITY DEFINER surface as a security concern requiring source-level review and a separately approved remediation decision.

### Part B — Coordination configuration

User-reported singleton policy: `claim_lease_minutes=360`, `donation_direct_min_kg=10.000`, `geofence_radius_m=20000`, `config_version=v2.0`.

**PASS:** all three coordination policy values match the Stage A prerequisite. Config version was recorded as supplied; no expected-version contract was inferred beyond the reviewed migration guards.

### Stage A phase assessment

The observed helper set and `assign_task_to_route` replacement support the hypothesis that Stage A 001/002 objects are present. The six lifecycle source hashes also match the expected pre-003 inputs, and the reported exhaustive private-function list omits the 10 private helpers Stage A 003 creates. This is a **MISMATCH against Stage A 003's expected postcondition** and indicates that 003 is absent/incomplete or the installation diverges. The existing `routing_private` schema blocks the Stage A first-install package; there is no established safe upgrade path in the reviewed README. **UNKNOWN:** whether all tables, types, guards, triggers and other 003 dependencies are absent or partially present, and whether a compatible upgrade can be designed. Do not infer safe deployability from matching source hashes alone.

## Query 8 actual result

### Part A — Spatial helpers

User-provided result:

| Function | Actual MD5 | Expected pre-correction | Reviewed B.2 MD5 | Body status | Metadata |
|---|---|---|---|---|---|
| `public.geolock_resolve_road_node(double precision,double precision)` | `9701683fdcfeb2486c887860c6470262` | same | `3e2ae3b624e0276110b5029231671df0` | `PRE-CORRECTION` | metadata matches; owner `postgres`; SECURITY DEFINER; STABLE; ACL reported `postgres`, `service_role`. |
| `public.geolock_road_costs(bigint[],bigint[],double precision,double precision,double precision)` | `828217e0b8faeeb3d32fa726b3e06a2a` | same | `53bac7e143510f560006bb641024c1a3` | `PRE-CORRECTION` | metadata matches; owner `postgres`; SECURITY DEFINER; VOLATILE; ACL reported `postgres`, `service_role`. |

- **PASS:** both functions exist and their reported metadata matches the reviewed contract.
- **MISMATCH:** both functions remain at pre-correction bodies; Stage B.2 helper correction is not present in the inspected DEV state.
- **MISMATCH:** reported ACL/effective privilege grants `service_role` EXECUTE on both helpers; the B.2 migration guard excludes `service_role` as well as `anon` and `authenticated` from these private spatial helpers.
- **UNKNOWN:** whether the reviewed Stage B.2 function changes are compatible with the DEV extension versions; no DEV runtime test or migration execution was performed.

### Parts B/C — Extensions and pgRouting overloads

User-reported: PostGIS `3.3.7`, pgRouting `3.4.1`, both in `extensions`; five `pgr_dijkstraCost` overloads, all returning `SETOF record` and marked VOLATILE. The required polymorphic many-to-many signature `text,anyarray,anyarray,boolean` is present.

- **PASS:** required extensions and compatible overload shape are present for the B.2 migration's catalog preflight.
- **UNKNOWN:** runtime compatibility. Local B.2 evidence used PostGIS `3.6.2` and pgRouting `4.0.1`; presence of a matching overload does not establish execution parity across versions.
- **NOT VERIFIED:** whether B.2 migration was ever applied historically. Current helper body hashes show the proposed correction is not currently installed; they do not prove migration history or any past apply/rollback.

## Query 9 actual result

User-provided result:

| Function | Actual MD5 | Pre-correction MD5 | Candidate 2 MD5 | Metadata |
|---|---|---|---|---|
| `public.claim_listing(uuid,uuid)` | `2c1f60c876797c61b44b3cb43591bab8` | same | `c8d324772b12c843fba231e7ea733914` | matches; owner `postgres`; SECURITY DEFINER; VOLATILE; `jsonb`; ACL reported `postgres`, `authenticated`, `service_role`. |
| `public.geolock_lock_listing_donations(uuid,text[])` | `90816e7c6db3606dc8b6451a899d8036` | same | `e97a3fd80673a827465f3eaa79b65903` | matches; owner `postgres`; invoker; VOLATILE; `boolean`; ACL reported `postgres` only. |

- **PASS:** both functions exist and reported metadata matches expected contracts.
- **MISMATCH:** both functions remain at the original pre-Candidate-2 bodies; Candidate 2 correction is not present in the inspected DEV state.
- **UNKNOWN:** whether the concurrency issue reproduces in DEV. No live concurrency test was performed or authorized.
- The body fingerprints establish current body state, not migration ledger history or whether the correction was applied and later reverted.

## Query 10 actual result

User-provided effective EXECUTE results:

| Function group | Reported effective permissions | Classification |
|---|---|---|
| `public.start_pickup(uuid)` and `public.complete_pickup(uuid,boolean)` | `anon=true`, `authenticated=true`, `service_role=true`; all three Stage A worker roles false | **MISMATCH:** reviewed Stage A 003 revokes from PUBLIC/anon/authenticated/service_role, then grants authenticated only. The anon and service_role effective grants contradict that target boundary. Whether anonymous invocation passes internal authorization is **UNKNOWN**; no RPC was called. |
| `public.claim_listing(uuid,uuid)` and `public.submit_claim_reconciliation(uuid,boolean,uuid)` | anon false; authenticated/service_role true | **PASS:** anon is excluded, consistent with the reported intended role boundary. |
| `public.geolock_resolve_road_node(...)` and `public.geolock_road_costs(...)` | anon/authenticated false; service_role true | **MISMATCH:** Stage B.2 explicitly rejects EXECUTE for anon, authenticated, and service_role on both private spatial helpers. |
| `public.assign_task_to_route(uuid,uuid,integer)` | All six roles false | **PASS** for the Stage A 002 fail-closed entrypoint's client/service/worker restriction. |
| `public.geolock_lock_listing_donations(...)` and six-argument `geolock_transition_listing_donations(...)` | All six roles false | **PASS** for owner-only/private helper expectations. |
| `public.authorize_my_routing_candidate(uuid,uuid,timestamptz)` | anon false; authenticated true; service_role and all worker roles false | **PASS** for the Stage A 002 authenticated-only caller boundary. |
| `public.get_my_routing_overview()` and `public.get_my_authorized_route(uuid)` | NULL for all six roles | **MISMATCH against Stage A 003 expected objects:** the reviewed file defines these exact signatures and grants authenticated only. The NULLs indicate the signatures were not found by the query, not merely denied. |

All three worker roles returned false for the functions included in Query 10. This does not establish overall worker-privilege parity: Stage A 001 grants worker-specific functions that Query 10 did not include. **UNKNOWN** pending those exact role/function checks. The SQL query's 72 combinations are recorded as user-reported; only the summarized results above were supplied.

## Stage A 003 and package completeness update

Repository comparison confirms `docs/stage8/stage-a/forward-migrations/20261103_routing_pickup_and_reconciliation.sql` defines `public.get_my_routing_overview() RETURNS jsonb` and `public.get_my_authorized_route(uuid) RETURNS jsonb`, then revokes from PUBLIC/anon/authenticated/service_role and grants both to `authenticated` (around lines 215–266). Query 10's NULL results therefore confirm these expected signatures are absent in the inspected state. The same migration revokes pickup function access from PUBLIC/anon/authenticated/service_role and grants only authenticated (lines 211–212); the reported effective anon and service_role permissions are a confirmed contract mismatch.

Worker grants reviewed in `20261101_routing_authority.sql` include graph-worker access to `install_routing_policy(uuid,jsonb)`, `freeze_routing_graph(uuid,text,text,text)`, `store_routing_matrix(uuid,uuid,jsonb)`, and `read_frozen_routing_graph(uuid,bigint,integer)`; planner access to `read_routing_snapshot_bundle(uuid)`, `read_pending_routing_snapshot(uuid)`, `seal_routing_snapshot(uuid,uuid)`, and `submit_routing_candidate(uuid,uuid,jsonb)`; validator access to `read_routing_work_item(uuid)` and `attest_routing_candidate(uuid,text,jsonb)`. These functions were not all included in Query 10, so worker grants remain unverified. Stage A 003 also introduces a `routing_task_authority` trigger on `public.pickup_tasks`; Query 11 must inspect its presence/enabled state and the related private tables, constraints and policies.

## Query 11a actual result

User-provided schema marker result:

- `fleet_private` owner `postgres`, seal `geolock-stage8-c1-v2:364bdf2b0f4e413ce0f43d10c56684dc`.
- `routing_private` owner `postgres`, schema comment `NULL`.

The reviewed Stage A artifacts do not define a `routing_private` schema comment marker. Therefore its NULL comment is **EXPECTED**, not a mismatch. The fleet seal is consistent with the previously verified Query 4 result.

User-provided table inventory:

- All 18 requested public tables are present.
- All 11 expected Stage A authority tables in `routing_private` are present: `bindings`, `cancelled_stop_history`, `candidates`, `graphs`, `items`, `legacy_inflight`, `matrices`, `policies`, `requests`, `snapshots`, `validations`.
- All 29 returned tables have RLS enabled; none have FORCE RLS enabled.

Classifications:

- **PASS:** schema presence and the expected `fleet_private` v2 seal.
- **PASS:** reported presence of all requested public tables and all 11 Stage A 001 routing tables; RLS is enabled on all 29 returned tables.
- **EXPECTED:** NULL comment on `routing_private`; no Stage A routing-schema comment marker is defined in the reviewed migrations.
- **UNKNOWN:** full Stage A table/column/index/constraint/RLS-policy/trigger parity. RLS enabled is not equivalent to policy parity; FORCE RLS is not required by the reviewed table creation loop.
- **PASS:** the dedicated Query 11a-2 returned the corrected complete private constraint count; the original broad output was display-truncated and is not used as a complete inventory.

## Query 11a-2 / 11a-3 actual results and correction record

The initial Query 11a-2 summary supplied by the user stated 37 rows with 8 UNIQUE constraints. The later Query 11a-3 result returned exactly six private UNIQUE constraints. The user then corrected the Query 11a-2 aggregate: **35 constraints total** across the 11 private tables, consisting of 11 primary keys, 15 foreign keys, 6 unique constraints, and 3 check constraints. The initial 37/8 count was an aggregate reporting error and is superseded; no database data changed.

Query 11a-3 returned these six validated constraints:

| Constraint | Definition | Stage A 001 comparison |
|---|---|---|
| `candidates_request_id_key` | `UNIQUE (request_id)` | Match |
| `graphs_request_id_key` | `UNIQUE (request_id)` | Match |
| `items_route_id_ordinal_key` | `UNIQUE (route_id, ordinal)` | Match |
| `matrices_request_id_key` | `UNIQUE (request_id)` | Match |
| `policies_request_id_key` | `UNIQUE (request_id)` | Match |
| `snapshots_ngo_id_request_id_key` | `UNIQUE (ngo_id, request_id)` | Match |

Repository comparison against `docs/stage8/stage-a/forward-migrations/20261101_routing_authority.sql:63-112` finds these are exactly the six UNIQUE constraints declared for the private tables. Stage A 002/003 do not add routing_private table constraints.

- **PASS:** corrected count matches the repository expectation: 11 PK + 15 FK + 6 UNIQUE + 3 CHECK = 35.
- **PASS:** all six UNIQUE definitions/names supplied match Stage A 001; all six are validated.
- **UNKNOWN:** exact definitions and names of all remaining 29 constraints were not supplied, so full exact parity of all 35 constraints is not established yet.
- **Audit correction:** the prior report's “two additional unique constraints” finding is withdrawn. It resulted from the superseded 37/8 summary, not a verified database mismatch.

The two reported unvalidated constraints, `public.donations.donations_description_length` and `public.donations.donations_title_length`, are present as `NOT VALID` in the local public schema snapshot (`geolock-v3-public-schema.sql:3153-3157` and `3168-3173`) and are added `NOT VALID` by `supabase/migrations/20261018_donation_photo_and_availability_transition.sql:229-236`. Their `convalidated=false` state is **EXPECTED against the reviewed repository baseline**, not evidence of migration drift by itself. Whether existing rows violate them is outside this read-only catalog inspection and has not been checked.

## Query 11b actual results

### Part 1 — RLS policies

The user reports that the policy query executed successfully and returned no rows for the specified public coordination/routing tables and all policies under `fleet_private` and `routing_private`.

Repository comparison: the reviewed Stage A 001/002/003 migrations do not create policies on the inspected routing authority tables/private schemas. Stage A 001 enables RLS on its private tables and removes client/service-role schema access; it does not create policies (`docs/stage8/stage-a/forward-migrations/20261101_routing_authority.sql:116-124`). Earlier public migration `CREATE POLICY` statements target donation/batch image or `storage.objects` surfaces, not the inspected coordination/routing tables. Thus zero policies is **consistent with the reviewed repository DDL** for this scope. It does not prove the live database has every expected policy on out-of-scope tables.

- **OBSERVED:** zero policies returned for the query's specified scope.
- **PASS (repository intent comparison):** no policies are declared for the inspected coordination/routing tables or private routing schemas in the reviewed migrations.
- **REVIEW REQUIRED:** RLS-enabled tables with no applicable policy deny direct row access under ordinary roles; the app's actual access through RPCs and privileged paths is not established by catalog inspection alone.
- **UNKNOWN:** whether any application operation is affected; no app operations or RPCs were executed.

### Part 2 — broad trigger inventory

The user reports exactly 100 rows, ending at `public.listings / trg_listing_transition`: 90 internal triggers and 10 application-defined triggers, all with `tgenabled='O'`. The result is truncated by the SQL Editor display cap and stops before `public.pickup_tasks`.

- **OBSERVED:** 100 returned rows; 90 internal, 10 application-defined; all returned triggers enabled; final visible row is `public.listings/trg_listing_transition`.
- **INCOMPLETE:** this broad output is not a complete trigger inventory.
- **UNKNOWN (not absent):** `routing_task_authority` status. The output ended before the relevant `pickup_tasks` section, so it must not be classified absent.

The reviewed trigger is declared in `docs/stage8/stage-a/forward-migrations/20261103_routing_pickup_and_reconciliation.sql:131-132` as a `BEFORE UPDATE OF task_status` trigger on `public.pickup_tasks`, invoking `routing_private.task_guard()`. The migration's checks also require it enabled (`20261103...sql:221` and `:357`). A targeted application-trigger-only query has been added as **Query 11b-2** in `READ_ONLY_QUERIES.sql`; it filters `NOT t.tgisinternal`, covers `pickup_tasks` and all listed Stage A public/private routing tables, and returns trigger function plus trigger definition. It is pending user execution.

**Safety:** Query 11b-2 is a SELECT over `pg_trigger`, `pg_class`, `pg_namespace`, and `pg_proc`. It returns catalog definitions only, excludes internal FK/system triggers, and reads no application records or state. Codex did not execute it.

## Query 11b-2 actual results

The user reports 27 application-defined triggers across `public` and `routing_private`. Every returned row has `tgisinternal=false` and `tgenabled='O'`. The trigger list includes:

- `c1_route_vehicle_guard` on `pickup_routes`.
- `c1_vehicle_audit` and `zz_c1_vehicle_guard` on `vehicles`.
- `routing_graph_freeze` and `routing_graph_truncate` on each of `road_network_coverage`, `road_network_nodes`, and `road_network_edges`.
- `routing_private` append-only/immutability triggers and `snapshot_seal_guard`.
- Existing donation, listing, and hub guards.

The complete 27-row output contains no `routing_task_authority` trigger on `public.pickup_tasks`; unlike the earlier broad query, this targeted query included `pickup_tasks`, excluded internal triggers, and was not reported truncated.

- **MISMATCH (CONFIRMED against reviewed Stage A 003):** expected `routing_task_authority` is absent. Stage A 003 creates it as a `BEFORE UPDATE OF task_status` trigger on `public.pickup_tasks`, calling `routing_private.task_guard()` (`docs/stage8/stage-a/forward-migrations/20261103_routing_pickup_and_reconciliation.sql:131-132`). The migration also asserts its existence and enabled state at lines 221 and 357.
- **PASS:** all 27 returned application-defined triggers are enabled (`tgenabled='O'`).
- **PASS (presence only):** the listed route/vehicle guards, graph freeze triggers, private append-only/snapshot guards, and existing donation/listing/hub guards are present.
- **UNKNOWN:** exact trigger-definition parity for all 27 because the user supplied the summary rather than row-by-row function/definition output. Absence of the task-authority trigger is directly reported by the complete targeted result.
- **NOT VERIFIED:** whether an unauthorized task-status write is exploitable or can cause state changes. No write/RPC was attempted, and no exploitability conclusion is drawn.

### Additional Stage A 003 object gaps

The earlier Query 5 user-reported exhaustive `routing_private` inventory contained 15 functions and did not include the ten private helper functions defined by Stage A 003: `lock_route(uuid,boolean)`, `close_collected(uuid)`, `task_guard()`, `check_remaining(uuid,uuid,timestamptz)`, `legacy_start_pickup(uuid)`, `legacy_complete_pickup(uuid,boolean)`, `reconciliation_participant(uuid)`, `lock_reconciliation_scope(uuid)`, `permit_reconciled_collection(uuid)`, and `finish_reconciled_collection(uuid)`. Query 10 also found Stage A 003's `public.get_my_routing_overview()` and `public.get_my_authorized_route(uuid)` signatures absent. The missing trigger additionally depends on `routing_private.task_guard()`. Together these reported absences are a **MISMATCH against Stage A 003's reviewed postcondition**, though migration history remains unavailable and no inference is made about how/when the state arose.

The Stage A 003 file contains one explicit application trigger creation (`routing_task_authority` at lines 131-132); no other `CREATE TRIGGER` declaration appears in that migration. Its helper functions, public routing read functions, lifecycle wrappers and authorization grants are separate expected objects and are not triggers.

### Next manual check

Query 10b has been added to `READ_ONLY_QUERIES.sql` to inspect the ten exact Stage A 001 worker functions and effective `EXECUTE` privilege for `geolock_graph_worker`, `geolock_planner`, and `geolock_validator`. It uses `to_regprocedure` and `has_function_privilege` over catalog-resolved roles/functions only. Missing roles/functions yield NULL for interpretation; it performs no DDL, DML, RPC, or application-row reads. Pending user execution.

## Query 10b actual results

The user reports exactly ten rows. All three expected roles exist; all ten expected signatures exist; and all ten intended effective `EXECUTE` grants are true:

- `geolock_graph_worker`: 4/4 (`freeze_routing_graph`, `install_routing_policy`, `read_frozen_routing_graph`, `store_routing_matrix`).
- `geolock_planner`: 4/4 (`read_pending_routing_snapshot`, `read_routing_snapshot_bundle`, `seal_routing_snapshot`, `submit_routing_candidate`).
- `geolock_validator`: 2/2 (`attest_routing_candidate`, `read_routing_work_item`).

- **PASS:** all three expected Stage A 001 worker roles exist.
- **PASS:** all ten inspected functions exist under the expected signatures.
- **PASS:** all ten intended effective grants are present.
- **UNKNOWN:** whether `anon`, `authenticated`, `service_role`, or other worker roles also have effective EXECUTE on these functions; Query 10b only checked intended pairs.
- **UNKNOWN:** full worker-role isolation pending Query 10c and any other role memberships/privilege paths outside the tested set.

Query 10c is prepared in `READ_ONLY_QUERIES.sql`: it checks all ten functions against `anon`, `authenticated`, `service_role`, and all three worker roles, reports role/function presence separately, and labels the intended worker role per function. The query is catalog-only and pending user execution.

## Query 10c actual results

The user reports 60 rows (10 functions × 6 roles); all role and function presence checks are true. All ten intended grants are true, and all 50 unintended combinations are false. This includes `anon`, `authenticated`, `service_role`, and the other two worker roles for each function.

- **PASS:** all 60 effective `EXECUTE` results match the expected six-role/function matrix.
- **PASS:** all ten intended worker grants are present.
- **PASS:** all 50 unintended grants are absent among the six inspected roles.
- **UNKNOWN:** effective access through roles outside the six-role inspection scope. Do not claim global privilege isolation or complete Stage A readiness from this query.

The next completeness check is Query 11c in `READ_ONLY_QUERIES.sql`. It compares the 17 function signatures declared or replaced by Stage A 003 (ten private helpers and seven public lifecycle/read/reconciliation functions) with DEV catalog presence and reports owner, security mode, volatility, result type, configuration, ACL, and body MD5. It does not invoke any function. It can confirm missing signatures and metadata drift, but body parity still requires comparison against reviewed source definitions and phase-aware hashes.

## Query 11c actual results

The user reports all 17 signatures returned: 3 present and 14 absent. All ten `routing_private` helpers are absent: `lock_route(uuid,boolean)`, `close_collected(uuid)`, `task_guard()`, `check_remaining(uuid,uuid,timestamptz)`, `legacy_start_pickup(uuid)`, `legacy_complete_pickup(uuid,boolean)`, `reconciliation_participant(uuid)`, `lock_reconciliation_scope(uuid)`, `permit_reconciled_collection(uuid)`, and `finish_reconciled_collection(uuid)`. Four public functions are absent: `close_my_collected_route(uuid,boolean)`, `cancel_my_unstarted_route(uuid)`, `get_my_routing_overview()`, and `get_my_authorized_route(uuid)`.

The three present public functions were reported owned by `postgres`, SECURITY DEFINER, VOLATILE, with expected result types:

| Function | Reported body MD5 | Phase-aware repository comparison | Reported ACL |
|---|---|---|---|
| `public.start_pickup(uuid)` | `e89b650c83713b04e8310f4c372f10f4` | Matches Stage A 003's required pre-replacement source guard; 003 is expected to replace this body. | `postgres, anon, authenticated, service_role` |
| `public.complete_pickup(uuid,boolean)` | `ae1b885377292281da17951cb18afd55` | Matches Stage A 003's required pre-replacement source guard; 003 is expected to replace this body. | `postgres, anon, authenticated, service_role` |
| `public.submit_claim_reconciliation(uuid,boolean,uuid)` | `246a33d552da2ac4e229fa79c357d194` | Matches Stage A 003's explicit source/security precondition at `20261103_routing_pickup_and_reconciliation.sql:345-350`; the replacement declaration is at lines 492-496. | `postgres, authenticated, service_role` |

- **MISMATCH:** 14/17 expected Stage A 003 signatures are absent. The trigger `routing_task_authority` is also absent per Query 11b-2.
- **PASS (existing-state/precondition only):** the three reported functions exist with expected owner/security/volatility/result metadata and hashes at their observed installation phase.
- **MISMATCH:** the two pickup functions still have reported `anon` and `service_role` ACL entries. Stage A 003's final permission boundary is authenticated-only for pickup/route lifecycle functions (`20261103...sql:211-212`).
- **PASS (precondition fingerprint):** the reconciliation function matches the reviewed Stage A 003 required source MD5; this does not establish final grants or the rest of Stage A 003.
- **UNKNOWN:** complete final-body parity for functions absent from DEV, and full expected metadata/ACL parity for the absent objects.

### Deployment preconditions and blockers

The Stage A README says these files are forward review artifacts, their filenames are proposed order rather than applied migration history, and an existing `routing_private` schema requires a separately designed upgrade (`docs/stage8/stage-a/README.md:32`). Stage A 003 itself says it requires 001 and 002, enforces exact lifecycle/helper source fingerprints and coordination configuration before changes, and takes a `SHARE ROW EXCLUSIVE` lock on `public.pickup_tasks` to drain old task writers before legacy in-flight capture (`20261103_routing_pickup_and_reconciliation.sql:1-44`). The missing functions/trigger plus existing schema mean the reviewed first-install package cannot be presumed safe to apply in place. The historical migration ledger remains unavailable, and no exact deployed-state manifest or approved upgrade path has been established.

**Deployment blockers:** (1) no separately reviewed upgrade package for the already-existing `routing_private`; (2) Stage A 003 postconditions are materially absent; (3) pickup EXECUTE grants do not match the final contract; (4) migration-history evidence is unavailable; (5) the exact full prerequisite object/function/trigger fingerprints have not all been proven. Do not deploy the review artifacts directly or infer that matching source guards alone establishes safe in-place upgrade readiness.

Query 11d is prepared to inspect effective `EXECUTE` across the six Stage A 003 public functions, the preserved reconciliation function, and the ten private helpers against `anon`, `authenticated`, `service_role`, and the three worker roles. It labels documented intended grantees separately and reports role/function presence. It is catalog-only and pending user execution.

## Query 11d actual results

The user reports the SQL Editor returned 100 of the expected 102 rows, truncating during `routing_private.task_guard()`. The output is **TRUNCATED** and must not be treated as a complete matrix. All six roles exist. The three present public functions are `start_pickup`, `complete_pickup`, and `submit_claim_reconciliation`; the other fourteen expected Stage A 003 functions remain absent. For absent functions, `can_execute=NULL` reflects missing functions, not a privilege mismatch.

For the three present functions, the user reports 13 permission comparisons match expectations, four mismatch, and one unknown:

| Function / role | Actual effective EXECUTE | Expected | Classification |
|---|---:|---:|---|
| `start_pickup(uuid)` / `anon` | true | false | **MISMATCH** |
| `start_pickup(uuid)` / `service_role` | true | false | **MISMATCH** |
| `complete_pickup(uuid,boolean)` / `anon` | true | false | **MISMATCH** |
| `complete_pickup(uuid,boolean)` / `service_role` | true | false | **MISMATCH** |
| `submit_claim_reconciliation(uuid,boolean,uuid)` / `authenticated` | true | true | **PASS** |
| `submit_claim_reconciliation(uuid,boolean,uuid)` / `anon` | false | false | **PASS** |
| `submit_claim_reconciliation(uuid,boolean,uuid)` / `geolock_graph_worker` | false | false | **PASS** |
| `submit_claim_reconciliation(uuid,boolean,uuid)` / `geolock_planner` | false | false | **PASS** |
| `submit_claim_reconciliation(uuid,boolean,uuid)` / `geolock_validator` | false | false | **PASS** |
| `submit_claim_reconciliation(uuid,boolean,uuid)` / `service_role` | true | deliberately unassigned | **UNKNOWN** |

The remaining reported comparisons across present function/role pairs matched their expected values. **PASS:** 13 matches as reported. **MISMATCH:** four `anon`/`service_role` pickup-function grants, consistent with the direct ACL finding and the Stage A 003 authenticated-only grant boundary. **UNKNOWN:** whether the service-role reconciliation access is inherited or directly granted and whether it is intended by the preserved Stage 1 contract. No RPC was executed.

The original Query 11d output remains recorded as **TRUNCATED (100/102)**. The two omitted role comparisons are not inferred from it; Query 11d-2 was run separately and returned all six role/function combinations for `routing_private.task_guard()`.

## Query 11d-2 actual results

The user reports all six expected role rows returned. Each role exists, but `routing_private.task_guard()` is absent under its expected signature. Accordingly, `can_execute=NULL` for all six rows.

- **PASS:** Query 11d-2 returned all six expected rows.
- **MISMATCH:** `routing_private.task_guard()` is absent, confirming Query 11c.
- **UNKNOWN:** effective EXECUTE on the absent function. NULL is due to function absence and is not a permission mismatch.
- **Combined coverage:** Query 11d's 100 returned rows plus Query 11d-2's six rows (four overlapping `task_guard()` roles and the two omitted roles) cover all 102 expected role/function combinations. The original Query 11d truncation remains documented; the combined evidence supplies the missing checks without reclassifying the original query as untruncated.

## Remaining Stage C.1 unknowns and deployment blockers

- **UNKNOWN:** effective EXECUTE on `routing_private.task_guard()` because the function is absent; this is not a grant mismatch.
- **UNKNOWN:** worker/function access through roles outside the six inspected roles; Query 10c only establishes the six-role matrix.
- **UNKNOWN:** whether the `service_role` reconciliation privilege is direct or inherited and how the Stage 1 contract intends it; do not infer from the ACL text alone.
- **UNKNOWN:** exact full parity of all 27 application-trigger definitions, all 35 private constraints beyond the six UNIQUE definitions, and application impact of zero scoped RLS policies.
- **UNKNOWN:** runtime compatibility of Stage B.2 against DEV's PostGIS 3.3.7/pgRouting 3.4.1; extension presence/overload discovery is not a runtime test.
- **UNKNOWN:** historical migration application sequence; the expected ledger was not found/visible.
- **MISMATCH / BLOCKER:** Stage A 003's trigger and 14 functions are absent; pickup grants do not match its final boundary; Stage B.2 corrections and Stage B.4.3 Candidate 2 are also absent in the inspected DEV fingerprints.
- **BLOCKER:** repository guidance says existing `routing_private` requires a separately designed upgrade. No compatible in-place upgrade package or deployed-state manifest is established. Do not infer an upgrade sequence from migration filenames or apply the first-install artifacts directly.

No final deployment sequence is recommended from this evidence. A separate parity/upgrade design and approval are required after the remaining read-only checks; none of those actions are authorized here.

## Stage C.1 inspection closure summary

This closure summarizes only repository evidence and user-executed, read-only DEV catalog results. It is not deployment approval or an assertion that application behavior was tested.

### Confirmed PASS findings

- PostgreSQL 17.11, PostGIS 3.3.7 and pgRouting 3.4.1 are installed; the required polymorphic `pgr_dijkstraCost` overload was observed. Runtime compatibility with Stage B.2 remains unknown.
- The `fleet_private` v2 installation seal was computed and matches (`364bdf2b0f4e413ce0f43d10c56684dc`).
- The reported coordination policy is `claim_lease_minutes=360`, direct threshold `10 kg`, and geofence radius `20,000 m`.
- The 11 routing-private tables and 18 requested public tables were reported present with RLS enabled; all 35 reported routing-private constraints are validated, and the corrected count plus all six UNIQUE definitions match Stage A 001.
- Zero policies were observed in the inspected scope; that absence matches the reviewed migration DDL for those coordination/routing tables and private schemas. Application impact remains untested.
- All 27 returned application-defined triggers were enabled. This does not include the missing Stage A 003 trigger.
- Query 10b/10c confirmed all ten intended worker function grants and no unintended effective grants among the six inspected roles (60/60 results matched). This is not global role isolation.
- Query 11d/11d-2 combined evidence covers all 102 expected role/function combinations despite Query 11d's retained 100-row truncation note. The 14 missing functions are handled as object mismatches; NULL privilege results for absent functions are not permission mismatches.

### Confirmed MISMATCH findings

- An existing `routing_private` schema conflicts with Stage A 001's first-install assumption; repository guidance says existing installations need a separately designed upgrade (`docs/stage8/stage-a/README.md:32`).
- 14 of the 17 Stage A 003 signatures are absent (Query 11c), including all ten private helpers and four public route/read functions. `routing_private.task_guard()` is independently confirmed absent by Query 11d-2.
- `routing_task_authority` is absent from `public.pickup_tasks`, despite the Stage A 003 declaration and enabled-trigger guards (`docs/stage8/stage-a/forward-migrations/20261103_routing_pickup_and_reconciliation.sql:131-132,221,357`).
- `start_pickup` and `complete_pickup` have effective `EXECUTE` for `anon` and `service_role`, contrary to Stage A 003's authenticated-only boundary (`20261103...sql:211-212`). No calls were made; exploitability is not established.
- Stage B.2 road-helper bodies and ACLs remain at the reported pre-correction state; Stage B.4.3 Candidate 2 claim-function bodies are also pre-correction. These are catalog mismatches, not runtime/concurrency tests.

### Remaining UNKNOWN findings

- Historical migration application order: the expected migration ledger was absent or not visible; do not infer that migrations were never applied.
- The effective permission result for `submit_claim_reconciliation` under `service_role` is true, but whether this comes from a direct grant or role inheritance and whether it is intended by the preserved Stage 1 contract is unresolved.
- Access through roles outside the six-role inspections, complete function ACL/ownership parity, and global privilege isolation.
- Exact definitions for all 27 application triggers, the 29 non-UNIQUE private constraints, and complete public constraint parity.
- Runtime impact of no scoped RLS policies; no application RPC or UI path was tested.
- Stage B.2 runtime compatibility with DEV's extension versions and road-network dependencies; overload presence alone is insufficient.
- Application impact/security exploitability of absent trigger and current pickup grants; no state-changing call was authorized or performed.

### Deployment blockers and migration preconditions

- **Not ready for migration deployment.** Stage A 003's reviewed postconditions are materially absent and pickup grants differ from the final boundary.
- The Stage A forward SQL files are review artifacts outside normal migration discovery, not proof of deployment history. Stage A 003 requires 001/002, exact lifecycle/helper source and metadata preconditions, coordination configuration, a postgres session, READ COMMITTED isolation, and a lock/drain of old pickup-task writers before capturing legacy in-flight tasks (`20261103_routing_pickup_and_reconciliation.sql:1-44,345-368`).
- The existing `routing_private` state has not been reconciled against a complete deployed-state manifest, and no reviewed in-place upgrade package exists. Do not apply first-install forward artifacts directly or treat the matching subset of hashes as sufficient compatibility evidence.
- Stage B.2 extension/runtime parity, Stage B.4.3 Candidate 2 presence, historical migration history, and safe operational scheduling are also unresolved. No deployment sequence is proposed in this inspection report.

### Is more read-only inspection needed?

No additional query is needed to conclude that the inspected DEV state is **not ready** for deployment of the reviewed forward artifacts. Further read-only collection **is needed before designing a concrete separate upgrade strategy**: obtain complete exact public/private table, constraint, trigger, function-definition/dependency, ownership and ACL inventories; resolve migration/release history through an approved source; and establish the actual operational writer/dependency state. That discovery must precede any upgrade design review, but it does not authorize database-changing work. Wait for the user's review and separate explicit approval before any such work.

## Decision log

Confirmed PASS findings include platform/extension discovery, the C.1 fleet seal, reported table/RLS presence, corrected private constraint count and six unique definitions, the ten intended worker-role grants and absence of unintended grants within the six checked roles, and the current expected pre-correction lifecycle/helper fingerprints. Confirmed MISMATCH findings include Stage A first-install incompatibility with existing `routing_private`, absent Stage A 003 routing-read functions/private helper inventory and `routing_task_authority`, anon/service_role effective EXECUTE on SECURITY DEFINER pickup functions, Stage B.2 helper bodies/ACL not at the reviewed state, and Candidate 2 not present. Global worker-role isolation, exact full RLS/trigger/constraint parity, full Stage A upgrade compatibility, and live concurrency/runtime effects remain UNKNOWN. No database mutation or application RPC was performed by Codex.

## Historical cautions

The initial reports about `routing_private`, assignment phase, missing Stage B.2/Candidate 2, anonymous pickup EXECUTE and unavailable migration history have now been partially confirmed by user-supplied manual results. Migration history itself remains UNKNOWN because the expected ledger was not visible.
