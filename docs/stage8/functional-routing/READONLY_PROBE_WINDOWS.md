# Windows read-only frozen-graph probe

**Native-service diagnostic now PASS:** current full-size command is the separate
`run_readonly_graph_probe.ps1 -NativeServiceProbe`; see
[NATIVE_FULL_GRAPH_PROBE.md](NATIVE_FULL_GRAPH_PROBE.md). Historical -Run/DSN/comparison
actions below are superseded for this pilot; no automatic retry or activation.

**Current next step:** first use the separate bounded connection diagnostic:
`run_readonly_graph_probe.ps1 -ConnectionDiagnostic`. See
[CONNECTION_DIAGNOSTIC.md](CONNECTION_DIAGNOSTIC.md). It never chains to the full probe;
hold the full `-Run` operation until the diagnostic passes and its report is reviewed.

Prepared and offline-validated27 October2026. No live authentication, graph load,
matrix generation or worker activation performed in this preparation.

From repo root:

```powershell
# Offline: approved-profile/CA presence and libpq conninfo parsing; no password/network.
& '.\docs\stage8\functional-routing\run_readonly_graph_probe.ps1'
# Operator-run real read-only probe, one hidden graph-login password prompt:
& '.\docs\stage8\functional-routing\run_readonly_graph_probe.ps1' -Run
```

Use geolock_graph_login's database password. Never enter the owner/export password,
API key or validator secret. No password/DSN is placed in process command arguments,
repository files, shell history or evidence logs. The launcher holds it temporarily
in memory and passes GEOLOCK_GRAPH_DSN only in the child environment. It releases
launcher copies immediately after process start. Do not print process environments.

Exact connection identity (matching approved geolock_dev_graph_initializer profile):

* host aws-0-ap-northeast-2.pooler.supabase.com; port5432; databasepostgres.
* user geolock_graph_login.rcgyuwiidqvrgbxswhqj → role geolock_graph_worker.
* sslmodeverify-full; sslrootcert C:/Users/User/Downloads/prod-ca-2021.crt.
* DSN uses libpq keyword/value syntax; launcher escapes single quotes/backslashes
  correctly. No options/service/passfile/hostaddr field is copied into the DSN.
  The initializer's default_transaction_read_only=off is deliberately NOT copied.
* RoleRpc uses explicit target fields,5s connect timeout,120s statement timeout and
  5s lock timeout. Each probe connection executes SET TRANSACTION READ ONLY before
  role/RPC work. All inherited PG* and GEOLOCK_* variables are removed from the child;
  only the dedicated DSN is added. Parent environment is not modified.

The exact child command is:

```powershell
& '.\.venv-stage8\Scripts\python.exe' -B -m backend.routing.worker_service.readonly_pilot_probe --run --matrix --timeout-seconds 300
```

Use the launcher rather than manually typing a password-bearing DSN. It never sets
GEOLOCK_ROUTING_ALLOW_DEV_WRITES/ACTIVATION_REF, starts an HTTP server or initializes
an application worker. There is no automatic retry. On failure preserve evidence
and STOP; don't increase timeouts or change credentials/permissions automatically.

## Privilege boundary

Existing catalog evidence confirms graph login has ONLY graph membership among the
three routing worker roles, no superuser/BYPASSRLS/CREATEDB/CREATEROLE and no direct
public/routing table writes. It has EXECUTE on read_frozen_routing_graph.

It is NOT an intrinsically read-only database role: the installed contract also grants
graph-role write RPCs (install/freeze/store matrix). No grants were changed. For this
test ReadOnlyGraphRpc rejects every RPC except read_frozen_routing_graph for the exact
pinned UUID, with database READ ONLY enforcement as a second boundary. An independently
least-privilege read-only login would need separately approved provisioning; none is
invented or substituted. Runtime membership/safety checks still execute on every
connection, but successful password/TLS authentication awaits the operator run.

## Evidence and PASS conditions

Pinned graph eab1f7ee-a8e0-4bed-a0e1-2c4bff024936; content digest
5e06dab0fb4d2b97ac53fd9a1178dc46aa6b98811aefbaef96528c604a04012a;
snapshotOSM-OPS-20261018;926414nodes/2145828directed edges. Manifest mismatch fails
before accepting pages. No recomputation of the database hash chain is claimed.

The runner prints the new results/worker-readiness/<timestamp>-<suffix> directory.
result.json records UUID/digest, phase, graph_warmup_seconds, matrix_seconds,
arc availability, elapsed time and safe failure code. matrix-1/2.json store actual
in-memory3×3 diagnostic matrices, graph cache is local only. Timeout or unexpected
child exit records a non-PASS status with the pinned identity and partial progress.
Failed warm-up timing remains null rather than a fabricated measurement.

READ_ONLY PROBE PASS means graph loading and both matrix computations finished;
it does NOT mean a matrix was accepted/stored by SQL, a route was authorized or
Flutter end-to-end readiness proven. Assess timings against the150-second request
budget with room for solving and independent validation; graph cold warm-up occurs
before taking a live snapshot. The300-second overall limit is not an SLA. RAM/peak
usage are not bounded by this runner; monitor the Windows host and stop if needed.

Actual preparation validation: offline launcher returned
READ_ONLY_PROBE_CONFIGURED / NOT CONNECTED;5 targeted regression tests PASS.
Synthetic password roundtrips preserve spaces, quotes, backslashes, metacharacters
and Unicode via libpq parsing. No real password used. Graph/role evidence reused
from frozen-graph-worker-permissions.json; no live performance result claimed.
