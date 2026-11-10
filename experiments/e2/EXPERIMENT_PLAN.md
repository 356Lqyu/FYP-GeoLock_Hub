# E2 plan: safe claiming and lease recovery

## Questions
1. When several NGOs claim the same donation at the same time, does exactly one of them get it?
2. When an NGO claims a donation and never comes, is the donation released after its 6 hour lease so another NGO can
   take it, without ever taking away a claim that is still valid?
3. Check of the proposed method: can only NGOs within 20 km by road claim? (Geofence eligibility correctness.)

## Data (frozen benchmark GEOLOCK-BENCHMARK-DATASET)
| Part | Benchmark scenarios | Trials |
| --- | --- | --- |
| Contention | 150 `CLAIM_COORDINATION` | 50 trials at each of 2, 5 and 10 NGOs claiming one listing at the same time |
| Lease | 100 `LEASE_RECOVERY` + 25 `LEASE_ACTIVE_VERIFICATION` | 100 lease expiry and reclaim trials, plus 25 leases that are still running |
| Geofence check | 100 `GEOFENCE_VERIFICATION` | 1,100 NGO and listing pairs (100 listings × 11 NGOs) |

Every input file is checked against its SHA-256 in `generation_manifest.json`.

## Conditions (report Table 3.6)
| | Non-Atomic Claim (baseline 1) | Protected Claim without Lease Recovery (baseline 2) | Protected Claim with Lease Recovery (proposed) |
| --- | --- | --- | --- |
| Claim | check availability and save the claim as two separate steps: no lock, no second check, no one claim rule | the app's `claim_listing()` | the app's `claim_listing()` |
| Expired leases | never released | never released | the app's `recover_expired_claims()`, run as the scheduler before the next NGO claims |
| Trials | contention (part 1) | lease (part 2) | contention, lease, geofence check and extra checks |

Each baseline removes one protection of the proposed method and is compared with it on the part that protection is for:
baseline 1 against the proposed method on contention, baseline 2 against the proposed method on leases. The two sides of
each comparison start from the same scenario state and use the same listing, NGO set and request schedule.

## Contention setting (recorded in each `run_info.md`)
* Concurrency: 2, 5 and 10 NGOs, 50 trials each.
* Synchronisation: one database connection per NGO; a barrier releases all requests of a trial together. In
  baseline 1 a second barrier makes every NGO finish its check before any NGO saves.
* Isolation: READ COMMITTED.
* Retry: a request that hits a deadlock or serialization failure is retried once with the same request ID.
* Timeout: 15 s to connect, 30 s per statement, 60 s at a barrier.
* Road geofence 20 km, lease 360 minutes.

## Measures
* **Main 1:** duplicate committed claim rate, the share of contention trials that end with more than one saved owner
  (read from the database, not from the answers).
* **Main 2:** lease recovery success, the share of expired lease trials where another NGO could take the donation over.
* Also: valid leases wrongly released (must be 0), the answers each NGO got, trials where answers and saved data
  disagree, attempts recorded in the audit log, response time and requests per second.
* Extra checks of the proposed method: sending the same request ID again, a claim held open for 1 second while another
  NGO claims (50 trials), running recovery twice, the old NGO trying again, two recovery jobs at the same moment, and
  the geofence check.
* Uncertainty: 95 % Wilson intervals and an exact McNemar test on the paired trials.

## Steps
1. For each condition: rebuild the database, then run it.
2. Run the comparison. It only reads the result folders.
