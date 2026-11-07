# Next checkpoint — separately approved routing initialization

**Functional-delivery priority update,27 October2026:** the owner paused authentication/road-export investigation. A real disposable local database/HTTP claim-to-depot lifecycle now passes, with explicit Auth/Storage/cron adapters and separate Flutter contract replay. See [functional implementation result](../../functional-routing/IMPLEMENTATION_RESULT.md). No DEV writes/initialization are authorized; the exact policy/graph proposals and their source qualifications below remain unchanged. Native psql can support the prepared read-only input inspection without restarting Python password diagnostics.

**Preparation update, 27 October 2026 MYT:** 003 milestone closed by owner instruction. Proposed exact policy, requests, commands, separate A/B approval gates and evidence are now in [routing-initialization/APPROVAL_PACKAGE.md](routing-initialization/APPROVAL_PACKAGE.md). Values are **NOT YET APPROVED**; no initialization occurred. Proposed inputs are supplied there; approval, current-DEV reachability and qualified provenance decisions remain outstanding. Historical statements below describe the original handoff state.

The next secure read-only road export/comparison is fully prepared in [CURRENT_DEV_EXPORT_AND_EQUIVALENCE.md](routing-initialization/CURRENT_DEV_EXPORT_AND_EQUIVALENCE.md), with the unchanged policy reviewed in [POLICY_BUSINESS_REVIEW.md](routing-initialization/POLICY_BUSINESS_REVIEW.md). Full current-DEV equivalence remains **NOT VERIFIED pending the local password-prompted export**. No write approval is implied.

**PREPARED ONLY. NOT AUTHORIZED / NOT EXECUTED.** Stage A 003 is now **DEPLOYED / POSTFLIGHT PASS** in the scope of `POSTDEPLOYMENT_ASSESSMENT.md`. That status does not install policy, freeze a graph, activate workers, recover leases or create test fixtures. No defaults, road records, candidates or validation reports are invented here.

## Current state and immediate prerequisite

All 11 routing_private tables were empty at **21:13:32 MYT on 26 October 2026**. An approved active operational coverage `OSM-OPS-20261018` exists; it is not itself a frozen routing manifest. Prior role evidence includes separate graph/planner/validator LOGINs and their worker-role memberships; credentials, approved TLS/service profiles, independent deployment and current process activation must still be checked before use. Recovery scheduler remains disabled. Two expired ACTIVE leases remain ineligible.

Prepare exact inputs locally first. Initial writes should be limited to the reviewed policy installation and graph-manifest freeze under the approved graph-worker identity. All snapshots, matrices, candidates, attestations, route bindings and permits must be produced later by actual protected operations; do not manually seed them. `legacy_inflight` and cancellation history may correctly remain empty.

## 1. Policy installation approval

Owner must provide and approve one complete policy JSON file. Codex can validate it offline against the actual SQL/Python contracts and freeze its SHA-256 plus a stable request UUID for review. Do not reuse synthetic test/benchmark settings as operational approval.

Required top-level fields:

| Field | Decision / contract |
|---|---|
| mandatory | Explicit boolean business choice, not a chosen default |
| horizon_minutes | Positive finite number, ≤1440 under SQL; also compatible with available lease lengths and planning/dispatch margin |
| dispatch_margin_minutes | Explicit finite nonnegative value |
| direct_service_minutes / hub_service_minutes | Explicit finite nonnegative service assumptions for each source type |
| solver | Exact `engine`, `version`, `time_limit_seconds`, `workers`, `seed`, `first_solution`, `local_search`, `tie_break`, `timeout_policy` object required by `backend/routing/contract.py` |
| execution | Explicit supported `ExecutionConfig` fields: fixed_cost_weight, distance_cost_weight, deterministic_seconds_per_pass; validate finite nonnegative values and positive combined cost weighting |

Existing engine-contract constants include OR_TOOLS, one worker, PATH_CHEAPEST_ARC, GUIDED_LOCAL_SEARCH, TASK_ID_THEN_VEHICLE_ID and VALIDATED_INCUMBENT_ONLY. These are implementation constraints, **not proposed business settings**. Record actual installed solver version and validate it against the code/runtime; do not invent it. SQL's basic JSON checks alone do not prove the complete Python contract is satisfied.

Actual write operation after exact approval: **`public.install_routing_policy(p_request uuid,p_body jsonb)`**, called through the approved `geolock_graph_login` session with `SET LOCAL ROLE geolock_graph_worker` inside a reviewed transaction. Its worker guard/ACL must pass. No postgres/service-role worker substitute or privilege widening. The policy is immutable, and request reuse accepts only the same body. Retain returned policy_id, body/digest and request/file hash in the approval/release evidence.

Postconditions: exactly the approved policy inserted (or exact idempotent replay), stored body/digest equal approved input, no unrelated table mutation, owner/ACL/trigger boundaries unchanged. Newest policy is selected by the existing overview's ordering; there is no invented active-policy toggle or retirement RPC. All installed policies remain operational approval commitments. Stop on conflicts; no delete/update repair.

**Still missing:** approved complete policy values/file/hash/request ID and authorized use of the graph-worker credential for this exact write. No runnable installation SQL with invented values is supplied.

## 2. Operational graph freeze approval

Before the write, perform focused read-only checks on the intended actual source: coverage approval/active status, nodes/edges provenance and completeness, positive finite paired costs, directed reachability for intended depot/task nodes, serialization/path precision, existing freeze triggers, current graph inventory and downstream graph-export compatibility. Reuse prior verified evidence where current; do not run an unnecessary full experiment suite or label historical edge-count evidence as a fresh measurement.

Exact inputs to review:

* Stable request UUID and intended **real** `network_snapshot_id` (current candidate is OSM-OPS-20261018, to be rechecked).
* A justified, explicit speed-profile description corresponding to actual stored paired distance/time costs; do not invent a nominal speed or silently recompute times.
* Required precision contract **`EXACT_MAX_6_DECIMALS`**, output profile PG_REAL_OUTPUT_0 and the actual float/provenance limitations.
* Operator-approved full-graph hashing/lock/runtime limits and maintenance scope. Prior DEV-scale memory/time results are not available. The freeze hashes full node/edge relations under SHARE locks, not a hand-cropped substitute.

Actual write operation after exact approval: **`public.freeze_routing_graph(p_request uuid,p_snapshot text,p_speed_profile text,p_precision_policy text)`** under the graph-worker identity. Preserve all guards and stable replay payload. Record returned graph_id, database-derived digest/counts, approved snapshot/speed/precision/output metadata and the exact request.

**Critical approval consequence:** existing 001 network triggers reject nodes/edges/coverage writes and TRUNCATE once any graph manifest exists (`GRAPH_REVISION_FROZEN`). A successful freeze locks out future network maintenance under this contract. Do not delete manifests, disable triggers or introduce graph refresh/versioning as part of initialization. Concurrent graph versions/maintenance require separate design and approval.

Postconditions: one exact manifest or exact replay, actual source digest/counts, unchanged road data, intended freeze triggers/ACLs intact and no policy/task/custody modifications. The SQL guard does not independently prove every path or total meets precision/performance constraints. A dummy manifest or manual INSERT is prohibited.

**Still missing:** approved final freeze arguments and speed provenance, current source validation, execution limits/window and explicit acceptance of the global maintenance freeze. Existing coverage approval is not approval to execute this RPC.

## 3. Worker activation dependencies — separate approval

Prepare/review before activation:

* Existing dedicated `geolock_graph_login`, `geolock_planner_login`, `geolock_validator_login` credentials, intended memberships/SET ROLE behavior and no unintended elevated membership. Keep graph/planner secrets in the planner process and validator secret/DB credential only in the independent validator. No secrets in Flutter/Git/URLs/logs.
* DEV project ref and graph_id from the actual freeze, certificate-verified database access, valid publishable client key and real NGO JWT validation. Do not use the postgres installer/export login or service-role API key as worker credentials.
* Independent private validator endpoint/token, protected durable exact-payload journal/cache, approved planner HTTPS endpoint (only existing debug loopback/emulator exceptions where applicable), exact web CORS origins, and complete graph download/cache warm-up capacity.
* Reviewed `GEOLOCK_ROUTING_ALLOW_DEV_WRITES=APPROVED` and an actual activation approval reference. Do not set activation flags simply to bypass a disabled-state response. Worker health is not end-to-end acceptance.
* Approved business/test users and real valid current source claims, verified NGO depot and owned active/available/unheld vehicle(s). The two expired leases cannot be renewed or used implicitly. Any exact-pair recovery or fixture/provisioning operation is a separate explicit write approval; leave scheduler disabled.

Actual existing process commands, **only after activation approval**, from the repository root:

```powershell
.venv-stage8/Scripts/python.exe -m backend.routing.worker_service --mode validator
.venv-stage8/Scripts/python.exe -m backend.routing.worker_service --mode planner --warm-graph
.venv-stage8/Scripts/python.exe -m backend.routing.worker_service --mode planner
```

Run independent validator/planner with the appropriate separate environments. Warm-graph is a preparation invocation, not permission to invent/freeze a missing manifest. Installation, credential provisioning, externally exposed networking and activation are not performed by this document. See the actual `backend/routing/worker_service/README.md` for the precise configuration contract; do not rerun its historical 001→002→003 setup instruction now that 003 is deployed.

## 4. Real protected planning → pickup sequence

After the prerequisites and the separately approved DEV pilot scope:

1. Legitimate NGO `claim_listing(p_listing,p_request)` creates a live claim/lease/CONFIRMED task atomically; use existing approved lifecycle, no table seeds.
2. NGO overview/vehicle reads confirm policy, active verified depot, owned eligible vehicles and current admissible tasks.
3. NGO `begin_my_routing_snapshot(p_request,p_policy,p_vehicle_ids)` captures real source facts. Capturing observations is not admission/authorization; stale/expired tasks must be excluded by the contract.
4. Real planner `/v1/plan` with `{request_id,snapshot_id}` and NGO JWT retrieves the trusted complete graph, produces bounded directed matrices through `store_routing_matrix`, seals through `seal_routing_snapshot`, runs actual engines and submits through `submit_routing_candidate`. Respect the 1–100 unique matrix-node bound and required directed-pair FAIL_SCENARIO behavior.
5. Independent validator rebuilds the work item and invokes `attest_routing_candidate` with matching actual digests/valid-feasible report/build. Do not manufacture a PASS or treat planner local validation as independent attestation.
6. NGO calls `authorize_my_routing_candidate(p_request,p_candidate,p_depart_at)`. PostgreSQL rechecks current sources/vehicle/lease/windows/capacity and creates bindings/items/requests plus public routes/stops/assignments, task PLANNED and committed route AUTHORISED. The old `assign_task_to_route` stays fail-closed.
7. NGO uses `get_my_authorized_route(p_route)` and fresh per-stop authority to start (`start_pickup`), complete after physical handover (`complete_pickup`), then explicitly confirm depot return and close (`close_my_collected_route`). Start creates DISPATCHED/IN_PROGRESS and completion collects custody; completion alone does not release reservations.
8. Execute the approved cancel/reconciliation/foreign-actor/stale-lease/replay/rollback and donation/claim regression pilot in `POST_DEPLOYMENT_TESTS.md`. Record real outcomes; existing 49 mocked Flutter tests do not satisfy live acceptance.

Cancellation/reconciliation/closure retain actual existing rules. No client table writes, fabricated route states or new RPC names are introduced. Do not re-execute 003 to test rollback or initialize anything.

## 5. Next approval packages and stop conditions

Shortest next step: supply the proposed **policy JSON/business decisions** and the **graph freeze input/provenance decisions**. Codex can validate/freeze those files and prepare exact request IDs, transaction SQL/commands, expected deltas and failure handling for your review. Policy and graph freeze may be reviewed together, but their effects must be separately explicit; neither is authorized by this postflight PASS.

Then approve worker activation/configuration and a narrowly scoped valid-claim Flutter pilot. Any recovery of the existing expired pair remains distinct from initialization and must be freshly source-pinned/bounded, not an old queue call or stale exact-two wrapper.

Stop without automatic repair on source/hash/ACL drift, policy/request conflict, precision/provenance failure, graph timeout, unreachable pair, stale claim/vehicle/departure, missing independent attestation, ambiguous outcome or unexpected data/audit delta. Pre-commit failures should roll back their own reviewed transaction; after a confirmed policy/freeze commit there is no approved inverse deletion or trigger bypass. Preserve current source state and request a separate forward-repair decision. No DEV restore or destructive cleanup is implied.

**Current stop:** procedure prepared, policy/freeze inputs not chosen, no initialization/recovery/activation performed. Stage A 003 is installed; routing remains uninitialized and awaits your separate exact-operation approval.
