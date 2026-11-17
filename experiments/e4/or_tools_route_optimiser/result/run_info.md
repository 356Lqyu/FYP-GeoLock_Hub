# Run information: OR-Tools route optimiser (proposed, current app)

| Item | Value |
| --- | --- |
| Run ID | 725519de6de948e6a60fb673f563dbe8 |
| Run at | 2026-11-17T14:00:26+08:00 |
| Scenarios | 100 ROUTE_PLANNING snapshots (sealed, shared by all E4 methods) |
| Method | backend.routing.optimizers.methods.proposed -> backend/routing/optimizers/cp_sat.py (Google OR-Tools CP-SAT; the same callable the routing worker uses) |
| Execution policy | ExecutionConfig(fixed_cost_weight=1.0, distance_cost_weight=1.0, deterministic_seconds_per_pass=0.25) |
| Settings | 240 minute route, 10 min per stop, 360 minute lease, fixed cost 5 + 1 per km |
| Validator | backend.routing.validator.validate_plan (independent recomputation) |
| OR-Tools | 9.15.6755 |
| Python | 3.13.9 |
