# Run information: AI hub ranking (E1 proposed)

| Item | Value |
| --- | --- |
| Run at | 2026-11-10T03:09:01+08:00 |
| Benchmark | GEOLOCK-BENCHMARK-DATASET (inputs checked against the manifest) |
| Scenarios | 349 held out test donations (test_scenario_ids.csv) |
| Model | hubrank-xg-2026-11-01-894d3223 (XGBRegressor), SHA-256 894d3223e7c45846... (checked) |
| Features | road_distance_km, utilisation_ratio, capacity_pressure, donation_weight_kg, handling_penalty |
| Ranking rule | api/main.py rank(): predicted score (9 dp), then road distance, then hub ID; Top-k 3 |
| App code used | FEATURES, load_model(), rank() from ai hub ranking/api/main.py (SHA-256 of extracted source f659e8d137b34271...) |
| Runner | run_ai_hub_ranking.py SHA-256 ec9a284b319e8ee7... |
| Scoring time | 349 ms for 349 donations (1.00 ms each) |
| Python / xgboost | 3.13.18 / 2.1.4 |
