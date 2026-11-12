# E4 plan: OR-Tools route optimiser against simple routing rules

## Question
With the same claimed pickups and the same vehicle rules, does the app's OR-Tools route optimiser serve more pickups
than simple routing rules? And where they serve the same pickups, does it drive less?

## Data (frozen benchmark GEOLOCK-BENCHMARK-DATASET)
* 100 `ROUTE_PLANNING` scenarios, each with 5 claimed donations of one NGO and its two vehicles (car 100 kg, van
  500 kg). Road distances and times from the benchmark road network.
* Each scenario becomes one sealed planning snapshot (fixed SHA-256). The experiment adapter ignores the synthetic
  `listing_expires_at` copied from legacy availability data, because the current post-claim workflow has no separate
  listing expiry. Claim lease, owner, status, pickup windows, capacity, route duration, depot return and directed-road
  checks remain active. The adapter admits 5 tasks per snapshot (500 total), and all three methods use the same task IDs.
* Every input file is checked against its SHA-256 in `generation_manifest.json`.

## Methods
| Role | Method | What it does |
| --- | --- | --- |
| Baseline 1 | Nearest-Next | each vehicle in turn drives to the closest pickup it can still fit and finish in time |
| Baseline 2 | First come first served | each vehicle takes pickups in the order they were claimed |
| Proposed | **OR-Tools route optimiser** (as in the app) | `backend/routing/optimizers/cp_sat.py` (Google OR-Tools CP-SAT), the function the routing worker calls: serve as many pickups as possible, then the shortest total road distance |

Rules for all: start and end at the NGO depot, one trip per vehicle, within capacity, within 240 minutes (driving
plus 10 minutes per stop). The app's routing code is used without any change.

## Measures (in this order)
1. Every plan must pass an independent check (capacity, 240 minutes, each pickup served once or reported unserved).
2. **Main:** pickups served.
3. Aggregate coverage and distance use all 100 snapshots. Paired distance and driving-time comparisons include only
   independently validated snapshots where both methods served the exact same task-ID set.

Uncertainty: Wilson 95 % intervals, exact McNemar test (every pickup served), Wilcoxon–Pratt paired tests and Hodges–Lehmann
estimates with 10,000-resample bootstrap 95 % intervals for identical-task distance and driving time. Holm adjustment
is applied across the four secondary baseline-by-measure tests.

## Steps
1. Run the two baselines on the shared sealed snapshots.
2. Run the OR-Tools route optimiser on the same snapshots.
3. Run the comparison. It only reads the result folders.
