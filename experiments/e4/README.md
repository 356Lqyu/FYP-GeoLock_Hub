# E4: OR-Tools route optimiser against simple routing rules

* Plan: [`EXPERIMENT_PLAN.md`](EXPERIMENT_PLAN.md)
* Result report and figures are regenerated under `experiment_result/` after a complete same-run execution. The currently saved result files predate the 500-task admission/matched-task correction and must be treated as historical until that rerun completes.

| Folder | Content |
| --- | --- |
| `test_harness/` | builds one sealed planning snapshot per scenario and checks every plan; used by all three methods |
| `baseline/` | Nearest-Next (baseline 1) and first come first served (baseline 2): programs in `source_code/`, results in `1_nearest_next/` and `2_fcfs/` |
| `or_tools_route_optimiser/` | proposed method, the app's OR-Tools route optimiser (`backend/routing/optimizers/cp_sat.py`, unchanged): program in `source_code/`, results in `result/` |
| `experiment_result/` | comparison program, summary, figures and the per scenario comparison table |

## How to run

From the repository root, in PowerShell. These commands intentionally replace the fixed result folders. First confirm the current result files are committed or otherwise backed up. All three methods use one shared run ID, and execution stops if any command fails:

```powershell
$ErrorActionPreference = 'Stop'
$env:GEOLOCK_E4_RUN_ID = [guid]::NewGuid().ToString('N')
try {
    python experiments/e4/baseline/source_code/nearest_next_baseline.py
    if ($LASTEXITCODE -ne 0) { throw 'Nearest-Next failed; preserve partial evidence and stop.' }

    python experiments/e4/baseline/source_code/fcfs_baseline.py
    if ($LASTEXITCODE -ne 0) { throw 'FCFS failed; preserve partial evidence and stop.' }

    python experiments/e4/or_tools_route_optimiser/source_code/run_or_tools_route_optimiser.py
    if ($LASTEXITCODE -ne 0) { throw 'CP-SAT failed; preserve partial evidence and stop.' }

    python experiments/e4/experiment_result/source_code/e4_compare.py
    if ($LASTEXITCODE -ne 0) { throw 'E4 comparison failed; do not treat the outputs as final.' }
}
finally {
    Remove-Item Env:\GEOLOCK_E4_RUN_ID -ErrorAction SilentlyContinue
}
```

The comparison fails closed unless the three manifests have the same run ID, settings, frozen-input hashes and source hashes; it also requires 100 scenarios, 500 common-admission tasks and successful independent validation of all 300 plans. Do not run only one method and combine it with earlier results.

The E4 adapter ignores the synthetic legacy listing-expiry field only for this benchmark. It preserves claim-lease, ownership, task-status, pickup-window, capacity, route-duration, depot-return and directed-road checks. The CP-SAT optimiser and frozen dataset are unchanged.

## Result files

Start with `experiment_result/comparison_summary.csv`: the main numbers of the three methods side by side.

| File | What it shows |
| --- | --- |
| `<method>/results_per_scenario.csv` | one row per scenario: valid pickups, pickups served, km, driving time, vehicles used, rule violations, whether the plan passed the independent check and planning time |
| `<method>/details/routes.csv` | the stop order of every vehicle |
| `experiment_result/comparison_summary.csv` | one row per measure with the value of each method |
| `experiment_result/comparison_per_scenario.csv` | one row per scenario, including whether the methods served identical task-ID sets |
| `experiment_result/metrics.json` | aggregate metrics and exact-task paired estimates, intervals and tests |
