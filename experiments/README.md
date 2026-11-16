# GeoLock Hub experiments

All four experiments use the frozen benchmark dataset **GEOLOCK-BENCHMARK-DATASET** (`benchmark dataset/dataset`).
Every program checks each input file against the SHA-256 in `generation_manifest.json` and stops if anything changed.

The experiment folders share this basic layout. E2 also has local PostgreSQL setup, safety checks, and run-specific evidence.

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
| [E2](e2/README.md#find-and-verify-the-results) | protected claim with lease recovery | Non-Atomic Claim, Protected Claim without Lease Recovery | See the latest verified comparison for duplicate ownership and expired-lease recovery. |
| [E3](e3/experiment_result/summary.md) | community hub aggregation | direct household pickup | NGO drives **1,376 km** instead of 2,689 km (48.8 % less); 100 pickup stops instead of 438 |
| [E4](e4/experiment_result/summary.md) | OR-Tools route optimiser (app routing worker) | Nearest-Next, first come first served | See the active comparison for coverage and matched-task savings. |

## Setup (once)

```powershell
py -m venv .venv
.venv\Scripts\activate
pip install -r experiments/requirements.txt
```

Follow each experiment's README for its commands. For E2, use the [hosted reproduction guide](e2/README.md#reproduce-the-hosted-paper-procedure-on-windows) and the [latest-run verification instructions](e2/README.md#find-and-verify-the-results). For E4, see [active-result verification](e4/README.md#how-to-run).
