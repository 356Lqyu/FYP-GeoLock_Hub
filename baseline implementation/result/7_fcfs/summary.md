# First-Come-First-Served routing (baseline 7)

Benchmark GEOLOCK-BM-v3.2. This describes this method on its own; comparing methods is done in experiment E4.

**Method.** Vehicles are used one at a time in ascending vehicle ID. A vehicle always takes the earliest-confirmed task it can still legally add, whatever its distance; a task that does not fit is skipped, not allowed to block later tasks. When nothing fits, it returns to its depot.

| Result | Value | Meaning |
| --- | --- | --- |
| Scenarios | 100 | One NGO with its own vehicles and a set of pickups |
| Confirmed pickup tasks | 500 | Pickups the NGO legally holds (protected claim, inside its 20 km road geofence) |
| **Valid-task coverage** (main metric) | 454 of 500 (90.8%) | Share of valid confirmed tasks placed on a valid route |
| Unserved tasks | 46 | 44 FLEET_CAPACITY_OR_ROUTE_BUDGET_EXHAUSTED; 2 ROUTE_UNAVAILABLE |
| Excluded before planning | 0 | none |
| Total route distance | 4,802.7 km | Depot to pickups and back to the depot, all routes |
| Total travel time | 5,576 min | Driving only; service time (10 min per stop) is counted in route duration |
| Road distance per collected task | 10.58 km | Total distance / collected tasks |
| Pickup trips (vehicles used) | 122 of 150 available | Each vehicle makes at most one trip |
| Route duration | median 87.2 min (10th-90th percentile 26.8-127.8; max 172.4) | Driving + 10 min service per stop + return; limit 240 min |
| **Hard-constraint violations** | 0 (routes of all 100 scenarios pass) | Independent check: capacity, 240-min duration, lease, NGO ownership, road route, each task once |

## By scenario profile

| Profile | Scenarios | Tasks | Collected | Not collected | Road distance (km) | Trips |
| --- | --- | --- | --- | --- | --- | --- |
| CAPACITY_PRESSURE | 25 | 125 | 81 | 44 | 801.0 | 25 |
| CONNECTIVITY_STRESS | 25 | 125 | 125 | 0 | 1,320.5 | 37 |
| GEOGRAPHIC_SPREAD | 25 | 125 | 125 | 0 | 1,480.2 | 25 |
| NORMAL | 25 | 125 | 123 | 2 | 1,201.0 | 35 |

## Reason codes

| Code | Meaning |
| --- | --- |
| FLEET_CAPACITY_OR_ROUTE_BUDGET_EXHAUSTED | The task could be collected by an empty vehicle on its own, but every vehicle was already full or out of its 240-minute route time (each vehicle makes one trip). |
| ROUTE_UNAVAILABLE | No directed road route between the pickup point and a depot in the road matrix (the point is on a one-way road section), so no vehicle can collect it. |

## How the method works

1. Start from exactly the same planning snapshots as Nearest-Next (same pickups, vehicles and cutoff).
2. Take the vehicle with the lowest ID and start at its depot.
3. Among the pickups this vehicle can still legally add (capacity, 240 minutes with the return, lease), take the one that was confirmed earliest, wherever it is (ties: task ID). A pickup that does not fit is skipped for this vehicle; it does not block later pickups.
4. Repeat until nothing more fits, then drive back to the depot. Continue with the next vehicle.

## What to expect

- Serving requests in the order they arrive is the simplest dispatching rule. In the classic analysis of dynamic vehicle routing, first-come-first-served is studied as the basic policy, and distance-aware rules such as nearest-neighbour quickly do better once there is more than a trickle of requests, because FCFS ignores where the stops are [1].
- So FCFS is expected to zig-zag and drive more than a distance-aware rule on the same pickups, while collecting about the same number of them (the same capacity and time limits apply).

## How to read the results

- **Valid-task coverage** is the main metric: the share of the NGO's valid confirmed tasks that got onto a valid route. Tasks no vehicle can take are counted as **Unserved tasks**, each with a reason code (explained under Reason codes).
- **Total route distance** and **Total travel time** are what the NGO's vehicles drive. Lower is better, but distances are only comparable between methods with the same coverage, and only after the hard-constraint check passes.
- **Pickup trips** is how many vehicles were used; each vehicle drives at most one trip.
- **Route duration** includes driving, 10 minutes per stop and the drive back; every route must stay within 240 minutes.
- **Hard-constraint violations** must be 0. A separate check recomputes every route from the road matrix and stops the run if any rule is broken, so 0 means the plans are valid, not just plausible.
- In `details/routes.csv`, `stops_in_order` lists the stops in driving order. In `details/tasks.csv`, each task is SERVED (with vehicle and stop number), UNSERVED or EXCLUDED with its reason.

A spread such as "median 77.8 min (10th-90th percentile 29.2-117.7; max 144.1)" means: half of the routes are at or below the median; 8 in 10 lie between the two percentiles; max is the longest one.

## References

- [1] Bertsimas, D. J., & van Ryzin, G. (1991). A stochastic and dynamic vehicle routing problem in the Euclidean plane. *Operations Research*, 39(4), 601-615. https://doi.org/10.1287/opre.39.4.601 *(not yet in the report: add it if you cite it)*

## Files

| File | Content |
| --- | --- |
| `results_per_scenario.csv` | **The main result.** One row per scenario. |
| `details/routes.csv` | One row per vehicle trip: stops in driving order, load, distance, time. |
| `details/tasks.csv` | One row per pickup: SERVED (vehicle, stop number), UNSERVED or EXCLUDED with its reason. |
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
