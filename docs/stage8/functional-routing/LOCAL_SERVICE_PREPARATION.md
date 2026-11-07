# Local planner/validator preparation — activation HOLD

**Runtime adapter update:** Windows startup now reuses pinned native libpq17.11
and original native-console password bytes. Local tests PASS; both startup
configuration checks remain DISABLED. Actual DEV runtime checks await your local
hidden password entry using `Start-Worker.ps1 -Mode validator -CheckConnection`
and then planner mode. See [NATIVE_RUNTIME_ADAPTER.md](NATIVE_RUNTIME_ADAPTER.md)
for authoritative current commands and evidence. The18.4-path description below
is historical. Activation remains HOLD until the DEV checks pass and you approve it.

27 October2026. No service started, DEV connection made, snapshot/business write,
permission change, recovery activation or frozen-graph modification performed.

## Actual local checks completed

- Both encrypted profiles exist in `%LOCALAPPDATA%\GeoLockHubRoutingDev` and were
  successfully deserialized under the owning Windows account. All required
  SecureString fields are nonempty: graph/planner/validator passwords, planner DEV
  publishable key and each profile's validator token. Values were not printed.
  This establishes presence/decryptability, not credential validity or token equality.
  Do not rerun Save-WorkerConfig or overwrite these profiles.
- Both target DEV `rcgyuwiidqvrgbxswhqj`, approved session pooler on5432,
  sslmodeverify-full. CA exists at `C:\Users\User\Downloads\prod-ca-2021.crt`.
  Stored planner GraphId is empty: pass the approved graph ID explicitly below.
- User-reported planner/validator native identity/permission checks PASS; reused,
  not repeated. Full-size native graph/matrix PASS reused.
- Original319523682-byte sealed cache SHA256 verified:
  `a525f79eada8fc65ce0568fd0cdba66237f1e5e6e3009bb4fa0e7482fc70accb`.
  Copied and checksum-verified at
  `C:\Users\User\AppData\Local\GeoLockHubRoutingDev\state\graphs`.
  Original probe evidence preserved. Both `.jsonl` and `.sha256` files are present;
  copied seal published last. New `Prepare-WorkerCache.ps1` refuses to overwrite
  different/incomplete caches and performs no connection or activation.
- Existing startup commands with `-CheckConfig` exited0 for both modes and printed
  DISABLED. The existing application exits early while activation is unset, so
  this is NOT proof of runtime credentials, active configuration or DB connectivity.
  No HTTP server was started. Cache preparation script PowerShell AST syntax PASS.

## Remaining runtime connection gate

Plain worker Python currently selects psycopg3.3.6 **binary libpq18.4**. The proven
native-service probe used the Python implementation with exact native libpq17.11,
service configuration and original password bytes. Existing Start-Worker.ps1
instead constructs Unicode keyword DSNs from DPAPI SecureStrings and invokes the
ordinary worker module. It does not select the native probe connection factory.

Therefore service activation is HOLD until the actual runtime connection path for
all three logins is confirmed in READ ONLY sessions or the narrowly scoped runtime
adapter to the proven native method is prepared/validated. Do not assume copying
the READ ONLY probe wrapper enables matrix storage/candidate submission/attestation;
runtime transactions must preserve RoleRpc commit/rollback and scoped worker roles.
No password resets, diagnostic comparisons, grants or graph probe are needed.
No automatic authentication attempt or runtime adapter change was made here.

## Exact prepared commands

From repository root. Optional repeat of LOCAL-ONLY checks (already executed):

```powershell
& '.\backend\routing\worker_service\windows\Start-Worker.ps1' -Mode validator -CheckConfig
& '.\backend\routing\worker_service\windows\Start-Worker.ps1' -Mode planner -GraphId 'eab1f7ee-a8e0-4bed-a0e1-2c4bff024936' -CheckConfig
```

After runtime connection gate is closed AND explicit service activation approval,
run in two interactive PowerShell terminals. `$approvalRef` must name the actual
user approval record; no approval is inferred from these prepared commands:

```powershell
# Terminal1 — conditional; NOT authorized/executed by preparation.
$approvalRef = Read-Host 'Actual approved service-activation reference'
& '.\backend\routing\worker_service\windows\Start-Worker.ps1' -Mode validator -Activate -ApprovalRef $approvalRef
```

```powershell
# Terminal2 — conditional; NOT authorized/executed by preparation.
$approvalRef = Read-Host 'Actual approved service-activation reference'
& '.\backend\routing\worker_service\windows\Start-Worker.ps1' -Mode planner -GraphId 'eab1f7ee-a8e0-4bed-a0e1-2c4bff024936' -Activate -ApprovalRef $approvalRef
```

Existing launcher uses distinct credentials for each role, shared internal token,
freshness300s, protected persistent state, private validator127.0.0.1:8788 and
planner127.0.0.1:8787. It clears its routing credential/activation environment on
exit. Secrets briefly exist in process memory/environment during runtime; do not
capture dumps, environment listings or transcripts of secret-bearing commands.

From a third terminal, after approved startup:

```powershell
Invoke-RestMethod 'http://127.0.0.1:8788/health'
Invoke-RestMethod 'http://127.0.0.1:8787/health'
```

Expected each: statusACTIVE, project_ref`rcgyuwiidqvrgbxswhqj`. Health is read-only
and reports activation only; it proves neither DB authentication nor route validity.
Use Ctrl+C in each service terminal to stop intake. Do not publicly expose validator.

## Separate business-write approval

Service preparation/health checks do not authorize a live demonstration. Obtain
explicit approval for a named NGO/vehicle/donation and the exact scope: fresh claim
if needed, snapshot, matrix storage, sealing, candidate submission, validator
attestation, route authorization/reservations, pickup start/actual handover completion
and confirmed depot return. No manual fixtures or recovery. Leave expired claims alone.

After those approvals, shortest Flutter endpoint is Android emulator debug:

```powershell
Set-Location '.\frontend\geolock_hub_app'
& 'C:\flutter\src\flutter\bin\flutter.bat' run --dart-define=GEOLOCK_SUPABASE_ENV=dev --dart-define=GEOLOCK_ROUTING_API_URL=http://10.0.2.2:8787
```

Select eligible sources with >255min remaining lease/listing validity, verified NGO
depot and available owned vehicle. Existing Flutter route/authorization/pickup/depot
screens are reused. No UI rewrite. Full claim-to-route API latency remains to be
observed during the first approved pilot; the successful matrices are supporting
evidence, not proof of complete150s request latency.
