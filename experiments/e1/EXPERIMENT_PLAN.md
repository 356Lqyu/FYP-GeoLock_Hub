# E1 plan: AI hub ranking against Nearest-Hub

## Question
For a small donation (under 10 kg), does the app's AI hub ranking pick the same community hub as the reference
policy, on donations from areas it has never seen? And does it do so more often than just picking the nearest hub?

## Data (frozen benchmark GEOLOCK-BENCHMARK-DATASET)
* The 349 test donations in `ai hub ranking/data split/split/test_scenario_ids.csv`. They come from map areas that
  were kept out of model training.
* For each donation: the hubs that pass the hard rules (accept the category, enough free space, open in the drop off
  window, active, reachable by road), with road distance, how full the hub is, free space and handling penalty.
* Every input file is checked against its SHA-256 in `generation_manifest.json`. The run stops if anything changed.

## Methods
| Role | Method | What it does |
| --- | --- | --- |
| Baseline 1 | Nearest-Hub | recommends the hub with the shortest road distance (ties: hub ID) |
| Baseline 2 | Random Hub | recommends a random hub from the list (fixed seed 42), the chance level |
| Proposed | AI hub ranking | the frozen XGBoost model in `ai hub ranking/model/`, ranked with the same code as the app's ranking API |

All three rank exactly the same hub list for each donation and return their top 3.

## The right hub
The reference policy picks the lowest score of 0.45 × road distance (scaled within the donation's hubs) + 0.20 × how
full the hub is + 0.25 × capacity pressure + 0.10 × handling penalty. Ties go to the shorter distance, then hub ID.

## Measures
* **Main:** share of donations where the method's first hub is the reference hub (Top 1 agreement).
* Also: reference hub in the method's top 3, ranking quality (NDCG@3), regret (how much worse the chosen hub's
  reference score is than the best) and road distance to the chosen hub.
* Uncertainty: 95 % Wilson intervals. Paired tests on the same donations: exact McNemar test (Top 1) and Wilcoxon
  signed rank test with a 10,000 resample bootstrap interval (NDCG@3).

## Check before the experiment
The benchmark's 8 fixed weight cases go through the app's collection rule (missing or 0 kg is invalid, under 10 kg
goes to a community hub, 10 kg or more is a direct pickup).

## Steps
1. Run both baselines on the 349 test donations.
2. Run the AI hub ranking on the same donations.
3. Run the comparison. It only reads the three result folders.
