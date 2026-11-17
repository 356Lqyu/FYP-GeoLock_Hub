# DEV routing worker

**Selected workflow: local Windows laptop (7 November 2026).** Use [the Windows Routing + Android Flutter Quick Start](../../../docs/LOCAL_ROUTING_WINDOWS.md#quick-start-windows-routing-android-flutter-app) and the existing `windows/Start-Worker.ps1` launcher. Render/Docker/Linux and PostgreSQL journal redesign are not required. Existing activation remains opt-in; this documentation does not authorize DEV writes. The seven-folder release remains undeployed pending DEV validator compatibility and cutover approval. Earlier stage notes below are historical; the guide records native client/CA portability prerequisites and current offline verification.

Current DEV: policy installed and graph `eab1f7ee-a8e0-4bed-a0e1-2c4bff024936`
frozen (digest `5e06dab0fb4d2b97ac53fd9a1178dc46aa6b98811aefbaef96528c604a04012a`).
See `docs/stage8/functional-routing/FROZEN_DEV_PILOT.md` for the separate read-only
warm-up/matrix probe, actual scoped-permission evidence and activation/pilot gates.
Historical policy/graph initialization prerequisites below are now satisfied;
do not reinstall/refreeze. Workers/recovery remain unactivated by this preparation.

Current checkpoint: StageA003 is already DEPLOYED / POSTFLIGHT PASS; do not replay001/002/003 against DEV. The complete local claim→HTTP planning→independent validation→authorization→pickup→depot-close test and minimum DEV activation path are in `docs/stage8/functional-routing/IMPLEMENTATION_RESULT.md`. That local result uses explicit Auth/Storage/cron adapters and is not live Supabase acceptance. DEV policy/graph/worker activation still require separate approvals.

No migrations, DEV requests or records were executed while implementing this service. Startup is **disabled by default**. Existing migrations 001–003 are unchanged.

The planner verifies the NGO token through **DEV Supabase Auth**, checks the NGO-only fleet RPC and snapshot ownership, downloads a complete frozen graph through the graph role, builds directed matrices, evaluates FCFS, nearest neighbour and the proposed CP-SAT optimiser and submits the proposed candidate. A **separate validator process/login** rereads the database work item, rebuilds inputs, independently validates and attests exact digests. Only then is an advisory candidate returned.

Flutter still calls `authorize_my_routing_candidate` under the NGO JWT. `/v1/authorize` also forwards that same protected RPC under the caller JWT, never a worker credential. PostgreSQL alone validates current sources, reserves tasks/vehicles and grants route authority. The worker has no dispatch, claim, pickup or direct-table-write endpoint.

## Setup and startup

Use the [Windows Quick Start](../../../docs/LOCAL_ROUTING_WINDOWS.md#quick-start-windows-routing-android-flutter-app) for the pinned native client, encrypted profiles, offline configuration checks, and approved Validator, Planner and Flutter startup. Use the same guide for USB troubleshooting and shutdown. The planner and validator listen on loopback ports 8787 and 8788 respectively. The Flutter app reaches the planner. PostgreSQL retains route authorisation.

## Retry/failure behavior

`POST /v1/plan` accepts **only** `{request_id,snapshot_id}` with the NGO bearer token. Flutter creates the selected-vehicle snapshot through its protected RPC first. Client-supplied plans, NGO IDs and success flags are rejected. The durable journal saves exact matrix/plan payloads **before** mutating RPCs; deterministic request IDs and OS locks handle duplicates, crashes and lost acknowledgements. Repeat the same request after retryable errors. Refresh/create a new snapshot after a stale/conflict error; no automatic reservation cleanup or claim release occurs.

Infeasible results contain actual engine comparisons, no candidate ID and no authority. Missing/unreachable arcs fail closed before matrix storage. Only a successful independent attestation produces `ATTESTED`, which remains advisory. PostgreSQL authorization failures are returned as failures/unknown outcomes; never converted into success. Preserve the original authorization request ID after timeouts.

## Focused checks / remaining activation prerequisites

```powershell
.venv-stage8/Scripts/python.exe -m unittest discover -s backend/routing/worker_service/tests -t . -q
.venv-stage8/Scripts/python.exe supabase/tests/stage8_worker_rpc_isolated_test.py --run-isolated
```

The second command creates a **new disposable local PostgreSQL cluster**, uses synthetic NGO auth and real separate database-role logins, and executes only four worker/RPC tests. It accepts no external DSN. Neither command proves live authenticated Supabase behavior.

Still required: approved worker LOGIN memberships and secrets; explicit routing policy and frozen graph initialization; trusted network/TLS access; eligible real pilot sources/depot/vehicles and authenticated checks. No migration replay or further password investigation is required by the current local test. Warm the 2.1-million-edge DEV graph before demo snapshots. DEV-scale memory/runtime remains unmeasured: C2 retains the complete graph in memory, and the API intentionally serializes planning jobs. Multiple replicas need the same protected persistent journal or must fail closed on idempotency conflicts. No live dispatch or end-to-end DEV success is claimed.
