# First controlled DEV Flutter routing demonstration

**Connection gate update:** the minimal native runtime adapter is implemented and
locally tested. Run the two read-only Windows `-CheckConnection` commands from
[NATIVE_RUNTIME_ADAPTER.md](NATIVE_RUNTIME_ADAPTER.md) using local hidden prompts.
No additional graph/performance investigation is needed; services remain unactivated.

**Local preparation update:** user reports both dedicated native planner/validator
identity checks PASS. Encrypted credential fields are present; successful sealed
cache copied/verified in protected runtime state. Activation is still HOLD pending
the actual runtime connection gate and explicit approval. See
[LOCAL_SERVICE_PREPARATION.md](LOCAL_SERVICE_PREPARATION.md) for exact startup and
health commands. Do not repeat identity checks or the full-size graph probe.

Prepared27 October2026. Full-size read-only graph/matrix gate PASS, reused without
rerunning: `results/worker-readiness/20261027T083653Z-5f56bb/result.json`.
Actual graph/digest match the frozen approved manifest.215page rollbacks, one closed
native connection, no cleanup failure, returncode0, no resource stop; sampled
interpreter peak3764772864bytes <4096MiB. Both matrices have all arcs AVAILABLE.
This proves the diagnostic workload, not the complete live HTTP/SQL workflow.

## Existing path — reuse

Flutter `NgoRoutingRepository.plan` creates a protected NGO snapshot through
`begin_my_routing_snapshot`, then sends snapshot/request IDs and real NGO JWT to
`POST /v1/plan`. Existing planner obtains the trusted snapshot, builds/stores its
matrix, seals snapshot, runs four methods, submits candidate and requests a separate
validator's attestation. Flutter authorizes directly through
`authorize_my_routing_candidate`; PostgreSQL reserves tasks/vehicle and issues route
IDs. Existing route screens use `get_my_authorized_route`, `start_pickup`,
`complete_pickup` with handover confirmation, and `close_my_collected_route` with
depot-return confirmation. No UI rewrite or new lifecycle RPC is required.

## Minimum remaining gates

1. **READ ONLY / configuration:** confirm dedicated planner and validator login/TLS
   and effective scoped RPC privileges using the existing identity SQL. Existing
   catalog evidence already supports intended grants; do not grant anything anew.
   Native-service success currently applies to the probe only. Live `server.py`
   constructs ordinary `RoleRpc` DSN connections; `Start-Worker.ps1` still reveals
   SecureString to Unicode DSNs. Do not assume the native probe proved that path.
   Verify the actual runtime connection path for all three identities, or prepare
   only the narrow connection-factory adaptation to the proven native method. The
   probe's READ ONLY wrapper cannot be reused for mutating runtime RPCs. No further
   password comparisons or general authentication investigation is required.
2. **Local preparation:** separate private validator127.0.0.1:8788 and planner
   127.0.0.1:8787, shared secret>=32chars, distinct scoped credentials, DEV publishable
   key, approved graph ID, persistent protected journal/cache, freshness300s and
   OR-Tools9.15.6755. Keep all activation variables unset during preparation.
   Reuse/copy the successful probe's SEALED `.jsonl` and `.sha256` pair into the
   chosen runtime `GEOLOCK_WORKER_STATE/graphs` directory; preserve original evidence
   and validate its seal and live manifest using existing GraphCache checks.
   Never use the failed partial. No fresh full export is needed. Graph cache is
   process-local; the probe did not warm a separate planner process. Avoid cold
   download after snapshot creation:294s download plus~60s matrix exceeds300s
   snapshot freshness. A graph warm-up alone is read-only, even if the existing
   CLI guard requires an activation receipt; do not bypass that guard.
3. **READ ONLY / pilot selection:** one real NGO with verified active depot and
   an owned available eligible vehicle (capacity fits), plus one eligible nearby
   donation/listing whose road node belongs to the frozen snapshot and has a usable
   directed depot round trip. Diagnostic pairs do not prove arbitrary pilot nodes.
   Exact NGO/vehicle/donation IDs and current eligibility remain to be selected.
   Fresh claim lease and applicable listing validity must exceed255min at snapshot
   cutoff. Do not use or recover the two expired ACTIVE leases.
4. **Separate approval required:** authorize only the two service processes and
   one selected NGO pilot. This includes snapshot/matrix/seal/candidate/attestation,
   route authorization/reservations, fresh claim if needed, pickup start/completion
   and depot-return writes through existing protected APIs. No permission changes,
   manual fixtures, graph modifications or recovery activation.
5. **After approval:** validator first, planner second; reuse sealed cache before
   claim/planning. Android emulator is the shortest endpoint path:
   `GEOLOCK_ROUTING_API_URL=http://10.0.2.2:8787`, `GEOLOCK_SUPABASE_ENV=dev`.
   Physical devices require a reachable trusted HTTPS planner endpoint. Validator
   stays private; no worker secret goes into Flutter. Observe one claim → Generate
   route → independently ATTESTED candidate → authorize → assigned route → ordered
   start/complete pickup with actual handover → confirmed depot return. Record
   snapshot/candidate/route/task IDs, receipts, state transitions and audit events.
   Matrix~60s is below Flutter150s, but solver/SQL/Auth/validator latency must also
   fit; the first authorized pilot measures this. No timeout increase is proposed.

Stop on authentication/authorization/stale/unknown-outcome failure. Preserve request
IDs and journal; refresh protected reads before deciding a retry. Stop service
processes to disable worker intake. Stopping workers does not undo committed routes
or pickups; existing cancellation/reconciliation rules still apply, and started
work must not be manually deleted/reset. Recovery scheduler remains disabled.

## Exact first command — read only

From repository root, run the planner identity check (hidden prompt for that
account's password, no credentials in this command):

```powershell
& 'C:\Program Files\PostgreSQL\17\bin\psql.exe' -X -W --dbname "host=aws-0-ap-northeast-2.pooler.supabase.com hostaddr='' port=5432 dbname=postgres user=geolock_planner_login.rcgyuwiidqvrgbxswhqj sslmode=verify-full sslrootcert='C:/Users/User/Downloads/prod-ca-2021.crt' connect_timeout=5 options='-c default_transaction_read_only=on'" --set worker_role=geolock_planner --file '.\docs\stage8\functional-routing\worker-identities.readonly.sql'
if ($LASTEXITCODE -ne 0) { throw 'STOP; no automatic retry or grants.' }
```

Expect session_user=geolock_planner_login, current_user=geolock_planner,
databasepostgres, read_onlyon, ssltrue, only intended membership, elevated attributes
false and only planner RPCs permitted. Then repeat with username
`geolock_validator_login.rcgyuwiidqvrgbxswhqj` and worker_role`geolock_validator`,
using that account's own password. This command proves native identity/permissions,
not Python runtime authentication. No worker is activated by either check.
