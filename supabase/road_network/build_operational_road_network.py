#!/usr/bin/env python3
"""Build the OPERATIONAL road network that Supabase uses to snap live locations.

Input : a Geofabrik OpenStreetMap extract (.osm.pbf). Nothing else.
Output: CSV/SQL files in the exact column layout of
        supabase/migrations/20261020_operational_road_node_resolution.sql
        (road_network_coverage, road_network_nodes, road_network_edges).

Rules (FYP report section 3.3.1 and 3.3.5.1):
  * Study area: the 11 Peninsular Malaysia states plus the Federal Territories of
    Kuala Lumpur and Putrajaya, taken from the OSM state boundaries in the extract.
  * Only drivable ways; one-way restrictions and inactive/closed ways respected.
  * Edge travel time = length / OSM maxspeed when usable, else the default speed
    of the road class (SPEED_KMH below). No live traffic.
  * Connectivity: only the largest strongly connected component is kept, so every
    node can reach every other node in both directions. A location whose nearest
    node is not on that network therefore finds no node and is "not routable".
  * Pass-through points are contracted (shortest paths verified unchanged), but a
    node is kept at least every --max-spacing-m metres (default 350 m) so a point
    beside a road still finds a node well within 500 m.
  * Default excludes highway=service (driveways, car parks): it halves the network
    and pickups snap to the public road instead (see README "Sizing").

This pipeline never reads `benchmark dataset/`, `baseline implementation/` or
`experiments/`. The benchmark builds its own frozen research graph; the live app
uses only this snapshot.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import platform
import re
import sys
import time
import zipfile
from array import array
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import osmium
import shapely
from scipy.sparse import csr_matrix
from scipy.sparse.csgraph import connected_components
from shapely import wkb
from shapely.geometry import MultiPolygon, Polygon
from shapely.ops import unary_union

# ISO 3166-2 codes of the study area (report 3.3.1). Sabah, Sarawak, Labuan excluded.
STUDY_AREA = {
    "MY-01": "Johor", "MY-02": "Kedah", "MY-03": "Kelantan", "MY-04": "Melaka",
    "MY-05": "Negeri Sembilan", "MY-06": "Pahang", "MY-07": "Pulau Pinang",
    "MY-08": "Perak", "MY-09": "Perlis", "MY-10": "Selangor", "MY-11": "Terengganu",
    "MY-14": "Kuala Lumpur", "MY-16": "Putrajaya",
}
# Generous bounding box of Peninsular Malaysia (Borneo starts east of 109 E).
BBOX = (99.4, 0.8, 104.9, 6.9)  # min lon, min lat, max lon, max lat
# Several OSM state boundaries follow the coastline, so clipping roads to them would
# cut the Penang bridges (isolating Penang Island) and reclaimed coastal land. Roads
# are therefore clipped to the states plus a coastal band of BRIDGE_BAND_DEG, minus
# Singapore and the band along the Thai land border (north of THAI_BORDER_BAND_LAT).
# Locations themselves must still fall inside the states (coverage_area).
BRIDGE_BAND_DEG = 0.05            # ~5.5 km: Penang bridges are <= ~4.5 km from shore
EXCLUDED_NEIGHBOUR_ISO = "SG"
THAI_BORDER_BAND_LAT = 5.6        # Penang bridges lie at 5.27-5.36 N

# Default speed (km/h) per drivable highway class when maxspeed is absent/unusable.
SPEED_KMH = {
    "motorway": 90, "motorway_link": 60, "trunk": 70, "trunk_link": 50,
    "primary": 60, "primary_link": 45, "secondary": 50, "secondary_link": 40,
    "tertiary": 40, "tertiary_link": 35, "unclassified": 30, "residential": 25,
    "living_street": 10, "service": 15,
}
EXCLUDED_SERVICE = {"parking_aisle", "drive-through", "emergency_access"}
NO_ACCESS = {"no", "private"}
ALLOW_ACCESS = {"yes", "permissive", "destination", "designated"}
MAX_SNAP_DISTANCE_M = 500  # report 3.3.5.1; fixed by the migration's check constraint


def drivable_profile(tags, excluded=frozenset()) -> tuple[float, int] | None:
    """(speed_kmh, direction) for a drivable way, or None.

    direction: 1 = forward only, -1 = reverse only, 0 = both ways.
    """
    hw = tags.get("highway")
    if hw not in SPEED_KMH or hw in excluded:
        return None
    if tags.get("area") == "yes" or tags.get("service") in EXCLUDED_SERVICE:
        return None
    motor = tags.get("motor_vehicle") or tags.get("motorcar") or tags.get("vehicle")
    if motor in NO_ACCESS or motor == "no":
        return None
    if tags.get("access") in NO_ACCESS and motor not in ALLOW_ACCESS:
        return None

    oneway = tags.get("oneway", "")
    if oneway == "reversible":
        return None
    if oneway in ("yes", "1", "true"):
        direction = 1
    elif oneway == "-1":
        direction = -1
    elif oneway == "no":
        direction = 0
    elif hw == "motorway" or tags.get("junction") in ("roundabout", "circular"):
        direction = 1
    else:
        direction = 0

    speed = parse_maxspeed(tags.get("maxspeed")) or float(SPEED_KMH[hw])
    return speed, direction


_SPEED_RE = re.compile(r"^\s*(\d+(?:\.\d+)?)\s*(km/h|kmh|kph|mph)?\s*$")


def parse_maxspeed(value: str | None) -> float | None:
    if not value:
        return None
    m = _SPEED_RE.match(value.split(";")[0])
    if not m:
        return None  # e.g. "MY:urban", "signals", "none": use the class default
    speed = float(m.group(1)) * (1.609344 if m.group(2) == "mph" else 1.0)
    return speed if 5 <= speed <= 130 else None


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def md5_of(path: Path) -> str:
    h = hashlib.md5()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


# 1. Study-area polygon ------------------------------------------------------

def build_study_area(pbf: Path, simplify_deg: float):
    factory = osmium.geom.WKBFactory()
    parts, found, neighbour = [], {}, None
    fp = osmium.FileProcessor(pbf).with_areas(
        osmium.filter.TagFilter(("admin_level", "4"), ("admin_level", "2")))
    for obj in fp:
        if not obj.is_area() or obj.from_way():
            continue
        if (obj.tags.get("admin_level") == "2"
                and obj.tags.get("ISO3166-1") == EXCLUDED_NEIGHBOUR_ISO
                and obj.tags.get("boundary") == "administrative"):
            neighbour = wkb.loads(factory.create_multipolygon(obj), hex=True)
            found[EXCLUDED_NEIGHBOUR_ISO] = obj.orig_id()
            continue
        code = obj.tags.get("ISO3166-2")
        if code not in STUDY_AREA or obj.tags.get("boundary") != "administrative":
            continue
        geom = wkb.loads(factory.create_multipolygon(obj), hex=True)
        parts.append(geom)
        found[code] = obj.orig_id()
    missing = sorted(set(STUDY_AREA) - set(found)) + ([] if neighbour else [EXCLUDED_NEIGHBOUR_ISO])
    if missing:
        sys.exit(f"Study-area boundaries missing from the extract: {missing}")
    area = shapely.make_valid(unary_union(parts))
    band = (area.simplify(simplify_deg).buffer(BRIDGE_BAND_DEG)
            .difference(shapely.make_valid(neighbour))
            .difference(shapely.box(BBOX[0], THAI_BORDER_BAND_LAT, BBOX[2], BBOX[3]))
            .intersection(shapely.box(*BBOX)))
    road_area = shapely.make_valid(area.union(band))
    simplified = shapely.make_valid(area.simplify(simplify_deg, preserve_topology=True))
    polys = [g for g in getattr(simplified, "geoms", [simplified]) if isinstance(g, Polygon)]
    if isinstance(simplified, MultiPolygon):
        polys = list(simplified.geoms)
    coverage = MultiPolygon(polys)
    if not coverage.is_valid or coverage.is_empty:
        sys.exit("Study-area polygon is invalid after simplification.")
    return road_area, coverage, found


# 2. Drivable ways -----------------------------------------------------------

def read_drivable_ways(pbf: Path, excluded=frozenset()):
    ids, lats, lons = array("q"), array("d"), array("d")
    offsets, speeds, dirs = array("q", [0]), array("f"), array("b")
    min_lon, min_lat, max_lon, max_lat = BBOX
    fp = (osmium.FileProcessor(pbf, osmium.osm.NODE | osmium.osm.WAY)
          .with_locations()
          .with_filter(osmium.filter.EntityFilter(osmium.osm.WAY))
          .with_filter(osmium.filter.KeyFilter("highway")))
    kept = 0
    for way in fp:
        profile = drivable_profile(way.tags, excluded)
        if profile is None:
            continue
        refs = []
        in_box = False
        for n in way.nodes:
            loc = n.location
            if not loc.valid():
                refs.append((n.ref, math.nan, math.nan))
                continue
            refs.append((n.ref, loc.lat, loc.lon))
            if min_lon <= loc.lon <= max_lon and min_lat <= loc.lat <= max_lat:
                in_box = True
        if not in_box or len(refs) < 2:
            continue
        for ref, lat, lon in refs:
            ids.append(ref)
            lats.append(lat)
            lons.append(lon)
        offsets.append(len(ids))
        speeds.append(profile[0])
        dirs.append(profile[1])
        kept += 1
    return (np.frombuffer(ids, dtype=np.int64), np.frombuffer(lats, dtype=np.float64),
            np.frombuffer(lons, dtype=np.float64), np.frombuffer(offsets, dtype=np.int64),
            np.frombuffer(speeds, dtype=np.float32), np.frombuffer(dirs, dtype=np.int8), kept)


def haversine_km(lat1, lon1, lat2, lon2):
    r = 6371.0088
    p1, p2 = np.radians(lat1), np.radians(lat2)
    dphi, dlmb = p2 - p1, np.radians(lon2 - lon1)
    a = np.sin(dphi / 2) ** 2 + np.cos(p1) * np.cos(p2) * np.sin(dlmb / 2) ** 2
    return 2 * r * np.arcsin(np.sqrt(a))


# 3. Contraction -------------------------------------------------------------

def segments(ids, lats, lons, offsets, speeds, dirs, inside):
    """Directed arcs between consecutive in-area nodes of every drivable way."""
    way_of = np.repeat(np.arange(len(speeds)), np.diff(offsets))
    i = np.arange(1, len(ids))
    ok = (way_of[i] == way_of[i - 1]) & inside[i] & inside[i - 1] & (ids[i] != ids[i - 1])
    i = i[ok]
    a, b = ids[i - 1], ids[i]
    km = haversine_km(lats[i - 1], lons[i - 1], lats[i], lons[i])
    minutes = km / speeds[way_of[i]].astype(np.float64) * 60.0
    d = dirs[way_of[i]]
    fwd, rev = d >= 0, d <= 0
    src = np.concatenate([a[fwd], b[rev]])
    dst = np.concatenate([b[fwd], a[rev]])
    return src, dst, np.concatenate([km[fwd], km[rev]]), np.concatenate([minutes[fwd], minutes[rev]])


def dedupe_shortest(src, dst, km, minutes):
    """One arc per (source, target): parallel ways keep the shortest."""
    order = np.lexsort((km, dst, src))
    src, dst, km, minutes = src[order], dst[order], km[order], minutes[order]
    first = np.ones(len(src), dtype=bool)
    first[1:] = (src[1:] != src[:-1]) | (dst[1:] != dst[:-1])
    return src[first], dst[first], km[first], minutes[first]


def csr(rows, cols, n, *values):
    order = np.argsort(rows, kind="stable")
    ptr = np.zeros(n + 1, dtype=np.int64)
    np.cumsum(np.bincount(rows, minlength=n), out=ptr[1:])
    return (ptr.tolist(), cols[order].tolist(), *(v[order].tolist() for v in values))


def contract(src, dst, km, minutes, max_spacing_m):
    """Contract the full OSM arc graph to junctions, dead ends, one-way changes and
    spacing points. Path lengths and travel times between kept nodes are exact sums
    of the original segments, so shortest paths are unchanged."""
    src, dst, km, minutes = dedupe_shortest(src, dst, km, minutes)
    nodes, idx = np.unique(np.concatenate([src, dst]), return_inverse=True)
    n = len(nodes)
    s, t = idx[: len(src)], idx[len(src):]

    # Undirected neighbour structure (distinct neighbours) and directed degrees.
    lo, hi = np.minimum(s, t), np.maximum(s, t)
    pair, first = np.unique(lo * n + hi, return_index=True)
    u_a, u_b, u_km = pair // n, pair % n, km[first]  # either direction's length
    udeg = np.bincount(np.concatenate([u_a, u_b]), minlength=n)
    indeg = np.bincount(t, minlength=n)
    outdeg = np.bincount(s, minlength=n)
    # A node can be dropped only if it is a plain pass-through point: two distinct
    # neighbours and either two-way on both sides or a consistent one-way chain.
    simple = (udeg == 2) & (indeg == outdeg) & ((indeg == 1) | (indeg == 2))
    kept = (~simple).tolist()

    un_ptr, un_idx, un_km = csr(np.concatenate([u_a, u_b]), np.concatenate([u_b, u_a]), n,
                                np.concatenate([u_km, u_km]))
    spacing_km = max_spacing_m / 1000.0
    visited = [False] * n

    def place_spacing(start, k0):
        prev, cur, acc = start, un_idx[k0], un_km[k0]
        while not kept[cur] and not visited[cur]:
            visited[cur] = True
            if acc >= spacing_km:
                kept[cur] = True
                acc = 0.0
            j = un_ptr[cur]
            if un_idx[j] == prev:
                j += 1
            acc += un_km[j]
            prev, cur = cur, un_idx[j]

    for v in np.flatnonzero(~simple).tolist():
        for k in range(un_ptr[v], un_ptr[v + 1]):
            w = un_idx[k]
            if not kept[w] and not visited[w]:
                place_spacing(v, k)
    for v in range(n):  # closed loops made only of pass-through points
        if not kept[v] and not visited[v]:
            kept[v] = True
            visited[v] = True
            for k in range(un_ptr[v], un_ptr[v + 1]):
                w = un_idx[k]
                if not kept[w] and not visited[w]:
                    place_spacing(v, k)

    # Walk directed arcs from every kept node to the next kept node.
    out_ptr, out_idx, out_km, out_min = csr(s, t, n, km, minutes)
    e_src, e_dst, e_km, e_min = array("q"), array("q"), array("d"), array("d")
    for v in range(n):
        if not kept[v]:
            continue
        for k in range(out_ptr[v], out_ptr[v + 1]):
            prev, cur, acc_km, acc_min = v, out_idx[k], out_km[k], out_min[k]
            while not kept[cur]:
                step = -1
                for j in range(out_ptr[cur], out_ptr[cur + 1]):
                    if out_idx[j] != prev:
                        step = j
                        break
                if step < 0:
                    break  # cannot happen for a pass-through node; stop safely
                acc_km += out_km[step]
                acc_min += out_min[step]
                prev, cur = cur, out_idx[step]
            if kept[cur] and cur != v:
                e_src.append(v)
                e_dst.append(cur)
                e_km.append(acc_km)
                e_min.append(acc_min)

    kept_arr = np.array(kept)
    e_src = nodes[np.frombuffer(e_src, dtype=np.int64)]
    e_dst = nodes[np.frombuffer(e_dst, dtype=np.int64)]
    stats = {"osm_nodes": int(n), "kept_before_connectivity": int(kept_arr.sum()),
             "max_spacing_m": max_spacing_m}
    return (*dedupe_shortest(e_src, e_dst, np.frombuffer(e_km), np.frombuffer(e_min)), stats)


# 4. Connectivity ------------------------------------------------------------

def largest_strong_component(src, dst):
    nodes, idx = np.unique(np.concatenate([src, dst]), return_inverse=True)
    s_idx, d_idx = idx[: len(src)], idx[len(src):]
    graph = csr_matrix((np.ones(len(src), dtype=np.int8), (s_idx, d_idx)),
                       shape=(len(nodes), len(nodes)))
    n_strong, labels = connected_components(graph, directed=True, connection="strong")
    n_weak, _ = connected_components(graph, directed=True, connection="weak")
    sizes = np.bincount(labels)
    main = int(np.argmax(sizes))
    keep_node = labels == main
    keep_edge = keep_node[s_idx] & keep_node[d_idx]
    # Re-verify on the kept subgraph: it must be exactly one strong component.
    k_nodes = nodes[keep_node]
    _, k_idx = np.unique(np.concatenate([src[keep_edge], dst[keep_edge]]), return_inverse=True)
    n_kept = len(k_nodes)
    sub = csr_matrix((np.ones(int(keep_edge.sum()), dtype=np.int8),
                      (k_idx[: keep_edge.sum()], k_idx[keep_edge.sum():])),
                     shape=(n_kept, n_kept))
    check, _ = connected_components(sub, directed=True, connection="strong")
    if check != 1:
        sys.exit(f"Connectivity check failed: kept graph has {check} strong components.")
    stats = {
        "nodes_before": int(len(nodes)), "strong_components_before": int(n_strong),
        "weak_components_before": int(n_weak), "largest_component_nodes": int(sizes[main]),
        "nodes_dropped_not_connected": int(len(nodes) - sizes[main]),
        "second_largest_component_nodes": int(np.sort(sizes)[-2]) if n_strong > 1 else 0,
        "kept_graph_strong_components": int(check),
    }
    return k_nodes, keep_edge, stats


def verify_shortest_paths(full, reduced, nodes, samples=25, limit_km=25.0, seed=20261020):
    """Dijkstra from sampled kept nodes on the full OSM graph and on the contracted
    graph: distances to every kept node must match (contraction loses no path)."""
    from scipy.sparse.csgraph import dijkstra
    f_src, f_dst, f_km, _ = dedupe_shortest(*full, np.zeros(len(full[0])))
    r_src, r_dst, r_km = reduced
    f_km, r_km = np.maximum(f_km, 1e-6), np.maximum(r_km, 1e-6)  # keep zero-length arcs
    ids, inv = np.unique(np.concatenate([f_src, f_dst]), return_inverse=True)
    n = len(ids)
    f_graph = csr_matrix((f_km, (inv[: len(f_src)], inv[len(f_src):])), shape=(n, n))
    r_s, r_t = np.searchsorted(ids, r_src), np.searchsorted(ids, r_dst)
    r_graph = csr_matrix((r_km, (r_s, r_t)), shape=(n, n))
    kept = np.searchsorted(ids, nodes)
    rng = np.random.default_rng(seed)
    sources = rng.choice(kept, size=min(samples, len(kept)), replace=False)
    d_full = dijkstra(f_graph, directed=True, indices=sources, limit=limit_km)[:, kept]
    d_red = dijkstra(r_graph, directed=True, indices=sources, limit=limit_km)[:, kept]
    both = np.isfinite(d_full) & np.isfinite(d_red)
    reach_mismatch = int((np.isfinite(d_full) != np.isfinite(d_red)).sum())
    max_diff_m = float(np.abs(d_full[both] - d_red[both]).max() * 1000) if both.any() else 0.0
    return {"sources": int(len(sources)), "pairs_compared": int(both.sum()),
            "limit_km": limit_km, "reachability_mismatches": reach_mismatch,
            "max_distance_difference_m": round(max_diff_m, 3)}


# 5. Main --------------------------------------------------------------------

def main() -> None:
    here = Path(__file__).resolve().parent
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--pbf", type=Path, required=True, help="Geofabrik .osm.pbf extract")
    ap.add_argument("--snapshot-id", help="default: OSM-OPS-<extract date>")
    ap.add_argument("--out", type=Path, default=here / "output")
    ap.add_argument("--max-spacing-m", type=float, default=350.0,
                    help="keep a node at least this often along a road chain")
    ap.add_argument("--simplify-deg", type=float, default=0.0005,
                    help="study-area polygon simplification (~55 m)")
    ap.add_argument("--exclude-highway", nargs="*", default=["service"], choices=sorted(SPEED_KMH),
                    help="drivable classes left out to fit the database plan (default: service; "
                         "pass the flag with no value to keep every class)")
    ap.add_argument("--zip", action="store_true", help="also write a zip of the outputs")
    args = ap.parse_args()

    pbf = args.pbf.resolve()
    for forbidden in ("benchmark dataset", "baseline implementation", "experiments"):
        if forbidden in str(pbf).replace("\\", "/"):
            sys.exit(f"Refusing input inside '{forbidden}': operational data must be separate.")
    started = time.time()
    header = osmium.io.Reader(str(pbf), osmium.osm.NOTHING)
    osm_timestamp = header.header().get("osmosis_replication_timestamp", "")
    header.close()
    extract_date = (osm_timestamp[:10].replace("-", "") if osm_timestamp
                    else datetime.now(timezone.utc).strftime("%Y%m%d"))
    snapshot = args.snapshot_id or f"OSM-OPS-{extract_date}"
    if not snapshot.startswith("OSM-OPS-"):
        sys.exit("Snapshot id must start with OSM-OPS- (migration constraint).")
    args.out.mkdir(parents=True, exist_ok=True)

    log(f"Study area from {pbf.name}")
    area, coverage, relations = build_study_area(pbf, args.simplify_deg)
    log(f"  {len(relations) - 1} state boundaries (+ {EXCLUDED_NEIGHBOUR_ISO} excluded), "
        f"{shapely.get_num_coordinates(coverage)} coverage vertices")

    log("Reading drivable ways (with node locations)")
    excluded = frozenset(args.exclude_highway)
    ids, lats, lons, offsets, speeds, dirs, n_ways = read_drivable_ways(pbf, excluded)
    log(f"  {n_ways} ways, {len(ids)} node references")

    log("Clipping to the study area")
    valid = ~np.isnan(lats)
    shapely.prepare(area)
    uniq, inv = np.unique(ids, return_inverse=True)
    first_pos = np.zeros(len(uniq), dtype=np.int64)
    first_pos[inv[::-1]] = np.arange(len(ids))[::-1]
    u_inside = np.zeros(len(uniq), dtype=bool)
    u_valid = valid[first_pos]
    u_inside[u_valid] = shapely.contains_xy(area, lons[first_pos][u_valid], lats[first_pos][u_valid])
    inside = u_inside[inv] & valid
    log(f"  {int(u_inside.sum())} of {len(uniq)} distinct nodes inside")

    log(f"Contracting chains (keep a node at least every {args.max_spacing_m:.0f} m)")
    full = segments(ids, lats, lons, offsets, speeds, dirs, inside)
    log(f"  {len(full[0])} directed OSM segments")
    src, dst, km, minutes, contraction = contract(*full, args.max_spacing_m)
    log(f"  {contraction['osm_nodes']} OSM nodes -> {contraction['kept_before_connectivity']} kept, "
        f"{len(src)} directed edges")

    log("Connectivity: keeping the largest strongly connected component")
    nodes, keep_edge, conn = largest_strong_component(src, dst)
    src, dst, km, minutes = src[keep_edge], dst[keep_edge], km[keep_edge], minutes[keep_edge]
    log(f"  {conn['largest_component_nodes']} nodes kept, "
        f"{conn['nodes_dropped_not_connected']} dropped, {len(src)} edges")

    log("Verifying contracted shortest paths against the full OSM graph")
    path_check = verify_shortest_paths(full[:3], (src, dst, km), nodes)
    log(f"  {path_check}")
    if path_check["reachability_mismatches"] or path_check["max_distance_difference_m"] > 1.0:
        sys.exit("Contraction changed shortest paths; refusing to write outputs.")
    conn["shortest_path_check"] = path_check
    del full

    # Coordinates of kept nodes.
    pos = first_pos[np.searchsorted(uniq, nodes)]
    n_lat, n_lon = lats[pos], lons[pos]
    if (nodes <= 0).any():
        sys.exit("Non-positive OSM node id found.")
    km = np.maximum(np.round(km, 5), 0.00001)          # road_km > 0 check
    minutes = np.maximum(np.round(minutes, 4), 0.0001)  # travel_minutes > 0 check

    nodes_csv = args.out / "road_network_nodes.csv"
    edges_csv = args.out / "road_network_edges.csv"
    coverage_sql = args.out / "operational_road_coverage.sql"
    activate_sql = args.out / "activate_snapshot.sql"
    manifest_path = args.out / "manifest.json"

    log("Writing outputs")
    with nodes_csv.open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["osm_node_id", "network_snapshot_id", "latitude", "longitude",
                    "component_id", "active_flag"])
        for nid, la, lo in zip(nodes.tolist(), n_lat.tolist(), n_lon.tolist()):
            w.writerow([nid, snapshot, f"{la:.7f}", f"{lo:.7f}", 0, "true"])
    with edges_csv.open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["source_node", "target_node", "road_km", "travel_minutes"])
        for row in zip(src.tolist(), dst.tolist(), km.tolist(), minutes.tolist()):
            w.writerow(row)

    pbf_md5, pbf_sha = md5_of(pbf), sha256_of(pbf)
    builder_sha = sha256_of(Path(__file__).resolve())
    provenance = (f"OPERATIONAL; OpenStreetMap via Geofabrik {pbf.name}; md5={pbf_md5}; "
                  f"osm_timestamp={osm_timestamp}; licence=ODbL-1.0; "
                  f"builder=build_operational_road_network.py sha256={builder_sha[:16]}")
    wkt = shapely.to_wkt(coverage, rounding_precision=6)
    coverage_sql.write_text(
        "-- Generated by supabase/road_network/build_operational_road_network.py\n"
        "-- Registers the snapshot (not approved, not active). Run before importing nodes/edges.\n"
        "begin;\n"
        "insert into public.road_network_coverage\n"
        "  (network_snapshot_id, coverage_area, max_snap_distance_m, provenance,\n"
        "   dataset_kind, node_count, edge_count)\n"
        f"values ('{snapshot}',\n"
        f"  extensions.ST_Multi(extensions.ST_GeomFromText('{wkt}', 4326)),\n"
        f"  {MAX_SNAP_DISTANCE_M}, '{provenance}', 'OPERATIONAL', {len(nodes)}, {len(src)})\n"
        "on conflict (network_snapshot_id) do nothing;\n"
        "commit;\n", encoding="utf-8")
    activate_sql.write_text(
        "-- Approve and activate the imported snapshot, then re-resolve open records.\n"
        "-- Stops (and changes nothing) if the imported counts differ from manifest.json.\n"
        "begin;\n"
        "do $$\n"
        "declare v_nodes bigint; v_edges bigint;\n"
        "begin\n"
        f"  select count(*) into v_nodes from public.road_network_nodes where network_snapshot_id = '{snapshot}';\n"
        "  select count(*) into v_edges from public.road_network_edges e\n"
        "    join public.road_network_nodes n on n.osm_node_id = e.source_node\n"
        f"   where n.network_snapshot_id = '{snapshot}';\n"
        f"  if v_nodes <> {len(nodes)} or v_edges <> {len(src)} then\n"
        f"    raise exception 'SNAPSHOT_COUNT_MISMATCH: nodes % of {len(nodes)}, edges % of {len(src)}', v_nodes, v_edges;\n"
        "  end if;\n"
        "end $$;\n"
        "update public.road_network_coverage set active_flag = false\n"
        f" where active_flag and network_snapshot_id <> '{snapshot}';\n"
        "update public.road_network_coverage\n"
        "   set approved_at = coalesce(approved_at, clock_timestamp()), active_flag = true\n"
        f" where network_snapshot_id = '{snapshot}';\n"
        "commit;\n"
        "select public.geolock_backfill_road_nodes();\n", encoding="utf-8")

    manifest = {
        "network_snapshot_id": snapshot,
        "dataset_kind": "OPERATIONAL",
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "source": {"provider": "Geofabrik", "file": pbf.name, "md5": pbf_md5,
                   "sha256": pbf_sha, "osm_replication_timestamp": osm_timestamp,
                   "licence": "ODbL 1.0, (c) OpenStreetMap contributors"},
        "study_area": {"iso3166": relations, "names": STUDY_AREA,
                       "roads_clipped_to": f"states + {BRIDGE_BAND_DEG} deg coastal band, minus "
                                           f"{EXCLUDED_NEIGHBOUR_ISO} and lat > {THAI_BORDER_BAND_LAT}",
                       "simplify_deg": args.simplify_deg,
                       "vertices": int(shapely.get_num_coordinates(coverage))},
        "graph_filter": {"highway_speed_kmh": {k: v for k, v in SPEED_KMH.items()
                                               if k not in excluded},
                         "excluded_highway": sorted(excluded),
                         "excluded_service": sorted(EXCLUDED_SERVICE),
                         "excluded_access": sorted(NO_ACCESS),
                         "oneway": "yes/1/true forward, -1 reverse, reversible excluded, "
                                   "motorway and roundabout implied one-way",
                         "maxspeed": "numeric km/h or mph within 5-130 km/h, else class default"},
        "contraction": {**contraction,
                        "kept": "junctions, dead ends, one-way changes, study-area exits "
                                "and a node at least every max_spacing_m along a chain"},
        "snap_rule": {"max_snap_distance_m": MAX_SNAP_DISTANCE_M,
                      "report_section": "3.3.5.1"},
        "connectivity": conn,
        "counts": {"ways": int(n_ways), "nodes": int(len(nodes)), "edges": int(len(src))},
        "files": {p.name: sha256_of(p) for p in (nodes_csv, edges_csv, coverage_sql)},
        "builder": {"sha256": builder_sha, "python": platform.python_version(),
                    "numpy": np.__version__, "shapely": shapely.__version__},
        "elapsed_s": round(time.time() - started, 1),
    }
    manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")

    if args.zip:
        zpath = args.out / f"geolock_road_network_data_{snapshot}.zip"
        with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED) as z:
            for p in (nodes_csv, edges_csv, coverage_sql, activate_sql, manifest_path):
                z.write(p, p.name)
        log(f"  {zpath.name}")
    log(f"Done: {snapshot}, {len(nodes)} nodes, {len(src)} edges, "
        f"{manifest['elapsed_s']} s")


if __name__ == "__main__":
    main()
