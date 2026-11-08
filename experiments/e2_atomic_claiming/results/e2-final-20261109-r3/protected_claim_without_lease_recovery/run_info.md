# Run information: Protected Claim without Lease Recovery

| Item | Value |
| --- | --- |
| Run at | 2026-11-09 01:24 Malay Peninsula Standard Time |
| Benchmark | GEOLOCK-BM-v3.3 (manifest SHA-256 5fdafca9baa69c4e...; every input CSV checked against it) |
| Script | `protected_claim_without_lease_recovery_baseline.py` (SHA-256 edb27ba73208b69d...) |
| Python | 3.12.14 |
| Database | Isolated loopback PostgreSQL port 61038 |
| PostgreSQL | PostgreSQL 17.11 |
| Transaction isolation | read committed |
| claim_listing() row lock | FOR NO KEY UPDATE (checked before the run) |
| Run ID | e2-final-20261109-r3-protected_claim_without_lease_recovery |
| Scenarios run | 150 contention trials, 125 lease cases (all) |
| Settings | 2 / 5 / 10 requests per trial; 20 km road geofence; 360-min lease; one retry after a deadlock; lease recovery off |
