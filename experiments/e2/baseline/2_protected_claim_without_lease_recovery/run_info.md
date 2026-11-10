# Run information: Protected Claim without Lease Recovery (baseline 2)

| Item | Value |
| --- | --- |
| Condition | Protected Claim without Lease Recovery (baseline 2) |
| Run at | 2026-11-10T14:32:37+08:00 |
| Benchmark | GEOLOCK-BENCHMARK-DATASET (every input checked against generation_manifest.json) |
| Database | separate experiment only Supabase project (PostgreSQL 17.11) |
| Isolation | read committed |
| Schema | 01_geolock_v3_schema.sql, 02_app_claim_layer.sql (app functions copied from the deployed Supabase export of 2026-11-09), 03_non_atomic_baseline.sql |
| claim_listing() SHA-256 | 7953f67c152bcf3a... |
| Contention trials | not run (lease part only) |
| Lease trials | 100 expired, 25 still running |
| Synchronisation | one database connection per NGO, all requests of a trial released together by a barrier |
| Retry | one retry with the same request ID after a deadlock or serialization failure |
| Timeout | connect 15 s, statement 30 s, barrier 60 s |
| Rules | 20 km road geofence, 360 min lease |
| Lease recovery | never runs |
| Run ID | a76ede7e1276 |
| Python | 3.12.10 |
| psycopg | 3.3.6 |
