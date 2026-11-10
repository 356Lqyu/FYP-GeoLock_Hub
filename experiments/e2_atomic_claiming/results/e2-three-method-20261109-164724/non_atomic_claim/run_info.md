# Run information: Non-Atomic Claim (baseline 3)

| Item | Value |
| --- | --- |
| Run at | 2026-11-09 16:49 Malay Peninsula Standard Time |
| Benchmark | GEOLOCK-BM-v3.3 (manifest SHA-256 5fdafca9baa69c4e...; every input CSV checked against it) |
| Script | `non_atomic_claim_baseline.py` (SHA-256 251f5d51c4e38507...) |
| Python | 3.12.14 |
| Database | Isolated loopback PostgreSQL port 58752 |
| PostgreSQL | PostgreSQL 17.11 |
| Transaction isolation | read committed |
| Run ID | e2-three-method-20261109-164724-non_atomic_claim |
| Scenarios run | 150 contention trials (all) |
| Settings | 2 / 5 / 10 requests per trial; race window 50 ms; 20 km road geofence; one retry after a deadlock |
