# E3 plan: community hub aggregation against direct household pickup

## Question (RQ3)
When small donations are dropped at a community hub and collected as one batch, how much collection effort does the
NGO save compared with collecting every donation from each home?

## Expected result
The hub needs less NGO driving, less NGO route time, fewer pickup stops and a lower collection cost, while every
donation is still collected and every hub rule holds.

## Data
The frozen benchmark GEOLOCK-BENCHMARK-DATASET: 100 `HUB_AGGREGATION` scenarios with 3 to 5 small donations each
(438 donations), one community hub and one NGO with a car (100 kg) and a van (500 kg) per scenario. Every input file is
checked against its SHA-256 in `generation_manifest.json`.

## Methods
| Role | Method | What it does |
| --- | --- | --- |
| Baseline | Direct household pickup | the NGO collects each donation from the donor's home |
| Proposed | Community hub aggregation (as in the app) | reserve hub space, drop off and receipt in opening hours, one batch (3 to 5 items, at most 30 kg, one category), published as one listing, the NGO collects the batch at the hub |

Both use the same route planner (Nearest-Next, the same code), vehicles, depot and road distances, 240 minutes per
vehicle and 10 minutes per stop. Only the way donations are collected differs.

## Measures (all on the NGO side, paired by scenario)
| Measure | Role | Better when |
| --- | --- | --- |
| NGO road distance (km) | primary | lower |
| NGO route time, including 10 minutes per stop (min) | secondary | lower |
| NGO pickup stops | secondary | lower |
| NGO collection cost (1 per km + 5 per trip + 0.5 per item handled at a hub) | secondary | lower |
| Donations collected, vehicle trips, batch rule checks | checks | all donations collected, all rules pass |

Driving time and donations collected per vehicle-hour are also reported in the main table.

## Decision rule
The proposed method is better than the baseline if its total NGO road distance is lower and the Wilcoxon signed rank
test on the 100 paired differences gives p < 0.05, with every donation collected. The secondary measures are tested the
same way with the Holm correction. Each result is reported with a Hodges-Lehmann estimate and a 95 % bootstrap interval
(10,000 resamples, seed 20260915).

## Robustness checks
1. Cost coefficients halved and doubled, one at a time and all together.
2. Saving by batch size (3, 4, 5 donations) and by distance from the NGO depot to the hub.
3. Every scenario where the hub needed more NGO driving, with the reason.

## Outputs (only these)
| Folder | Files |
| --- | --- |
| `baseline/direct_household_pickup/` | `results_per_scenario.csv`, `routes.csv`, `run_info.md` |
| `hub_aggregation/result/` | `results_per_scenario.csv`, `routes.csv`, `batch_integrity_checks.csv`, `run_info.md` |
| `experiment_result/` | `summary.md`, `comparison_summary.csv`, `comparison_per_scenario.csv` and three figures |

| Figure | What it proves |
| --- | --- |
| `e3_fig1_main_comparison.png` | the hub is lower on all four NGO measures (totals, with % change) |
| `e3_fig2_ngo_km_per_scenario.png` | the saving is not an average effect: the hub is shorter in almost every scenario |
| `e3_fig3_saving_by_batch_size.png` | why it works: one hub stop replaces 3 to 5 home stops, so a fuller batch saves more |

## Steps
1. Run the baseline. 2. Run hub aggregation on the same scenarios. 3. Run the comparison, which only reads the two
result folders. Rerunning gives exactly the same numbers, apart from planning times.

## Change record
November 2026: E3 was refocused on the collection effort of the NGO. Donor travel to the hub is no longer a comparison
measure. It is kept as one column (`donor_travel_km`) in the proposed results for reference only.
