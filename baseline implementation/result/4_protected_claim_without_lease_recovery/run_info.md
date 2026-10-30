# Run information: Protected Claim without Lease Recovery

| Item | Value |
| --- | --- |
| Run at | 2026-10-28 22:09 Malay Peninsula Standard Time |
| Benchmark | GEOLOCK-BM-v3.3 (manifest SHA-256 9c69e28601990a3a...; every input CSV checked against it) |
| Script | `protected_claim_without_lease_recovery_baseline.py` (SHA-256 9117604c5f2a76ed...) |
| Python | 3.12.10 |
| Database | Supabase project (aws-0-ap-southeast-1.pooler.supabase.com); response times include the network delay |
| PostgreSQL | PostgreSQL 17.11 |
| Transaction isolation | read committed |
| claim_listing() row lock | FOR NO KEY UPDATE (checked before the run) |
| Run ID | 75caad903519 |
| Scenarios run | 150 contention trials, 125 lease cases (all) |
| Settings | 2 / 5 / 10 requests per trial; 20 km road geofence; 360-min lease; one retry after a deadlock; lease recovery off |
