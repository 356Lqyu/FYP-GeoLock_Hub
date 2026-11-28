# Run information: Community hub aggregation (E3 proposed)

| Item | Value |
| --- | --- |
| Run at | 2026-11-28T21:42:38+08:00 |
| Benchmark | GEOLOCK-BENCHMARK-DATASET (inputs checked against the manifest) |
| Scenarios | 100 HUB_AGGREGATION; 100 aggregated, 0 kept as direct pickups |
| Hub workflow rules | five hard rules + capacity; drop off in donor window and hub hours; batch 3-5 items, <= 30 kg, one category; NGO <= 20 km road from hub |
| Routing | Nearest-Next + independent validator imported from the baseline (identical code) |
| Settings | 240-min route, 10 min per stop, 360-min lease, one trip per vehicle, cutoff = last donation available |
| Cost index | 1.0 x NGO km + 5.0 x trips + 0.5 x donations handled at a hub |
| Donor travel | kept as one reference column (donor_travel_km), not compared |
| Runner | run_hub_aggregation.py SHA-256 7a55be206baa7378... |
| Python | 3.12.10 |
