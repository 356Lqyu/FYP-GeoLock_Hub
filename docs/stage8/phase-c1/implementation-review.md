# Stage 8 Phase C1 NGO fleet management implementation proposal

**Prepared for approval only. No DEV migration or data mutation has been executed.** DEV inspected: `rcgyuwiidqvrgbxswhqj`; no shared project accessed. This package extends the existing fleet entity, leaves NGO registration unchanged, and does not implement road matrices, snapshots, independent plan acceptance, reservations or dispatch authorization. `start_pickup` and all donation/listing/claim/lease/recovery/hub lifecycle functions remain unchanged.

## Deliverables and evidence

- [Proposed atomic migration, including protected RPC SQL](proposed_migration.sql). Intentionally outside `supabase/migrations`, so ordinary migration tooling cannot apply it accidentally.
- [Fresh SELECT-only DEV evidence](dev-evidence.json), including exact columns, constraints, indexes, ACLs, triggers, identity/depot functions and catalog queries; [additional version/dependency evidence](dev-additional-evidence.json).
- [Read-only preflight queries](read_only_preflight.sql) for a later approved deployment review. Some MCP clients return only the last result of a multi-statement query; execute these separately.
- [Isolated PostgreSQL test harness](../../../supabase/tests/stage8_c1_fleet_isolated_test.py) and [final test log](isolated-test-results.txt).
- Governing approval register: `docs/stage8/review/2026-10-24-phase-b-signoff-and-phase-c-approval-plan.md`, units C0/C1 and fleet integrity portions of the existing route dependency only.

## 1. Confirmed deployed schema

Inspection time: 2026-10-23 19:56:50 UTC / 24 October 2026 03:56:50 MYT. Counts: **zero vehicles, zero pickup routes**. DEV PostgreSQL is 17.11. Counts are observations, not deployment-time assumptions.

| Required field | CONFIRMED IN DEV | Proposal |
|---|---|---|
| Vehicle identity | `vehicles.vehicle_id uuid` PK, generated UUID | Reuse; immutable after creation. |
| Owning NGO | `ngo_user_id` FK to `ngo_profiles.user_id`; unique `(vehicle_id,ngo_user_id)` | Reuse; no client owner parameter; immutable owner. No unique NGO-only constraint: zero, one or multiple vehicles permitted. |
| Vehicle type | Missing; display label is not a type | Add bounded nonblank text `vehicle_type`; no invented car/van taxonomy restriction. |
| Capacity | `payload_capacity_kg numeric(12,3) NOT NULL CHECK >0` | Reuse kg and three decimal places; reject nonfinite values and RPC precision loss. No capacity default. |
| Fixed cost | Missing | `fixed_cost_rm numeric`, nonnegative, finite, at most two decimal places. RM per used vehicle/route in the current one-trip model. Explicit caller input. |
| Distance cost | Missing | `distance_cost_rm_per_km numeric`, nonnegative, finite, at most four decimal places. Explicit caller input. |
| Maximum duration | Missing | `max_route_duration_min numeric`, positive, finite, at most three decimal places. Explicit caller input, no inherited synthetic 240-minute default. |
| Depot | Nullable text `depot_road_node_id` | Reuse trusted NGO operating node; no client-editable depot argument. |
| Availability | `active_flag` only | Add distinct `available_for_planning NOT NULL DEFAULT false`. Deactivated vehicles cannot be reactivated through this proposal. |
| Version/retry metadata | Missing | Add `vehicle_version`, `updated_at`, owner/request registration key and immutable original request payload for retry conflict detection. |

Existing keys: vehicle PK and `(vehicle_id,ngo_user_id)` unique key; NGO FK; `pickup_routes(vehicle_id,ngo_user_id)` references that composite key. Existing indexes do not lead with NGO or route vehicle lookup. The proposal adds owner/active lookup, owner/request uniqueness and a partial busy-route vehicle index; it creates no duplicate fleet table.

### Identity and verified depot provenance

`auth.users.id` → `user_profiles.user_id`, whose role includes NGO → `ngo_profiles(user_id,role)` with role fixed to NGO. `vehicles.ngo_user_id` references this NGO subtype. Every public fleet RPC derives the owner from `auth.uid()` and verifies an active NGO/profile role; supplying another vehicle UUID produces the same `VEHICLE_NOT_FOUND` result as a nonexistent UUID.

The deployed `trg_vehicle_depot_node` invokes `geolock_assign_vehicle_depot()` before insert or update of owner/depot. It ignores the supplied depot and derives `ngo_profiles.road_node_id` only when `location_verified_at` is present. It does not itself verify current graph membership or availability. No vehicle depot road-node FK exists today.

`set_ngo_operating_location` resolves the location against approved operational coverage, checks the 500 m snap policy, locks the NGO, increments location generation and refreshes vehicle depot fields and eligibility jobs. Existing `verify_ngo_location` and `geolock_backfill_road_nodes` also update vehicle depots. These functions were inspected but are not changed. C1 registration requires a verified active NGO node that exists and is active in approved active OPERATIONAL coverage; node lookup uses the existing bigint node PK, with safe conversion from legacy text IDs. Future graph changes must re-evaluate eligibility; C1 does not version the graph.

## 2. Minimal migration and legacy handling

The SQL is a single transaction with bounded lock/statement timeouts. It extends `public.vehicles`, creates private fleet helper functions and five public RPCs, adds three vehicle triggers and one fleet-integrity trigger on existing `pickup_routes`. No lifecycle function or existing depot trigger/function is replaced.

Legacy vehicles retain IDs, owners, capacity, depot and activity. Missing type/cost/duration remain NULL and planning availability starts false; the migration does not guess business values. An existing row must be completed through the update RPC before availability can be enabled. Required completeness is checked whenever planning availability is true. New RPC registrations always require all operational values, including explicitly entered zero costs if appropriate. No vehicle is inserted by NGO registration.

Idempotence means rerunning this same proposal on its reviewed schema is safe: additive columns/indexes, conditional named constraints, replaceable C1 functions and recreated C1 triggers. The isolated tests apply it twice and rerun it with a legacy row, verifying exact row preservation. This is not an automatic schema-drift repair tool. Unexpected vehicle policies, a missing original depot trigger, new vehicle-dependent relations or first-install nonterminal routes abort for review. Recheck definitions/types/owners against the evidence before deployment; `IF NOT EXISTS` does not certify equivalence of arbitrary pre-existing objects with the same names.

The migration locks vehicles/routes briefly with ACCESS EXCLUSIVE to make installation/preflight atomic. Approve a maintenance window; do not run it during active route work. Invalid existing nonfinite capacities cause constraint validation to abort without correcting/deleting data. New text labels/types are length-bounded by RPC validation; historical labels are preserved while unavailable.

## 3. Protected RPC contract

All functions below return JSONB, run SECURITY DEFINER under the trusted postgres owner with `search_path=pg_catalog,pg_temp`, and use qualified application relations. Only authenticated callers receive EXECUTE; each still checks actual NGO identity. No NGO ID or depot node is accepted as client proof.

| RPC | Inputs and behavior |
|---|---|
| `register_my_vehicle` | Request UUID, label, type, kg capacity, fixed RM cost, RM/km rate, maximum minutes and availability (defaults false). Requires active verified NGO depot even for unavailable registration. Generates vehicle ID. Same owner/request and identical original payload returns the existing vehicle's current representation; a conflicting payload is rejected. Different request IDs can register additional vehicles. |
| `list_my_vehicles()` | Lists only caller-owned vehicles, including inactive vehicles, with current `eligible_for_planning`. Zero eligible vehicles yields `fleet_outcome=NO_FEASIBLE_PLAN`; an empty fleet also reports `reason=NO_REGISTERED_VEHICLES`. `AVAILABLE_VEHICLES` is fleet eligibility only, not proof that a task route is feasible. |
| `update_my_vehicle` | Vehicle ID, expected version and complete permitted field values: label/type/capacity/costs/duration. No owner, depot, active flag or version assignment. No patch ambiguity; caller resubmits the whole editable profile. |
| `set_my_vehicle_availability` | Vehicle ID, expected version and Boolean. Enabling requires current verified operational depot and complete fields. Disabling is blocked by a nonterminal route. |
| `deactivate_my_vehicle` | Vehicle ID and expected version. Sets active=false and available=false, retains identity and historical FKs. No delete/reactivate RPC. |

All changes use optimistic expected-version checks. Effective edits increment the version/time and emit an atomic audit event with before/after values; a true no-op changes neither version nor audit history. Registration retries do not duplicate audit rows. A stale retry of update/deactivation must refresh the row before retrying; no blanket last-write-wins behavior is provided. Database failure rolls back both data and successful audit. Rejected calls return errors; a durable rejected-action log is not claimed because an exception would roll back its same-transaction audit insert.

## 4. Ownership, RLS and permissions

**CONFIRMED IN DEV:** vehicles RLS is enabled with no policies, and FORCE RLS is false. Anon/authenticated/service_role currently have broad table grants, including TRUNCATE. No-policy RLS denies ordinary row access, but RLS does not protect TRUNCATE and service_role bypasses it. Therefore C1 explicitly revokes **all** vehicle table privileges from PUBLIC, anon, authenticated and service_role, including non-row privileges. It does not add client SELECT or write policies. Fleet access is RPC-only. Existing trusted postgres-owned location functions retain owner access.

Helpers live in `fleet_private`, with schema access and function EXECUTE revoked from all client/service roles. The public five RPCs have all inherited/default EXECUTE grants revoked and only authenticated EXECUTE restored. Global Supabase defaults and unrelated grants/policies are not changed. This explicit handling matters because current default privileges grant new public functions to multiple roles.

The owner is intentionally trusted and can bypass RLS; C1 does not claim to constrain a database administrator or stolen administrative credentials. A service-role API key must not be exposed to clients. PostgREST must authenticate and establish `auth.uid()` normally; the local auth setting used in tests is an explicit test double, not a client authorization mechanism.

Reference guidance: [Supabase database-function privileges and definer search paths](https://supabase.com/docs/guides/database/functions), [PostgreSQL schema trust](https://www.postgresql.org/docs/17/ddl-schemas.html) and [PostgreSQL row-lock semantics](https://www.postgresql.org/docs/17/explicit-locking.html).

## 5. Active-route and reservation compatibility

**CONFIRMED IN DEV:** the only non-system relations with a vehicle ID column are `vehicles` and `pickup_routes`. There is no deployed authoritative vehicle-reservation table in the inspected schema. `active_task_route_assignments` reserves a task to a route, not a time slot on a vehicle. C1 implements no new reservation tables or authorization records.

For C1, every existing DRAFT, VALIDATED, AUTHORISED or IN_PROGRESS route is conservatively treated as holding its vehicle. While held, changes to label/type/capacity/costs/duration/depot/availability/activity are rejected. Label edits are also frozen because they increment the vehicle version that future plans may bind. Identical no-ops remain allowed. Terminal COMPLETED/CANCELLED/STALE routes release this fleet-edit guard. C1 does not decide or implement how routes enter these states.

The fleet mutation path locks the owned vehicle before checking routes. The additional route trigger locks that same vehicle for route insertion/status updates, checks current availability/owner/depot for nonterminal routes, forbids rebinding an existing route to another vehicle/NGO and forbids deleting a nonterminal route. This closes the simple check-then-write race without modifying a lifecycle RPC. Tests exercise both route-first and fleet-edit-first orderings in independent PostgreSQL sessions. C1 guards use READ COMMITTED and explicitly reject writes at stronger isolation levels so stale predicate snapshots are not silently accepted. Applications must retry deadlock/serialization failures as whole operations with fresh versions; the two tested races do not certify every possible multi-table lock schedule.

This trigger does **not** certify route feasibility, prevent two routes from booking overlapping time slots, authorize pickup or close the `start_pickup` bypass. Those remain later approvals. When a future reservation/authorization model is introduced, all its writers must participate in the same fleet locking/version guards and receive new race tests before use. The preflight rejects unreviewed new vehicle-dependent relations rather than pretending the current guard protects them.

Idle depot revocation/clearing automatically changes availability to false and increments the version. Re-verification does not automatically restore availability. Valid idle depot refreshes preserve the existing derived-depot behavior. If a depot would change while a nonterminal route holds the vehicle, the entire calling location-verification/backfill transaction is rejected. This includes trusted verifier and graph-maintenance paths that refresh vehicle depots. **Approve this conservative operational behavior explicitly:** resolve/cancel the route through existing authorized procedures before maintenance; any emergency revocation policy requires a separate design. The C1 SQL adds no lifecycle cancellation or forced release path.

## 6. Test plan, results and limits

Tests runnable offline:

```powershell
.\.venv-stage8\Scripts\python.exe supabase/tests/stage8_c1_fleet_isolated_test.py --run-isolated
.\.venv-stage8\Scripts\python.exe -m unittest discover -s backend/routing -t . -p 'test*.py' -q
.\.venv-stage8\Scripts\python.exe -m backend.routing.generate_examples --check
.\.venv-stage8\Scripts\python.exe -m docs.stage8.review.phase_b_final_review
```

The C1 runner requires PostgreSQL `initdb`, `pg_ctl`, `psql` on PATH and creates/stops a NEW temporary loopback cluster. It accepts no URL, DSN or existing server and strips PG connection environment settings. The Windows sandbox cannot start pg_ctl's restricted process token; the isolated run was permitted outside that sandbox. It never connects to Supabase. Local PostgreSQL version: 17.11. The harness executes the exact proposed SQL and captured deployed depot function; it uses a reduced schema, synthetic road nodes, synthetic NGOs and a test `auth.uid()` implementation. It does not execute the full production location resolver, eligibility jobs, PostGIS or lifecycle system.

| Coverage | Isolated evidence / required later check |
|---|---|
| Tenant ownership and role | Own list only; other NGO register/list isolation; foreign update/availability/deactivation denied; anonymous, missing identity, donor and inactive NGO denied. |
| Capacity/cost/duration | Null/zero/negative/nonfinite/unsupported precision cases; explicit zero costs accepted; invalid update; direct constraint checks. |
| Depot | Unverified NGO, missing/inactive/invalid/overflowing node and inactive graph denied; client node overridden by captured trigger; stale/unverified fleet not eligible. |
| Fleet state | Zero and multiple vehicles; availability toggles; expected-version conflict; deactivation preserves historical route/vehicle; incomplete legacy completion; retry conflicts and no-op behavior. |
| Active-route conflicts | All four nonterminal statuses; label/profile/availability/deactivation guards; terminal release; owner mismatch; active-route delete; two transaction race orderings. This substitutes existing route holds, not a nonexistent C5 reservation implementation. |
| Permissions | SELECT/INSERT/UPDATE/DELETE/TRUNCATE denied to anon/authenticated/service_role; helpers denied; RPC ACL/search-path inspection. |
| Compatibility/atomicity | Identical migration reruns and legacy preservation; idle depot refresh/revocation; held-depot change rolls back; failed audit rolls back registration; unexpected policies abort migration. |

Final C1 result: **29 tests passed in 33.230 seconds**, with additional parameterized ownership/value/permission checks inside the tests. Exact proposed SQL SHA256: `8158c5e0c28cedcbd6a42d4d83f1a1bf4f4561fa98c72654a31cfdec9fdb133f`. Existing routing regression result: **117 passed in 3.014 seconds**, including the 54 Phase A tests. Nine unchanged synthetic fixtures verify. The Phase B review still confirms all 17 preserved files, 252 independently valid saved reports and 84 reproducible groups; benchmark source hashes/non-timing digest remain unchanged.

**Requires approval of a migrated staging/DEV environment; NOT RUN against DEV:** real JWT/PostgREST role tests; full unchanged NGO registration and location/verifier/graph-maintenance integration; existing lifecycle regression suite under the added triggers; catalog drift/type/ACL verification; concurrent claim/recovery/location/route paths and deadlock retries; migration locks/timeouts and deployment rollback rehearsal. Use test NGOs and records only under a separately approved mutation plan. Do not run the isolated fixture SQL in DEV. Do not claim local RLS/auth doubles prove deployed JWT security.

## 7. Rollback and deployment compatibility

Before any later deployment: confirm DEV project URL, export schema/grants/dependent definitions, inspect rows and nonterminal routes, compare this evidence with fresh catalogs, review the exact SQL digest and run tests on a disposable clone. Check public RPC names/private schema do not collide with unrelated objects and inspect the no-policy assumption. New or altered same-name objects require manual review; this proposal must not overwrite unknown production customization.

An error before COMMIT rolls the whole migration back, including DDL and ACL changes. If post-deployment rollback is needed, first pause fleet clients and route writers. Revoke the five C1 RPCs; retain vehicle data, added columns and audit history. Restore the captured previous trigger/ACL state only after inspecting new routes and explaining the loss of fleet protection. Do not drop columns or tables, cascade-delete historical vehicles, restore broad client writes automatically, or remove guards with live held vehicles. A destructive down migration is deliberately not provided. Approve a concrete retirement script against the then-current schema before running it.

Registration remains separate and unchanged. Existing active_flag semantics remain retirement; planning availability is independent. No automatic existing-vehicle activation, guessed capacity, RM cost or duration occurs. No Flutter calls or current pickup calls are changed. Current `start_pickup` bypass remains open until its separately approved phase; C1 must not be marketed as enforced safe dispatch.

Reference alignment: FYP RO5, §4.4.2/Table 4.2/Algorithm 8 and Appendix A Table A.4 supply vehicle/capacity/duration/cost context; their synthetic car/van capacities and 240-minute duration are not operational defaults. Supervisor Stage 8 feedback (pages 14–15) motivates capacity/time/duration constraints and operational inputs. Contract v3.2 §11.4/§11.6/§12.8 motivates explicit configured fleet, owned planning inputs and a no-feasible-plan outcome. Currency/precision and management policy here are explicit C1 proposals, not assertions that every detail was mandated by the thesis. Cost-objective/engine documentation corrections from Phase B remain outstanding. Source document SHA256 identities match the Phase B review; none was edited.

## 8. Explicit approval checklist

- [ ] Approve extension of existing `vehicles`, nine added columns, constraints/indexes and nullable legacy operational fields with planning disabled.
- [ ] Approve RM units, capacity precision, fixed-cost two decimals, distance-rate four decimals, duration-minute three decimals, bounded free-text types/labels, no cost/capacity/duration defaults and explicitly entered zero costs.
- [ ] Approve verified operational NGO depot before vehicle registration; no independent client vehicle depot or registration-flow change.
- [ ] Approve RPC-only access, including revoking direct service-role vehicle table privileges while retaining existing postgres-owned location functions; review external service callers first.
- [ ] Approve request-key registration retries, expected-version updates, immutable owner/identity and permanent deactivation with retained history.
- [ ] Approve the C1-only route dependency trigger, all nonterminal routes as conservative holds, frozen labels/profile versions, immutable route vehicle bindings and READ COMMITTED write requirement.
- [ ] Approve idle depot revocation disabling planning and held-vehicle depot changes rejecting the entire verifier/backfill transaction; document maintenance/emergency procedures.
- [ ] Review final test log and accept its isolated-schema limitations; approve full-stack staging/security/lifecycle/race tests separately before DEV execution.
- [ ] Approve a maintenance window, backup/drift checks, exact final SQL digest, rollback/retirement procedure and subsequent **explicit DEV application authorization**.

**Decision requested at this boundary: review the proposal. No DEV application authorization has been inferred. C2–C5, UI and lifecycle/dispatch changes are outside this package.**
