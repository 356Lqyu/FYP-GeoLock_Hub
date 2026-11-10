# E3: community hub aggregation against direct household pickup

* Plan: [`EXPERIMENT_PLAN.md`](EXPERIMENT_PLAN.md)
* Result: [`experiment_result/summary.md`](experiment_result/summary.md)

| Folder | Content |
| --- | --- |
| `baseline/` | direct household pickup: program in `source_code/`, results in `direct_household_pickup/` |
| `hub_aggregation/` | proposed method: program in `source_code/`, results in `result/` |
| `experiment_result/` | comparison program, summary, figures and the per scenario comparison table |

## How to run

From the repository root (`D:\fyp-combine\FYP-GeoLock_Hub`), in this order:

1. Baseline, direct household pickup:
   ```powershell
   python experiments/e3/baseline/source_code/direct_household_pickup_baseline.py
   ```
2. Proposed method, community hub aggregation:
   ```powershell
   python experiments/e3/hub_aggregation/source_code/run_hub_aggregation.py
   ```
3. Comparison (reads both result folders and writes `experiment_result/`):
   ```powershell
   python experiments/e3/experiment_result/source_code/e3_compare.py
   ```

## Result files

Start with `experiment_result/comparison_summary.csv`: the totals of both methods side by side.

| File | What it shows |
| --- | --- |
| `baseline/direct_household_pickup/results_per_scenario.csv` | one row per scenario: NGO km, driving time, trips, cost and donations collected with home pickups |
| `hub_aggregation/result/results_per_scenario.csv` | the same with the hub, plus the batch, NGO stops and donor travel |
| `hub_aggregation/result/details/batch_integrity_checks.csv` | one row per batch: every hub rule check (YES or NO) |
| `hub_aggregation/result/details/donor_trips_to_hub.csv` | each donor's trip to the hub and back |
| `.../details/routes.csv` and `tasks.csv` | each vehicle route and each pickup task |
| `experiment_result/comparison_summary.csv` | one row per measure: total for each method, change in % and the paired test |
| `experiment_result/comparison_per_scenario.csv` | one row per scenario with the baseline and proposed values next to each other |
| `experiment_result/metrics.json` | every number in summary.md, with intervals and test results |
