# Run information: Non-Atomic Claim (baseline 3)

| Item | Value |
| --- | --- |
| Run at | 2026-11-09 01:22 Malay Peninsula Standard Time |
| Benchmark | GEOLOCK-BM-v3.3 (manifest SHA-256 5fdafca9baa69c4e...; every input CSV checked against it) |
| Script | `non_atomic_claim_baseline.py` (SHA-256 251f5d51c4e38507...) |
| Python | 3.12.14 |
| Database | Isolated loopback PostgreSQL port 61038 |
| PostgreSQL | PostgreSQL 17.11 |
| Transaction isolation | read committed |
| Run ID | e2-final-20261109-r3-non_atomic_claim |
| Scenarios run | 150 contention trials (all) |
| Settings | 2 / 5 / 10 requests per trial; race window 50 ms; 20 km road geofence; one retry after a deadlock |
