# DEV routing worker

**Selected workflow: local Windows laptop (7 November 2026).** Use [the current beginner setup/start/stop guide](../../../docs/LOCAL_ROUTING_WINDOWS.md) and the existing `windows/Start-Worker.ps1` launcher. Render/Docker/Linux and PostgreSQL journal redesign are not required. Existing activation remains opt-in; this documentation does not authorize DEV writes. Earlier stage notes below are historical; the guide records native client/CA portability prerequisites and current offline verification.

Current DEV: policy installed and graph `eab1f7ee-a8e0-4bed-a0e1-2c4bff024936`
frozen (digest `5e06dab0fb4d2b97ac53fd9a1178dc46aa6b98811aefbaef96528c604a04012a`).
See `docs/stage8/functional-routing/FROZEN_DEV_PILOT.md` for the separate read-only
warm-up/matrix probe, actual scoped-permission evidence and activation/pilot gates.
Historical policy/graph initialization prerequisites below are now satisfied;
do not reinstall/refreeze. Workers/recovery remain unactivated by this preparation.

Current checkpoint: StageA003 is already DEPLOYED / POSTFLIGHT PASS; do not replay001/002/003 against DEV. The complete local claim→HTTP planning→independent validation→authorization→pickup→depot-close test and minimum DEV activation path are in `docs/stage8/functional-routing/IMPLEMENTATION_RESULT.md`. That local result uses explicit Auth/Storage/cron adapters and is not live Supabase acceptance. DEV policy/graph/worker activation still require separate approvals.

Stage B local update: the primary proposed algorithm calls actual RoutingModel;
distance-only retains CP-SAT. No live service was started. See
`docs/stage8/stage-b/REPORT.md` for the native invocation test, local PostgreSQL
coverage and unverified real Auth/HTTP/Flutter integration.

No migrations, DEV requests or records were executed while implementing this service. Startup is **disabled by default**. Existing migrations 001–003 are unchanged.

The planner verifies the NGO token through **DEV Supabase Auth**, checks the NGO-only fleet RPC and snapshot ownership, downloads a complete frozen graph through the graph role, builds C2 directed matrices, evaluates the existing four algorithms and submits the proposed candidate. A **separate validator process/login** rereads the database work item, rebuilds inputs, independently validates and attests exact digests. Only then is an advisory candidate returned.

Flutter still calls `authorize_my_routing_candidate` under the NGO JWT. `/v1/authorize` also forwards that same protected RPC under the caller JWT, never a worker credential. PostgreSQL alone validates current sources, reserves tasks/vehicles and grants route authority. The worker has no dispatch, claim, pickup or direct-table-write endpoint.

## Setup

From the repository root, using Python 3.12 and the existing Stage 8 environment:

```powershell
.venv-stage8/Scripts/python.exe -m pip install -r backend/routing/worker_service/requirements.txt
.venv-stage8/Scripts/python.exe -m backend.routing.worker_service --check-config
```

Without activation variables the last command prints `DISABLED` and makes no database/network calls.

Provision these values using protected **process environments/secret management**, not Git, Flutter, command-line DSNs or chat:

| Configuration | Value |
|---|---|
| `GEOLOCK_PROJECT_REF` | `rcgyuwiidqvrgbxswhqj` |
| `GEOLOCK_GRAPH_DSN` / `GEOLOCK_PLANNER_DSN` | Separate dedicated database LOGINs, each a member of **only** `geolock_graph_worker` / `geolock_planner`. Planner process only. |
| `GEOLOCK_VALIDATOR_DSN` | Dedicated LOGIN member of **only** `geolock_validator`. Validator process only; do not supply this secret to the planner. |
| Database connection settings | DEV direct host `db.rcgyuwiidqvrgbxswhqj.supabase.co`, or Supabase pooler with username suffix `.rcgyuwiidqvrgbxswhqj`; database `postgres`; `sslmode=verify-full`; `sslrootcert=system` or a trusted CA file. LOGIN names must start `geolock_` and end `_login`. No postgres/service-role/superuser credentials. |
| `GEOLOCK_GRAPH_ID` | UUID of an **already approved/frozen** graph manifest. No graph or policy is auto-created. |
| `GEOLOCK_SUPABASE_PUBLISHABLE_KEY` | The existing DEV publishable key; planner process only. |
| `GEOLOCK_VALIDATOR_URL` | `http://127.0.0.1:8788`, or a private HTTPS validator endpoint. |
| `GEOLOCK_VALIDATOR_TOKEN` | Same random ≥32-character service secret in both processes; not an NGO JWT. |
| `GEOLOCK_WORKER_STATE` | Protected persistent directory for the exact-payload journal and graph cache. Default: module `.state/`, ignored by Git. Back up the journal; losing it can require a new snapshot. |
| `GEOLOCK_MAX_SNAPSHOT_AGE_SECONDS` | Default `300`, allowed range 1–1800; current DB time is used. |
| **Activation, only after approval** | `GEOLOCK_ROUTING_ALLOW_DEV_WRITES=APPROVED` and `GEOLOCK_ROUTING_ACTIVATION_REF` identifying the operator's approval record. These enable future request-driven writes; do not set them before DEV write authorization. |

After approved deployment/configuration, run separate processes:

```powershell
.venv-stage8/Scripts/python.exe -m backend.routing.worker_service --mode validator
.venv-stage8/Scripts/python.exe -m backend.routing.worker_service --mode planner --warm-graph
.venv-stage8/Scripts/python.exe -m backend.routing.worker_service --mode planner
```

Defaults are loopback ports 8788 / 8787. Expose the planner through a trusted HTTPS reverse proxy, or supply `GEOLOCK_TLS_CERT`/`GEOLOCK_TLS_KEY` when binding beyond loopback. Keep the validator private. For Flutter web, set exact comma-separated `GEOLOCK_CORS_ORIGINS`; wildcards are rejected. `/health` reports activation state, **not** proof of database readiness or route validity.

Flutter Android emulator debug:

```powershell
flutter run --dart-define=GEOLOCK_ROUTING_API_URL=http://10.0.2.2:8787
```

Use `https://your-worker-host` for physical devices/release. Debug HTTP is restricted to loopback/emulator domains. The existing `GEOLOCK_ROUTING_FUNCTION` transport remains an optional alternative. No worker credential is ever embedded in Flutter.

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
