# Stage B.2 — spatial corrections and remaining-work accounting

**COMPLETE within the approved local spatial-correction scope.** Broader Stage B
and authenticated DEV acceptance remain PARTIAL/unapproved. Final fresh-cluster
run: **69 PASS, 0 FAIL, 0 skipped**. This includes all 22 prior spatial checks.
No Supabase connection, deployment, live experiment, real cron configuration
change, historical migration edit or unrelated backlog implementation occurred.

## Exact files changed

New files only:

1. `docs/stage8/stage-b2/forward-migrations/20261104_spatial_endpoint_validation.sql`
   — reviewed forward SQL correcting the two geographic helper defects.
2. `supabase/tests/stage8_spatial_correction_isolated_test.py`
   — fresh-cluster runner reusing the unchanged B.1 real spatial suite plus
   endpoint, planner, privilege, source-preservation and claim-compatibility tests.
3. `docs/stage8/stage-b2/REPORT.md` — results, review and remaining-work matrix.
4. `docs/stage8/stage-b2/CHAPTER5_READINESS.md` — current status of all eight areas.
5. `results/stage-b2/` and `results/stage-b2-first.log` — raw attempts, SQL,
   diagnostics, catalogs, environment, audit/claim evidence and file hashes.

Earlier B/B.1 reports, runners, failure evidence and all historical migration
sources remain unchanged. No live baseline or expected deployed fingerprint was
updated. The new forward migration stays outside the auto-deployment directory.

## Forward migration review

The resolver retains its exact geography KNN distance expression, approved active
snapshot, coverage, coordinate-range and 500 m predicates. The only resolver body
change is a secondary `n.osm_node_id` ordering, preserving the primary criterion.

The road-cost helper first validates both input endpoint sets against active
nodes in the approved active snapshot. Invalid endpoints produce no rows; mixed
sets retain only valid endpoints. Valid duplicate endpoint IDs collapse to one
node, and a valid isolated node still returns precisely one zero-cost self row.
The self shortcut occurs only after this validation. Directed routing remains
`pgr_dijkstraCost(..., true)` with reverse cost -1. The graph query now checks
target-node activity and snapshot as well as source-node activity and snapshot,
so invalid intermediate nodes cannot create a valid-looking route. Invalid/null
centers and negative/nonfinite/null radius fail closed. The policy radius remains
20,000 m; no configuration values are updated.

Before replacing either function, the migration requires the reviewed original
body hashes derived from unchanged October 20 source, expected signatures,
owner, SECURITY DEFINER, volatility and search_path, private execution privileges,
one approved 500 m operational snapshot and unchanged 20 km/360-minute/10 kg
configuration. It checks the actual supported pgRouting many-to-many overload
(polymorphic anyarray in local pgRouting 4.0.1). It does not enable/change an
extension. CREATE OR REPLACE preserves OIDs, owners and ACLs. No grants, business
row writes, table changes, cron operations or lifecycle replacements are present.
Replay refuses the already-changed source; this is intentionally not a blind
idempotent deployment script.

## Installation and real environment

Fresh disposable portable PostgreSQL 17.11 x64, PostGIS 3.6.2 and pgRouting 4.0.1,
both extensions in schema extensions, reused from B.1's private binary runtime.
Explicit 127.0.0.1/random-port connection only; no existing server or database
was accessed. Final environment and full extension build details are in
`results/stage-b2/b2-attempt-03/environment.json`.

The unchanged B.1 snapshot-plus-migration installation (October 19 through 31,
including operational roads and real async eligibility) runs first. The B.2
forward correction runs last, before geographic tests. Exact order and hashes:
`applied.json`. The SQL compiled and executed successfully. All submitted SQL,
actual outputs, timings and errors are retained in sql/ and operations.jsonl;
NOTICE/error streams are separately retained in diagnostics.jsonl. Server logs
and results.json confirm the disposable cluster stopped.

Real PostGIS/pgRouting and production geographic SQL are used. Auth GUC, Storage
metadata and inert cron catalog adapters remain; no scheduler exists. The fixture
is explicitly synthetic and its registry OPERATIONAL flag is solely a local
operational-guard fixture, not approved OSM provenance. The Stage A routing
authorization cutover package was not reapplied here; broader full-stack
acceptance is outside this correction's claims.

## Determinism and fail-closed evidence

The prior failing tie now returns node **100 before and after reinsertion**.
Ascending and descending insertion orders each ran 25 coordinate-correlated
resolver calls under sequential-scan and index-scan planner profiles: **100/100
selected node 100**. EXPLAIN of the equivalent resolver body shows Seq Scan in
the sequential profile and Index Scan in the index profile, both followed by
the stable sort. Evidence: nearest-tie-evidence.json and tie-plan-evidence.json.
This demonstrates the tested local plans/orders, not every possible future plan.

The original nonexistent `[999999] -> [999999]` now returns zero rows. Valid
101->101 returns one zero-distance row, including duplicate IDs and no edges.
Missing, inactive (201), and out-of-snapshot (301) nodes each return no rows as
self, source and target. Valid distinct endpoints still route; reverse paths
remain unreachable. Null/empty arrays, null members, invalid center/radius,
inactive targets, inactive/out-of-snapshot intermediates, missing edges and
missing active snapshots fail closed. Negative edge-weight, single-active-
snapshot and approval constraints still reject invalid writes in this new
disposable fixture. No failed check was skipped or redefined as success.

All prior real spatial regression checks pass, including boundary results:

| Specified road m | Actual float4-backed path m | Outcome |
|---:|---:|---|
| 19999.9 | 19999.900817871094 | ELIGIBLE |
| 20000 | 20000 | ELIGIBLE |
| 20000.1 | 20000.099182128906 | OUTSIDE_GEOFENCE |

Boundary evidence retains raw distances and rounded RPC values. All three RPC
display distances round to 20.0 km; authorization must use outcome/raw predicate.
Real pgRouting vs worker matrix consistency still passes the explicit 0.002 m
float-projection tolerance; unavailable reverse arcs remain null/UNREACHABLE.
Matrix evidence uses a local export adapter, not protected full-stack attestation.

## Security, audit and lifecycle compatibility

Catalog comparison covers **86 public functions** before/after. Only the two
reviewed helper bodies changed. All function OIDs, signatures, owner, SECURITY
DEFINER setting, volatility, search_path, return type and ACLs are unchanged.
Claim, recovery, pickup, reconciliation and other function bodies are unchanged.

Actual direct execution of both helpers is denied for anon, authenticated and
service_role. The test fixture grants only public-schema USAGE to these roles
so denial reaches function ACLs rather than merely a missing schema grant. This
is disposable fixture setup, not a migration grant or deployed ACL assumption.

Protected current claim succeeds using real corrected eligibility; retry returns
the same claim/result with the contract's `replayed: true` flag and no new audit
events. Committed donation CLAIMED, claim/lease ACTIVE, 360-minute lease, CONFIRMED
task and donation-audit claim/lease/transaction linkage pass. This verifies a
focused compatibility path, not collection, failure-injection or race coverage.

Earlier B.2 attempts remain: schema-prefix formatting, combined NOTICE/JSON
transport, schema-level vs function-level permission fixture, an ambiguous USING
join in the verification query, and an incorrect exact-response replay assertion
that omitted the current replay flag. These harness errors were corrected using
the actual contract. Function ACL assertions were strengthened through schema
USAGE, not relaxed. The historical 372-test Stage B result is not rerun or added
to this stage's 69-check count.

Reproduce using a new output directory:

```powershell
$spatialRoot = (Get-Content results/stage-b1/runtime-path.txt -Raw).Trim()
.venv-stage8/Scripts/python.exe -B supabase/tests/stage8_spatial_correction_isolated_test.py --run-isolated --runtime $spatialRoot --output-dir results/stage-b2/NEW-UNUSED-DIRECTORY
```

## Remaining Stage B.1 / broader Stage B accounting

The preceding B.1 request authorized local spatial investigation/testing. It did
not close the broader Stage B backlog. B.2 explicitly permits accounting for the
following items, not implementation. No new nonspatial experiment was run here.

| Area | Status | Completed evidence | Remaining work |
|---|---|---|---|
| A RoutingModel NONREPRODUCIBLE_RESULT and 30-second repeatability | **Partially completed** | Stage B actual RoutingModel/unit tests and `results/stage-b/routingmodel-report-profile.json`: one validated one-task run with 30-second upper bound. Earlier short-budget replay failure remains in `python-routing-tests-final.log`. | No completed root-cause analysis or repeated 30-second snapshot series; fixed toy replay is insufficient. Freeze supported seed/budget/repeat policy without removing the replay guard. No additional solver work in B.1/B.2. |
| B Whole-hub-batch pickup/collection | **Not started — current composed-package runtime acceptance** | Existing hub lifecycle/static assertions and older test functions are reusable; they do not establish current spatial/routing acceptance. | Prepare protected whole-batch fixtures and test all members, inventory, authorization, collection/reconciliation and depot closure. No current whole-batch run in B/B.1/B.2. |
| C Recovery-versus-pickup and lifecycle races | **Partially completed** | Stage B `attempt-07/results.json` and `postgresql-final.log`: cancellation/start ordering, publication replay, reconciliation serialization/contention and reserved-task recovery. | Recovery-versus-pickup, remaining lock orders/crash cases and whole-batch/legacy interactions remain unexecuted. B.2 adds no race/recovery execution. |
| D Remaining SQL authorization negatives | **Partially completed** | Stage B real security/rollback tests; B.2 direct helper ACL denials and source/security preservation in checks.json. | Routing SQL capacity/window/duration and other cutover/released-authority negatives are not closed by solver-level tests or these helper tests. |
| E Actual Flutter-to-disposable-backend | **Blocked** | Stage B 67 mocked-transport Flutter tests/analyzer and actual solver invocation regression; documented SQL contract inspection. Local postgrest/gotrue/supabase/docker/podman commands were not found. | Real local Auth/PostgREST/Storage gateway, token/session path, independent worker/validator transport and app integration driver absent/unverified. Technically feasible with separately approved local infrastructure; not implemented here. |
| F Eight-area Chapter 5 readiness | **Completed — accounting only** | Updated `CHAPTER5_READINESS.md` links existing runners, evidence and exact remaining prerequisites for all eight tracks. | Formal experiment execution/readiness remains PARTIAL; no final experiment was run. |

## Remaining risks and next checkpoint

The two local spatial defects are corrected and regressions pass. This does not
verify deployed Supabase versions, schemas, function fingerprints, OSM quality,
large-network performance, real Auth/Storage/PostgREST or Flutter acceptance.
Existing geographic KNN versus spheroidal-distance semantics and component/reason
classification remain unchanged. There is no authorization for DEV inspection.

Recommended next approval: **local RoutingModel reproducibility investigation**,
including separately labelled repeated 30-second verification cases, preserved
raw statuses/plans and an explicit repeatability policy. This targets the next
methodology blocker without mixing it with hub/lifecycle/gateway work. Those
areas need separately defined local verification scope. Any future DEV read-only
comparison or deployment requires new explicit approval. Stop after B.2.
