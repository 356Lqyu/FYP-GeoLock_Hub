# Protected Claim without Lease Recovery

Benchmark GEOLOCK-BM-v3.3. Database: Supabase project (aws-0-ap-southeast-1.pooler.supabase.com); response times include the network delay.

## What this baseline does

It is the GeoLock claim **without lease recovery**. Claims are protected exactly as in the proposed system: the real `public.claim_listing()` locks the listing row, checks again that it is still AVAILABLE, and a unique index allows only one active claim per listing. The difference is that the job that releases expired claims, `public.recover_expired_claims()`, is never run. So an NGO that claims a listing and never collects it keeps it blocked, even after its 360-minute lease has expired.

## Compared with (experiment E2, RQ2)

| | This baseline | Proposed method (E2) |
| --- | --- | --- |
| Claim | `claim_listing()` | the same `claim_listing()` |
| Expired leases | never released | `recover_expired_claims()` runs before the second NGO claims |
| Same inputs | | same scenarios, listings, NGOs, request order, 20 km road geofence, 360-min lease, database and retry rule |

Pair the files by `scenario_id`. Main E2 metrics: **duplicate committed-claim rate** (`more_than_one_owner`) and **lease recovery success** (`second_ngo_got_listing` in the "lease expired" cases). Expected: both methods 0 duplicates; only the proposed method recovers expired leases; neither may take over a lease that is still running.

## Part 1 - several NGOs claim the same listing at the same moment

| Result | Value | Meaning |
| --- | --- | --- |
| Contention trials | 150 | One new listing per trial |
| Trials with exactly 1 stored claim | 150 of 150 | Correct ownership |
| **Duplicate committed-claim rate** | 0 of 150 (0%) | Must be 0% |
| Requests told CONFLICT | 700 | Clear "already claimed" answers |
| Requests failed with a database error | 0 | Should be 0 |

### By number of NGOs claiming at once

| NGOs claiming at once | Trials | SUCCESS | CONFLICT | ERROR | Trials with 1 stored claim | Trials with a duplicate | Median response (ms) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 2 | 50 | 50 | 50 | 0 | 50 | 0 | 19 |
| 5 | 50 | 50 | 200 | 0 | 50 | 0 | 28 |
| 10 | 50 | 50 | 450 | 0 | 50 | 0 | 31 |
| All | 150 | 150 | 700 | 0 | 150 | 0 | 27 |

## Part 2 - another NGO claims a listing that was claimed earlier

| Earlier claim at replay time | Cases | Second NGO got the listing | Earlier claim still active | Median response (ms) |
| --- | --- | --- | --- | --- |
| lease expired | 100 | 0 | 100 | 17 |
| lease still running | 25 | 0 | 25 | 18 |

**Lease recovery success**: 0 of 100 expired-lease listings (0%) could be claimed by another NGO. Without recovery the expired claim is never released, so the listing stays blocked; this is the gap the proposed method must close.

## How a trial runs

1. A new AVAILABLE listing is made from the benchmark listing (same location, weight and claim window).
2. Each NGO is checked against the 20 km road geofence using the benchmark road matrix.
3. Part 1: every request opens its own signed-in connection; all are released at the same moment and call `claim_listing()`. Part 2: the earlier claim is written first, timed so that "now" is the benchmark replay time, then the second NGO calls `claim_listing()`.
4. A deadlock gets one retry with the same request ID; a CONFLICT is never retried.
5. The claims actually stored for the listing are read back from the database.

## How to read the results

- `claims_stored` = 1 and `more_than_one_owner` = NO in every trial means ownership is safe.
- In "lease expired" cases, `second_ngo_got_listing` = NO is the problem this baseline shows; in "lease still running" cases NO is the correct answer.
- Response times include the network delay when the database is a Supabase project.

## Files

| File | Content |
| --- | --- |
| `results_per_scenario.csv` | Part 1: one row per contention trial |
| `lease_results_per_scenario.csv` | Part 2: one row per lease case |
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

### Columns of lease_results_per_scenario.csv

| Column | Meaning |
| --- | --- |
| `scenario_id` | Benchmark lease scenario: the key used to pair this row with the proposed method |
| `case` | "lease expired" (should be released) or "lease still running" (should be kept) |
| `listing_id` | Benchmark listing |
| `first_ngo` | NGO that claimed the listing earlier |
| `second_ngo` | Another eligible NGO that now tries to claim it |
| `second_ngo_answer` | Answer to the second NGO (SUCCESS / CONFLICT) |
| `second_ngo_reason` | Reason code (CLAIM_CONFLICT = listing still claimed) |
| `second_ngo_got_listing` | YES if the second NGO got the listing (lease recovery success) |
| `first_claim_still_active` | YES if the first NGO still holds the listing |
| `active_claims_after` | Active claims on the listing afterwards (correct = 1) |
| `listing_status_after` | Listing status afterwards |
| `second_ngo_response_ms` | Time from the second NGO pressing claim to its answer |

## References

- PostgreSQL Global Development Group. (2026). SELECT: the locking clause. *PostgreSQL 18 documentation*. https://www.postgresql.org/docs/18/sql-select.html
- Gray, C. G., & Cheriton, D. R. (1989). Leases: An efficient fault-tolerant mechanism for distributed file cache consistency. *Proceedings of the 12th ACM SOSP*, 202-210. https://doi.org/10.1145/74850.74870
