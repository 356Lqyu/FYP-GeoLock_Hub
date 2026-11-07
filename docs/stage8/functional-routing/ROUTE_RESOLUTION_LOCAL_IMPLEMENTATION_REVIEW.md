# Route resolution LOCAL implementation review — SECURITY HOLD

29 October 2026. **NOT READY for DEV deployment review. L6 is blocked; no local
completion or deployment success is claimed.** The user required STOP on a new
security issue; implementation stopped after confirming the audit-identity defect.
No DEV connection, live business mutation, APK build/install, scheduler change,
frozen graph change or preserved-route/V2 operation occurred.

## Confirmed blocker and next approval

A correctly mapped native resolver can set a JWT subject GUC. The finalizer still
requires the restricted login, matching evidence and all custody checks, but the
new audit helper records the supplied NGO as actor and omits operator_principal.
The private receipt actor_key remains resolver-scoped, so this is not evidence of
an authority/custody bypass; it is a real violation of D02 audit attribution.
See ROUTE_RESOLUTION_OPERATOR_IDENTITY_BLOCKER.md and confirmed-security-failure.json.

Next approval: narrowly reject mixed native-resolver/JWT context before replay or
writes, derive operator audit identity from the trusted login/mapping, cover legacy
donation audits and rerun isolated regressions. No SQL fix was applied after the
security hold. Seven composite acceptance checks also remain incomplete; related
passing assertions are not claimed as full coverage. The mapping lists their gaps. Use the same local forward migration, then repin its checksum.

## Progress L0–L6

- L0: prior narrow custody contradiction resolved by explicit local user amendment;
  historical blocker retained with a dated addendum. Current D02 security hold is separate.
- L1–L3: forward source, private schema, disabled gate, scoped/versioned receipts,
  reporting, custody classification, evidence and execution fencing implemented locally.
- L4: restricted atomic finalization and both reverse custody edges tested; COLLECTED
  terminal, unsafe listing MANUAL_REVIEW, assignment/vehicle release guarded. Audit
  attribution is **not accepted**, despite successful transactional rollback tests.
- L5: default-disabled Flutter participant inbox/report/evidence/incident/history and
  persistent request reconciliation implemented. Finalization is absent from NGO UI.
  API adapters are separate fixed-RPC surfaces, not activated live HTTP endpoints.
- L6: 70-scenario suite, 3 positive SQL adapter/isolation tests and regressions pass;
  additional security negative FAILS. Stop gate prevents final readiness acceptance.

## Actual executed tests

| Command/suite | Actual result | Evidence |
| --- | --- | --- |
| `.venv-stage8/Scripts/python.exe -B supabase/tests/route_resolution_isolated_test.py --run-isolated --runtime <local-runtime>` | **70 PASS**, 0 failures/errors, 476.505s | results/route-resolution-full-final-01.log; results/automatic-routing-local/20261029T085711Z-845dc0 |
| Same Python, route_resolution_api_isolated_test.py, --run-isolated --runtime <local-runtime>, before adding the negative | **3 PASS**, 87.924s | results/route-resolution-api-sql-bridge-final-02.log; results/automatic-routing-local/20261029T090756Z-f7d528 |
| Same bridge command plus --operator-context-check | **1 FAIL**, 0 errors, 56.019s | results/route-resolution-operator-identity-regression.log; results/automatic-routing-local/20261029T091549Z-8d842f |
| `python -B -m unittest discover -s backend/routing/worker_service/tests -t . -v` | **116 PASS** | results/route-resolution-worker-regressions-02.log |
| `python -B -m unittest discover -s backend/routing/integration/tests -v` | **34 PASS** | results/route-resolution-api-regressions-01.log |
| Flutter focused resolution and existing routing suites | **97 PASS** | results/route-resolution-flutter-full-final.log |
| Flutter analyze, 7 affected Dart sources/tests | **No issues** | results/route-resolution-analysis-final-02.log |

Local runtime: C:/Users/User/AppData/Local/Temp/geolock-spatial-runtime-24dbda5e04a04d48bd8d8dab0299d7eb.
PostgreSQL **17.11**, PostGIS **3.6.2**, pgRouting **4.0.1**, Python **3.12.14**.
These spatial extension versions are NON-PARITY with DEV. Synthetic JWT-GUC auth,
Storage metadata and inert cron adapters do not prove hosted Supabase behavior.
All three cited clusters stopped cleanly; input-integrity checks show no drift and
remote/DEV connections are zero. The failing regression commits only disposable
fixture data; it is not an operation on the preserved DEV route.

The current bridge default now includes the negative (4 tests); it must **not** be
represented as a currently green suite. Positive earlier results used identical
migration/API bytes. The full 70-scenario source remains unchanged from its PASS.

Flutter invocation used Dart's flutter_tools.snapshot --no-version-check test
--no-pub, with GEOLOCK_AUTOMATIC_LOCAL_CAPTURE pointing to the existing local capture
results/automatic-routing-local/20261027T164147Z-e1313d/flutter-combined-capture.json,
and these tests: route_resolution_test.dart, route_cards_test.dart,
route_details_presentation_test.dart, routing_worker_client_test.dart,
automatic_route_operation_test.dart, routing_resume_ui_test.dart,
routing_feedback_test.dart, routing_connection_visibility_test.dart,
ngo_routing_test.dart, routing_pending_request_test.dart, proposed_route_view_test.dart.
Exact invocations are retained in the tool record; no APK command ran.

Earlier failed attempts remain preserved: hub receipt/member/photo fixture setup,
wrong parameter name in a drift fixture, privilege inspection by constructed name,
audit assertion using a nonexistent column, and a source-integrity failure while
an API file was edited during a run. These were corrected and rerun. The first
worker discovery command omitted -t ., causing package-import/console-child errors;
correct package discovery passed 116. None is silently converted into a PASS.

## Migration and function fingerprints — local draft, NOT approved for deployment

File: `docs/stage8/stage-a/forward-migrations/20261106_route_interruption_resolution.sql`

SHA-256: **d89820781ccb1d7faa773a6dfdd3e4a0d62d65f3487ddc28a48ad1c7621f34af**

One forward migration only. Default config.enabled=false; no operator mappings;
resolver is NOLOGIN. No recovery function or cron schedule modification. Existing
explicit/NULL departure RPCs, all algorithms, graph and lease deadlines preserved.
Of 143 captured public/fleet/routing baseline functions, **141** retain body/owner/
volatility/config/ACL metadata. Only enforce_donation_transition and
fleet_private.route_vehicle_guard change. Public schema USAGE for the new resolver
is an intentional new permission, not a change to old function grants.

Normalized prosrc MD5 (CRLF → LF), not full-definition MD5:

| Function | MD5 |
| --- | --- |
| enforce_donation_transition() | 50f7c982be9c6cce75174e09f73649ae |
| finalize_route_resolution(uuid,bigint,uuid) | 3650767a5a9bc4928b58193321367ed8 |
| fleet_private.route_vehicle_guard() | 30c632aae8cd73948cb82009112527f2 |
| get_my_route_resolution(uuid) | f8cf1e5807aeabb5c788761ecd540785 |
| get_my_route_resolution_receipt(uuid) | 2421041911b62dc6cd48b6859efce81c |
| get_route_resolution_for_operator(uuid) | 30859479335ce319b95fc724486de2c7 |
| list_my_route_resolution_cases() | 608e9dffc5842b793f34a399778660a3 |
| register_route_test_provenance(uuid,text,uuid,uuid,uuid[],uuid) | c11af47936e6a3894a3cadb3da8c83fa |
| report_my_route_interruption(uuid,text,uuid) | 52819df2234b131a52633ad63d2f51a4 |
| report_route_resolution_incident(uuid,uuid,text,uuid) | 34c213ee1bee4b96675e33e8953b4eb2 |
| submit_route_resolution_evidence(uuid,uuid,text,bigint,uuid) | 58234be92e9d3402df678464e250e96d |

Every new/private function fingerprint, owner, security mode, volatility/config
and actual effective role execution result is retained in
resolution-reviewed-function-metadata.json / resolution-effective-permissions.json.
These are isolated catalog observations, not fresh DEV fingerprints.

## Effective permission matrix

| Surface | authenticated | resolver role + active named session mapping | anon/service_role/graph/planner/validator |
| --- | --- | --- | --- |
| Report / evidence / incident | scoped owning NGO/source participant | denied | denied |
| Case read / participant inbox | owner/source scoped; STABLE | denied | denied |
| Receipt read | own actor/request; STABLE | own resolver actor/request; STABLE | denied |
| Finalize / provenance registration / operator read | denied | permitted subject to gates; operator read STABLE | denied |
| resolution_private direct tables/columns/functions | denied | denied | denied |

The audit defect does not expand these permissions. Current session context still
can corrupt attribution after an otherwise authorized native operation, which is
why the package is NOT READY. Trusted PostgreSQL owners can rewrite schema; no
claim of protection against an administrator changing guards/tables is made.

## Custody, idempotency, races, rollback and historical evidence

- Direct and complete immutable hub releases pass; unauthorized direct/hub reverse
  transitions and old-transaction permits fail. No COLLECTED reverse edge exists.
- Reporting fences ordinary Start/Complete/cancel/close and retains assignments.
  Expired leases can enter reconciliation without extending original deadlines.
- Existing genuine two-party collection and mixed retained-collection/release
  scenarios preserve collected states/timestamps. Unsafe expired hub/direct
  listings remain MANUAL_REVIEW and held.
- Identical reports/finalizations serialize to one case/result; changed payloads,
  stale versions and cross-actor receipts fail or are NOT_FOUND. Flutter persists
  request IDs before writes, reconciles reads and does not retry writes.
- Actual report/start/complete/recovery/reconciliation and finalization/amendment/
  recovery/report/vehicle races passed with bounded timeouts and no hidden retry.
  Two fresh claims after valid release produced one winner with a new claim ID.
- Injected failures at donation member, task, claim, lease, listing, reconciliation,
  assignment, binding, item, case, terminalization, audit and receipt phases roll
  back. Full local state digests match before/after failed finalization writes.
- An independent NGO's real local planner/independent-validator/authorization route
  retained its original route/binding/assignment and vehicle hold after this route
  finalized. No copied route was represented as authorized in that bridge test.
- Snapshots/candidates/validations/matrices/stops remain. ABANDONED is terminal;
  its protected reads disable pickup/close. Later concerns append incidents only.
- Synthetic provenance labels derive from a trusted registry, not titles/client
  flags; it cannot bypass ordinary gates. It is not discovery isolation or proof
  of physical custody. The operator-attribution failure remains unresolved.

The 58-row acceptance mapping is in acceptance-evidence.json: **50 scoped PASS,
1 FAIL and 7 BLOCKED** (composite subcriteria incomplete, including the audit hold); it is not a claim that all acceptance is
complete. Retention/institutional approval and actual hosted runtime behavior are
outside the executed local tests, not silently marked verified.

## Changed files — exact scoped source list

- [20261106_route_interruption_resolution.sql](C:/Users/User/Downloads/FYP-GeoLock_Hub/docs/stage8/stage-a/forward-migrations/20261106_route_interruption_resolution.sql) — `docs/stage8/stage-a/forward-migrations/20261106_route_interruption_resolution.sql`
- [route_resolution_isolated_test.py](C:/Users/User/Downloads/FYP-GeoLock_Hub/supabase/tests/route_resolution_isolated_test.py) — `supabase/tests/route_resolution_isolated_test.py`
- [route_resolution_api_isolated_test.py](C:/Users/User/Downloads/FYP-GeoLock_Hub/supabase/tests/route_resolution_api_isolated_test.py) — `supabase/tests/route_resolution_api_isolated_test.py`
- [route_resolution.py](C:/Users/User/Downloads/FYP-GeoLock_Hub/backend/routing/integration/route_resolution.py) — `backend/routing/integration/route_resolution.py`
- [test_route_resolution.py](C:/Users/User/Downloads/FYP-GeoLock_Hub/backend/routing/integration/tests/test_route_resolution.py) — `backend/routing/integration/tests/test_route_resolution.py`
- [route_resolution_repository.dart](C:/Users/User/Downloads/FYP-GeoLock_Hub/frontend/geolock_hub_app/lib/routing/route_resolution_repository.dart) — `frontend/geolock_hub_app/lib/routing/route_resolution_repository.dart`
- [route_resolution_page.dart](C:/Users/User/Downloads/FYP-GeoLock_Hub/frontend/geolock_hub_app/lib/routing/route_resolution_page.dart) — `frontend/geolock_hub_app/lib/routing/route_resolution_page.dart`
- [route_resolution_test.dart](C:/Users/User/Downloads/FYP-GeoLock_Hub/frontend/geolock_hub_app/test/route_resolution_test.dart) — `frontend/geolock_hub_app/test/route_resolution_test.dart`
- [ngo_routes_page.dart](C:/Users/User/Downloads/FYP-GeoLock_Hub/frontend/geolock_hub_app/lib/routing/ngo_routes_page.dart) — `frontend/geolock_hub_app/lib/routing/ngo_routes_page.dart`
- [ngo_routing_repository.dart](C:/Users/User/Downloads/FYP-GeoLock_Hub/frontend/geolock_hub_app/lib/routing/ngo_routing_repository.dart) — `frontend/geolock_hub_app/lib/routing/ngo_routing_repository.dart`
- [route_card_view.dart](C:/Users/User/Downloads/FYP-GeoLock_Hub/frontend/geolock_hub_app/lib/routing/route_card_view.dart) — `frontend/geolock_hub_app/lib/routing/route_card_view.dart`
- [donation_pages.dart](C:/Users/User/Downloads/FYP-GeoLock_Hub/frontend/geolock_hub_app/lib/donation_pages.dart) — `frontend/geolock_hub_app/lib/donation_pages.dart`
- [ROUTE_RESOLUTION_DECISION_REGISTER.md](C:/Users/User/Downloads/FYP-GeoLock_Hub/docs/stage8/functional-routing/ROUTE_RESOLUTION_DECISION_REGISTER.md) — `docs/stage8/functional-routing/ROUTE_RESOLUTION_DECISION_REGISTER.md`
- [ROUTE_RESOLUTION_LOCAL_PLAN_AND_ACCEPTANCE.md](C:/Users/User/Downloads/FYP-GeoLock_Hub/docs/stage8/functional-routing/ROUTE_RESOLUTION_LOCAL_PLAN_AND_ACCEPTANCE.md) — `docs/stage8/functional-routing/ROUTE_RESOLUTION_LOCAL_PLAN_AND_ACCEPTANCE.md`
- [ROUTE_RESOLUTION_L0_CONTRACT_BLOCKER.md](C:/Users/User/Downloads/FYP-GeoLock_Hub/docs/stage8/functional-routing/ROUTE_RESOLUTION_L0_CONTRACT_BLOCKER.md) — `docs/stage8/functional-routing/ROUTE_RESOLUTION_L0_CONTRACT_BLOCKER.md`
- [ROUTE_RESOLUTION_CONTRACT_AMENDMENT.local-draft.md](C:/Users/User/Downloads/FYP-GeoLock_Hub/docs/stage8/functional-routing/ROUTE_RESOLUTION_CONTRACT_AMENDMENT.local-draft.md) — `docs/stage8/functional-routing/ROUTE_RESOLUTION_CONTRACT_AMENDMENT.local-draft.md`
- [ROUTE_RESOLUTION_DEPLOYMENT_REVIEW_PLAN.md](C:/Users/User/Downloads/FYP-GeoLock_Hub/docs/stage8/functional-routing/ROUTE_RESOLUTION_DEPLOYMENT_REVIEW_PLAN.md) — `docs/stage8/functional-routing/ROUTE_RESOLUTION_DEPLOYMENT_REVIEW_PLAN.md`
- [ROUTE_RESOLUTION_OPERATOR_IDENTITY_BLOCKER.md](C:/Users/User/Downloads/FYP-GeoLock_Hub/docs/stage8/functional-routing/ROUTE_RESOLUTION_OPERATOR_IDENTITY_BLOCKER.md) — `docs/stage8/functional-routing/ROUTE_RESOLUTION_OPERATOR_IDENTITY_BLOCKER.md`

This report itself and the generated review artifacts are additional deliverables.
The repository already contained many untracked files and unrelated pending claim
harness changes. No reset/cleanup was performed. The scoped diff excludes those
unrelated changes; see implementation.patch and changed-files.json. Some existing
routing source is untracked in Git; its feature-specific before-image is reconstructed
by removing only this feature's small additions, explicitly identified in the manifest.

## Remaining limitations and future controls

- **Security blocker:** reject mixed operator/JWT context and ensure trusted audit
  attribution; approval to implement this correction is requested separately.
- No hosted PostgREST/JWT parity, real pg_cron daemon, live permission checks,
  physical handover, GPS verification, DEV route resolution or Android deployment
  is claimed. Bounded races are evidence, not a proof of all possible interleavings.
- D07 retention is provisional; D10 contract draft is not supervisor acceptance.
  The independent synthetic DEV manifest remains unbound and unapproved; no real
  fixture creation is authorized. No unsafe expired-listing withdrawal exists.
- Default database/Flutter/API gates remain disabled. No new service activation or
  automatic resolver endpoint exists. Future installer authority, role inheritance,
  named operator mapping, fresh backup/recovery controls and writer plan need review.
- See ROUTE_RESOLUTION_DEPLOYMENT_REVIEW_PLAN.md for future deployment, postflight,
  pause/forward-correction and receipt reconciliation. No destructive DOWN migration
  is offered. Never delete history, revive old claims or undo committed collection.
- The preserved route db1b455e-92d0-4d58-9fa1-5de07d7ab0f9 and V2 were not accessed
  or changed. Their live state is not certified; existing cron may still act under
  its existing settings. Future resolution may remain MANUAL_REVIEW for unsafe expiry.
