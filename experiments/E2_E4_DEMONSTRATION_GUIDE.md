# E2 and E4 demonstration on 6 November 2026

Use the preserved results first. Explain the limitations before showing totals. These commands create **new local disposable runs only**; they do not connect to Supabase or start planner/validator services. A dataset-integrity check is not an experiment result. One-case demos are not full independent replications.

## Preparation

```powershell
Set-Location 'C:\Users\User\Downloads\FYP-GeoLock_Hub'
$py = Join-Path (Get-Location) '.venv-stage8\Scripts\python.exe'
& $py experiments/run_repro_benchmarks.py --experiment E4 --run-id demo-check --check-only
```

Expected: `INPUT_CHECK_ONLY_NOT_EXPERIMENT_RESULTS`, GEOLOCK-BM-v3.3, 150/100/25/100 scenario counts and manifest-matching canonical CSV hashes. The original LF inputs remain unchanged. Runtime dependencies and paths are described in `README.md`.

## E2: concurrent ownership and recovery

Opening explanation: “The non-atomic baseline checks then writes without serializing ownership. We inspect committed owner records, not only returned success messages. The normal E2 launcher runs the two baselines and the corrected atomic-with-lease method. The original proposed version’s deadlocks remain separate historical debugging evidence and are not rerun in the normal workflow or counted as another method.”

```powershell
# One live frozen contention scenario, two concurrent requests per method.
# Choose another RunId if these paths already exist. This can take tens of seconds.
& $py experiments/run_repro_benchmarks.py --experiment E2 --run-id demo-e2-contention-01 --scenario SCN-CLAIM_COORDINATION-0001
if ($LASTEXITCODE -ne 0) { throw 'Demo failed; retain evidence, do not switch to DEV' }
$e2demo = 'experiments/e2_atomic_claiming/results/demo-e2-contention-01'
Import-Csv "$e2demo/non_atomic_claim/results_per_scenario.csv" | Format-Table scenario_id,claims_stored,more_than_one_owner
Import-Csv "$e2demo/protected_claim_without_lease_recovery/results_per_scenario.csv" | Format-Table scenario_id,claims_stored,failed_with_error
Import-Csv "$e2demo/proposed_results_per_scenario.csv" | Format-Table scenario_id,claims_stored,told_success,failed_with_error
Get-Content "$e2demo/proposed_committed_states.json"
Get-Content "$e2demo/cluster-stop.json"

# One expired and one active lease case; no non-atomic recovery algorithm is invented.
& $py experiments/run_repro_benchmarks.py --experiment E2 --run-id demo-e2-lease-01 --scenario SCN-LEASE_RECOVERY-0001,SCN-LEASE_ACTIVE_VERIFICATION-0001
if ($LASTEXITCODE -ne 0) { throw 'Lease demo failed; inspect retained results' }
$lease = 'experiments/e2_atomic_claiming/results/demo-e2-lease-01'
Import-Csv "$lease/proposed_results_per_scenario.csv" | Format-Table scenario_id,second_ngo_answer,first_claim_still_active,recovery_affected_rows
```

The normal E2 launcher applies the hash-verified lock correction to its isolated proposed database after both baselines finish. The executed historical smoke evidence shows duplicate naive claims; the corrected method is checked for one committed owner, successful expired-lease recovery and active-lease protection. A new demo is an actual execution with its own results; do not promise which concurrent NGO wins or an exact latency/error count in advance. A nonzero failed_with_error is not a clean conflict, and `database_errors.csv` preserves any proposed-method failure audit. Do not delete an old run to reuse its name.

Show the full run:

```powershell
$e2Baseline = 'experiments/e2_atomic_claiming/results/e2-final-20261109-055816'
$e2Corrected = 'experiments/e2_atomic_claiming/results/e2-lockfix-final-20261109-061706'
Import-Csv "$e2Baseline/non_atomic_claim/results_per_scenario.csv" | Group-Object ngos_competing | Select-Object Name,Count
Import-Csv "$e2Baseline/protected_claim_without_lease_recovery/results_per_scenario.csv" | Group-Object ngos_competing | Select-Object Name,Count
Get-Content "$e2Corrected/completion.json"
Get-Content "$e2Corrected/regressions.json" -Raw | ConvertFrom-Json | Select-Object passed,checks
```

The baseline results and corrected results above are preserved split-run evidence. A new normal full E2 run now writes both baselines and the corrected proposed method into one unique output directory. The `e2-final-20261109-r3` and `e2-final-20261109-055816` proposed-method records are historical deadlock evidence; do not include them as the final Method 3 results. Do not describe timing differences across these runs as the isolated causal effect of one lock keyword.

## E4: route order, validation and the full benchmark

Use **SCN-ROUTE_PLANNING-0003**, a genuine strict same-served-task comparison in the executed full run:

| Method | Served task order (one route) | Distance |
|---|---|---|
| Nearest-Next | LST000090 → LST000087 → LST000089 → LST000088 | 47.55281 km |
| Actual GeoLock proposed | LST000088 → LST000090 → LST000087 → LST000089 | 42.94797 km |

The task IDs above abbreviate `TASK-LST…`; both plans serve exactly the same four tasks. They come from actual saved plans, not an invented map. Read their independent feasibility reports and input hashes. The times/roads are the supplied directed matrix, not Google Maps live traffic.

```powershell
# Optional fresh one-case offline solve. No database or worker service starts.
& $py experiments/run_repro_benchmarks.py --experiment E4 --run-id demo-e4-01 --scenario SCN-ROUTE_PLANNING-0003
if ($LASTEXITCODE -ne 0) { throw 'Routing demo failed; inspect saved failure evidence' }
$demo = 'experiments/e4_post_claim_routing/results/demo-e4-01'
Import-Csv "$demo/results_per_scenario.csv" | Format-Table method,valid_tasks,served_tasks,total_distance_km,feasibility_pass,planner_execution_ms
$proposal = Get-Content "$demo/raw/SCN-ROUTE_PLANNING-0003-proposed.json" -Raw | ConvertFrom-Json
$proposal.plan.routes | ForEach-Object { $_.stops | Select-Object task_id,arrival_us,departure_us,cumulative_load_kg }
$proposal.independent_validation | Format-List valid,feasible,violations

# Full final E4 rerun is pending. Use a fresh ID and inspect only that new run:
$e4RunId = 'e4-final-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
& $py experiments/run_repro_benchmarks.py --experiment E4 --run-id $e4RunId
if ($LASTEXITCODE -ne 0) { throw 'E4 stopped; preserve partial evidence' }
$e4 = "experiments/e4_post_claim_routing/results/$e4RunId"
& $py experiments/summarize_repro_benchmarks.py --e4 $e4
Import-Csv "$e4/summary_statistics.csv" | Format-Table method,scenarios,valid_tasks,served_tasks,task_weighted_coverage_pct,feasibility_pass
Get-Content "$e4/verification.json"
```

Say explicitly: “The corrected E4 experiment is awaiting its final rerun. Its E4-only adapter treats synthetic listing expiry timestamps as NULL, while claim-lease, ownership, task, pickup-window, route and independent validation checks remain active. No current final E4 metrics are being reported.”

Do not compare all-scenario distance totals as a saving when task coverage differs. The summary distinguishes 98 equal-count scenarios and stricter identical-task subsets. Do not claim zero unserved tasks just because constraints pass. An offline feasible plan is not database dispatch authorization or proof of physical pickup.

## Closing explanation

“The original proposed E2 run records claim deadlock rollback errors as historical debugging evidence. The normal E2 workflow compares exactly three methods and applies the corrected lock migration only to its isolated proposed database. The original baseline schema differs from the current implementation. E4 source, baselines and frozen inputs remain available, but the corrected final E4 run is pending. Older 483-task figures are historical and must not be presented as current results.”

All disposable E2 servers should stop automatically and leave `cluster-stop.json`; retain runtime evidence instead of deleting request history. If startup fails before a normal completion, inspect only that new run's runtime/server log and PostgreSQL status—never substitute a hosted DSN, reset shared data or kill unrelated workers. Existing Flutter/planner/validator sessions are not required for this benchmark demonstration.
