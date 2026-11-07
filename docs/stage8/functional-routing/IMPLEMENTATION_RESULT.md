# Functional post-claim routing — implementation result

27 October2026 MYT. Authentication investigation and failed road export work are paused. **No DEV connection, data mutation, policy installation, graph freeze or worker activation occurred. StageA003 remains closed.**

## Working result

**PASS: real disposable local PostgreSQL claim→planning HTTP→independent validator process→route authorization→pickup→depot closure.** Final captured results: `results/postclaim-local-e2e/20261026T184052Z-64c95e/`.

This is a database/HTTP integration test, not mocked database success and not live Supabase acceptance. It uses PostgreSQL17.11, real PostGIS3.6.2/pgRouting4.0.1 and OR-Tools9.15.6755. DEV GIS versions are3.3.7/3.4.1, so GIS/runtime parity remains unproved. Synthetic local adapters implement auth.uid/role, Storage metadata and an inert cron catalog; no actual Supabase JWT verification, Storage bytes, recovery scheduler or Flutter device run is claimed. Local connection injection replaces production DSN targeting/TLS with a fixed trusted loopback transport; actual PostgreSQL worker-role membership/ACL and routing-permit guards remain exercised. Flutter repository tests separately replay the **actual captured** backend payloads; their transport is explicitly a test double.

Stable two-node/two-directed-arc/one-vehicle/one-donation fixtures have no route-order ambiguity. Actual RPCs still generate IDs/timestamps; byte-for-byte solver/runtime reproducibility is not asserted. Local policy retains the proposed business values but uses a one-second solver budget for the tiny fixture; the proposed DEV policy JSON/hash/request were not changed.

Final SQL facts: taskCOLLECTED, donationCOLLECTED, claimCOMPLETED, leaseCOMPLETED, routeCOMPLETED, assignments0, vehicle_holdfalse. Audit rows include CLAIM_ATTEMPT, AUTHORIZE_ROUTING, START_PICKUP, COMPLETE_PICKUP and CLOSE_COLLECTED_ROUTE. Assertions verify the exact donation audit chain AVAILABLE→CLAIMED→PICKUP_IN_PROGRESS→COLLECTED, NGO actor, donation/claim identity, lease context and SUCCESS outcomes. Reservations remained held after collection until depot confirmation. Both worker services and the owned cluster stopped; data/evidence retained for inspection.

## Actual workflow audit

Paths below are repository-relative. Every stage is implemented for the demonstrated direct-donation happy path; no new business RPC is invented.

| Stage | Existing implementation | Inputs / permission | Evidence / exact DEV blocker |
|---|---|---|---|
| Claim succeeds | `frontend/geolock_hub_app/lib/donation_pages.dart` persisted claim request→`claim_listing`; actual20261031 SQL | Active NGO, READY/eligible AVAILABLE listing, donor/source rules, fresh idempotent request; authenticated actor | Real local donation-creation and claim RPC SUCCESS, replay no duplicate. DEV claim functionality predates routing; no new DEV claim was attempted. |
| Identify eligible claims | `get_my_routing_overview`, `routing_private.admissible`, selected-vehicle snapshot | Owned CONFIRMED tasks, active source/claim/lease, verified depot; expiry strictly beyond horizon+margin | Actual local snapshot contains claimed task. With240+15, require>255 minutes remaining. Existing expired leases cannot qualify. DEV policy absent; fresh eligible sources needed. |
| Request planning | `NgoRoutesPage._generate`, `NgoRoutingRepository.plan`, `POST /v1/plan` | NGO JWT, selected owned vehicle IDs, policy_id, stable request/snapshot IDs; no client-written plan | Real local planner HTTP endpoint exercised with explicit synthetic local Auth adapter. DEV API endpoint/worker activation missing. |
| Obtain road costs | GraphCache→`read_frozen_routing_graph`→C.2 matrix→`store_routing_matrix` | Dedicated graph login/role; actual frozen graph_id, complete export, supported REAL projection, directed available pairs | Actual protected local graph export and stored matrix distances/times [[0,1],[1,0]]. No forged matrices. DEV graph not frozen; current equivalence/reachability evidence remains unverified. |
| Generate candidate | `RoutingWorker.plan`→`solve_bundle`→actual RoutingModel/other three methods→`submit_routing_candidate` | Sealed snapshot, fleet capacities/costs/windows, real matrix; planner role | Real four-method response, proposed feasible candidate, no route authority. DEV planner not active/configured/warmed. No AI-ranking component changed. |
| Independent validation | RemoteValidator→separate validator HTTP OS process→`validate_work_item`→`attest_routing_candidate` | Validator-only login/role, private endpoint/token, matching source/matrix/candidate digests | Actual separate PID and validator-role attestation valid/feasible recorded. DEV independent validator not activated. |
| Authorize and assign | Flutter calls `authorize_my_routing_candidate`; SQL rechecks current data and books tasks/vehicle | NGO ownership, ATTESTED candidate, future actual departure, valid lease/window/capacity/current source | Actual DB routeAUTHORISED, taskPLANNED; planner candidate alone created no route. DEV requires initialized graph/policy/worker-generated candidate. |
| Show assigned route | `get_my_authorized_route`, `NgoRouteDetailPage`, fresh backend flags | Owned route, geolock.ngo-routing.v1 response, backend-confirmed action permissions | Actual SQL response accepted by Flutter repository test; existing widget tests passed. Real device/JWT/PostgREST access not demonstrated. |
| Start pickup | Repository fresh detail→`start_pickup`→003 permit/source/order/departure guards | Owner, authorized departure and next-stop authority | Actual local taskDISPATCHED, routeIN_PROGRESS, donationPICKUP_IN_PROGRESS. Unrouted and worker dispatch denied. |
| Complete pickup | Fresh detail→`complete_pickup(...,true)` | Actual handover confirmation, active claim/lease, valid authority | Actual collection/custody updates. False confirmation rolled back without state/audit delta. Local action represents fixture handover, not a physical measurement. |
| Return depot/close | `close_my_collected_route(...,true)` | Explicit depot return confirmation; all tasks resolved | Actual DB close released assignment/vehicle; false depot confirmation rejected. DEV route needed first. No invented GPS-return rule. |

## Implemented/fixed

* Added `supabase/tests/postclaim_local_e2e.py`: fresh owned loopback cluster, exact historical SQL and unchanged A001/A002/A003, actual source creation/eligibility/claim, real separate-role worker SQL, actual planner+validator HTTP, independent validator process, actual pickup/closure and audit assertions. No DSN/URL/existing server accepted. Environment remote DB variables are removed from this process/children. No approved migration guards were changed; B.2/B.4.3 are not applied.
* Fixed the existing C.5 local assembly helper: the snapshot already contained its depot trigger. The helper now verifies/preserves it rather than blindly creating a duplicate. A differing trigger still fails. A local Supabase schema-USAGE baseline and exact claim-card reader source are supplied explicitly; no fake pg_extension entry or scheduler is installed.
* Fixed graph endpoint validation in `backend/routing/phase_c2/matrices.py`: build one node set and use constant-time membership rather than scanning up to926414 nodes for every endpoint of2.1m edges. Validation semantics/canonical output stay unchanged. Full DEV graph warm-up/memory remains unmeasured; this code change does not establish its performance envelope.
* Added `frontend/geolock_hub_app/test/postclaim_contract_capture_test.dart`: exercises the existing repository's planning, authorization, fresh detail/pickup, completion and closure interfaces with real captured backend DTOs. Existing working UI/repository components were preserved.

## Tests actually executed

| Test | Result |
|---|---|
| Final new local integration runner | PASS,39.516s; real claim/HTTP/validator/authorization/collection/closure, six negative/replay checks and audit-integrity assertions |
| Six checks | Claim replay creates no duplicate; graph worker cannot dispatch; unrouted pickup rejected; foreign NGO route read denied; false handover rolls back without audit/state delta; depot confirmation required |
| C.2 unittest discovery |24/24 PASS,97.483s |
| Flutter selected regression/capture suite |51/51 PASS, including actual first successful local capture; existing NGO routing, worker client, claim request/cards |
| Final-capture-only Flutter test |1/1 PASS after formatting, against final39.516s integration output; no remote transport |

Initial local bootstrap failures and their stopped clusters remain as evidence. Windows sandbox token prevented PostgreSQL/Flutter startup; authorized local tests ran outside that sandbox. No security policy or DEV permission was changed. Local historical assembly required the depot-trigger fix and platform schema-USAGE fixture; the first worker request needed proper PostgREST JSON wire serialization of psycopg UUID/datetime values in the local Auth adapter. These were harness issues, not silently repaired DEV state.

To reproduce the database integration from the repository root with the existing private runtime:

```powershell
.venv-stage8/Scripts/python.exe -B supabase/tests/postclaim_local_e2e.py --run-local --runtime "$env:TEMP/geolock-spatial-runtime-24dbda5e04a04d48bd8d8dab0299d7eb"
```

This creates another NEW local results directory/cluster. It never attaches to DEV/system services and does not accept remote DSNs. It retains stopped cluster data for inspection; this is not a cloud TEST project. The case exercises a direct donation; a full real-schema hub-batch pilot and concurrent multi-operator acceptance are still unverified.

## Minimum DEV path: mandatory functional blockers

1. **Approve and install the exact policy** through its existing separately reviewed graph-role operation. Business JSON/hash/request unchanged. Confirm service/horizon choices; new valid claims must satisfy them.
2. **Approve the real graph freeze and satisfy its source gates.** Use actual approved coverage, required precision/profile and freeze RPC. Preserve the global maintenance-freeze decision. Current DEV import equivalence is NOT VERIFIED and this local test does not resolve it. Any qualification/risk acceptance needs an explicit owner decision; no fabricated proof or bypass of existing gates.
3. **Configure dedicated worker identities and separate validator/planner services**, actual graph_id, trusted endpoints, protected state and validator token. Owner/export credential is never a runtime substitute. Existing Python-export owner-login failure does not prove the separately configured worker logins fail; do not resume password troubleshooting without a concrete activation need. Verify their scoped access when activation is approved.
4. **Warm and smoke-test actual graph/matrix inputs**, valid pilot node pairs and bounded job age/memory/runtime, then separately approve activation. The endpoint set fix addresses a known scaling issue; it does not replace DEV-scale verification. Existing graph/policy source approval must precede request-driven matrix/candidate writes.
5. **Connect Flutter to the planner**, e.g. existing `GEOLOCK_ROUTING_API_URL` with DEV environment. Emulator debug allowshttp://10.0.2.2:8787; physical/release needs a trusted reachable HTTPS endpoint. Keep validator private. Real NGO session, verified depot and at least one active/available owned vehicle are required.
6. **Approve a narrowly scoped real pilot** using a valid current claim; execute the demonstrated flow under real Supabase JWT/PostgREST and device/network configuration. Existing expired claims remain ineligible; no recovery or live fixture creation is implied. Fresh legitimate claims do not require enabling the expired-claim scheduler.

These are operational/configuration/approval blockers; no missing Dart routing screen or business RPC was found for the demonstrated path.

## Work that need not delay this bounded DEV feature pilot

Production HA/multi-replica journal coordination, broad load/chaos benchmarking, exhaustive historical migration reconstruction, physical-device breadth and complete provider/external backup recovery are separate assurance/hardening work. Full import comparison is not what makes the SQL APIs operate, but **any current approved source/freeze gate remains binding**; its unknown status cannot be relabeled PASS or silently waived. Known concurrency, GIS-version and hub-batch risks must be considered for a wider pilot rather than inferred covered by this case. No B.2/B.4.3 migration is automatically scheduled by this result.

Exact verification invocations (run from the repository root for Python; from the Flutter app directory for Flutter):

```powershell
.venv-stage8/Scripts/python.exe -B -m unittest discover -s backend/routing/phase_c2/tests -t . -q
```

```powershell
& 'C:/flutter/src/flutter/bin/flutter.bat' --no-version-check test --no-pub --dart-define=GEOLOCK_LOCAL_ROUTING_CAPTURE=C:/Users/User/Downloads/FYP-GeoLock_Hub/results/postclaim-local-e2e/20261026T182222Z-e4d080/flutter-contract-capture.json test/postclaim_contract_capture_test.dart test/ngo_routing_test.dart test/routing_worker_client_test.dart test/claim_request_test.dart test/claim_card_test.dart
```

```powershell
& 'C:/flutter/src/flutter/bin/flutter.bat' --no-version-check test --no-pub --dart-define=GEOLOCK_LOCAL_ROUTING_CAPTURE=C:/Users/User/Downloads/FYP-GeoLock_Hub/results/postclaim-local-e2e/20261026T184052Z-64c95e/flutter-contract-capture.json test/postclaim_contract_capture_test.dart
```

The51-case suite used the first successful capture; the additional one-case run verified the final capture after audit assertions and formatting. These are distinct executions, not52 unique tests or a live Flutter/DEV run.

## Native psql supports remaining read-only preparation

The already successful approved native psql17.11 connection can run [DEV_READONLY_PREPARATION.sql](DEV_READONLY_PREPARATION.sql) with the existing `geolock_dev_owner_export` profile, TLSverify-full and its read-only startup option. This is a small policy/graph/coverage/role inventory plus three indexed node lookups, not an auth diagnostic, graph algorithm or full export. Codex did not execute it or request a password.

```powershell
$env:PGSERVICEFILE = 'C:\Users\User\Downloads\FYP-GeoLock_Hub\backups\stage-a003\pg_service.conf'
& 'C:\Program Files\PostgreSQL\17\bin\psql.exe' -X -W --dbname 'service=geolock_dev_owner_export' --set ON_ERROR_STOP=1 --file 'C:\Users\User\Downloads\FYP-GeoLock_Hub\docs\stage8\functional-routing\DEV_READONLY_PREPARATION.sql'
```

No role, data, configuration or routing state is changed. This owner-profile read-only preparation is distinct from runtime graph/planner/validator roles. Full native road export/comparison can be prepared later if required by the chosen source gate; it is not restarted by this report.

## Decisions now

Approve the existing policy values, confirm graph-source qualifications and permanent maintenance-freeze acceptance, choose the planner/validator hosting and pilot endpoint, then give separate exact initialization/activation/pilot approvals. No passwords are needed in chat. Local integration is working; **live DEV routing is not yet demonstrated**.
