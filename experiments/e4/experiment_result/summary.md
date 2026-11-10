# E4 result: OR-Tools route optimiser vs simple routing rules

## What we wanted to find out

After an NGO has claimed several donations, it has to decide which vehicle picks up which donation and in what order. The GeoLock routing worker (Python backend called by the Flutter app) plans this with Google OR-Tools. We wanted to know whether the OR-Tools optimiser serves more of the pickups than simple rules do, and, when they serve the same pickups, whether it drives less.

## What we used

- **Data:** the frozen benchmark dataset GEOLOCK-BENCHMARK-DATASET: 100 route planning scenarios. Each has 5 claimed donations of one NGO and its two vehicles (a 100 kg car and a 500 kg van). After the app's admission checks, 483 of the 500 pickups were valid to plan; every method received exactly the same valid pickups.
- **Nearest-Next (baseline 1):** each vehicle in turn keeps driving to the closest pickup it can still fit and finish in time.
- **First come first served (baseline 2):** each vehicle takes pickups in the order they were claimed.
- **OR-Tools route optimiser (proposed):** the app's routing code, used without any change (`backend/routing/optimizers/cp_sat.py`, Google OR-Tools CP-SAT solver, the same function the routing worker calls). It first serves as many pickups as possible, then chooses the shortest total road distance.
- **Same rules for all:** each vehicle starts and ends at the NGO depot, carries at most its capacity, and finishes within 240 minutes (driving + 10 minutes per stop). Every plan was checked again by an independent validator.

## Results

The main numbers are also in `comparison_summary.csv`, one row per measure with every method side by side.

| Method | Plans passing the independent check | Pickups served | Scenarios with every pickup served | Total km | km per pickup served |
| --- | --- | --- | --- | --- | --- |
| **OR-Tools route optimiser (proposed)** | 100 of 100 | 439 of 483 (90.9%) | 73 of 100 | 3,380 | 7.70 |
| Nearest-Next (baseline 1) | 100 of 100 | 437 of 483 (90.5%) | 73 of 100 | 3,732 | 8.54 |
| First come first served (baseline 2) | 100 of 100 | 437 of 483 (90.5%) | 73 of 100 | 4,429 | 10.14 |

| Method | Vehicles used | Capacity, duration or time window violations | Solver timeouts | Median planning time |
| --- | --- | --- | --- | --- |
| OR-Tools route optimiser (proposed) | 100 | 0 | 0 | 16 ms |
| Nearest-Next (baseline 1) | 115 | 0 | 0 | 1 ms |
| FCFS (baseline 2) | 115 | 0 | 0 | 1 ms |

Where OR-Tools and the baseline served the same number of pickups (98 scenarios for Nearest-Next, 98 for first come first served):

| Comparison | OR-Tools km | Baseline km | OR-Tools shorter / equal / longer |
| --- | --- | --- | --- |
| vs Nearest-Next | 3,341 | 3,709 | 85 / 13 / 0 |
| vs First come first served | 3,341 | 4,397 | 93 / 5 / 0 |

![Figure 1](e4_fig1_tasks_served.png)

*Figure 1. Share of the 483 valid pickups placed on a valid route. Error bars show 95 % Wilson confidence intervals.*

![Figure 2](e4_fig2_km_per_scenario.png)

*Figure 2. Route distance per scenario for OR-Tools and Nearest-Next, in the scenarios where both serve the same number of pickups. Points below the dashed line are scenarios where OR-Tools drives less.*

![Figure 3](e4_fig3_total_km.png)

*Figure 3. Total route distance of OR-Tools and each baseline over the scenarios where both serve the same number of pickups.*

## Analysis

**All plans are valid.** All 300 plans (100 scenarios × 3 methods) passed the independent check: no vehicle was overloaded, no route ran over 240 minutes, and every pickup was either served exactly once or reported as unserved. So the comparison below is between valid plans only.

**OR-Tools serves the most pickups.** It placed 439 of 483 valid pickups on a route, against 437 for both simple rules. It served more than Nearest-Next in 2 scenarios and never fewer. For each scenario OR-Tools also proved that no plan could serve more pickups (100 of 100), so the 44 pickups it left out could not fit on any valid plan with these two vehicles (one trip each, capacity, 240 minutes). The gap is small because each scenario has only 5 pickups, so the simple rules already serve almost everything they can.

**Why the two simple rules serve the same number of pickups.** They are different methods and gave different plans: their routes differed in 100 of 100 scenarios, their distance in 97 and even the set of pickups they served in 23. Only the count was the same, in 100 of 100 scenarios. Both fill one vehicle and then the other, adding pickups until none fits any more, and what stops them is the same in both: of the 46 pickups Nearest-Next left out, 44 still fitted by weight, so the limit was the 240 minute route time, and 2 had no direct road route from the depot in the benchmark matrix. With only 5 pickups per scenario, the order of the stops changed which far pickup was dropped, but not how many.

**OR-Tools drives clearly less.** Where both served the same pickups, OR-Tools drove 3,341 km instead of 3,709 km with Nearest-Next (9.9 % less). It was shorter in 85 scenarios, equal in 13 (where the nearest first order was already the best), and never longer. The typical saving is 2.9 km per scenario (95 % confidence interval 2.1 to 3.7 km; Wilcoxon signed rank test p = 3e-17), and driving time falls by about 2.8 minutes per scenario.

**Why:** Nearest-Next always takes the closest next stop, which can leave a far away pickup for the end and force a long drive back to the depot. OR-Tools looks at the whole route at once and can choose a slightly longer step early to save more later. Against first come first served, which ignores distance, the saving is larger: 3,341 km vs 4,397 km (24 % less).

**Planning is still fast.** OR-Tools needed a median of 16 ms per scenario.

## Conclusion

On the same claimed pickups and the same rules, the OR-Tools route optimiser produced only valid plans, served the most pickups (439 vs 437) and drove 10 % less than Nearest-Next where both served the same pickups. The proposed method is better than both baselines. Its main benefit is shorter routes; the gain in pickups served is small with only 5 pickups per scenario.

## Limits of this experiment

- Each scenario has only 5 pickups and 2 vehicles; with more pickups OR-Tools has more room to improve on the simple rules.
- Each vehicle makes one trip, and travel times assume no traffic.
- The routing code of the app was used as it is, without changes.
