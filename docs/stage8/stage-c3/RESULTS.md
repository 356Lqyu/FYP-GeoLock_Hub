# Stage C.3 — Read-Only Prerequisite Results

**DEV project reference:** `rcgyuwiidqvrgbxswhqj`  
**Execution mode:** User-run manually in the Supabase Dashboard SQL Editor. Codex does not connect to Supabase.  
**Status:** Queries 1–6 user-reported results are recorded. Query 1 and Query 2 full JSON evidence has now been reconciled against reviewed Stage A 001/002 SQL. No further DEV query is prepared.

## Query 1 — Stage A 001/002 function inventory

**Comparison source:** reviewed Stage A forward SQL: `20261101_routing_authority.sql` and `20261102_routing_publication.sql`. Each expected signature was matched to its reviewed `CREATE FUNCTION` body and declaration. `public.assign_task_to_route(uuid,uuid,integer)` is phase-aware: its expected definition is the fail-closed post-002 replacement.

**Result:** **28/28 PASS** for exact signature, body MD5, return type, owner, SECURITY DEFINER/INVOKER, volatility, hardened configuration, and ACL against the reviewed source grant/revoke declarations. All reported functions are present, owned by `postgres`, and configured with `search_path=pg_catalog, pg_temp`, `TimeZone=UTC`, and `extra_float_digits=0`. ACLs match the source: worker-only grants for graph/planner/validator functions, `authenticated` for snapshot start and candidate authorization, and owner-only private helpers/assignment function.

| Phase | Signature | DEV body MD5 | Comparison |
|---|---|---|---|
| 001 | `public.attest_routing_candidate(uuid,text,jsonb)` | `99789f22097aabb066595f44a7cfdb48` | **PASS** — body and reported metadata/ACL match reviewed phase definition |
| 001 | `public.begin_my_routing_snapshot(uuid,uuid,uuid[])` | `dca3ee04e8fbf991c4ef0993930ec185` | **PASS** — body and reported metadata/ACL match reviewed phase definition |
| 001 | `public.freeze_routing_graph(uuid,text,text,text)` | `8e1434ea2727e30f898ddff289ac2df3` | **PASS** — body and reported metadata/ACL match reviewed phase definition |
| 001 | `public.install_routing_policy(uuid,jsonb)` | `7b3549f82b239d6c6abbd4a5fee58b4e` | **PASS** — body and reported metadata/ACL match reviewed phase definition |
| 001 | `public.read_frozen_routing_graph(uuid,bigint,integer)` | `f3f732a1224fa0290077197f473026b6` | **PASS** — body and reported metadata/ACL match reviewed phase definition |
| 001 | `public.read_pending_routing_snapshot(uuid)` | `5125c4a3cce5f4c0bf9aebdf83f73847` | **PASS** — body and reported metadata/ACL match reviewed phase definition |
| 001 | `public.read_routing_snapshot_bundle(uuid)` | `443812854b91b1bf9f93d6fecbd48ced` | **PASS** — body and reported metadata/ACL match reviewed phase definition |
| 001 | `public.read_routing_work_item(uuid)` | `1ee7721aca6bc5d8fd490898e0fcf6d9` | **PASS** — body and reported metadata/ACL match reviewed phase definition |
| 001 | `public.seal_routing_snapshot(uuid,uuid)` | `21440a57a37758997fcffcd89cf416a0` | **PASS** — body and reported metadata/ACL match reviewed phase definition |
| 001 | `public.store_routing_matrix(uuid,uuid,jsonb)` | `bccccc76068912ae1d3cbff42a18964f` | **PASS** — body and reported metadata/ACL match reviewed phase definition |
| 001 | `public.submit_routing_candidate(uuid,uuid,jsonb)` | `85ff82ee813722c69a98e8d197bd5323` | **PASS** — body and reported metadata/ACL match reviewed phase definition |
| 001 | `routing_private.append_only()` | `bf4e4f93b210de23118f16eb3b5b6f33` | **PASS** — body and reported metadata/ACL match reviewed phase definition |
| 001 | `routing_private.freeze_network()` | `55f50fab862e381f21ed355a93c2bcea` | **PASS** — body and reported metadata/ACL match reviewed phase definition |
| 001 | `routing_private.hash(jsonb)` | `9baadd9fb14fce159d94e4e0bd983c22` | **PASS** — body and reported metadata/ACL match reviewed phase definition |
| 001 | `routing_private.network_digest(text,text)` | `26aceaa8835e3db8bba3a73879024212` | **PASS** — body and reported metadata/ACL match reviewed phase definition |
| 001 | `routing_private.ngo_observation(uuid)` | `6da6cd58224e4d6e58c732b734a081cb` | **PASS** — body and reported metadata/ACL match reviewed phase definition |
| 001 | `routing_private.observe_task(uuid)` | `53f058161125f26980f65303d45dccc1` | **PASS** — body and reported metadata/ACL match reviewed phase definition |
| 001 | `routing_private.snapshot_guard()` | `fd7b479db124345977509f8401b2dab6` | **PASS** — body and reported metadata/ACL match reviewed phase definition |
| 001 | `routing_private.task_digest(jsonb)` | `e28f2dba4773bbbe8e32a700047e6f6e` | **PASS** — body and reported metadata/ACL match reviewed phase definition |
| 001 | `routing_private.worker(text)` | `9fce37c17364e88eb1e2101be042a822` | **PASS** — body and reported metadata/ACL match reviewed phase definition |
| 002 | `public.authorize_my_routing_candidate(uuid,uuid,timestamptz)` | `1c3c880e27da261a9a95a95730640196` | **PASS** — body and reported metadata/ACL match reviewed phase definition |
| 002 | `routing_private.actor_lock(uuid,boolean)` | `b7de071f2da83c77809f4d505b2cc3b2` | **PASS** — body and reported metadata/ACL match reviewed phase definition |
| 002 | `routing_private.admissible(jsonb,uuid,timestamptz,jsonb)` | `86cdbf87fcaef3f3ac0e36cda4824418` | **PASS** — body and reported metadata/ACL match reviewed phase definition |
| 002 | `routing_private.arc(jsonb,text,text)` | `ceb33e05e1bf4b7d8238daee42c13974` | **PASS** — body and reported metadata/ACL match reviewed phase definition |
| 002 | `routing_private.lock_sources(uuid[])` | `52dc6262f3f85bd3c67a787401cf71aa` | **PASS** — body and reported metadata/ACL match reviewed phase definition |
| 002 | `routing_private.snapshot_task(jsonb,uuid)` | `61704ef635b841fe02fff0118a196aef` | **PASS** — body and reported metadata/ACL match reviewed phase definition |
| 002 | `routing_private.task_window(jsonb,timestamptz,jsonb)` | `82362da140f544be5d5ca5c622183fbb` | **PASS** — body and reported metadata/ACL match reviewed phase definition |
| 002 (post-publication) | `public.assign_task_to_route(uuid,uuid,integer)` | `047f2b5d6a4483b8cef8e3b91c9dc299` | **PASS** — body and reported metadata/ACL match reviewed phase definition |

**Scope note:** This establishes the supplied DEV catalog records match the reviewed local 001/002 definitions. It does not establish migration history, runtime behavior, source parity outside these records, or deployment readiness.

## Query 2 — private table structure and dependencies

**Comparison source:** `docs/stage8/stage-a/forward-migrations/20261101_routing_authority.sql`. The complete 11-row JSON was compared table by table against its CREATE TABLE, index, constraint, RLS and trigger declarations.

**Overall:** **PASS** for all 11 table definitions on reported name, owner, relation kind/persistence, RLS flags, columns (names, types, order, nullability and defaults), constraints, index identities/definitions and application-defined triggers. All 11 tables are ordinary permanent `postgres`-owned tables with RLS enabled and FORCE RLS disabled. The reported 75 columns and 35 validated constraints match the reviewed migration.

| Table | DEV columns | DEV indexes | DEV constraints | Application triggers | Classification |
|---|---:|---:|---:|---|---|
| `routing_private.bindings` | 10 | 3 | 5 (all validated) | none expected | **PASS** — compared with reviewed DDL |
| `routing_private.cancelled_stop_history` | 6 | 1 | 3 (all validated) | `immutable` | **PASS** — compared with reviewed DDL |
| `routing_private.candidates` | 6 | 3 | 3 (all validated) | `immutable` | **PASS** — compared with reviewed DDL |
| `routing_private.graphs` | 10 | 2 | 3 (all validated) | `immutable` | **PASS** — compared with reviewed DDL |
| `routing_private.items` | 11 | 3 | 5 (all validated) | none expected | **PASS** — compared with reviewed DDL |
| `routing_private.legacy_inflight` | 2 | 1 | 2 (all validated) | none expected | **PASS** — compared with reviewed DDL |
| `routing_private.matrices` | 6 | 2 | 3 (all validated) | `immutable` | **PASS** — compared with reviewed DDL |
| `routing_private.policies` | 5 | 2 | 2 (all validated) | `immutable` | **PASS** — compared with reviewed DDL |
| `routing_private.requests` | 5 | 1 | 1 (all validated) | none expected | **PASS** — compared with reviewed DDL |
| `routing_private.snapshots` | 9 | 2 | 6 (all validated) | `snapshot_no_truncate`, `snapshot_seal_guard` | **PASS** — compared with reviewed DDL |
| `routing_private.validations` | 5 | 1 | 2 (all validated) | `immutable` | **PASS** — compared with reviewed DDL |

### Index discrepancy reconciliation

The full JSON contains **21 index records**, not 19. Recount by table: bindings 3, cancelled_stop_history 1, candidates 3, graphs 2, items 3, legacy_inflight 1, matrices 2, policies 2, requests 1, snapshots 2, validations 1 (total 21). The earlier “19 observed” summary was a counting/reporting error; it is superseded by this complete row-level evidence.

All 21 index names and definitions match the reviewed Stage A 001 schema: 11 primary-key indexes, 6 unique-constraint indexes, and 4 explicit indexes (`routing_one_vehicle_booking`, `routing_one_task_booking`, `routing_candidate_snapshot`, `routing_binding_candidate`). All 21 are reported `valid=true` and `live=true`. **No missing or altered index is indicated.**

Per-table index names:

- `bindings`: `bindings_pkey`, `routing_binding_candidate`, `routing_one_vehicle_booking`
- `cancelled_stop_history`: `cancelled_stop_history_pkey`
- `candidates`: `candidates_pkey`, `candidates_request_id_key`, `routing_candidate_snapshot`
- `graphs`: `graphs_pkey`, `graphs_request_id_key`
- `items`: `items_pkey`, `items_route_id_ordinal_key`, `routing_one_task_booking`
- `legacy_inflight`: `legacy_inflight_pkey`
- `matrices`: `matrices_pkey`, `matrices_request_id_key`
- `policies`: `policies_pkey`, `policies_request_id_key`
- `requests`: `requests_pkey`
- `snapshots`: `snapshots_ngo_id_request_id_key`, `snapshots_pkey`
- `validations`: `validations_pkey`

### Other table-definition comparison details

- **Columns — PASS:** all 75 reported columns align with source order, name, type, nullability and defaults. The only textual rendering difference is `graphs.float_output_profile` default: catalog output includes `::text`, while the migration literal omits the explicit cast; this is PostgreSQL canonicalization of the same text default, not a semantic mismatch.
- **Constraints — PASS:** all 35 names, types, keys/checks/references and validation states match the migration (11 PK, 15 FK, 6 UNIQUE, 3 CHECK); all are reported validated. Unqualified `public` references in `pg_get_constraintdef` output resolve to the same expected public tables in the reported definitions.
- **Triggers — PASS:** expected eight application triggers are present and enabled: six `immutable` triggers on policies, graphs, matrices, candidates, validations and cancelled_stop_history, plus `snapshot_seal_guard` and `snapshot_no_truncate` on snapshots. PostgreSQL-rendered event ordering is normalized; the trigger actions/functions match the source. Internal RI triggers are FK implementation details and not extra application triggers.
- **Dependencies — PASS for declared FK relationships; UNKNOWN for literal `pg_depend` inventory parity:** FK targets match the table DDL. TOAST relation names and dependency OIDs are generated per database and are not stable migration fingerprints; their literal values are not compared as portable definitions. No dependency discrepancy is established by the supplied output.
- **Policy note:** RLS enabled with no forced RLS matches the reviewed 001 table setup. This is not a review of later policy state or effective access beyond the separately recorded privilege checks.

### Audit-trail correction

The earlier Query 2 note reported 19 indexes versus 21 expected and called this a count discrepancy. Recounting the supplied complete 11-row JSON yields 21 observed index records. That earlier numeric summary is corrected here; the evidence does not support a missing-index finding.

## Query 3 — private-table DML privileges

**Purpose:** Check effective INSERT, UPDATE, DELETE and TRUNCATE privileges for each of the six previously inspected roles against `routing_private.items` and `routing_private.legacy_inflight`; also report role/table presence and the exact combined `INSERT,UPDATE,DELETE` predicate used by the Stage A 003 review guard.

**Safety:** catalog/ACL inspection only using `pg_roles`, `pg_class`, `pg_namespace`, and PostgreSQL `has_table_privilege`. Expected output is 12 rows. No application functions or table data are read. Query 3 was manually executed by the user; results are recorded below.

### User-reported results

The complete output returned 12 rows (six roles × two tables). All six roles and both tables were present. For every pair, INSERT, UPDATE, DELETE, TRUNCATE, and the combined `stage_a_003_guard_dml_access` check were false.

- **PASS:** the Stage A 003 guard's effective `INSERT,UPDATE,DELETE` predicate is false for all six inspected roles on both `routing_private.items` and `routing_private.legacy_inflight` (12/12 pairs).
- **PASS:** the separately inspected INSERT, UPDATE, DELETE, and TRUNCATE privileges are false for those same 12 pairs.
- **Scope limit:** this PASS applies only to these six roles and two tables. It does not cover other roles, column-level grants, other objects, or broader security boundaries.

## Query 4 — role membership and reconciliation EXECUTE source

**Purpose:** inspect direct and transitive role membership paths for the six known roles, distinguishing inheritance-capable paths; report ACL grantees for `public.submit_claim_reconciliation(uuid,boolean,uuid)`; compare direct, PUBLIC, inherited ACL routes with `has_function_privilege` effective access.

**Safety:** catalog/ACL-only SELECT using `pg_roles`, `pg_auth_members`, `pg_proc`, `aclexplode`, and `has_function_privilege`. The recursive membership closure is bounded to role reachability and a finite closure; it returns six principal rows with nested membership/ACL summaries. It does not call the reconciliation function or inspect application records. Query 4 was manually executed by the user; results are recorded below.

### User-reported results and repository comparison

The six-row result reports all inspected roles present and `public.submit_claim_reconciliation(uuid,boolean,uuid)` present, owned by `postgres`, SECURITY DEFINER. `authenticated` and `service_role` both have effective EXECUTE through direct ACL grants. `anon`, all three routing worker roles, and PUBLIC have no EXECUTE. No membership paths or inherited EXECUTE grants were reported for these six roles.

- **PASS within inspected scope:** function presence/owner/security metadata and direct grants to `authenticated` and `service_role` match the returned evidence.
- **PASS within inspected scope:** no PUBLIC, anon, or worker-role execute path; no membership/inherited grant path among the six examined roles.
- **PASS (documented preserved reconciliation boundary):** Stage A 003 uses `CREATE OR REPLACE` for this function and does not reset its ACL. The 20261026 migration comment explicitly documents the preserved reconciliation grant set as `postgres/authenticated/service_role` (`supabase/migrations/20261026_fix_claim_recovery_reconciliation_audit_columns.sql:304-305`). The direct service_role grant is therefore consistent with the repository's documented preserved boundary, not a newly granted Stage A 003 capability.
- **Scope limit:** this classification is confined to the six inspected roles and documented current ACL; it does not establish global privilege isolation or application-level behavior.

## Query 5 — aggregate operational cutover counts

Before preparing Query 5, the reviewed definitions were checked: `routing_private.bindings.closed_at`, `routing_private.items.released_at`, and `routing_private.legacy_inflight.task_id` are declared in Stage A 001 (`20261101_routing_authority.sql:93-112`); `public.pickup_tasks.task_status` and `public.pickup_routes.route_status` are used by Stage A 001/003 (including the migration's `DISPATCHED` capture at `20261103_routing_pickup_and_reconciliation.sql:130` and route-state checks); `claim_reconciliation_cases.case_status` and its allowed states are declared in `supabase/migrations/20261019_stage1_claim_recovery_and_reconciliation.sql:27-35` and used in Stage A 003 as `OPEN`/`MANUAL_REVIEW` unresolved states.

**Purpose:** return one aggregate row counting dispatched tasks, legacy-inflight rows and overlap, active bindings/items, active bound items, dispatched tasks still tied to an active route, in-progress routes, and unresolved reconciliation cases. No identifier or individual row is returned.

**Safety:** read-only aggregate `SELECT` over only the reviewed operational tables; no RPCs, personal data, donation details, UUIDs, or row-level output. The query scans only the listed tables to calculate exact counts.

### User-reported result

One aggregate row returned all ten counts as zero: `dispatched_task_count=0`, `legacy_inflight_count=0`, `dispatched_legacy_overlap_count=0`, `dispatched_not_in_legacy_count=0`, `active_route_binding_count=0`, `active_route_item_count=0`, `active_item_on_active_binding_count=0`, `dispatched_task_on_active_route_count=0`, `in_progress_route_count=0`, and `unresolved_reconciliation_case_count=0`.

- **PASS (point-in-time, inspected counts):** all ten reported operational cutover counts are zero.
- These point-in-time counts do **not** establish future cutover safety, absence of later concurrent activity, migration-history completeness, successful migration execution, or deployment authorization.

## C.3 findings closure (current evidence)

| Area | Current classification | Remaining evidence / limit |
|---|---|---|
| Stage A 001/002 function inventory | **PASS (28/28 exact comparisons)** | Function bodies, metadata/configuration and reviewed ACL boundaries match the supplied DEV JSON. This is catalog parity, not migration-history proof. |
| `routing_private` table inventory | **PASS (11/11 reviewed table definitions)** | Full JSON reconciled: 75 columns, 21 indexes, 35 validated constraints, and expected enabled application triggers. Earlier reported index count of 19 was an incorrect recount. Literal generated dependency OIDs remain non-portable and unverified as identities. |
| Private-table DML grants | **PASS within six-role/two-table scope** | Does not establish grants for other roles, column privileges, or other objects. |
| Reconciliation EXECUTE boundary | **PASS within six-role scope and documented preserved ACL** | `service_role` grant matches the repository-documented preserved boundary; no global privilege isolation claim. |
| Operational cutover snapshot | **PASS (point-in-time counts)** | All ten counts zero; no future cutover safety or deployment authorization implied. |
| Alternate migration-relation discovery | **PASS (discovery completed)** | Query 6 returned seven catalog objects: `auth.schema_migrations` and its primary-key index; `realtime.schema_migrations` and its primary-key index; `storage.migrations` and its unique and primary-key indexes. These are Supabase internal component migration objects, not evidence that GeoLock Hub Stage A migrations were applied. |
| GeoLock Hub application migration history | **UNKNOWN** | The expected `supabase_migrations.schema_migrations` relation was not found. The alternate objects are internal component histories and do not establish GeoLock Hub migration application. No queries against those internal migration tables are authorized or prepared. |
| Direct Stage A 003 upgrade readiness | **UNKNOWN / NOT APPROVED** | Exact 001/002 function and private table definitions now match the supplied catalog evidence, but Stage A 003 preconditions/cutover assumptions, application migration history, remaining authority objects and a separately reviewed non-destructive upgrade design are not established by these comparisons. No direct deployment is authorized. |

### Remaining DEV blockers from earlier C.1 evidence

These earlier user-run catalog findings are not cleared by the Query 1/2 source comparison:

| Prerequisite | Classification | Recorded evidence |
|---|---|---|
| Stage A 003 installation | **MISMATCH** | Query 11c reported 14 of 17 expected Stage A 003 signatures absent; the expected `routing_task_authority` trigger was also absent from the complete application-trigger inventory. |
| Pickup-function privilege boundary | **MISMATCH** | Queries 7/10/11c-11d reported `anon` and `service_role` EXECUTE on `start_pickup` and `complete_pickup`, contrary to the reviewed Stage A 003 intended boundary. Whether anonymous calls could pass internal checks was not tested and remains **UNKNOWN**. |
| Stage B.2 spatial corrections | **MISMATCH** | Query 8 reported both spatial helper bodies at their pre-correction fingerprints. Compatibility of the reviewed correction with DEV's PostGIS/pgRouting versions remains **UNKNOWN**. |
| Stage B.4.3 Candidate 2 correction | **MISMATCH** | Query 9 reported `claim_listing` and `geolock_lock_listing_donations` at pre-correction fingerprints. DEV concurrency behavior was not tested and remains **UNKNOWN**. |
| Direct replay of Stage A 001 | **MISMATCH / unsafe precondition** | The reviewed 001 first-install guard rejects an existing `routing_private` schema. Query 1/2 parity with selected 001/002 objects does not authorize replay or establish a safe in-place upgrade. |

The Stage C.3 comparison resolves only the supplied 001/002 function and private-table definition parity. It does not clear these separately recorded DEV blockers or establish a safe Stage A 003 upgrade path.

## Query 6 — alternate migration-history relation discovery

**Purpose:** inspect catalog names only for non-system relations conventionally named for migration tools, after the expected `supabase_migrations.schema_migrations` relation was reported absent.

**Safety:** bounded, read-only `SELECT` from `pg_class` and `pg_namespace`; returns schema/relation metadata only, no relation contents or application records. It invokes no function or RPC. A returned name is only a lead for later review; no result cannot establish that migrations were never applied.

### User-reported result

Query 6 returned seven catalog objects:

- `auth.schema_migrations` — table
- `auth.schema_migrations_pkey` — index
- `realtime.schema_migrations` — table
- `realtime.schema_migrations_pkey` — index
- `storage.migrations` — table
- `storage.migrations_name_key` — index
- `storage.migrations_pkey` — index

- **PASS:** alternate migration-relation discovery completed with seven returned objects.
- **UNKNOWN:** GeoLock Hub application migration history. These are Supabase internal component migration objects and do not evidence Stage A migration application.
- No queries against these internal migration tables are prepared.

## Remaining C.3 inspections

No further database inspection is prepared. Query 1 and Query 2 JSON evidence has been reconciled offline. Application migration history remains UNKNOWN, and deployment readiness remains UNKNOWN; these catalog comparisons do not imply upgrade safety or deployment authorization.
