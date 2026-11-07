# Geographic acceptance handoff for teammate review

Proposed coordination document only. No teammate has been contacted and no
algorithm, graph, hub recommendation, aggregation or routing implementation was
changed. The algorithm owner should confirm the expected-case manifest before
execution. Current FYP responsibility split: authority/auth/claims/leases/audit
belongs to the coordination work; geography/hub/AI/aggregation/routing belongs
to the teammate's work. Joint interface acceptance is required, not replacement.

## Shared interface and source baseline

Current operational functions are captured in [function_catalog.json](function_catalog.json).
geolock_resolve_road_node uses approved active OPERATIONAL coverage and
ST_DWithin at max_snap_distance_m (500 m). Coverage uses ST_Covers. NGO-to-listing
eligibility uses directed road distance <=20,000 m; geolock_road_costs invokes
pgr_dijkstraCost with directed=true. There is also a straight-line prefilter.
There is no permission to substitute that prefilter for road distance or use
BENCHMARK nodes to authorize a live claim.

Both async readiness generations must be current. The cache reader requires
active snapshot, exact NGO/listing nodes, radius, active technically verified NGO
and both readiness checks. Claim can refresh a missing cache entry internally;
therefore geolock_ngo_listing_road_check is not an approved SELECT-only probe.
Use catalog/cache SELECTs during review and actual RPC tests only in a separately
approved mutating run or isolated fixture. No readiness helper is invoked here.

## Case manifest to agree once, then reuse

| Case | Expected policy / evidence to freeze | Test owner |
|---|---|---|
| Road snap 499.9 / 500.0 / 500.1 m | Inside/exact eligible for snapping if coverage/node active; outside no node. Build deterministic coordinates with PostGIS geodesic distances, record tolerance and raw distances; do not eyeball map pixels | Teammate supplies geometry/node expectations; authority tests fail-closed UI/RPC |
| Coverage boundary and no approved active coverage | ST_Covers includes boundary; absent/inactive/unapproved/BENCHMARK-only nodes cannot grant operational routing | Joint fixture review, isolated mutations only |
| Directed path 19,999.9 / 20,000.0 / 20,000.1 m | At most 20 km allowed; just beyond denied. Construct exact weighted graph locally; use real graph paired cases for operational plausibility | Teammate graph/distance oracle; coordination claim rejection evidence |
| Asymmetric A->B versus B->A | Use NGO->listing direction; reversing a reachable path can be unreachable or longer | Teammate routing oracle; joint claim/discovery consistency |
| Disconnected / one-way-unreachable paths | Fail closed; distinguish outcome labels from current implementation, no straight-line fallback | Teammate expected code/distance; authority no ownership commit |
| Pending/FAILED/stale NGO or listing generation | Not discoverable/claimable until current generation succeeds; on-demand routing cannot bypass pending or stale queue readiness | Coordination async tests plus teammate node/snapshot changes in isolated fixture |
| Snapshot/node/radius cache mismatch | Stale cached ELIGIBLE must not authorize claim; only matching current evidence accepted | Joint source/config manifest |
| No node/null coordinates/invalid input | Explicit unroutable/undetermined result, no successful claim; preserve photo/location validation | Existing location UI/tests + protected authority integration |
| Hub feasibility and route output | Use the same feasible set and directed graph for nearest/random/AI comparisons; route only authoritative confirmed tasks, independent validator checks load/time/connectivity | Teammate algorithms/validator; coordination task-authority checks |

500 m snapping and 20 km eligibility are different boundaries. Testing an error
message in Flutter does not execute PostGIS/pgRouting. Synthetic exact-boundary
graphs belong only to isolated PostgreSQL; the live operational graph is not
edited. Floating-point display rounding to three decimal km must not become an
authorization comparison. Record raw meters/costs and tolerances.

Reuse existing supabase/road_network sources, operational migration, frozen
benchmark manifest and independent validators. Do not regenerate a graph or
rebuild a baseline because a current acceptance result is missing. Record graph
snapshot/hash, directed pair, coordinates/node IDs, algorithm version, expected
raw distance/outcome, cache generation and observed source/time in the shared
case manifest. The teammate approves expected routing semantics; the database
remains the authority for ownership regardless of recommendation/ranking output.
