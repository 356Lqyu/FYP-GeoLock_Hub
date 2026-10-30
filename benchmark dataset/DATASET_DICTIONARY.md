# GeoLock Hub benchmark dataset v3.3 — column dictionary

Every column below is read by at least one baseline, the AI model, the backend test
fixtures or the reference policy. Provenance fields (OSM IDs of the hubs, the public NGO
record fields, snap distances), the donor-sampling record and the study boundary are in
`generation_manifest.json`, not in the CSVs.

| Code | Reader |
| --- | --- |
| HUB | Nearest, Weighted and Random hub baselines; AI hub ranking |
| CLAIM | Non-atomic claim and protected-claim baselines; claim, lease and geofence tests |
| ROUTE | Nearest-Next and FCFS route baselines; route optimiser |
| AGG | Direct-household baseline; community-hub aggregation runs |
| SYS | Loading the benchmark into the isolated test database (`supabase/tests/benchmark_fixture_mapping.md`) |
| AI | Model feature, training target or split key |

All timestamps are local time (Asia/Kuala_Lumpur, ISO 8601 without offset) between
2025-01-01 and 2026-04-30.

## ngos.csv — the 11 NGOs (real)
| Column | Meaning | Used by |
| --- | --- | --- |
| ngo_id | Key used by vehicles, scenario members and claim states | CLAIM, ROUTE, AGG, SYS |
| ngo_name | Organisation name (NGO profile in the test database) | SYS |
| latitude, longitude | NGO location | SYS |
| road_node_id | Origin of the 20 km road-distance eligibility check and vehicle depot | CLAIM, ROUTE, AGG |

## hubs.csv — candidate community hubs (OSM location real, operating state synthetic)
| Column | Meaning | Used by |
| --- | --- | --- |
| hub_id | Key | HUB, AGG, SYS |
| hub_name | OSM name; unnamed features read "Unnamed … (OSM type id)" | AI (explanations), SYS |
| latitude, longitude | Hub location; 20 km candidate radius | SYS |
| road_node_id | Destination of the donor-to-hub road distance; batch pickup point | HUB, AGG |
| hub_capacity_kg | Maximum storage, 50–250 kg | HUB, AGG, SYS |
| hub_load_kg | Stored load at decision time (0–80 % of capacity) | HUB, AGG, SYS |
| hub_reserved_kg | Load held by active reservations (0–20 %) | HUB, AGG, SYS |
| hub_active_flag | 0 = hub cannot receive donations | HUB, SYS |
| operating_start, operating_end | Daily opening hours (HH:MM, same every day) | HUB, AGG, SYS |
| accepted_categories | Categories the hub accepts, `|`-separated | HUB, AGG, SYS |

## donors.csv (synthetic)
| Column | Meaning | Used by |
| --- | --- | --- |
| donor_id | Key | HUB, AGG |
| latitude, longitude | Donor home: a real road node on a residential, living_street, service or unclassified street | SYS |
| road_node_id | Origin of donor-to-hub distance; household pickup stop | HUB, AGG |

## donations.csv (synthetic)
| Column | Meaning | Used by |
| --- | --- | --- |
| donation_id, donor_id | Keys (numbered in time order) | all |
| category | Compatibility, handling penalty, batch category | HUB, AGG, AI |
| weight_kg | 10 kg collection rule, hub capacity, vehicle load | all |
| availability_start | When the donation can be handed over; listing opens; aggregation cutoff | CLAIM, ROUTE, AGG |
| availability_end | When the listing expires; the window lasts 8–72 h | CLAIM, ROUTE, AGG |
| collection_path | COMMUNITY_HUB (< 10 kg) or DIRECT_HOUSEHOLD (≥ 10 kg) | HUB, SYS |
| geographic_group_id | Geohash-5 cell of the donor; whole cells stay in one train/validation/test partition | AI |

## donation_hub_candidates.csv — every hub within 20 km of each COMMUNITY_HUB donation
| Column | Meaning | Used by |
| --- | --- | --- |
| donation_id, hub_id | Candidate pair | HUB, AI |
| item_compatible_flag | Hub accepts the category | HUB |
| capacity_feasible_flag | weight ≤ capacity − load − reserved | HUB |
| operating_feasible_flag | The availability window overlaps the hub's opening hours for ≥ 30 min | HUB |
| active_feasible_flag | Hub is active | HUB |
| route_available_flag | A directed donor-to-hub road route exists | HUB |
| feasible_flag | All five rules pass; only these hubs may be ranked | HUB, AI |
| road_distance_km | Directed donor-to-hub distance (blank if no route) | HUB, AI |
| donation_weight_kg | Donation weight, repeated so the table is a complete training table | AI |
| utilisation_ratio | hub_load / capacity | HUB, AI |
| capacity_pressure | weight / remaining capacity | HUB, AI |
| handling_penalty | clothing 0.1, books 0.2, electronics 0.4, food 0.6, appliances 0.8, furniture 1.0 | HUB, AI |
| reference_score | Weighted deterministic score of feasible rows (lower is better); the AI training target | HUB, AI |
| geographic_group_id | Split key, repeated from donations | AI |

## listings.csv — claimable direct-household pickups
| Column | Meaning | Used by |
| --- | --- | --- |
| listing_id | Key (numbered in time order) | CLAIM, ROUTE |
| donation_id | Donation collected | ROUTE, SYS |
| pickup_road_node_id | Geofence check and route stop | CLAIM, ROUTE |
| listing_weight_kg | Vehicle load | ROUTE |
| created_at, listing_expires_at | Claimable window (= the donation's availability) | CLAIM, ROUTE |

## vehicles.csv (synthetic)
| Column | Meaning | Used by |
| --- | --- | --- |
| vehicle_id, ngo_id | Vehicle and owner | ROUTE, AGG |
| vehicle_type, vehicle_capacity_kg | small_car 100 kg, van 500 kg | ROUTE, AGG |
| depot_road_node_id | Route start and end (the NGO's road node) | ROUTE, AGG |

## hub_batches.csv / hub_batch_members.csv — batch templates
| Column | Meaning | Used by |
| --- | --- | --- |
| batch_id, hub_id | Template and the hub it forms at (pickup = the hub's road node) | AGG |
| batch_category, batch_weight_kg, batch_item_count | One category, ≤ 30 kg, 3–5 items | AGG |
| created_at | Time the last member is received at the hub | AGG |
| batch_id, donation_id (members) | Original donations in the batch | AGG |
| added_at (members) | Time the donation is received at the hub (first opening-hours moment inside its window) | AGG |

## road_nodes.csv / road_distance_matrix.csv (real, OSM)
| Column | Meaning | Used by |
| --- | --- | --- |
| road_node_id, latitude, longitude | Every node referenced anywhere in the dataset | SYS |
| from_node_id, to_node_id | Directed node pair | all |
| road_distance_km, travel_time_min | Shortest directed distance and its free-flow time (blank if unreachable) | all |
| route_available_flag | 0 = no directed path | all |

## scenarios.csv / scenario_members.csv
| Column | Meaning | Used by |
| --- | --- | --- |
| scenario_id, scenario_type | Test case and what it tests | all |
| scenario_profile | STANDARD; route stress profile; NO_FEASIBLE_HUB | HUB, ROUTE |
| entity_type, entity_id, scenario_role | Records that make up the case (e.g. SOURCE_DONATION, CANDIDATE_HUB, CLAIMABLE_LISTING, PRIOR_CLAIMANT, AVAILABLE_FLEET) | all |

## claim_initial_states.csv — lease replay cases
| Column | Meaning | Used by |
| --- | --- | --- |
| scenario_id, listing_id, ngo_id | The prior claim and its holder | CLAIM, SYS |
| input_state | EXPIRED or ACTIVE at replay time | CLAIM |
| claim_expires_at | Lease end, 6 h after the listing opens | CLAIM |
| replay_at | When a different NGO tries to claim | CLAIM |

## verification_cases.csv — 10 kg rule cases
| Column | Meaning | Used by |
| --- | --- | --- |
| case_id | Key | SYS |
| weight_kg | Blank, −1, 0, 0.5, 9.9, 10, 10.1, 30 | SYS |
| expected_result | INVALID_WEIGHT, COMMUNITY_HUB or DIRECT_HOUSEHOLD | SYS |

## Report Table A.2 names → this release

| Report (Table A.2) | Here |
| --- | --- |
| Location entity | Folded into ngos / hubs / donors (latitude, longitude, road_node_id) |
| NGO Reference + NGO Agent | `ngos.csv`; public record fields in the manifest (`provenance.ngos`) |
| `ngo_agent_id` | `ngo_id` |
| Listing `source_type` / `source_id` | All listings are direct donations; `donation_id` |
| Donation `valid_input_flag`, `classification_reason` | Every generated donation is valid; the reason follows from `collection_path`; invalid inputs are in `verification_cases.csv` |
| Hub `location_id`, OSM identity | Manifest `provenance.hubs` |
| Scenario seed / matrix / version | Manifest (`seed`, `matrix_id`, `benchmark_version`) |
| Population Context | Manifest `donor_sampling.district_population` |
