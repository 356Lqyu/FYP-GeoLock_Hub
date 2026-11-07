# Graph-login native PASS vs Python connect failure

27 October2026 MYT. No live authentication/probe retried by Codex; original failure
20261027T053742Z-26ad1a and frozen graph/policy/permissions untouched.

## Confirmed comparison

Owner's native psql17 test with approved geolock_dev_graph_initializer service
authenticated as geolock_graph_login/session_user and databasepostgres. Python
diagnostic failed in connect after3.844s, OperationalError, SQLSTATEnull, auth-text
marker, no observed identity or graph. The marker is not independent proof of an
incorrect password or PostgreSQL-vs-pooler origin.

Offline effective configuration comparison passes for all six requested fields:

| Setting | Native service and Python DSN |
|---|---|
| host | aws-0-ap-northeast-2.pooler.supabase.com |
| port | 5432 session pooler |
| database | postgres |
| username | geolock_graph_login.rcgyuwiidqvrgbxswhqj |
| TLS | verify-full |
| CA | C:/Users/User/Downloads/prod-ca-2021.crt |

Python explicitly overrides ambient hostaddr/options/target fields and launcher
removes PG*/GEOLOCK_* overrides in its child. Known differences: native service
connect_timeout15/default_transaction_read_onlyoff; RoleRpc connect_timeout5 and
options empty, followed by explicit BEGIN READ ONLY. Neither transaction setting
has run at the reported connect failure. No evidence identifies these as its cause.

DSN is libpq keyword/value syntax, NOT URI. Percent encoding is neither required
nor applied. Password single quotes/backslashes are escaped for libpq; spaces,
Unicode and shell metacharacters pass offline conninfo roundtrip tests. No confirmed
quoting/escaping defect found. SecureString→BSTR→managed string→child environment is
the inspected path; no actual password bytes compared to native console input.
Different entry bytes/invisible characters/normalization remain hypotheses, not
findings; no credentials are requested, printed, hashed or persisted.

Concrete client mismatch: default psycopg3.3.6 binary implementation selected its
bundled libpq18.4 (180004); installed native psql uses17.11. Server/pooler negotiation
or client differences remain hypotheses. Do not claim a known Supabase/libpq18 bug
or reset passwords based on these observations.

## Smallest controlled correction

The existing launcher's -ConnectionDiagnostic now starts
connection_diagnostic_native17, which pins ONLY this diagnostic process and its
bounded child to the actual installed C:/Program Files/PostgreSQL/17/bin/libpq.dll,
version170011, through psycopg's pure-Python implementation. It fails closed on wrong
path/version or an already imported client; no fallback/retry. Offline load check
passes. No package reinstall/upgrade, global PATH change or production worker
client change. Password handling, TLS and the approved connection identity remain
unchanged. This aligns the known client difference; it is NOT proof the underlying
authentication issue is resolved until the operator-run diagnostic returns.

Report now records actual psycopg implementation/libpq version and allowlisted
nonsecret connection fields, in addition to operation/SQLSTATE/sanitized error
category and actual SQL-returned manifest when reached.

Exact bounded diagnostic command from repo root:

```powershell
& '.\docs\stage8\functional-routing\run_readonly_graph_probe.ps1' -ConnectionDiagnostic
```

Enter graph-login password at the hidden prompt. One attempt, READ ONLY, expected
three tail nodes/three edges,45s total. No full graph/matrix/server/write activation.
Preserve the NEW results/worker-connection-diagnostics report. On failure STOP;
no automatic retry/password reset/TLS weakening/grants. On PASS review actual
identity/graph/digest/client170011 first. The full probe still uses its original
client and remains HOLD; do not infer its auth/performance PASS from this diagnostic.

Safe additional local check (no password/network):

```powershell
& '.\.venv-stage8\Scripts\python.exe' -B -m backend.routing.worker_service.connection_diagnostic_native17 --check-local
```

Offline regressions cover six-field equality to the approved service, password
roundtrips, native17 DLL path/version, child retaining the pinned bootstrap, and
the existing bounded/read-only/redaction gates. No successful live authentication
or root-cause attribution is fabricated.
