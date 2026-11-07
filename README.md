# GeoLock Hub Team

GeoLock Hub is a Flutter Android app for donor and NGO workflows. The Windows Python planner builds routes using the frozen directed road graph, FCFS, nearest neighbour, distance-only optimization and the proposed CP-SAT method. A separate validator verifies the proposed route before Supabase authorizes it. The planner records recoverable work in a local SQLite journal.

## Windows setup and offline validation

Install Flutter with Android SDK tooling and the Android Studio JDK, Python 3.12 x64, and the approved PostgreSQL 17.11 native client. The current launcher expects the native DLL under the PostgreSQL 17 installation in Program Files. Use an approved SDK installation and run `flutter doctor -v` to check Android tooling.

From this folder:

```powershell
py -3.12 -m venv .venv-stage8
.\.venv-stage8\Scripts\python.exe -m pip install -r backend/routing/worker_service/requirements.txt
.\.venv-stage8\Scripts\python.exe -m pip check
.\backend\routing\worker_service\windows\Test-LocalRoutingSetup.ps1
```

The setup checker runs the planner and validator in DISABLED mode on temporary loopback ports and checks their health. Without the administrator's pinned profile and CA, the profile check fails and the overall exit code is nonzero. The individual DISABLED health results can still pass. Do not use `-CheckConnection` during offline setup, since it connects to DEV.

## Android emulator, USB phone and APK

From `frontend/geolock_hub_app`:

```powershell
flutter pub get
flutter run --debug --dart-define=GEOLOCK_SUPABASE_ENV=dev --dart-define=GEOLOCK_ROUTING_API_URL=http://10.0.2.2:8787
flutter build apk --debug --dart-define=GEOLOCK_SUPABASE_ENV=dev --dart-define=GEOLOCK_ROUTING_API_URL=http://10.0.2.2:8787
```

The emulator uses `10.0.2.2` to reach the host. For a physical phone, authorize USB debugging on the chosen backend laptop and use `adb reverse tcp:8787 tcp:8787`. Build or run with `GEOLOCK_ROUTING_API_URL=http://127.0.0.1:8787` for that phone. Keep the validator on loopback. Debug HTTP is limited to the existing emulator and loopback allowlist. A LAN setup needs separately configured trusted HTTPS.

The debug APK is generated under `build/app/outputs/flutter-apk/`. Maps rendering requires an approved Android Maps key in local `android/local.properties` as `google.maps.apiKey`. Use a key restricted to the approved Android app and signing identity. Keep local properties and signing material outside Git.

## Separately approved DEV setup and live routing

The Flutter client uses the existing DEV project and its publishable client configuration. Each app user signs in with their own authorized account. A backend operator needs administrator-provisioned credentials for the separate graph, planner and validator logins, and an approved frozen graph and policy. A fresh Supabase project needs separately provisioned schema, RPCs, grants, graph and operational data.

Follow [Windows operator configuration](docs/WINDOWS_OPERATOR_CONFIGURATION.md) before proceeding. The supplied configuration example is a checklist. The current launcher only accepts the administrator's exact byte-pinned profile and matching CA path. Obtain those separately through the approved channel.

Once the administrator has provisioned access and approved the session, run the wizard from the root:

```powershell
.\backend\routing\worker_service\windows\Save-WorkerConfig.ps1
```

Start the validator in the first terminal:

```powershell
$approval = Read-Host 'Current approved DEV session reference'
.\backend\routing\worker_service\windows\Start-Worker.ps1 -Mode validator -Activate -ApprovalRef $approval
```

Start the planner in a second terminal:

```powershell
$approval = Read-Host 'Current approved DEV session reference'
$graph = Read-Host 'Administrator-approved frozen graph UUID'
.\backend\routing\worker_service\windows\Start-Worker.ps1 -Mode planner -GraphId $graph -Activate -ApprovalRef $approval -EnableCombinedWorkflow
```

Check both health endpoints:

```powershell
Invoke-RestMethod 'http://127.0.0.1:8788/health' -TimeoutSec 5
Invoke-RestMethod 'http://127.0.0.1:8787/health' -TimeoutSec 5
```

ACTIVE confirms the HTTP service is enabled. Database permissions, graph readiness and real route authorization require their own approved checks. Keep both terminals open and the laptop awake for the session. Wait for active work to finish, then use Ctrl+C in the planner terminal and the validator terminal. To remove the phone tunnel, run `adb reverse --remove tcp:8787`.

## Recovery

Flutter saves the original request UUID and the snapshot ID. The worker's SQLite journal preserves exact step payloads and lets a retry reconcile a committed receipt before continuing. After an uncertain outcome, resume the original operation on the same host with its journal intact. State lives under `%LOCALAPPDATA%\GeoLockHubRoutingDev\state`. Keep it protected and use a separately approved SQLite-consistent backup procedure. A different laptop has a different journal.

The exact source inventory is in [INCLUDED_FILES.txt](INCLUDED_FILES.txt).
