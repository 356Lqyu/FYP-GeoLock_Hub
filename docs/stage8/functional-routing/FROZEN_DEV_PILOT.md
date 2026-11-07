# Frozen DEV graph → first Flutter pilot

**Current checkpoint: full-size read-only probe PASS.** Actual evidence:
`results/worker-readiness/20261027T083653Z-5f56bb/result.json`.
926414nodes/2145828edges; warm-up294.485s; matrices61.672s/58.437s;
total414.657s. Correct interpreter monitoring and clean connection closure PASS.
No database writes or activation. Graph-loading investigation is closed; do not
repeat the probe or the earlier query-plan investigation. Follow
[FIRST_REAL_FLUTTER_DEMO.md](FIRST_REAL_FLUTTER_DEMO.md) for remaining gates.
Do not repeat password comparisons or use older DSN authentication instructions
below as the current next action. No automatic full probe or worker activation.

Older DSN-based connection instructions below are historical. Current native-service
commands and unchanged600s/4096MiB safeguards are documented in
[NATIVE_FULL_GRAPH_PROBE.md](NATIVE_FULL_GRAPH_PROBE.md).

Graph freeze committed; independently confirmed via approved READ ONLY DEV MCP
on27 October2026 at04:02:44 MYT. No worker activation/recovery/business write performed.

Immutable graph ID:eab1f7ee-a8e0-4bed-a0e1-2c4bff024936.
Content digest:5e06dab0fb4d2b97ac53fd9a1178dc46aa6b98811aefbaef96528c604a04012a.
Request:eb29d74d-d556-4135-b200-a691902cfbba; snapshotOSM-OPS-20261018;
926414nodes/2145828directed edges; created2026-10-26T19:58:54.947084Z.
Policy80db858b-93e8-4a0a-94e2-dbe14940f0a1, digest
b4f97b8c5ec2f41b986ea5a9bcd805cd16877d77c1d99c047c788ba4e81f734c unchanged.
Option A network-maintenance protection remains in force; future updates require
reviewed forward migration. No replay/reinstall/freeze command is needed.

## Verified identity/permission configuration

All three catalog logins exist/can login, have no superuser/BYPASSRLS/CREATEDB/
CREATEROLE, each member of ONLY its intended role among the three routing roles:

| Login | Role | Permitted runtime RPCs |
|---|---|---|
| geolock_graph_login | geolock_graph_worker | read_frozen_routing_graph, store_routing_matrix |
| geolock_planner_login | geolock_planner | read_pending_routing_snapshot, seal_routing_snapshot, read_routing_snapshot_bundle, submit_routing_candidate |
| geolock_validator_login | geolock_validator | read_routing_work_item, attest_routing_candidate |

The24 role×RPC checks match this matrix; forbidden direct table writes on public/
routing_private:0. Recovery cron inactive. Evidence:
results/routing-initialization-preparation/frozen-graph-worker-permissions.json.
These are effective catalog checks, NOT successful password/TLS connections as the
planner/validator logins. Do not use postgres/owner-export as a runtime substitute.

Optional operator native connection checks, from repo root, one hidden prompt each:

```powershell
$psql = 'C:\Program Files\PostgreSQL\17\bin\psql.exe'
$env:PGSSLMODE = 'verify-full'
$env:PGSSLROOTCERT = 'C:/Users/User/Downloads/prod-ca-2021.crt'
$env:PGOPTIONS = '-c default_transaction_read_only=on'
Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
& $psql -X -W --host aws-0-ap-northeast-2.pooler.supabase.com --port 5432 --dbname postgres --username geolock_planner_login.rcgyuwiidqvrgbxswhqj --set worker_role=geolock_planner --file '.\docs\stage8\functional-routing\worker-identities.readonly.sql'
if ($LASTEXITCODE -ne 0) { throw 'STOP; preserve outcome, no automatic retry/grants' }
& $psql -X -W --host aws-0-ap-northeast-2.pooler.supabase.com --port 5432 --dbname postgres --username geolock_validator_login.rcgyuwiidqvrgbxswhqj --set worker_role=geolock_validator --file '.\docs\stage8\functional-routing\worker-identities.readonly.sql'
if ($LASTEXITCODE -ne 0) { throw 'STOP; preserve outcome, no automatic retry/grants' }
```

Check identity, databasepostgres, ssl=true, read_only=on, one intended membership,
all elevated attributesfalse and exact RPC matrix. Use each account's OWN password,
never print or store it. Readiness sessions use read-only startup options; do not
reuse those options as runtime DSNs. Worker RoleRpc explicitly overrides ambient
PGOPTIONS/host fields. No Python owner-password investigation is resumed.

## Full-size read-only warm-up and matrix probe

New dedicated module uses the real GraphCache and C2 matrix implementation, with
transaction READ ONLY set before role/RPC work. It accepts ONLY read_frozen_routing_graph,
pins the frozen UUID/digest/counts, starts no server and cannot call store_routing_matrix,
submit/attest/authorize or any lifecycle RPC. Existing startup --warm-graph remains
unchanged and activation-gated; use this probe before activation instead.

Securely provision GEOLOCK_GRAPH_DSN in the local process via existing protected
secret management (no credential command arguments/Git/chat). It must explicitly
specify DEV host, port5432, postgres database, graph LOGIN (project suffix forpooler),
verify-full and CA; no service/options/passfile. Do not supply planner/validator
passwords to this probe. Keep GEOLOCK_ROUTING_ALLOW_DEV_WRITES unset; probe refuses
if setAPPROVED. Defaults perform local validation only, no connection:

```powershell
& '.\.venv-stage8\Scripts\python.exe' -B -m backend.routing.worker_service.readonly_pilot_probe
# Once the scoped graph credential is provisioned, bounded real read-only test:
& '.\.venv-stage8\Scripts\python.exe' -B -m backend.routing.worker_service.readonly_pilot_probe --run --matrix --timeout-seconds 300
```

New timestamped results/worker-readiness directory retains graph cache, progress,
matrix1/matrix2 and timing report. Timeout kills only the probe child; server read
transaction closes/rolls back. Partial cache never treated as complete. Per-RPC
statement120s/connection5s/lock5s limits remain. No automatic retries or timeout
increases. It loads all926414nodes/2145828edges, then generates two real directed
3×3 matrices for1755847853/2308277456/5735535080 using full-network paths and paired
times, not cropped graph or fabricated arcs. Report first/warm matrix cost, graph
download time and availability. New directory measures cold disk cache; second
matrix measures in-memory graph reuse but current C2 rebuilds/validates graph each
call. RAM capacity/peak are not enforced/measured by this probe; use host monitoring
and stop if resource pressure is unacceptable. The300s budget is an observation
limit, NOT a promised readiness target.

Actual DEV warm-up/matrix performance: NOT RUN / no scoped graph credential supplied
to Codex. No timings or PASS invented. Each matrix must fit within the150s Flutter
request budget with enough room for snapshot handling, all solver passes and independent
validation. A matrix-only PASS does not establish full HTTP/SQL acceptance; matrix
storage/candidate/attestation need separately approved controlled writes. Freshness
default300s must also be met. Cold warm-up belongs BEFORE live snapshot creation.

Executed local checks:38 worker tests PASS in27.211s (including3 new read-only
probe boundary tests);26 existing Flutter routing/transport tests PASS; Android
manifest/XML cleartext configuration PASS; local OR-Tools version9.15.6755.
These are unit/replay tests, not DEV performance or live-device results. Machine
readable summary: results/routing-initialization-preparation/pilot-preparation-tests.json.

## Separate validator and planner startup — prepare now, activate later

Use exact pinned OR-Tools9.15.6755 and existing requirements. No automatic install/
upgrade. In protected process configuration:

* Both: GEOLOCK_PROJECT_REF=rcgyuwiidqvrgbxswhqj, matching >=32-character
  GEOLOCK_VALIDATOR_TOKEN and snapshot freshness300 seconds.
* Validator ONLY: GEOLOCK_VALIDATOR_DSN for its dedicated login. Do not give this
  DSN to planner. Private127.0.0.1:8788 endpoint (private HTTPS if separate host).
* Planner ONLY: GEOLOCK_GRAPH_DSN, GEOLOCK_PLANNER_DSN, GEOLOCK_GRAPH_ID equal to
  frozen UUID above, DEV GEOLOCK_SUPABASE_PUBLISHABLE_KEY,
  GEOLOCK_VALIDATOR_URL=http://127.0.0.1:8788, protected persistent GEOLOCK_WORKER_STATE.
* Separate activation approval/receipt needed before setting
  GEOLOCK_ROUTING_ALLOW_DEV_WRITES=APPROVED and GEOLOCK_ROUTING_ACTIVATION_REF.
  Those allow request-driven matrix/seal/candidate/attestation writes; they are NOT
  set by this preparation. Do not start an ACTIVE server before approval.

After approved provisioning/activation, exact startup commands in separate terminals:

```powershell
# ONLY after explicit activation approval; never provision secrets in these commands.
& '.\.venv-stage8\Scripts\python.exe' -B -m backend.routing.worker_service --mode validator --host 127.0.0.1 --port 8788
& '.\.venv-stage8\Scripts\python.exe' -B -m backend.routing.worker_service --mode planner --host 127.0.0.1 --port 8787
```

No modifications to server activation guards. /health ACTIVE means service state,
not permission/graph/matrix/planning readiness. Keep validator private. Planner must
verify actual NGO JWT via DEV Auth and independently obtain validator attestation;
PostgreSQL remains the route-assignment authority.

## Flutter: existing transport ready for endpoint configuration

From frontend/geolock_hub_app, after approved service activation:

```powershell
# Android emulator debug; host is the Windows worker machine.
& 'C:\flutter\src\flutter\bin\flutter.bat' run --dart-define=GEOLOCK_SUPABASE_ENV=dev --dart-define=GEOLOCK_ROUTING_API_URL=http://10.0.2.2:8787
# Physical device/release: replace approved hostname; trusted TLS and reachability required.
& 'C:\flutter\src\flutter\bin\flutter.bat' run --dart-define=GEOLOCK_SUPABASE_ENV=dev --dart-define=GEOLOCK_ROUTING_API_URL=https://YOUR-APPROVED-WORKER-HOST
```

Existing transport accepts emulator HTTP only in debug; LAN-IP HTTP is rejected.
Main Android manifest now declares INTERNET (previously debug/profile only), so
release builds retain network access; debug cleartext exceptions remain restricted
to localhost/127.0.0.1/10.0.2.2. This does not activate an API or change DEV data.
Physical device cannot use127.0.0.1 to reach Windows. Keep services loopback and
publish planner via trusted HTTPS reverse proxy, or use existing TLS cert/key options
for external bind. Do not open validator publicly. Flutter receives no worker secrets;
existing NGO JWT is used. No UI/repository rewrite required. Real-device run not done.

## Remaining gates for a controlled NGO pilot

1. Successful native planner/validator identity checks and actual runtime scoped
   credentials; read-only full-size warm-up/matrix timing/resource acceptance.
2. Choose emulator or physical HTTPS endpoint; provision isolated validator/planner
   processes, protected token/state, pinned versions and scoped DSNs.
3. Explicit approval for worker request-driven writes and narrow real NGO pilot.
4. Real authorized NGO account/JWT, verified active depot, available owned vehicle
   and sufficient capacity/availability. Confirm actual pilot coordinates/nodes.
5. Fresh real donation/listing and claim through authorized app operations. For240+15
   policy, remaining lease AND applicable listing validity >255minutes;360-minute
   lease age <105minutes. Existing expired ACTIVE leases are not eligible; no repair
   or fixture creation in this phase.
6. Observe app claim→snapshot→matrix→plan→independent validation→NGO authorization→
   assigned route→start/complete pickup→depot return. Verify states/audits and
   unauthorized-operation rejection. Stop on stale/unknown results; preserve request
   IDs. Full earlier local lifecycle PASS is not a live DEV/Flutter-device PASS.

Current next action: dedicated planner/validator identity checks and scoped runtime
connection configuration, as described in FIRST_REAL_FLUTTER_DEMO.md. The probe
instructions and NOT RUN statements above are historical. No more migrations,
policy installation, graph export-equivalence replay, freeze or recovery activation.
