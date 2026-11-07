# Reproduce the coordinated E2 correction locally

Use the existing reviewed source package, extracted teammate package and frozen GEOLOCK-BM-v3.3 inputs. This procedure accepts no remote DSN. Do not use shared DEV, Python `-O`, `PYTHONOPTIMIZE`, the upstream unwrapped E2 CLI, or an existing run ID.

Recorded environment: Windows, Python 3.12.14 (`.venv-stage8`), psycopg 3.3.6, PostgreSQL 17.11. Custody fixture setup also uses the installed OR-Tools 9.15.6755 and an isolated synthetic graph/local validator. It does not activate a hosted worker. Package/native hashes remain in `experiments/repro_environment.json` and `experiments/repro_runtime_checksums.json`. Native binaries are expected at `.tmp/geolock-spatial-runtime-safe-cancel/pgsql/bin`. No extension catalog is fabricated. Primary E2 eligibility uses the frozen directed matrix through the same documented local adapter as the original run.

The teammate extraction is currently `C:\Users\User\Downloads\FYP-GeoLock_Hub-ss (1)\FYP-GeoLock_Hub-ss`; the existing integrity helper verifies it against the project copies and the canonical-byte input mirror. All 15 CSV manifest hashes must match. A missing source/native package is a prerequisite failure, not a reason to use a remote connection or regenerate inputs.

```powershell
Set-Location 'C:\Users\User\Downloads\FYP-GeoLock_Hub'
$py = Join-Path (Get-Location) '.venv-stage8\Scripts\python.exe'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$focus = "e2-shared-focus-$stamp"
$full = "e2-shared-full-$stamp"

# Optional independent reproduction of the ORIGINAL defect in a fresh cluster.
# This is a negative control and is not pooled into the corrected benchmark.
& $py experiments/e2_atomic_claiming/reproduce_shared_original.py --run-id "original-$stamp"
if ($LASTEXITCODE -ne 0) { throw 'Original control incomplete; retain evidence' }

# Existing custody/reconciliation tests, using new disposable clones each run.
$receipt = 'docs/investigations/e2-shared-lock-review/custody-tests.json'
if (Test-Path -LiteralPath $receipt) {
  $archive = "docs/investigations/e2-shared-lock-review/custody-tests-preserved-$stamp.json"
  if (Test-Path -LiteralPath $archive) { throw 'Choose a new timestamp; receipt archive already exists' }
  Copy-Item -LiteralPath $receipt -Destination $archive
}
& $py experiments/e2_atomic_claiming/shared_custody_tests.py
if ($LASTEXITCODE -ne 0) { throw 'Custody tests failed/incomplete: do not benchmark' }

# Independent focused SQL check run; starts and stops a NEW local cluster.
& $py experiments/e2_atomic_claiming/run_shared.py --focused-only --output "experiments/e2_atomic_claiming/results/$focus"
if ($LASTEXITCODE -ne 0) { throw 'Focused checks failed/incomplete: do not benchmark' }

# Full frozen 275-case run in another NEW cluster. It also repeats the focused
# SQL checks before any formal scenario and requires the custody pass receipt.
& $py experiments/e2_atomic_claiming/run_shared.py --output "experiments/e2_atomic_claiming/results/$full"
if ($LASTEXITCODE -ne 0) { throw 'Full run incomplete; retain logs and do not mark PASS' }

# Read-only analysis of saved measurements; writes only into the NEW run.
& $py experiments/e2_atomic_claiming/summarize_corrected.py --run "experiments/e2_atomic_claiming/results/$full"
if ($LASTEXITCODE -ne 0) { throw 'Result verification failed' }
```

The runners refuse output-directory reuse and retain stopped runtime data. Setup failures and partial results remain evidence, never PASS. A focused completion receipt is different from a full benchmark completion receipt. The final full run must contain all 150 CLAIM_COORDINATION, 100 LEASE_RECOVERY and 25 LEASE_ACTIVE_VERIFICATION IDs plus a successful shutdown record.

Primary outputs: `proposed_results_per_scenario.csv`, `proposed_requests.json`, `proposed_committed_states.json`, `database_errors.csv`, `all_failure_audits.json`, `regressions.json`, `manifest.json`, `completion.json`, `cluster-stop.json`, `corrected_summary.json`, `comparison.csv`, `lease_comparison.csv` and `COMPARISON.md`. Benchmark failure audits are filtered by the exact measured request UUIDs; deliberate fault/authorization/drift controls are retained separately and do not enter the benchmark error denominator.

Custody evidence uses new timestamped directories under `results/automatic-routing-local/`, referenced by `custody-tests.json`. That convenience receipt/log is the latest run; preserve/archive it before another attempt. Existing prior attempts are already archived with attempt suffixes. Its adapter adds the same explicit authenticated claim-function grant as the primary fixture, retaining the existing PUBLIC execution grant and body authorization. The legacy CRLF fixture is normalized only where every nonblank source line is identical. No substantive source mismatch or migration security guard is bypassed, and no operational trigger is removed.

The benchmark runs the actual corrected claim/recovery functions and the original request driver/fixtures. The additional distinct-account tests use regression-only co-located verified NGO accounts because the frozen ten-request scenarios may repeat a smaller actor set. They do not modify or replace the frozen scenarios.

Historical comparisons are read from `e2-20261105-v33-actual-01`. The failed claim-only run is retained but is not a full corrected-method comparison sample. Baseline schema/audit differences, one execution per method/scenario and synthetic Auth/Storage/road adapters limit causal runtime conclusions. LOCAL PASS means the requested local correctness/robustness checks passed; it is not DEV deployment, production verification or a claim that every possible lifecycle schedule is deadlock-free.
