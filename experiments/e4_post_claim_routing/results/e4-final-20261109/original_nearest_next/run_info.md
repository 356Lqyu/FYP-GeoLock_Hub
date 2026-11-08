# Run information: Nearest-Next routing (baseline 6)

This file only records what produced the results in this folder, so the run can be repeated and checked. You do not need it to read the results.

| Item | Value |
| --- | --- |
| Run at | 2026-11-09 00:26 Malay Peninsula Standard Time |
| Benchmark | GEOLOCK-BM-v3.3 (generation_manifest.json SHA-256 5fdafca9baa69c4e...; every input CSV was checked against this manifest) |
| Script | `nearest_next_baseline.py` (SHA-256 23104306cc38866b...) |
| Python | 3.12.14 |
| Command to repeat | `python nearest_next_baseline.py` |
| Scenarios run | 100 (all) |
| Planning input | built from the benchmark (same snapshots as the other route baselines) |
| Settings | 20 km geofence; 360 min lease; 240 min per route; 10 min per stop; safety margin 0 min; one trip per vehicle |
| Note | Claims are taken as already protected; live dispatch authorisation is not part of this baseline |
