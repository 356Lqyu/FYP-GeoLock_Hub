# Run information: Protected Claim without Lease Recovery

| Item | Value |
| --- | --- |
| Run at | 2026-11-05 02:11 Malay Peninsula Standard Time |
| Benchmark | GEOLOCK-BM-v3.3 (manifest SHA-256 139c823a20753e16...; every input CSV checked against it) |
| Script | `protected_claim_without_lease_recovery_baseline.py` (SHA-256 9117604c5f2a76ed...) |
| Python | 3.12.14 |
| Database | Isolated loopback PostgreSQL port 63075 |
| PostgreSQL | PostgreSQL 17.11 |
| Transaction isolation | read committed |
| claim_listing() row lock | FOR NO KEY UPDATE (checked before the run) |
| Run ID | e2-20261105-v33-actual-01-protected_claim_without_lease_recovery |
| Scenarios run | 150 contention trials, 125 lease cases (all) |
| Settings | 2 / 5 / 10 requests per trial; 20 km road geofence; 360-min lease; one retry after a deadlock; lease recovery off |
