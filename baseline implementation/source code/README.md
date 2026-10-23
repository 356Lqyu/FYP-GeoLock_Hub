# Baseline source code (benchmark GEOLOCK-BM-v3.2)

Each script runs one baseline method on the frozen benchmark and writes that method's own
output to its own folder in `../result/`, including a plain-language `summary.md`. The
scripts do not compare methods; comparisons are made later by the experiments, on the
same scenarios.

Every script is standalone (no shared helper file). It reads `../../benchmark dataset/dataset`
and refuses to run if any input file differs from the SHA-256 recorded in
`generation_manifest.json`.

## The baselines

| # | Script | What it does | Runs on | Output folder |
| --- | --- | --- | --- | --- |
| 1 | `nearest_hub_baseline.py` | Recommends the feasible hub with the shortest road distance from the donor | Python | `result/1_nearest_hub/` |
| 2 | `random_hub_baseline.py` | Recommends a random feasible hub (fixed seed, so reruns are identical) | Python | `result/2_random_hub/` |
| 3 | `non_atomic_claim_baseline.py` | Unsafe claim: reads the listing without a lock, then writes the claim without checking again | **PostgreSQL** | `result/3_non_atomic_claim/` |
| 4 | `protected_claim_without_lease_recovery_baseline.py` | The real protected `claim_listing()`, but expired claims are never released | **PostgreSQL** | `result/4_protected_claim_without_lease_recovery/` |
| 5 | `direct_household_pickup_baseline.py` | No hub: the NGO collects every small donation from each donor's home | Python | `result/5_direct_household_pickup/` |
| 6 | `nearest_next_baseline.py` | Route: each vehicle drives to the nearest pickup it can still legally add | Python | `result/6_nearest_next/` |
| 7 | `fcfs_baseline.py` | Route: each vehicle takes the earliest-confirmed pickup it can still legally add | Python | `result/7_fcfs/` |
| ref | `weighted_hub_baseline.py` | Reference hub policy: lowest weighted score (0.45 distance + 0.20 utilisation + 0.25 capacity pressure + 0.10 handling) | Python | `result/ref_weighted_hub/` |

`ref` is the reference ranking that hub methods are measured against, not a competing
baseline.

## Run the Python baselines (1, 2, 5, 6, 7, ref)

Standard library only (Python 3.11 or newer). From the repository root:

```powershell
python "baseline implementation/source code/nearest_hub_baseline.py"
python "baseline implementation/source code/random_hub_baseline.py"
python "baseline implementation/source code/weighted_hub_baseline.py"
python "baseline implementation/source code/direct_household_pickup_baseline.py"
python "baseline implementation/source code/nearest_next_baseline.py"
python "baseline implementation/source code/fcfs_baseline.py"
```

No options are needed; each script takes a few seconds.

## Run the PostgreSQL baselines (3, 4)

First run the one-time setup of the Supabase baseline project (`../postgresql/README.md`).
Then, from the repository root:

```powershell
pip install -r "baseline implementation/source code/requirements.txt"
python "baseline implementation/source code/non_atomic_claim_baseline.py"
python "baseline implementation/source code/protected_claim_without_lease_recovery_baseline.py"
```

Baseline 3 takes about a minute; baseline 4 about 20 minutes (deadlock waiting, see
Known limitations).

How a trial runs:

- **Contention trial**: a fresh AVAILABLE listing is copied from the benchmark listing
  (same location, weight, lifetime). N NGOs each get their own database connection,
  signed in the way Supabase does (role `authenticated` + `request.jwt.claims`), and all
  press "claim" at the same moment. A deadlock or serialization failure gets one retry
  with the same request ID; an "already claimed" answer is never retried. The claims
  actually stored are then read back from the database.
- **Lease case** (baseline 4): a claim made earlier is placed so that "now" is the
  benchmark replay time (expired: claimed 7 h ago, lease ended 1 h ago; still active:
  claimed 2 h ago, 4 h left). Then another NGO tries to claim the listing.

## Output files

Every result folder has the same layout:

| File | Content |
| --- | --- |
| `summary.md` | **Start here.** Key numbers in plain words, how the method works, what to expect, how to read it, and the meaning of every column |
| `results_per_scenario.csv` | **The main result**: one row per scenario, readable column names with units, YES/NO flags. Experiments pair this file with the proposed method's file of the same format (see `../result/README.md`) |
| `details/` | Supporting evidence: `hub_ranking.csv` (hubs); `requests.csv` (claims); `routes.csv`, `tasks.csv` and, for Nearest-Next, `planning_snapshots.json` (routes) |
| `run_info.md` | When and how the run was made: benchmark, script fingerprint, database, command to repeat |

Baseline 4 has a second main file, `lease_results_per_scenario.csv` (one row per lease case).

## Rules every baseline follows (same as the backend)

- **Hub feasibility**: the hub accepts the category, weight ≤ capacity − stored − reserved,
  hub active, and a directed road route from the donor exists. Candidates are the hubs
  within 20 km (straight line) of the donor.
- **NGO eligibility**: route scripts use road distance ≤ 20 km; the PostgreSQL scripts use
  the database's own straight-line 20 km check (every requester in these scenarios is
  within 20 km by road, so also in a straight line).
- **Lease**: 360 minutes.
- **Routes**: one depot-returning trip per vehicle, in ascending vehicle ID; capacity,
  240-minute duration (driving + 10 min per stop + drive back) and lease are checked
  before a stop is added. A separate check recomputes every route afterwards and stops the
  run on any violation.

## Reproducibility

Python results are identical on every run, apart from `planning_runtime_ms`. The
PostgreSQL results depend on timing, so latencies and error counts change slightly between
runs; the ownership results (duplicates, claims stored, lease outcomes) do not. Every
`run_info.json` records the benchmark version, the SHA-256 of the inputs and of the script,
and the settings.

## Known limitations

- **To confirm – routing rule of baseline 5.** Direct Household Pickup is compared with
  community-hub aggregation, not with route planning. Routes are only used to measure the
  NGO's driving distance, and both sides must use the same routing rule. Baseline 5 uses
  Nearest-Next; if the hub side is planned with the route optimiser instead, baseline 5
  must be rerun with the same optimiser.

- Each vehicle makes one trip; a vehicle that returns early is not reused.
- 24 of 3,800 donors and 1 hub are on one-way road sections that can be entered but not
  left towards a depot, so 2 route tasks cannot be collected.
- Baseline 4 inherits a deadlock in the current `claim_listing()`: with 5 or 10
  simultaneous NGOs most losing requests fail with a database error instead of an
  "already claimed" answer. Ownership stays correct. Fix and details in
  `../postgresql/README.md`.
