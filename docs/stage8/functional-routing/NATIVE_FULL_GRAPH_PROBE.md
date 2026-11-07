# Controlled full-size read-only graph/matrix probe

**Current checkpoint: PASS; no further probe or performance investigation requested.**
Actual evidence `results/worker-readiness/20261027T083653Z-5f56bb/result.json`:
926414nodes/2145828edges, warm-up294.485s, matrices61.672s/58.437s,
total414.657s, writesfalse/activationfalse. The report confirms verified interpreter
monitoring within600s/4096MiB and clean closure. Earlier preparation/timeout text
below is historical. Continue with [FIRST_REAL_FLUTTER_DEMO.md](FIRST_REAL_FLUTTER_DEMO.md).

**Transaction startup corrected:** see [READONLY_STARTUP_CORRECTION.md](READONLY_STARTUP_CORRECTION.md).
The first full run stopped before graph loading because its initial implicit
transaction was read-write. Explicit psycopg READ ONLY startup and actual per-page
verification now replace reliance on service startup defaults. No DEV retry executed.

Prepared27 October2026. NativeServiceDiagnostic actual evidence reviewed:
results/worker-connection-diagnostics/20261027T063046Z-1184bf/result.json,
SHA25634da56475abd3150deb6b8c720277a70d9e947f9c0a287f00220a9679b382573.
Authentication, actual login/TLS1.3/READ ONLY/rollback and exact observed manifest
PASS. Full-size warm-up and matrix performance remain NOT MEASURED. No DEV full
probe, worker activation or write performed by Codex.

## One separate operator command

From repository root in interactive PowerShell:

```powershell
& '.\docs\stage8\functional-routing\run_readonly_graph_probe.ps1' -NativeServiceProbe
```

Enter the graph-login password ONCE at the proven native-style hidden prompt.
No other switch: full probe is mutually exclusive with diagnostics/comparisons and
never automatically chained. The command selects explicit600s/4096MiB limits;
neither will be automatically increased or retried. A local setup-only check is:

```powershell
& '.\.venv-stage8\Scripts\python.exe' -B -m backend.routing.worker_service.native_service_probe --check-local
```

## Connection and SQL safety

Same pinned native libpq17.11, approved service profile/verify-full CA and original
password-byte adapter as the PASS diagnostic. No Unicode re-encoding, password file,
password environment variable, fingerprint or secret-bearing argv/log. The prompt
runs before the benchmark deadline, then an anonymous stdin pipe transfers bytes
to the child. Mutable copies are cleared; transient libpq/Python/OS memory remains
a security limitation. No claim of erasing every immutable copy. Avoid process dumps.

One authenticated physical connection is reused by this probe only; no reconnect
or authentication retry after failure. Startup default_transaction_read_onlyon is
requested but not trusted; explicit psycopg BEGIN READ ONLY and actual SQL checks
are mandatory before initial identity and each graph page.
first connection verifies actual graph-login identity/TLS/read-only state. Every
RPC independently sets READ ONLY, graph role, timeouts and existing login/role checks.
Borrowed page contexts ALWAYS roll back and never commit; connection is closed on
completion/failure. On forced process termination the socket closes; server read
cleanup may persist until disconnect/statement timeout, but no writes are allowed.

Only read_frozen_routing_graph for UUID eab1f7ee-a8e0-4bed-a0e1-2c4bff024936 is
permitted. Every page must match digest
5e06dab0fb4d2b97ac53fd9a1178dc46aa6b98811aefbaef96528c604a04012a,
snapshotOSM-OPS-20261018 and counts926414nodes/2145828edges. Actual GraphCache/C2
code is reused. No store matrix, snapshot, candidate, attestation, route, policy,
freeze, planner/validator API or recovery activation. Catalog graph role has broader
write-RPC grants, but probe whitelist and database READ ONLY remain independent
boundaries. Frozen road tables/permissions are not changed.

## Resources and workload

* Minimum local available physical RAM6144MiB and free workspace disk2048MiB checked
  before prompting/connecting. Local setup observed about9.7GiB available at review;
  this is not a reservation or future guarantee. Close heavy applications first.
*600s wall budget after password entry. Child is terminated on timeout, no retry.
*4096MiB per-child process commit stop, sampled about every200ms using only the owned
  child's Windows process counters. This is NOT a hard OS allocation cap: a transient
  overshoot/system pressure is possible. Peak sampled commit and working-set counters
  are reported. Other applications are not monitored/terminated.
* Native connect5s; existing per-RPC statement120s/lock5s limits preserved.
* Fresh timestamped cache: all926414nodes and2145828edges,10000-row keyset pages,
  then two real full-network C2 3×3 matrices for1755847853/2308277456/5735535080.
  No graph crop or fabricated arcs. Matrix bodies remain LOCAL; no storage RPC.
* Node/edge dictionaries, multiple canonical JSON copies/revalidation and complete
  per-node path tuples in current Dijkstra can require multiple GiB and substantial
  CPU. Three selected nodes do not make the full-graph algorithm small. It may hit
  the memory/time stop before finishing the first matrix; that is a non-PASS result
  requiring analysis, not permission to increase limits silently.
* Persistent connection avoids authenticating for every page. It is probe-only;
  production worker authentication/pooling has NOT been changed. Recorded numbers
  do not benchmark the old per-page connection setup or complete Flutter HTTP work.

## Evidence and result review

New results/worker-readiness/<UTC>-<suffix> directory only; previous failures and
diagnostic evidence untouched. Local graph cache/partial files excluded from Git.
Atomic result.json replacement retains the last valid phase/progress if killed.

Report includes pinned UUID/digest, actual client, nodes/edges loaded, graph warm-up
seconds, matrix1/matrix2 seconds, arc availability, sanitized failure phase/SQLSTATE/
marker, connection/rollback/cleanup metrics and resource limits/peaks. Cache includes
manifest actually returned by DEV. GraphCache manifest/count checks are NOT an
independent whole-graph database hash-chain recomputation.

PASS requires full graph load, both matrices, expected identity/manifest/availability
and successful cleanup. Resource-limit exit is MEMORY LIMIT or TIMEOUT / NO READINESS
PASS, not proof of a graph defect. Partial progress may show successful graph load
even when matrix performance fails. Preserve reports/cache seals; do not edit them.

Review matrix times against Flutter's150s request limit with room for snapshot,
solver passes and independent validator. Matrix-only under150s is not sufficient
end-to-end latency proof; cold graph warm-up belongs before snapshot creation.
Success does not warm a separate planner process automatically or authorize writes.

## Tests and remaining gates

81 local worker tests PASS in34.220s, including new native-session reuse, READ ONLY
page rollback/no commit, auth failure/no reconnect, identity checks, secret redaction,
graph-load failure, cleanup failure, wall/memory stops and offline native setup.
The real bounded diagnostic PASS is reused; no live full-size performance PASS is
claimed. Resource monitor was checked against the test process and an actual owned
local no-network child. No DEV connection/full load was executed by these tests.

Files changed: new native_service_probe.py, native_readonly_session.py and
probe_resources.py; existing readonly_pilot_probe.py (factory/cleanup/resources),
graph_cache.py (optional page-progress callback), secure PowerShell launcher
(exclusive -NativeServiceProbe mode), test_native_full_probe.py and this/current
pilot documentation. No approved migration, service profile, policy or server
activation guard was modified.

No new migration/policy/freeze/role change is needed for this read-only probe.
Remaining: operator executes one controlled command with scoped credential and
adequate host resources; inspect real timing/resource evidence. If acceptable,
separately review runtime planner/validator auth integration, hosting/state/tokens,
activation and fresh NGO/vehicle/claim pilot approvals. Those do not follow
automatically from this command. Existing expired claims remain untouched.
