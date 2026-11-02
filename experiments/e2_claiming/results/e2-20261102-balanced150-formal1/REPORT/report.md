# GeoLock Hub E2 results

Only recorded artifacts are summarized. Incomplete and uncertain trials remain visible; this report does not label smoke runs as formal results.

Request errors include ERROR, TIMEOUT, DATABASE_ERROR, CONNECTION_ERROR, and any CLAIM_TRANSACTION_ROLLED_BACK reason code. Error reasons are listed separately. Latency summaries use every request with a recorded latency, including unsuccessful outcomes; the population size is shown. p95 uses linear interpolation over sorted observations. Wilson intervals are trial-level intervals for duplicate ownership and invariant violations; request errors are descriptive because requests within a trial are concurrent.

## NON_ATOMIC_BASELINE (contention; COMPLETE)

| Workers | Completed / planned | Duplicate ownership | Single-owner invariant | Duplicate 95% Wilson CI | Violation 95% Wilson CI | Zero winners | Errors / requests | Error rate | Latency n | Min | Median | p95 | Max (ms) |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 2 | 20 / 20 | 20 (100.0%) | 0/20 preserved; 20 violations | [83.9%, 100.0%] | [83.9%, 100.0%] | 0 | 0 / 40 | 0.0% | 40 | 86.81 | 108.15 | 124.81 | 139.50 |
  - Request error outcomes: `{}`; reason codes: `{}`; timeouts: 0.
| 5 | 20 / 20 | 20 (100.0%) | 0/20 preserved; 20 violations | [83.9%, 100.0%] | [83.9%, 100.0%] | 0 | 0 / 100 | 0.0% | 100 | 93.73 | 136.69 | 168.71 | 191.92 |
  - Request error outcomes: `{}`; reason codes: `{}`; timeouts: 0.
| 10 | 20 / 20 | 20 (100.0%) | 0/20 preserved; 20 violations | [83.9%, 100.0%] | [83.9%, 100.0%] | 0 | 0 / 200 | 0.0% | 200 | 98.46 | 179.08 | 260.29 | 296.81 |
  - Request error outcomes: `{}`; reason codes: `{}`; timeouts: 0.

## PROTECTED_ATOMIC (contention; COMPLETE)

| Workers | Completed / planned | Duplicate ownership | Single-owner invariant | Duplicate 95% Wilson CI | Violation 95% Wilson CI | Zero winners | Errors / requests | Error rate | Latency n | Min | Median | p95 | Max (ms) |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 2 | 20 / 20 | 0 (0.0%) | 20/20 preserved; 0 violations | [0.0%, 16.1%] | [0.0%, 16.1%] | 0 | 20 / 40 | 50.0% | 40 | 1021.91 | 1049.91 | 1076.82 | 1087.35 |
  - Request error outcomes: `{"ERROR": 20}`; reason codes: `{"CLAIM_TRANSACTION_ROLLED_BACK": 20}`; timeouts: 0.
| 5 | 20 / 20 | 0 (0.0%) | 20/20 preserved; 0 violations | [0.0%, 16.1%] | [0.0%, 16.1%] | 0 | 80 / 100 | 80.0% | 100 | 1020.19 | 3061.23 | 4104.88 | 4125.37 |
  - Request error outcomes: `{"ERROR": 80}`; reason codes: `{"CLAIM_TRANSACTION_ROLLED_BACK": 80}`; timeouts: 0.
| 10 | 20 / 20 | 0 (0.0%) | 20/20 preserved; 0 violations | [0.0%, 16.1%] | [0.0%, 16.1%] | 0 | 179 / 200 | 89.5% | 200 | 49.76 | 5098.24 | 9166.29 | 9184.76 |
  - Request error outcomes: `{"ERROR": 179}`; reason codes: `{"CLAIM_TRANSACTION_ROLLED_BACK": 179}`; timeouts: 0.

## Paired analysis

Not computed: the runner gives each condition fresh independent fixtures and does not establish matched trial pairs. Trial-number matching alone would not justify McNemar analysis.


## Lease recovery

Completed 30 / 30; successful release and reclaim 30 (100.0%); 95% Wilson CI [88.6%, 100.0%].

Raw JSON is the source of record. A trial without confirmed post-trial state is not considered completed.
