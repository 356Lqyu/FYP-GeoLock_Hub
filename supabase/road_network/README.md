# Operational road network

This folder holds the road network that the live GeoLock Hub backend (Supabase) uses.

When a user picks a location on the map, the backend matches it to the nearest
drivable road node. It then uses road distances, not straight lines, to decide:
- which NGOs can see and claim a listing;
- which community hubs a donor can reach.

Without this data every listing has no road node, and NGO claims are rejected.

**Status (DEV `rcgyuwiidqvrgbxswhqj`):** snapshot `OSM-OPS-20261018` imported from
`road_network_nodes.csv` (926,414 rows) and `road_network_edges.csv` (2,145,828 rows) and
activated on 2026-10-20. The activation matched the existing test donation and its
listing to road node `2308277369`. No NGO is registered yet, so claims are still to be
tested (see "End-to-end test in the app").

## Live data vs research data

| | This folder (live app) | `benchmark dataset/` (research) |
|---|---|---|
| Used by | Supabase triggers and RPCs, the Flutter app | Baselines, recommendation-model training, experiments |
| Built from | A Geofabrik OpenStreetMap extract only | Its own generator and frozen research graph |
| Changes | Can be rebuilt when OSM or the service area changes | Frozen |

The two are never mixed:
- the builder refuses inputs from `benchmark dataset/`, `baseline implementation/`
  or `experiments/`;
- the database only accepts snapshots named `OSM-OPS-*` with `OPERATIONAL` provenance.

## Coverage

Peninsular Malaysia only:
- **States:** Johor, Kedah, Kelantan, Melaka, Negeri Sembilan, Pahang, Pulau Pinang,
  Perak, Perlis, Selangor and Terengganu.
- **Federal territories:** Kuala Lumpur and Putrajaya.

| Included | Not included |
|---|---|
| Drivable public roads: motorway to residential, one-way rules respected | Footpaths, cycleways, tracks |
| A 5.5 km coastal band, so Penang Island and its bridges are kept | `service` roads (driveways, car parks), left out to fit the Free plan |
| Only roads connected to the main network | Private / no-access roads |
| | Islands without a road link (Langkawi, Pangkor, Tioman), Sabah, Sarawak, Labuan, Singapore, Thailand |

A location outside the coverage, or with no node within 500 m, is **not routable**.
The app blocks it for donor pickups and hubs, and NGO verification fails.

## How it works

```
User picks a point on the map (Flutter sends latitude/longitude, road node = null)
        │
        ▼
Database trigger, before the row is saved:
  geolock_resolve_road_node(lat, lon) → nearest active node within 500 m
  → written into the record (null if none)
        │
        ├─ Donation ≥ 10 kg → listing (same node) → road distance from every
        │  verified NGO is computed and stored
        ├─ Donation < 10 kg → only hubs reachable by road are offered
        └─ Hub registered or moved → hub node
        │
NGO: an operator runs verify_ngo_location → NGO node + road distance to open listings
        │
Discover shows listings ≤ 20 km by road ("READY", "x.x km by road")
        │
claim_listing re-checks: ROUTE_UNAVAILABLE / OUTSIDE_GEOFENCE / ELIGIBILITY_UNDETERMINED
        │ passes
Claim + 360-minute lease + pickup task (carries the node) in one transaction
```

| Who | How the node is matched |
|---|---|
| Donor pickup | Automatically, by trigger `trg_donation_road_node`, when the donation is saved |
| Listing | Automatically, by trigger `trg_listing_road_node`. A hub-batch listing uses the hub's location |
| Community hub | Automatically, by trigger `trg_hub_road_node`, on register or when the location changes |
| NGO | By an operator, with `verify_ngo_location`. NGO locations are self-selected, so they must be checked first |
| NGO vehicle depot | Automatically: the depot is the NGO's verified node |

## Where results are stored

| Result | Table / column |
|---|---|
| Road network | `road_network_nodes`, `road_network_edges` |
| Snapshot version, coverage, approval | `road_network_coverage` |
| Donor pickup node | `donations.pickup_road_node_id` |
| Listing node | `listings.pickup_road_node_id` |
| Hub node | `community_hubs.road_node_id` |
| NGO node and verification time | `ngo_profiles.road_node_id`, `ngo_profiles.location_verified_at` |
| Vehicle start point | `vehicles.depot_road_node_id` |
| Pickup task node | `pickup_tasks.pickup_road_node_id` |
| NGO → listing road distance and outcome | `ngo_listing_road_eligibility` |
| NGO verification and claim attempts | `audit_events` |

Road tables have RLS enabled, and app users have no direct access to them. The app
only uses the RPCs below.

## Flutter usage

Flutter never sends or chooses a road node; the database decides.

| Step | Call | Result |
|---|---|---|
| Check a picked point before confirming | `preview_location_routing(p_latitude, p_longitude)` | `{routable, snap_distance_m, max_snap_distance_m, reason_code}` |
| Create a donation | `create_donation_with_images(..., p_pickup_road_node_id: null, ...)` | The trigger assigns the node |
| Register a hub | `register_community_hub(..., p_road_node: null)` | The trigger assigns the node |
| Donor sees status | `get_my_donations()` → `listing_routing_status` | `READY`, `NOT_ROUTABLE`, `PENDING_NODE` |
| NGO discovery | `discover_eligible_listing_cards()` | Only listings ≤ 20 km by road. `distance_m` = road distance, `routing_status = READY` |
| NGO claim | `claim_listing(p_listing, p_request)` | `SUCCESS`, or `reason_code` `OUTSIDE_GEOFENCE` / `ROUTE_UNAVAILABLE` / `ELIGIBILITY_UNDETERMINED` / `CLAIM_CONFLICT` |
| Donor hub choice | `get_eligible_hubs(p_donation)` | Reachable hubs only, nearest by road first |
| Feature flag | `geolock_app_capabilities()` → `road_node_resolution` | `true` once a snapshot is active |

App code: `frontend/geolock_hub_app/lib/location/road_routing.dart`, used by the
location picker, the donation pages and the dashboards.

## Current snapshot: OSM-OPS-20261018

| | |
|---|---|
| Source | Geofabrik `malaysia-singapore-brunei-261018.osm.pbf` (OSM data of 2026-10-18), md5 `962e5488d557f21ed6f8cfba88eec0ad` |
| Drivable OSM nodes in the area | 4,863,935 |
| Stored nodes / directed edges | **926,414 / 2,145,828** |
| Connectivity | One connected network. 12,078 nodes on unlinked islands and stubs dropped |
| Accuracy check | 573,046 node pairs compared with the full OSM graph: 0 differences |
| Database size | About 371 MB (nodes 183 MB + edges 188 MB, including indexes) |
| Snap rule | Nearest node within 500 m. A node is kept at least every 350 m along every road |

Mid-road shape points are merged into longer edges. This doesn't change road distances
or connectivity, and it keeps the data within the 500 MB Free plan.

### Size options

| Variant | Nodes | Edges | Size | Roadside points with no node within 500 m |
|---|---|---|---|---|
| All road classes, 200 m spacing | 1.82 M | 4.22 M | ~700 MB | 2.96 % |
| No `service`, 200 m | 1.06 M | 2.40 M | ~430 MB | 4.12 % |
| **No `service`, 350 m (current)** | **0.93 M** | **2.15 M** | **~371 MB** | **~4.2 %** |
| Junctions only | 0.78 M | 1.88 M | ~320 MB | 11.38 % |

About 3 % of roadside points are never covered, because they're on islands with no road
link. On a paid Supabase plan, rebuild with `--exclude-highway` (no value) to keep
service roads.

## Files

| Path | Purpose |
|---|---|
| `build_operational_road_network.py` | OSM `.pbf` → `output/`: nodes, edges, coverage SQL, activation SQL, manifest |
| `import_operational_road_network.py` | Optional: loads `output/` into DEV in one transaction and checks counts. Needs Python + `psycopg` |
| `requirements.txt` | Python packages for the two scripts |
| `input/` | The Geofabrik extract (gitignored) |
| `output/road_network_nodes.csv` | 926,414 road nodes to import (54 MB, gitignored) |
| `output/road_network_edges.csv` | 2,145,828 directed road edges to import (81 MB, gitignored) |
| `output/operational_road_coverage.sql` | Registers the snapshot and its coverage area (inactive) |
| `output/activate_snapshot.sql` | Checks counts, activates the snapshot, re-matches open records |
| `output/manifest.json` | Counts, checksums, settings of the build |
| `../migrations/20261020_operational_road_node_resolution.sql` | Tables, resolver, triggers, distance checks |
| `../tests/road_network_preflight.sql` | Read-only check before the migration (all rows `ok = true`) |
| `../rollback/rollback_20261020_operational_road_node_resolution.sql` | Undoes the migration |

`output/` and `input/` are not in Git. To set up another project, either copy the
`output/` folder to the teammate, or rebuild it from the OSM extract (see "Rebuilding").

## Setup on a Supabase project (DEV only)

Do steps 4–7 in one sitting. Between the migration and activation, donors can't
reserve hubs.

0. **Check space and backup.** In the SQL Editor run
   `select pg_size_pretty(pg_database_size(current_database()));`. It must be under
   about 120 MB on the Free plan. Then confirm a recent backup under
   Database → Backups.
1. **Enable pgRouting:** Database → Extensions → `pgrouting`, schema `extensions`.
2. **Preflight:** run `supabase/tests/road_network_preflight.sql`. All 15 rows must be
   `ok = true`.
3. **Migration:** run `supabase/migrations/20261020_operational_road_node_resolution.sql`.
   If it stops with `FUNCTION_CHANGED_SINCE_REVIEW` or `OLD_ROAD_NETWORK_TABLES_PRESENT`,
   nothing was changed: review before continuing.
4. **Register the snapshot:** run `output/operational_road_coverage.sql`.
5. **Import the data.** Nodes first, then edges. Choose one method:
   - **Dashboard (no extra tools).** Table Editor → Insert → Import data from CSV:
     1. Table `road_network_nodes`: upload `output/road_network_nodes.csv`.
     2. Table `road_network_edges`: upload `output/road_network_edges.csv`.

     Check the totals after the uploads:

     ```sql
     select (select count(*) from public.road_network_nodes) nodes,
            (select count(*) from public.road_network_edges) edges;
     ```

     | Table | Expected rows |
     |---|---|
     | nodes | 926,414 |
     | edges | 2,145,828 |

     If an upload fails or a total is wrong, don't upload the file again on top. Run
     `truncate public.road_network_edges, public.road_network_nodes;` and start again
     from the nodes file.
   - **Python script:**

     ```powershell
     $env:GEOLOCK_DEV_DATABASE_URL = Read-Host "DEV session-pooler connection string"
     python supabase/road_network/import_operational_road_network.py
     Remove-Item Env:GEOLOCK_DEV_DATABASE_URL
     ```

     The connection string is never saved. The script refuses any project other
     than DEV.
6. **Activate:** run `output/activate_snapshot.sql`. If the counts don't match, it stops
   with `SNAPSHOT_COUNT_MISMATCH` and changes nothing. On success it prints the
   backfill summary, e.g. `{"donations_changed": 1, "listings_changed": 1, ...}`.
7. **Verify each NGO** (SQL Editor or a trusted Edge Function, never Flutter):

   ```sql
   select user_id, ngo_name, latitude, longitude, location_verified_at from public.ngo_profiles;
   select public.verify_ngo_location('<ngo user_id>', true, 'Address checked by operator');
   ```

   - `VERIFIED` plus `road_node_id` and `eligible_open_listings`: done.
   - `NGO_LOCATION_NOT_ROUTABLE`: the NGO must pick a location on or next to a road.

### Note on SQL pasted from Windows

SQL pasted into the SQL Editor from Windows is stored with `\r\n` line endings. The
preflight and the migration compare function bodies without `\r`, so this doesn't
cause false failures.

## Checks after activation

```sql
-- Totals, size, connectivity
select (select count(*) from public.road_network_nodes) nodes,                -- 926414
       (select count(*) from public.road_network_edges) edges,                -- 2145828
       (select count(distinct component_id) from public.road_network_nodes) components, -- 1
       pg_size_pretty(pg_database_size(current_database())) db_size;         -- < 500 MB

-- Every state / territory matches a node; sea and Singapore do not
select p.name, r.node_id, round(r.snap_distance_m::numeric,1) snap_m
from (values
 ('Johor Bahru',1.4927,103.7414), ('Alor Setar',6.1248,100.3678), ('Kota Bharu',6.1254,102.2381),
 ('Melaka',2.1896,102.2501), ('Seremban',2.7258,101.9424), ('Kuantan',3.8077,103.3260),
 ('George Town',5.4141,100.3288), ('Ipoh',4.5975,101.0901), ('Kangar',6.4414,100.1986),
 ('Shah Alam',3.0733,101.5185), ('Kuala Terengganu',5.3296,103.1370),
 ('Kuala Lumpur',3.1390,101.6869), ('Putrajaya',2.9264,101.6964),
 ('Sea (empty)',3.0,104.5), ('Singapore (empty)',1.2903,103.8520)) p(name,lat,lon)
left join lateral public.geolock_resolve_road_node(p.lat,p.lon) r on true;

-- Which records already have a node
select d.title, d.donation_status, d.pickup_road_node_id as donation_node,
       l.listing_status, l.pickup_road_node_id as listing_node
from public.donations d left join public.listings l on l.donation_id = d.donation_id;
```

## End-to-end test in the app

1. **Donor:**
   - Pick a point on a road: "Road access confirmed".
   - Pick a point at sea: Confirm is disabled.
2. **Donor:** create a donation of 10 kg or more. My Donations shows "Road route ready".
3. **NGO:** register within about 20 km by road of that donation. Then an operator
   verifies it (step 7); `eligible_open_listings` should be 1.
4. **NGO:** Discover shows the listing with "x.x km by road". Claim → committed.

   ```sql
   select c.claim_status, le.lease_status, le.expires_at - le.issued_at lease, t.pickup_road_node_id
   from public.donation_claims c join public.claim_leases le using (claim_id)
   join public.pickup_tasks t using (claim_id);
   -- ACTIVE | ACTIVE | 06:00:00 | <node>
   ```

5. **Optional:** a second NGO far away (e.g. Johor for a KL donation) does not see the
   listing. A claim returns `OUTSIDE_GEOFENCE`.

## Rollback

Run `supabase/rollback/rollback_20261020_operational_road_node_resolution.sql` in the
SQL Editor. In one transaction it:
1. removes the 6 triggers;
2. restores the 9 replaced functions to their original bodies;
3. removes the 16 new functions and the 4 road tables;
4. checks the result.

Existing donations, listings, claims and other rows are not touched.

## Rebuilding with newer OSM data

```powershell
python -m pip install -r supabase/road_network/requirements.txt
curl -L -o supabase/road_network/input/malaysia-singapore-brunei-<yymmdd>.osm.pbf `
  https://download.geofabrik.de/asia/malaysia-singapore-brunei-<yymmdd>.osm.pbf
python supabase/road_network/build_operational_road_network.py `
  --pbf supabase/road_network/input/malaysia-singapore-brunei-<yymmdd>.osm.pbf
```

`road_network_nodes.osm_node_id` is the primary key, so two snapshots can't be loaded
side by side. To replace the current one:
1. Pick a quiet time.
2. Deactivate the old snapshot and delete its nodes (edges are removed with them).
3. Repeat steps 4–6 for the new `OSM-OPS-<date>`.

Activation re-matches open donations, listings, hubs and verified NGOs.

Road data © OpenStreetMap contributors, ODbL 1.0.
