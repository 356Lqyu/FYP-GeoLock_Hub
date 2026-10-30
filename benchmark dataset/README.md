# GeoLock Hub Benchmark Dataset — v3.3

A frozen, reproducible dataset for testing GeoLock Hub from donation intake to route
planning. It mixes **real public data** (11 NGOs, OpenStreetMap roads and community
halls, OpenDOSM population) with **synthetic operational records** (donors, donations,
hub states, vehicles).

The dataset holds **inputs only**: no baseline or proposed-method output, no claims,
tasks or routes, and no train/test split. Baselines and experiments read it and write
their own results elsewhere.

## What changed in v3.3 (from v3.2)

| Change | Why |
| --- | --- |
| Donations are dated between **1 Jan 2025 and 30 Apr 2026** (v3.2: all on 2 Nov 2026) | A realistic timeline; every window starts and ends inside that period |
| Hub **opening hours** (`operating_start`, `operating_end`) and the **operating-window rule** (`operating_feasible_flag`) | Report Eq. 4.3 / Algorithm 2 line 11 (O_di) and Table A.2 |
| Stored hub load **0–80 %** of capacity (v3.2: 0–95 %) | Report Table A.3 |
| Availability windows **8–72 h** (v3.2: up to 84 h) | Report Table A.3 |
| **Study boundary** enforced: no point or road in Singapore (v3.2 had 8 hubs and 19 donors in Singapore, from the Johor Bahru window) | Report 3.3.1 and Table 3.3 (geography check) |
| Only columns that a baseline, the AI model or the test fixtures read are kept; provenance (hub OSM IDs, NGO registry fields, snap distances) moved to `generation_manifest.json` → `provenance`; batch members get `added_at` | Leaner tables; Table A.2 names are mapped in `DATASET_DICTIONARY.md` |
| IDs follow time (DON000001 is the earliest donation; same for DNR, LST, BAT) | Readable ordering |

## Folder

```
benchmark dataset/
├── README.md                 this file
├── DATASET_DICTIONARY.md     every column and why it exists
├── source code/
│   ├── extract_osm_python.py           step 1a: OSM PBF -> road cache
│   ├── extract_study_boundary.py       step 1b: OSM PBF -> study boundary (state polygons)
│   ├── generate_geolock_benchmark.py   step 2: road cache + boundary + public data -> dataset/
│   └── requirements.txt
├── road cache/               made by step 1 (road_nodes, road_edges, household_nodes, osm_hub_candidates,
│                             study_boundary.wkt, road_area.wkt, study_boundary.json)
└── dataset/                  made by step 2: 15 CSV + 2 JSON
```

Public inputs live in `../public dataset/`: `malaysia-singapore-brunei.osm.pbf`
(Geofabrik, OSM data of 2026-07-19), `population_district.csv` (OpenDOSM),
`NGO_references.csv`.

## Generate

Run from the repository root.

```bash
python -m pip install -r "benchmark dataset/source code/requirements.txt"

# step 1a (about 4 minutes; only needed if the road cache is missing)
python "benchmark dataset/source code/extract_osm_python.py" "public dataset/malaysia-singapore-brunei.osm.pbf" "benchmark dataset/road cache/road_nodes.csv" "benchmark dataset/road cache/road_edges.csv" "benchmark dataset/road cache/osm_hub_candidates.csv" --ngos "public dataset/NGO_references.csv"

# step 1b (about 1.5 minutes; only needed if the .wkt files are missing)
python "benchmark dataset/source code/extract_study_boundary.py"

# step 2 (about 3.5 minutes)
python "benchmark dataset/source code/generate_geolock_benchmark.py" --population-retrieved 2026-09-08 --osm-retrieved 2026-09-08 --ngo-retrieved 2026-09-13 --ngo-source-url https://www.ros.gov.my/portal-main/semakan2
```

The `--...-retrieved` dates and the NGO source URL are only recorded in the manifest
(values above are the retrieval dates in the report's reference list). The same inputs
and seed (20260915) always produce byte-identical CSVs.

## Tables

| File | Rows | Content | Real or synthetic |
| --- | --- | --- | --- |
| `ngos.csv` | 11 | NGOs with coordinates and road node | Real |
| `hubs.csv` | 180 | OSM community centres / town halls as candidate hubs | Location real; capacity, load, opening hours, categories synthetic |
| `donors.csv` | 3,800 | Donor home coordinates (each on a real residential-type street node) | Synthetic |
| `donations.csv` | 3,800 | Category, weight, dated availability window, collection path | Synthetic |
| `donation_hub_candidates.csv` | 92,941 | Every hub within 20 km of each small donation, five hard-rule flags, reference score | Derived |
| `listings.csv` | 1,172 | Claimable pickups (direct-household donations) | Derived |
| `vehicles.csv` | 22 | Per NGO: one car (100 kg), one van (500 kg) | Synthetic |
| `hub_batches.csv`, `hub_batch_members.csv` | 100 / 424 | Batch templates of small donations at one hub | Derived |
| `road_nodes.csv` | 3,990 | Coordinates of every road node used | Real (OSM) |
| `road_distance_matrix.csv` | 142,514 | Directed road distance and travel time between nodes | Real (OSM) |
| `scenarios.csv`, `scenario_members.csv` | 2,594 / 77,962 | Test cases and the records each one uses | Selection |
| `claim_initial_states.csv` | 125 | Prior claim state for lease replay cases | Synthetic |
| `verification_cases.csv` | 8 | Weight inputs and expected collection path | Fixed |
| `generation_manifest.json` | — | Version, seed, sources, boundary, timeline, rules, donor-sampling record, provenance of NGOs and hubs, row counts, SHA-256 per file | — |
| `validation_summary.json` | — | Results of the generation checks | — |

Study area: Peninsular Malaysia. Points are sampled inside the 17 km road-extract window
around each NGO — Klang Valley (4 NGOs), Johor Bahru, Penang, Ipoh, Seremban, Kuantan,
Kemaman and Kuala Muda — and must also lie inside the state boundary (no Singapore).

## Generation rules

| Item | Rule |
| --- | --- |
| Study boundary | Donor, hub and NGO points inside the OSM state boundaries of the 11 states + Kuala Lumpur + Putrajaya; roads inside the states plus a 0.05° coastal band, minus Singapore. Same rule as the app road network (`supabase/road_network`). 42 hub sites and 178 donor nodes outside were rejected (`validation_summary.json` → `geography`) |
| Donor location | Locality quota ∝ OpenDOSM district population × proximity to the nearest NGO; each donor home = an unused road node on a residential, living_street, service or unclassified street (never a main road or highway) within 5.5 km of the locality (full record in the manifest, `donor_sampling`) |
| Snapping | NGO and hub points map to the nearest drivable node within 500 m; donors are placed on nodes |
| Roads | Directed OSM drivable graph; unreachable pairs have `route_available_flag = 0`; no straight-line fallback |
| Donation weight | 0.5–30 kg (furniture ≥ 7 kg, appliances ≥ 3 kg, electronics ≥ 0.8 kg); fixed boundary cases 9.9 / 10.0 / 10.1 kg |
| Collection path | < 10 kg → COMMUNITY_HUB (2,628); ≥ 10 kg → DIRECT_HOUSEHOLD (1,172) |
| Timeline | Every availability window lies between 1 Jan 2025 and 30 Apr 2026; weekends weighted 1.5× (about 230 donations per month) |
| Availability | Opens 09:00–14:00; closes 17:00–21:00 the same day or up to 3 days later; lasts 8–72 h (realised 8–60 h, median 35 h) |
| Hub state | Capacity 50–250 kg; stored load 0–80 %; reserved 0–20 % (never above what remains); 5 % inactive |
| Hub opening hours | Daily: 09:00–17:00 (55 %), 08:00–22:00 (25 %), 08:00–12:00 (10 %), 18:00–22:00 (10 %) |
| Hub categories | All six, except: no furniture below 100 kg capacity; half the hubs decline one more category |
| Candidate hubs | Every hub within 20 km (straight line) of the donor |
| Hard feasibility (five rules) | Category accepted AND weight ≤ remaining capacity AND the availability window overlaps the opening hours for ≥ 30 min AND hub active AND a directed donor-to-hub route |
| Reference score | 0.45 × road distance (min-max within the feasible hubs) + 0.20 × utilisation + 0.25 × capacity pressure + 0.10 × handling penalty; lower is better; ties by distance, then hub ID |
| NGO eligibility | Directed NGO-to-pickup road distance ≤ 20 km |
| Batch template | Small donations whose top reference-score hub is the same; one category; 3–5 items; ≤ 30 kg. Each template is one accumulation episode: the windows overlap, `added_at` = first opening-hours handover, `created_at` = last `added_at`, and no other donation of the same hub and category is dated within 7 days, so "earliest received_at, then donation_id" selects exactly the members |
| Route scenario | 5 listings of one NGO within 15 km by road, dated as one planning episode (common collection window) |
| Lease cases | Claim expires 6 h after the listing opens; expired cases replay at 7 h, active cases at 2 h; replay is always before listing expiry |

Dating is done after all scenarios are selected and uses its own seed offset, so it never
changes which records a scenario holds. Hub hours repeat daily, so the operating-window
rule depends on the time of day and the window length, not on the calendar day.

## Settings fixed by the data

These values shape which records and scenarios exist. Changing them requires
regenerating the dataset (new version):

- 10 kg collection threshold
- 20 km radius (candidate hubs and NGO eligibility)
- The five hard hub rules (incl. the 30-minute handover overlap) and the reference-score weights
- Batch limits: 3–5 donations, ≤ 30 kg, one category
- 6-hour (360-minute) lease in `claim_initial_states`
- The timeline (1 Jan 2025 – 30 Apr 2026)

Everything else is set by each baseline or experiment run and is not stored here: the
train/validation/test split, number of concurrent workers, route duration limit, service
time, safety margin, solver settings, Top-k, and random seeds of baselines.

## Checks run at generation

All pass for v3.3 (counts in `validation_summary.json`):

- Every admitted donor, hub and NGO point lies inside the study boundary; rejected points are counted.
- Every ID referenced by another table or by `scenario_members` exists.
- No hub has stored + reserved load above capacity.
- `feasible_flag` equals the AND of the five rule flags; only feasible rows have a reference score.
- Each batch template has one category, 3–5 donations and ≤ 30 kg; no donation is in two templates; members' windows overlap; `added_at` lies inside each member's window; no other same hub-and-category donation falls in the episode.
- Every route scenario's 5 listings share a common collection window; no route listing is reused.
- No lease case shares a listing; lease replay happens before listing expiry.
- Every window starts on or after 1 Jan 2025, ends before 1 May 2026 and lasts 8–72 h; IDs are in time order.
- Boundary weights are classified as 9.9 → COMMUNITY_HUB, 10.0 and 10.1 → DIRECT_HOUSEHOLD.

Every baseline checks each CSV against the SHA-256 in `generation_manifest.json` and
stops if a file has been changed.

## Key figures

| Figure | Value |
| --- | --- |
| Candidate hubs per small donation | median 31 (5–67) |
| Feasible hubs per small donation | median 24 (0–62) |
| Candidate rows rejected by rule | category 8,884; capacity 424; opening hours 285; inactive hub 5,103; no route 1,476 |
| Directed road speed (free flow) | median about 55 km/h |
| Donor distance to nearest feasible hub | median 3.4 km |
| Donor distance to top reference-score hub | median 4.2 km |
| Top reference-score hub = nearest feasible hub | 48 % of recommendation scenarios |

## Limits

- Donations, hub load and capacity, opening hours, accepted categories and vehicles are synthetic;
  they test the mechanisms under controlled conditions and do not describe real NGO volumes.
- Travel times are free-flow from the OSM speed profile; there is no congestion.
- OSM community halls are candidate locations, not approved donation centres.
- Hub state (load, reserved load) is one frozen snapshot replayed by every recommendation
  scenario; capacity is not used up across scenarios or over the timeline.
- The road graph is the benchmark's own extract (OSM data of 2026-07-19, its own speed table,
  service roads kept). The app network (`supabase/road_network`, OSM data of 2026-10-18) uses the
  same boundary and 500 m snap rule but leaves out service and private roads, so 7 of the 3,991
  benchmark points (1 hub, 6 donors) would not snap in the app. The two networks are never mixed.
