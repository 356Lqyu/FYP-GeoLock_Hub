# E4 executed results

Readiness: **PASS for the recorded corrected E4 run** when all 300 plans independently validate and no evaluation errors are present; this is not evidence of operational DEV integration.

## Original baseline reproduction (500 tasks)

| method | scenarios | valid_tasks | served_tasks | distance_km | feasibility_pass |
|---|---|---|---|---|---|
| nearest_next | 100 | 500 | 453 | 3849.889 | 100 |
| fcfs | 100 | 500 | 453 | 4575.154 | 100 |

Both original methods reproduce all published non-runtime scenario fields exactly.

## Corrected common-admission comparison (500 admitted of 500 candidates)

| method | scenarios | successful_plans | failed_or_invalid | timed_plans | valid_tasks | served_tasks | task_weighted_coverage_pct | mean_scenario_coverage_pct | distance_km | travel_min | route_duration_min | capacity_violations | window_violations | duration_violations | feasibility_pass | timeouts | vehicle_opportunities_used | vehicle_opportunities_available | plan_status_counts | solver_pass_status_counts | median_method_reported_runtime_ms | p95_method_reported_runtime_ms | median_solver_ms | p95_solver_ms | median_method_pipeline_wall_ms | p95_method_pipeline_wall_ms | median_end_to_end_evaluation_ms | p95_end_to_end_evaluation_ms |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| nearest_next | 100 | 100 | 0 | 100 | 500 | 453 | 90.6 | 90.6 | 3849.88966 | 4578.58029 | 9108.58029 | 0 | 0 | 0 | 100 | 0 | 116 | 150 | {"COMPLETE": 73, "PARTIAL": 27} | {} | 0.2286 | 0.364 | 0.0 | 0.0 | 4.0582 | 6.2645 | 7.4624 | 11.903 |
| fcfs | 100 | 100 | 0 | 100 | 500 | 453 | 90.6 | 90.6 | 4575.15709 | 5307.49304 | 9837.49304 | 0 | 0 | 0 | 100 | 0 | 116 | 150 | {"COMPLETE": 73, "PARTIAL": 27} | {} | 0.2173 | 0.3492 | 0.0 | 0.0 | 4.0346 | 6.2574 | 7.4235 | 11.307 |
| proposed | 100 | 100 | 0 | 100 | 500 | 455 | 91.0 | 91.0 | 3462.21381 | 4163.537 | 8713.537 | 0 | 0 | 0 | 100 | 0 | 100 | 150 | {"COMPLETE": 73, "PARTIAL": 27} | {"OPTIMAL": 200} | 71.4326 | 175.58 | 61.5596 | 153.9195 | 71.6376 | 175.9254 | 76.8325 | 182.7361 |

The E4-only adapter treats synthetic listing expiry timestamps as NULL. This run recorded 0 admission exclusions; the shared operational contract and independent validator remain unchanged. All supplied candidates and exclusion evidence remain in the raw inputs. The original 500-task benchmark inputs were not regenerated or modified.

## Distance on equal served-task counts only

| baseline | paired_scenarios | equal_served_task_count | coverage_differs | baseline_equal_coverage_km | proposed_equal_coverage_km | distance_reduction_pct | identical_served_task_sets | strict_baseline_km | strict_proposed_km | strict_distance_reduction_pct |
|---|---|---|---|---|---|---|---|---|---|---|
| nearest_next | 100 | 98 | 2 | 3826.47451 | 3423.44754 | 10.533 | 91 | 3575.26217 | 3222.41822 | 9.869 |
| fcfs | 100 | 98 | 2 | 4542.83872 | 3423.44754 | 24.641 | 79 | 3931.22055 | 3003.34604 | 23.603 |

All three methods receive the same 500 admitted task IDs and common frozen snapshot per scenario. Served-task identity sets differ in 9 scenarios versus Nearest-Next and 21 versus FCFS; paired distance and driving-time inference is restricted to the identical served-task sets (91 and 79 scenario pairs). Aggregate distance totals are descriptive and are not an all-scenario paired comparison. Newly calculated E4-only paired tests, Hodges-Lehmann effects, bootstrap intervals and Holm adjustments are in `statistical_analysis/paired_tests.csv`; do not reuse inferential results from the former 483-task run. This single-run synthetic benchmark does not establish end-to-end HTTP/DEV/driver performance or donor-window feasibility.
