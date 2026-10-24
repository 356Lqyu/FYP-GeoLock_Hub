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

- `public dataset/` — public inputs: OSM PBF (Geofabrik), OpenDOSM district population, NGO reference list
- `benchmark dataset/` — generator, road cache and the frozen benchmark tables (see its README and DATASET_DICTIONARY)
- `baseline implementation/` — the seven baselines of the report plus the weighted reference policy: `source code/` (scripts), `postgresql/` (test-database setup for the two claim baselines), `result/` (one folder per baseline, each with a plain-language `summary.md`)
- `ai hub ranking/` — the AI hub-ranking model: its frozen train / validation / test split (`data split/`) and, later, the training code
- `experiments/` — experiment runners
- `supabase/` — schema, migrations and backend tests of the GeoLock system
- `frontend/` — the mobile app
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

```bash
python -m pip install -r "benchmark dataset/source code/requirements.txt"
python -m pip install -r "baseline implementation/source code/requirements.txt"
```

## Generate the benchmark

See `benchmark dataset/README.md`: build the road cache with `extract_osm_python.py`,
then run `generate_geolock_benchmark.py`. The same inputs always give byte-identical CSVs.

## Run the baselines

See `baseline implementation/source code/README.md` (PostgreSQL setup:
`baseline implementation/postgresql/README.md`). Results: `baseline implementation/result/README.md`.
A baseline only produces its own method output; comparisons with the proposed system are
made by the experiments E1–E4.

| Baseline | Stage | Runs on |
| --- | --- | --- |
| Nearest-Hub, Random Hub (+ Weighted reference policy) | 5–6 | Python |
| Non-Atomic Claim, Protected Claim without Lease Recovery | 2–3 | PostgreSQL test database |
| Direct Household Pickup | 7 | Python |
| Nearest-Next, FCFS | 8 | Python |

## Benchmark and reproducibility notes

The dataset and scripts are designed to support reproducible evaluation:
- frozen scenario selection
- deterministic seeded baselines
- fixed benchmark version, seed and per-file SHA-256 in the generation manifest
- comparison against the same benchmark conditions across policies
- explicit handling of no-feasible-hub outcomes

The project report and supervision notes emphasize that the system should be judged by whether it delivers protected claim correctness, safe expiry recovery, hub aggregation value, route efficiency, and AI ranking improvements within a deterministic eligibility boundary.

## Related documentation

For a concise summary of the project methodology and the architecture decisions described in the review materials, see [MF.md](MF.md).
