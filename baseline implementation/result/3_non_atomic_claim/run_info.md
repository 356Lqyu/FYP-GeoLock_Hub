# Run information: Non-Atomic Claim (baseline 3)

This file only records what produced the results in this folder, so the run can be repeated and checked. You do not need it to read the results.

| Item | Value |
| --- | --- |
| Run at | 2026-10-23 18:45 Malay Peninsula Standard Time |
| Benchmark | GEOLOCK-BM-v3.2 (generation_manifest.json SHA-256 4ef29e205fd09eba...; every input CSV was checked against this manifest) |
| Script | `non_atomic_claim_baseline.py` (SHA-256 c290f0e04a633be4...) |
| Python | 3.12.10 |
| Command to repeat | `python non_atomic_claim_baseline.py` |
| Database | Supabase project (aws-0-ap-southeast-1.pooler.supabase.com); network delay is included in response times |
| PostgreSQL | PostgreSQL 17.11 |
| Transaction isolation | read committed |
| Run ID | a8c2175d77ad |
| Scenarios run | 150 contention trials (all) |
| Settings | 2, 5 and 10 NGOs per trial (50 trials each); race window 50 ms; one retry after a deadlock |
