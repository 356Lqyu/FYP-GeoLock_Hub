# Final E2/E4 summary

## E2 primary research comparison

The primary E2 comparison contains exactly three methods: non-atomic baseline; atomic without lease recovery; and atomic with lease recovery using the corrected proposed implementation. See `e2_primary_three_method_comparison.csv` for results at each concurrency level.

The 2/5/10 values are concurrent request counts, not distinct NGO counts. The frozen actor pool contains two to four distinct eligible NGOs and can reuse an identity across requests; the CSV records the per-level identity distribution. The corrected synthetic distinct-actor regression is diagnostic evidence and is not counted as GEOLOCK-BM-v3.3 benchmark data.

Lease results are in `e2_lease_comparison.csv`. The non-atomic method's lease values are N/A because that baseline did not test lease recovery. The atomic-without-recovery baseline recovered 0/100 expired leases and protected 25/25 active leases. Corrected proposed recovered/reassigned 100/100 expired leases and protected 25/25 active leases.

## E2 implementation development history

`e2_development_history.csv` keeps the original proposed version separate from the research comparison. The historical version in `e2-final-20261109-r3` had 683 request errors, all matched to rollback-confirmed SQLSTATE 40P01 audit records across the 850 contention requests. The corrected version in `e2-three-method-20261109-164724` has 0 surfaced contention request errors; corrected SQLSTATE-by-error is N/A because no request errors were recorded. Original result artifacts remain unchanged.
The corrected candidate was validated independently and compared with preserved run `e2-lockfix-final-20261109-061706`. Each run must satisfy the same frozen scenarios, exact per-scenario claim/lease/ownership invariants, and zero unexpected errors or retries. Concurrent winners may differ: `e2_corrected_reference_comparison.csv` records winner request ordinals and NGO identities per scenario, and `e2_corrected_request_differences.csv` records request-level outcome/reason/retry/SQLSTATE differences with run-scoped IDs. These are reported as scheduling differences when both runs pass the invariants. Timing is descriptive, not a parity criterion.

## E4

`e4_original_500_task_baseline.csv` reports the original 500-task Nearest-Next/FCFS admission lane. `e4_common_admission_summary.csv` reports the 483-task common-admission lane for Nearest-Next, FCFS, and CP-SAT. All 300 saved method/scenario routes passed independent validation. Paired distance and uncertainty tables are retained separately; distance conclusions remain restricted to scenarios with identical served-task sets.

Latency results are descriptive across separate runs. E2 schema/function differences confound a causal latency interpretation; E4 uncertainty intervals describe the fixed benchmark scenario set, not population inference.
