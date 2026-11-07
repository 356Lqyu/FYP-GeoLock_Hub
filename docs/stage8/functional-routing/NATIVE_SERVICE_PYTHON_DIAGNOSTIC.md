# Python connection using approved native libpq service and password bytes

Preparation only; no live authentication or full graph probe executed by Codex.
No more repeated password-entry comparisons. The earlier mismatch remains
unexplained; no password re-encoding/reset/normalization is introduced.

## One exact operator command

From repository root in an interactive Windows console:

```powershell
& '.\docs\stage8\functional-routing\run_readonly_graph_probe.ps1' -NativeServiceDiagnostic
```

Do NOT add -Run, -ConnectionDiagnostic or -PasswordTransportCheck. Enter the graph
login password ONCE at the native-style hidden prompt. No PowerShell SecureString,
UTF-8 password conversion, repeated comparison, password file or password environment
variable is used in this mode. No automatic retries. The budget starts AFTER entry,
so terminating a timed-out child cannot leave the parent's password prompt in
echo-disabled mode. No new terminal window is opened.

## Supported authentication path

The exact approved pg_service.proposed.conf is hash-checked, then native libpq17.11
resolves servicegeolock_dev_graph_initializer through its PGSERVICEFILE directly.
It retains DEV session pooler5432, postgres database, project-qualified graph login,
verify-full and the supplied CA. No alternate host/role/security relaxation.
Explicit parameters shorten connection timeout to5s and enforce startup
default_transaction_read_onlyon instead of the installer's writable default.
Database roles/security definitions are unchanged.

The console reader follows the PostgreSQL17 native narrow-CRT prompt pattern and
returns its bytes. Those bytes are retained verbatim; only quote/backslash syntax
escaping required by libpq's supported keyword/value format is applied. No Unicode
decode/re-encode, percent encoding, code-page guessing or SCRAM reimplementation.
The byte-oriented public psycopg.pq.PGconn.connect interface calls native PQconnectdb
directly, including service resolution and authentication. On successful status,
the same PGconn is wrapped in a psycopg Connection for actual parameterized SQL.
This removes psycopg's Unicode connect-string and DNS/nonblocking authentication
setup from THIS experiment; normal query I/O then uses psycopg as before.

libpq does not provide psql's interactive prompt automatically. The native-style
reader is a separate helper, not interception of the psql executable or takeover
of a previously authenticated session. This is a new authentication attempt using
the same intended native input/service path. Success remains UNVERIFIED until the
operator runs it; it is not asserted to reproduce every CRT/terminal condition.

References: https://www.psycopg.org/psycopg3/docs/api/pq.html and
https://www.postgresql.org/docs/17/libpq-connect.html .

## Secret handling and limits

Password moves through one anonymous in-memory stdin pipe to the diagnostic child.
It is never written to argv/environment variables/files/logs/reports; no plaintext
passfile, credential fingerprint or external credential store is created. The
nonempty explicit password avoids default passfile fallback. Inherited PG*/GEOLOCK_*
settings are removed by the launcher; approved service file is explicitly selected.

Passwords necessarily exist transiently in prompt, pipe, Python/libpq and process
memory. Mutable buffers are cleared on completion/failure; complete erasure of
immutable copies/OS buffers is not claimed. An administrator/process debugger can
inspect process memory. Do not collect dumps or print environments/connection
objects. The service profile itself contains no password and must remain unchanged.
Old native-console input limitations remain; the adapter preserves bytes rather
than guessing a correction. It does not prove their correctness before authenticating.

One native libpq connect call; no application retry loop. libpq may itself handle
multiple DNS addresses. Connection5s, SQL10s, lock2s and child45s limits. After auth:
BEGIN READ ONLY, actual login/TLS checks, graph-role permission check, one existing
protected RPC for manifest plus expected3tail nodes/3edges, then ROLLBACK/close.
No full download, matrix, policy, snapshot, candidate, route, worker or recovery.

New results/worker-connection-diagnostics/<timestamp>-<suffix>/result.json records
transport, actual client version, observed session/TLS/permissions and manifest/sample
only if returned by SQL. Failures retain sanitized phase/category/SQLSTATE or fixed
markers. Expected UUID/digest alone do not produce PASS. Unknown/failure/timeout:
STOP, preserve evidence, no automatic repair/credentials changes.

PASS establishes a working real Python connection through this native-service
adapter and bounded read-only SQL. It does NOT validate or switch the production
worker's existing authentication factory, performance, writable RPCs or Flutter
pilot. Review it before separately approving any full-size probe or worker change.

## Offline validation and changed files

Native17 library/path/service/CA check passes; actual native17 PQconninfoParse
preserves synthetic legacy/non-UTF8 bytes and quote/backslash values exactly.
Tests mock the connect operation to verify status checking, ownership transfer to
psycopg, failure cleanup and secret buffer clearing. No real password/network used.

Changed: new native_service_connection.py and native_service_diagnostic.py; optional
factory/password-pipe support in connection_diagnostic.py; single-prompt label in
password_transport_check.py; launcher isolated mode; offline regression tests.
All other diagnostic modes and live-worker connection factories remain unchanged.
