# Native Windows runtime adapter — local PASS / DEV check pending

**Current update:** actual validator and planner/graph DEV runtime reports now PASS
(`20261027T095305Z-2ea399` / `20261027T095412Z-b02a67`). The connection gate is
closed. A subsequent local startup review found the planner's protected publishable
key fails the required format check; see
[SERVICE_ACTIVATION_REVIEW.md](SERVICE_ACTIVATION_REVIEW.md). No service activation.
The pending-DEV-check statements below are historical.

27 October2026. No service activation, DEV connection, graph load/cache change,
business write, permission change or scheduler/recovery activation was performed.

## Change and scope

The old Windows launcher revealed database SecureStrings into Unicode DSNs and
selected the default psycopg binary libpq18.4. The proven probe instead pinned
native libpq17.11 and passed original narrow-console bytes to PQconnectdb. These
are confirmed path differences; they do not establish that18.4 itself is incompatible
with Supabase or that Unicode encoding alone caused every earlier failure.

`Start-Worker.ps1` now invokes `native_worker.py`, which selects the existing exact
native17.11 DLL before importing the server. Existing hash-pinned approved service
settings are reused, with explicit dedicated graph/planner/validator login overrides,
session pooler5432, postgres and verify-full/approved CA. Password-free DSNs carry
only expected configuration; drift, extra password fields or wrong roles fail closed.
No credential, service file, database role, permission or approved migration changed.

Database passwords are collected at the existing native CONIN$ hidden prompt, once
per role before the HTTP listener starts. They are not read from the old Unicode
profile fields, re-encoded, normalized, fingerprinted, logged, put in argv/environment
or persisted. Mutable buffers are cleared at process shutdown and temporary
connection copies are cleared after authentication. Passwords necessarily remain
in process/libpq memory during operation; no claim of eliminating every transient
immutable copy. Existing encrypted profiles remain untouched and still supply
non-secret target settings, shared validator token and DEV publishable key.

The factory returns ordinary psycopg connections to existing RoleRpc; its normal
role/membership checks, per-request commit on success, rollback on failure and
connection close remain intact. The read-only probe's Borrowed/always-rollback
wrapper is not used for live runtime RPCs. Server activation guards are unchanged.
Other platform/direct-server entrypoints are unchanged; use the Windows launcher.

## Verification actually completed

-101 worker tests PASS in38.164s before the final TLS-visibility adjustment.
- Final relevant native-runtime/native-service suite:17 PASS in2.399s.
- Updated Windows launcher PowerShell syntax PASS. Both actual launcher
  `-CheckConfig` paths exited0 with DISABLED through the pinned native entrypoint,
  no password prompt, database connection or HTTP server.
- Owned disposable loopback PostgreSQL17.11 with synthetic roles/certificates:
  planner and validator actual native TLS connections PASS, each intended role,
  full8-RPC ACL matrix, explicit READ ONLY, ROLLBACK and close PASS. Synthetic
  normal runtime connections committed successful local writes and rolled back
  failures. Local server stopped afterward. These local fixture writes were NOT
  DEV operations and do not prove Supabase runtime credentials.
- TLS must be observed while still the authenticated login. After SET ROLE to
  a NOLOGIN worker, PostgreSQL can redact pg_stat_ssl fields. The check preserves
  both actual observations rather than requiring broader stats permissions.

Local evidence:
`results/worker-native-adapter-local/20261027-native17/local-tls-runtime-regression.json`.

## Exact next commands — already authorized READ ONLY

Run in interactive PowerShell from repository root. Do not add Activate.

```powershell
& '.\backend\routing\worker_service\windows\Start-Worker.ps1' -Mode validator -CheckConnection
```

Enter the dedicated validator login's current password at the native hidden prompt.
Stop on failure; no automatic retry or credential change. If PASS, run:

```powershell
& '.\backend\routing\worker_service\windows\Start-Worker.ps1' -Mode planner -GraphId 'eab1f7ee-a8e0-4bed-a0e1-2c4bff024936' -CheckConnection
```

This prompts for the planner login and graph login passwords, each clearly labeled.
These use the SAME native factory and RoleRpc connection path as service startup.
No HTTP listener/application activation is constructed. Each session starts with
read-only startup options, then explicit BEGIN READ ONLY,10s statement and2s lock
limits. Only identity, SSL and catalog permission SELECTs occur. No routing RPC,
graph query, matrix, snapshot or business action is executed. Connections always
roll back/close; one failure stops the mode with no authentication retry.

Reports are written to fresh `results/worker-runtime-connections/<UTC>-<suffix>/result.json`:
native17.11 client; actual login and effective role; actual pre-role TLS/read-only
observations;8 allowed/denied permission results; rollback and close. Failures retain
only sanitized phase/type/SQLSTATE/markers, never raw exceptions or credentials.

**DEV runtime connection verification is NOT RUN by Codex.** The original native
password bytes are not available to the agent, and safely obtaining them requires
your local hidden entry. No re-encoding of stored Unicode passwords is attempted.
Return the result paths/statuses, not passwords. After both modes PASS, the
technical connection gate can be marked closed based on actual DEV evidence.

## Subsequent commands — require separate explicit service activation approval

After the two DEV reports PASS, in separate terminals:

```powershell
$approvalRef = Read-Host 'Actual approved service-activation reference'
& '.\backend\routing\worker_service\windows\Start-Worker.ps1' -Mode validator -Activate -ApprovalRef $approvalRef
```

```powershell
$approvalRef = Read-Host 'Actual approved service-activation reference'
& '.\backend\routing\worker_service\windows\Start-Worker.ps1' -Mode planner -GraphId 'eab1f7ee-a8e0-4bed-a0e1-2c4bff024936' -Activate -ApprovalRef $approvalRef
```

Enter native passwords once again for each new service process. Validator starts
private127.0.0.1:8788; planner127.0.0.1:8787. Existing sealed cache/state remain in
the protected local directory. Neither approval is inferred from this document.

Read-only health checks after approved startup:

```powershell
Invoke-RestMethod 'http://127.0.0.1:8788/health'
Invoke-RestMethod 'http://127.0.0.1:8787/health'
```

HealthACTIVE confirms activation state only. The named NGO pilot still requires
explicit approval for claim/snapshot/matrix/seal/candidate/attestation/authorization/
pickup/depot-return writes. Recovery stays disabled. The existing Flutter emulator
endpoint and UI remain unchanged; no new graph/performance probe is needed.

Files changed: `native_service_connection.py`, new `native_worker.py`,
`server.py` (optional RPC factory injection only), `windows/Start-Worker.ps1`,
new `tests/test_native_worker.py`, extended local-only
`supabase/tests/local_probe_transaction_regression.py`, and current documentation.
