# GeoLock Hub benchmark dataset v3.2 — column dictionary

| Code | Reader |
| --- | --- |
| HUB | Nearest, Weighted and Random hub baselines; AI hub ranking |
| CLAIM | Non-atomic claim and protected-claim baselines; claim, lease and geofence tests |
| ROUTE | Nearest-Next and FCFS route baselines; route optimiser |
| AGG | Direct-household baseline; community-hub aggregation runs |
| SYS | Loading the benchmark into the isolated test database (`supabase/tests/benchmark_fixture_mapping.md`) |
| AI | Model feature, training target or split key |
| SRC | Tells where a real record came from |

How donor locations were sampled (OpenDOSM district populations, localities, quotas) is
recorded in `generation_manifest.json` → `donor_sampling`, not in a CSV.

## ngos.csv — the 11 NGOs (real)
| Column | Meaning and reason | Used by |
| --- | --- | --- |
| ngo_id | Key used by vehicles, scenario members and claim states | CLAIM, ROUTE, AGG, SYS |
| ngo_name, state, category, status | Public organisation record; only active (`AKTIF`) NGOs are admitted | SYS, SRC |
| latitude, longitude | NGO location | SYS |
| road_node_id | Origin of the 20 km road-distance eligibility check and vehicle depot | CLAIM, ROUTE, AGG |
| node_snap_distance_m | Distance to the snapped road node (must be ≤ 500 m) | SRC |

## hubs.csv — candidate community hubs (OSM location real, operating state synthetic)
| Column | Meaning and reason | Used by |
| --- | --- | --- |
| hub_id | Key | HUB, AGG, SYS |
| hub_name | OSM name; unnamed features read "Unnamed … (OSM type id)" | SYS, SRC |
| latitude, longitude | Hub location; 20 km candidate radius | SYS |
| road_node_id | Destination of the donor-to-hub road distance | HUB |
| node_snap_distance_m | Distance to the snapped road node (≤ 500 m) | SRC |
| osm_type, osm_id, osm_amenity | The OSM feature (community_centre or townhall) | SRC |
| hub_capacity_kg | Maximum storage, 50–250 kg | HUB, AGG, SYS |
| hub_load_kg | Stored load at decision time | HUB, AGG, SYS |
| hub_reserved_kg | Load held by active reservations | HUB, AGG, SYS |
| hub_active_flag | 0 = hub cannot receive donations | HUB, SYS |
| accepted_categories | Categories the hub accepts, `|`-separated | HUB, AGG, SYS |

## donors.csv (synthetic)
| Column | Meaning and reason | Used by |
| --- | --- | --- |
| donor_id | Key | HUB, AGG |
| latitude, longitude | Donor home location: a real road node on a residential, living_street, service or unclassified street | SYS |
| road_node_id | Origin of donor-to-hub distance; household pickup stop | HUB, AGG |

## donations.csv (synthetic)
| Column | Meaning and reason | Used by |
| --- | --- | --- |
| donation_id, donor_id | Keys | all |
| category | Compatibility, handling penalty, batch category | HUB, AGG, AI |
| weight_kg | 10 kg collection rule, hub capacity, vehicle load | all |
| availability_start | When the donation can be handed over: listing opens; batch member order; aggregation cutoff | CLAIM, ROUTE, AGG |
| availability_end | When the listing expires | CLAIM, ROUTE, AGG |
| collection_path | COMMUNITY_HUB (< 10 kg) or DIRECT_HOUSEHOLD (≥ 10 kg) | HUB, SYS |
| geographic_group_id | Geohash-5 cell of the donor; whole cells stay in one train/validation/test partition | AI |

## donation_hub_candidates.csv — every hub within 20 km of each COMMUNITY_HUB donation
| Column | Meaning and reason | Used by |
| --- | --- | --- |
| donation_id, hub_id | Candidate pair | HUB, AI |
| item_compatible_flag | Hub accepts the category | HUB |
| capacity_feasible_flag | weight ≤ remaining capacity | HUB |
| active_feasible_flag | Hub is active | HUB |
| route_available_flag | A directed donor-to-hub road route exists | HUB |
| feasible_flag | All four rules pass; only these hubs may be ranked | HUB, AI |
| road_distance_km | Directed donor-to-hub distance (blank if no route) | HUB, AI |
| donation_weight_kg | Donation weight, repeated so the table is a complete training table | AI |
| utilisation_ratio | hub_load / capacity | HUB, AI |
| remaining_capacity_kg | capacity − load − reserved; explains `capacity_feasible_flag` | HUB |
| capacity_pressure | weight / remaining capacity | HUB, AI |
| handling_penalty | Category penalty: clothing 0.1, books 0.2, electronics 0.4, food 0.6, appliances 0.8, furniture 1.0 | HUB, AI |
| reference_score | Weighted deterministic score of feasible rows (lower is better); the AI training target | HUB, AI |
| reference_rank | Rank by reference_score within the donation (ties: distance, then hub_id) | HUB, AI |
| geographic_group_id | Split key, repeated from donations | AI |

## listings.csv — claimable direct-household pickups
| Column | Meaning and reason | Used by |
| --- | --- | --- |
| listing_id | Key | CLAIM, ROUTE |
| donation_id | Donation collected | ROUTE, SYS |
| pickup_road_node_id | Geofence check and route stop | CLAIM, ROUTE |
| listing_weight_kg | Vehicle load | ROUTE |
| created_at, listing_expires_at | Claimable window (from the donation availability) | CLAIM, ROUTE |

## vehicles.csv (synthetic)
| Column | Meaning and reason | Used by |
| --- | --- | --- |
| vehicle_id, ngo_id | Vehicle and owner | ROUTE, AGG |
| vehicle_type, vehicle_capacity_kg | small_car 100 kg, van 500 kg | ROUTE, AGG |
| depot_road_node_id | Route start and end (the NGO's road node) | ROUTE, AGG |

## hub_batches.csv / hub_batch_members.csv — batch templates
| Column | Meaning and reason | Used by |
| --- | --- | --- |
| batch_id, hub_id | Template and the hub it forms at | AGG |
| batch_category, batch_weight_kg, batch_item_count | One category, ≤ 30 kg, 3–5 items | AGG |
| created_at | Time the last member becomes available; the aggregation cutoff | AGG |
| batch_id, donation_id (members) | Original donations in the batch | AGG |

## road_nodes.csv / road_distance_matrix.csv (real, OSM)
| Column | Meaning and reason | Used by |
| --- | --- | --- |
| road_node_id, latitude, longitude | Every node referenced anywhere in the dataset | SYS |
| from_node_id, to_node_id | Directed node pair | all |
| road_distance_km, travel_time_min | Shortest directed distance and its free-flow time (blank if unreachable) | all |
| route_available_flag | 0 = no directed path | all |

## scenarios.csv / scenario_members.csv
| Column | Meaning and reason | Used by |
| --- | --- | --- |
| scenario_id, scenario_type | Test case and what it tests | all |
| scenario_profile | STANDARD; route stress profile; NO_FEASIBLE_HUB | HUB, ROUTE |
| entity_type, entity_id, scenario_role | Records that make up the case (e.g. SOURCE_DONATION, CANDIDATE_HUB, CLAIMABLE_LISTING, PRIOR_CLAIMANT, AVAILABLE_FLEET) | all |

## claim_initial_states.csv — lease replay cases
| Column | Meaning and reason | Used by |
| --- | --- | --- |
| scenario_id, listing_id, ngo_id | The prior claim and its holder | CLAIM, SYS |
| input_state | EXPIRED or ACTIVE at replay time | CLAIM |
| claim_expires_at | Lease end, 6 h after the listing opens | CLAIM |
| replay_at | When a different NGO tries to claim | CLAIM |

## verification_cases.csv — 10 kg rule cases
| Column | Meaning and reason | Used by |
| --- | --- | --- |
| case_id | Key | SYS |
| weight_kg | Blank, −1, 0, 0.5, 9.9, 10, 10.1, 30 | SYS |
| expected_result | INVALID_WEIGHT, COMMUNITY_HUB or DIRECT_HOUSEHOLD | SYS |
