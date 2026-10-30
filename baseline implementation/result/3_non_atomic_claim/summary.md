# Non-Atomic Claim (baseline 3)

Benchmark GEOLOCK-BM-v3.3. Database: Supabase project (aws-0-ap-southeast-1.pooler.supabase.com); response times include the network delay.

## What this baseline does

It is the **unsafe "read, then write" claim** that a simple app would use. Each NGO request reads the listing without locking it, sees AVAILABLE, waits a short race window (50 ms, standing for the gap between the app reading and writing), then writes its claim without checking again. Nothing stops a second claim: there is no row lock and no one-active-claim index. When several NGOs press "claim" at the same moment, all of them can win.

## Compared with (experiment E2, RQ2)

| | This baseline | Proposed method (E2) |
| --- | --- | --- |
| Claim | unlocked read, then write | `claim_listing()`: row lock, recheck, one-active-claim index, idempotent request ID |
| Same inputs | | same 150 scenarios, listings, NGOs, request order (2 / 5 / 10 at once), 20 km road geofence, database and retry rule |

Pair the files by `scenario_id`. Main E2 metric: **duplicate committed-claim rate** (`more_than_one_owner`). Expected: this baseline has duplicates; the proposed method has none.

## Results

| Result | Value | Meaning |
| --- | --- | --- |
| Contention trials | 150 | One new listing per trial |
| Requests told SUCCESS | 850 | Each was told it owns the listing |
| Claims stored | 850 | Correct would be 150 (one per trial) |
| **Duplicate committed-claim rate** | 150 of 150 (100%) | Trials where more than one NGO owns the listing |
| Requests failed with a database error | 0 | |

### By number of NGOs claiming at once

| NGOs claiming at once | Trials | SUCCESS | CONFLICT | ERROR | Trials with 1 stored claim | Trials with a duplicate | Median response (ms) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 2 | 50 | 100 | 0 | 0 | 0 | 50 | 68 |
| 5 | 50 | 250 | 0 | 0 | 0 | 50 | 71 |
| 10 | 50 | 500 | 0 | 0 | 0 | 50 | 76 |
| All | 150 | 850 | 0 | 0 | 0 | 150 | 72 |

## How a trial runs

1. A new AVAILABLE listing is made from the benchmark listing (same location, weight and claim window).
2. Each NGO is checked against the 20 km road geofence using the benchmark road matrix.
3. Every request opens its own signed-in connection; all are released at the same moment.
4. Each request reads the listing without a lock, waits the race window and writes its claim.
5. A deadlock gets one retry with the same request ID; a CONFLICT is never retried.
6. The claims actually stored for the listing are read back from the database.

## How to read the results

- `claims_stored` above 1 (`more_than_one_owner` = YES) means two or more NGOs would drive to the same donation. This is the failure the baseline is meant to show (the "lost update" race).
- Response times include the race window, and the network delay when the database is a Supabase project.

## Files

| File | Content |
| --- | --- |
| `results_per_scenario.csv` | One row per contention trial |
| `details/requests.csv` | Every claim request: NGO, road distance, answer, reason, retries, response time |
| `run_info.md` | Database, PostgreSQL version, script fingerprint, settings |

### Columns of results_per_scenario.csv

| Column | Meaning |
| --- | --- |
| `scenario_id` | Benchmark contention scenario: the key used to pair this row with the proposed method |
| `listing_id` | Benchmark listing copied into the database for this trial |
| `ngos_competing` | Claim requests sent at the same moment (2, 5 or 10) |
| `different_ngos` | Different NGOs among them (the scenario has 2-4 nearby NGOs, reused in turn) |
| `told_success` | Requests told "the listing is yours" |
| `told_already_claimed` | Requests told "already claimed" (CONFLICT) |
| `told_not_eligible` | Requests refused by the 20 km road geofence or another eligibility rule |
| `failed_with_error` | Requests aborted by the database even after one retry (nothing stored) |
| `retries_after_deadlock` | Retries used after a deadlock or serialization failure |
| `claims_stored` | Active claims stored for the listing afterwards (correct = 1) |
| `more_than_one_owner` | YES = duplicate committed claim (the E2 safety metric) |
| `listing_status_after` | Listing status afterwards |
| `median_response_ms` | Middle response time of the requests |
| `slowest_response_ms` | Slowest response time |

## References

- Berenson, H., Bernstein, P., Gray, J., Melton, J., O'Neil, E., & O'Neil, P. (1995). A critique of ANSI SQL isolation levels. *Proceedings of ACM SIGMOD 1995*, 1-10. https://doi.org/10.1145/223784.223785
- PostgreSQL Global Development Group. (2026). Transaction isolation. *PostgreSQL 18 documentation*. https://www.postgresql.org/docs/18/transaction-iso.html
