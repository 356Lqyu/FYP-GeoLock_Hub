# E4: OR-Tools route optimiser against simple routing rules

* Plan: [`EXPERIMENT_PLAN.md`](EXPERIMENT_PLAN.md)
* Result: [`experiment_result/summary.md`](experiment_result/summary.md)

| Folder | Content |
| --- | --- |
| `test_harness/` | builds one sealed planning snapshot per scenario and checks every plan; used by all three methods |
| `baseline/` | Nearest-Next (baseline 1) and first come first served (baseline 2): programs in `source_code/`, results in `1_nearest_next/` and `2_fcfs/` |
| `or_tools_route_optimiser/` | proposed method, the app's OR-Tools route optimiser (`backend/routing/optimizers/cp_sat.py`, unchanged): program in `source_code/`, results in `result/` |
| `experiment_result/` | comparison program, summary, figures and the per scenario comparison table |

## How to run

From the repository root (`D:\fyp-combine\FYP-GeoLock_Hub`), in this order:

1. Baseline 1, Nearest-Next:
   ```powershell
   python experiments/e4/baseline/source_code/nearest_next_baseline.py
   ```
2. Baseline 2, first come first served:
   ```powershell
   python experiments/e4/baseline/source_code/fcfs_baseline.py
   ```
3. Proposed method, OR-Tools route optimiser:
   ```powershell
   python experiments/e4/or_tools_route_optimiser/source_code/run_or_tools_route_optimiser.py
   ```
4. Comparison (reads the three result folders and writes `experiment_result/`):
   ```powershell
   python experiments/e4/experiment_result/source_code/e4_compare.py
   ```

## Result files

Start with `experiment_result/comparison_summary.csv`: the main numbers of the three methods side by side.

| File | What it shows |
| --- | --- |
| `<method>/results_per_scenario.csv` | one row per scenario: valid pickups, pickups served, km, driving time, vehicles used, rule violations, whether the plan passed the independent check and planning time |
| `<method>/details/routes.csv` | the stop order of every vehicle |
| `experiment_result/comparison_summary.csv` | one row per measure with the value of each method |
| `experiment_result/comparison_per_scenario.csv` | one row per scenario: pickups served, km and vehicles of all three methods next to each other, and the km saved against Nearest-Next where both serve the same pickups |
| `experiment_result/metrics.json` | every number in summary.md, with intervals and test results |
