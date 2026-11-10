# GeoLock Hub experiments

All four experiments use the frozen benchmark dataset **GEOLOCK-BENCHMARK-DATASET** (`benchmark dataset/dataset`).
Every program checks each input file against the SHA-256 in `generation_manifest.json` and stops if anything changed.

Each experiment folder has the same layout:

```
eX/
├── README.md            what is in the folder and how to run it, step by step
├── EXPERIMENT_PLAN.md   question, data, methods and measures
├── baseline/            the comparison methods: program and results
├── <proposed method>/   the GeoLock method as the app does it: program and results
└── experiment_result/   comparison program, summary.md (start here) and figures
```

The baselines are the ones named for each research area in the report (Table 3.6).

| Experiment | Proposed (GeoLock) | Baselines | Main result |
| --- | --- | --- | --- |
| [E1](e1/experiment_result/summary.md) | AI hub ranking | Nearest-Hub, Random Hub | picks the reference hub for **82.2 %** of 349 test donations, against 41.8 % (Nearest-Hub) and 4.6 % (Random) |
| [E2](e2/experiment_result/summary.md) | protected claim with lease recovery | Non-Atomic Claim, Protected Claim without Lease Recovery | **0** of 150 races end with two owners (150 for Non-Atomic Claim); **100** of 100 expired leases released (0 for both baselines) |
| [E3](e3/experiment_result/summary.md) | community hub aggregation | direct household pickup | NGO drives **1,376 km** instead of 2,689 km (48.8 % less); 100 pickup stops instead of 438 |
| [E4](e4/experiment_result/summary.md) | OR-Tools route optimiser (app routing worker) | Nearest-Next, first come first served | serves **439** pickups against 437; **9.9 % less** driving than Nearest-Next where both serve the same pickups |

## Setup (once)

```powershell
py -m venv .venv
.venv\Scripts\activate
pip install -r experiments/requirements.txt
```

Every program runs with plain `python <file>.py` from the repository root, no extra options. The order is in each
experiment's README. E2 needs its own new Supabase project (never the app's project), see `e2/HOW_TO_RUN_E2.md`.
