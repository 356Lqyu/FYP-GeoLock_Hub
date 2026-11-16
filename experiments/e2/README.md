# E2 — Safe claiming and lease recovery

E2 asks whether two NGOs can claim the same donation at once and whether another NGO can collect it after the first claim expires. The experiment runs real SQL against a dedicated test database.

| Method | What it does |
| --- | --- |
| Baseline 1 — Non-Atomic Claim | Checks availability, then saves the claim in a separate call. |
| Baseline 2 — Protected Claim without Lease Recovery | Checks and saves the claim as one protected database operation. Expired claims are left in place. |
| Proposed — Protected Claim with Lease Recovery | Uses the same protected claim and releases eligible expired claims so another NGO can take over. |

Each method uses the same 150 contention trials. Both protected methods also use the same 100 expired leases and 25 active leases. See the [experiment plan](EXPERIMENT_PLAN.md) for the workload and measures.

## Choose how to run E2

1. [Option A — Isolated Supabase (recommended)](#reproduce-the-hosted-paper-procedure-on-windows) uses a fresh disposable Supabase project. The published E2 run used this option.
2. [Option B — Isolated local PostgreSQL (alternative)](#local-postgresql-on-windows) uses a dedicated cluster on your computer.

Both modes use the same three methods, SQL rules, frozen workload, and comparison. You can set them up in either order. Start in PowerShell at the root of a complete GeoLock Hub checkout. Keep this folder, the repository's Git attributes, and the [frozen inputs](../../benchmark%20dataset/dataset/) together.

Enrollment and offline verification open no database connection. Preflight connects and uses read-only SQL. Local preflight with `-AllowStart` can start and stop the dedicated server. Target-marker provisioning, local setup, and recovery completion can change database state. A full run rebuilds E2 objects separately for all three methods.

## Important files

| Path | What to look for |
| --- | --- |
| [run.ps1](run.ps1), [run_e2.py](run_e2.py) | Entry point and driver for both modes |
| [scripts/](scripts/) | One-time local PostgreSQL setup and interrupted-setup recovery |
| [baseline/](baseline/), [protected_claim_with_lease_recovery/](protected_claim_with_lease_recovery/) | Method entry points |
| [database/](database/), [test_harness/](test_harness/) | SQL rules and guarded reset, target checks, workloads, and offline tests |
| [Shared benchmark](../../benchmark%20dataset/dataset/) | Fixed scenarios, starting claim states, and road distances |
| [experiment_result/](experiment_result/) | Comparator and saved runs |

## Prepare Python for either option

**1. Check Windows permissions.** Use Windows PowerShell or PowerShell 7 from the repository root. Your Windows account needs write access to the checkout for the virtual environment and results, and to your user-profile folders for the E2 configuration, hosted password file, or local cluster. Check which execution policy applies before running the scripts:

~~~powershell
Get-ExecutionPolicy -List
~~~

If PowerShell blocks a script, use a trusted checkout and ask your administrator how to run project scripts under your organization's policy. Keep the policy and security protections in place.

**2. Install Python 3.12 for Windows.** Include the Windows Python launcher and open a new PowerShell window at the repository root after installation. Run the following lines in order. Stop if the version is not 3.12.x or if any command fails. Installing dependencies may download packages. These commands do not access a database. [Python releases for Windows](https://www.python.org/downloads/windows/)

~~~powershell
py -3.12 --version
py -3.12 -m venv .venv-e2
$e2Python = '.\.venv-e2\Scripts\python.exe'
& $e2Python -m pip install -r experiments/e2/requirements.txt
& $e2Python -m pip check
~~~

Expect `No broken requirements found.` The packages are Psycopg (database access) and Matplotlib (figures). The runner uses `.venv-e2` automatically. To reuse another environment, install the E2 requirements there and pass its Python executable with `-Python` to `run.ps1`. In a new shell, set `$e2Python` again using the line above.

## Reproduce the hosted paper procedure on Windows

**Option A — recommended.** The published E2 run used Supabase PostgreSQL 17.11. This option needs a browser, network access, and a Supabase account. Psycopg connects from Python, so a local PostgreSQL installation is unnecessary.

**1. Create a fresh Supabase project for E2 only.** Use an account with permission to create a project, manage its database settings, and run SQL as the project’s `postgres` role. Use a disposable project with no application users, data, or integrations. Keep the database password in your password manager. Verify that the project uses PostgreSQL major version **17**. Stop if your disposable project is on another major version.

**2. Enable extensions and SSL.** In the project's database settings, confirm that `pgcrypto` is enabled and enable `postgis` in the `extensions` schema. Under **Database Settings → SSL Configuration**, enable SSL enforcement and download the CA certificate. Keep the CA file in a stable location on your computer. The runner uses it to check both the identity of the server and the connection encryption. [Supabase extensions](https://supabase.com/docs/guides/database/extensions) · [Supabase SSL settings](https://supabase.com/docs/guides/platform/ssl-enforcement)

**3. Find and enroll the same project.** In **Connect → Session pooler**, note the hostname and project reference. Use the shared Session Pooler on port `5432`. Supply the hostname alone. The runner sets the database to `postgres` and username to `postgres.<project-ref>`. Session mode keeps a database session attached across transactions. Check that the pool and project can provide up to **12 simultaneous sessions** during the busiest trial (10 request connections, one harness connection, and one reset-lock connection). [Supabase connection options](https://supabase.com/docs/guides/database/connecting-to-postgres) · [Session Pooler capacity](https://supabase.com/kb/troubleshooting/supavisor-and-connection-terminology-explained-9pr_ZO)

~~~powershell
$e2Python = '.\.venv-e2\Scripts\python.exe'
$projectRef = Read-Host 'E2-only project reference'
$poolerHost = Read-Host 'Session pooler hostname only'
$caFile = Read-Host 'Full path to the downloaded CA file, without quotes'
& $e2Python -B experiments/e2/run_e2.py --register-hosted $projectRef $poolerHost $caFile
~~~

Type the exact authorization phrase displayed. Enrollment makes no database connection. It reports `Wrote password-free enrollment` and prints SQL for a target marker. The enrollment is saved as `%LOCALAPPDATA%\GeoLockHub\E2\hosted.json`. An existing enrollment is refused rather than overwritten.

**4. Store the database password locally.** Open your per-user password file. The runner reads this file when connecting. Enter the password in the editor rather than in a shell command.

~~~powershell
$pgDir = Join-Path $env:APPDATA 'postgresql'
New-Item -ItemType Directory -Force -Path $pgDir | Out-Null
notepad (Join-Path $pgDir 'pgpass.conf')
~~~

Add one line using your own values in the following format. Place it above any matching wildcard entry. In the password, escape literal colons and backslashes with a backslash. Save as `pgpass.conf` and keep it outside Git.

~~~text
<pooler-host>:5432:postgres:postgres.<project-ref>:<database-password>
~~~

**5. Add the target marker.** This changes the database. In your E2-only project's **SQL Editor**, recheck the project reference, select the `postgres` role, and run the SQL printed during enrollment once. It creates the marker that binds the runner to that project.

**6. Check the target with a read-only preflight.** This connects with `verify-full` TLS and checks the PostgreSQL major version, exact project marker, extensions, managed Auth role and session behavior, reset inventory, and benchmark hashes. It does not create fixtures, rebuild the database, or write a result directory. Passing preflight does not exercise pool capacity at peak load or prove that every fixture insert, fixture delete, schema rebuild, and workload call will succeed.

~~~powershell
.\experiments\e2\run.ps1 -Hosted -PreflightOnly
~~~

Look for `Verified E2 target`, `Reset inventory`, and `Read-only preflight passed`. Compare the project reference to the disposable project in the dashboard. Require `marker_verified: true`, `tls: verify-full`, and an approved inventory with zero external dependencies. If preflight fails, check the Session Pooler hostname and port, CA path, password-file entry, and marker. Clear any target overrides reported by the runner, including a set `PGPASSWORD`. Stop if identity or inventory differs from what you expect.

**7. Run all three methods.** This rebuilds the selected experiment objects three times. Use it only after preflight passes for your own isolated project.

~~~powershell
$projectRef = Read-Host 'Enrolled E2-only Supabase project reference'
.\experiments\e2\run.ps1 -Hosted -ConfirmProject $projectRef
~~~

A completed run prints `E2 complete:` with the result folder and run ID. If execution fails after preflight, keep the terminal output. Partial files may remain in `.latest.pending/` until the next full run or offline recovery. For connection timeouts during contention, check Session Pooler capacity and logs. For fixture or reset errors, check the reported SQL error and the disposable project's Auth and object inventory. Keep the guards in place. Follow [Find and verify the results](#find-and-verify-the-results) to check the new run.

## Local PostgreSQL on Windows

**Option B — alternative.** Install Windows PostgreSQL **17** with its command-line tools and the PostGIS package built for that installation. The Windows installer includes Stack Builder, which can provide the matching PostGIS package. Installation may need administrative approval. Use your normal Windows account for E2, with permission to create the cluster under your user profile and bind an unused loopback port. The cluster is separate from any ordinary PostgreSQL service and uses local loopback trust, so run it on a trusted Windows machine. Complete the [Python setup](#prepare-python-for-either-option) first. [PostgreSQL Windows installers](https://www.postgresql.org/download/windows/)

Check the installation without starting a server. If you used a custom install path, replace the first line with a full path to its `bin` folder.

~~~powershell
$pgBin = Join-Path $env:ProgramFiles 'PostgreSQL\17\bin'
& (Join-Path $pgBin 'postgres.exe') --version
if ($LASTEXITCODE -ne 0) { throw 'Could not check PostgreSQL. Check the bin folder.' }
$shareDir = & (Join-Path $pgBin 'pg_config.exe') --sharedir
if ($LASTEXITCODE -ne 0) { throw 'Could not resolve the PostgreSQL share folder.' }
$shareDir = $shareDir.Trim()
Get-Item -ErrorAction Stop -LiteralPath @(
    (Join-Path $shareDir 'extension\postgis.control'),
    (Join-Path $shareDir 'extension\pgcrypto.control')
) | Select-Object -ExpandProperty Name
~~~

Expect a `17.x` server version and both extension file names. If either is missing, fix the matching PostgreSQL installation before setup. The control files show that the extensions are available to install. The setup script actually loads them.

**1. Create the dedicated cluster.** This creates database files and briefly starts the new server. Setup creates `geolock_e2` on IPv4 loopback port `55432` by default, prepares local Auth and the marker, and saves the separate `local.json`.

~~~powershell
.\experiments\e2\scripts\setup_local_e2.ps1
~~~

For a custom installation, enter the full path to its PostgreSQL 17 `bin` folder when prompted:

~~~powershell
$pgBin = Read-Host 'Full path to the PostgreSQL 17 bin folder'
.\experiments\e2\scripts\setup_local_e2.ps1 -PgBin $pgBin
~~~

Use one setup command. Expect the dedicated target and `local.json` path in the output. The config, logs, and cluster are under `%LOCALAPPDATA%\GeoLockHub\E2`. Setup normally stops the server it started. Treat any startup or shutdown warning as unresolved, even if the final message says `prepared and stopped`. Check the dedicated cluster status and log before continuing. For a custom installation, replace the first line below with an assignment to your actual PostgreSQL 17 `bin` directory.

~~~powershell
$pgBin = Join-Path $env:ProgramFiles 'PostgreSQL\17\bin'
$data = Join-Path $env:LOCALAPPDATA 'GeoLockHub\E2\cluster\data'
& (Join-Path $pgBin 'pg_ctl.exe') -D $data status
Get-Content -LiteralPath (Join-Path $env:LOCALAPPDATA 'GeoLockHub\E2\postgresql.log') -Tail 30
~~~

**2. Verify the target.** After fresh setup, allow the preflight to start the dedicated server and stop it afterward. Preflight SQL is read-only. Server startup itself can update PostgreSQL internal files. For a running E2 server, leave off `-AllowStart`.

~~~powershell
.\experiments\e2\run.ps1 -PreflightOnly -AllowStart
~~~

Check the displayed database `geolock_e2`, address `127.0.0.1`, configured port, data directory, and cluster system identifier against the setup record in `local.json`. Require a verified marker, an approved reset inventory with zero external dependencies, and `Read-only preflight passed`.

**3. Run all three methods.** This rebuilds the dedicated experiment database for each method. The runner starts the local server if needed and stops it if it started it. A dedicated server that was already running stays running. The final experiment tables and test rows remain on the dedicated target.

~~~powershell
.\experiments\e2\run.ps1
~~~

To run a standalone method, use one of the following commands. Each rebuilds E2, gets its own run ID, and replaces `results/standalone/` on success. Only the full run publishes to `results/latest/` and makes the three-method comparison.

~~~powershell
.\experiments\e2\run.ps1 -Method baseline1
.\experiments\e2\run.ps1 -Method baseline2
.\experiments\e2\run.ps1 -Method proposed
~~~

**4. Troubleshoot setup.** For a missing extension, install the package for the same PostgreSQL 17 installation. For an occupied port, check which service owns it. You can choose a different unused port during a **fresh** setup with `-Port`. Use the same port and binaries for recovery of an existing cluster. For startup or stop warnings, inspect the existing cluster status and `postgresql.log` before proceeding.

## Recover a configured cluster with a stale PID file

Use this section when `local.json` already exists and the runner reports a stale or unreadable `postmaster.pid`. Keep `local.json` and `hosted.json` in place. Close other E2 runs and avoid starting PostgreSQL manually while recovering the cluster.

**1. Inspect from the repository root.** Use the same Windows account that set up E2, in a PowerShell window that can read the Windows process, service and TCP listener inventories. If access is denied, use an elevated PowerShell window under that same account. This command reads local files and system metadata without starting or connecting to PostgreSQL.

~~~powershell
$localRoot = Join-Path $env:LOCALAPPDATA 'GeoLockHub\E2'
$e2Config = Get-Content -LiteralPath (Join-Path $localRoot 'local.json') -Raw | ConvertFrom-Json
$recoveryTarget = @{
    ExpectedSystemIdentifier = [string]$e2Config.cluster_system_identifier
    PgBin = $e2Config.pg_bin
    Port = [int]$e2Config.port
}
.\experiments\e2\scripts\recover_local_e2.ps1 -Action Inspect @recoveryTarget
~~~

**2. Quarantine only if inspection reports a verified stale PID candidate.** If the PID is still assigned, the port has a listener, or any check fails, stop and preserve the file. In the same PowerShell window, enter the PID reported by the successful inspection. The command below repeats the checks and renames the PID file in the same directory, printing its new path and SHA-256. It leaves PostgreSQL stopped.

~~~powershell
$stalePid = Read-Host 'Verified stale PID reported by Inspect'
$clusterId = $recoveryTarget.ExpectedSystemIdentifier
.\experiments\e2\scripts\recover_local_e2.ps1 -Action QuarantineStalePid @recoveryTarget -ConfirmStalePid "QUARANTINE STALE PID $stalePid FOR E2 CLUSTER $clusterId"
~~~

**3. Run normal preflight when ready to start PostgreSQL.** Startup may replay WAL and update cluster files after an unclean shutdown. Preflight checks the live target marker and reset inventory without rebuilding or running experiment methods.

~~~powershell
.\experiments\e2\run.ps1 -PreflightOnly -AllowStart
~~~

## Recover an interrupted E2 setup

Use this procedure when local setup created the dedicated cluster but did not write `local.json`. Recovery preserves the cluster. An existing regular `hosted.json` can stay in place.

**1. Inspect.** Use the same PostgreSQL binaries and port as setup. These commands show the on-disk cluster identifier. The recovery script checks identity, the PID record, and the cluster inventory.

~~~powershell
$data = Join-Path $env:LOCALAPPDATA 'GeoLockHub\E2\cluster\data'
$pgBin = Join-Path $env:ProgramFiles 'PostgreSQL\17\bin'
& (Join-Path $pgBin 'pg_controldata.exe') -D $data
$clusterId = Read-Host 'Database system identifier printed above'
.\experiments\e2\scripts\recover_local_e2.ps1 -Action Inspect -ExpectedSystemIdentifier $clusterId -PgBin $pgBin
~~~

If setup used another port, append `-Port` with that port to the recovery commands. If the desktop cannot read process or listener metadata, inspect from a shell with access to that metadata. Stop if identity or inventory disagrees.

**2. Follow the inspection result.** If inspection confirms a stale PID and reports its value, the following command renames that file after checking it again. It does not start a server. For a stopped cluster without a live PID, inspection may ask you to permit startup so it can query the inventory. Startup can update internal files. Recovery leaves the dedicated server running for the next step if it starts it.

~~~powershell
$stalePid = Read-Host 'Verified stale PID reported by Inspect'
.\experiments\e2\scripts\recover_local_e2.ps1 -Action QuarantineStalePid -ExpectedSystemIdentifier $clusterId -PgBin $pgBin -ConfirmStalePid "QUARANTINE STALE PID $stalePid FOR E2 CLUSTER $clusterId"
~~~

~~~powershell
.\experiments\e2\scripts\recover_local_e2.ps1 -Action Inspect -ExpectedSystemIdentifier $clusterId -PgBin $pgBin -ApprovePostgresStartForInspection
~~~

**3. Complete only a supported recoverable state.** This can create the missing database and setup objects or write the missing local config. If inspection found unexpected or partial objects it cannot handle, preserve the log and cluster for review.

~~~powershell
.\experiments\e2\scripts\recover_local_e2.ps1 -Action Complete -ExpectedSystemIdentifier $clusterId -PgBin $pgBin -ConfirmRecovery "COMPLETE E2 SETUP $clusterId"
.\experiments\e2\run.ps1 -PreflightOnly
~~~

If the runner reports a missing or invalid config, follow the [Supabase enrollment](#reproduce-the-hosted-paper-procedure-on-windows) or [local setup](#local-postgresql-on-windows) steps for your mode. If local setup was interrupted, preserve the existing files and use the recovery steps above.

## Result files

Open `experiments/e2/experiment_result/results/latest/comparison/summary.md` after a full run. Local and hosted runs publish to the same `latest/` folder. The root manifest records the mode and a new run ID, which also appears in each method manifest.

| File | What it tells you |
| --- | --- |
| `summary.md`, `metrics.json`, `comparison_summary.csv` | Ownership, lease, timing, and eligibility totals |
| `comparison_contention.csv`, `comparison_lease.csv`, `comparison_geofence.csv` | Matched cases behind the totals |
| `methods/<method>/` | Raw requests, scenario rows, and method manifest |
| `run_manifest.json` | Completion status, target, input hashes, and source hashes |
| `result_sha256.json` | Run ID and SHA-256 inventory of the published output files |

Start with duplicate ownership and expired-lease recovery. A conflict is the expected answer for a losing request. Figure 2 shows the median of trial medians. Pooled P95 answers a separate question about the slower end of all recorded requests.

For the research paper, use the [verified results in `latest/`](#find-and-verify-the-results) and record the run ID from its manifest.

The runner writes to a fixed staging directory and validates the evidence before publication. If execution or validation fails, the previous result remains active. During replacement, `latest/` may be briefly absent while the previous result is held in `.latest.previous/`. If interrupted in that window, run the following offline command from the repository root. It restores the previous result if necessary and clears pending output. Copy any partial diagnostics you want to inspect before recovery. The next full run also performs this recovery automatically. Review a recovery error before proceeding.

~~~powershell
& .\.venv-e2\Scripts\python.exe -B experiments/e2/run_e2.py --recover-results
~~~

Each output slot uses one pending directory and one temporary backup. Keep any paper exports you edit separately, since verification checks the exact published file inventory. Existing UUID-named runs are outside this replacement process.

## Find and verify the results

**1. Check the evidence for the latest run.** The verifier checks the complete output inventory, run ID, and frozen input hashes offline. The next commands show the root manifest and open the comparison summary. The runner checks the three method manifests, recorded source hashes, and workload coverage before publication.

~~~powershell
& .\.venv-e2\Scripts\python.exe -B experiments/e2/run_e2.py --verify-latest
if ($LASTEXITCODE -ne 0) { throw 'Latest E2 result did not pass verification.' }
$runDir = 'experiments/e2/experiment_result/results/latest'
Get-Content -Raw -LiteralPath (Join-Path $runDir 'run_manifest.json') | ConvertFrom-Json
Invoke-Item -LiteralPath (Join-Path $runDir 'comparison/summary.md')
~~~

Look for `summary.md`, `metrics.json`, the summary, contention, lease, and geofence CSVs, and four PNG figures. In `metrics.json`, each method should show 50 trials each at 2, 5, and 10 concurrent requests. The protected methods also log lease requests, so their raw `details/requests.csv` can have more than 850 rows. The proposed method's additional evidence sits in its `details/` and `geofence_check/` folders.

**2. Read the scientific verdict.** `E2 complete` means the driver saved the full run and generated the comparison. The `Assessment` in `summary.md` (also `verdict` in `metrics.json`) interprets the proposed method's recorded outcomes. `SUPPORTED` means the defined checks passed. `PARTIALLY SUPPORTED` means the core safety checks passed while at least one additional condition failed. `NOT SUPPORTED` means the core safety checks did not all pass. Review the actual counts, errors, and audit evidence even when the run completes. Keep the new run ID with its results.

**3. Run offline tests if you are checking an implementation change.** These exercise the runner with test data and mocked connections. They do not start PostgreSQL. The second command uses PowerShell 7 (`pwsh`).

~~~powershell
$e2Python = '.\.venv-e2\Scripts\python.exe'
& $e2Python -B -m unittest discover -s experiments/e2/test_harness
pwsh -NoProfile -File experiments/e2/test_harness/test_e2_process_safety.ps1
~~~
