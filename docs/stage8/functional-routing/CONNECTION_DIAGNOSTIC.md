# Bounded DEV graph connection diagnostic

**Next controlled path:** use [NATIVE_SERVICE_PYTHON_DIAGNOSTIC.md](NATIVE_SERVICE_PYTHON_DIAGNOSTIC.md)
and launcher `-NativeServiceDiagnostic` to reuse the approved service/native bytes
without PowerShell password conversion. No repeated comparison or automatic retry.
Prior DSN-based diagnostic instructions below remain historical alternatives.

**Client alignment update:** launcher now pins this bounded diagnostic to installed
libpq17.11, matching the owner's native psql PASS. See
[NATIVE_PSQL_PYTHON_CONNECTION_COMPARISON.md](NATIVE_PSQL_PYTHON_CONNECTION_COMPARISON.md).
This does not assert that the authentication discrepancy is resolved or change
the full-size probe/worker client.

Run from repository root in interactive PowerShell:

```powershell
& '.\docs\stage8\functional-routing\run_readonly_graph_probe.ps1' -ConnectionDiagnostic
```

Enter only geolock_graph_login's database password at the hidden prompt. Do NOT add
-Run: that selects the full-size probe and is mutually exclusive with this mode.
No authentication/retry/full probe has been executed by Codex in this preparation.

Reuses the existing approved graph initializer's host/port/database/user/verify-full
CA settings and secure launcher. Password only enters child-process environment;
no password, DSN or token appears in argv, repository files or reports. Ambient PG*
and GEOLOCK_* settings, including write activation, are removed in that child.
Writable installer options are not copied. No HTTP server is started.

One connection attempt through the SAME RoleRpc connection implementation as the
full probe. No retry loop. Explicit BEGIN READ ONLY; connection5s, statement10s,
lock2s and whole child45s bounds. Queries:

1. Observe session_user/current_user, database, transaction_read_only and own
   pg_stat_ssl TLS state/version. Require dedicated graph login, postgres database,
   read_only=on, ssl=true. Conninfo must request verify-full with the approved CA;
   successful TLS connection plus server observation establishes that configured path.
2. SET LOCAL ROLE geolock_graph_worker; inspect actual effective graph-read EXECUTE,
   safe login attributes and exclusive routing-role membership. Report broader
   store-matrix grant honestly; role itself is not read-only. No grant changes.
3. Exactly one protected read_frozen_routing_graph call, with tail cursors derived
   offline from SHA-verified native export20261026T190933Z-native-23ecce:
   after_node14297239927, after_edge2145825. Expected node IDs14297239930/14297239933/
   14297239934 and edge IDs2145826/2145827/2145828. This avoids normal first-page
   10000nodes/10000edges and returns only the final three of each for the verified
   frozen dataset. Existing RPC retains its own10000-per-relation maximum; unexpected
   tail contents fail the small-sample gate. Statement timeout bounds database work.
4. Record observed_graph from ACTUAL SQL-returned metadata, separately from expected
   constants; require graph eab1f7ee-a8e0-4bed-a0e1-2c4bff024936 and digest
   5e06dab0fb4d2b97ac53fd9a1178dc46aa6b98811aefbaef96528c604a04012a,
   snapshotOSM-OPS-20261018, counts926414/2145828 and expected precision/output profiles.
   Sample nodes must be active and in that snapshot. No reachability/matrix proof.
5. ROLLBACK and close. PASS requires all checks AND completed rollback. Primary
   failures remain recorded even if rollback fails; no false success after cleanup.

Evidence directory: results/worker-connection-diagnostics/<timestamp>-<suffix>.
result.json records status, connection/authentication results, observed_identity,
observed_permissions, observed_graph, observed_sample, rollback and elapsed time.
Failure includes fixed operation/type/domain/markers and validated SQLSTATE when
available; never raw exception text/DSN/password/token. Expected graph constants
alone cannot produce PASS. Timeout/crash remains non-PASS with retained phase.

The three sample nodes are tail-record integrity samples, NOT pilot depot/pickup
locations. This diagnostic does not import GraphCache/matrix code, fetch all graph
pages, store matrices, create snapshots/candidates/routes, touch policy, provision
roles, change frozen roads or enable workers/recovery.

## After the result

* FAIL: stop; share only result.json/non-secret status. Use failed phase/SQLSTATE
  and sanitized category to identify cause. No full graph retry or automatic fix.
* PASS: confirms this dedicated connection/READ ONLY role/read RPC/observed manifest
  path. It does NOT establish all-page completeness, path precision, warm-up/memory/
  matrix performance, worker write permissions in action or live Flutter routing.
  Review the report first, then assess a separately authorized bounded full graph/
  matrix probe with activation still unset. No automatic chaining to the full probe.

Offline tests exercise actual-observation mismatch, one-RPC tail limits, one-attempt
auth failure, TLS and login checks, structured permission errors/redaction, rollback
and separation from full graph/matrix paths. Existing password-escaping/activation
guard regressions are retained. No real credentials used by tests.
