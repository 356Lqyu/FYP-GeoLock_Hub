# GeoLock Hub: Windows laptop routing (selected default)

7 November 2026 MYT. This is the selected workflow for the owner, routing teammate and supervisor. No Render, Docker, Linux, cloud worker or PostgreSQL journal redesign is required. Supabase remains the existing remote Auth/database: this is laptop-based computation, not an internet-free app. No commands in the live-session sections below were executed during this review.

## 1. What runs where

```text
Android app -> planner HTTP API 127.0.0.1:8787 on chosen laptop
                    |-> existing Python algorithms / OR-Tools CP-SAT
                    |-> persistent local SQLite journal and graph cache
                    |-> independent validator HTTP process 127.0.0.1:8788
Both processes -> existing scoped Supabase DEV RPCs over verified database TLS
App -> Supabase Auth / protected RPCs using its own NGO login
```

`Start-Worker.ps1` starts the HTTP server itself; no separate gateway is needed for USB/emulator use. Keep both PowerShell terminals open and the laptop awake and online during the demonstration. The planner serializes planning jobs. `ACTIVE` means enabled HTTP service, not verified DB permissions, graph readiness or a successful route. Only protected database authorization grants route authority.

Default is still **disabled until explicit activation**. Choosing this workflow does not enable DEV writes. Obtain a current session approval before the activation commands or any real routing request.

## 2. Choose the role of each laptop

| Person | Simplest arrangement | Independent hosting requirements |
| --- | --- | --- |
| Owner | Existing repository, venv and protected profiles; run offline check first | Existing approved local setup; do not overwrite credentials/journal |
| Teammate | Own checkout and offline tests; connect phone to the agreed backend laptop for joint demo | Same native client/profile/CA prerequisites; administrator-approved scoped credentials provisioned locally |
| Supervisor | Use app with own authorized NGO account against the agreed laptop; no database password required | If their laptop must host: complete the same operator setup and credential approval as teammate |

Each can run computation independently after provisioning. They are **not automatically ready merely by copying the repository**. Do not copy the owner's encrypted profiles, database passwords, live SQLite journal or private keys. DPAPI profiles are bound to the Windows user/PC and cannot be used as portable configuration.

Use one agreed backend laptop per demonstration/request stream. Separate laptops have separate journals. Do not load-balance requests or resume an uncertain operation on a different laptop without its recovery state and an approved recovery procedure. Shared DEV data remains shared: coordinate test NGO accounts, vehicles and claims rather than expecting isolated databases.

## 3. Install prerequisites once (operator actions, not executed here)

Install approved Python **3.12 x64**, Git or an approved complete project copy, and Flutter/Android SDK only if building the APK or using ADB. The existing native launcher additionally requires **libpq 17.11** at `C:\Program Files\PostgreSQL\17\bin\libpq.dll`. Its version must be exactly `170011`; a different major/patch or pip's bundled libpq does not satisfy the pin. No local PostgreSQL database server needs to be started for routing. Have the administrator supply/install a verified compatible client; this guide does not silently install or downgrade software.

Open PowerShell in your own project checkout. The owner uses:

```powershell
Set-Location 'C:\Users\User\Downloads\FYP-GeoLock_Hub'
py -3.12 --version
# New laptop only; do not recreate an existing working venv:
py -3.12 -m venv .venv-stage8
& .\.venv-stage8\Scripts\python.exe -m pip install -r .\backend\routing\requirements.txt
& .\.venv-stage8\Scripts\python.exe -m pip check
```

On other laptops change only `Set-Location` to that person's checkout. Dependencies are pinned by `backend/routing/requirements.txt` and `backend/routing/requirements-lock.txt`, including OR-Tools 9.15.6755 and psycopg 3.3.6. Do not regenerate pins or upgrade the solver to fix an installation error. Installing packages uses the configured package index but does not access DEV. A venv activation command is unnecessary because every command uses its explicit Python path.

If local PowerShell policy blocks trusted project scripts, review them and, if organizational policy permits, use a session-only policy:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned
```

Do not weaken machine policy or bypass organizational restrictions.

### Important native-launcher portability prerequisite

The existing launcher uses a **hash-pinned** profile at `docs/stage8/stage-a/deployment-preparation/routing-initialization/pg_service.proposed.conf`. It fixes the DEV session-pooler host, port 5432 and the CA path **`C:/Users/User/Downloads/prod-ca-2021.crt`**, even on another person's laptop. `NativeRpcFactory` compares saved DSN settings with this profile before asking for passwords. `Save-WorkerConfig.ps1` offers other hosts/system trust, but those choices do **not** override the native pin.

For unchanged native behavior, an administrator must arrange the public, independently verified database CA file at that exact path and the approved client directory on each operator laptop, with appropriate permissions. The CA certificate is public trust material, not a database password; verify its authenticity through the project administrator. Do not create another Windows account or copy a private key. If the exact path cannot be provisioned under local policy, **stop at offline setup**. A portable reviewed profile change is a separate small follow-up; do not edit the historical profile/hash or disable `verify-full` as a workaround. This is a pre-existing portability restriction, not a Render dependency.

## 4. Verify setup without accessing DEV

```powershell
.\backend\routing\windows\Test-LocalRoutingSetup.ps1
& .\.venv-stage8\Scripts\python.exe -B -m unittest discover -s backend/routing/tests/service -t . -q
```

The setup check clears activation/database variables **in its child processes**, imports no encrypted profiles and starts isolated disabled APIs on temporary ports. It GETs only `/health` and stops its own children. Existing services on 8787/8788 are left alone. Expected result: `PASS`, native client `NOT CONNECTED`, both health results `DISABLED`. Worker test discovery includes the Windows SQLite journal regression under `backend/routing/tests/service`.

## 5. Credentials and saved configuration (approved operator only)

The administrator must authorize and privately provision existing scoped credentials; this guide does not grant or create anything:

| Credential / scope | Where required |
| --- | --- |
| `geolock_graph_login`, member only of `geolock_graph_worker` | Planner: frozen graph/matrix RPCs |
| `geolock_planner_login`, member only of `geolock_planner` | Planner: snapshot/candidate RPCs |
| `geolock_validator_login`, member only of `geolock_validator` | Independent validator: work-item read and attestation |
| DEV publishable client key | Planner Auth checks / Flutter; never service_role or postgres |
| Random private validator token | Both server profiles on same laptop, generated by setup; never APK |
| NGO Auth session/account | Each app user; current NGO/fleet/task/depot eligibility still required |

The native launcher currently fixes these three LOGIN names. Independently revocable per-person LOGIN names would need administrator provision and a separately reviewed launcher change; they cannot simply be typed into the existing wizard. Do not send the owner's credentials to teammates. The project administrator must determine approved operator credential distribution; otherwise use app-only access to the chosen host. No postgres password, Supabase secret/service-role key, direct table-write permission or cross-role membership is needed by the worker. Current DEV permissions have **not** been rechecked in this local review.

For a newly approved host, once the native prerequisites are satisfied:

```powershell
.\backend\routing\windows\Save-WorkerConfig.ps1
```

Answer **Y** for session pooler, use the exact host from the pinned profile, enter the exact CA path above, then use the masked prompts for authorized credentials and DEV publishable key. Existing graph UUID: `eab1f7ee-a8e0-4bed-a0e1-2c4bff024936` (historically approved; current availability is not freshly verified here). Never initialize/refreeze graphs or replay migrations to set up another laptop. The wizard refuses to overwrite existing profiles. Do not delete them to get past that protection. Profiles/state are outside Git under `$env:LOCALAPPDATA\GeoLockHubRoutingDev`.

No activation or DB call occurs during saving. The saved passwords exist for historical configuration compatibility; the native startup still asks for hidden native-console passwords once per process before serving requests. Do not put passwords in command arguments, transcripts, environment dumps or Flutter defines.

<a id="quick-start-windows-routing-android-flutter-app"></a>

## Quick Start — Windows Routing + Android Flutter App

**Release status: the seven-folder routing release remains undeployed pending DEV validator compatibility and cutover approval.** Use this sequence only for an explicitly approved checkout, DEV session, and graph. The earlier references `DEV-GROUP1-EXACT-20261030` and `DEV-VALIDATOR-RESTORE-20261029` are historical examples. Obtain current approval for each role before activation. Supplying an approval string to the launcher does not itself grant approval.

### Initial setup

1. Follow [Windows prerequisites](#3-install-prerequisites-once-operator-actions-not-executed-here) for Python 3.12 x64, the pinned worker dependencies, native libpq 17.11, and the verified CA at the pinned location. A local PostgreSQL server is unnecessary.
2. Have the DEV administrator provision the scoped graph, planner, and validator logins, the DEV publishable client key, and an approved frozen graph. Follow [saved configuration](#5-credentials-and-saved-configuration-approved-operator-only) to register the profiles privately. Use an authorised DEV NGO account in the app. The validator token stays between the two services.
3. Install Flutter, the Android build toolchain and SDK platform-tools. The current [Flutter launcher](../scripts/Run-RoutingDev.ps1) expects its Flutter tool files under `C:\flutter\src\flutter\bin\cache` and ADB under `%LOCALAPPDATA%\Android\Sdk\platform-tools`. Confirm these locations before proceeding. From the repository root, run dependency setup with the same Flutter SDK on PATH. The launcher itself uses `--no-pub`.

   ```powershell
   Push-Location .\frontend\geolock_hub_app
   try { flutter pub get } finally { Pop-Location }
   ```

### Read-only configuration checks

From the repository root, check the saved worker profiles and Flutter launcher paths without activation. Run the worker checks as the operator who saved the profiles.

```powershell
.\backend\routing\windows\Start-Worker.ps1 -Mode validator -CheckConfig
.\backend\routing\windows\Start-Worker.ps1 -Mode planner -CheckConfig
.\scripts\Run-RoutingDev.ps1 -CheckConfig
```

These checks do not start workers, alter ADB mappings, launch Flutter, or connect to DEV. `-CheckConnection` is a separate read-only **live DEV** check that requires approval. Never combine it with `-Activate`. It writes a local diagnostic receipt under `results/worker-runtime-connections/`.

```powershell
.\backend\routing\windows\Start-Worker.ps1 -Mode validator -CheckConnection
.\backend\routing\windows\Start-Worker.ps1 -Mode planner -CheckConnection
```

### Normal startup after setup and approval

Open three PowerShell terminals at the repository root. Before launching, use the following to check whether ports 8787 or 8788 are already occupied. Identify the owning session before proceeding if either is in use.

```powershell
Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
    Where-Object { $_.LocalPort -in 8787,8788 } |
    Select-Object LocalAddress,LocalPort,OwningProcess
```

1. **Terminal 1 — Start Validator.** Enter its current approval reference and use only the hidden native password prompt. Leave the terminal open.

   ```powershell
   $validatorApproval = Read-Host 'Current approved DEV validator reference'
   .\backend\routing\windows\Start-Worker.ps1 -Mode validator -Activate -ApprovalRef $validatorApproval
   ```

   From terminal 3, check the existing listener before starting the planner. Expect `ACTIVE` and DEV project `rcgyuwiidqvrgbxswhqj`.

   ```powershell
   Invoke-RestMethod 'http://127.0.0.1:8788/health' -TimeoutSec 5
   ```

2. **Terminal 2 — Start Planner.** The UUID `eab1f7ee-a8e0-4bed-a0e1-2c4bff024936` is a previously working **DEV example**. Enter it only if the administrator confirms it is still available and approved for this session. Otherwise enter the approved frozen graph ID. Leave the terminal open.

   ```powershell
   $graphId = Read-Host 'Approved frozen DEV graph UUID'
   $plannerApproval = Read-Host 'Current approved DEV planner reference'
   .\backend\routing\windows\Start-Worker.ps1 -Mode planner -GraphId $graphId -Activate -ApprovalRef $plannerApproval -EnableCombinedWorkflow
   ```

   `-EnableCombinedWorkflow` enables the normal Flutter Generate & Authorize flow. The separate exact pilot is outside this Quick Start. From terminal 3, check the planner listener. `ACTIVE` confirms the HTTP listener is enabled. It does not prove graph readiness, current database permissions, or a successful route.

   ```powershell
   Invoke-RestMethod 'http://127.0.0.1:8787/health' -TimeoutSec 5
   ```

3. **Terminal 3 — Connect Android.** Use a USB data cable, enable USB debugging, and authorise this laptop on the phone. Continue only if ADB shows the selected device as `device`.

   ```powershell
   $adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
   & $adb devices -l
   $device = Read-Host 'Authorised physical Android device serial'
   $state = & $adb -s $device get-state
   if ($LASTEXITCODE -ne 0 -or $state -ne 'device') { throw 'Android device is not ready' }
   foreach ($port in 8787,8788) {
       & $adb -s $device reverse "tcp:$port" "tcp:$port"
       if ($LASTEXITCODE -ne 0) { throw "ADB reverse failed for port $port" }
   }
   & $adb -s $device reverse --list
   ```

   The app uses port 8787, the planner. The planner talks to the validator on laptop loopback. The Flutter launcher also installs both USB mappings, including 8788, to match its current workflow. No LAN firewall rule is required. Keep the validator token out of Flutter.

4. **Terminal 3 — Run the Flutter debug app.**

   ```powershell
   .\scripts\Run-RoutingDev.ps1 -Device $device
   ```

   The launcher reapplies both USB mappings, builds and launches the debug app, and selects the DEV Supabase environment and `http://127.0.0.1:8787` as the planner endpoint. Sign in with the authorised DEV account. Use the app's connection check before generating a route. Generate & Authorize can write to DEV, so use it only within the approved scope. Keep the laptop awake and preserve app storage and pending request IDs.

For shutdown, see [Stop and recover safely](#9-stop-and-recover-safely). For device, graph, or connection errors, see [Troubleshooting](#10-troubleshooting-and-remaining-requirements). A first graph load can be slow and memory-intensive. The optional cache preparation script requires separate graph-export approval and does not prove the live database manifest.

## 7. Android emulator on backend laptop

Use the standard Android emulator host alias, not the emulator's own localhost:

```powershell
# From frontend/geolock_hub_app; select emulator when prompted:
flutter run --debug --dart-define=GEOLOCK_SUPABASE_ENV=dev --dart-define=GEOLOCK_ROUTING_API_URL=http://10.0.2.2:8787
```

No reverse tunnel normally needed. A physical phone cannot use `10.0.2.2` to locate your laptop. For an emulator on **another** laptop, use the LAN HTTPS arrangement below (or run its own approved backend); that emulator's host alias points to the wrong machine.

## 8. Another device on the LAN: optional HTTPS setup

USB is the default. For wireless LAN access, `127.0.0.1` on a phone is not the laptop, and HTTP `http://192.168.x.x:8787` is rejected by both existing Flutter URL validation and Android debug policy. Do not broaden that allowlist, disable certificate validation or expose the validator to make it work.

Find the backend laptop's active Wi-Fi/Ethernet IPv4 (not Docker/WSL/VPN), for example `192.168.1.50`:

```powershell
Get-NetIPConfiguration | Select-Object InterfaceAlias,IPv4Address,IPv4DefaultGateway
```

Both devices must share a reachable trusted LAN; guest Wi-Fi/client isolation can block connections. Use an administrator-configured **local HTTPS reverse proxy** to the unchanged loopback planner. No cloud service/router port-forward is necessary. Example conditional procedure using an approved installed Caddy binary, a certificate/private key already provisioned for `routing-demo.example.edu`, and LAN DNS resolving that name to the laptop's IPv4. Substitute the real authorized hostname/file paths. Certificate SAN must match the URL and chain must already be trusted by the actual Flutter/Android build; installing a user CA on Android does not automatically establish app trust. This certificate/DNS setup is not present or verified by this review. Avoid self-signed shortcuts or `tls internal` without reviewed app trust provisioning.

Example **local** `Caddyfile` outside Git, with no access log configured:

```caddyfile
{
    admin off
    auto_https off
}
https://routing-demo.example.edu:8789 {
    tls C:/GeoLockTLS/fullchain.pem C:/GeoLockTLS/private-key.pem
    reverse_proxy 127.0.0.1:8787
}
```

Only a local trusted upstream hop uses HTTP. The NGO Authorization header is preserved; no worker credential is sent to clients. Keep private key access limited to the proxy operator. Do not log JWTs/request bodies or add automatic POST retries. See official [proxy](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy) and [certificate](https://caddyserver.com/docs/caddyfile/directives/tls) documentation. This is an optional new network arrangement, **not tested here** and not a requirement to install software for USB use.

```powershell
# Conditional future operator commands, after cert/DNS/proxy approval:
& 'C:\Tools\Caddy\caddy.exe' validate --config 'C:\GeoLockTLS\Caddyfile' --adapter caddyfile
& 'C:\Tools\Caddy\caddy.exe' run --config 'C:\GeoLockTLS\Caddyfile' --adapter caddyfile
# Separate elevated terminal, trusted Private LAN only (substitute exact client IP):
New-NetFirewallRule -DisplayName 'GeoLock local HTTPS demo' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8789 -Profile Private -RemoteAddress 192.168.1.60
# From another trusted laptop; do not bypass certificate checking:
Invoke-RestMethod 'https://routing-demo.example.edu:8789/health' -TimeoutSec 5
# Flutter app directory, LAN build:
flutter build apk --debug --dart-define=GEOLOCK_SUPABASE_ENV=dev --dart-define=GEOLOCK_ROUTING_API_URL=https://routing-demo.example.edu:8789
```

Do not open 8787/8788 to the LAN, disable the firewall or expose ports to the internet. If the phone changes IP, update the narrow rule deliberately. An HTTPS URL is also required for release APKs; loopback HTTP is **debug-only**. A publicly trusted certificate can be used entirely on a private LAN; obtaining/provisioning it is an operator prerequisite, not permission here to register a domain or incur cost.

## 9. Stop and recover safely

Wait for an active request to finish, then Ctrl+C in the **planner** terminal and **validator** terminal. Stop the optional proxy with Ctrl+C. Do not use `taskkill /IM python.exe` or stop unrelated Python processes. The native worker clears its in-memory password buffers on orderly exit; hard termination may skip cleanup.

```powershell
# Remove only this phone mapping when no longer needed:
& $adb -s $device reverse --remove tcp:8787
& $adb -s $device reverse --remove tcp:8788
# Optional LAN rule cleanup, elevated terminal, only if created by this guide:
Remove-NetFirewallRule -DisplayName 'GeoLock local HTTPS demo'
```

Keep `$env:LOCALAPPDATA\GeoLockHubRoutingDev\state\journal` intact, including SQLite WAL/SHM and locks. Never delete a journal, switch to an empty directory or generate a new UUID to resolve an unknown outcome. Restart the same approved host/state, then resume the saved operation using the original IDs and protected receipt checks. A terminal exit is not proof a DB transaction rolled back. If state is lost/stale, stop and have the operator reconcile receipts; do not make up a recovery result.

No live backup is performed by these instructions. For a separately approved backup, quiesce and stop workers first, use an operator-approved SQLite-consistent backup procedure (not an arbitrary copy of only the `.sqlite3` file while live), protect the payloads/ACLs and verify restoration in isolation. DPAPI profiles require independent secure reprovisioning on another Windows account. Do not distribute operational journals with the project.

## 10. Troubleshooting and remaining requirements

- `NATIVE_POSTGRESQL17_LIBRARY_REQUIRED` / version mismatch: exact client installation missing; do not disable the pin.
- `APPROVED_CA_MISSING` / profile mismatch: check the exact historical path/host; do not alter the hash casually.
- Encrypted profile missing: administrator-approved local configuration is required; copying someone else's file is not a fix.
- `DISABLED`: expected during offline inspection; live activation is a separate approval.
- Phone connection failure: verify installed URL/debug build, online ADB device and reverse mapping; ACTIVE on the laptop alone does not prove phone reachability.
- Auth/DB/eligibility failure: keep original IDs and collect safe fixed diagnostics. Current grants, policies, graph and real work remain unverified here.
- Cold graph or insufficient RAM: wait/warm only under approved procedure, reduce demo scope through legitimate UI/data selection; never change road weights, solver semantics or freshness checks.

Cloud hosting is postponed/not selected. Render code, Docker definitions and experiment evidence remain reference material and are not imported or required by the Windows entrypoints. The only shared production change from that investigation was the previously tested bounded Windows SQLite initialization retry; it is retained because reverting it would restore a reproducible local crash-recovery defect. No PostgreSQL journal redesign exists.

## Validator identity for the local routing consolidation

The seven-folder source layout is pending separate DEV compatibility and cutover approval.
The validator hashes the raw bytes of the three inputs below in order. The prefix for
both identities is `geolock-independent-validator:`. These values describe the
migration checkout, whose Windows line endings are part of the fingerprint.

| Before | After | SHA-256 before | SHA-256 after |
| --- | --- | --- | --- |
| `contract.py` | `contract.py` | `47ed1d97ba249ac50f3462babeb932f4d91c863899ea4297ddcb1a3ce4efa3fb` | `47ed1d97ba249ac50f3462babeb932f4d91c863899ea4297ddcb1a3ce4efa3fb` |
| `phase_b/validation.py` | `validator/validation.py` | `3788a5aee2d5758b26bc04c7299215ff5bae6810f95b0264f8ddfa3c4f59a37d` | `ee1a0633f36be4be198790fdf9eeb257c5c61e890ac66c92fd78d623e862296a` |
| `integration/worker.py` | `integration/worker.py` | `2daec4009ae5acbddf8b919486f3e2c9e2e1de40141cb07d693a9ceaa7cc1a71` | `c80443f80a34b407d63ec37c0b66cc74d337884db314e92fda6774e10eabe20b` |

The build digest changed from `56b2745bcd81b3d2a2ca90f1f57460262870bbb86d12b553d4eb88dbadc663d6`
to `4184dbbe2dc85f77bb142406ffe8527e45c97ce8642e0571ebc89c66c0d7919f`
because the validator source moved and the validator and integration imports changed.
This record describes the local checkout.

The reviewed SQL compares the entire attestation report on replay, including build
identity. Before switching or rolling back either release, verify the deployed
contract and reconcile unfinished requests that could replay an attestation. Preserve
the planner journal, client request IDs and existing database attestations.
