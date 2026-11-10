# Run information: Non-Atomic Claim (baseline 1)

| Item | Value |
| --- | --- |
| Condition | Non-Atomic Claim (baseline 1) |
| Run at | 2026-11-10T14:31:31+08:00 |
| Benchmark | GEOLOCK-BENCHMARK-DATASET (every input checked against generation_manifest.json) |
| Database | separate experiment only Supabase project (PostgreSQL 17.11) |
| Isolation | read committed |
| Schema | 01_geolock_v3_schema.sql, 02_app_claim_layer.sql (app functions copied from the deployed Supabase export of 2026-11-09), 03_non_atomic_baseline.sql |
| claim_listing() SHA-256 | 7953f67c152bcf3a... |
| Contention trials | 150: 50 each with 2, 5 and 10 NGOs |
| Lease trials | not run (contention part only) |
| Synchronisation | one database connection per NGO, all requests of a trial released together by a barrier; a second barrier makes every NGO finish its check before any NGO saves |
| Retry | none |
| Timeout | connect 15 s, statement 30 s, barrier 60 s |
| Rules | 20 km road geofence, 360 min lease |
| Lease recovery | never runs |
| Run ID | 4e8ee7f3217e |
| Python | 3.12.10 |
| psycopg | 3.3.6 |
