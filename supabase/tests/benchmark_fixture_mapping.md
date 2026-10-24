# Stage 1 benchmark fixture mapping

Current interpretation (23 October 2026): see the
[Stage 3J matrix](review-only/stage3j/EVIDENCE_MATRIX.md). The original benchmark
and historical outputs are preserved. Existing baselines are simulations, not
native PostgreSQL acceptance results. Stage 3I direct supervised recovery PASS
does not authorize reusing its retained fixture or activating job 3.

The supplied benchmark is experimental data, not seed data for the shared Supabase project. The app and additive migration do not import any CSV rows.

The automated fixture setup for the claim-recovery runner creates independent,
synthetic records rather than importing benchmark users or scenario rows. See
[`stage1_dev_fixture_setup.md`](stage1_dev_fixture_setup.md) for the exact
fixture graph and DEV-only command sequence.

## Mapping rules for an isolated test database

| Benchmark source | Fixture identity | Test database representation |
|---|---|---|
| `scenarios.csv` | `scenario_id`, `scenario_type`, `scenario_profile` | Test-run metadata; retain the scenario ID and the benchmark version in each test result. |
| `scenario_members.csv` | `(scenario_id, entity_type, entity_id, scenario_role)` | Resolve through the fixture map below; never use the synthetic ID as a production UUID. |
| `donors.csv` | `donor_id` | Create one disposable Auth user and `donor_profiles` record; store `donor_id -> auth UUID` only in the test fixture map. |
| `donations.csv` | `donation_id`, `weight_kg`, `collection_path`, availability values | Create through the authenticated `create_and_validate_donation` RPC in the isolated database; retain the benchmark ID as a test label, not as the database primary key. |
| `listings.csv` | `listing_id`, `donation_id`, `pickup_road_node_id`, `listing_weight_kg`, `created_at`, `listing_expires_at` | Create as an AVAILABLE `DIRECT_DONATION` listing in the isolated database, keeping the benchmark lifetime (expiry − created). Keep its generated UUID mapped from the benchmark listing ID. The route-node reference is valid only inside the benchmark test network. |
| `ngos.csv` | `ngo_id`, `ngo_name`, `latitude`, `longitude`, `road_node_id` | Create one disposable NGO Auth/profile record per NGO at its coordinates; the trusted test setup sets `location_verified_at`. |
| `hubs.csv`, `hub_batches.csv`, `hub_batch_members.csv` | `hub_id`, `batch_id`, member donation IDs | Create hub admins through the test-only trusted setup, then create reservations/receipts/batches through protected RPCs. Map all fixture IDs to generated UUIDs. Preserve each original donation-to-batch relationship. |
| `claim_initial_states.csv` | `scenario_id`, `listing_id`, `ngo_id`, `input_state`, `claim_expires_at`, `replay_at` | Set up the prior claim with test-only SQL so that the database time is the replay time (claim at listing opening, 360-minute lease). `EXPIRED` cases have no physical handover and are safe-release cases; `ACTIVE` cases remain active. Never copy timestamps as the production clock. |
| `road_nodes.csv` and `road_distance_matrix.csv` | `road_node_id`, directed node pair, `route_available_flag` | Load only into an isolated benchmark network with `dataset_kind='BENCHMARK'`. The app resolver and NGO discovery require `dataset_kind='OPERATIONAL'`, so these fixtures cannot authorize production claims. Keep matrix direction and `route_available_flag`; never add a straight-line fallback. |
| `verification_cases.csv` | `case_id`, `weight_kg`, `expected_result` | Deterministic 10 kg rule inputs. `COMMUNITY_HUB` = backend `HUB_COLLECTION`, `DIRECT_HOUSEHOLD` = `DIRECT_PICKUP`, `INVALID_WEIGHT` must fail validation. |
| `generation_manifest.json`, `validation_summary.json` | row counts, SHA-256 per file, scenario counts, generation rules | Store with each benchmark run; use the hashes to confirm fixture provenance. |

## Concurrency and lifecycle cases

Use separate AVAILABLE listings for the 2, 10 and 50 claimant cases. Each test NGO must be authenticated, location-verified by the trusted test setup and within the configured 20 km eligibility radius (straight line in the V3 schema; road network after migration `20261020_operational_road_node_resolution.sql`). Exactly one request should return `SUCCESS`; the remaining requests should return the database's rejection outcome, and a service-role read in the isolated test database should show exactly one active claim. Replay the winning `(listing_id, request_id, NGO)` and require the same claim ID with `replayed=true`.

Additional deterministic cases to run against an isolated database:

- Lease recovery: expired and not dispatched releases; active leases remain; dispatched or uncertain handover enters reconciliation and never reopens automatically.
- Handover races: expiry vs `start_pickup`/`complete_pickup`; database time and row locking decide the committed result.
- State guards: invalid skips, `COLLECTED -> AVAILABLE`, and stale holder operations fail without state change.
- Hub rules: 50–250 kg capacity, reservation contention, 3–5 whole donations, one category, no more than 30 kg, and no duplicate active membership.
- Road coverage: an approved operational coverage point resolves only within its configured snap distance; outside-coverage and benchmark-only points return no node and cannot be discovered/claimed.
- Audit: ordinary returned claim rejections commit in `claim_requests`/`audit_events`. Thrown errors roll back those writes. A trusted post-rollback failure record is a remaining requirement; DEV has no public `operation_failure_events` table. Do not claim a failure logger is installed or that transactional audits survive rollback.

The two E2 claim baselines (`baseline implementation/source code`) already apply this mapping to an isolated PostgreSQL test database: see `baseline implementation/postgresql/README.md` for the setup. Flutter unit tests do not establish PostgreSQL concurrency safety.
