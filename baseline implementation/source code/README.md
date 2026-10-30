# Baseline source code (benchmark GEOLOCK-BM-v3.3)

Each script runs one baseline method on the frozen benchmark and writes its output to its
own folder in `../result/`. Every script is standalone, reads
`../../benchmark dataset/dataset` and stops if any input file differs from the SHA-256 in
`generation_manifest.json`. The scripts do not compare methods; the experiments E1–E4 pair
each baseline with the proposed method by `scenario_id`.

## The baselines and the experiment each one belongs to

| # | Script | What it does | Experiment | Proposed method it is compared with | Main metric |
| --- | --- | --- | --- | --- | --- |
| 1 | `nearest_hub_baseline.py` | Recommends the feasible hub with the shortest road distance | E1 (RQ1) | AI hub ranking | Top-1 agreement with the reference policy |
| 2 | `random_hub_baseline.py` | Recommends a random feasible hub (fixed seed) | E1 (RQ1) | AI hub ranking | Top-1 agreement (chance level) |
| ref | `weighted_hub_baseline.py` | Reference policy: lowest 0.45 distance + 0.20 utilisation + 0.25 capacity pressure + 0.10 handling | E1 (RQ1) | – (the target, not a competitor) | – |
| 3 | `non_atomic_claim_baseline.py` | Unsafe claim: unlocked read, then write without recheck | E2 (RQ2) | Protected claim with lease recovery | Duplicate committed-claim rate |
| 4 | `protected_claim_without_lease_recovery_baseline.py` | Real `claim_listing()`, but expired claims are never released | E2 (RQ2) | Protected claim with lease recovery | Lease recovery success (and duplicate rate) |
| 5 | `direct_household_pickup_baseline.py` | No hub: every small donation collected from the donor's home | E3 (RQ3) | Community-hub aggregation | Total NGO road distance |
| 6 | `nearest_next_baseline.py` | Each vehicle drives to the nearest task it can still legally add | E4 (RQ4) | Constrained route optimiser | Valid-task coverage, then distance |
| 7 | `fcfs_baseline.py` | Each vehicle takes the earliest-confirmed task it can still legally add | E4 (RQ4, optional) | Constrained route optimiser | Valid-task coverage, then distance |

Each `summary.md` explains in plain words what the baseline does, what it is compared
with, the results and every column.

## Run

Python baselines:

```powershell
python "baseline implementation/source code/nearest_hub_baseline.py"
python "baseline implementation/source code/random_hub_baseline.py"
python "baseline implementation/source code/weighted_hub_baseline.py"
python "baseline implementation/source code/non_atomic_claim_baseline.py" 
python "baseline implementation/source code/protected_claim_without_lease_recovery_baseline.py"
python "baseline implementation/source code/direct_household_pickup_baseline.py"
python "baseline implementation/source code/nearest_next_baseline.py"
python "baseline implementation/source code/fcfs_baseline.py"
```


## Output files

| File | Content |
| --- | --- |
| `summary.md` | **Start here.** What the baseline does, what it is compared with, key results, how to read them, every column |
| `results_per_scenario.csv` | **The main result**: one row per scenario, keyed by `scenario_id` |
| `lease_results_per_scenario.csv` | Baseline 4 only: one row per lease case |
| `details/` | Supporting evidence: `hub_ranking.csv` (hubs); `requests.csv` (claims); `routes.csv`, `tasks.csv` and, for Nearest-Next, `planning_snapshots.json` (routes) |
| `run_info.md` | When and how the run was made: benchmark, script fingerprint, database, settings |

## Comparing with the proposed methods

The proposed method of each experiment must use the same inputs as its baselines and
write a `results_per_scenario.csv` with the same `scenario_id` values and column names, so
each comparison is a join on `scenario_id`.

| Experiment | Scenarios | Must be the same as the baseline |
| --- | --- | --- |
| E1 | The 349 test donations in `ai hub ranking/data split/split/test_scenario_ids.csv` (filter the 2,019 baseline rows) | Feasible hubs (five rules), road distances, tie rule (shorter distance, then hub ID), Top-k = 3 |
| E2 | 150 `CLAIM_COORDINATION` + 100 `LEASE_RECOVERY` + 25 `LEASE_ACTIVE_VERIFICATION` | Same database and schema (`01`; baseline 3 adds its own `e2_baseline` schema), same NGO order (scenario's NGO list in turn; 2 / 5 / 10 requests for scenarios 1–50 / 51–100 / 101–150), 20 km road check, 360-min lease, one retry after a deadlock, READ COMMITTED. Simplest: copy baseline 4 and call `public.recover_expired_claims()` (as `service_role`) before the second NGO claims in the lease cases |
| E3 | 100 `HUB_AGGREGATION` | Same original donations, NGO, fleet, depot, road matrix, **Nearest-Next routing**, 240-min route, 10 min per stop, cost 1.00 × km + 5.00 × trips + 0.50 per hub donation; report donor travel |
| E4 | 100 `ROUTE_PLANNING` | Same snapshots (`../result/6_nearest_next/details/planning_snapshots.json`), vehicles, capacity, 240-min route, 10 min per stop; check coverage and violations before distance |

## Rules every baseline follows

- **Hub feasibility** (five rules): the hub accepts the category, weight ≤ capacity −
  stored − reserved, the availability window overlaps the hub's opening hours for at least
  30 minutes, hub active, and a directed road route from the donor exists. Candidates are
  the hubs within 20 km (straight line) of the donor.
- **NGO eligibility**: directed NGO-to-pickup road distance ≤ 20 km (benchmark road
  matrix). The claim scripts check it before every request; the database also applies its
  own 20 km straight-line check, which agrees for every E2 scenario.
- **Lease**: 360 minutes, no renewal.
- **Routes**: one depot-returning trip per vehicle, in ascending vehicle ID; capacity,
  240-minute duration (driving + 10 min per stop + drive back) and lease are checked
  before a stop is added. An independent check recomputes every route afterwards.

## Reproducibility

Python results are identical on every run, apart from `planning_time_ms`. PostgreSQL
response times change slightly between runs; the ownership results (duplicates, claims
stored, lease outcomes) do not.

## Known limitations

- Each vehicle makes one trip; a vehicle that returns early is not reused.
- A few donors sit on one-way road sections that cannot be left towards the NGO depot, so
  2 route tasks cannot be collected (reason `ROUTE_UNAVAILABLE`).
- The claim scenarios have only 2–4 NGOs within 20 km, so with 5 or 10 requests the same
  NGOs send more than one request (each with its own request ID).
