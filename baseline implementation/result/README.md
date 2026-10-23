# Baseline results (benchmark GEOLOCK-BM-v3.2)

## What is in each folder

Every folder has the same layout:

| File | What it is | Do you need it? |
| --- | --- | --- |
| `summary.md` | Plain-language report: key numbers, how the method works, what to expect, how to read it, column meanings | **Start here** |
| `results_per_scenario.csv` | **The main result**: one row per benchmark scenario, readable column names with units, YES/NO flags | **Yes** – the experiments use this file |
| `details/…` | Supporting evidence (full hub rankings, every route, every pickup, every claim request) | Only to check a specific case |
| `run_info.md` | When and how the run was made (benchmark, script fingerprint, database, command) | Only to repeat or audit the run |

| Folder | Baseline | Key result |
| --- | --- | --- |
| `1_nearest_hub/` | Nearest-Hub | 2,000 of 2,019 donations get a hub (19 have no feasible hub); median donor-to-hub distance 3.8 km |
| `2_random_hub/` | Random Hub | Same 2,000 / 19; median 14.7 km (as expected for a random feasible hub) |
| `ref_weighted_hub/` | Reference hub policy | Same 2,000 / 19; median 4.7 km. The target ranking for hub methods, not a competing baseline |
| `3_non_atomic_claim/` | Non-Atomic Claim | A duplicate owner in 150 of 150 trials (850 claims stored for 150 listings) |
| `4_protected_claim_without_lease_recovery/` | Protected Claim without Lease Recovery | Exactly 1 owner in 150 of 150 trials; 0 of 100 expired listings released; many deadlock errors with 5 or 10 NGOs |
| `5_direct_household_pickup/` | Direct Household Pickup | 417 of 417 donations collected, 2,780.7 km NGO distance, 100 trips, 0 km donor travel |
| `6_nearest_next/` | Nearest-Next routing | 457 of 500 tasks collected, 3,901.6 km, 122 trips |
| `7_fcfs/` | First-Come-First-Served routing | 454 of 500 tasks collected, 4,802.7 km, 122 trips |

All hub choices, routes and pickups were recomputed by a separate checker from the raw
benchmark tables (0 differences); the claim results were checked against the claims stored
in the database. Python results are identical on every run. Claim results depend on timing:
the error counts and response times change a little between runs, the ownership results do
not.

## How to run the experiments once the proposed system is complete

The rule is the same for every experiment:

1. **Run the proposed method on the same scenarios** as the baseline (same `scenario_id`s).
2. **Save its result in the same format** as the baseline's `results_per_scenario.csv`:
   same column names, one row per `scenario_id`. Put it in the experiment folder, e.g.
   `experiments/e2_claim/proposed/results_per_scenario.csv`.
3. **Pair the rows by `scenario_id`** and compute the metric below for each method from
   the same columns. Because both files have the same columns, the comparison is a simple
   join; nothing in the baseline files has to be recomputed.
4. For paired YES/NO outcomes use McNemar's exact test; for paired numbers use the
   Wilcoxon signed-rank test, and report the median paired difference.

### E1 – hub recommendation (AI ranking)

| | |
| --- | --- |
| Scenarios | The frozen test split `ai hub ranking/data split/split/test_scenario_ids.csv` (337 scenarios; see `ai hub ranking/README.md`) |
| Baseline files | `1_nearest_hub/`, `2_random_hub/` and the target `ref_weighted_hub/` – `results_per_scenario.csv` |
| Proposed output | Same columns as the hub file: `scenario_id, donation_id, status, feasible_hubs, recommended_hub, distance_to_recommended_hub_km, second_hub, third_hub` (and the full order in `details/hub_ranking.csv` for NDCG) |
| Top-1 agreement (main) | share of scenarios where `recommended_hub` = the reference's `recommended_hub` |
| Top-3 coverage | share where the reference's `recommended_hub` is one of `recommended_hub, second_hub, third_hub` |
| NDCG@3 | from `details/hub_ranking.csv`, with relevance taken from the reference ranking |
| Current baseline values (test split) | Nearest-Hub: Top-1 46.3%, Top-3 coverage 85.2%. Random: Top-1 3.3%, Top-3 coverage 17.5% |

### E2 – claim safety and lease recovery

| | |
| --- | --- |
| Scenarios | All CLAIM_COORDINATION, LEASE_RECOVERY and LEASE_ACTIVE_VERIFICATION scenarios |
| Baseline files | `3_non_atomic_claim/results_per_scenario.csv`; `4_protected_claim_without_lease_recovery/results_per_scenario.csv` and `lease_results_per_scenario.csv` |
| Proposed method | The protected claim **with** lease recovery: the same procedure as baseline 4, but `public.recover_expired_claims()` runs before the second NGO tries. The easiest way is a copy of `protected_claim_without_lease_recovery_baseline.py` that makes this one extra call; it then writes the same two files |
| Duplicate committed-claim rate (main) | share of rows in `results_per_scenario.csv` with `more_than_one_owner` = YES. Baseline 3: 100%. Must be 0% |
| Lease recovery success | in `lease_results_per_scenario.csv`, among rows with `case` = "lease expired": share with `second_ngo_got_listing` = YES. Baseline 4: 0% |
| Safety check | rows with `case` = "lease still running" must keep `second_ngo_got_listing` = NO |
| Supporting | `failed_with_error`, `median_response_ms` (run baselines and proposed on the same database type) |

### E3 – community-hub aggregation

| | |
| --- | --- |
| Scenarios | All HUB_AGGREGATION scenarios (100) |
| Baseline file | `5_direct_household_pickup/results_per_scenario.csv` |
| Proposed output | Same columns: `scenario_id, ngo_id, vehicles_available, donations, donations_collected, coverage_percent, total_ngo_distance_km, total_driving_time_min, vehicle_trips, donor_travel_km, benchmark_cost, cost_per_donation, longest_route_min, all_rules_passed, planning_time_ms`. Here `donor_travel_km` is the donors' road distance to the hub, and `benchmark_cost` adds 0.50 per donation handled at the hub |
| NGO road distance (main) | paired difference of `total_ngo_distance_km` per scenario |
| Supporting | `vehicle_trips`, `donor_travel_km` (the burden moved to donors), `benchmark_cost`, `cost_per_donation` |
| Required | same `ngo_id` and fleet as the baseline; `all_rules_passed` = YES |

### E4 – route planning (optimiser)

| | |
| --- | --- |
| Scenarios | All ROUTE_PLANNING scenarios (100) |
| Baseline files | `6_nearest_next/results_per_scenario.csv`, `7_fcfs/results_per_scenario.csv` |
| Planning input | `6_nearest_next/details/planning_snapshots.json` – the optimiser must plan on exactly these pickups and vehicles |
| Proposed output | Same columns as the route file: `scenario_id, scenario_profile, ngo_id, vehicles_available, tasks_valid, tasks_collected, tasks_not_collected, tasks_excluded, coverage_percent, total_distance_km, total_driving_time_min, vehicle_trips, longest_route_min, all_rules_passed, planning_time_ms` |
| Valid-task coverage (main) | `coverage_percent` per scenario (paired) |
| Distance | compare `total_distance_km` only where both methods collected the same number of tasks, and only if `all_rules_passed` = YES |
| Supporting | `total_driving_time_min`, `vehicle_trips`, `tasks_not_collected` by profile |

## How these results were produced

See `../source code/README.md` (how to run each script) and `../postgresql/README.md`
(database for baselines 3 and 4).
