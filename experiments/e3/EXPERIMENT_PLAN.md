# E3 plan: community hub aggregation against direct household pickup

## Question
If small donations are dropped at a community hub and collected as one batch, how much less does the NGO drive than
when it collects every donation from each home? And how much travel moves to the donors?

## Data (frozen benchmark GEOLOCK-BENCHMARK-DATASET)
* 100 `HUB_AGGREGATION` scenarios. Each has 3 to 5 small donations from nearby homes (438 in total), one community
  hub, its batch template and one NGO with a car (100 kg) and a van (500 kg).
* Road distances and times from the benchmark road network.
* Every input file is checked against its SHA-256 in `generation_manifest.json`.

## Methods
| Role | Method | What it does |
| --- | --- | --- |
| Baseline | Direct household pickup | the NGO collects each donation from the donor's home |
| Proposed | Community hub aggregation (as in the app) | reserve hub space, drop off and receipt in opening hours, one batch (3 to 5 items, at most 30 kg, one category), published as one listing, the NGO collects it at the hub |

Both use the same route planner (Nearest-Next, the same code), the same vehicles and depot, 240 minutes per vehicle,
10 minutes per stop and a 360 minute claim lease. Only the way donations are collected differs.

## Measures
* **Main:** NGO driving distance per scenario (paired).
* Also: pickup stops, vehicle trips, NGO cost (1 per km + 5 per trip + 0.5 per item handled at a hub), donor travel
  to the hub and back, NGO and donor travel together, and the batch rule checks.
* Uncertainty: Wilcoxon signed rank test on the paired differences, Hodges Lehmann estimate with a 10,000 resample
  bootstrap 95 % interval (seed 20260915).

## Steps
1. Run the baseline.
2. Run hub aggregation on the same scenarios.
3. Run the comparison. It only reads the two result folders.
