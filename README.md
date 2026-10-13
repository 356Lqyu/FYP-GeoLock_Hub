# GeoLock Hub

GeoLock Hub is a multi-NGO donation coordination system designed to prevent duplicate pickup claims, enforce service-area eligibility, and improve collection efficiency through community hub aggregation and route planning.

This repository contains the benchmark data generation and reproducible baseline implementations used to evaluate the coordination logic described in the GeoLock Hub project report and supervision notes.

## Project focus

The project is built around the following idea: donation coordination must be both operationally realistic and auditable.

Key goals:
- verify whether a donation is within an NGO's service area
- prevent concurrent NGOs from claiming the same donation
- enforce atomic claim logic and lease expiry/recovery rules
- aggregate scattered donations into suitable community hubs
- generate feasible pickup routes and compare alternative policies
- evaluate the system using a repeatable benchmark rather than ad hoc examples

The project explicitly separates:
- deterministic authority functions, which must be correctness-critical and not delegated to AI
- AI-assisted advisory functions, which can rank feasible options within a validated decision boundary

## Repository structure

- `benchmark dataset/` — benchmark generation inputs, generated dataset tables, and the reusable scenario data used by the experiments
- `baseline implementation/` — standalone baseline scripts and result exports used for comparison
- `pubic dataset/` — public reference dataset used for the geographic context
- `README.md` — project overview and usage notes
- `MF.md` — concise methodology / feature summary

## Core architecture principles

### 1. Deterministic authority boundary
The project treats donation validity, claim success, service-area checks, expiry/recovery, route feasibility, and duplicate assignment as deterministic system responsibilities. These rules must be enforced by the coordination logic and database state transitions, not by model-generated decisions.

### 2. AI-assisted advisory layer
AI can help rank valid hub or pickup options once a deterministic feasible set has already been established. It should never bypass geofencing, override claim protection, create invalid donations, or assign a donation to a second NGO.

### 3. Protected claim management
The project implements and evaluates atomic claim behavior to guarantee that only one NGO can successfully claim a donation at a time. Concurrency tests check duplicate request handling, expired lease behavior, and the inability to leave conflicting states.

### 4. Lease and recovery lifecycle
Each claim is expected to have a bounded lease. Recovery logic is needed for stale or incomplete pickups so that expired claims do not permanently block replacement attempts.

### 5. Hub aggregation and routing
The system evaluates both hub-based coordination and downstream route planning. The purpose is not to merely visualize a map, but to measure whether aggregation and routing reduce distance or improve task execution under the same frozen scenario constraints.

## Setup

Create a Python environment and install the required dependencies.

```bash
python -m pip install -r "benchmark dataset/source code/requirements.txt"
```

## Running the benchmark baselines

The baseline implementation is intentionally modular. Each script reads the frozen benchmark dataset, runs a single policy, and writes its own CSV/JSON output.

### Hub recommendation baselines

```bash
python "baseline implementation/source code/nearest_hub_baseline.py"
python "baseline implementation/source code/random_hub_baseline.py" --seed 42
```

These scripts evaluate different feasible-hub selection strategies using the frozen recommendation scenarios.

### Coordination and route baselines

```bash
python "baseline implementation/source code/non_atomic_claim_baseline.py"
python "baseline implementation/source code/protected_claim_without_lease_recovery_baseline.py"
python "baseline implementation/source code/direct_household_pickup_baseline.py"
python "baseline implementation/source code/nearest_next_baseline.py"
python "baseline implementation/source code/fcfs_baseline.py"
```

Each script writes scenario-specific result files under `baseline implementation/result` and retains the benchmark inputs unchanged.

## Benchmark and reproducibility notes

The dataset and scripts are designed to support reproducible evaluation:
- frozen scenario selection
- deterministic seeded baselines
- fixed benchmark generation version and matrix IDs
- comparison against the same benchmark conditions across policies
- explicit handling of no-feasible-hub outcomes

The project report and supervision notes emphasize that the system should be judged by whether it delivers protected claim correctness, safe expiry recovery, hub aggregation value, route efficiency, and AI ranking improvements within a deterministic eligibility boundary.

## Related documentation

For a concise summary of the project methodology and the architecture decisions described in the review materials, see [MF.md](MF.md).
