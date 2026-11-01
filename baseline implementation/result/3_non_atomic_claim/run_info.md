# Run information: Non-Atomic Claim (baseline 3)

| Item | Value |
| --- | --- |
| Run at | 2026-11-01 22:10 Malay Peninsula Standard Time |
| Benchmark | GEOLOCK-BM-v3.3 (manifest SHA-256 5fdafca9baa69c4e...; every input CSV checked against it) |
| Script | `non_atomic_claim_baseline.py` (SHA-256 44eb362fbbb2b515...) |
| Python | 3.12.10 |
| Database | Supabase project (aws-0-ap-southeast-1.pooler.supabase.com); response times include the network delay |
| PostgreSQL | PostgreSQL 17.11 |
| Transaction isolation | read committed |
| Run ID | 6835c1293933 |
| Scenarios run | 150 contention trials (all) |
| Settings | 2 / 5 / 10 requests per trial; race window 50 ms; 20 km road geofence; one retry after a deadlock |
