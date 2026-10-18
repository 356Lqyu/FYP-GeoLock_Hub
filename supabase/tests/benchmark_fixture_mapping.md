# Stage 1 benchmark fixture mapping

The supplied benchmark is experimental data, not seed data for the shared Supabase project. The app and additive migration do not import any CSV rows.

The automated fixture setup for the claim-recovery runner creates independent,
synthetic records rather than importing benchmark users or scenario rows. See
[`stage1_dev_fixture_setup.md`](stage1_dev_fixture_setup.md) for the exact
fixture graph and DEV-only command sequence.

## Mapping rules for an isolated test database

| Benchmark source | Fixture identity | Test database representation |
|---|---|---|
| `scenarios.csv` | `scenario_id`, `scenario_type`, `scenario_seed`, `matrix_id` | Test-run metadata row; retain these values in each test result. |
| `scenario_members.csv` | `(scenario_id, entity_type, entity_id, scenario_role)` | Resolve through the fixture map below; never use the synthetic ID as a production UUID. |
| `donors.csv` | `donor_id` | Create one disposable Auth user and `donor_profiles` record; store `donor_id -> auth UUID` only in the test fixture map. |
| `donations.csv` | `donation_id`, `weight_kg`, `collection_path`, availability values | Create through the authenticated `create_and_validate_donation` RPC in the isolated database; retain the benchmark ID as a test label, not as the database primary key. |
| `listings.csv` | `listing_id`, `source_id`, `initial_state`, `pickup_road_node_id` | Create through the scenario setup in the isolated database. Keep its generated UUID mapped from the benchmark listing ID. The route-node reference is valid only inside the benchmark test network. |
| `ngo_agents.csv` and `ngo_references.csv` | `ngo_agent_id`, `public_ref_key`, `location_id`, verification flags | Create disposable NGO Auth/profile records. Synthetic organization status and coordinates remain fixture attributes and are not independently verified facts. The trusted test verifier must explicitly approve a test NGO location. |
| `hubs.csv`, `hub_batches.csv`, `hub_batch_members.csv` | `hub_id`, `batch_id`, member donation IDs | Create hub admins through the test-only trusted setup, then create reservations/receipts/batches through protected RPCs. Map all fixture IDs to generated UUIDs. Preserve each original donation-to-batch relationship. |
| `claim_initial_states.csv` | `scenario_id`, `listing_id`, `ngo_agent_id`, `input_state`, `claim_expires_at`, `handover_status` | Set up lease/claim states using test-only SQL in the isolated database. `EXPIRED` with `NOT_TRANSFERRED` is a safe-release case; active-lease cases remain active. Never copy timestamps as the production clock. |
| `road_nodes.csv` and `road_distance_matrix.csv` | `road_node_id`, `network_snapshot_id`, directed edge pair | Load only into an isolated benchmark network with `dataset_kind='BENCHMARK'`. The app resolver and NGO discovery require `dataset_kind='OPERATIONAL'`, so these fixtures cannot authorize production claims. Keep matrix direction and `route_available_flag`; never add a straight-line fallback. |
| `verification_cases.csv` | `case_id`, `weight_kg`, `input_valid` | Use as deterministic validation inputs. Expected 10 kg classification: 9.9 kg = `HUB_COLLECTION`; 10.0 and 10.1 kg = `DIRECT_PICKUP`. Invalid/missing/negative weights must fail validation. |
| `generation_manifest.json`, `validation_summary.json` | row counts, hashes, scenario counts and source notes | Store verbatim with each benchmark run; use hashes to confirm fixture provenance. Do not translate synthetic validation flags into production verification. |

## Concurrency and lifecycle cases

Use separate AVAILABLE listings for the 2, 10 and 50 claimant cases. Each test NGO must be authenticated, location-verified by the trusted test setup and inside the configured 20 km straight-line radius. Exactly one request should return `SUCCESS`; the remaining requests should return the database's rejection outcome, and a service-role read in the isolated test database should show exactly one active claim. Replay the winning `(listing_id, request_id, NGO)` and require the same claim ID with `replayed=true`.

Additional deterministic cases to run against an isolated database:

- Lease recovery: expired and not dispatched releases; active leases remain; dispatched or uncertain handover enters reconciliation and never reopens automatically.
- Handover races: expiry vs `start_pickup`/`complete_pickup`; database time and row locking decide the committed result.
- State guards: invalid skips, `COLLECTED -> AVAILABLE`, and stale holder operations fail without state change.
- Hub rules: 50–250 kg capacity, reservation contention, 3–5 whole donations, one category, no more than 30 kg, and no duplicate active membership.
- Road coverage: an approved operational coverage point resolves only within its configured snap distance; outside-coverage and benchmark-only points return no node and cannot be discovered/claimed.
- Audit: claim rejections are durable in `claim_requests`/`audit_events`; errors that roll back are sent after rollback to the trusted failure logger and verified in `operation_failure_events`.

The repository currently has no isolated Supabase test credentials or disposable database, so these database cases are specified but not run. Flutter unit tests do not establish PostgreSQL concurrency safety.
