# Direct Household Pickup (baseline 5)

Benchmark GEOLOCK-BM-v3.3.

## What this baseline does

No community hub. The NGO claims every original small donation of the aggregation scenario and collects each one from the donor's home, using the Nearest-Next routing rule and the same NGO fleet that the hub condition will use in E3.

## Compared with (experiment E3, RQ3)

| | This baseline | Proposed method (E3) |
| --- | --- | --- |
| Collection | every small donation picked up at the donor's home | donations dropped at the community hub, batched (3-5 items, <= 30 kg), one pickup per batch |
| Same inputs | | same 100 aggregation scenarios, original donations, NGO, fleet, depot, road matrix, Nearest-Next routing, 240-min route limit, 10 min per stop |

Pair the files by `scenario_id`. Main metric: **total NGO road distance** (paired difference). Also compare pickup trips, **donor travel burden** (km donors drive to the hub; 0 here) and the benchmark cost (1.00 x NGO km + 5.00 x trips + 0.50 per donation handled at a hub), so a lower NGO distance cannot hide travel moved onto donors (report Section 3.8.2).

## Results

| Result | Value | Meaning |
| --- | --- | --- |
| Scenarios | 100 | One NGO with its own vehicles and a set of pickups |
| Original donations | 424 | Every small donation (< 10 kg) of the aggregation scenario, each picked up at the donor's home |
| Collected | 424 of 424 (100.0%) | Assigned to a valid route |
| **Total NGO road distance** (main metric) | 2,617.7 km | Depot to every household and back, all routes |
| Pickup trips (NGO dispatches) | 100 of 200 vehicles available | Each vehicle makes at most one trip |
| Donor travel burden | 0 km | Donors stay at home in this condition |
| Calculated benchmark cost | 3,117.7 units | 1.00 x NGO km + 5.00 x trips; a benchmark index, not real money |
| Calculated cost per original donation | 7.35 units | Cost / donations |
| NGO road distance per donation | 6.17 km | Total distance / donations |
| Route duration | median 75.9 min (10th-90th percentile 51.2-96.6; max 111.1) | Driving + 10 min service per stop + return; limit 240 min |
| **Hard-constraint violations** | 0 (routes of all 100 scenarios pass) | Independent check: capacity, 240-min duration, lease, NGO ownership, road route, each task once |

## How the method works

1. Each HUB_AGGREGATION scenario holds 3-5 small donations (< 10 kg) from nearby households that the proposed system would bring together at a community hub.
2. Here there is no hub: the NGO claims every donation itself, and each one becomes a pickup at the donor's home.
3. The NGO's vehicles collect them with the Nearest-Next rule (nearest legal pickup next, one trip per vehicle, 240 minutes, capacity, lease), using the same NGO and fleet as the hub condition in E3.

## What to expect

- Collecting at every household means one stop per donation, so the NGO's driving grows with the number of donations. Pickup-point and alternative-delivery-location studies show that consolidating items at a shared point can cut travel for one party, but the benefit depends on participation, capacity and routing, and part of the travel moves to the people who bring items to the point [1, 2, 3].
- Example from a UK case study: collection points reduced total vehicle travel from 1,846 km to 940-1,246 km when 30% of first home deliveries failed, but with few failures overall travel could even rise (by 10.9% in one case) [4].
- So this baseline gives the NGO side of the no-hub option, with zero donor travel. E3 then checks whether the hub condition lowers NGO distance and how much donor travel it adds.

## How to read the results

- **Total NGO road distance** is the main metric. E3 compares it with the hub condition on the same scenarios, NGO, fleet and routing rule.
- **Donor travel burden** is 0 here. In the hub condition donors take their items to the hub, so E3 reports that distance next to the NGO distance (burden transfer).
- **Pickup trips** counts NGO dispatches; each vehicle makes at most one trip.
- **Calculated benchmark cost** = 1.00 x NGO km + 5.00 x trips. It is supporting evidence only, not real money; the hub condition also adds 0.50 per donation handled at a hub.
- **Hard-constraint violations** must be 0: every route was re-checked independently.
- In `details/routes.csv`, `stops_in_order` lists the households in driving order; `details/tasks.csv` shows the vehicle and stop number of each donation.

A spread such as "median 77.8 min (10th-90th percentile 29.2-117.7; max 144.1)" means: half of the routes are at or below the median; 8 in 10 lie between the two percentiles; max is the longest one.

## References

- [1] Galiullina, A., Mutlu, N. R., Kinable, J., & van Woensel, T. (2024). Demand steering in a last-mile delivery problem with home and pickup point delivery options. *Transportation Science*, 58(2), 454-473. https://doi.org/10.1287/trsc.2023.0287 *(in the report reference list)*
- [2] Mo, Y., Yang, K., Han, S., & Gupta, S. (2024). Multi-period heterogeneous fleet vehicle routing problem with self-pickup point selection: A last-mile delivery scenario in urban and rural areas. *Annals of Operations Research*. https://doi.org/10.1007/s10479-024-06011-7 *(in the report reference list)*
- [3] Pourmohammadreza, N., Akbari Jokar, M. R., & Van Woensel, T. (2025). Last-mile logistics with alternative delivery locations: A systematic literature review. *Results in Engineering*, 25, 104085. https://doi.org/10.1016/j.rineng.2025.104085 *(in the report reference list)*
- [4] Song, L., Cherrett, T., McLeod, F., & Guan, W. (2009). Addressing the last mile problem: Transport impacts of collection and delivery points. *Transportation Research Record*, 2097. https://doi.org/10.3141/2097-02 *(not yet in the report: add it if you cite it)*

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
| `scenario_id` | Benchmark aggregation scenario (3-5 small donations from nearby households) |
| `ngo_id` | The NGO that collects them |
| `vehicles_available` | Vehicles of that NGO |
| `donations` | Small donations to collect |
| `donations_collected` | Donations placed on a valid route |
| `coverage_percent` | donations_collected / donations x 100 |
| `total_ngo_distance_km` | Road distance driven by the NGO's vehicles (depot - homes - depot) |
| `total_driving_time_min` | Driving time only (service time not included) |
| `vehicle_trips` | Vehicles used (each makes at most one trip) |
| `donor_travel_km` | Distance donors travel; always 0 here because the NGO comes to their home |
| `benchmark_cost` | 1.00 x NGO km + 5.00 x trips (benchmark cost index, not real money) |
| `cost_per_donation` | benchmark_cost / donations |
| `longest_route_min` | Longest vehicle route, including 10 min per stop; must be <= 240 |
| `all_rules_passed` | YES if every route passed the independent check (capacity, 240 min, lease, road route) |
| `planning_time_ms` | Computer time to plan the routes (varies between computers) |
