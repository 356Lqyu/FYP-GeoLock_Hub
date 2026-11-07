# Full Phase B Synthetic Scenario Review

Each cell is served/unserved; km; configured weighted cost; status. All are synthetic.
Infeasible/blocked rows are not objective-dominance comparisons.

| Scenario | Admitted | FCFS | Nearest-neighbour | Distance-only | Proposed |
|---|---:|---|---|---|---|
| phase_a/direct_only | 1 | 1/0; 4.5; 9.5; COMPLETE | 1/0; 4.5; 9.5; COMPLETE | 1/0; 4.5; 9.5; COMPLETE | 1/0; 4.5; 9.5; COMPLETE |
| phase_a/expired_claim | 0 | 0/0; 0; 0; NO_VALID_TASKS | 0/0; 0; 0; NO_VALID_TASKS | 0/0; 0; 0; NO_VALID_TASKS | 0/0; 0; 0; NO_VALID_TASKS |
| phase_a/hub_only | 1 | 1/0; 11; 16; COMPLETE | 1/0; 11; 16; COMPLETE | 1/0; 11; 16; COMPLETE | 1/0; 11; 16; COMPLETE |
| phase_a/missing_edge | 2 | 0/2; 0; 0; ROUTE_UNAVAILABLE | 0/2; 0; 0; ROUTE_UNAVAILABLE | 0/2; 0; 0; ROUTE_UNAVAILABLE | 0/2; 0; 0; ROUTE_UNAVAILABLE |
| phase_a/mixed | 2 | 2/0; 15.5; 30.7; COMPLETE | 2/0; 15.5; 30.7; COMPLETE | 2/0; 11; 21.2; COMPLETE | 2/0; 11; 21.2; COMPLETE |
| phase_a/no_tasks | 0 | 0/0; 0; 0; NO_VALID_TASKS | 0/0; 0; 0; NO_VALID_TASKS | 0/0; 0; 0; NO_VALID_TASKS | 0/0; 0; 0; NO_VALID_TASKS |
| phase_a/no_vehicles | 2 | 0/2; 0; 0; NO_FEASIBLE_PLAN | 0/2; 0; 0; NO_FEASIBLE_PLAN | 0/2; 0; 0; NO_FEASIBLE_PLAN | 0/2; 0; 0; NO_FEASIBLE_PLAN |
| phase_a/reconciliation | 0 | 0/0; 0; 0; NO_VALID_TASKS | 0/0; 0; 0; NO_VALID_TASKS | 0/0; 0; 0; NO_VALID_TASKS | 0/0; 0; 0; NO_VALID_TASKS |
| phase_a/unreachable | 2 | 0/2; 0; 0; ROUTE_UNAVAILABLE | 0/2; 0; 0; ROUTE_UNAVAILABLE | 0/2; 0; 0; ROUTE_UNAVAILABLE | 0/2; 0; 0; ROUTE_UNAVAILABLE |
| phase_b/capacity_infeasible | 2 | 1/1; 11; 16; INFEASIBLE | 1/1; 11; 16; INFEASIBLE | 0/2; 0; 0; INFEASIBLE | 0/2; 0; 0; INFEASIBLE |
| phase_b/colocated_tasks | 2 | 2/0; 9; 22.9; COMPLETE | 2/0; 9; 22.9; COMPLETE | 2/0; 4.5; 13.4; COMPLETE | 2/0; 4.5; 13.4; COMPLETE |
| phase_b/cost_tradeoff | 2 | 2/0; 11; 111; COMPLETE | 2/0; 11; 111; COMPLETE | 2/0; 11; 111; COMPLETE | 2/0; 15.5; 17.5; COMPLETE |
| phase_b/duration_infeasible | 2 | 0/2; 0; 0; INFEASIBLE | 0/2; 0; 0; INFEASIBLE | 0/2; 0; 0; INFEASIBLE | 0/2; 0; 0; INFEASIBLE |
| phase_b/exact_duration | 1 | 1/0; 4.5; 9.5; COMPLETE | 1/0; 4.5; 9.5; COMPLETE | 1/0; 4.5; 9.5; COMPLETE | 1/0; 4.5; 9.5; COMPLETE |
| phase_b/no_return_arc | 2 | 0/2; 0; 0; INFEASIBLE | 0/2; 0; 0; INFEASIBLE | 0/2; 0; 0; INFEASIBLE | 0/2; 0; 0; INFEASIBLE |
| phase_b/primary_over_cost | 2 | 2/0; 11; 1.00001e+06; COMPLETE | 2/0; 11; 1.00001e+06; COMPLETE | 2/0; 11; 1.00001e+06; COMPLETE | 2/0; 11; 1.00001e+06; COMPLETE |
| phase_b/unreachable_forbid | 2 | 1/1; 4.5; 9.5; INFEASIBLE | 1/1; 4.5; 9.5; INFEASIBLE | 0/2; 0; 0; INFEASIBLE | 0/2; 0; 0; INFEASIBLE |
| phase_b/unreachable_optional | 2 | 1/1; 4.5; 9.5; PARTIAL | 1/1; 4.5; 9.5; PARTIAL | 1/1; 4.5; 13.4; PARTIAL | 1/1; 4.5; 9.5; PARTIAL |
| phase_b/urgent_hub_optional | 2 | 1/1; 4.5; 9.5; PARTIAL | 1/1; 4.5; 9.5; PARTIAL | 2/0; 11; 16; COMPLETE | 2/0; 11; 16; COMPLETE |
| phase_b/waiting | 1 | 1/0; 4.5; 9.5; COMPLETE | 1/0; 4.5; 9.5; COMPLETE | 1/0; 4.5; 9.5; COMPLETE | 1/0; 4.5; 9.5; COMPLETE |
| phase_b/window_infeasible | 1 | 0/1; 0; 0; INFEASIBLE | 0/1; 0; 0; INFEASIBLE | 0/1; 0; 0; INFEASIBLE | 0/1; 0; 0; INFEASIBLE |
