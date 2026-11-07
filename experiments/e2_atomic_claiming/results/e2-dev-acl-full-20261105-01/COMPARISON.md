# E2 corrected proposed-method comparison

PASS_LOCAL_E2_CORRECTNESS_AND_ROBUSTNESS

Original proposed and baseline measurements are reused unchanged from `e2-20261105-v33-actual-01`; only corrected proposed was rerun.

| method | workers | trials | requests | duplicate_trials | extra_committed_claims | exactly_one_committed_claim | exactly_one_success_response | successes | conflicts | ineligible | errors | latency_n | median_ms | p95_ms | evidence_run |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| non_atomic_claim | 2 | 50 | 100 | 50 | 50 | 0 | 0 | 100 | 0 | 0 | 0 | 100 | 130.7 | 233.215 | e2-20261105-v33-actual-01 |
| non_atomic_claim | 5 | 50 | 250 | 50 | 192 | 0 | 0 | 242 | 8 | 0 | 0 | 250 | 176.05 | 273.81 | e2-20261105-v33-actual-01 |
| non_atomic_claim | 10 | 50 | 500 | 50 | 361 | 0 | 0 | 411 | 89 | 0 | 0 | 500 | 236.8 | 398.37 | e2-20261105-v33-actual-01 |
| protected_claim_without_lease_recovery | 2 | 50 | 100 | 0 | 0 | 50 | 50 | 50 | 50 | 0 | 0 | 100 | 102.3 | 155.295 | e2-20261105-v33-actual-01 |
| protected_claim_without_lease_recovery | 5 | 50 | 250 | 0 | 0 | 50 | 50 | 50 | 200 | 0 | 0 | 250 | 131.4 | 201.695 | e2-20261105-v33-actual-01 |
| protected_claim_without_lease_recovery | 10 | 50 | 500 | 0 | 0 | 50 | 50 | 50 | 450 | 0 | 0 | 500 | 163.3 | 258.21 | e2-20261105-v33-actual-01 |
| original_proposed | 2 | 50 | 100 | 0 | 0 | 50 | 50 | 50 | 2 | 0 | 48 | 100 | 1055.95 | 1109.31 | e2-20261105-v33-actual-01 |
| original_proposed | 5 | 50 | 250 | 0 | 0 | 50 | 50 | 50 | 2 | 0 | 198 | 250 | 3049.15 | 4103.485 | e2-20261105-v33-actual-01 |
| original_proposed | 10 | 50 | 500 | 0 | 0 | 50 | 50 | 50 | 5 | 0 | 445 | 500 | 5096.75 | 9142.62 | e2-20261105-v33-actual-01 |
| corrected_proposed | 2 | 50 | 100 | 0 | 0 | 50 | 50 | 50 | 50 | 0 | 0 | 100 | 119.6 | 183.375 | e2-dev-acl-full-20261105-01 |
| corrected_proposed | 5 | 50 | 250 | 0 | 0 | 50 | 50 | 50 | 200 | 0 | 0 | 250 | 134.3 | 203.75 | e2-dev-acl-full-20261105-01 |
| corrected_proposed | 10 | 50 | 500 | 0 | 0 | 50 | 50 | 50 | 450 | 0 | 0 | 500 | 182.9 | 324.77 | e2-dev-acl-full-20261105-01 |

## Lease cases

| method | case | scenarios | replacement_success | old_holder_still_active | incorrect_active_releases | errors | evidence_run |
|---|---|---|---|---|---|---|---|
| protected_claim_without_lease_recovery | lease expired | 100 | 0 | 100 | None | 0 | e2-20261105-v33-actual-01 |
| protected_claim_without_lease_recovery | lease still running | 25 | 0 | 25 | 0 | 0 | e2-20261105-v33-actual-01 |
| original_proposed | lease expired | 100 | 100 | 0 | None | 0 | e2-20261105-v33-actual-01 |
| original_proposed | lease still running | 25 | 0 | 25 | 0 | 0 | e2-20261105-v33-actual-01 |
| corrected_proposed | lease expired | 100 | 100 | 0 | None | 0 | e2-dev-acl-full-20261105-01 |
| corrected_proposed | lease still running | 25 | 0 | 25 | 0 | 0 | e2-dev-acl-full-20261105-01 |

Benchmark database errors: {}. Expected authorization/fault/drift negative controls are in regressions.json, outside benchmark scenario counts.

Historical baselines use older schema; one local run; Auth/Storage/roads are adapters; no DEV or end-to-end phone performance claim. No automatic product or driver retries were added. No E4 change or rerun.
