# Standalone GeoLock Hub baselines

Each script contains its own dataset loading, feasibility checks, selection
algorithm, metric calculation, and result export. Neither imports the other
script or a shared baseline module. Python's standard library is sufficient.

- `nearest_hub_baseline.py` sorts feasible hubs by frozen directed donor-to-hub
  road distance, then hub ID, and selects the first hub.
- `random_hub_baseline.py` uniformly shuffles the same feasible hubs using a
  recorded seed (default 42) and selects the first hub. Distance and reference
  scores do not influence random selection.

Both read `benchmark dataset/dataset` relative to the workspace root, process
the same recommendation scenarios, and write separate CSV rankings,
recommendations, and JSON summaries to `baseline implementation/result`.
No-feasible-hub scenarios produce explicit `NO_FEASIBLE_HUB` results.

From the workspace root:

```powershell
python "baseline implementation/source code/nearest_hub_baseline.py"
python "baseline implementation/source code/random_hub_baseline.py" --seed 42
```

Both support `--dataset-dir`, `--output-dir`, `--scope`, `--scenario-ids`, and
`--top-k`. For formal held-out evaluation, pass the same frozen test scenario
selection with `--scenario-ids` to both scripts. Default all-scenario metrics
are exploratory rather than held-out test results.

Verified on the supplied benchmark: each script processes 2,023 scenarios,
producing 2,000 recommendations and 23 no-feasible-hub outcomes. Nearest-Hub
Top-1 agreement is 0.7015; Random Hub at seed 42 is 0.1465.

## Remaining report baselines

All five scripts below are standalone: each contains its own loading,
algorithm, validation, and export functions and uses only Python's standard
library. They read the same benchmark and preserve its files unchanged.

| Script | Report baseline | Default scenarios |
| --- | --- | ---: |
| `non_atomic_claim_baseline.py` | Read-before-write claim race | 150 contention trials |
| `protected_claim_without_lease_recovery_baseline.py` | Protected claim; expiry does not release ownership | 150 contention + 100 expired + 25 active lease cases |
| `direct_household_pickup_baseline.py` | Original small donations remain separate pickup stops | 100 matched direct/hub pairs |
| `nearest_next_baseline.py` | Nearest currently feasible stop | 100 route scenarios |
| `fcfs_baseline.py` | Earliest confirmed currently feasible task | 100 route scenarios |

```powershell
python "baseline implementation/source code/non_atomic_claim_baseline.py"
python "baseline implementation/source code/protected_claim_without_lease_recovery_baseline.py"
python "baseline implementation/source code/direct_household_pickup_baseline.py"
python "baseline implementation/source code/nearest_next_baseline.py"
python "baseline implementation/source code/fcfs_baseline.py"
```

All support `--dataset-dir`, `--output-dir`, `--scenario-ids`, `--geofence-km`
(20), and `--lease-minutes` (360). Scenario selections accept a CSV
`scenario_id` column or one ID per line. Input hashes must agree with the
generation manifest. Version, matrix ID, input/code hashes, configuration,
selected scenarios, and configuration digest are retained in JSON summaries.

### Claim conditions

The report's default contention design is 50 trials at each of 2, 5, and 10
workers. Sorted scenario ordinals 1-50, 51-100, and 101-150 determine those
cohorts in both scripts. `--workers 2`, `--workers 5`, or `--workers 10`
overrides the cohort for an exploratory run. Workers reuse the scenario's NGO
identities in round-robin order, with a distinct request/idempotency key per
worker. Every attempted request is logged, including ineligible requests.

Both scripts release actual Python threads through a synchronization barrier.
In Non-Atomic Claim, workers read availability before the barrier and commit
from that stale read, deliberately omitting revalidation and active-claim
uniqueness. In the protected condition, availability recheck and simulated
commit occur under one lock after the barrier. Thread scheduling can change
the winning requester; the input schedule and cohort remain identical.

Expired claims in the no-recovery condition remain retained and block
replacement. Their valid-authority flag is zero; retained expired ownership
is not presented as a valid active lease. Active claims reject replacement.
Uncertain physical transfer requires reconciliation. This script deliberately
does not implement the proposed recovery-enabled method.

Each writes `<method>_results.csv`, `_requests.csv`, `_claims.csv`, `_tasks.csv`,
and `_summary.json`. Duplicate-claim rates use complete contention trials as
the denominator, separately by worker cohort. Request rows are not independent
trials. The unsafe schedule deliberately forces the race; its frequency is not
an estimate of naturally occurring production races.

These are **in-memory controlled simulations**. They do not implement the
report's PostgreSQL READ COMMITTED transactions, database constraints,
transport retries, authentication, or production claim authority. Those
integration experiments are still required for formal E2 database claims.

### Routing conditions

Both route scripts construct the same sealed task snapshot from the same
initial listings. At the latest source availability start, they simulate serial
protected admission for the intended NGO, check the directed 20 km geofence,
create confirmed tasks with 360-minute leases, and retain exclusions. The same
task IDs, owner, timestamps, fleet, and snapshot digest are used for both
methods; tests verify all 100 snapshots are identical.

Vehicle order is ascending vehicle ID. Each vehicle makes at most one route,
starting and returning to its declared depot. Nearest-Next chooses by current
directed road distance, then task ID. FCFS chooses by confirmed task creation
time, then task ID, deferring currently infeasible tasks rather than blocking
later tasks. This FCFS deferral policy is recorded explicitly because the
report does not freeze that detail. Task timestamps are created by the common
claim schedule, not copied from an assumed benchmark task table. Simultaneous
claims therefore use task IDs to break FCFS ties.

The defaults are `--route-minutes 240` and `--service-minutes 10`. Duration
includes outbound/inter-stop travel, service at every stop, and depot return.
Unavailable directed arcs are excluded without a straight-line fallback.
Capacity, authority, and lease sufficiency through service completion are
checked before adding a stop. Remaining tasks retain capacity, connectivity,
duration, lease, or exhausted-fleet reasons.

`--safety-margin-minutes` defaults to **0 for exploratory runs**. The report
requires this margin to be frozen but does not supply its value. Choose and
record the formal margin before comparing with the optimiser. No live
pre-dispatch revalidation or dispatch authorisation is issued.

The independent validator recomputes every emitted route from its stop IDs:
exactly-once task accounting, valid authority, lease duration, vehicle payload,
directed arcs, stop timing, depot return, distance, and total route duration.
An invalid plan raises an error rather than producing a success summary.

Each route runner writes `_results.csv`, `_routes.csv`, `_tasks.csv`,
`_snapshots.json`, and `_summary.json`. Snapshots include confirmed task and
claim records; task outputs retain served, unserved, and excluded cases.
Reuse the matching snapshot content and experiment configuration in the
proposed optimiser. Compare coverage before comparing distance.

### Direct Household Pickup and the matched hub reference

The direct script processes HUB_AGGREGATION scenarios and retains every
ORIGINAL_DONATION as its own household pickup opportunity. This is the
intentional E3 counterfactual for small donations; it does not reclassify the
benchmark donations. It also creates the matched hub-condition reference from
the same originals, NGO, fleet, cutoff, lease/service/horizon settings, and
Nearest-Next downstream routing rule.

The hub reference checks 3-5 compatible members, at most 30 kg, membership
uniqueness, initial feasibility and total hub capacity. It simulates protected
reservation, verified receipt, stored inventory, batching and publication,
then claims the published batch as one pickup opportunity. These transitions
are simulated evidence, not verified physical receipts or live database
transactions. Sealed snapshots retain the custody transition records.

Report original-donation coverage across conditions; hub task counts and
household task counts are not directly comparable. The runner additionally
writes `_pairs.csv` and `_cost_sensitivity.csv`. Costs use the report's
benchmark index: 1.00 unit per NGO road-km + 5.00 per dispatch + 0.50 per
original donation handled through the hub. Sensitivity varies each coefficient
and all jointly by 0.5 and 2.0, with the 1.0 base retained. These are index units,
not Malaysian ringgit or observed expenditure.

Donor burden is the sum of frozen **one-way** donor-to-hub road distances,
reported separately; donor return trips are not assumed. Burden is retained
even if an NGO later leaves a hub task unserved. Compare distance/cost only
after examining matched coverage and failures. Default metrics are exploratory;
no formal paired significance or bootstrap results are claimed.

### Executed remaining baseline results

| Condition | Executed result |
| --- | --- |
| Non-Atomic Claim | 150/150 forced-race trials produce duplicate claims |
| Protected Claim without Lease Recovery | 0/150 duplicate trials; 100 expired leases remain unrecovered; 25 active leases reject replacement |
| Nearest-Next | 453/500 valid tasks served; 47 retained unserved |
| FCFS | 451/500 valid tasks served; 49 retained unserved |
| Direct Household Pickup | 418/418 originals collected over 100 scenarios; 2,523.75559 NGO road-km |
| Matched hub reference | 418/418 originals collected; 1,428.54013 NGO road-km and 1,668.60605 donor one-way road-km |

Both matched E3 conditions use 100 NGO dispatches. All emitted routing plans
pass independent constraint validation. Thirteen automated checks cover
algorithm differences, capacity, directed return availability, duration,
lease margin, tampered outputs, physical-transfer uncertainty, schedule parity,
all E4 snapshot comparisons, and E3 original/fleet/cutoff parity.

### Report review and reconciliation before formal results

Implementation follows Sections 3.6, 3.8.2, 4.5 / Table 4.7, Algorithms 6-9,
Table 4.9, and Table A.4. Benchmark inputs deliberately exclude claims, tasks,
request execution configuration, and route solutions; runners create those
states without treating initial benchmark records as already committed.

Equation 4.1 on PDF page 80 puts threshold equality on the community-hub path,
but Algorithm 1, Table 4.9, and the supplied generator place 10 kg equality on
the direct-household path. Reconcile Equation 4.1 before formal verification.
The remaining baselines use the benchmark's declared paths, and E3's direct
condition explicitly changes the collection mechanism as required.

Freeze the FCFS deferral policy, vehicle order, safety margin, simulated claim
schedule and receipt assumptions alongside the formal configuration. Replace
the in-memory coordination layer with the report's real protected backend
before interpreting these runs as PostgreSQL concurrency, physical-custody,
or live dispatch evidence. Proposed recovery and constrained optimisation
remain separate methods, not extra baselines implemented here.
