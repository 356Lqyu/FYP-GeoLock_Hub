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
& .\.venv-stage8\Scripts\python.exe -m pip install -r .\backend\routing\worker_service\requirements.txt
& .\.venv-stage8\Scripts\python.exe -m pip check
```

On other laptops change only `Set-Location` to that person's checkout. Dependencies are pinned by `worker_service/requirements.txt` and `phase_b/requirements-lock.txt`, including OR-Tools 9.15.6755 and psycopg 3.3.6. Do not regenerate pins or upgrade the solver to fix an installation error. Installing packages uses the configured package index but does not access DEV. A venv activation command is unnecessary because every command uses its explicit Python path.

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
.\backend\routing\worker_service\windows\Test-LocalRoutingSetup.ps1
& .\.venv-stage8\Scripts\python.exe -B -m unittest discover -s backend/routing/worker_service/tests -t . -q
& .\.venv-stage8\Scripts\python.exe -B -m unittest backend.routing.hosted.tests.test_journal_initialization -q
```

The setup check clears activation/database variables **in its child processes**, imports no encrypted profiles and starts isolated disabled APIs on temporary ports. It GETs only `/health` and stops its own children. Existing services on 8787/8788 are left alone. Expected result: `PASS`, native client `NOT CONNECTED`, both health results `DISABLED`. The last test module is retained under `hosted/tests` because it tests the shared SQLite fix; importing that test does not require Docker or enable hosted runtime.

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
.\backend\routing\worker_service\windows\Save-WorkerConfig.ps1
```

Answer **Y** for session pooler, use the exact host from the pinned profile, enter the exact CA path above, then use the masked prompts for authorized credentials and DEV publishable key. Existing graph UUID: `eab1f7ee-a8e0-4bed-a0e1-2c4bff024936` (historically approved; current availability is not freshly verified here). Never initialize/refreeze graphs or replay migrations to set up another laptop. The wizard refuses to overwrite existing profiles. Do not delete them to get past that protection. Profiles/state are outside Git under `$env:LOCALAPPDATA\GeoLockHubRoutingDev`.

No activation or DB call occurs during saving. The saved passwords exist for historical configuration compatibility; the native startup still asks for hidden native-console passwords once per process before serving requests. Do not put passwords in command arguments, transcripts, environment dumps or Flutter defines.

## 6. Start an approved live demonstration

**Instructions only. Requires separate approval to access DEV/run routing.** Check for an already running pair before starting duplicates:

```powershell
Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
    Where-Object { $_.LocalPort -in 8787,8788 } |
    Select-Object LocalAddress,LocalPort,OwningProcess
```

If occupied, identify the owning session; do not kill/restart another person's workers. In **terminal 1**, repository root:

```powershell
$approval = Read-Host 'Current approved DEV demonstration/session reference'
.\backend\routing\worker_service\windows\Start-Worker.ps1 -Mode validator -Activate -ApprovalRef $approval
```

In **terminal 2**, same root:

```powershell
$approval = Read-Host 'Current approved DEV demonstration/session reference'
.\backend\routing\worker_service\windows\Start-Worker.ps1 -Mode planner -GraphId 'eab1f7ee-a8e0-4bed-a0e1-2c4bff024936' -Activate -ApprovalRef $approval -EnableCombinedWorkflow
```

Enter each role's password only in its hidden prompt. Combined workflow is needed for the normal Flutter Generate & Authorize action. Add `-EnableExactWorkflow` **only** if the separately scoped exact-pilot path is approved and needed; it is not required for normal generation. Historical approval strings are not automatically current approval. Both commands remain foreground processes; closing terminals or sleep/logoff interrupts access.

In **terminal 3**, check HTTP only:

```powershell
Invoke-RestMethod 'http://127.0.0.1:8788/health' -TimeoutSec 5
Invoke-RestMethod 'http://127.0.0.1:8787/health' -TimeoutSec 5
```

Expect `ACTIVE` and project `rcgyuwiidqvrgbxswhqj`. Do not use POST `/v1/plan`, `/v1/validate` or authorization as a health check. If separately approved, the following make **real read-only DEV connections** and exit without a listener; **not run in this review**:

```powershell
.\backend\routing\worker_service\windows\Start-Worker.ps1 -Mode validator -CheckConnection
.\backend\routing\worker_service\windows\Start-Worker.ps1 -Mode planner -CheckConnection
```

Never combine `-CheckConnection` with `-Activate`. First full-graph load can be slow and memory-heavy on the original representation; have several GiB of free RAM, do not apply Render's 512 MB assumptions, and do not create demonstration snapshots while cold-loading. The optional existing `Prepare-WorkerCache.ps1` copies a sealed historical graph **only after evidence verification**, but still does not prove today's DB manifest, preload the in-memory graph or authorize transferring graph data to another person. Obtain explicit graph-export sharing/preparation approval first; do not copy live journals or caches as a shortcut.

## 7. Android connection: recommended USB development path

Use a **debug** APK and a USB data cable, enable Android Developer options/USB debugging, and authorize that laptop. Commands below change only the local device tunnel/build when an operator runs them; none were executed here. Install Android platform-tools through the approved SDK setup.

```powershell
$adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
& $adb devices -l
$device = Read-Host 'Online authorized device serial from the list'
& $adb -s $device get-state
# Continue only if the state is device (not offline/unauthorized):
& $adb -s $device reverse tcp:8787 tcp:8787
& $adb -s $device reverse --list
```

This maps the phone's `127.0.0.1:8787` to that USB laptop's planner. No LAN firewall opening or TLS exception is needed: cleartext is permitted only for the existing debug loopback/emulator allowlist. Port 8788 is never forwarded to the phone. Recheck the mapping after reconnect/reboot. A phone attached to the supervisor's laptop reaches **that laptop**, not the owner's laptop.

From the Flutter app directory:

```powershell
Set-Location .\frontend\geolock_hub_app
flutter pub get
flutter build apk --debug --dart-define=GEOLOCK_SUPABASE_ENV=dev --dart-define=GEOLOCK_ROUTING_API_URL=http://127.0.0.1:8787
& $adb -s $device install -r .\build\app\outputs\flutter-apk\app-debug.apk
```

The tracked DEV Flutter configuration already selects its matching publishable key. Do not pass worker passwords/tokens to the build. URL is compile-time configuration: changing PowerShell variables later does not update an installed APK. Preserve app storage/pending request IDs when reinstalling; do not uninstall to clear an uncertain operation. In-app read-only connection check must reach ACTIVE on the configured endpoint before generating; generation still needs separate approval.

## 8. Android emulator on backend laptop

Use the standard Android emulator host alias, not the emulator's own localhost:

```powershell
# From frontend/geolock_hub_app; select emulator when prompted:
flutter run --debug --dart-define=GEOLOCK_SUPABASE_ENV=dev --dart-define=GEOLOCK_ROUTING_API_URL=http://10.0.2.2:8787
```

No reverse tunnel normally needed. A physical phone cannot use `10.0.2.2` to locate your laptop. For an emulator on **another** laptop, use the LAN HTTPS arrangement below (or run its own approved backend); that emulator's host alias points to the wrong machine.

## 9. Another device on the LAN: optional HTTPS setup

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

## 10. Stop and recover safely

Wait for an active request to finish, then Ctrl+C in the **planner** terminal and **validator** terminal. Stop the optional proxy with Ctrl+C. Do not use `taskkill /IM python.exe` or stop unrelated Python processes. The native worker clears its in-memory password buffers on orderly exit; hard termination may skip cleanup.

```powershell
# Remove only this phone mapping when no longer needed:
& $adb -s $device reverse --remove tcp:8787
# Optional LAN rule cleanup, elevated terminal, only if created by this guide:
Remove-NetFirewallRule -DisplayName 'GeoLock local HTTPS demo'
```

Keep `$env:LOCALAPPDATA\GeoLockHubRoutingDev\state\journal` intact, including SQLite WAL/SHM and locks. Never delete a journal, switch to an empty directory or generate a new UUID to resolve an unknown outcome. Restart the same approved host/state, then resume the saved operation using the original IDs and protected receipt checks. A terminal exit is not proof a DB transaction rolled back. If state is lost/stale, stop and have the operator reconcile receipts; do not make up a recovery result.

No live backup is performed by these instructions. For a separately approved backup, quiesce and stop workers first, use an operator-approved SQLite-consistent backup procedure (not an arbitrary copy of only the `.sqlite3` file while live), protect the payloads/ACLs and verify restoration in isolation. DPAPI profiles require independent secure reprovisioning on another Windows account. Do not distribute operational journals with the project.

## 11. Troubleshooting and remaining requirements

- `NATIVE_POSTGRESQL17_LIBRARY_REQUIRED` / version mismatch: exact client installation missing; do not disable the pin.
- `APPROVED_CA_MISSING` / profile mismatch: check the exact historical path/host; do not alter the hash casually.
- Encrypted profile missing: administrator-approved local configuration is required; copying someone else's file is not a fix.
- `DISABLED`: expected during offline inspection; live activation is a separate approval.
- Phone connection failure: verify installed URL/debug build, online ADB device and reverse mapping; ACTIVE on the laptop alone does not prove phone reachability.
- Auth/DB/eligibility failure: keep original IDs and collect safe fixed diagnostics. Current grants, policies, graph and real work remain unverified here.
- Cold graph or insufficient RAM: wait/warm only under approved procedure, reduce demo scope through legitimate UI/data selection; never change road weights, solver semantics or freshness checks.

Cloud hosting is postponed/not selected. Render code, Docker definitions and experiment evidence remain reference material and are not imported or required by the Windows entrypoints. The only shared production change from that investigation was the previously tested bounded Windows SQLite initialization retry; it is retained because reverting it would restore a reproducible local crash-recovery defect. No PostgreSQL journal redesign exists.
