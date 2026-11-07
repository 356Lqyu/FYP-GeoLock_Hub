# Phase C1 final SQL security and operational compatibility review

**Recommendation: APPROVE WITH CONDITIONS for the revised v2 C1 fleet foundation only. Do not execute the original proposal. This review is not execution approval.** No migration, lifecycle function or DEV record was changed. Inspection used Supabase MCP SELECT-only against confirmed URL `https://rcgyuwiidqvrgbxswhqj.supabase.co`; no shared project was accessed. No C2 implementation is included.

The original proposal revoked more backend access than required for NGO isolation and treated terminal route status alone as sufficient to release a vehicle. V2 retains narrowly defined trusted service access and checks unresolved route activity before release. Operational route closure and emergency maintenance remain explicit deployment conditions.

Artifacts:

- [Revised complete migration SQL](proposed_migration_v2.sql), containing all fleet RPCs. It is outside the automatic migrations directory.
- [Exact original-to-v2 SQL diff](original-to-v2.diff); original [proposal SQL](proposed_migration.sql) remains unchanged.
- [Fresh authoritative DEV catalog/function evidence](final-review-dev-evidence.json), including expanded ACLs, role bypass capabilities, route-related functions and cron inspection.
- [V2 isolated PostgreSQL tests](../../../supabase/tests/stage8_c1_fleet_v2_isolated_test.py) and [results](v2-isolated-test-results.txt).
- [Deterministic local review-file generator](build_review_v2.py), which only generates files and makes no database connection.

Original SQL SHA256: `8158c5e0c28cedcbd6a42d4d83f1a1bf4f4561fa98c72654a31cfdec9fdb133f`.

V2 SQL SHA256: `f50af9705de117bdd12581f2515605c8e5c548e0fee7ae01d7ea33ecfbb0cb05`.

## 1. Security decision table

| Area | CONFIRMED IN DEV / original proposal | Final recommendation in v2 |
|---|---|---|
| Ordinary NGO vehicle table access | anon/authenticated hold eight table privileges; no vehicle RLS policies | Revoke all table privileges and any column SELECT/INSERT/UPDATE/REFERENCES grants from PUBLIC/anon/authenticated. Use the five authenticated NGO RPCs. |
| Trusted backend | service_role holds the same eight privileges, has BYPASSRLS; original C1 revoked everything | Retain/grant vehicle SELECT, INSERT, UPDATE without grant option. Revoke DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN. Backend writes still encounter row guards, constraints and audit. This is a separate trust boundary from NGO clients. |
| Row deletion / destructive reset | Original delete guard blocks row DELETE but TRUNCATE bypasses row triggers | No normal vehicle delete. Also revoke pickup_routes TRUNCATE from PUBLIC/anon/authenticated/service_role so route holds cannot be erased through this path. Database-owner maintenance remains privileged. |
| NGO RPC ownership | No client NGO/depot argument; auth.uid() plus active NGO/profile subtype checked | Retain. Foreign/nonexistent vehicle IDs share VEHICLE_NOT_FOUND. Private helpers accepting NGO IDs are inaccessible to client/service roles. |
| Function execution | Supabase defaults can grant EXECUTE broadly | Explicitly revoke PUBLIC/anon/authenticated/service_role EXECUTE, then grant only authenticated EXECUTE on the five NGO RPCs. Private helpers remain inaccessible, including to service_role. |
| Definer trust | postgres owns tables/functions and bypasses RLS | Retain for compatibility with existing protected V3 functions, qualified objects and fixed pg_catalog,pg_temp path. No dynamic caller-supplied SQL. This does not constrain a database owner or stolen administrator credential. |
| Active route freeze | DRAFT, VALIDATED, AUTHORISED, IN_PROGRESS | Keep all four as conservative holds. Drafts are not production reservations; without safe invalidation/cleanup, editing beneath them is unsafe. |
| Terminal release | Original used only status | Require terminal state plus no active assignments or linked PLANNED/DISPATCHED tasks; COMPLETED transition additionally requires all existing stop tasks COLLECTED. Terminal routes cannot be reactivated. |
| Trusted depot refresh | Existing location/verifier/backfill functions refresh vehicles | Idle refresh remains supported; clearing depot disables planning. No generic live-route bypass. Held-depot changes fail atomically and require controlled operational resolution. |

### Exact current privileges

At 2026-10-23 20:11:55 UTC / 24 October 04:11:55 MYT, `public.vehicles` is owned by postgres. Raw ACL is:

```text
{postgres=arwdDxtm/postgres,anon=arwdDxtm/postgres,
 authenticated=arwdDxtm/postgres,service_role=arwdDxtm/postgres}
```

Expanded ACL confirms **SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER and MAINTAIN** for each of those roles. No PUBLIC grant, column grants or anon/authenticated/service_role role memberships were found. None of those three roles has grant option. Postgres has implicit owner authority; information_schema reports its grantability differently from the explicit ACL entries.

The earlier C1 evidence used information_schema.role_table_grants, which omitted PostgreSQL 17 MAINTAIN. This final review uses aclexplode for the complete list. The same eight privileges are currently granted on pickup_routes. V2 changes only its TRUNCATE privilege in addition to the fleet row trigger; other route ACLs are unchanged.

Vehicles and routes have RLS enabled, FORCE false and no policies. Thus ordinary roles are default-denied row access despite table ACLs. This does not make broad grants harmless: TRUNCATE/REFERENCES are outside row security. Bypass roles still require table privileges. Service_role and postgres have BYPASSRLS; anon/authenticated do not. Catalog checks also confirm that anon/authenticated/service_role neither inherit postgres privileges nor have SET permission for session_replication_role. A retained service role therefore cannot bypass ordinary enabled row triggers by that setting. External roles, proxy code, credential distribution and all possible privileged maintenance mechanisms are not certified by these checks.

The least-privilege compatible split is **NGO RPC-only, backend SELECT/INSERT/UPDATE, administrator-only destructive/DDL maintenance**. Revoking service access is unnecessary for NGO isolation. A future planner should use a dedicated read-limited identity where feasible rather than receive a global service key; creating that integration role is not part of C1.

Trusted backend writes intentionally may name an owning NGO: the backend credential, not the supplied ID, supplies authority. Such a backend must verify any originating user's JWT and permissions before proxying a request. Never expose a generic service-role write endpoint driven by a client NGO ID. The NGO RPCs are not granted to service_role and do not turn a missing user identity into administrative ownership.

References: [Supabase RLS and bypass roles](https://supabase.com/docs/guides/database/postgres/row-level-security), [database-function privileges](https://supabase.com/docs/guides/database/functions), [PostgreSQL row-security scope](https://www.postgresql.org/docs/17/ddl-rowsecurity.html). These support the design; the linked DEV catalog evidence establishes the actual deployment.

## 2. SECURITY DEFINER review

The five public signatures remain unchanged: register_my_vehicle(uuid,text,text,numeric,numeric,numeric,numeric,boolean), list_my_vehicles(), update_my_vehicle(uuid,bigint,text,text,numeric,numeric,numeric,numeric), set_my_vehicle_availability(uuid,bigint,boolean), deactivate_my_vehicle(uuid,bigint).

Each derives `auth.uid()` through the private active-NGO/profile check. Mutations lock and select a vehicle by both UUID and derived owner. Neither ownership reassignment nor arbitrary depot input is available. Registration retry identity is `(derived NGO, request UUID)`; a request cannot select another NGO's vehicle. Immutable owner, vehicle ID and original registration identity are also enforced by the row trigger, including for backend UPDATE.

All new functions have fixed `search_path=pg_catalog,pg_temp`; tables, types and nonbuilt-in functions are qualified. Caller-created public/temp tables cannot replace the qualified application tables. Helpers are in a schema with USAGE/CREATE revoked from PUBLIC/anon/authenticated/service_role and have no client EXECUTE. Security definer operations bypass owner RLS intentionally and must therefore retain the explicit ownership predicates. There is no client-supplied SQL string or authorization session flag. Dynamic SQL is limited to quoted catalog column names for ACL revocation and a quoted installation comment.

Backend writes are privileged across tenants, but they cannot normally transfer ownership, edit held profiles, change managed version/timestamp fields, reactivate retired vehicles, delete vehicles or circumvent constraints. V2 corrects the original metadata gap: explicitly updating vehicle_version or updated_at now raises VEHICLE_METADATA_MANAGED instead of incrementing a held vehicle's version without a profile change. The trigger alone generates these fields for effective edits. The audit derives the actual profile role when a user identity is present; backend actions without a user identity remain SYSTEM.

Object-owner privileges remain powerful. No RLS setting protects against an administrator replacing a function, disabling triggers, changing grants or editing the installation marker. The fingerprint described below detects accidental/schema drift for reviewed repeat execution; it is not a cryptographic authorization system or an adversarial administrator boundary.

## 3. Vehicle holds, abandoned routes and release

**Exact deployed allowed statuses:** DRAFT, VALIDATED, AUTHORISED, IN_PROGRESS, COMPLETED, CANCELLED, STALE, enforced by pickup_routes_route_status_check. DEV has no custom route-table trigger. The C1 route guard exists only in proposal SQL. Vehicles currently have only trg_vehicle_depot_node. Current counts remain zero vehicles and zero routes.

Deployed function inspection found reads of routes/assignments but no public route-table writer/closing function. No route-related cron job was found. `complete_pickup` completes task/listing/claim/lease/donation state but does not close the route or remove its assignments. `cancel_claim` and `recover_expired_claims` conservatively treat route activity as a release/reconciliation concern. They are not a route-abandonment cleanup service. External workers are NOT VERIFIED.

Consequently, a DRAFT, VALIDATED or even IN_PROGRESS row can remain abandoned indefinitely. A route's age or lease expiry is not evidence that its vehicle is free. C1 provides **no automatic TTL, no fabricated completion, and no NGO cleanup RPC**. An approved route administration/reconciliation procedure is needed before live route records are used. It must resolve source tasks and assignments with existing lifecycle authority; this review adds no task, claim, lease or custody mutation.

Editing becomes possible when all routes for that vehicle are terminal and none retains an active_task_route_assignments entry or a stop linked to a PLANNED/DISPATCHED task. Another held route continues to block editing. For a new COMPLETED transition, each existing stop task must already be COLLECTED and assignments cleared. For CANCELLED/STALE, unresolved PLANNED/DISPATCHED activity or assignments blocks closure. A terminal row with legacy inconsistent activity still blocks vehicle editing through the independent hold predicate. A mere UPDATE of the route status cannot release the hold. This predicate is also used by list_my_vehicles eligibility.

Terminal COMPLETED/CANCELLED/STALE rows cannot return to a different route status; planning a new route requires a new record. Historical stop records can remain. A terminal historical route is not a live dispatch candidate. V2 does not implement immutable plan contents, plan-version binding, reservation scheduling or validation; those later stages must not reuse historical mutable fleet values as execution authority.

### Concurrency

Fleet mutations lock the vehicle before checking holds. Route insert/status updates lock the same vehicle. Existing route assignment RPCs lock the route before creating their activity, serializing against that route's closure. Terminal transition checks use read-only child-state checks; no child task/claim rows are updated by C1.

- Route binding commits first: fleet edit waits, observes the nonterminal route and fails.
- Fleet deactivation commits first: route binding waits, sees unavailable vehicle and fails.
- Route completion/cancellation commits first after legitimate resolution: waiting fleet edit sees release and may proceed.
- Cancellation rolls back: waiting fleet edit sees the original hold and fails.
- An attempted terminal transition with unresolved assignments/tasks fails; no false release is committed.

Writes require READ COMMITTED, which provides fresh command snapshots after waits; stronger isolation levels are explicitly rejected rather than silently relying on a stale predicate snapshot. Lock order can still deadlock in larger operations, especially trusted SQL that locks vehicles and then invokes a route update while another writer holds a route and waits for the vehicle. Use consistent route/vehicle ordering, bounded lock/statement timeouts and whole-operation retries. The isolated tests cover selected two-session races, not every V3 interleaving.

Direct backend child-table edits remain a trusted responsibility. Do not truncate/delete assignments or stops to manufacture release, or insert activity against a terminal route. Future reservation/route-publication writers must join this locking/validation protocol. C1 does not claim its route row trigger intercepts arbitrary writes to every lifecycle child table.

### Depot verification and maintenance

For idle vehicles, existing verifier/location/backfill functions still derive the depot through the unchanged original trigger; clearing it disables planning and requires explicit later re-enablement. A held depot change rejects and rolls back the entire caller transaction, including its NGO-location update. This is deliberate preservation of the existing route's vehicle/depot binding, not an emergency revocation solution.

A controlled operational exception is necessary when urgent revocation or graph replacement cannot wait. **Do not implement it as service_role skipping the row guard, a caller-set GUC, or a silent depot rewrite.** In C1 there is no safe generic exception because route snapshots, cancellation/reconciliation and dispatch revocation are not yet implemented. First stop affected operations under an approved incident procedure, reconcile/close held work through authorized mechanisms, then change the depot. A live-route emergency path needs separate reviewed changes and tests. C1 fleet CRUD can progress with zero live routes; production route use must wait for that procedure. No existing verifier/lifecycle function is modified here.

## 4. Full migration safety review and exact differences

| Review area | Result |
|---|---|
| Existing rows | Preserved. Existing type/cost/duration gaps stay NULL and planning is false. Capacity, NGO, vehicle identity and historical FKs are retained. No default capacity/cost/duration or vehicle creation occurs. |
| CHECK / NOT NULL | Existing positive capacity retained; nonfinite values rejected. New operational fields remain nullable for legacy imports; planning=true requires a complete active vehicle/depot. New RPC registrations require every operational value. Availability/version/timestamp are NOT NULL with false/1/server-clock defaults. Capacity's numeric(12,3) storage range and lossless RPC precision checks remain. |
| Foreign keys | Existing vehicle→NGO and route→(vehicle,NGO) FKs reused. No duplicate entity or speculative node FK/type rewrite. Depot text remains derived from verified NGO and current operational node membership. |
| Indexes | Original three C1 indexes retained: owner/request uniqueness, owner/activity lookup and nonterminal route vehicle lookup. Existing stop route prefix/task PK indexes support checks; assignment-route lookup may need a later measured index if scale warrants it. |
| Object identity | Fresh installs reject unexpected private schemas/public RPC collisions/partial C1 artifacts. Expected original depot trigger must be enabled and point to the captured function. No V3 lifecycle routine is replaced. |
| Repeat execution | New column types/nullability and availability default are checked. Installation fingerprint detects changes to vehicle/table shape, constraints, index definitions/validity, managed functions and triggers before replacement. Data edits do not change it. Reviewed client/column ACL tightening is reapplied. Drift aborts for review instead of being repaired silently. |
| Transaction | Single BEGIN/COMMIT, 5-second lock timeout, 60-second statement timeout; vehicles/routes ACCESS EXCLUSIVE during installation. Constraint validation and the volatile timestamp default can hold locks/rewrite rows if the table later grows. Use a maintenance window and fresh counts. |
| Rollback | Before COMMIT, PostgreSQL rolls back DDL/data/grants atomically on failure. After commit, revoke C1 RPC access and pause affected writers first; retain new columns/vehicle history. A reviewed retirement/restore script must account for holds and assignments. Do not restore broad grants or drop guards/columns with live routes. |
| Phase A/B | Public fleet function signatures and operational units remain as proposed. No Phase A/B source/scenario/schema contract version is rewritten. A future adapter is still required; C1 JSON is not an authoritative immutable solver snapshot. No live routing or dispatch guarantee is implied. |

Exact changes from the retained original are in the unified diff. The material differences are:

1. Preserve service_role vehicle SELECT/INSERT/UPDATE; remove its DELETE/TRUNCATE/REFERENCES/TRIGGER/MAINTAIN. Ordinary roles lose all table and residual column rights.
2. Revoke pickup_routes TRUNCATE from client/service roles to protect holds from a row-trigger bypass.
3. Add a shared vehicle_has_hold helper considering nonterminal routes, any active assignment, and linked PLANNED/DISPATCHED tasks. Use it for editing and fleet eligibility.
4. Add terminal-transition unresolved-activity checks; COMPLETED requires existing stop tasks COLLECTED. Block terminal reactivation and deletion with unresolved activity.
5. Protect managed version/timestamp fields from explicit UPDATE and derive audit actor role accurately for trusted backend actions.
6. Add schema/RPC collision, partial-install and enabled-depot-trigger checks; verify new column shapes/default; add a private installation-fingerprint helper and schema marker for fail-closed repeats.
7. Add v2 tests and exact-diff generation; retain original SQL/tests/results for comparison. No deployment, table/record mutation in DEV, lifecycle RPC changes or C2 functionality is included.

This v2 file installs onto the reviewed pre-C1 DEV baseline. It deliberately does not silently upgrade a previously executed v1 private schema. A v1 installation would require its own reviewed upgrade plan; no v1 installation is currently observed.

## 5. Tests and remaining approval conditions

**44 v2 tests passed in 56.038 seconds**; the linked local test log records the run. Tests run the exact v2 SQL inside a newly initialized disposable PostgreSQL 17.11 instance on loopback only, never on DEV or an existing server. The harness accepts no DSN/URL. It inherits the original 29 behavioral tests with the service expectation intentionally revised, plus new service-privilege/metadata guards, unresolved/terminal route tests, cancellation/completion races, and schema/ACL drift checks. Reduced tables, synthetic nodes/NGOs and auth.uid() are explicit doubles; local child-state edits are fixture setup, not proposed DEV administration instructions.

Existing Phase A/B regression suite: **117 tests passed in 4.786 seconds**. Original SQL remains byte-identical by SHA256. No solver source or frozen input changed.

Before authorizing DEV execution:

- Approve the revised SQL/digest and the exact client/backend privilege split; inventory trusted external service consumers. Never deploy a service key to Flutter or an unverified proxy.
- Confirm the maintenance/cutover window, schema/ACL backup, unchanged baseline and zero nonterminal/unresolved route work. Recheck all referenced objects and grants immediately before execution.
- Accept C1 as fleet-only. Do not create live route workloads until a reviewed route closure/abandonment and emergency depot-maintenance procedure exists. No hidden TTL or privileged bypass is approved.
- Verify staging compatibility of unchanged NGO registration, location verification/revocation, graph maintenance and V3 lifecycle functions under these fleet triggers. Test lock ordering/retries with real assignment/cancellation/completion/recovery interleavings.

Tests requiring a separately approved migrated DEV/staging environment are **NOT RUN in DEV**: real PostgREST/JWT roles and function exposure; service-key backend behavior; actual road resolver/coverage/NGO location changes; full lifecycle integration; real concurrent routes and source-task cleanup; maintenance lock duration, post-commit retirement/rollback; and deployed schema/ACL verification. They require their own controlled data-mutation plan after explicit authorization. Catalog inspection cannot certify credential secrecy, hosted backend implementations or live traffic behavior.

Recommendation remains **APPROVE WITH CONDITIONS**, limited to this revised C1 foundation and the stated staging/cutover gates. The original blanket service-role revocation should not be approved. This report stops for review and does not authorize applying v2 to DEV.
