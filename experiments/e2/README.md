# E2: safe claiming and lease recovery

* Plan: [`EXPERIMENT_PLAN.md`](EXPERIMENT_PLAN.md)
* Result: [`experiment_result/summary.md`](experiment_result/summary.md)
* Creating the separate Supabase project, step by step: [`HOW_TO_RUN_E2.md`](HOW_TO_RUN_E2.md)

| Folder | Content |
| --- | --- |
| `database/` | the SQL that builds the experiment database; `deployed_snapshot/` is the app's function, trigger and table export the app functions are copied from |
| `test_harness/` | `e2_harness.py`, the one test program behind all three conditions, so they get the same donations, NGOs, timing and checks |
| `baseline/` | Non-Atomic Claim and Protected Claim without Lease Recovery: programs in `source_code/`, results in `1_non_atomic_claim/` and `2_protected_claim_without_lease_recovery/` |
| `protected_claim_with_lease_recovery/` | proposed method (the app's functions): program in `source_code/`, results in `result/` |
| `experiment_result/` | comparison program, summary, figures and comparison tables |

## How to run

E2 runs on its own Supabase project, never the app's project. Its connection string is set once in
`test_harness/e2_harness.py` (`DSN`), so every program below runs without asking. Each condition rebuilds the
database first, so no condition sees another one's data.

Run everything at once, from the repository root (`D:\fyp-combine\FYP-GeoLock_Hub`):
```powershell
python experiments/e2/run_e2.py
```

Or one step at a time, in this order:

1. Baseline 1, Non-Atomic Claim:
   ```powershell
   python experiments/e2/baseline/source_code/run_non_atomic_claim.py
   ```
2. Baseline 2, Protected Claim without Lease Recovery:
   ```powershell
   python experiments/e2/baseline/source_code/run_protected_claim_without_lease_recovery.py
   ```
3. Proposed method, Protected Claim with Lease Recovery:
   ```powershell
   python experiments/e2/protected_claim_with_lease_recovery/source_code/run_protected_claim_with_lease_recovery.py
   ```
4. Comparison (reads the three result folders and writes `experiment_result/`):
   ```powershell
   python experiments/e2/experiment_result/source_code/e2_compare.py
   ```

Each condition's numbers are saved in its own result folder before the next condition empties the database
(`details/requests.csv` has every request and its answer). The Supabase tables only keep the last condition you ran.

## Result files

Start with `experiment_result/comparison_summary.csv`: each baseline next to the proposed method on the part it tests.

| File | What it shows |
| --- | --- |
| `baseline/1_non_atomic_claim/results_per_scenario.csv` and the proposed `result/results_per_scenario.csv` | one row per contention trial: how many NGOs claimed, what they were told, how many claims were really saved and whether the trial ended with more than one owner |
| `baseline/2_protected_claim_without_lease_recovery/lease_results_per_scenario.csv` and the proposed `result/lease_results_per_scenario.csv` | one row per lease trial: whether the lease had expired, whether the second NGO got the donation and what happened to the first claim |
| `<condition>/details/requests.csv` | one row per claim request: the NGO, its answer, reason code and response time |
| `protected_claim_with_lease_recovery/result/geofence_check/` | the geofence decision for each of the 1,100 NGO and listing pairs |
| `protected_claim_with_lease_recovery/result/details/` | the extra checks: delayed request and two recovery jobs at once |
| `experiment_result/comparison_summary.csv` | one row per measure: part 1 compares baseline 1 with the proposed method, part 2 compares baseline 2 with the proposed method |
| `experiment_result/comparison_contention.csv` | one row per contention trial: baseline 1 and proposed next to each other |
| `experiment_result/comparison_lease.csv` | one row per lease trial: baseline 2 and proposed next to each other |
| `experiment_result/comparison_geofence.csv` | one row per geofence pair: the right answer, the decision and the direct claim result |
| `experiment_result/metrics.json` | every number in summary.md, with intervals and test results |
