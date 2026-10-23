# Run information: Protected Claim without Lease Recovery (baseline 4)

This file only records what produced the results in this folder, so the run can be repeated and checked. You do not need it to read the results.

| Item | Value |
| --- | --- |
| Run at | 2026-10-23 19:09 Malay Peninsula Standard Time |
| Benchmark | GEOLOCK-BM-v3.2 (generation_manifest.json SHA-256 4ef29e205fd09eba...; every input CSV was checked against this manifest) |
| Script | `protected_claim_without_lease_recovery_baseline.py` (SHA-256 874e3bd6646bebc6...) |
| Python | 3.12.10 |
| Command to repeat | `python protected_claim_without_lease_recovery_baseline.py` |
| Database | Supabase project (aws-0-ap-southeast-1.pooler.supabase.com); network delay is included in response times |
| PostgreSQL | PostgreSQL 17.11 |
| Transaction isolation | read committed |
| Run ID | c332f725ef59 |
| Scenarios run | 150 contention trials, 125 lease cases (all) |
| Settings | 2, 5 and 10 NGOs per trial (50 trials each); one retry after a deadlock; lease recovery switched off |
