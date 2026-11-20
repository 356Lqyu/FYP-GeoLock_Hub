# Operational road network (Kuala Lumpur, Putrajaya and Selangor)

This folder holds the road network used by the live GeoLock Hub backend (Supabase DEV
`rcgyuwiidqvrgbxswhqj`).

When a user picks a location, the database matches it to the nearest drivable road
node within 500 m. Road distances, not straight lines, then decide which NGOs can see
and claim a listing and which community hubs a donor can reach. Without this data
listings have no road node and NGO claims are rejected.

## Service area

The app serves Kuala Lumpur, Putrajaya and Selangor only. Every other state is left
out, so the road data fits the 500 MB Supabase Free plan.

| | Peninsular `OSM-OPS-20261018` (old, removed) | `OSM-OPS-20261018-KLSEL` (now) |
|---|---|---|
| Nodes / edges | 926,414 / 2,145,828 | **205,524 / 454,178** |
| Database size | about 371 MB | **about 80 MB** |
| CSV files | 135 MB | 30 MB |

Putrajaya lies inside Selangor, so leaving it out would leave a hole that blocks
pickups and routes through it. Roads are kept up to about 2 km past the border so
points near the edge still find a node within 500 m. Users can only pick locations
inside the three areas.

Checks recorded in `output/manifest.json`:
- one strongly connected network;
- road distances up to 20 km between service-area nodes are 99.98 % identical to
  the old Peninsular network;
- on a 1 km grid, 3,906 of the 3,909 points that had a node within 500 m still have one.

Further cuts were checked and not taken. 200,753 of the nodes lie inside the three
areas, so a narrower border band saves less than 2 %. Only about 11 % of the nodes are
spacing points on long roads; removing them, or dropping residential roads, would
leave many pickup points without a node.

## Files

| File | Purpose |
|---|---|
| `output/` | The snapshot to import: nodes, edges, coverage SQL, activation SQL, manifest |
| `import_operational_road_network.py` | Does the whole switch in one transaction (recommended) |
| `free_previous_snapshot.sql` | SQL Editor switch, step 1: removes the old network |
| `check_usage.sql` | Read-only: database size, active snapshot, routing graph, biggest tables, job history, photo storage |
| `cleanup_cron_history.sql` | Deletes old scheduled job history (grows by about 4,300 rows a day) |
| `freeze_kl_selangor_graph.sql` | For the routing owner, after the switch: freezes the routing graph again |
| `build_operational_road_network.py` | OSM `.pbf` in `input/` → `output/`. Only needed to refresh the OSM data |
| `requirements.txt` | Python packages for the scripts |

The current `output/` was made on 2026-11-18 from the Peninsular snapshot with a
separate trim step, which used Natural Earth borders. The builder now cuts the three
areas straight from the OSM extract (OSM state borders), so the old Peninsular output
and the trim step are no longer needed and were removed. The provenance text inside
`output/operational_road_coverage.sql` still names that trim step; it is kept as it
is so the file hashes in `manifest.json` stay valid.

The files in `output/` use LF line endings (set in `.gitattributes`), so the hashes in
`manifest.json` match on Windows, Mac, Linux and GitHub.

## Why the switch needs care: the routing freeze

The routing worker froze the road tables when its graph was created. The triggers
`routing_graph_freeze` and `routing_graph_truncate` on `road_network_nodes`,
`road_network_edges` and `road_network_coverage` reject every insert, update,
delete and truncate while a row exists in `routing_private.graphs`
(`GRAPH_REVISION_FROZEN`).

Both switch methods below pause these six triggers only during the switch and turn
them back on at the end. No routing function is changed. Afterwards the old graph
(counts 926,414 / 2,145,828) no longer matches the data, so the routing worker refuses
to plan until the routing owner freezes a new graph (step 4).

## Switching DEV to KL, Putrajaya and Selangor

Pick a quiet time. While the switch runs, new pickups and hubs wait for a road node.

**1. Check.** Run `check_usage.sql` in the SQL Editor. Note the database size.
`open_routed_trips` must be 0. If it is not, finish or close those routes first
(their plans use the old nodes). Both methods stop by themselves if a trip is open.

**2. Switch.** Choose one method.

*Python, one transaction (recommended).* It either completes or changes nothing.

```powershell
python -m pip install -r supabase/road_network/requirements.txt
$env:GEOLOCK_DEV_DATABASE_URL = Read-Host "DEV session pooler connection string"
python supabase/road_network/import_operational_road_network.py
Remove-Item Env:GEOLOCK_DEV_DATABASE_URL
```

Type `SWITCH` when asked. The connection string is never saved or printed, and the
script refuses any project other than DEV.

*SQL Editor and Table Editor.* Do all four steps in one sitting. Between a and d the
freeze triggers are off.

  a. Run `free_previous_snapshot.sql`. It also lifts read-only mode if the project
     went over quota. `database_size_now` should drop by about 370 MB.
  b. Run `output/operational_road_coverage.sql`.
  c. Table Editor → `road_network_nodes` → Import data from CSV →
     `output/road_network_nodes.csv`. Then `road_network_edges` →
     `output/road_network_edges.csv`. Expect 205,524 and 454,178 rows.
     If an upload fails, run `truncate public.road_network_edges, public.road_network_nodes;`
     and start c again from the nodes file.
  d. Run `output/activate_snapshot.sql`. It checks the counts, activates the
     snapshot, turns the freeze triggers back on and re-matches open records.
     If it stops with `SNAPSHOT_COUNT_MISMATCH`, fix the import and run it again;
     the triggers stay off until it succeeds.

**3. Verify.** Run `check_usage.sql` again (about 80 MB of road data instead of 370 MB),
then the place test:

```sql
select p.name, r.node_id, round(r.snap_distance_m::numeric, 1) snap_m
from (values ('Kuala Lumpur', 3.1390, 101.6869), ('Shah Alam', 3.0733, 101.5185),
             ('Putrajaya', 2.9264, 101.6964), ('Klang', 3.0449, 101.4456),
             ('Ipoh (outside)', 4.5975, 101.0901), ('Johor Bahru (outside)', 1.4927, 103.7414)
     ) p(name, lat, lon)
left join lateral public.geolock_resolve_road_node(p.lat, p.lon) r on true;
```

The first four get a node, the two outside do not. Records outside the three areas
lose their road node and show as not routable.

**4. Routing owner: freeze a new graph.** Run `freeze_kl_selangor_graph.sql` with psql as
`geolock_graph_login`, set the planner's `GEOLOCK_GRAPH_ID` to the printed `graph_id`,
and delete the old graph cache in the worker state folder. The read-only probes in
`backend/routing/worker_service/` still expect the old snapshot id and counts; the
routing owner updates them together with the new graph.

**5. Optional: job history.** Run `cleanup_cron_history.sql` if `check_usage.sql` shows
the job history taking space.

## Coverage

| Included | Not included |
|---|---|
| Drivable public roads in KL, Putrajaya and Selangor, motorway to residential, one-way rules respected | Footpaths, cycleways, tracks |
| Roads up to about 2 km past the border | `service` roads (driveways, car parks), left out to fit the Free plan |
| Only roads connected to the main network | Private / no-access roads, every other state |

A location outside the coverage, or with no node within 500 m, is not routable. The
app blocks it for donor pickups and hubs, and NGO verification fails.

## How it works

```
User picks a point on the map (Flutter sends latitude/longitude, road node = null)
        │
        ▼
Database trigger, before the row is saved:
  geolock_resolve_road_node(lat, lon) → nearest active node within 500 m (null if none)
        │
        ├─ Donation ≥ 10 kg → listing (same node) → road distance from every verified NGO
        ├─ Donation < 10 kg → only hubs reachable by road are offered
        └─ Hub registered or moved → hub node
        │
NGO: an operator runs verify_ngo_location → NGO node + road distance to open listings
        │
Discover shows listings ≤ 20 km by road; claim_listing checks again
```

| Who | How the node is matched |
|---|---|
| Donor pickup | Trigger `trg_donation_road_node` when the donation is saved |
| Listing | Trigger `trg_listing_road_node`. A hub-batch listing uses the hub's location |
| Community hub | Trigger `trg_hub_road_node`, on register or when the location changes |
| NGO | An operator, with `verify_ngo_location` |
| NGO vehicle depot | The NGO's verified node |

Flutter never sends or chooses a road node. It calls `preview_location_routing` before
a point is confirmed and reads `routing_status` from the listing RPCs. App code:
`frontend/geolock_hub_app/lib/location/road_routing.dart`.

## Live data vs research data

| | This folder (live app) | `benchmark dataset/` (research) |
|---|---|---|
| Used by | Supabase triggers and RPCs, the Flutter app | Baselines, model training, experiments |
| Built from | A Geofabrik OpenStreetMap extract only | Its own generator and frozen research graph |
| Changes | Rebuilt when OSM or the service area changes | Frozen |

The builder refuses inputs from `benchmark dataset/`, `baseline implementation/` or
`experiments/`, and the database only accepts snapshots named `OSM-OPS-*` with
`OPERATIONAL` provenance.

## Rebuilding from newer OSM data

```powershell
python -m pip install -r supabase/road_network/requirements.txt
mkdir supabase/road_network/input
curl -L -o supabase/road_network/input/malaysia-singapore-brunei-<yymmdd>.osm.pbf `
  https://download.geofabrik.de/asia/malaysia-singapore-brunei-<yymmdd>.osm.pbf
python supabase/road_network/build_operational_road_network.py
```

The builder takes the newest `.osm.pbf` in `input/` (gitignored), cuts the three areas
from the OSM state borders and overwrites `output/` with a snapshot named
`OSM-OPS-<extract date>-KLSEL`. Settings such as the border band and node spacing are
constants at the top of the script. Then switch as above (update the expected counts in
step 2c and in `freeze_kl_selangor_graph.sql`) and freeze a new routing graph. The
`.osm.pbf` can be deleted afterwards.

## Setting up a new Supabase project

Enable `pgrouting` (schema `extensions`), run `supabase/tests/road_network_preflight.sql`
(all rows `ok = true`), run `supabase/migrations/20261020_operational_road_node_resolution.sql`,
then import as in step 2.

Road data © OpenStreetMap contributors, ODbL 1.0.
