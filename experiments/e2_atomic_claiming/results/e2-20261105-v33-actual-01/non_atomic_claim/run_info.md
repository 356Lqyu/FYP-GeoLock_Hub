# Run information: Non-Atomic Claim (baseline 3)

| Item | Value |
| --- | --- |
| Run at | 2026-11-05 02:09 Malay Peninsula Standard Time |
| Benchmark | GEOLOCK-BM-v3.3 (manifest SHA-256 139c823a20753e16...; every input CSV checked against it) |
| Script | `non_atomic_claim_baseline.py` (SHA-256 44eb362fbbb2b515...) |
| Python | 3.12.14 |
| Database | Isolated loopback PostgreSQL port 63075 |
| PostgreSQL | PostgreSQL 17.11 |
| Transaction isolation | read committed |
| Run ID | e2-20261105-v33-actual-01-non_atomic_claim |
| Scenarios run | 150 contention trials (all) |
| Settings | 2 / 5 / 10 requests per trial; race window 50 ms; 20 km road geofence; one retry after a deadlock |
