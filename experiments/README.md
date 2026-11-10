# Reproducing GeoLock Hub E2 and E4

This guide covers the frozen **GEOLOCK-BM-v3.3** experiments. The normal E2 launcher runs exactly three methods, applying the corrected claim-lock migration only to the disposable proposed-method database after both baselines finish. E2 uses an isolated local PostgreSQL fixture and E4 uses local computation; neither connects to Supabase or another hosted database. Use new run IDs for every experiment; runners refuse to overwrite existing result directories.

## Scope and preserved final runs

The benchmark is version **GEOLOCK-BM-v3.3**, road matrix **OSM-DIRECTED-v3.3**, dataset seed **20260915**. The current benchmark inputs and teammate baseline copies are retained under `experiments/repro_inputs/v33/` and `baseline implementation/source code/`; do not regenerate or edit them.

The preserved final artifacts used by the summary workflow are:

- E2 baselines and historical implementation evidence: `experiments/e2_atomic_claiming/results/e2-final-20261109-055816/` contains both baselines and the earlier proposed implementation; `e2-final-20261109-r3/` preserves the original 683-deadlock evidence and remains the historical reference.
- Corrected E2 proposed-method evidence: `experiments/e2_atomic_claiming/results/e2-lockfix-final-20261109-061706/` contains 275 corrected proposed-method scenarios and regression evidence. This is Method 3; original deadlock evidence remains separate.
- Corrected E4 final result: **awaiting rerun**. The E4 implementation and frozen inputs are retained, but no current final result directory is present. A future run should use a new unique output ID and the E4-only lease-based admission correction.

The existing `experiments/results/e2-e4-winner-aware-20261109-01/` package and older E4 investigation reports are historical snapshots of the former 483-task run. Their figures are not current final results. The corrected 500-candidate E4 rerun is pending.

Historical runs are evidence, not disposable scratch output. Summary generation reads these directories and writes only to a new output directory.

## Prerequisites

- Windows PowerShell, Python **3.12.14** recommended, and the project `.venv-stage8` environment.
- Install dependencies from the checked-in environment/lock files: `experiments/repro_environment.json`, `baseline implementation/source code/requirements.txt`, and `backend/routing/phase_b/requirements-lock.txt`. The recorded OR-Tools version is **9.15.6755** and `psycopg` is **3.3.6**; record any version differences.
- E2 requires PostgreSQL **17** binaries `initdb.exe`, `pg_ctl.exe`, and `psql.exe`, plus the spatial runtime/extension files needed by the fixture. The default remains the repository-local `.tmp/geolock-spatial-runtime-safe-cancel/pgsql/bin` directory. Override it with `--pg-bin` or `GEOLOCK_E2_PG_BIN` on another machine.
- The Windows security context must permit starting an isolated loopback PostgreSQL child process. A check-only command does not test the Windows process-start permission or start PostgreSQL.
- E4 requires the pinned Python routing dependencies and uses the checked-in current CP-SAT implementation; it does not require PostgreSQL.
- Do not set `PYTHONOPTIMIZE` or invoke Python with `-O`; the runner guards rely on assertions.

No `.env` file or private credential is used by the maintained E2/E4 workflow. The legacy scripts and CSV evidence are preserved for reference under `../docs/audits/legacy-claim-geofence/`; they are not part of this reproduction procedure.

## E2 methods and interpretation

The FYP's final E2 comparison has exactly three methods: (1) the non-atomic baseline, (2) atomic claiming without lease recovery, and (3) corrected atomic claiming with lease recovery. The normal launcher writes all three into one run directory. Historical split-run summaries remain supported.

The original proposed implementation in `e2-final-20261109-r3` is a historical version of Method 3, not a fourth research method. Its 683 rollback-confirmed SQLSTATE 40P01 contention failures are reported separately in `e2_development_history.csv`; do not use its contention measurements as the final proposed-method results. The normal E2 launcher applies and verifies the corrected migration against the isolated proposed fixture before it sends any proposed-method requests.

`run_claim_lock_regressions.py` remains available for focused verification. Its default mode runs lock/authorization/rollback/lease regressions only; `--full-benchmark` runs the corrected proposed method with those regressions, but omits both baselines and is not the normal three-method research run. Preserve its output even if a run fails.

The frozen E2 levels **2, 5, and 10 mean concurrent requests**, not necessarily 2, 5, or 10 distinct eligible NGOs. Scenario actor pools contain two to four eligible identities and some scenarios reuse an identity for multiple concurrent requests. The raw `different_ngos` field and the summary's `identity_distribution` show the number of distinct identities. The separate corrected-lock regression uses synthetic eligible identities to test contention among 2, 5, and 10 distinct NGOs; those diagnostic tests are not benchmark scenarios and must not be combined with paper totals.

E2 timing comparisons are descriptive. The older baseline and current GeoLock method use different schemas and function/lifecycle paths, so latency differences cannot be attributed solely to lease recovery or lock strength. The corrected implementation is the final proposed method; the original version's deadlocks remain visible in the separate development-history artifact and are not relabeled as clean conflicts.

## E4 methods and interpretation

E4 compares Nearest-Next, FCFS, and the current CP-SAT optimizer. The corrected common-input rerun is pending. The E4-only adapter treats frozen synthetic listing expiry as NULL; claim leases, ownership, task status, pickup windows, capacity, travel, duration, depot return, and independent validation remain enforced. The expected candidate set is 500 tasks; the final admitted and served counts must come from the next completed run and must not be inferred from historical results.

E4 uses `backend/routing/phase_b/optimizers/proposed` through the current routing worker bridge. The next run must independently validate every saved plan and report solver/planner and evaluation timing separately. Distance comparisons should use identical served-task sets; aggregate distance alone is not comparable when coverage differs. Runtime and paired intervals describe these fixed scenarios and are not population inference or end-to-end app latency.

## PowerShell commands

Run from the repository root. The following commands are examples; choose unique run IDs and new output paths. The preflight checks frozen input hashes and dependency versions without starting PostgreSQL or the optimizer.

```powershell
$py = Join-Path (Get-Location) '.venv-stage8\Scripts\python.exe'

# Optional: specify a PostgreSQL 17 bin folder for both E2 launch workflows.
# The corrected runner otherwise uses GEOLOCK_E2_PG_BIN, then the historical repository-local path.
# $pgBin = 'D:\tools\postgresql-17\bin'
# $env:GEOLOCK_E2_PG_BIN = $pgBin

# Read-only input/dependency check; no experiment is executed.
& $py experiments\run_repro_benchmarks.py --experiment E2 --run-id e2-preflight --check-only
if ($LASTEXITCODE -ne 0) { throw 'E2 input preflight failed' }
& $py experiments\run_repro_benchmarks.py --experiment E4 --run-id e4-preflight --check-only
if ($LASTEXITCODE -ne 0) { throw 'E4 input preflight failed' }

# Full E2: exactly two preserved baselines plus corrected proposed Method 3.
# The corrected migration/hash guards run inside the isolated proposed database.
$pgBin = Join-Path (Get-Location) '.tmp\geolock-spatial-runtime-safe-cancel\pgsql\bin'
$e2RunId = 'e2-three-method-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
$e2Output = Join-Path (Get-Location) "experiments\e2_atomic_claiming\results\$e2RunId"
if (Test-Path $e2Output) { throw "Output exists; choose another ID: $e2Output" }
& $py experiments\run_repro_benchmarks.py --experiment E2 --run-id $e2RunId --pg-bin $pgBin
if ($LASTEXITCODE -ne 0) { throw 'E2 stopped; retain partial evidence' }

# Corrected E2 regression-only run (no frozen 275-scenario benchmark).
$regressionOutput = 'experiments/e2_atomic_claiming/results/e2-lockfix-regressions-new-01'
& $py experiments\e2_atomic_claiming\run_claim_lock_regressions.py --output $regressionOutput
if ($LASTEXITCODE -ne 0) { throw 'Corrected E2 regressions stopped; retain partial evidence' }

# Optional corrected-proposed-only benchmark plus focused regressions.
# This is diagnostic evidence, not the normal three-method comparison.
$correctedOutput = 'experiments/e2_atomic_claiming/results/e2-lockfix-new-01'
& $py experiments\e2_atomic_claiming\run_claim_lock_regressions.py --output $correctedOutput --full-benchmark
if ($LASTEXITCODE -ne 0) { throw 'Corrected E2 stopped; retain partial evidence' }

# Full E4 rerun: choose a fresh unique ID; the former result directory was removed.
$e4RunId = 'e4-final-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
$e4Output = Join-Path (Get-Location) "experiments\e4_post_claim_routing\results\$e4RunId"
& $py experiments\run_repro_benchmarks.py --experiment E4 --run-id $e4RunId
if ($LASTEXITCODE -ne 0) { throw 'E4 stopped; retain partial evidence' }

# Summarize preserved split-run evidence without changing source runs.
& $py experiments\summarize_final_e2_e4.py `
  --original-e2 experiments\e2_atomic_claiming\results\e2-final-20261109-055816 `
  --corrected-e2 experiments\e2_atomic_claiming\results\e2-lockfix-final-20261109-061706 `
  --historical-e2 experiments\e2_atomic_claiming\results\e2-final-20261109-r3 `
  --e4 $e4Output `
  --output experiments\results\e2-e4-split-review-new-01
if ($LASTEXITCODE -ne 0) { throw 'Summary generation failed' }

# For a newly completed normal E2 run, summarize its three methods together.
& $py experiments\summarize_final_e2_e4.py `
  --combined-e2 $e2Output `
  --historical-e2 experiments\e2_atomic_claiming\results\e2-final-20261109-r3 `
  --e4 $e4Output `
  --output (Join-Path (Get-Location) ('experiments\results\e2-e4-' + (Get-Date -Format 'yyyyMMdd-HHmmss')))
if ($LASTEXITCODE -ne 0) { throw 'Combined E2/E4 summary generation failed' }
```

To use a specific PostgreSQL binary folder, pass `--pg-bin $pgBin` to the normal E2 launcher. It also accepts `GEOLOCK_E2_PG_BIN` and retains the existing local default.

After a successful future E4 rerun, pass its `$e4Output` to the summary command. No current final E4 result is available to summarize:

```powershell
& $py experiments\summarize_final_e2_e4.py `
  --original-e2 experiments\e2_atomic_claiming\results\e2-final-20261109-055816 `
  --corrected-e2 experiments\e2_atomic_claiming\results\e2-lockfix-final-20261109-061706 `
  --historical-e2 experiments\e2_atomic_claiming\results\e2-final-20261109-r3 `
  --e4 $e4Output `
  --output (Join-Path (Get-Location) ('experiments\results\e2-e4-review-' + (Get-Date -Format 'yyyyMMdd-HHmmss')))
```

The summary command refuses an existing output directory. Its primary E2 CSV contains exactly three methods, uses corrected proposed results for Method 3, and preserves the original proposed version separately as historical validation evidence. For a new combined run it independently validates both corrected runs against the frozen scenario IDs, migration/function hashes, per-scenario claim outcomes, committed ownership, error/retry/SQLSTATE counts, and lease invariants. It does not require the same concurrent request or NGO to win twice: `e2_corrected_reference_comparison.csv` records the winning request and NGO per scenario, while `e2_corrected_request_differences.csv` retains request-level outcome/reason/retry/SQLSTATE differences and run-scoped IDs. These winner changes are reported as scheduling differences when both runs pass their invariants. Timing is reported for context, not as a parity requirement. The summary also validates E4 method coverage, both admission lanes, and 300 independent route validations. Its manifest records source artifact hashes. It does not execute a database, call the solver, or modify source result directories.

## E2 development history

The original proposed E2 implementation in `e2-final-20261109-r3` recorded 683 contention errors with SQLSTATE 40P01. The corrected proposed run `e2-lockfix-final-20261109-061706` validates Method 3. The normal launcher now applies the same hash-verified correction only to the local proposed-method fixture. Original results remain development-history evidence and are excluded from the primary three-method comparison.

The maintained E2/E4 runner, tests, this README, and the final summary script do not read legacy `.env` configuration. The relocated historical evidence bundle contains no credentials.

`experiments/REPRODUCIBILITY_MANIFEST.json` continues to record hashes for earlier result artifacts and is retained as historical provenance.
