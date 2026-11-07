# GeoLock Hub — Technical Onboarding and DEV Audit

**Audit date:** 2026-11-01 (Asia/Kuala_Lumpur)  
**Mode:** source inspection and live read-only PostgreSQL catalog/data queries  
**DEV project verified:** `rcgyuwiidqvrgbxswhqj` (`https://rcgyuwiidqvrgbxswhqj.supabase.co`)  
**Scope:** no Flutter source, migration, Supabase configuration, or database record was changed. No write RPC, recovery action, evidence submission, or resolver operation was invoked.

## Executive conclusion

**Recommendation: NO-GO for retiring the route interruption participant evidence flow today.** The live DEV project has one unresolved route interruption case, Test 10. Its NGO and source-side assertions are incomplete for two never-started stops, and there is no route-level vehicle-return assertion. The Test 10 stop itself has matching NGO/source “no handover” route evidence, but its individual claim reconciliation is still `MANUAL_REVIEW`. Route finalization requires participant assertions on every affected stop plus NGO vehicle accountability and then a restricted resolver. Removing the route UI without an already available alternative strands this case and future interruption cases.

Individual claim reconciliation is not a substitute for route evidence: `finalize_route_resolution` explicitly reads the private route-case evidence ledger (`resolution_private.evidence`) and the route observation manifest. It requires matching NGO and source-side `NO_HANDOVER_SOURCE_RETAINS_GOODS` statements for each uncollected task and `VEHICLE_RETURNED_TO_NGO_CONTROL` from the NGO. Its checks do not accept two-party claim evidence as a replacement. Live `close_my_resolved_route` and per-stop deferral also reject routes with an unresolved route interruption case. Route-wide interruption reporting remains enabled.

The currently deployed architecture already includes a restricted resolver path. The live catalog showed one active resolver operator (only the count was inspected). That path is a necessary finalization mechanism, but it does not replace participant evidence. A safe retirement requires a forward-only design and delivery of an authorized way to obtain or adjudicate these missing route assertions, plus an explicit way to resolve the existing open case. Keep the route UI available until then.

## Evidence labels and limits

- **Live DEV fact** means returned by the Supabase MCP endpoint verified above, using read-only catalog or `SELECT` operations during this audit.
- **Local-source fact** means visible in tracked or untracked Flutter/migration/documentation source in this checkout. It is not proof that the same source is deployed.
- **Inference** means a conclusion drawn from those facts; it is labeled as such.
- This is a schema/business-logic onboarding audit, not a penetration test, full row-by-row data export, or execution test. No Flutter test suite was run. The live migration-list MCP call returned an empty list, and `supabase_migrations.schema_migrations` was absent. Thus migration history cannot be established from the migration ledger; deployed object definitions and catalog state are stronger evidence of the live behavior than file names or local migrations.
- Several repository files were already modified or untracked at audit start. They were left untouched. In particular, `frontend/geolock_hub_app/lib/donation_pages.dart` had a pre-existing modification. This report describes the inspected working-tree source.

## 1. Project architecture and Flutter inventory

The Flutter client is under `frontend/geolock_hub_app`. It is a compact, feature-oriented app rather than a layered package with separate domain/data packages:

| Area | Principal files | Purpose |
|---|---|---|
| Startup/environment | `lib/main.dart`, `lib/supabase_config.dart` | Environment selection, Supabase initialization, auth gate, session/role routing, NGO location onboarding and eligibility retry. |
| Auth | `lib/auth/auth_pages.dart`, `auth_controller.dart`, `auth_navigation.dart` | Welcome/login, role selection, registration, email verification, password recovery/reset, profile lookup, role registration, sign-out. |
| Dashboards | `lib/dashboard_pages.dart` | DONOR, NGO and HUB ADMIN tabs; profile pages; donor impact; hub operations entry; NGO pickup entry. |
| Donation/claim/hub | `lib/donation_pages.dart`, `claim_card.dart`, `claim_cards_controller.dart`, `claim_request.dart` | Create/read/cancel donation, discovery, claim cards and detail, hub registration/inventory/batches/reservations, claim reconciliation UI. |
| Routing | `lib/routing/ngo_routes_page.dart`, `ngo_fleet_page.dart`, `ngo_routing_repository.dart`, `route_execution_controller.dart`, `proposed_route_view.dart`, `route_card_view.dart` | NGO vehicle setup, route planning/preview/authorization, execution, pickup state and safety feedback. |
| Reconciliation UI | `lib/routing/route_resolution_page.dart`, `route_resolution_repository.dart` | Participant route interruption inbox/details, route-level evidence, receipts, donor-specific context, incident reporting. |
| Location | `lib/location/*` | Device location and road-network preview/access checks. |
| Shared UI/helpers | `status_timeline.dart`, `donation_status.dart`, `donation_collection_path.dart`, `donation_photo_rules.dart`, `donation_photo_errors.dart`, `async_request_gate.dart` | Status rendering, collection-path and photo validation, async request serialization. |

The repository root also contains `backend/routing/` (worker service), scripts, datasets/results, backups, research/Stage 8 documentation, and the Supabase source/migrations. The routing worker and planner/validator roles are separate from ordinary Flutter participant APIs; the DB grants planner/validator/graph-worker routines selectively.

### Auth and role navigation

Supabase Auth owns credentials/session. Registration stores a pending profile in user metadata, then `AuthController.completePendingRegistration` calls `register_role_profile` after sign-in. `get_my_profile` selects the registered role; `SessionRouter` sends the signed-in session to the role dashboard. NGO profiles additionally call `get_my_ngo_eligibility_refresh_status`. If setup is missing, the client collects location and invokes `set_ngo_operating_location`. `prevent_role_change()` is attached to `user_profiles` and blocks role mutation. Role-specific DB functions compare `auth.uid()` and `user_profiles.role`; the client’s navigation is convenience, not the security boundary.

`SupabaseConfig` defaults to DEV, with a hard-coded DEV project URL and a publishable client key. The shared environment requires explicit environment plus URL/key defines; there is no shared-key fallback. This report intentionally does not repeat any key material. `main()` renders a missing-configuration screen if setup is invalid and initializes `supabase_flutter` otherwise.

### Screens and participant workflows

- **DONOR:** welcome/login/register; donor dashboard and donations list/detail; create donation with items, location and required photos; choose/direct or hub collection where eligible; view reservations/drop-off status; cancel eligible donation; view claim outcome; submit individual claim reconciliation; access route-resolution context for their donation when the route feature flag is on.
- **NGO:** dashboard and eligible listing discovery; listing detail and claim; claim cards/history/detail; route/fleet views; routing diagnostics/policy display; propose, review and authorize routes; start and complete pickups; defer an eligible unstarted pickup; route interruption case inbox/details and route-level statements; profile/location setup; vehicle registration/availability/edit/deactivation.
- **HUB ADMIN:** register/manage hubs, service rules and accepted categories; monitor reservations/drop-offs; confirm received weight; inspect inventory and batch listings/images; publish whole-donation batches under server-side atomicity/eligibility rules.
- **RoleProfilePage:** reads profile and relevant hub/eligibility details, then calls role-specific update RPCs.

All UI operations handle stale account/session conditions, loading/error states and refresh. For sensitive operations, the client stores a request UUID and checks a server receipt after timeout before replaying; it does not silently substitute a new request. RPC failures surface structured PostgREST/auth messages or mapped safety reasons. Detailed UI implementation lives in the files linked above; the line-level call map is in §4.

### Feature switches

- Build-time `GEOLOCK_SUPABASE_ENV` selects `dev` by default or explicitly `shared`; the shared build also requires the matching URL and publishable key.
- Build-time `GEOLOCK_ROUTE_RESOLUTION_ENABLED` gates the route resolution repository, and the repository also requires DEV. When off, the client shows “backend unavailable” messaging; it does not remove DB safety holds. The live DB configuration row `resolution_private.config.enabled` was `true`.
- `geolock_app_capabilities()` is queried by donation/claim screens for server-reported capability gates. Route and listing availability also depends on the DB’s async road eligibility refresh/job state, rather than client feature flags alone.

### Tests present

`frontend/geolock_hub_app/test/` contains widget/unit suites for auth/navigation and profile, donation/claim cards and persisted requests, donor route resolution, NGO routing, route execution, proposed-route/detail cards, automatic route operations, worker client, and routing pending-request/feedback/resume/visibility. Additional isolated SQL/Python contracts are in `supabase/tests/`, including stage 8, route resolution, claim concurrency/recovery, and reconciliation compatibility. Inventory only; tests were not run as requested by the developer workflow instruction not to run tests unless asked.

## 2. Supabase DEV catalog and schema

### Schema inventory

**Live DEV facts:** relevant application objects are in `public`, `routing_private`, `resolution_private`, and `fleet_private`. PostgreSQL also exposes standard Supabase schemas (`auth`, `storage`, `extensions`, `cron`, etc.). There are **39 public base tables; all 39 have RLS enabled**. `routing_private` holds immutable route planning/execution evidence and request receipts; `resolution_private` holds restricted route resolution cases/evidence/operator configuration; `fleet_private` contains fleet guards/auditing logic.

#### Public tables (39)

`active_task_route_assignments`, `audit_events`, `claim_cancellation_requests`, `claim_leases`, `claim_reconciliation_cases`, `claim_reconciliation_evidence`, `claim_requests`, `community_hubs`, `coordination_config`, `donation_cancellation_requests`, `donation_categories`, `donation_claims`, `donation_create_requests`, `donation_images`, `donation_items`, `donations`, `donor_profiles`, `hub_accepted_categories`, `hub_admin_profiles`, `hub_batch_images`, `hub_batch_members`, `hub_batches`, `hub_inventory`, `hub_receipts`, `hub_reservations`, `listing_eligibility_refresh_jobs`, `listings`, `ngo_eligibility_refresh_jobs`, `ngo_listing_road_eligibility`, `ngo_profiles`, `operation_failure_events`, `pickup_route_stops`, `pickup_routes`, `pickup_tasks`, `road_network_coverage`, `road_network_edges`, `road_network_nodes`, `user_profiles`, `vehicles`.

#### Private tables

- `routing_private`: `bindings`, `cancelled_stop_history`, `candidates`, `deferred_events`, `deferred_release_permits`, `deferred_requests`, `deferred_stops`, `graphs`, `items`, `legacy_inflight`, `matrices`, `mixed_route_closures`, `policies`, `requests`, `snapshots`, `validations`.
- `resolution_private`: `cases`, `config`, `evidence`, `finalizations`, `incidents`, `items`, `operators`, `permits`, `releases`, `requests`, `test_runs`.

#### Important columns, constraints and relationships

| Entity | Key columns and relationship | Workflow |
|---|---|---|
| `user_profiles` and role profile tables | User UUID references `auth.users`; role profile tables keyed by user, with NGO/hub identity and location/verification fields. | Auth onboarding, role-specific identity. |
| `donations`, `donation_items`, `donation_images`, `donation_categories` | Donation UUID, donor UUID, status, collection path, pickup coordinates/road node, weight and availability; item/category and image metadata linked to donation. | Donation creation, validation, images, lifecycle. |
| `hub_reservations`, `community_hubs`, `hub_inventory`, `hub_receipts` | Donation/hub IDs; capacity reservation and receipt/weight; hub owner references hub-admin profile. | Direct-to-hub dropoff and inventory receipt. |
| `hub_batches`, `hub_batch_members`, `hub_batches` listing source, `hub_batch_images`, `hub_accepted_categories` | Hub/batch/member/category links; batch membership guarded immutable; whole batch represented by one listing/claim. | Batch publication, eligibility, atomic collection/handover. |
| `listings`, `ngo_listing_road_eligibility`, eligibility refresh jobs | Listing source (`DIRECT_DONATION` or `HUB_BATCH`), state/version/expiry; eligibility keyed by listing and NGO and network snapshot. | Discovery, geofence/road eligibility, expiry. |
| `claim_requests`, `donation_claims`, `claim_leases`, `claim_cancellation_requests` | Request UUID unique/idempotency; one lease per claim; claim references listing and NGO; bounded lease status. | Claim atomicity, ownership lease, cancellation/recovery. |
| `claim_reconciliation_cases`, `claim_reconciliation_evidence` | One reconciliation case per claim; evidence keyed by request, actor and case with `handover_confirmed`; case status check includes OPEN, resolved collected/released, MANUAL_REVIEW. | Two-party evidence for an individual donation claim or whole hub batch claim. |
| `pickup_routes`, `pickup_route_stops`, `pickup_tasks`, `active_task_route_assignments`, `vehicles` | Route ↔ NGO/vehicle; stop ↔ route/task; unique active assignment per task; task ↔ claim/listing/NGO composite FK; route and vehicle ownership composite FKs. | Route plan, authorisation, dispatch, completion, closure and fleet accountability. |
| `routing_private.snapshots`, `graphs`, `matrices`, `candidates`, `validations`, `bindings`, `items`, `requests` | Immutable snapshot→matrix→candidate→validation→binding chain; route/task observations and XID markers; unique active task and vehicle bookings; request receipts. | Deterministic route planning and execution authority. |
| `routing_private.deferred_stops`, `deferred_events`, `deferred_requests`, `mixed_route_closures` | Unique route/task deferred state; append-only event/request receipts; route-level mixed close receipt. | Per-stop deferral and auditable mixed outcome closure. |
| `resolution_private.cases`, `items`, `evidence`, `operators`, `permits`, `releases`, `finalizations`, `requests`, `incidents` | One case per route; per-task source/NGO anchors and initial classification; versioned immutable assertions; operator-only permits/releases/finalization receipts. | Route interruption holds and restricted route-wide resolution. |
| `road_network_coverage`, `road_network_nodes`, `road_network_edges` | Snapshot-scoped nodes/geography and directed weighted edges; one active operational snapshot unique partial index. | Road eligibility and reproducible routing graph. |
| `audit_events`, `operation_failure_events`, create/cancel/claim request tables | UUID correlation/request IDs, state/outcome/reason and details; append-only audit trigger; idempotent receipts. | Audit trail, rejected operation diagnostics and idempotency. |

The full live column catalog (name, PostgreSQL type, nullability, and defaults), primary/foreign-key definitions, and check constraints were queried from `information_schema.columns` and `pg_constraint`. Key enforced invariants include UUID primary keys; unique claim request/claim lease/claim reconciliation associations; constrained state enums; coordinate ranges; hub capacity and route weight/range checks; immutable role; and composite ownership FKs. Because there are 310 catalog constraints, the table above gives the business relationships rather than reproducing every generated constraint name. Query exact definitions directly from `pg_constraint` before any schema change.

### Index inventory and use

The live relevant index catalog contains **135 indexes** (ordinary, unique, primary, partial, expression and spatial). It includes indexes backing all PK/unique/FK lookup paths, road-network GiST coverage, eligibility lookup, claim/request idempotency, route/task order, and private immutable plan/binding/deferred/evidence receipts. Notable examples: unique `claim_leases(claim_id)`, unique `claim_reconciliation_cases(claim_id)`, unique `pickup_tasks(claim_id)`, route-stop uniqueness by route/order and route/task, partial `routing_one_task_booking(task_id) WHERE released_at IS NULL`, `routing_one_vehicle_booking(vehicle_id) WHERE closed_at IS NULL`, `pickup_routes_c1_vehicle_busy(vehicle_id)` for active route states, `road_network_one_active_operational` partial/expression unique index, and GiST `idx_road_coverage_gist`.

No index was removed. The audit did not run a controlled workload/`pg_stat_user_indexes` period analysis, so no index is labeled unused. The full `pg_get_indexdef` catalog query is the authoritative inventory; compare stats only after checking `stats_reset` and representative workload duration. Do not infer that an index is redundant solely from a similar prefix: unique/partial/expression predicates may enforce state invariants.

### Functions and RPCs

Catalog counts in the live DB: **152 public functions, 29 `routing_private` helpers, 16 `resolution_private` helpers, and 9 `fleet_private` helpers**. Core participant RPCs are `SECURITY DEFINER`, use fixed search paths, and generally check `auth.uid()`, role, ownership, current state/version, related rows and idempotent request UUIDs. Worker/validator/planner and resolver routines are granted to dedicated roles; they are not ordinary authenticated APIs. Direct private-schema table privileges are denied to `anon` and `authenticated`.

| Group | Important live signatures (return type) | Authorization / effects |
|---|---|---|
| Auth/profile | `register_role_profile(text,text,text,text,text,text,double precision,double precision,text) → uuid`; `get_my_profile() → jsonb`; `update_my_profile(...) → jsonb`; NGO location setup/status calls. | Authenticated identity; one fixed role; role-specific fields and validated location. |
| Donation & discovery | `create_donation_with_images(uuid,text,text,text,double precision,double precision,jsonb,text,jsonb) → uuid`; `get_my_donation_dashboard_v2()`, `get_my_donation_detail(uuid)`, `get_active_donation_categories()`, `discover_eligible_listing_cards()`, `cancel_donation(uuid,uuid)`. | Donor ownership, photo requirement at commit, category/weight/availability/road validation, transition guard, idempotent create/cancel request. |
| Hub | `register_my_hub(...)`, `get_my_hubs()`, `set_my_hub_service_rules(...)`, `publish_whole_donation_batch(uuid,uuid[])`, `get_my_hub_inventory_v2(uuid)`, `confirm_hub_receipt(uuid,numeric)`, hub detail/dropoff/batch reads. | Hub-admin ownership/verification, operating hours, capacity/category compatibility, immutable batch membership, all-or-nothing batch lifecycle. |
| Claim | `claim_listing(uuid,uuid) → jsonb`; `get_my_claim_cards_v2()`; `get_claimed_listing_detail(uuid)`; `cancel_claim(uuid,uuid)`; `recover_expired_claims(integer) → integer`. | NGO identity and eligibility, active lease, unique request/idempotency, listing locks, reconciliation/route/custody guards. Recovery is private scheduled execution; no recovery was run in this audit. |
| Individual reconciliation | `submit_claim_reconciliation(uuid,boolean,uuid) → jsonb`; `get_my_reconciliation_cases()`; `get_my_donation_claim_reconciliation(uuid) → jsonb`; `get_my_claim_reconciliation_receipt(uuid) → jsonb`. | NGO and source-side participant only; one actor/request receipt; counterpart evidence; disagreement or dispatched no-handover remains in manual review. Collect outcome requires two validated positive handover assertions and checks batch atomicity. |
| Route planning/execution | `begin_my_routing_snapshot(uuid,uuid,uuid[])`; `freeze_routing_graph(...)`; `submit_routing_candidate(...)`; `attest_routing_candidate(...)`; `authorize_my_routing_candidate(...)`; `get_my_routing_overview()`; `get_my_authorized_route(uuid)`; `start_pickup(uuid)`; `complete_pickup(uuid,boolean)`. | Dedicated planner/validator/worker roles for planning steps; NGO route/vehicle ownership, sealed candidate and version/manifest, authorized next stop, locks/custody at execution. |
| Interruption/reconciliation | `report_my_route_interruption(uuid,text,uuid) → jsonb`; `submit_route_resolution_evidence(uuid,uuid,text,bigint,uuid) → jsonb`; `get_my_route_resolution(uuid) → jsonb`; `list_my_route_resolution_cases() → jsonb`; `get_my_donation_route_resolution(uuid)`; `finalize_route_resolution(uuid,bigint,uuid) → jsonb`; `get_my_route_resolution_receipt(uuid)`. | Participants read/submit within one case and version; resolver finalization restricted to `geolock_route_resolver` with active operator. It may release tasks/route assignments and mark route abandoned atomically after strict checks. |
| Per-stop and route closure | `defer_my_pickup_for_reconciliation(uuid,uuid) → jsonb`; `get_my_authorized_route(uuid)`; `close_my_resolved_route(uuid,boolean,uuid) → jsonb`; `get_my_deferred_pickup_receipt(uuid)`; `close_my_collected_route(uuid,boolean)`. | NGO owns active route; defer only eligible unstarted, undispatched custody-safe pickup; whole-route interruption and reconciliation hold block defer/close; closure checks every task outcome, assignment, vehicle return and receipt. |
| Failures/audit/receipts | `get_authorized_audit_events(text,uuid)`, request-specific claim/donation/routing/deferred/route-close receipts, `operation_failure_events`. | Entity participant/admin scope; append-only audit, protected request payload digest, no replacement request on uncertain outcome. |

Core private helpers include `routing_private.lock_route`, `lock_sources`, `actor_lock`, `lock_reconciliation_scope`, `task_guard`, `check_remaining`, `observe_task`, `snapshot_guard`, `freeze_network`, `permit_reconciled_collection`, `finish_reconciled_collection`, `reconciliation_participant`, `guard_deferred_transition`, and `record_deferred_event`; and `resolution_private.allowed`, `latest`, `manifest`, `lock_case`, `require_enabled`, `operator_key`, `receipt`, `save_receipt`, `release_allowed`, `assert_test_scope`, `audit`, and immutability guards. They coordinate lock order, participant ownership, deterministic observation digests, replay safety, audit, and narrowly scoped release permits.

**Privileges caveat:** role execution privileges are per signature. The live function inventory confirmed `finalize_route_resolution` is not executable by `authenticated`; its intended resolver-only grant appears in the local 20261106 forward migration. Several legacy/general functions report broad `anon` execute grants in catalog privilege checks. RLS prevents direct row exposure where no policy applies, but `SECURITY DEFINER` functions must be reviewed individually. Do not use client-side role hiding as an authorization control.

### Triggers, RLS and permissions

The catalog reports **48 non-internal triggers** across the relevant application/private schemas. Significant guards include:

- Donation lifecycle commit validator, required-photo deferred constraint, road-node assignment, donation transition guard.
- Listing eligibility refresh/generation triggers and listing-state transition guard.
- Donation-item and hub batch/member immutability guards.
- Hub reservation opening-hours and road-route checks; hub location synchronization.
- Claim/task routing authority and test-scope guards; route/vehicle guards and fleet audit.
- Road graph freeze on row mutations and truncate.
- Append-only audit provenance/immutability.
- Private resolution evidence/incident/release/receipt/test-run immutable triggers.
- Private routing append-only planning snapshots/graphs/matrices/candidates/validations; sealed snapshot guard; deferred stop transition/event; deferred and mixed-close receipt immutability; deferred collection linkage.

All public base tables have RLS enabled. The `pg_policies` query returned a small explicit policy set (including authenticated hub reads/own-hub update, category reads, and guarded image reads); numerous operational tables have no direct-use policy and are intended to be accessed through scoped RPCs. Although table ACLs show privileges on a number of public tables for roles such as `anon`/`authenticated`, RLS without a matching policy denies rows. Private schemas have no direct client table privileges. `audit_events` has append-only mutation trigger and server provenance trigger. Role changes are blocked by trigger. Recheck `pg_policies`, `has_table_privilege`, routine ACLs and trigger definitions on any deployment.

### Background processing

Live `cron.job` returned three active jobs, all scheduled every minute:

1. `geolock-ngo-eligibility-refresh` → `process_ngo_eligibility_refresh_jobs()`.
2. `geolock-listing-eligibility-refresh` → `process_listing_eligibility_refresh_jobs()`.
3. `geolock-expired-claim-recovery` → `recover_expired_claims(1)`.

The recovery cron job is already active in DEV; this audit did not invoke it. It can change eligible expired-claim rows independently while a read-only audit is being performed. No route-reconciliation cron job appeared. Per-stop/deferred state changes and route resolution are RPC-driven, with receipts/triggers rather than a scheduled resolution worker.

## 3. End-to-end business flow and state machines

### Registration → donation → discovery → claim

1. User registers through Supabase Auth with a pending role profile. After authenticated session creation, Flutter calls `get_my_profile`; if absent, `register_role_profile` creates the role profile; pending metadata is cleared. Email verification/password recovery are Supabase Auth APIs, not DB RPCs. Errors include invalid/expired auth session, unsupported/already registered role, account switch, and profile mismatch.
2. Donor completes donation form, item/category/weight, location and required photo selection. `create_donation_with_images` creates donation, items, images, idempotency request and listing/eligibility side effects in one transaction. Constraints/triggers validate photos at commit, legal state, categories, availability and road-node assignment. Expected UI result is a receipt/card and a listed/unlisted collection path. Missing/invalid photo, road location, availability or invalid state aborts.
3. Donation may be direct (`DIRECT_DONATION`) or reserved at a hub; hub choice is constrained by eligibility and reservation capacity/opening hours/routability. Reservation expiry/reassignment/cancellation uses protected functions. Hub receives via `confirm_hub_receipt`, which creates inventory receipt and records weight. Batch publication uses `publish_whole_donation_batch`; membership is immutable and batch listing is atomic. Hub listing/claim is a single batch claim to protect batch integrity.
4. NGO discovery calls `discover_eligible_listing_cards`; eligibility requires active listing, NGO status/location, current road network snapshot/geofence and ready async eligibility. `claim_listing` records an idempotent `claim_requests` receipt, locks listing, verifies eligibility and no active conflicting lease/hold, creates `donation_claims`, `claim_leases`, and pickup work. `get_my_claim_cards_v2` serves cards. Conflicts, location refresh pending, listing expired/claimed, active lease or unresolved case block.
5. Claim leases have configurable fixed 360-minute life (live `coordination_config`); expiry recovery runs in cron batches. Recovery is guarded against routing/custody and reconciliation. It can release claim/listing only when allowed; ambiguous active route custody opens/retains reconciliation instead. Flutter reads status; it does not perform recovery itself.

### Route planning → vehicle → execution

6. NGO registers/maintains vehicles (capacity, cost, duration, availability, version). Server creates a snapshot from eligible tasks and available vehicles; worker graph/matrix candidate steps are separately authorized and sealed. NGO reviews proposal and authorizes a candidate. Binding freezes vehicle version, route manifest, claims and task order; uniqueness/partial indexes prevent one active vehicle/task booking. UI reflects route validation, blocked/pending eligibility and changed versions.
7. NGO starts route/pickup with `start_pickup`; then a controlled transition marks stop/task `DISPATCHED`, recording XID/custody in private route items. Only the authorized next stop and matching NGO/route/vehicle binding can proceed. Collection/handover uses `complete_pickup` or protected reconciliation path. It checks two-party custody, direct versus hub source, all members of batch, current lease and route observation; direct task and donation status move to collected atomically. User cannot edit task/route tables directly.
8. Vehicle and route are released only by valid route closure/resolution after all stops have valid terminal outcomes, assignments removed and depot-return accountability supplied. Route closure writes an immutable receipt and audit event. Route `ABANDONED` denotes reconciled closure as well as mixed outcome; use receipt/case outcome to distinguish.

### Individual claim reconciliation versus route interruption

9. Individual reconciliation is one claim at a time. It is created when a protected event leaves claim/lease in `RECONCILIATION_REQUIRED`. The DONOR (or hub admin for batch) and NGO each submit a boolean via `submit_claim_reconciliation(claim, handover_confirmed, request)`. Evidence is stored in `claim_reconciliation_evidence`; a two-positive matching handover can resolve collected only when task/batch custody checks succeed. Two negatives before pickup starts can release/relist; two negatives after dispatch go to `MANUAL_REVIEW` because physical custody is uncertain. Disagreement or invalid state also requires review. Claim lease/case remains locked pending resolution. Individual claim state does not account for the entire route or vehicle.
10. Route interruption uses a separate route-wide `resolution_private.cases` case, one per route. `report_my_route_interruption(route, reason, request)` creates a snapshot-bound case of all stops and places a safety hold. For each affected task, the NGO and source actor (donor or hub admin) can assert `NO_HANDOVER_SOURCE_RETAINS_GOODS`, `HANDOVER_TO_NGO_CONFIRMED` (not allowed for never-started), or `UNKNOWN_CUSTODY`. New disagreement/unknown can move case to `MANUAL_REVIEW`. NGO must separately assert `VEHICLE_RETURNED_TO_NGO_CONTROL` with a null task. Evidence increments case version and is immutable; receipts are idempotent. `finalize_route_resolution` is a restricted resolver-only transaction; it rechecks route binding, vehicle version, manifest, observations, current custody and matching statements, then records releases/permits, resolves claims, removes route assignments, releases bindings, marks route abandoned and writes audit/receipt. Conflicting/unsafe state blocks or leaves manual review.
11. Per-stop defer is different again. `defer_my_pickup_for_reconciliation(claim, request)` only accepts an NGO-owned, authorized active route and an eligible `PLANNED`/`CONFIRMED`, unstarted task with claim/lease reconciliation hold and no dispatched task elsewhere in route. It requires **no unresolved whole-route interruption case** and source/lease integrity. It writes `routing_private.deferred_stops`, receipt and event, safely detaches that stop so other safe stops can continue. Later reconciliation resolves it collected or uncollected; guarded triggers and XID permits keep route history/assignment integrity. Final mixed closure requires every stop collected or released-uncollected and vehicle accountability.

### Key state sketches

```text
Donation: DRAFT/created → AVAILABLE → CLAIMED → PICKUP_IN_PROGRESS → COLLECTED
                   └─ hub reservation/drop-off → RECEIVED/INVENTORY → BATCHED/LISTED → CLAIMED → …
Claim:    ACTIVE + ACTIVE lease → COMPLETED (collected) | RELEASED/CANCELLED/EXPIRED
                                  ↘ RECONCILIATION_REQUIRED → resolved | MANUAL_REVIEW
Task:     PLANNED/CONFIRMED → DISPATCHED → COLLECTED
                     └─ eligible deferred stop → STALE/released after uncollected reconciliation
Route:    planned/validated → AUTHORISED → IN_PROGRESS → CLOSED (all collected)
                                                    └→ ABANDONED (resolved interruption or mixed outcome)
Route case: absent → AWAITING_EVIDENCE → RESOLVED (restricted resolver)
                          └→ MANUAL_REVIEW (conflicting/unknown/unsafe)
```

These labels are verified against live catalog constraints and deployed function source, but each historical/legacy task may have transitional states. Always use the live task, claim, lease, route, case and receipt together; do not infer custody from one status field.

## 4. Flutter-to-Supabase call map

Important direct calls in current source (RPC parameters shown where specific):

| User action / source | RPCs and parameters | Result and primary blocks |
|---|---|---|
| Session role/profile, `auth_controller.dart` | `get_my_profile()`; `register_role_profile(p_full_name,p_role,p_phone,p_ngo_name,p_registration_number,p_operating_address,p_latitude,p_longitude,p_road_node_id)` | Profile JSON/role; auth/session mismatch, existing profile/role errors. |
| NGO location onboarding, `main.dart` | `get_my_ngo_eligibility_refresh_status()`; `set_ngo_operating_location(p_operating_address,p_latitude,p_longitude)` | READY/pending/error; requires verified valid road-reachable location. |
| Donor dashboard/profile, `dashboard_pages.dart` | `get_my_donation_dashboard_v2()`, `get_my_profile()` | Current donor rows/profile; authorization/network errors. |
| NGO dashboard/discovery, `dashboard_pages.dart`, `donation_pages.dart` | `get_my_claim_cards_v2()`, `get_my_profile()`, `discover_eligible_listing_cards()`, `geolock_app_capabilities()` | Claim list, eligible listings/capabilities; feature, eligibility refresh, location or listing state blocks. |
| Hub dashboard, `dashboard_pages.dart` | `get_my_hubs()`; hub summary/dashboard reads | Owned hubs and operations; only authorized hub admin. |
| Donor create/detail, `donation_pages.dart` | `get_active_donation_categories()`; `create_donation_with_images(p_request,p_title,p_description,p_pickup_address,p_latitude,p_longitude,p_items,p_pickup_road_node_id,p_images)`; `get_my_donation_dashboard_v2()`, `get_my_donation_detail(p_donation)`, `get_authorized_audit_events('DONATION',p_donation)`, `cancel_donation(p_donation,p_request)`, `reserve_hub_capacity(p_donation,p_hub)`, `get_eligible_hubs(p_donation)`, `get_hub_options(p_donation)` | Donation/listing/receipt, category and hub choices, history/cancel; required image, availability, eligibility, existing claim/reservation or lifecycle transition. |
| NGO listing/claim, `donation_pages.dart` | `discover_eligible_listing_cards()`, `get_eligible_listing_constituents(p_listing)`, `get_claimed_listing_detail(p_claim)`, `get_claimed_listing_constituents(p_claim)`, `get_donation_images(p_donation)`, `get_batch_images(p_batch)`, `claim_listing(p_listing,p_request)` (via persisted claim helper) | Detail and claim receipt/cards; request conflict, listing already taken/expired, not eligible, route/lease hold. |
| Claim cards and cancellation | `get_my_claim_cards_v2()`, `cancel_claim(p_claim,p_request)`, `get_my_claim_reconciliation_receipt(p_request)` | Active/history card, idempotent cancellation/reconciliation receipt; custody/route/reconciliation state can block. |
| NGO route execution/repository | `get_my_routing_overview()`, `list_my_vehicles()`, `get_my_authorized_route(p_route)`, `start_pickup(p_claim)`, `complete_pickup(p_claim,p_handover_confirmed)`, `defer_my_pickup_for_reconciliation(p_claim,p_request)`, route planning/authorization RPCs; receipt calls | Authorized route/next-stop flags and immutable request receipts. Role, candidate, ownership, version, lease, custody, other-dispatched-stop and unresolved route case are server guards. |
| Route-resolution repository | `list_my_route_resolution_cases()`, `get_my_route_resolution(p_route)`, `get_my_donation_route_resolution(p_donation)`, `get_my_donation_claim_reconciliation(p_donation)`, `submit_claim_reconciliation(p_claim,p_handover_confirmed,p_request)`, `report_my_route_interruption(p_route,p_reason,p_request)`, `submit_route_resolution_evidence(p_case,p_task,p_assertion,p_version,p_request)`, `report_route_resolution_incident(p_case,p_task,p_assertion,p_request)`, corresponding receipts | Protected route/case views; idempotent request IDs, version conflict, participant/role check, report/evidence state restrictions. `finalize_route_resolution` has no client call and is restricted. |
| Hub operations | `register_my_hub(...)`, `get_my_hub_inventory(p_hub)`, `get_my_hub_inventory_v2(p_hub)`, `get_my_hub_batches_dashboard(p_hub)`, `get_my_hub_reservations(p_hub)`, `get_my_hub_dropoffs(p_hub)`, `confirm_hub_receipt(p_reservation,p_received_weight)`, `publish_whole_donation_batch(p_hub,p_donation_ids)`, hub detail/activity/image/service-rule RPCs | Inventory, reservations, batches and receipts; admin verification, open hours, capacity, category/vehicle access, batch atomicity. |

The client also calls Supabase Auth directly for sign-in/sign-up/verification/password reset/update and Storage signed URLs. It does not issue direct SQL. Dynamic `_call`/`_rpc` methods in the routing repositories carry the request ID and normalize JSON/list responses. Receipt timeouts remain visible and are recovered by querying the same request ID; the app avoids blind write retries.

## 5. Per-stop reconciliation migration and retirement analysis

### Local source and deployed behavior

The named migration is present as `docs/stage8/stage-a/forward-migrations/20261108_per_stop_reconciliation.sql`, not under `supabase/migrations/`. Local `supabase/migrations/` currently ends at `20261031_claim_audit_and_failure_capture.sql`; it contains no 20261108 migration. Earlier route interruption source is `docs/stage8/stage-a/forward-migrations/20261106_route_interruption_resolution.sql`, with donor read additions in `20261107_donor_route_resolution_read.sql`.

**Live DEV confirmation:** expected 20261108-era functions exist, with expected arguments/return types, `SECURITY DEFINER`, fixed `pg_catalog, pg_temp` (or explicit public where needed) search paths, and the principal route/deferred guards in their source. `defer_my_pickup_for_reconciliation` and `close_my_resolved_route` both contain `WHOLE_ROUTE_INTERRUPTION_REQUIRES_RECONCILIATION`. `get_my_authorized_route` reports `can_defer` only when no route case is `AWAITING_EVIDENCE`/`MANUAL_REVIEW`. `submit_route_resolution_evidence` enforces source/NGO participant, current case version, allowed assertions, and locks the managed route/reconciliation scope. `get_my_route_resolution`/`get_my_donation_claim_reconciliation` are present as expected.

The local 20261108 script **does not define** all of those named route-case APIs; it forward-patches selected private route guards and defines per-stop defer, mixed-route close, claim reconciliation hooks and reads. Route interruption APIs and resolver behavior are defined in the prior 20261106 migration. Hence compare the combined forward chain 20261106→07→08 with live catalog definitions, not the 20261108 file alone. The local `supabase/migrations` directory and the connected project’s absent migration ledger are both incomplete provenance; do not conclude “not deployed” from either. Catalog behavior matches the intended chain for the inspected functions, but exact byte/hash equivalence of every deployed function to every local source file was not established.

### The three separate workflows

| Flow | Participant question | Durable evidence | Effect and safety boundary |
|---|---|---|---|
| Individual claim reconciliation | For this one donation claim, did handover/collection occur? | `claim_reconciliation_cases` + `claim_reconciliation_evidence`; each source and NGO submits boolean. | Resolves one claim/batch only under custody rules. A dispatched no-handover claim stays manual review; no route or vehicle authority by itself. |
| Route-wide interruption | On every task in an interrupted route, where are goods, and did vehicle return to NGO control? | `resolution_private.cases/items/evidence`; per-task source+NGO statements plus separate NGO vehicle assertion. | Holds the complete route, and restricted resolver rechecks manifest, every task, vehicle and bindings before releasing route/task assignments. |
| Per-stop deferral | May an eligible, unstarted pickup be removed while the NGO continues other safe route stops? | `routing_private.deferred_stops/events/requests` plus claim reconciliation state/receipts. | Narrow safe detach; disallowed if any route-wide interruption case remains unresolved or any task has been dispatched. Other stops can proceed only when these preconditions hold. |

These systems interact deliberately: an individual discrepancy can mark a claim and lease `RECONCILIATION_REQUIRED`; per-stop deferral handles only a not-yet-started, safe pickup so a route can continue; a route-wide interruption holds and snapshots all assignments and requires route evidence for every task, including never-started tasks, plus vehicle return. Final route closure checks every task and releases the route/vehicle only after complete accountability. Existing evidence/history is immutable/append-only.

### Test 10 current live state

Verified by exact IDs and independent title lookup (`Test 10`):

| Item | Current DEV state |
|---|---|
| Donation `9505c1ad-2116-42cf-961f-8b883cf1aa62` | Title `Test 10`; `PICKUP_IN_PROGRESS`. |
| Claim `73f345b8-c293-454e-8bea-16d91019fc3c` | `RECONCILIATION_REQUIRED`; individual case `93165fa6-76a9-4dc9-82a8-a8362fcfe9b2` is `MANUAL_REVIEW`. DONOR and NGO individual evidence both currently say not collected (`handover_confirmed=false`). Because task had already reached `DISPATCHED`, matching negatives do not auto-release custody. |
| Route `db1b455e-92d0-4d58-9fa1-5de07d7ab0f9` | `IN_PROGRESS`; Test 10’s pickup task `0cc74890-12b8-418f-a926-080f22602b51` is `DISPATCHED`. |
| Route interruption `075e845c-9e00-4821-b36e-3f16d8c743ce` | `AWAITING_EVIDENCE`, version 6, reason `OTHER_REQUIRES_REVIEW`. Only unresolved route case returned in live catalog query. |
| Other route tasks in that case | Two tasks were `NEVER_STARTED`; neither has a current NGO or source assertion. For Test 10’s dispatched task, both NGO and source actors have latest `NO_HANDOVER_SOURCE_RETAINS_GOODS` route assertions. |
| Vehicle assertion | Missing. There is no `task_id IS NULL` evidence for this case; only the NGO can supply `VEHICLE_RETURNED_TO_NGO_CONTROL`. |

**Authorized next actions, not performed:** the NGO participant may submit the missing route-level vehicle-return assertion if it is accurate, and the relevant source/NGO participants may submit allowed assertions for each never-started task. Then the restricted `geolock_route_resolver` workflow may attempt finalization against the current version; all live checks must still pass. Because the Test 10 individual case is manual review and one route stop was dispatched, release/closure must go through the guarded route resolver and its transaction checks, not a direct status update. A resolver may refuse or retain manual review if source/vehicle/custody/manifest state does not match. No evidence was submitted and no resolver was invoked.

### Is it safe to retire route-level UI?

**Not yet.** Confirmed live facts: one unresolved route-wide case exists; future cases remain creatable by `report_my_route_interruption`; participant route evidence remains necessary for restricted finalization; the feature is enabled; route and per-stop operations contain unresolved-case guards; and Test 10 is not currently complete. The route UI is the only participant UI found that invokes `submit_route_resolution_evidence`, including vehicle accountability and per-task assertions. The restricted resolver is an operator function, not a replacement participant evidence source.

Removing only the screen while leaving existing functions/guards intact would preserve database safety but leave participant evidence paths inaccessible from Flutter and strand the current case; future cases would face the same gap. Replacing route evidence with individual claim evidence alone is insufficient: there are multiple claims/stops, never-started stops still need route-level custody disposition, a vehicle return assertion is independent, and finalizer code does not consume claim evidence as equivalent route assertions.

### Forward-only change requirements

- **Flutter-only retirement** is safe only after a fully operational alternative can resolve every existing/open route case and provide participant or delegated evidence for future cases. Maintain the current route UI or feature gate in a way that keeps already-open cases accessible until closure. Do not silently disable `GEOLOCK_ROUTE_RESOLUTION_ENABLED` for all participants while cases exist.
- **SQL changes are required** if the intended business contract removes route-level participant assertions from finalization, changes interruption holds, or lets claim evidence release routes. That is a forward-only migration: preserve old evidence/cases/receipts; retain route/vehicle/custody checks; design explicit authority for never-started/dispatched task disposition and vehicle return; update route guards (`defer_my_pickup_for_reconciliation`, `get_my_authorized_route`, `close_my_resolved_route`, route resolver finalizer/guards); define legacy open-case resolution; use audited receipts, version checks, immutable history and idempotency; test direct and hub-batch atomicity plus mixed/deferred routes before DEV rollout. Removing tables/history or editing old migration files is not appropriate.
- **Recommendation for sequence:** (1) keep current UI; (2) design and review an alternative authorized interruption-resolution workflow, including Test 10’s existing case treatment and future cases; (3) build isolated/offline regression coverage for all open-case, custody, route, vehicle, direct/hub batch, deferral and mixed-close paths; (4) only then prepare forward SQL and Flutter together; (5) read-only preflight, explicit deployment approval, migration, postflight and participant usability check. No implementation was made.

## 6. Risks and follow-up

1. **Current open blocker:** Test 10 route interruption plus individual claim are unresolved. Without the current participant UI or another authorized participant-evidence workflow, the route cannot be safely resolved.
2. **Catalog/migration provenance gap:** DB migration ledger absent and `list_migrations` empty. Keep a deployment source manifest/hash outside the DB and compare deployed functions to the combined forward chain.
3. **Background recovery:** active per-minute claim recovery can change claim state during future audits; take a fresh consistent snapshot before acting. This audit never called it.
4. **RLS/API review:** all public tables enable RLS, but routine ACLs and `SECURITY DEFINER` functions need per-function review; some routines have broad `anon` execute privileges. Continue checking routine grants, fixed search path, authorization predicates and returned PII.
5. **State is multi-table:** donation, listing, claim, lease, task, route binding, route item, route-case evidence and individual case must be read together. Stale route versions and source/vehicle changes can make evidence/finalization fail safely.
6. **No index usage conclusion:** index “unused” status requires stable usage statistics and representative workload, which were not captured.
7. **Local working tree:** pre-existing edits/untracked content may not be the author’s intended final source; review `git status` before future changes and do not discard them.

## 7. References for continued development

- App startup and DEV guard: `frontend/geolock_hub_app/lib/main.dart`, `lib/supabase_config.dart`.
- Registration/profile: `lib/auth/auth_controller.dart`, `lib/auth/auth_pages.dart`.
- Role dashboards and navigation: `lib/dashboard_pages.dart`.
- Donation, claims, hub, individual claim reconciliation: `lib/donation_pages.dart`, `lib/claim_request.dart`, `lib/claim_cards_controller.dart`.
- Route interruptions and participant UI: `lib/routing/route_resolution_page.dart`, `lib/routing/route_resolution_repository.dart`.
- Route planning/execution/defer: `lib/routing/ngo_routing_repository.dart`, `lib/routing/route_execution_controller.dart`, `lib/routing/ngo_routes_page.dart`.
- Interruption SQL source: `docs/stage8/stage-a/forward-migrations/20261106_route_interruption_resolution.sql`.
- Donor route read source: `docs/stage8/stage-a/forward-migrations/20261107_donor_route_resolution_read.sql`.
- Per-stop/defer source: `docs/stage8/stage-a/forward-migrations/20261108_per_stop_reconciliation.sql`.
- Current tracked migrations: `supabase/migrations/` (last local file `20261031_claim_audit_and_failure_capture.sql`).
- Tests: `frontend/geolock_hub_app/test/`, `supabase/tests/`, plus isolated review suites under `docs/stage8/`.

The most safety-relevant live function definitions are `submit_route_resolution_evidence`, `finalize_route_resolution`, `get_my_route_resolution`, `get_my_donation_claim_reconciliation`, `defer_my_pickup_for_reconciliation`, `get_my_authorized_route`, `close_my_resolved_route`, `submit_claim_reconciliation`, `routing_private.task_guard`, `routing_private.lock_reconciliation_scope`, and `fleet_private.route_vehicle_guard`. Retrieve their live definitions from `pg_get_functiondef(to_regprocedure(...))` before any implementation or deployment.
