# E2 executed results

Readiness: **PARTIAL for unqualified methodological/functional signoff; all requested scenario counts executed.**

## Contention

| method | workers | trials | requests | duplicate_trials | extra_committed_claims | exactly_one_committed_claim | exactly_one_success_response | successes | conflicts | ineligible | errors | latency_n | median_ms | p95_ms |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| non_atomic_claim | 2 | 50 | 100 | 50 | 50 | 0 | 0 | 100 | 0 | 0 | 0 | 100 | 130.7 | 233.215 |
| non_atomic_claim | 5 | 50 | 250 | 50 | 192 | 0 | 0 | 242 | 8 | 0 | 0 | 250 | 176.05 | 273.81 |
| non_atomic_claim | 10 | 50 | 500 | 50 | 361 | 0 | 0 | 411 | 89 | 0 | 0 | 500 | 236.8 | 398.37 |
| protected_claim_without_lease_recovery | 2 | 50 | 100 | 0 | 0 | 50 | 50 | 50 | 50 | 0 | 0 | 100 | 102.3 | 155.295 |
| protected_claim_without_lease_recovery | 5 | 50 | 250 | 0 | 0 | 50 | 50 | 50 | 200 | 0 | 0 | 250 | 131.4 | 201.695 |
| protected_claim_without_lease_recovery | 10 | 50 | 500 | 0 | 0 | 50 | 50 | 50 | 450 | 0 | 0 | 500 | 163.3 | 258.21 |
| proposed | 2 | 50 | 100 | 0 | 0 | 50 | 50 | 50 | 2 | 0 | 48 | 100 | 1055.95 | 1109.31 |
| proposed | 5 | 50 | 250 | 0 | 0 | 50 | 50 | 50 | 2 | 0 | 198 | 250 | 3049.15 | 4103.485 |
| proposed | 10 | 50 | 500 | 0 | 0 | 50 | 50 | 50 | 5 | 0 | 445 | 500 | 5096.75 | 9142.62 |

## Lease cases

| method | case | scenarios | replacement_success | old_holder_still_active | incorrect_active_releases | errors |
|---|---|---|---|---|---|---|
| protected_claim_without_lease_recovery | lease expired | 100 | 0 | 100 | None | 0 |
| protected_claim_without_lease_recovery | lease still running | 25 | 0 | 25 | 0 | 0 |
| proposed | lease expired | 100 | 100 | 0 | None | 0 |
| proposed | lease still running | 25 | 0 | 25 | 0 | 0 |

Database failure-audit SQLSTATE counts: `{"40P01": 691}`. Generic GeoLock rollback responses are counted as errors, not claim conflicts. Duplicate counts use committed database records, not only HTTP/RPC success messages.

Original teammate baselines run unchanged on their supplied V3 schema; the actual proposed method runs unchanged claim/recovery bodies plus the current reconciliation package on the full GeoLock schema. Both use the same fresh PG17 cluster, isolation, scenario/NGO order, 2/5/10 request barriers, retry setting, directed matrix eligibility and 360-minute lease. Schema/lifecycle/audit differences are a validity threat: latency is not a causal estimate of atomic locking alone. The older baseline has a FOR NO KEY UPDATE fix; the actual current GeoLock claim body retains its reviewed FOR UPDATE behavior. No production logic was changed to improve results.

Auth/Storage/cron are local adapters; the actual protected claim/recovery SQL and constraints execute in PostgreSQL. Proposal eligibility uses the exact supplied directed matrix, not a new live road extraction. Absolute historical timestamps are replayed against server time with their original relative durations, as the teammate driver specifies. The optional pgcrypto extension load is omitted because core PG17 supplies UUID generation; PostGIS is real in the baseline DB. There are no hosted calls or workers. All tables/raw requests and fixture failures are retained. No unexecuted method/lease cell is marked PASS; non-atomic lease recovery is not implemented by that baseline and is not invented.
