#!/usr/bin/env python3
"""Study boundary of the benchmark (report Section 3.3.1) from the OSM PBF.

Writes two WKT files next to the road cache, using the same rule as the live app's
road network (supabase/road_network/build_operational_road_network.py), so that the
benchmark and the app share one geographic definition:

  study_boundary.wkt  locations: the 11 Peninsular Malaysia states plus the Federal
                      Territories of Kuala Lumpur and Putrajaya (OSM admin_level 4
                      boundaries, simplified ~55 m). Donor, hub and NGO points must
                      lie inside it.
  road_area.wkt       roads: the same states plus a 0.05 deg coastal band (keeps the
                      Penang bridges), minus Singapore and minus the band along the
                      Thai border (north of 5.6 N).

Only the PBF is read; nothing from supabase/ is used. Needs osmium and shapely.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys

import osmium
import shapely
from shapely import wkb
from shapely.geometry import MultiPolygon, Polygon
from shapely.ops import unary_union

STUDY_AREA = {
    'MY-01': 'Johor', 'MY-02': 'Kedah', 'MY-03': 'Kelantan', 'MY-04': 'Melaka',
    'MY-05': 'Negeri Sembilan', 'MY-06': 'Pahang', 'MY-07': 'Pulau Pinang',
    'MY-08': 'Perak', 'MY-09': 'Perlis', 'MY-10': 'Selangor', 'MY-11': 'Terengganu',
    'MY-14': 'Kuala Lumpur', 'MY-16': 'Putrajaya',
}
BBOX = (99.4, 0.8, 104.9, 6.9)        # min lon, min lat, max lon, max lat
BRIDGE_BAND_DEG = 0.05
EXCLUDED_NEIGHBOUR_ISO = 'SG'
THAI_BORDER_BAND_LAT = 5.6


def build(pbf, simplify_deg):
    factory = osmium.geom.WKBFactory()
    parts, found, neighbour = [], {}, None
    fp = osmium.FileProcessor(str(pbf)).with_areas(
        osmium.filter.TagFilter(('admin_level', '4'), ('admin_level', '2')))
    for obj in fp:
        if not obj.is_area() or obj.from_way():
            continue
        if (obj.tags.get('admin_level') == '2' and obj.tags.get('ISO3166-1') == EXCLUDED_NEIGHBOUR_ISO
                and obj.tags.get('boundary') == 'administrative'):
            neighbour = wkb.loads(factory.create_multipolygon(obj), hex=True)
            found[EXCLUDED_NEIGHBOUR_ISO] = obj.orig_id()
            continue
        code = obj.tags.get('ISO3166-2')
        if code not in STUDY_AREA or obj.tags.get('boundary') != 'administrative':
            continue
        parts.append(wkb.loads(factory.create_multipolygon(obj), hex=True))
        found[code] = obj.orig_id()
    missing = sorted(set(STUDY_AREA) - set(found)) + ([] if neighbour else [EXCLUDED_NEIGHBOUR_ISO])
    if missing:
        sys.exit(f'Study-area boundaries missing from the extract: {missing}')
    area = shapely.make_valid(unary_union(parts))
    band = (area.simplify(simplify_deg).buffer(BRIDGE_BAND_DEG)
            .difference(shapely.make_valid(neighbour))
            .difference(shapely.box(BBOX[0], THAI_BORDER_BAND_LAT, BBOX[2], BBOX[3]))
            .intersection(shapely.box(*BBOX)))
    road_area = shapely.make_valid(area.union(band))
    simplified = shapely.make_valid(area.simplify(simplify_deg, preserve_topology=True))
    polys = list(simplified.geoms) if isinstance(simplified, MultiPolygon) else \
        [g for g in getattr(simplified, 'geoms', [simplified]) if isinstance(g, Polygon)]
    coverage = MultiPolygon(polys)
    if not coverage.is_valid or coverage.is_empty:
        sys.exit('Study-area polygon is invalid after simplification.')
    return coverage, road_area, found


def main():
    here = Path(__file__).resolve().parent
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--pbf', type=Path, default=here.parent.parent / 'public dataset' / 'malaysia-singapore-brunei.osm.pbf')
    ap.add_argument('--out', type=Path, default=here.parent / 'road cache')
    ap.add_argument('--simplify-deg', type=float, default=0.0005)
    args = ap.parse_args()
    coverage, road_area, found = build(args.pbf, args.simplify_deg)
    args.out.mkdir(parents=True, exist_ok=True)
    files = {}
    for name, geom in (('study_boundary.wkt', coverage), ('road_area.wkt', road_area)):
        path = args.out / name
        path.write_text(shapely.to_wkt(geom, rounding_precision=6) + '\n', encoding='utf-8')
        files[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    record = dict(source=args.pbf.name, osm_relations=found, names=STUDY_AREA,
                  simplify_deg=args.simplify_deg, coastal_band_deg=BRIDGE_BAND_DEG,
                  excluded=[EXCLUDED_NEIGHBOUR_ISO, f'band north of {THAI_BORDER_BAND_LAT} N'],
                  files=files)
    (args.out / 'study_boundary.json').write_text(json.dumps(record, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(record, indent=2))


if __name__ == '__main__':
    main()
