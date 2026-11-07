# Stage B.1 — real spatial verification

**PARTIAL: local extension limitation resolved; geographic acceptance has two
failing checks.** Final run: 22 checks, 20 PASS, 2 FAIL, zero skipped. Failures are
retained, not suppressed or converted into passes. No Supabase access occurred.
No production function, historical migration or existing PostgreSQL configuration
was changed.

## Investigation and installation

Installed PostgreSQL is 17.11 x64, under `C:/Program Files/PostgreSQL/17`.
`pg_config --sharedir` reports its `share` directory; extensions belong under
`share/extension`, with libraries under `lib`. There were no `postgis.control`
or `pgrouting.control` files. PostgreSQL itself was working; the optional spatial
binary packages were absent. This says nothing about the user's Supabase setup.
The installed extension directory still lacks those files after these tests.

Docker/Podman executables were not found on PATH or their checked standard
installation paths. The available wsl.exe returned installation/help text rather
than a usable distribution inventory. No runtime/WSL feature/service was installed
or configured. The safest immediately available method was a portable private
copy rather than changing the installed server.

Official PostGIS documentation lists a PostgreSQL 17 x64 binary bundle containing
both PostGIS and pgRouting:

- https://postgis.net/documentation/getting_started/install_windows/released_versions/
- https://postgis.net/documentation/getting_started/install_windows/enabling_postgis/
- Download: https://download-cache.osgeo.org/postgis/windows/pg17/postgis-bundle-pg17-3.6.2x64.zip

Downloaded archive: 123,959,035 bytes. SHA-256:
`7ba180ee2a352987b9a2f194673652c59483b55852295ccf401dceccd8765425`.
This is the observed artifact hash, not a separately verified publisher signature.

Installation was limited to a new `geolock-spatial-runtime-*` temporary directory:
copy the installed server's bin/lib/share there, overlay the ZIP's matching
directories, and initdb a fresh data directory for each attempt. No installer,
Windows service registration, system PATH edit, existing database connection,
extension upgrade or existing-instance restart was performed. The relocated
pg_config confirms the private share/lib paths. The runner uses only explicit
127.0.0.1/random-port connections and strips external connection variables.
All new clusters were stopped. Their private files remain available for review;
the temporary runtime location is recorded in `results/stage-b1/runtime-path.txt`.

Actual runtime versions from `attempt-06/environment.json`:

| Component | Observed result |
|---|---|
| PostgreSQL | 17.11 x64 Windows |
| PostGIS | 3.6.2, installed in schema extensions |
| pgRouting | 4.0.1, installed in schema extensions |
| GEOS | 3.14.1dev-CAPI-1.20.4, as reported by this binary bundle |
| PROJ | 8.2.1, network disabled |
| pgRouting build | PostgreSQL 17.2, GNU 13.2.0, Boost 1.88.0; successfully loaded on 17.11 |

## Actual schema and migration execution

`attempt-06/applied.json` contains source hashes and exact order: full public
snapshot; October 19 claim/reconciliation, retire-DELIVERED and remove-VALIDATED;
October 20 operational roads; October 21 registration; October 22 onboarding;
October 23/24 async eligibility; October 25/26 audit corrections; October 27
persisted lifecycle; October 29/30 recovery fixes; October 31 claim/audit/failure.
Historical files execute unchanged. Snapshot psql restrict directives alone are
removed for file transport. This is snapshot-plus-relevant-migrations replay,
not every historical migration and not the Stage A routing cutover package.

Auth identity and Storage metadata remain local adapters. An inert cron catalog
and schedule recorder satisfy migration catalog dependencies: there is **no real
scheduler**, worker activation or recovery execution. Queue functions are called
explicitly only inside the new disposable database. Geographic functions,
spatial types/indexes, shortest paths, readiness guards and queue processing are
real production SQL, not replacement geographic doubles.

The registry fixture has a clearly synthetic local snapshot name and provenance;
its OPERATIONAL marker is necessary to exercise operational guards locally and
does not represent an imported or approved OSM dataset. Nodes are at (3,101) and
(3.01,101.01); edge weights are explicitly constructed synthetic road distances.
Donation/listing creation uses the protected photo-backed creation RPC; no claim
or lease is created for these geographic checks.

Earlier attempts are retained: Windows pg_ctl inherited-pipe handling; missing
extensions search_path for pgr_full_version; omitted historical get_eligible_hubs
prerequisite; incomplete inert cron catalog. These were test-environment defects,
not extension incompatibility. No source guard was bypassed or hash adopted.

## Actual SQL results

Final evidence: `results/stage-b1/attempt-06/checks.json`. All submitted SQL is
retained under its `sql/` directory; operations.jsonl records outputs, SQL hashes
and timings. Server logs include shutdown confirmation.

| Check | Result |
|---|---|
| PostGIS SRID and real geography distance operations | PASS |
| pgRouting directed forward shortest path / unavailable reverse | PASS / PASS |
| Invalid latitude/longitude, NaN and NULL resolver inputs | PASS: no resolved node |
| Repeated unique-nearest-node resolution | PASS |
| Outside 500 m snapping / inactive snapshot | PASS / PASS: no resolved node |
| Missing source node to existing target | PASS: no path row |
| Same nonexistent source and target node | **FAIL: one fabricated self-distance row** |
| Pending listing generation | PASS: ELIGIBILITY_UNDETERMINED |
| Real listing queue processor and current readiness guards | PASS / PASS |
| 19,999.9 / 20,000 / 20,000.1 m | PASS / PASS / PASS |
| Directed unreachable NGO-to-listing eligibility | PASS: never ELIGIBLE |
| Different-component unreachable reason | PASS: ROUTE_UNAVAILABLE |
| Missing NGO node | PASS: never ELIGIBLE |
| Worker matrix vs actual pgRouting costs | PASS within explicit 0.002 m projection tolerance |
| Worker reverse unreachable matrix entry | PASS: UNREACHABLE and null cost |
| Explicit production float-output projection | PASS |
| Equal-distance nearest-node selection across reinsertion order | **FAIL: 101 then 100** |

## Boundary evidence

Actual `geolock_ngo_listing_road_check` and underlying pgRouting/cache results:

| Specified road distance m | Actual float4-backed shortest path m | Outcome |
|---:|---:|---|
| 19999.9 | 19999.900817871094 | ELIGIBLE |
| 20000 | 20000 | ELIGIBLE |
| 20000.1 | 20000.099182128906 | OUTSIDE_GEOFENCE |

The inclusive `<= 20000` predicate behaves correctly for these three cases. Input
weights are stored as production `real`, so binary values are not exact decimal
inputs. The RPC rounds displayed km to three decimals: all three responses show
20.0 km, including the rejected one. Authorization must use the outcome/raw
predicate, never that rounded display field. Evidence: boundary-evidence.json.

The worker export uses PG_REAL_OUTPUT_0 decimal projection. Its maximum difference
from raw float4-backed pgRouting cost was 0.0008178710935 m on this fixture. This
is measured projection error, not an exact-equality claim. Matrix evidence uses
the real Python worker with database rows and a **local manifest adapter** whose
digest is a placeholder; it does not prove protected snapshot attestation or
operational full-network performance. No Supabase request is made by that code.

An unreachable pair with intentionally identical component labels returns
OUTSIDE_GEOFENCE/null distance in current code. With distinct component labels it
returns ROUTE_UNAVAILABLE. Both deny eligibility; reporting the first as a proven
physical distance above 20 km would be misleading. Component quality matters.

## Two defects requiring reviewed forward corrections

1. `20261020_operational_road_node_resolution.sql:187` orders only by geography
   KNN distance. Two coincident nodes resolved to 101, then 100 after reloading
   identical node records in ascending ID order. Minimal proposed correction:
   preserve the distance expression and append `n.osm_node_id` as a stable
   secondary ordering key. Repeat the physical-order test afterward. No function
   definition was changed here. See nearest-tie-evidence.json.
2. The same file at line 219 returns `(s,s,0)` from matching input arrays without
   verifying that s exists and is active in the current snapshot. Inputs
   `[999999] -> [999999]` returned one zero-cost row, although no such node exists.
   Minimal proposed correction: validate the self-node against the active road
   snapshot before emitting zero distance. This is an internal-helper fail-closed
   gap, not demonstrated exploitation through protected registration/claim APIs.
   The failed SQL/actual row count are retained in checks.json and operations.jsonl.

## Remaining compatibility and acceptance risks

Real local PostGIS/pgRouting acceptance is now executed; it is **not fully passed**.
Do not promote geographic eligibility to ready for authenticated DEV acceptance
until the two defects are reviewed/corrected and their regressions pass. Keep
the current failure evidence and original historical migrations unchanged.

Further work: version/schema/function-overload parity with Supabase; trusted OSM
coverage/component/snap quality; larger real-network performance; PostgreSQL
geography KNN distance vs spheroidal-distance edge cases; full frozen matrix
attestation; real Auth/PostgREST/Storage acceptance; currently untested NGO async
worker branches. These 22 cases do not establish universal geographic correctness.

For a later separately approved read-only DEV comparison, the exact information
needed is PostgreSQL server_version_num; postgis/pgrouting extversion and schema;
PostGIS full build versions (GEOS/PROJ) and pgRouting full build version;
pgr_dijkstraCost overload signatures; resolver/road-cost/readiness/check function
definitions or fingerprints/search_path; actual road edge types, active snapshot
metadata and component policy. No such information was queried in Stage B.1.
No permission to access DEV or shared Supabase is inferred from this report.

Reproduce with the already prepared private runtime and a NEW evidence folder:

```powershell
$spatialRoot = (Get-Content results/stage-b1/runtime-path.txt -Raw).Trim()
.venv-stage8/Scripts/python.exe -B supabase/tests/stage8_spatial_isolated_test.py --run-isolated --runtime $spatialRoot --output-dir results/stage-b1/NEW-UNUSED-DIRECTORY
```

Expected exit is nonzero while the two source defects remain. Do not change the
expected assertions to obtain a passing result. Stage B's earlier 372-test count
is historical and not recomputed or overwritten by this spatial run.
