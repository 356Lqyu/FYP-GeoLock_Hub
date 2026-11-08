# E2 executed results

Readiness: **PARTIAL for unqualified methodological/functional signoff; all requested scenario counts executed.**

## Contention

| method | workers | trials | requests | duplicate_trials | extra_committed_claims | exactly_one_committed_claim | exactly_one_success_response | successes | conflicts | ineligible | errors | latency_n | median_ms | p95_ms |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| non_atomic_claim | 2 | 50 | 100 | 50 | 50 | 0 | 0 | 100 | 0 | 0 | 0 | 100 | 115.2 | 133.36 |
| non_atomic_claim | 5 | 50 | 250 | 50 | 200 | 0 | 0 | 250 | 0 | 0 | 0 | 250 | 124.1 | 141.71 |
| non_atomic_claim | 10 | 50 | 500 | 50 | 450 | 0 | 0 | 500 | 0 | 0 | 0 | 500 | 143.05 | 184.24 |
| protected_claim_without_lease_recovery | 2 | 50 | 100 | 0 | 0 | 50 | 50 | 50 | 50 | 0 | 0 | 100 | 89.05 | 110.775 |
| protected_claim_without_lease_recovery | 5 | 50 | 250 | 0 | 0 | 50 | 50 | 50 | 200 | 0 | 0 | 250 | 88.45 | 121.16 |
| protected_claim_without_lease_recovery | 10 | 50 | 500 | 0 | 0 | 50 | 50 | 50 | 450 | 0 | 0 | 500 | 115.3 | 167.86 |
| proposed | 2 | 50 | 100 | 0 | 0 | 50 | 50 | 50 | 15 | 0 | 35 | 100 | 1049.1 | 1155.07 |
| proposed | 5 | 50 | 250 | 0 | 0 | 50 | 50 | 50 | 0 | 0 | 200 | 250 | 3059.4 | 4124.155 |
| proposed | 10 | 50 | 500 | 0 | 0 | 50 | 50 | 50 | 2 | 0 | 448 | 500 | 5108.45 | 9156.515 |

## Lease cases

| method | case | scenarios | replacement_success | old_holder_still_active | incorrect_active_releases | errors |
|---|---|---|---|---|---|---|
| protected_claim_without_lease_recovery | lease expired | 100 | 0 | 100 | None | 0 |
| protected_claim_without_lease_recovery | lease still running | 25 | 0 | 25 | 0 | 0 |
| proposed | lease expired | 100 | 100 | 0 | None | 0 |
| proposed | lease still running | 25 | 0 | 25 | 0 | 0 |

Database failure-audit SQLSTATE counts: `{"40P01": 683}`. Generic GeoLock rollback responses are counted as errors, not claim conflicts. Duplicate counts use committed database records, not only HTTP/RPC success messages.

Paired scenario bootstrap summaries for success responses, errors and excess committed claims are in `paired_uncertainty.csv`. Resampling units are fixed benchmark scenarios; intervals describe this scenario set and are not population inference. E2 latency distributions are reported with median/P95 but no causal latency claim is made because schema/lifecycle implementations differ.

Per-SQLSTATE request counts, confirmed rollback counts, and observed retries are in `database_error_audit.csv`. The Python driver retries only transient SQLSTATEs that escape as psycopg exceptions. A function-returned JSON error is not retried by that exception handler; retry counts are taken from each request record rather than inferred from the SQLSTATE.

Original teammate baselines run unchanged on their supplied V3 schema; the actual proposed method runs unchanged claim/recovery bodies plus the current reconciliation package on the full GeoLock schema. Both use the same fresh PG17 cluster, isolation, scenario/NGO order, 2/5/10 request barriers, retry setting, directed matrix eligibility and 360-minute lease. Schema/lifecycle/audit differences are a validity threat: latency is not a causal estimate of atomic locking alone. The older baseline has a FOR NO KEY UPDATE fix; the actual current GeoLock claim body retains its reviewed FOR UPDATE behavior. No production logic was changed to improve results.

Auth/Storage/cron are local adapters; the actual protected claim/recovery SQL and constraints execute in PostgreSQL. Proposal eligibility uses the exact supplied directed matrix, not a new live road extraction. Absolute historical timestamps are replayed against server time with their original relative durations, as the teammate driver specifies. The optional pgcrypto extension load is omitted because core PG17 supplies UUID generation; PostGIS is real in the baseline DB. There are no hosted calls or workers. All tables/raw requests and fixture failures are retained. No unexecuted method/lease cell is marked PASS; non-atomic lease recovery is not implemented by that baseline and is not invented.
