# Stage C.5 environment-only smoke — prepared for manual review

Prepared 26 October 2026 (Asia/Kuala_Lumpur). **NON-PARITY. NOT EXECUTED.**

This procedure is for a normal user-opened, non-elevated Windows terminal, after the user reviews these files. It does not authorize Codex to launch the runner. It cannot continue into Stage A/B migrations, historical schema assembly, C.5 compatibility scenarios or an upgrade package.

## Files to review

- Runner: `supabase/tests/stage8_environment_smoke.py`.
- Runtime snapshot/pins: `docs/stage8/stage-c5/environment-smoke-runtime-manifest.json`.
- Background: `docs/stage8/stage-c5/ENVIRONMENT_RECOVERY.md`.

The runner uses Python's standard library only. It does not import the original C.5 harness, application code, a database driver or any other GeoLock test module. No DSN, host, SQL, migration, test selector, service name, existing data directory or arbitrary runtime path can be supplied on the command line. Its only database actions are fixed owned-instance identity/version queries and, with a separate flag, local PostGIS/pgRouting extension loading/version inspection.

The old `stage8_stage_c5_isolated_test.py` and `results/stage-c5/nonparity-attempt-01/` remain untouched. Do not run the original harness for this smoke test.

## What the runner enforces

1. **Actual Windows identity:** queries its process token/SID, elevation, integrity and restricting SIDs via read-only Windows APIs. Requires the expected `LAPTOP-SIR1D3LB\User` principal, a non-elevated, unrestricted Medium-integrity token, and rejects CodexSandbox identities. USERNAME environment text is recorded but does not establish identity. The required identity is not automatically learned from the current token.
2. **Pinned private binaries:** checks its own source hash and all **3,184 files** in the retained runtime, including DLLs, configuration templates and extension SQL. Both missing/changed and extra files block execution. Manifest pins describe the local retained snapshot; they do not independently authenticate the vendor distribution or establish DEV parity.
3. **Fresh ownership:** generates a new `results/stage-c5/environment-smoke-<UTC timestamp>-<random>/` directory, verifies its owner SID is the actual user, and gives initdb a nonexistent `data` child. It rejects links/reparse points in checked paths, existing data, changed ownership and unexpected pre-start PID files. It never reuses attempt 01.
4. **PostgreSQL protection retained:** refuses an inherited PG_RESTRICT_EXEC override and never sets one. No direct-server fallback, token/privilege adjustment, ACL repair, service installation or automatic retry exists.
5. **Immediate error stop:** captures stdout and stderr separately; classifies both regardless of exit code. Token creation/re-execution, launch, explicit ERROR/FATAL/PANIC and nonzero exit block continuation. In particular, initdb errors with exit 0 stop **before configuration writes or pg_ctl start**. A later success message cannot turn the result into PASS.
6. **Only an owned loopback endpoint:** creates a unique cluster marker, listens on 127.0.0.1/random port and caps max_connections at 10. Before any SQL it checks the fresh PID file, data directory, port/address, actual process image and creation time. A held Windows process handle guards against PID reuse. Every SQL input begins with an ownership guard. Connections specify loopback/port/user/database; connection/service/password environment settings are scrubbed, no password prompt or psql startup file is used.
7. **Runtime identity:** requires PostgreSQL 17.11, postgres session/current user, READ COMMITTED, the exact data directory/marker/endpoint and configured connection cap. Recorded binary metadata alone does not satisfy this check.
8. **Optional extension probe:** only with `--probe-extensions`, and only after successful server identity checks. Creates an empty `extensions` namespace plus the real PostGIS and pgRouting extensions in the fresh disposable database. These are extension dependencies, not GeoLock schema assembly. Records full build/version output and requires PostGIS 3.6.2 / pgRouting 4.0.1 in that namespace. A mismatch blocks; no substitution or installation is attempted. No application tables or data are created.
9. **Bounded lifecycle:** five-minute work budget, 90-second initdb bound, 25-second startup/shutdown wait bounds and bounded SQL calls. Cleanup gets its own bounded allowance, up to approximately 40 additional seconds. It stops only its verified owned cluster, checks the held process handle has exited and requires PID-file removal. It never kills arbitrary processes, operates services or deletes evidence.
10. **Terminal stop:** returns after environment checks and cleanup. There is no migration/compatibility continuation branch. A successful smoke test does not complete Stage C.5 or approve DEV deployment.

Loopback uses local trust authentication, as in the approved disposable plan. Other processes on this Windows machine could reach that short-lived local instance; it is not a production access model. Keep the normal terminal open until the runner finishes so its cleanup can run. Do not run concurrent smoke attempts.

## Exact manual PowerShell commands — only after your review

Open Windows PowerShell or Windows Terminal yourself from Start/the desktop. **Do not choose Run as administrator. Do not launch it as a child of a Codex tool command.** No activation, execution-policy change, software install or administrator command is needed.

First inspect the token identity and the prepared files. These commands do not start PostgreSQL:

```powershell
Set-Location -LiteralPath 'C:\Users\User\Downloads\FYP-GeoLock_Hub'

whoami /user
whoami /groups
whoami /priv

$smokeWindowsIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$smokeWindowsPrincipal = [Security.Principal.WindowsPrincipal]::new($smokeWindowsIdentity)
if ($smokeWindowsIdentity.Name -ine 'LAPTOP-SIR1D3LB\User') {
    throw 'Unexpected actual Windows identity. Stop; do not change permissions or substitute an expected identity.'
}
if ($smokeWindowsPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'This terminal is elevated. Stop and open a normal non-elevated terminal.'
}

$smokeRunner = 'C:\Users\User\Downloads\FYP-GeoLock_Hub\supabase\tests\stage8_environment_smoke.py'
$smokeManifest = 'C:\Users\User\Downloads\FYP-GeoLock_Hub\docs\stage8\stage-c5\environment-smoke-runtime-manifest.json'
$smokePython = 'C:\Users\User\Downloads\FYP-GeoLock_Hub\.venv-stage8\Scripts\python.exe'

if ((Get-FileHash -LiteralPath $smokeRunner -Algorithm SHA256).Hash -ine '43206BEDE0ED61D944C5B2871AA5C2AA7DDF50798601CB1338B8D44B09AD44BB') {
    throw 'Prepared runner hash mismatch. Stop for review.'
}
if ((Get-FileHash -LiteralPath $smokeManifest -Algorithm SHA256).Hash -ine 'D4A7590429656BD44BCE22B2AD82C0160E92B0074C766DCEA10A1732E0F494D8') {
    throw 'Prepared runtime manifest hash mismatch. Stop for review.'
}
if (-not (Test-Path -LiteralPath $smokePython -PathType Leaf)) {
    throw 'Existing Python environment is unavailable. Stop; do not install or change it.'
}
```

Then, when you decide to execute the reviewed smoke procedure, invoke **one** smoke attempt using the variables above:

```powershell
$smokeArguments = @(
    '-B', $smokeRunner,
    '--normal-user-terminal',
    '--confirm-environment-only',
    '--expected-user', 'LAPTOP-SIR1D3LB\User',
    '--probe-extensions'
)

& $smokePython @smokeArguments
$smokeExitCode = $LASTEXITCODE
Write-Output "Environment-only smoke exit code: $smokeExitCode"
```

The explicit `--probe-extensions` above scopes extension creation/loading to the owned disposable local database. If you choose **startup/identity/shutdown only**, remove that one array entry before your single attempt. The result will say `NOT_REQUESTED` for extensions and cannot establish their runtime versions. Do not run both variants automatically or retry on failure.

The runner prints the exact new evidence-directory path before invoking PostgreSQL. Retained runtime hash verification may take a little time before that message. If preflight fails earlier, the diagnostic is printed to the terminal and no database utility runs; an evidence directory may not yet exist. If the normal-user check rejects your identity, stop and report it rather than overriding the safeguard.

## Expected evidence and interpretation

Within the new `environment-smoke-*` directory:

| Artifact | Purpose |
|---|---|
| preflight.json | Actual Windows account/SID/token state, Python/OS, pinned runtime, marker, evidence owner and explicit extension choice |
| runtime-manifest.json | Copy of the reviewed runner/distribution pins |
| processes.json and numbered stdout/stderr logs | Exact utility arguments, phase, exit code, duration, timeouts/exceptions and raw diagnostics |
| data/ and server.log | Fresh initialized cluster/configuration and server diagnostics; retained, never reused |
| identity.sql / identity.json | Fixed ownership/version query and actual verified endpoint/session/server configuration |
| extension-load.sql / extension-versions.sql / extensions.json | Only if explicitly requested and reached: extension-only DDL and actual runtime/build evidence |
| failure.json | First error/phase, if any |
| cleanup.json | NOT_STARTED, STOPPED_CONFIRMED or UNCERTAIN; shutdown evidence is separate from successful startup |
| results.json | NON-PARITY outcome, identity/extension/cleanup status, zero migrations/scenarios/remote connections |
| evidence-index.json | Hashes of top-level evidence files; data/ contents are retained but not recursively indexed |

Exit **0** means the requested environment-only checks completed and shutdown was confirmed. Require `ENVIRONMENT_SMOKE_PASS`, `identity_verified=true`, `STOPPED_CONFIRMED`, and, if requested, `extension_probe=VERIFIED`. It is still NON-PARITY.

Exit **1** means BLOCKED. Read the first error and cleanup record; do not infer a migration incompatibility. A nonzero/error-diagnostic startup might leave process state uncertain; the runner only attempts cleanup when it can establish that the process is its own. If cleanup is UNCERTAIN, **do not retry, delete the data directory, kill all postgres processes, or operate a service**. Preserve evidence and request a bounded review of that specific instance. Missing postmaster.pid alone is not treated as proof of shutdown after an ambiguous start.

If initdb repeats the attempt 01 errors but exits 0, expect ENVIRONMENT_BLOCKED, `startup_attempted=false`, cleanup NOT_STARTED, no pg_ctl/psql invocation, and no identity/extension results. The initialized directory, if any, is retained and cannot be reused.

Only fixed version/identity operations and optional extension operations are permitted. Stop after the outcome. Do not invoke the C.5 harness, Stage A/B migration files, workers or any Supabase connection.

## Preparation validation and outstanding limits

During preparation only, the new source was parsed for Python syntax. Six isolated classifier checks exercised the diagnostic predicate alone: initdb error-87 on stderr with exit 0 plus success text; initdb re-execution error-3 on stdout with exit 0 plus success text; nonzero exit without text; clean success; pg_ctl server-start error; and FATAL output. All classified as expected. The runner module, Windows token/process APIs and startup/SQL/cleanup paths were **not executed**. No PostgreSQL utility, smoke test, Stage C.5 compatibility test or database operation ran.

This runner is prepared for manual review; its Windows ctypes integration, PostgreSQL lifecycle and extension loading remain runtime-unverified. Do not change expected hashes or weaken checks to obtain a pass. The existing C.5 broad fixture/assembly gaps and the blocked exact-version parity lane remain unresolved. A successful smoke result is evidence for a later separately approved C.5 continuation only; no upgrade package or deployment is prepared or approved here.
