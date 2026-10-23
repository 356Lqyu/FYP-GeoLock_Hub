# Non-Atomic Claim (baseline 3)

Benchmark GEOLOCK-BM-v3.2, run on PostgreSQL (Supabase project (aws-0-ap-southeast-1.pooler.supabase.com); network delay is included in response times). This describes this method on its own; comparing it with the proposed protected claim is experiment E2.

**Method.** Read the listing without a lock, check eligibility, wait a race window of 50 ms, then write the claim without checking again. There is no one-active-claim unique index. Several NGOs press "claim" on the same listing at the same moment.

| Result | Value | Meaning |
| --- | --- | --- |
| Contention trials | 150 | One new listing per trial, claimed at the same moment by 2, 5 or 10 NGOs |
| Claim requests | 850 | One database connection per request |
| Requests answered SUCCESS | 850 | Each of these NGOs was told it owns the listing |
| Claims committed in the database | 850 | A listing should never have more than 1 |
| **Duplicate committed-claim rate** (main safety metric) | 150 of 150 trials (100%) | Trials where more than one NGO owns the listing; the ownership error this method allows |
| Requests that failed with a database error | 0 | |

## By number of concurrent requests

| Concurrent requests per trial | Trials | Requests | SUCCESS | CONFLICT | ERROR | Retries | Trials with exactly 1 committed claim | Trials with a duplicate claim | Median latency (ms) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2 | 50 | 100 | 100 | 0 | 0 | 0 | 0 | 50 | 69 |
| 5 | 50 | 250 | 250 | 0 | 0 | 0 | 0 | 50 | 71 |
| 10 | 50 | 500 | 500 | 0 | 0 | 0 | 0 | 50 | 76 |
| All | 150 | 850 | 850 | 0 | 0 | 0 | 0 | 150 | 72 |

## Request outcomes

| Outcome | Meaning |
| --- | --- |
| SUCCESS | The function answered that this NGO now holds the listing. |
| CONFLICT | The function answered that the listing is already claimed by another NGO (reason code CLAIM_CONFLICT). |
| INELIGIBLE | The NGO failed an eligibility rule (geofence, location, listing expired). |
| ERROR | The database aborted the request (e.g. deadlock) and it also failed its one retry; nothing was committed for it. |

## How the method works

1. For each trial, create a new AVAILABLE listing copied from the benchmark listing.
2. N NGOs (2, 5 or 10) each open their own database connection, sign in, and press "claim" at the same moment.
3. Each request reads the listing WITHOUT locking it and sees AVAILABLE; it checks the NGO is eligible.
4. It waits the race window (default 50 ms, standing for the gap between the app reading and writing).
5. It writes its claim and marks the listing CLAIMED, without checking again. No unique index stops a second claim.
6. After the trial, the script counts how many claims are actually stored for the listing.

## What to expect

- This is the classic read-then-write race on shared data: two transactions both read the listing as available before either commits, and each then writes its own claim. Database research treats it as a concurrency-control problem that needs locking or an equivalent rule [1, 2]; it is known as the "lost update" anomaly [3]. PostgreSQL's default READ COMMITTED isolation does not stop it unless the code locks the row or a constraint rejects the second write [4].
- Here every request reads before any request writes, so the expected result is that every request succeeds: N claims stored per trial and a duplicate in every trial (duplicate committed-claim rate 100%). This failure is the point of the baseline: it shows what goes wrong without protection.

## How to read the results

- **Requests answered SUCCESS**: how many NGOs were told "the listing is yours".
- **Claims committed in the database**: what is really stored. A correct system stores at most 1 per trial.
- **Duplicate committed-claim rate** is the key number (main safety metric): the share of trials with more than one committed active claim. 0% means safe; anything above 0% means two or more NGOs would drive to the same food.
- The table by number of concurrent requests shows the effect of more NGOs at once. **Median latency** is the time from pressing claim to getting the answer (it includes the 50 ms race window).
- `results_per_scenario.csv` has one row per trial (`more_than_one_owner` = YES marks a duplicate); `details/requests.csv` has one row per request.

## References

- [1] Gray, J. N., Lorie, R. A., Putzolu, G. R., & Traiger, I. L. (1976). Granularity of locks and degrees of consistency in a shared data base. In G. M. Nijssen (Ed.), *Modelling in Data Base Management Systems* (pp. 365-394). North-Holland. *(in the report reference list)*
- [2] Bernstein, P. A., & Goodman, N. (1981). Concurrency control in distributed database systems. *ACM Computing Surveys*, 13(2), 185-221. https://doi.org/10.1145/356842.356846 *(in the report reference list)*
- [3] Berenson, H., Bernstein, P., Gray, J., Melton, J., O'Neil, E., & O'Neil, P. (1995). A critique of ANSI SQL isolation levels. *Proceedings of ACM SIGMOD 1995*, 1-10. https://doi.org/10.1145/223784.223785 (the "lost update" anomaly) *(not yet in the report: add it if you cite it)*
- [4] PostgreSQL Global Development Group. (2026a). Transaction isolation. *PostgreSQL 18 documentation*. https://www.postgresql.org/docs/18/transaction-iso.html *(in the report reference list)*

## Files

| File | Content |
| --- | --- |
| `results_per_scenario.csv` | **The main result.** One row per contention trial. |
| `details/requests.csv` | Every single claim request (for checking response times and errors). |
| `run_info.md` | What produced this run (date, database, PostgreSQL version, script fingerprint, command). |

### Columns of results_per_scenario.csv

| Column | Meaning |
| --- | --- |
| `scenario_id` | Benchmark contention scenario (one listing, several NGOs claiming at the same moment) |
| `listing_id` | Benchmark listing that was copied into the database for this trial |
| `ngos_competing` | How many NGOs pressed "claim" at the same moment (2, 5 or 10) |
| `told_success` | NGOs told "the listing is yours" |
| `told_already_claimed` | NGOs told "already claimed" (CONFLICT) |
| `told_not_eligible` | NGOs refused by an eligibility rule |
| `failed_with_error` | Requests aborted by the database (deadlock) even after one retry; nothing was stored for them |
| `retries_after_deadlock` | Retries used after a deadlock or serialization failure |
| `claims_stored` | Active claims actually stored for the listing afterwards (correct = 1) |
| `more_than_one_owner` | YES if more than one NGO owns the listing (a duplicate claim) |
| `listing_status_after` | Listing status afterwards (CLAIMED) |
| `median_response_ms` | Middle response time of the requests in this trial |
| `slowest_response_ms` | Slowest response time in this trial |

`details/requests.csv`: one row per request (NGO, answer, reason code, retries, error message, response time in ms, request and claim IDs).
