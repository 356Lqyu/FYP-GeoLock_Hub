# GeoLock Hub — Windows startup

Repository: `C:\Users\User\Downloads\FYP-GeoLock_Hub`
Package: `com.example.geolock_hub_app`

| | Current: **KLSEL** (NEW project) | Historical: **DEV** |
|---|---|---|
| Supabase project | `ppwmdsyoesvhgmqiaoxa` | `rcgyuwiidqvrgbxswhqj` |
| Frozen graph | `19c44bd2-8871-4eca-bf6b-4262f1bf766d` (set automatically) | `eab1f7ee-a8e0-4bed-a0e1-2c4bff024936` |
| Worker profiles and state | `%LOCALAPPDATA%\GeoLockHubRoutingKLSEL` | `%LOCALAPPDATA%\GeoLockHubRoutingDev` |
| App build | `--dart-define-from-file=klsel-config.json` | `GEOLOCK_SUPABASE_ENV=dev` / `scripts\Run-RoutingDev.ps1` |
| Section | [KLSEL startup](#current-klsel-startup) | [Historical DEV startup](#historical-dev-startup-exact-v3-pilot) |

> ⚠️ `Start-Worker.ps1` defaults to **DEV**. Every KLSEL worker command must include `-Environment KLSEL`. A command without it, including every command in the historical DEV section, starts DEV workers.

The switches and their meaning are explained in [backend/routing/README.md](backend/routing/README.md#what-each-switch-does).

## Current: KLSEL startup

Operator rules:
- Start or restart workers only under the applicable approval. Typing an approval reference records approval already granted; it does not grant it.
- Never start a second listener on an occupied port.
- Keep credentials, the graph cache and both journals intact.
- Never uninstall the app or clear its storage to fix a startup failure.

### Terminal 1 — Validator, port 8788

```powershell
Set-Location 'C:\Users\User\Downloads\FYP-GeoLock_Hub'
$validatorListeners = @(netstat -ano -p tcp | Select-String ':8788\s+.*LISTENING')
if ($LASTEXITCODE -ne 0) { throw 'Port inspection failed. Do not start.' }
if ($validatorListeners.Count -gt 0) { $validatorListeners; throw '8788 already occupied. Leave a healthy validator running; check its health first.' }
$validatorApproval = Read-Host 'Reference for this already-approved KLSEL validator startup'
& '.\backend\routing\windows\Start-Worker.ps1' -Environment KLSEL -Mode validator -Activate -ApprovalRef $validatorApproval
```

Enter only the validator database password at the hidden prompt.
- Expected: `{"mode":"validator","status":"ACTIVE","project_ref":"ppwmdsyoesvhgmqiaoxa"}` (key order irrelevant).
- **Keep this terminal open.**

### Terminal 2 — Planner, port 8787

```powershell
Set-Location 'C:\Users\User\Downloads\FYP-GeoLock_Hub'
$plannerListeners = @(netstat -ano -p tcp | Select-String ':8787\s+.*LISTENING')
if ($LASTEXITCODE -ne 0) { throw 'Port inspection failed. Do not start.' }
if ($plannerListeners.Count -gt 0) { $plannerListeners; throw '8787 already occupied. Do not start a duplicate planner; check its health first.' }
$plannerApproval = Read-Host 'Reference for this already-approved KLSEL planner startup'
& '.\backend\routing\windows\Start-Worker.ps1' -Environment KLSEL -Mode planner -Activate -ApprovalRef $plannerApproval
```

Enter the graph and planner database passwords at their hidden prompts.
- Expected: `{"mode":"planner","status":"ACTIVE","project_ref":"ppwmdsyoesvhgmqiaoxa"}`. **Keep this terminal open.**
- No `-GraphId` is needed: KLSEL pins its own frozen graph and refuses any other.
- `-EnableCombinedWorkflow` and `-EnableExactWorkflow` are **not** used. The current app generates through `/v1/plan` and starts routes through the database RPC `authorize_and_start_my_route`.
- If this machine has no KLSEL graph cache yet, build it first with this command (read-only, starts no server):

  ```powershell
  & '.\backend\routing\windows\Start-Worker.ps1' -Environment KLSEL -Mode planner -WarmGraph -ApprovalRef $plannerApproval
  ```

### Terminal 3 — Health

```powershell
netstat -ano -p tcp | Select-String ':878[78]\s+.*LISTENING'
Invoke-RestMethod -Uri 'http://127.0.0.1:8788/health' -TimeoutSec 5 | ConvertTo-Json -Compress
Invoke-RestMethod -Uri 'http://127.0.0.1:8787/health' -TimeoutSec 5 | ConvertTo-Json -Compress
```

Expected:
- exactly one listener on each port;
- each health response is `{"status":"ACTIVE","project_ref":"ppwmdsyoesvhgmqiaoxa"}`.

A DEV `project_ref` means the worker was started without `-Environment KLSEL`. Stop that worker with Ctrl+C in its own terminal and start it again correctly. `ACTIVE` alone does not prove database permissions, graph readiness or route feasibility.

### Terminal 4 — Android app (KLSEL build)

`frontend\geolock_hub_app\klsel-config.json` is git-ignored. It holds the KLSEL URL, the NEW project's **publishable** key (never a secret or service-role key) and `GEOLOCK_ROUTING_API_URL=http://127.0.0.1:8787`. If it is missing, copy it from `klsel-config.example.json` and fill in the key.

```powershell
Set-Location 'C:\Users\User\Downloads\FYP-GeoLock_Hub'
$adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
& $adb devices -l
$androidDevice = Read-Host 'Authorized physical Android device ID from the list above'
& $adb -s $androidDevice reverse tcp:8787 tcp:8787
& $adb -s $androidDevice reverse --list
Set-Location '.\frontend\geolock_hub_app'
$dart = 'C:\flutter\src\flutter\bin\cache\dart-sdk\bin\dart.exe'
$flutterTool = 'C:\flutter\src\flutter\bin\cache\flutter_tools.snapshot'
& $dart $flutterTool --no-version-check run --debug --no-pub -d $androidDevice --dart-define-from-file=klsel-config.json
```

Notes:
- **Don't use `scripts\Run-RoutingDev.ps1`, the historical DEV commands or the installed DEV APK for KLSEL.** Each of them builds or runs against DEV.
- The app checks the planner's `/health` and refuses a planner whose `project_ref` is not `ppwmdsyoesvhgmqiaoxa`.
- Only port 8787 is needed on the phone. The planner reaches the validator on the laptop's loopback address.

---

## Historical: DEV startup (Exact-V3 pilot)

**Historical, DEV only.** This is the October–November 2026 DEV procedure, used for the Exact-V3 staged pilot. It is kept unchanged as operator evidence.
- Every command in it targets DEV project `rcgyuwiidqvrgbxswhqj`.
- It enables `-EnableCombinedWorkflow` and `-EnableExactWorkflow`, which the current app does not use.
- Do not use it for KLSEL.

Supabase DEV: `rcgyuwiidqvrgbxswhqj`

Commands below are operator instructions, not permission to generate routes or
change business records. Start/restart services only under the applicable approval.
An approval reference records permission already granted; typing one does not grant
permission. Never start a second listener on an occupied port. Keep credentials,
the sealed graph cache and both operation journals intact. Never uninstall or clear
app storage to solve a startup failure. Do not bypass PowerShell execution policy.

### TERMINAL 1 — Graph: no separate service required

The graph is already frozen in DEV. Do not initialize, activate, import or freeze it
again. The planner uses graph ID `eab1f7ee-a8e0-4bed-a0e1-2c4bff024936` through its
dedicated graph login and loads the existing sealed disk cache when needed.

Local cache presence check (no database access):

```powershell
Set-Location 'C:\Users\User\Downloads\FYP-GeoLock_Hub'
$graphId = 'eab1f7ee-a8e0-4bed-a0e1-2c4bff024936'
$graphCache = Join-Path $env:LOCALAPPDATA 'GeoLockHubRoutingDev\state\graphs'
Get-Item -LiteralPath (Join-Path $graphCache ($graphId + '.jsonl')),(Join-Path $graphCache ($graphId + '.sha256')) | Select-Object Name,Length
```

Expected: both files exist and are nonempty. Presence alone does not prove integrity
or that a running planner has loaded the graph in RAM. `GraphCache.load` verifies
the seal and current frozen manifest when loading. Service `/health` does not prove
graph readiness. The full-size graph/matrix probe already passed; do not rerun it.

Optional **separately approved bounded DEV read-only** manifest/sample verification:

```powershell
Set-Location 'C:\Users\User\Downloads\FYP-GeoLock_Hub'
& '.\docs\stage8\functional-routing\run_readonly_graph_probe.ps1' -NativeServiceDiagnostic
```

Enter only the dedicated `geolock_graph_login` password at the native hidden prompt.
Expected result.json: `READ_ONLY CONNECTION DIAGNOSTIC PASS`, `manifest_matches=true`,
`rollback_completed=true`, graph ID above, snapshot `OSM-OPS-20261018`, 926414 nodes,
2145828 edges and content digest
`5e06dab0fb4d2b97ac53fd9a1178dc46aa6b98811aefbaef96528c604a04012a`.
This is NOT a full graph load/matrix probe; do not substitute `-Run` or
`-NativeServiceProbe`. No permanent graph terminal is needed.

### TERMINAL 2 — Planner, port 8787

The guard below refuses to start another planner on an occupied port. If it finds
a listener, inspect Terminal 5 instead. A healthy service should be left running.

```powershell
Set-Location 'C:\Users\User\Downloads\FYP-GeoLock_Hub'
$plannerListeners = @(netstat -ano -p tcp | Select-String ':8787\s+.*LISTENING')
if ($LASTEXITCODE -ne 0) { throw 'Port inspection failed. Do not start.' }
if ($plannerListeners.Count -gt 0) { $plannerListeners; throw '8787 already occupied. Do not start a duplicate planner; inspect Terminal 5.' }
$plannerApproval = Read-Host 'Reference for this already-approved planner startup'
& '.\backend\routing\windows\Start-Worker.ps1' -Mode planner -GraphId 'eab1f7ee-a8e0-4bed-a0e1-2c4bff024936' -Activate -ApprovalRef $plannerApproval -EnableCombinedWorkflow -EnableExactWorkflow
```

Enter dedicated graph and planner database passwords only at their native hidden
prompts. Existing DPAPI profiles in `%LOCALAPPDATA%\GeoLockHubRoutingDev` supply the
other reviewed configuration. Native libpq 17.11 and TLS verify-full are reused.

Expected: `{"mode":"planner","project_ref":"rcgyuwiidqvrgbxswhqj","status":"ACTIVE"}`.
**Keep this terminal open.** `-EnableExactWorkflow` enables the staged API, but does
not itself create a snapshot or authorize a route. The normal combined endpoint
remains available; do not use the Flutter Generate button for an exact-three-task
pilot. Confirm staged activation through Terminal 5's authenticated read.

### TERMINAL 3 — Validator, port 8788

If already running and healthy, leave its original terminal alone. Start only when
not running and startup has been approved:

```powershell
Set-Location 'C:\Users\User\Downloads\FYP-GeoLock_Hub'
$validatorListeners = @(netstat -ano -p tcp | Select-String ':8788\s+.*LISTENING')
if ($LASTEXITCODE -ne 0) { throw 'Port inspection failed. Do not start.' }
if ($validatorListeners.Count -gt 0) { $validatorListeners; throw '8788 already occupied. Leave a healthy validator running; inspect Terminal 5.' }
$validatorApproval = Read-Host 'Reference for this already-approved validator startup'
& '.\backend\routing\windows\Start-Worker.ps1' -Mode validator -Activate -ApprovalRef $validatorApproval
```

Enter only the dedicated validator database password at the native hidden prompt.
Expected: `{"mode":"validator","project_ref":"rcgyuwiidqvrgbxswhqj","status":"ACTIVE"}`.
**Keep this terminal open.** The planner contacts the validator at
`http://127.0.0.1:8788`; Flutter does not call the validator directly.

### TERMINAL 4 — Flutter / physical Android

Connect USB, authorize debugging and select the actual device shown below. Do not
assume the serial remains the same or select an emulator accidentally.

```powershell
Set-Location 'C:\Users\User\Downloads\FYP-GeoLock_Hub'
$adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
& $adb devices -l
$androidDevice = Read-Host 'Authorized physical Android device ID from the list above'
& $adb -s $androidDevice reverse tcp:8787 tcp:8787
& $adb -s $androidDevice reverse tcp:8788 tcp:8788
& $adb -s $androidDevice reverse --list
```

Expected: device state `device`, with reverse mappings for both ports. An
`unauthorized`/`offline` device is a STOP condition. Reapply mappings after USB/ADB
reconnection. Choose ONE of the following two options.

#### Option A — Open the installed verified APK; no rebuild or replacement

```powershell
& $adb -s $androidDevice shell am start -n com.example.geolock_hub_app/.MainActivity
```

Expected: Android reports a started/reused activity and GeoLock opens. App data,
session and operation history are retained. This terminal need not stay open, but
keep USB connected. Do not press Generate, pickup or reconciliation actions as a
startup test. This is the recommended option for the existing verified demo APK.

#### Option B — Flutter development run: rebuilds/updates the installed app

```powershell
Set-Location 'C:\Users\User\Downloads\FYP-GeoLock_Hub\frontend\geolock_hub_app'
$dart = 'C:\flutter\src\flutter\bin\cache\dart-sdk\bin\dart.exe'
$flutterTool = 'C:\flutter\src\flutter\bin\cache\flutter_tools.snapshot'
& $dart $flutterTool --no-version-check devices
& $dart $flutterTool --no-version-check run --debug --no-pub -d $androidDevice --dart-define=GEOLOCK_SUPABASE_ENV=dev --dart-define=GEOLOCK_ROUTING_API_URL=http://127.0.0.1:8787 --dart-define=GEOLOCK_ROUTE_RESOLUTION_ENABLED=false
```

This is the installed SDK's Flutter CLI, invoked as the existing run script does.
Expected: debug build/install and Flutter run controls (`r` hot reload, `R` restart,
`q` quit). **Keep this terminal open** for the debugger/hot reload. It may compile
and replace the installed verified APK with current source; its hash is no longer
guaranteed to match the named verified artifact. Same package/signature normally
retains data; STOP if uninstall/storage reset is offered. Never run plain Flutter
without the routing URL define. Route resolution remains explicitly disabled.

The existing convenience wrapper is also available from the repository root:
`& '.\scripts\Run-RoutingDev.ps1' -Device $androidDevice`. It fixes DEV and the
planner URL; route resolution defaults false in source. The explicit command above
additionally pins that false define.

#### Supabase / Google Maps configuration

`lib/supabase_config.dart` selects DEV project `rcgyuwiidqvrgbxswhqj` for the DEV
define. Do not supply a service-role key. Gradle reads `google.maps.apiKey` from
`android/local.properties` into the Android manifest's Maps metadata. The key is
already present locally; do not print the file. Existing `google_maps_flutter` is
used. Debug HTTP is allowed only for localhost/127.0.0.1/emulator loopback by
`routing_debug_network_security.xml`; release cleartext is not being enabled.

Optional key-presence-only check (does not display its value):

```powershell
Set-Location 'C:\Users\User\Downloads\FYP-GeoLock_Hub\frontend\geolock_hub_app'
$mapsConfigured = Select-String -LiteralPath '.\android\local.properties' -Pattern '^google\.maps\.apiKey=\S+' -Quiet
Write-Output "Google Maps key configured: $mapsConfigured"
```

Expected: `True`. This checks wiring/presence, not current Google API restrictions
or billing. On the phone, actual map tiles are the runtime check. The routing map
remains markers-only with its honest geometry-unavailable message.

### TERMINAL 5 — Health / authenticated readiness

```powershell
Set-Location 'C:\Users\User\Downloads\FYP-GeoLock_Hub'
netstat -ano -p tcp | Select-String ':878[78]\s+.*LISTENING'
Invoke-RestMethod -Uri 'http://127.0.0.1:8787/health' -TimeoutSec 5 | ConvertTo-Json -Compress
Invoke-RestMethod -Uri 'http://127.0.0.1:8788/health' -TimeoutSec 5 | ConvertTo-Json -Compress
```

Expected: exactly ONE listener for 8787 and ONE for 8788, and each health response
`{"project_ref":"rcgyuwiidqvrgbxswhqj","status":"ACTIVE"}` (key order irrelevant).
ACTIVE alone does not prove correct credentials, graph loading or task feasibility.
Do not automatically start another service after an unhealthy response while its
port is occupied.

After approval for matching-session DEV read-only checks, leave the installed app
signed in as `testerq356@gmail.com` (NGO UUID
`8e50bc66-7a8d-4791-bc6b-640682daa496`) and run:

```powershell
& '.\.venv-stage8\Scripts\python.exe' -B '.\scripts\Verify-ExactPilotGroup1.py' --run
```

Expected: `GROUP1 PASS` and a new evidence directory. Its result.json must show
`v3_ready=true`, approved policy ID, authenticated matching NGO,
`automatic_departure=true`, `combined_generation_enabled=true` and
`exact_staged_enabled=true`. This uses the phone session only in memory and performs
approved protected reads; it creates no donation, claim, snapshot or route. It does
not independently re-export the policy body or prove graph/matrix readiness.
For an offline helper check only, omit `--run`.

For phone connectivity: expand Route support/diagnostics and perform only the
read-only planner check (or observe its automatic read-only result). Expected:
`Planner ACTIVE for DEV`. Do not press normal Generate for the staged pilot.
This terminal can close after checks finish.

#### Old duplicate planner: identify first, stop only after approval

Use the listener table above. Inspect only the PID you believe is OLD:

```powershell
$oldPlannerPid = [int](Read-Host 'OLD planner listener PID to inspect, not the new planner or validator')
Get-Process -Id $oldPlannerPid | Select-Object Id,ProcessName,StartTime
```

Prefer **Ctrl+C in that old planner's original terminal**, leaving the new planner
and validator running. Do not close the wrong terminal. If it is inaccessible,
only after explicit approval and rechecking that PID belongs to the old listener:

```powershell
Stop-Process -Id $oldPlannerPid
netstat -ano -p tcp | Select-String ':878[78]\s+.*LISTENING'
```

Never stop all Python processes or use stale PID numbers from an earlier day.
There must then be only one planner listener; rerun the read-only verifier. Missing
`exact_staged_enabled` is not PASS and must not be treated as equivalent to true.

### Business-test boundary

Startup/health/readiness does not approve donation creation, claims, planning,
authorization, pickup, recovery or depot return. Those require the reviewed fresh
fixture/task scope and explicit approvals. Do not use the preserved V2 route or
change its reconciliation cases, claims, assignments or hold. Preserve all journals
and uncertain request IDs; never automatically retry an uncertain write.

Source precedence: this guide uses the current Windows native startup scripts,
`EXACT_V3_STAGED_PILOT.md`, `FRESH_V3_E2E_OPERATOR_STEPS.md` and current Android
configuration. Older README generic Unicode-DSN, graph-warmup and historical
"activation pending" examples are not the Windows demo startup procedure.
