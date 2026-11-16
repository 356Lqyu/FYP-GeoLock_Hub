# Run information: Non-Atomic Claim (baseline 1)

| Item | Value |
| --- | --- |
| Condition | Non-Atomic Claim (baseline 1) |
| Run at | 2026-11-16T16:28:47+08:00 |
| Benchmark | GEOLOCK-BENCHMARK-DATASET (every input checked against generation_manifest.json) |
| Database | verified isolated Supabase E2 target (PostgreSQL 17.11) |
| Isolation | read committed |
| PostgreSQL extensions | {"pgcrypto": "1.3", "postgis": "3.3.7"} |
| Schema | 01_geolock_v3_schema.sql, 02_app_claim_layer.sql (app functions copied from the deployed Supabase export of 2026-11-09), 03_non_atomic_baseline.sql |
| claim_listing() SHA-256 | 7953f67c152bcf3a... |
| Contention trials | 150: 50 each with 2, 5 and 10 NGOs |
| Lease trials | not run (contention part only) |
| Synchronisation | one database connection per NGO, all requests of a trial released together by a barrier; a second barrier makes every NGO finish its check before any NGO saves |
| Retry | none |
| Timeout | connect 15 s, statement 30 s, barrier 60 s |
| Rules | 20 km road geofence, 360 min lease |
| Lease recovery | never runs |
| Run ID | 0a6773e88bcc4fefa2b5dfdbd2c1b7b7 |
| Python | 3.12.7 |
| psycopg | 3.3.9 |
