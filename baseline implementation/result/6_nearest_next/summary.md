# Nearest-Next routing (baseline 6)

Benchmark GEOLOCK-BM-v3.2. This describes this method on its own; comparing methods is done in experiment E4.

**Method.** Vehicles are used one at a time in ascending vehicle ID. From the current position, a vehicle drives to the nearest (road distance) confirmed task it can still legally add; when no task fits, it returns to its depot and the next vehicle starts.

| Result | Value | Meaning |
| --- | --- | --- |
| Scenarios | 100 | One NGO with its own vehicles and a set of pickups |
| Confirmed pickup tasks | 500 | Pickups the NGO legally holds (protected claim, inside its 20 km road geofence) |
| **Valid-task coverage** (main metric) | 457 of 500 (91.4%) | Share of valid confirmed tasks placed on a valid route |
| Unserved tasks | 43 | 41 FLEET_CAPACITY_OR_ROUTE_BUDGET_EXHAUSTED; 2 ROUTE_UNAVAILABLE |
| Excluded before planning | 0 | none |
| Total route distance | 3,901.6 km | Depot to pickups and back to the depot, all routes |
| Total travel time | 4,616 min | Driving only; service time (10 min per stop) is counted in route duration |
| Road distance per collected task | 8.54 km | Total distance / collected tasks |
| Pickup trips (vehicles used) | 122 of 150 available | Each vehicle makes at most one trip |
| Route duration | median 77.8 min (10th-90th percentile 29.2-117.7; max 144.1) | Driving + 10 min service per stop + return; limit 240 min |
| **Hard-constraint violations** | 0 (routes of all 100 scenarios pass) | Independent check: capacity, 240-min duration, lease, NGO ownership, road route, each task once |

## By scenario profile

| Profile | Scenarios | Tasks | Collected | Not collected | Road distance (km) | Trips |
| --- | --- | --- | --- | --- | --- | --- |
| CAPACITY_PRESSURE | 25 | 125 | 84 | 41 | 584.3 | 25 |
| CONNECTIVITY_STRESS | 25 | 125 | 125 | 0 | 1,117.4 | 37 |
| GEOGRAPHIC_SPREAD | 25 | 125 | 125 | 0 | 1,191.5 | 25 |
| NORMAL | 25 | 125 | 123 | 2 | 1,008.4 | 35 |

## Reason codes

| Code | Meaning |
| --- | --- |
| FLEET_CAPACITY_OR_ROUTE_BUDGET_EXHAUSTED | The task could be collected by an empty vehicle on its own, but every vehicle was already full or out of its 240-minute route time (each vehicle makes one trip). |
| ROUTE_UNAVAILABLE | No directed road route between the pickup point and a depot in the road matrix (the point is on a one-way road section), so no vehicle can collect it. |

## How the method works

1. Start from the scenario's sealed planning snapshot: the NGO's confirmed pickups (its protected claims) and its vehicles at the cutoff time.
2. Take the vehicle with the lowest ID and start at its depot.
3. Among the pickups this vehicle can still legally add (load within capacity, back at the depot within 240 minutes, claim lease still valid), drive to the one with the shortest road distance from where the vehicle is now (ties: task ID).
4. Repeat until nothing more fits, then drive back to the depot. Continue with the next vehicle.
5. Pickups that no vehicle could take are reported as not collected, with the reason.

## What to expect

- Nearest-neighbour is the classic greedy route-building rule [1]: fast and simple, but not optimal. On large random travelling-salesman instances its tours average about 24-26% longer than a near-optimal lower bound [2]; in the worst case the gap grows with the number of stops [1]. With 5 pickups per scenario the gap is usually smaller.
- So a route optimiser (the proposed method, experiment E4) is expected to drive less for the same pickups, and this baseline is the standard yardstick for that.
- Food-rescue and food-bank studies treat collection as vehicle routing with capacity, timing and route limits [3, 4]; this baseline keeps the same kind of limits but builds each route greedily.
- The CAPACITY_PRESSURE profile deliberately has more weight than the vehicles can carry in one trip, so some pickups there cannot be collected by any method.

## How to read the results

- **Valid-task coverage** is the main metric: the share of the NGO's valid confirmed tasks that got onto a valid route. Tasks no vehicle can take are counted as **Unserved tasks**, each with a reason code (explained under Reason codes).
- **Total route distance** and **Total travel time** are what the NGO's vehicles drive. Lower is better, but distances are only comparable between methods with the same coverage, and only after the hard-constraint check passes.
- **Pickup trips** is how many vehicles were used; each vehicle drives at most one trip.
- **Route duration** includes driving, 10 minutes per stop and the drive back; every route must stay within 240 minutes.
- **Hard-constraint violations** must be 0. A separate check recomputes every route from the road matrix and stops the run if any rule is broken, so 0 means the plans are valid, not just plausible.
- In `details/routes.csv`, `stops_in_order` lists the stops in driving order. In `details/tasks.csv`, each task is SERVED (with vehicle and stop number), UNSERVED or EXCLUDED with its reason.

A spread such as "median 77.8 min (10th-90th percentile 29.2-117.7; max 144.1)" means: half of the routes are at or below the median; 8 in 10 lie between the two percentiles; max is the longest one.

## References

- [1] Rosenkrantz, D. J., Stearns, R. E., & Lewis, P. M. (1977). An analysis of several heuristics for the traveling salesman problem. *SIAM Journal on Computing*, 6(3), 563-581. https://doi.org/10.1137/0206041 *(not yet in the report: add it if you cite it)*
- [2] Johnson, D. S., & McGeoch, L. A. (1997). The traveling salesman problem: A case study in local optimization. In E. H. L. Aarts & J. K. Lenstra (Eds.), *Local Search in Combinatorial Optimization* (pp. 215-310). Wiley. *(not yet in the report: add it if you cite it)*
- [3] Nair, D. J., Grzybowska, H., Fu, Y., & Dixit, V. V. (2018). Scheduling and routing models for food rescue and delivery operations. *Socio-Economic Planning Sciences*, 63, 18-32. https://doi.org/10.1016/j.seps.2017.06.003 *(in the report reference list)*
- [4] Reusken, M., Laporte, G., Rohmer, S. U. K., & Cruijssen, F. (2024). Vehicle routing with stochastic demand, service and waiting times: The case of food bank collection problems. *European Journal of Operational Research*, 317(1), 111-127. https://doi.org/10.1016/j.ejor.2024.03.031 *(in the report reference list)*

## Files

| File | Content |
| --- | --- |
| `results_per_scenario.csv` | **The main result.** One row per scenario. |
| `details/routes.csv` | One row per vehicle trip: stops in driving order, load, distance, time. |
| `details/tasks.csv` | One row per pickup: SERVED (vehicle, stop number), UNSERVED or EXCLUDED with its reason. |
| `details/planning_snapshots.json` | The exact planning input of every scenario (pickups, vehicles, cutoff time). A route optimiser can plan on this same file with --snapshot-file. |
| `run_info.md` | What produced this run (date, benchmark, script fingerprint, command). |

### Columns of results_per_scenario.csv

| Column | Meaning |
| --- | --- |
| `scenario_id` | Benchmark route scenario (one NGO, its vehicles and its claimed pickups) |
| `scenario_profile` | NORMAL, CAPACITY_PRESSURE, GEOGRAPHIC_SPREAD or CONNECTIVITY_STRESS |
| `ngo_id` | The NGO |
| `vehicles_available` | Vehicles of that NGO |
| `tasks_valid` | Confirmed pickups the NGO legally holds |
| `tasks_collected` | Pickups placed on a valid route |
| `tasks_not_collected` | Pickups no vehicle could take (reason in details/tasks.csv) |
| `tasks_excluded` | Pickups removed before planning (outside geofence or expired) |
| `coverage_percent` | tasks_collected / tasks_valid x 100 |
| `total_distance_km` | Road distance driven by all vehicles (depot - pickups - depot) |
| `total_driving_time_min` | Driving time only (service time not included) |
| `vehicle_trips` | Vehicles used (each makes at most one trip) |
| `longest_route_min` | Longest vehicle route, including 10 min per stop; must be <= 240 |
| `all_rules_passed` | YES if every route passed the independent check (capacity, 240 min, lease, road route) |
| `planning_time_ms` | Computer time to plan the routes (varies between computers) |
