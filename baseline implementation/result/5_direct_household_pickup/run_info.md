# Run information: Direct Household Pickup (baseline 5)

This file only records what produced the results in this folder, so the run can be repeated and checked. You do not need it to read the results.

| Item | Value |
| --- | --- |
| Run at | 2026-10-23 18:39 Malay Peninsula Standard Time |
| Benchmark | GEOLOCK-BM-v3.2 (generation_manifest.json SHA-256 4ef29e205fd09eba...; every input CSV was checked against this manifest) |
| Script | `direct_household_pickup_baseline.py` (SHA-256 c4704c56e0f25c0f...) |
| Python | 3.12.10 |
| Command to repeat | `python direct_household_pickup_baseline.py` |
| Scenarios run | 100 (all) |
| Planning input | built from the benchmark (same snapshots as the other route baselines) |
| Settings | 20 km geofence; 360 min lease; 240 min per route; 10 min per stop; safety margin 0 min; one trip per vehicle |
| Note | Claims are taken as already protected; live dispatch authorisation is not part of this baseline |
