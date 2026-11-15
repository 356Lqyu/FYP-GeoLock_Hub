# E2 experiment plan — Safe claiming and lease recovery

## 1. Research questions

When NGOs try to claim the same donation at once, does protected claiming leave just one owner? When an eligible claim expires, can another NGO take it over while valid claims remain protected?

## 2. Dataset

The [frozen benchmark](../../benchmark%20dataset/dataset/) provides fixed listings, NGO identities, claim states, and a directed road-distance matrix. Input hashes are checked before execution.

| Workload | Cases per applicable method |
| --- | --- |
| Contention | 150 trials and 850 requests. 50 trials each at 2, 5, and 10 concurrent requests |
| Lease expiry and safety | 100 expired leases and 25 active leases for each protected method |
| Eligibility | 1,100 pairs for the proposed method, including direct attempts from ineligible NGOs |

## 3. Methods

| Method | Claim rule | Recovery rule |
| --- | --- | --- |
| Baseline 1 | Read availability and write separately. No recheck before the write | No lease recovery |
| Baseline 2 | Check and write in one protected database operation | Recovery disabled |
| Proposed | The same protected claim function as Baseline 2 | Release eligible expired claims before the next NGO attempts takeover |

## 4. Experiment conditions

- Both [execution modes](README.md#choose-how-to-run-e2) use PostgreSQL 17, the same benchmark files, and the same methods. The driver rebuilds the test database before each method.
- Each sent request has its own signed-in connection. A barrier releases requests together. Baseline 1 uses a second barrier to ensure all availability reads finish before any claim write.
- The rules use a 20 km road-distance limit and a 360-minute lease. Prepared timestamps create expired and active cases directly. Request counts can exceed the number of distinct NGO identities.
- The response timer starts after connection and sign-in. Baseline 1 sums its two timed database calls and excludes its barrier wait. The protected methods time one call and any retry. The code allows one retry with the same request ID for a deadlock or serialization failure.

## 5. Measures

| Measure | How to read it |
| --- | --- |
| Duplicate ownership | Trials where more than one active claim was actually stored |
| Expired lease recovery | Expired cases where another NGO could take over |
| Active lease safety | Active cases where the original claim was wrongly released |
| Responses and timing | Successes, conflicts, errors, SQLSTATEs, median of trial medians, and pooled request P95 |
| Extra checks | Same-request replay, delayed competition, repeat and simultaneous recovery, stale claimants, audit consistency, and geofence decisions |

Wilson intervals describe uncertainty around observed proportions. Exact paired McNemar tests compare the same scenarios across methods for duplicate ownership and expired-lease recovery.

## 6. Execution flow

1. Check the experiment target, reset inventory, and frozen inputs.
2. Rebuild the verified target separately for each method.
3. Run the scheduled cases and record both request responses and stored database state.
4. Check that all three method outputs belong to one run and generate the comparison.
5. Use the [paper-run verifier instructions](README.md#result-files) to inspect the sealed paper evidence offline.

## 7. Interpretation and limits

An expected conflict protects the winning claim. A correct geofence allow/refuse decision can use a different rejection code from the benchmark reference. Report decision correctness and reason-code agreement separately.

This controlled workload is designed to expose a race. The timing includes database round trips and work, and can change with the machine, hosted pooler, or network. Recovery is invoked directly on prepared leases, so the result measures the recovery rules in these cases rather than production scheduler delays.
