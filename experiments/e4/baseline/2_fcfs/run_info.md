# Run information: First come first served, FCFS (baseline 2)

| Item | Value |
| --- | --- |
| Run ID | 4b03c152c6224c9fa5f3321fc8d31d78 |
| Run at | 2026-11-10T21:52:40+08:00 |
| Scenarios | 100 ROUTE_PLANNING snapshots (sealed, shared by all E4 methods) |
| Method | its own plan_routes(): each vehicle in turn takes pickups in the order they were claimed |
| Execution policy | ExecutionConfig(fixed_cost_weight=1.0, distance_cost_weight=1.0, deterministic_seconds_per_pass=0.25) |
| Settings | 240 minute route, 10 min per stop, 360 minute lease, fixed cost 5 + 1 per km |
| Validator | backend.routing.phase_b.validate_plan (independent recomputation) |
| Python | 3.13.9 |
