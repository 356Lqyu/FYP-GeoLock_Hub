# NativeServiceProbe transaction startup correction

27 October2026 MYT. Original failure20261027T065011Z-70282f is preserved. No DEV
connection/retry/graph query, permission change, policy/freeze mutation or activation
performed in this investigation. Authentication path is unchanged.

## Confirmed cause

The two paths use the same native PQconnectdb→psycopg.Connection adapter, whose
default client autocommitFalse/read_onlyNone means the first SQL statement starts
an ordinary implicit BEGIN, without an explicit READ ONLY clause.

NativeServiceDiagnostic sets autocommitTrue, executes BEGIN READ ONLY, then queries
identity; that is why it observed transaction_read_onlyon. NativeServiceProbe's
persistent-session factory queried identity FIRST, before returning the borrowed
connection to ReadOnlyGraphRpc. It observed transaction_read_onlyoff and correctly
closed the connection. Its later SET TRANSACTION READ ONLY had not been reached.
page_rollbacks0 is consistent with no borrowed page/graph call being started.

The failed check reads current_setting('transaction_read_only') INSIDE the implicit
transaction. It does not read default_transaction_read_only or query outside a
transaction. The earlier report did not record the server default; service/pooler
handling of startup options is not proven by that report. The programming defect
was relying on startup defaults before explicit transaction setup. No auth/TLS or
graph repair is indicated.

## Smallest fail-closed correction

Native session requires fresh connection IDLE, sets autocommitFalse/read_onlyTrue
BEFORE its first SELECT. Psycopg consequently emits BEGIN READ ONLY before identity
and on subsequent transaction starts. The SAME existing identity/TLS/read_onlyon
check remains mandatory. Initial rollback must return IDLE. Driver transaction
policy/IDLE are checked before every borrow; drift closes rather than reconnects.

ReadOnlyGraphRpc retains SET TRANSACTION READ ONLY and now additionally SELECTs the
actual transaction_read_only state BEFORE any cursor/role/graph RPC work; anything
other than on closes/fails. Page contexts retain ROLLBACK (never COMMIT), verify
IDLE afterward and close on failure. No failed check was removed or weakened.

Identity evidence now includes default_read_only separately from read_only, and
session metrics identify initialization/failure phase. A server default off is
permitted only when the ACTUAL active transaction is independently verified on.
Structured WorkerError guard failures are categorized as contract rejection instead
of misleading unstructured connection/auth failure.

## Tests

Unit regressions cover setup ordering, default-off/transaction-on separation,
nonidle rejection, initial RO-off rejection, per-page RO-off rejection before graph
query, rollback/driver-state drift, cleanup and no reconnect.

Real disposable LOCAL PostgreSQL17.11/TLS regression used native libpq170011 and
the actual PQconnectdb→psycopg.Connection wrapping path with server default OFF:

* Old first implicit SELECT reproduced read_onlyoff/default_read_onlyoff.
* Corrected initialization and two successive page transactions observed ROon while
  default stayedoff; real rollbacks returned transaction statusIDLE.
* A synthetic local write, despite local fixture INSERT permission, was rejected
  with SQLSTATE25006. The local test table remained empty; session then closed.
* Local TLS used an ephemeral self-signed test CA with verify-full; no production
  certificate/key/credentials or DEV fixtures. Server was stopped after the test.
  pg_stat_ssl visibility under SET ROLE yielded null in page metadata, so TLS proof
  is the actual initial login observation, not an invented per-role observation.

Saved non-secret local report:
results/worker-readiness/local-readonly-transaction-regression.json.
Local temporary certificate/private key were NOT copied into the repository.
Local SQL fixture grants do not alter or represent changes to DEV roles.

## Separate operator retry only

No further prerequisite reset, policy install, graph export/freeze or service edit.
For a separately approved retry from repository root:

```powershell
& '.\docs\stage8\functional-routing\run_readonly_graph_probe.ps1' -NativeServiceProbe
```

Same one native prompt and proven byte-preserving service authentication. Existing
600s/4096MiB sampled-stop controls, host headroom, frozen ID/digest, rollback and
secret-redaction gates remain. No automatic retry or worker/recovery activation.
Require observed_identity.read_onlyon, verified pages/cleanup and resource evidence;
performance remains NOT MEASURED because DEV graph loading has not begun.

Files changed: native_readonly_session.py, readonly_pilot_probe.py, identity evidence
SQL in connection_diagnostic.py, probe_diagnostics.py guard classification, worker
regressions, and explicit local_probe_transaction_regression.py/local report/docs.
No approved migration/service-profile/role/graph/policy changed.
