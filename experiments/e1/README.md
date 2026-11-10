# E1: AI hub ranking against Nearest-Hub and Random Hub

* Plan: [`EXPERIMENT_PLAN.md`](EXPERIMENT_PLAN.md)
* Result: [`experiment_result/summary.md`](experiment_result/summary.md)

| Folder | Content |
| --- | --- |
| `baseline/` | Nearest-Hub and Random Hub: programs in `source_code/`, results in `1_nearest_hub/` and `2_random_hub/` |
| `ai_hub_ranking/` | proposed method: program in `source_code/`, results in `result/` |
| `experiment_result/` | comparison program, summary, figures and the per donation comparison table |

## How to run

From the repository root (`D:\fyp-combine\FYP-GeoLock_Hub`), in this order:

1. Baseline 1, Nearest-Hub:
   ```powershell
   python experiments/e1/baseline/source_code/nearest_hub_baseline.py
   ```
2. Baseline 2, Random Hub:
   ```powershell
   python experiments/e1/baseline/source_code/random_hub_baseline.py
   ```
3. Proposed method, AI hub ranking:
   ```powershell
   python experiments/e1/ai_hub_ranking/source_code/run_ai_hub_ranking.py
   ```
4. Comparison (reads the three result folders and writes `experiment_result/`):
   ```powershell
   python experiments/e1/experiment_result/source_code/e1_compare.py
   ```

All three methods use the 349 test donations in `ai hub ranking/data split/split/test_scenario_ids.csv` automatically.

## Result files

Start with `experiment_result/comparison_summary.csv`: the main numbers of the three methods side by side.

| File | What it shows |
| --- | --- |
| `baseline/1_nearest_hub/results_per_scenario.csv` | one row per test donation: the hub Nearest-Hub recommends, its road distance and the next two hubs |
| `baseline/2_random_hub/results_per_scenario.csv` | the same for Random Hub |
| `ai_hub_ranking/result/results_per_scenario.csv` | the same for the AI, plus its predicted score and the score gap to the second hub |
| `.../details/hub_ranking.csv` | the full hub order of every donation for that method |
| `experiment_result/comparison_summary.csv` | one row per measure (Top-1 agreement, top 3, NDCG@3, regret, distance) with the value of each method |
| `experiment_result/comparison_per_scenario.csv` | one row per donation: the reference hub and, for each method, its hub, whether it matches the reference (1 or 0), NDCG@3, regret and km |
| `experiment_result/metrics.json` | every number in summary.md, with intervals and test results |
| `run_info.md` (in each result folder) | how that result was produced |
