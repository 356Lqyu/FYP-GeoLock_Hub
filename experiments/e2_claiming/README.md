# GeoLock Hub E2: isolated claim race and lease recovery

This runner is local-only. It creates a fresh PostgreSQL 17 cluster bound to `127.0.0.1`, builds the existing Stage B isolated full-schema test fixture, applies the remaining reviewed 20261104–20261108 Stage A routing migrations in order, applies the 20261109 recovery patch with its original preconditions intact, verifies the deployed DEV-captured claim/recovery function hashes, and clones two local databases. It contains no Supabase URL/DSN input and refuses databases other than its two names on its marked local cluster. No formal experiment has been run by this preparation. A failed SQL preflight now reports each expected and observed fingerprint, owner, `SECURITY DEFINER` flag, function configuration, database host/port/isolation/version, and lease value separately. Hash output includes both raw and CRLF-normalized MD5 plus body length, which distinguishes source drift from line-ending-only differences.

## Conditions and interpretation

- `geolock_e2_atomic` uses the repository's protected `public.claim_listing(uuid,uuid)`, existing ownership unique index, authorization, lease, audit, and recovery logic.
- `geolock_e2_nonatomic` uses the same cloned schema, but removes only `public.ux_active_claim` and exposes a test-only check-then-act RPC in `e2_baseline`. The RPC deliberately takes no listing lock and does not recheck availability before writing ownership. It uses the same claim, lease, task, request, listing, donation, and audit tables. It exists only in the local baseline database.
- Consequently the comparison intentionally changes a key protection. Baseline duplicate committed ownership is measured from final committed DB state. Removing that unique index is essential for measuring duplicate ownership commitments; it is documented and verified by setup. Other unique/FK/check constraints remain. Do not describe the baseline as schema-identical.
- Local road eligibility is the deterministic test double used by the existing Stage B harness. This tests claim concurrency and lease recovery, not road graph correctness.
- The synthetic staged photo follows `supabase/migrations/20261027_persisted_donation_lifecycle.sql`: `<donor UUID>/pending/<request UUID>/<image UUID>.jpg`, `image/jpeg`, a size from 1 to 5,242,880 bytes, and a `storage.objects` row in `geolock-donation-images` with matching `metadata.size` and `metadata.mimetype`. The runner uses 100 bytes. If staging or the donation RPC fails, it removes only that exact unreferenced staged object; cleanup failure is reported as an error.
- Each synthetic donation contains one item with positive quantity `1`, positive numeric unit weight `20` kg, a nonblank item name, and the active local category seeded by Stage B (`aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa`). This exceeds the isolated 10 kg direct-pickup threshold; the protected donation RPC creates the initial available direct listing.
- The isolated Stage B harness recreates `public`, so its schema ACL differs from Supabase's baseline. Setup grants only `USAGE ON SCHEMA public` to local `service_role` in each E2 database; the existing recovery function `EXECUTE` grant to `service_role` remains authoritative. Setup then checks the real scheduler session/current role, `auth.role()`, null `auth.uid()`, role membership, schema `USAGE`, and function `EXECUTE`. Recovery runs as a system actor with no user subject, matching the transition-audit contract. No grant is made to `PUBLIC`, `anon`, or `authenticated` for recovery.
- Lease expiry is simulated by backdating timestamps on new local claims while preserving the configured 360-minute expiry interval, then invoking the real recovery RPC under the synthetic `service_role` identity.
- Fixtures use synthetic actors, synthetic listing content, and a local storage catalog double. They do not use real NGO identities, Auth tokens, hosted Supabase, PostGIS, or production data.
- Each trial gets a newly created donation/listing and independent request UUID per worker. The barrier is a real `threading.Barrier`; each worker has a separate PostgreSQL connection. Database isolation is READ COMMITTED.
- Selected Balanced FYP formal configuration: exactly 20 trials at each 2/5/10-worker level for each claiming condition (60 non-atomic + 60 protected) and exactly 30 lease-recovery trials, for 150 total. These counts are supplied with `--trials-per-level 20` and `--trials 30`. Incomplete/timeout outcomes are retained. Do not pool requests as independent statistical units.
- The runner creates independent condition fixtures, so the report does not calculate a paired test. Pairing trial numbers without matched fixtures would be invalid.

## Prerequisites and setup (Windows PowerShell)

Run in the repository root. PostgreSQL 17 server binaries must be installed at the default path or supplied with `--pg-bin`; Python environment `.venv-dev-fixtures` must have `psycopg` installed. The local Windows host must allow PostgreSQL `initdb` and `pg_ctl` to start a server process. Setup fails closed and removes only the new runtime it created if that cannot be done.

```powershell
$ErrorActionPreference = 'Stop'
$Repo = (Get-Location).Path
$Python = Join-Path $Repo '.venv-dev-fixtures\Scripts\python.exe'
$PgBin = 'C:\Program Files\PostgreSQL\17\bin'
& $Python -c "import psycopg; print('psycopg', psycopg.__version__)"
Get-Item (Join-Path $PgBin 'initdb.exe'), (Join-Path $PgBin 'pg_ctl.exe'), (Join-Path $PgBin 'psql.exe')
Get-NetTCPConnection -State Listen -LocalPort 5432 -ErrorAction SilentlyContinue
$RunId = 'e2-20261102-review1'
$Runtime = Join-Path $env:TEMP "GeoLockE2-$RunId"
if (Test-Path -LiteralPath $Runtime) { throw "Runtime already exists; choose a new RunId. Nothing was reset." }
& $Python (Join-Path $Repo 'experiments\e2_claiming\e2_runner.py') setup --root $Runtime --run-id $RunId --pg-bin $PgBin
if ($LASTEXITCODE -ne 0) { throw 'Isolated setup failed; inspect the safe error message before continuing.' }
```

Setup performs schema loading and fixture bootstrap inside the new cluster; the created databases are named `geolock_e2_atomic` and `geolock_e2_nonatomic`. It prints the loopback port and observed source hashes. If setup cannot start PostgreSQL, stop: do not substitute a hosted Supabase project. On setup failure, cleanup verifies a per-invocation marker and token and checks server status; it removes only that newly created runtime when server shutdown is confirmed. If status is uncertain or shutdown fails, it retains the marked directory for manual inspection rather than deleting it.

## Smoke tests

```powershell
& $Python (Join-Path $Repo 'experiments\e2_claiming\e2_runner.py') smoke --root $Runtime --condition non-atomic --run-id "$RunId-smoke"
if ($LASTEXITCODE -ne 0) { throw 'Non-atomic smoke failed.' }
& $Python (Join-Path $Repo 'experiments\e2_claiming\e2_runner.py') smoke --root $Runtime --condition protected --run-id "$RunId-smoke"
if ($LASTEXITCODE -ne 0) { throw 'Protected smoke failed.' }
& $Python (Join-Path $Repo 'experiments\e2_claiming\e2_runner.py') lease --root $Runtime --run-id "$RunId-smoke" --trials 1 --smoke
if ($LASTEXITCODE -ne 0) { throw 'Lease smoke failed.' }
```

Review the three smoke result folders under `experiments\e2_claiming\results\` before formal execution. Smoke outcomes are software smoke results, not formal E2 results.

## Formal execution (only when you decide to run it)

```powershell
& $Python (Join-Path $Repo 'experiments\e2_claiming\e2_runner.py') contention --root $Runtime --condition non-atomic --run-id "$RunId-formal" --trials-per-level 20 --seed 20261102
if ($LASTEXITCODE -ne 0) { throw 'Non-atomic run stopped; preserve partial artifacts and inspect them.' }
& $Python (Join-Path $Repo 'experiments\e2_claiming\e2_runner.py') contention --root $Runtime --condition protected --run-id "$RunId-formal" --trials-per-level 20 --seed 20261102
if ($LASTEXITCODE -ne 0) { throw 'Protected run stopped; preserve partial artifacts and inspect them.' }
& $Python (Join-Path $Repo 'experiments\e2_claiming\e2_runner.py') lease --root $Runtime --run-id "$RunId-formal" --trials 30 --seed 20261103
if ($LASTEXITCODE -ne 0) { throw 'Lease run stopped; preserve partial artifacts and inspect them.' }
```

Formal trial counts are configurable with `--trials-per-level` (1..50) and `--trials` (1..100); this FYP configuration uses 20 at each of concurrency levels 2, 5, and 10, plus 30 lease trials. Each run writes raw JSON/CSV and run metadata to a new folder. It never overwrites a result directory.

## Report

```powershell
$Results = Join-Path $Repo 'experiments\e2_claiming\results'
& $Python (Join-Path $Repo 'experiments\e2_claiming\report.py') `
  --non-atomic (Join-Path $Results "$RunId-formal\NON_ATOMIC_BASELINE") `
  --protected (Join-Path $Results "$RunId-formal\PROTECTED_ATOMIC") `
  --lease (Join-Path $Results "$RunId-formal\LEASE_RECOVERY") `
  --output (Join-Path $Results "$RunId-formal\REPORT")
```

The report writes `summary.csv` and `report.md`, including trial-level Wilson intervals for duplicate ownership and invariant violations, request error counts/rates and separate reason-code counts, unexpected zero-winner counts, and request latency distributions (sample count, min, median, p95, max). Latency includes all requests with a recorded measurement, including unsuccessful outcomes; p95 uses linear interpolation on sorted observations. Request errors include `ERROR`, `TIMEOUT`, `DATABASE_ERROR`, `CONNECTION_ERROR`, and the `CLAIM_TRANSACTION_ROLLED_BACK` reason code. Request-error rates are descriptive because concurrent requests within a trial are not independent. A baseline invariant violation is reported as an expected measurable outcome and does not make the baseline trial incomplete. It does not claim a paired analysis because condition fixtures are independent.

## Cleanup

Review and archive the results first. Cleanup requires the runtime marker, exact temporary-root location, matching run-id directory, local server identity, and an explicit confirmation token. It removes only that one marked E2 runtime.

```powershell
& $Python (Join-Path $Repo 'experiments\e2_claiming\e2_runner.py') cleanup --root $Runtime --confirm DELETE_GEOLOCK_E2_RUNTIME
```

## Preparation status and known host limitation

At preparation time the runner, database bootstrap, race implementation and report generator are local artifacts. The current sandbox cannot start PostgreSQL: both `initdb.exe` and `pg_ctl.exe` fail Windows restricted-token creation with error 87. Therefore the isolated setup, smoke tests and formal experiments have **not** completed here. Retry the documented local setup only on a machine/session where PostgreSQL can start; no claim is made that the smoke tests passed.
