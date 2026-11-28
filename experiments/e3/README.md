# E3: community hub aggregation against direct household pickup

* Plan: [`EXPERIMENT_PLAN.md`](EXPERIMENT_PLAN.md)
* Result: [`experiment_result/summary.md`](experiment_result/summary.md)

| Folder | Content |
| --- | --- |
| `baseline/` | direct household pickup: program in `source_code/`, results in `direct_household_pickup/` |
| `hub_aggregation/` | proposed method: program in `source_code/`, results in `result/` |
| `experiment_result/` | comparison program, summary, main table and three figures |

## How to run

From the repository root, in this order:

1. Baseline: `python experiments/e3/baseline/source_code/direct_household_pickup_baseline.py`
2. Proposed method: `python experiments/e3/hub_aggregation/source_code/run_hub_aggregation.py`
3. Comparison (needs numpy, scipy and matplotlib): `python experiments/e3/experiment_result/source_code/e3_compare.py`

Rerunning gives exactly the same numbers, apart from planning times.

## Result files

| File | What it shows |
| --- | --- |
| `baseline/direct_household_pickup/results_per_scenario.csv` | one row per scenario: NGO km, driving time, trips, cost, donations collected |
| `baseline/direct_household_pickup/routes.csv` | each vehicle route, with its stops and route time |
| `hub_aggregation/result/results_per_scenario.csv` | the same for the hub, plus NGO stops and the batch |
| `hub_aggregation/result/routes.csv` | each vehicle route to the hub |
| `hub_aggregation/result/batch_integrity_checks.csv` | one row per batch: every hub rule check (YES or NO) |
| `experiment_result/comparison_summary.csv` | **main table**: every NGO measure for both methods, % change with 95 % interval, p values |
| `experiment_result/comparison_per_scenario.csv` | one row per scenario, baseline and proposed side by side |
| `experiment_result/e3_fig1_main_comparison.png` | both methods on the four NGO measures (for slides and Chapter 5) |
| `experiment_result/e3_fig2_ngo_km_per_scenario.png` | NGO road distance in every scenario |
| `experiment_result/e3_fig3_saving_by_batch_size.png` | NGO driving by number of donations in the batch |

If the benchmark files were downloaded as a ZIP, their line endings may have been changed from CRLF to LF. The
runners then stop with "Input hash differs from generation manifest". The data itself is unchanged, so use the git
copy of the repository, or convert the CSV files in `benchmark dataset/dataset` back to CRLF line endings.
