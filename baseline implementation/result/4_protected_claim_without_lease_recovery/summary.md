# Protected Claim without Lease Recovery (baseline 4)

Benchmark GEOLOCK-BM-v3.2, run on PostgreSQL (Supabase project (aws-0-ap-southeast-1.pooler.supabase.com); network delay is included in response times). This describes this method on its own; comparing it with the proposed recovery-enabled claim is experiment E2.

**Method.** The GeoLock claim function `public.claim_listing()` (row lock, recheck, one-active-claim unique index, idempotent request ID), but the job that releases expired claims (`public.recover_expired_claims()`) is never run.

## Part 1 - Several NGOs claim the same listing at the same moment

| Result | Value | Meaning |
| --- | --- | --- |
| Contention trials | 150 | One new listing per trial, claimed at the same moment by 2, 5 or 10 NGOs |
| Trials with exactly 1 committed claim | 150 of 150 | Correct ownership |
| **Duplicate committed-claim rate** (main safety metric) | 0 of 150 trials (0%) | Must be 0% |
| Requests that failed with a database error | 602 of 850 | Deadlock even after one retry; nothing was committed for these requests, but the NGO got an error instead of a clear CONFLICT answer |

### By number of concurrent requests

| Concurrent requests per trial | Trials | Requests | SUCCESS | CONFLICT | ERROR | Retries | Trials with exactly 1 committed claim | Trials with a duplicate claim | Median latency (ms) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2 | 50 | 100 | 50 | 50 | 0 | 39 | 50 | 0 | 1,022 |
| 5 | 50 | 250 | 50 | 24 | 176 | 221 | 50 | 0 | 6,087 |
| 10 | 50 | 500 | 50 | 24 | 426 | 477 | 50 | 0 | 13,026 |
| All | 150 | 850 | 150 | 98 | 602 | 737 | 150 | 0 | 9,064 |

## Part 2 - Another NGO tries to claim a listing whose claim was made earlier

| Prior claim at replay time | Cases | Replacement NGO got the listing | Answer to the replacement NGO | Prior claim still ACTIVE afterwards | Listing status afterwards |
| --- | --- | --- | --- | --- | --- |
| ACTIVE (lease still running) | 25 | 0 | CONFLICT CLAIM_CONFLICT | 25 | CLAIMED |
| EXPIRED (lease expired) | 100 | 0 | CONFLICT CLAIM_CONFLICT | 100 | CLAIMED |

**Lease recovery success** (main metric): 0 of 100 expired-lease cases (0%) were released and reclaimed.

Without lease recovery, 100 of 100 listings whose lease had already expired stayed blocked: the expired claim was never released, so no other NGO could collect the food. Refusing the replacement NGO is correct only while the lease is still running.

## Request outcomes

| Outcome | Meaning |
| --- | --- |
| SUCCESS | The function answered that this NGO now holds the listing. |
| CONFLICT | The function answered that the listing is already claimed by another NGO (reason code CLAIM_CONFLICT). |
| INELIGIBLE | The NGO failed an eligibility rule (geofence, location, listing expired). |
| ERROR | The database aborted the request (e.g. deadlock) and it also failed its one retry; nothing was committed for it. |

## How the method works

1. Part 1: for each trial, create a new AVAILABLE listing; N NGOs (2, 5 or 10) press "claim" at the same moment, each on its own signed-in connection.
2. Each request calls the real `public.claim_listing()`: it records the request ID, locks the listing row (`SELECT ... FOR UPDATE`), checks again that it is still AVAILABLE, then writes the claim with a 360-minute lease. A unique index allows only one active claim per listing; repeating a request ID returns the same answer.
3. Part 2: a listing already has a claim made earlier, with its lease either expired or still running at the replay time. Another NGO then tries to claim it.
4. The recovery job `public.recover_expired_claims()` is never run, so an expired claim is never released.

## What to expect

- Locking the row and checking again turns the claims into a queue: the first request wins and every later one sees CLAIMED and gets CONFLICT [1, 2]. Expected: exactly 1 claim in every trial, no duplicates.
- A lease limits how long a holder can block others, but only if expired leases are actually taken back [3]. Without recovery, an expired claim keeps the listing CLAIMED forever. Expected: 0 expired listings reclaimed (the problem), and 0 active ones reclaimed (correct).
- Known side effect in the current function: recording the request first makes PostgreSQL take a key-share lock on the listing (foreign key), and `FOR UPDATE` conflicts with that lock [2]. Concurrent requests then wait for each other (deadlock) and PostgreSQL aborts one of them [2]. Expected: database errors that grow with the number of simultaneous NGOs, with nothing wrongly committed. Using `FOR NO KEY UPDATE` removes it (see `postgresql/README.md`).

## How to read the results

- **Trials with exactly 1 committed claim** must equal the number of trials: that is the safety result.
- **Duplicate committed-claim rate** must be 0%.
- **Lease recovery success** is the share of expired-lease cases that another NGO could claim; without recovery it is expected to be 0%, which is the gap the proposed lease recovery must close.
- **Requests that failed with a database error** are requests aborted by a deadlock. They wrote nothing, so safety holds, but the NGO got an error instead of a clear "already claimed". Read it together with **Median latency**: seconds instead of milliseconds also come from deadlock waiting.
- Part 2 table: in the EXPIRED row, **Replacement NGO got the listing** = 0 and **Prior claim still ACTIVE** = all cases is the lease-recovery problem this baseline is meant to show. In the ACTIVE row, 0 is the correct answer (the lease is still running).
- `results_per_scenario.csv` (Part 1), `lease_results_per_scenario.csv` (Part 2) and `details/requests.csv` (every request) hold the details.

## References

- [1] PostgreSQL Global Development Group. (2026b). SELECT (the locking clause: FOR UPDATE, FOR NO KEY UPDATE). *PostgreSQL 18 documentation*. https://www.postgresql.org/docs/18/sql-select.html *(in the report reference list)*
- [2] PostgreSQL Global Development Group. (2026). Explicit locking (row-level lock conflicts, deadlocks). *PostgreSQL 18 documentation*. https://www.postgresql.org/docs/18/explicit-locking.html *(not yet in the report: add it if you cite it)*
- [3] Gray, C. G., & Cheriton, D. R. (1989). Leases: An efficient fault-tolerant mechanism for distributed file cache consistency. *Proceedings of the Twelfth ACM Symposium on Operating Systems Principles*, 202-210. https://doi.org/10.1145/74850.74870 *(in the report reference list)*

## Files

| File | Content |
| --- | --- |
| `results_per_scenario.csv` | **Main result, part 1.** One row per contention trial. |
| `lease_results_per_scenario.csv` | **Main result, part 2.** One row per lease case. |
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

### Columns of lease_results_per_scenario.csv

| Column | Meaning |
| --- | --- |
| `scenario_id` | Benchmark lease scenario |
| `case` | "lease expired" (the first claim should be released) or "lease still running" (it should be kept) |
| `listing_id` | Benchmark listing |
| `first_ngo` | NGO that claimed the listing earlier |
| `second_ngo` | Another eligible NGO that now tries to claim it |
| `second_ngo_answer` | Answer given to the second NGO (SUCCESS / CONFLICT) |
| `second_ngo_reason` | Reason code of that answer (CLAIM_CONFLICT = listing still claimed) |
| `second_ngo_got_listing` | YES if the second NGO got the listing |
| `first_claim_still_active` | YES if the first NGO still holds the listing afterwards |
| `active_claims_after` | Active claims on the listing afterwards (correct = 1) |
| `listing_status_after` | Listing status afterwards |

`details/requests.csv`: one row per request (NGO, answer, reason code, retries, error message, response time in ms, request and claim IDs).
