# Algorithm 6 road eligibility review

The SQL is a review draft. It belongs outside the automatic migration directory. It replaces the two eligibility cache writers, the discovery cache reader and the protected claim cache check. It leaves claim issuance, locks, leases, recovery, the planner, the validator and the frozen graph alone.

## Bounds and outcomes

On snapshot `OSM-OPS-20261018` and frozen graph `eab1f7ee-a8e0-4bed-a0e1-2c4bff024936`, the read-only DEV scan covered all 2,145,828 edges. Every edge had two active same-snapshot endpoints in the same recorded component and a positive finite weight. The maximum endpoint geodesic divided by the stored road weight in metres was 1.01681998402037. The draft binds the conservative factor 1.02 to this snapshot, graph ID, digest and counts.

For any directed path costing at most 20 km, the geodesic distance from either snapped endpoint to any path vertex is at most 1.02 times the cost of the intervening path segment by the triangle inequality. Every such vertex therefore lies within the 20.4 km search region centered on that snapped endpoint. Each refresh can batch routes using its own common endpoint as the center while preserving every path eligible at 20 km. The prefilter also compares snapped endpoints against that bound. The final decision still uses the unrounded directed road cost and an inclusive 20 km limit.

| Result | Evidence |
|---|---|
| `ELIGIBLE` | A directed cost at or below 20 km. |
| `OUTSIDE_GEOFENCE` | A directed path was found, but its minimum cost in the bounded search exceeds 20 km. The certified bound rules out a missed path within the limit. |
| `ROUTE_UNAVAILABLE` | Valid nodes are in different certified components with no intercomponent edges. |
| `ELIGIBILITY_UNDETERMINED` | Missing or stale metadata, unsupported graph, or no path found within the supplied edge subset without proof of disconnection. A one-way pair inside the same recorded component can fall into this case. |

The cache schema stays the same. Indeterminate pairs produce no cache row. Both claim lookups match snapshot, nodes and radius. Discovery uses those same identity fields and existing readiness checks. Concurrent inserts upsert the same key. The legacy positive rows remain usable because their cached cost already proves eligibility. Their exact displayed cost can improve the next time they are refreshed.

## Verification and release considerations

Run the bounded-search reproduction and draft tests with installed PostgreSQL, PostGIS and pgRouting:

```powershell
python -B docs/stage8/algorithm6-eligibility/test_local_eligibility.py --pg-bin 'C:/Program Files/PostgreSQL/17/bin'
```

The fixture uses synthetic endpoints and graph metadata, loads the actual baseline road helper bodies, and creates and stops a fresh loopback database. It reproduces the original failure using endpoint snaps within 500 m, then checks both refresh directions, inclusive 20 km, 19 and 21 km cases, one-way and disconnected cases, the four cache identity predicates independently, overlapping cache writers and certificate mismatch. The app test uses mocked claim RPC results. The separate claim and recovery suites exercise existing protections in their own fixtures.

Before any separate deployment decision, reconfirm the frozen graph identity, coverage, enabled freeze triggers, finite positive weights, valid endpoint membership, and the per-edge bound. Coordinate the deployment window so the negative-cache precondition can be trusted while switching the readers and writers. The draft stops if legacy negative rows are present, so their refresh or disposition requires explicit review. Re-certify the bound before changing graph snapshots. A different graph fails closed.

DEV has pgRouting 3.4.1. The local pgRouting fixture uses the installed version, and its timing is not a DEV load benchmark. A read-only count of candidate edges around 18 current cache anchors at 20.4 km found 56,399 to 201,342 edges, with a median of 151,021, out of 2,145,828 total edges. Verify execution plans, peak memory and concurrent latency with a disposable DEV-sized graph and the DEV extension version before deployment. The isolated two-writer check covers one overlapping cache key; larger worker and graph-switch schedules require separate testing.
