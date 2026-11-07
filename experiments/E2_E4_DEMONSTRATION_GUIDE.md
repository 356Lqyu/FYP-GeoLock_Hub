# E2 and E4 demonstration on 6 November 2026

Use the preserved results first. Explain the limitations before showing totals. These commands create **new local disposable runs only**; they do not connect to Supabase or start planner/validator services. A dataset-integrity check is not an experiment result. One-case demos are not full independent replications.

## Preparation

```powershell
Set-Location 'C:\Users\User\Downloads\FYP-GeoLock_Hub'
$py = Join-Path (Get-Location) '.venv-stage8\Scripts\python.exe'
& $py experiments/run_repro_benchmarks.py --experiment E4 --run-id demo-check --check-only
```

Expected: `INPUT_CHECK_ONLY_NOT_EXPERIMENT_RESULTS`, GEOLOCK-BM-v3.3, 150/100/25/100 scenario counts and manifest-matching canonical CSV hashes. The original LF inputs remain unchanged. Runtime dependencies and paths are described in `REPRODUCIBLE_E2_E4_README.md`.

## E2: concurrent ownership and recovery

Opening explanation: “The non-atomic baseline checks then writes without serializing ownership. GeoLock's actual PostgreSQL function uses transactions and uniqueness protection. We inspect committed owner records, not only returned success messages. The current implementation also produces rollback errors under contention; those errors are retained and reported.”

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

The executed smoke evidence for these exact scenarios shows duplicate naive claims, one committed GeoLock owner, successful expired-lease release/reclaim and zero active-lease release. A new demo is an actual execution with its own results; do not promise which concurrent NGO wins or an exact latency/error count in advance. A nonzero failed_with_error is not a clean conflict, and `database_errors.csv` preserves the proposed failure-audit SQLSTATEs. Do not delete an old run to reuse its name.

Show the full run:

```powershell
$e2 = 'experiments/e2_atomic_claiming/results/e2-20261105-v33-actual-01'
Import-Csv "$e2/comparison.csv" | Format-Table method,workers,trials,duplicate_trials,exactly_one_committed_claim,errors,median_ms
Import-Csv "$e2/lease_comparison.csv" | Format-Table
Get-Content "$e2/COMPARISON.md"
```

These tables distinguish original teammate schema/baseline versions from current GeoLock's complete schema. Do not describe their latency difference as the isolated causal effect of one lock keyword. The actual claim/recovery bodies were not changed for the demonstration.

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

# Full executed 100-scenario evidence, not the one-case demo:
$e4 = 'experiments/e4_post_claim_routing/results/e4-20261105-v33-actual-02'
Import-Csv "$e4/original_baseline_summary.csv" | Format-Table
Import-Csv "$e4/summary_statistics.csv" | Format-Table method,scenarios,valid_tasks,served_tasks,task_weighted_coverage_pct,feasibility_pass
Import-Csv "$e4/paired_distance_summary.csv" | Format-Table baseline,equal_served_task_count,coverage_differs,identical_served_task_sets,strict_distance_reduction_pct
Get-Content "$e4/verification.json"
```

Say explicitly: “The original 500-task baselines reproduce their published outputs. Current GeoLock admission rejects 17 short-lived listings. The separately labelled common-admission comparison has 483 tasks across the same 100 scenarios. Its routes all pass independent validation, but that does not erase the formal admission-policy mismatch. We have not weakened the application or changed the frozen dataset.”

Do not compare all-scenario distance totals as a saving when task coverage differs. The summary distinguishes 98 equal-count scenarios and stricter identical-task subsets. Do not claim zero unserved tasks just because constraints pass. An offline feasible plan is not database dispatch authorization or proof of physical pickup.

## Closing explanation

“The experiment exercises the real PostgreSQL claim/recovery functions and the real routing worker optimizer on the existing frozen benchmark. It also exposes engineering and protocol limitations: current claim contention can return rollback errors, the original baseline schema differs from the live implementation, and routing admission differs for 17 tasks. We retain those outcomes rather than patch the product or remove difficult cases to obtain a PASS.”

All disposable E2 servers should stop automatically and leave `cluster-stop.json`; retain runtime evidence instead of deleting request history. If startup fails before a normal completion, inspect only that new run's runtime/server log and PostgreSQL status—never substitute a hosted DSN, reset shared data or kill unrelated workers. Existing Flutter/planner/validator sessions are not required for this benchmark demonstration.
