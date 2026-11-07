# E4 executed results

Readiness: **PARTIAL for the unchanged original methodology; all 100 scenarios were executed.**

## Original baseline reproduction (500 tasks)

| method | scenarios | valid_tasks | served_tasks | distance_km | feasibility_pass |
|---|---|---|---|---|---|
| nearest_next | 100 | 500 | 453 | 3849.889 | 100 |
| fcfs | 100 | 500 | 453 | 4575.154 | 100 |

Both original methods reproduce all published non-runtime scenario fields exactly.

## Supplemental common-GeoLock-admission comparison (483 tasks)

| method | scenarios | valid_tasks | served_tasks | task_weighted_coverage_pct | mean_scenario_coverage_pct | distance_km | travel_min | route_duration_min | capacity_violations | window_violations | duration_violations | feasibility_pass | timeouts | median_planner_ms | p95_planner_ms |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| nearest_next | 100 | 483 | 437 | 90.476 | 90.75 | 3732.22677 | 4445.80953 | 8815.80953 | 0 | 0 | 0 | 100 | 0 | 0.2631 | 0.6956 |
| fcfs | 100 | 483 | 437 | 90.476 | 90.75 | 4429.11178 | 5152.83116 | 9522.83116 | 0 | 0 | 0 | 100 | 0 | 0.2594 | 0.679 |
| proposed | 100 | 483 | 439 | 90.89 | 91.15 | 3380.07299 | 4070.70276 | 8460.70276 | 0 | 0 | 0 | 100 | 0 | 107.1825 | 241.3605 |

The unchanged current worker admission excludes 17 supplied tasks whose listings expire before the full planning horizon. The existing adapter applies that same admission to both original algorithms and the actual optimizer. This is a clearly labelled supplemental lane, not an unchanged 500-task experiment or a new frozen dataset. All supplied rows remain in raw inputs/exclusion evidence.

## Distance on equal served-task counts only

| baseline | paired_scenarios | equal_served_task_count | coverage_differs | baseline_equal_coverage_km | proposed_equal_coverage_km | distance_reduction_pct | identical_served_task_sets | strict_baseline_km | strict_proposed_km | strict_distance_reduction_pct |
|---|---|---|---|---|---|---|---|---|---|---|
| nearest_next | 100 | 98 | 2 | 3708.81162 | 3341.30672 | 9.909 | 91 | 3457.59928 | 3140.2774 | 9.178 |
| fcfs | 100 | 98 | 2 | 4396.79341 | 3341.30672 | 24.006 | 79 | 3776.64111 | 2917.75813 | 22.742 |

All methods receive identical frozen input hashes in the supplemental lane. Equal counts do not guarantee identical served task identities; coverage differences and per-stop identities remain in raw outputs. The two coverage-different scenarios per comparison are excluded from distance aggregation. No all-scenario aggregate distance improvement is claimed. This single-run, synthetic-task benchmark does not prove end-to-end HTTP/DEV/driver performance or donor-window feasibility: the original baselines use the routing horizon as the time window. No formal significance test or supervisor approval is inferred.
