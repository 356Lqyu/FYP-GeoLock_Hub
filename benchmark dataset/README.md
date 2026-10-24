# GeoLock Hub Benchmark Dataset — v3.2

A frozen, reproducible dataset for testing GeoLock Hub from donation intake to route
planning. It mixes **real public data** (11 NGOs, OpenStreetMap roads and community
halls, OpenDOSM population) with **synthetic operational records** (donors, donations,
hub states, vehicles).

The dataset holds **inputs only**: no baseline or proposed-method output, no claims,
tasks or routes, and no train/test split. Baselines and experiments read it and write
their own results elsewhere.

## Folder

```
benchmark dataset/
├── README.md                 this file
├── DATASET_DICTIONARY.md     every column and why it exists
├── source code/
│   ├── extract_osm_python.py           step 1: OSM PBF -> road cache
│   ├── generate_geolock_benchmark.py   step 2: road cache + public data -> dataset/
│   └── requirements.txt
├── road cache/               made by step 1 (road_nodes, road_edges, household_nodes, osm_hub_candidates)
└── dataset/                  made by step 2: 15 CSV + 2 JSON
```

Public inputs live in `../public dataset/`: `malaysia-singapore-brunei.osm.pbf`
(Geofabrik), `population_district.csv` (OpenDOSM), `NGO_references.csv`.

## Generate

Run from the repository root. Each step takes about 4 minutes.

```bash
python -m pip install -r "benchmark dataset/source code/requirements.txt"

python "benchmark dataset/source code/extract_osm_python.py" "public dataset/malaysia-singapore-brunei.osm.pbf" "benchmark dataset/road cache/road_nodes.csv" "benchmark dataset/road cache/road_edges.csv" "benchmark dataset/road cache/osm_hub_candidates.csv" --ngos "public dataset/NGO_references.csv"

python "benchmark dataset/source code/generate_geolock_benchmark.py" --population-retrieved YYYY-MM-DD --osm-retrieved YYYY-MM-DD --ngo-retrieved YYYY-MM-DD
```

The three `--...-retrieved` dates are the download dates of the public files; they are
only recorded in the manifest. The same inputs and seed (20260915) always produce
byte-identical CSVs.

## Tables

| File | Rows | Content | Real or synthetic |
| --- | --- | --- | --- |
| `ngos.csv` | 11 | NGOs with coordinates and road node | Real |
| `hubs.csv` | 180 | OSM community centres / town halls as candidate hubs | Location real; capacity, load, categories synthetic |
| `donors.csv` | 3,800 | Donor home coordinates (each on a real residential-type street node) | Synthetic |
| `donations.csv` | 3,800 | Category, weight, availability, collection path | Synthetic |
| `donation_hub_candidates.csv` | 91,675 | Every hub within 20 km of each small donation, hard-rule flags, reference score | Derived |
| `listings.csv` | 1,185 | Claimable pickups (direct-household donations) | Derived |
| `vehicles.csv` | 22 | Per NGO: one car (100 kg), one van (500 kg) | Synthetic |
| `hub_batches.csv`, `hub_batch_members.csv` | 100 / 417 | Batch templates of small donations at one hub | Derived |
| `road_nodes.csv` | 3,991 | Coordinates of every road node used | Real (OSM) |
| `road_distance_matrix.csv` | 141,175 | Directed road distance and travel time between nodes | Real (OSM) |
| `scenarios.csv`, `scenario_members.csv` | 2,594 / 76,562 | Test cases and the records each one uses | Selection |
| `claim_initial_states.csv` | 125 | Prior claim state for lease replay cases | Synthetic |
| `verification_cases.csv` | 8 | Weight inputs and expected collection path | Fixed |
| `generation_manifest.json` | — | Version, seed, sources, rules, donor-sampling record, row counts, SHA-256 per file | — |
| `validation_summary.json` | — | Results of the generation checks | — |

Study area: the 17 km road-extract window around each NGO — Klang Valley (4 NGOs),
Johor Bahru, Penang, Ipoh, Seremban, Kuantan, Kemaman and Kuala Muda.

## Generation rules

| Item | Rule |
| --- | --- |
| Donor location | Locality quota ∝ OpenDOSM district population × proximity to the nearest NGO; each donor home = an unused road node on a residential, living_street, service or unclassified street (never a main road or highway) within 5.5 km of the locality (full record in the manifest, `donor_sampling`) |
| Snapping | NGO and hub points map to the nearest drivable node within 500 m; donors are placed on nodes |
| Roads | Directed OSM drivable graph; unreachable pairs have `route_available_flag = 0`; no straight-line fallback |
| Donation weight | 0.5–30 kg (furniture ≥ 7 kg, appliances ≥ 3 kg, electronics ≥ 0.8 kg); fixed boundary cases 9.9 / 10.0 / 10.1 kg |
| Collection path | < 10 kg → COMMUNITY_HUB (2,615); ≥ 10 kg → DIRECT_HOUSEHOLD (1,185) |
| Availability | Opens 09:00–14:00 on 2 Nov 2026; closes 17:00–21:00, 0–3 days later; at least 8 hours |
| Hub state | Capacity 50–250 kg; stored load 0–95 %; reserved 0–20 % (never above what remains); 5 % inactive |
| Hub categories | All six, except: no furniture below 100 kg capacity; half the hubs decline one more category |
| Candidate hubs | Every hub within 20 km (straight line) of the donor |
| Hard feasibility | Category accepted AND weight ≤ remaining capacity AND hub active AND a directed donor-to-hub route |
| Reference score | 0.45 × road distance (min-max within the feasible hubs) + 0.20 × utilisation + 0.25 × capacity pressure + 0.10 × handling penalty; lower is better; ties by distance, then hub ID |
| NGO eligibility | Directed NGO-to-pickup road distance ≤ 20 km |
| Batch template | Small donations whose top reference-score hub is the same; one category; 3–5 items; ≤ 30 kg; taken in order of availability |
| Lease cases | Claim expires 6 h after the listing opens; expired cases replay at 7 h, active cases at 2 h; replay is always before listing expiry |

## Settings fixed by the data

These values shape which records and scenarios exist. Changing them requires
regenerating the dataset (new version):

- 10 kg collection threshold
- 20 km radius (candidate hubs and NGO eligibility)
- The four hard hub rules and the reference-score weights
- Batch limits: 3–5 donations, ≤ 30 kg, one category
- 6-hour (360-minute) lease in `claim_initial_states`

Everything else is set by each baseline or experiment run and is not stored here: the
train/validation/test split, number of concurrent workers, route duration limit, service
time, safety margin, solver settings, Top-k, and random seeds of baselines.

## Checks run at generation

All pass for v3.2 (counts in `validation_summary.json`):

- Every ID referenced by another table or by `scenario_members` exists.
- No hub has stored + reserved load above capacity.
- `feasible_flag` equals the AND of the four rule flags; only feasible rows have a reference score.
- Each batch template has one category, 3–5 donations and ≤ 30 kg; no donation is in two templates.
- No route listing is reused; no lease case shares a listing; lease replay happens before listing expiry.
- Boundary weights are classified as 9.9 → COMMUNITY_HUB, 10.0 and 10.1 → DIRECT_HOUSEHOLD.

Every baseline checks each CSV against the SHA-256 in `generation_manifest.json` and
stops if a file has been changed.

## Key figures

| Figure | Value |
| --- | --- |
| Candidate hubs per small donation | median 32 (5–67) |
| Feasible hubs per small donation | median 21 (0–52) |
| Candidate rows rejected by rule | category 9,987; capacity 12,758; inactive hub 5,125; no route 1,528 |
| Directed road speed (free flow) | median about 55 km/h |
| Donor distance to nearest feasible hub | median 3.8 km |
| Donor distance to top reference-score hub | median 4.7 km |
| Top reference-score hub = nearest feasible hub | 51 % of recommendation scenarios |

## Limits

- Donations, hub load and capacity, accepted categories and vehicles are synthetic; they test
  the mechanisms under controlled conditions and do not describe real NGO volumes.
- Travel times are free-flow from the OSM speed profile; there is no congestion.
- OSM community halls are candidate locations, not approved donation centres.
- All donations open on one day; the dataset is a snapshot, not a time series.
- Recommendation scenarios replay the same frozen hub state; capacity is not used up across
  scenarios.
