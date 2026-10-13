#!/usr/bin/env python3
"""Offline, standard-library OSM PBF -> directed drivable road node/edge CSV.

Uses the exact uploaded NGO coordinates to select regional road extracts.
Requires Python 3.10+ and the original Malaysia/Singapore/Brunei .osm.pbf snapshot.
The regional extraction windows follow EVERY NGO in the supplied CSV.
An edge row is: origin_osm_id,destination_osm_id,road_km,travel_minutes.
A node row is: osm_id,latitude,longitude. Neither has a header (compatible with generator).
"""
import argparse
import hashlib
import csv
import math
import re
import struct
import sys
import time
import zlib
from pathlib import Path

# Operational processing windows centred on EVERY supplied NGO, not KL/Johor only.
# Crop radii are extraction guards, not geofences and not official boundaries.
BOXES = []
def set_boxes(ngo_csv, radius_km=35.0):
    global BOXES
    with open(ngo_csv, encoding='utf-8-sig', newline='') as f:
        ngos = list(csv.DictReader(f))
    if not ngos: raise ValueError('NGO CSV contains no records')
    boxes = []
    for r in ngos:
        lat, lon = float(r['latitude']), float(r['longitude'])
        delta_lat = (radius_km + 3)/111.2
        delta_lon = (radius_km + 3)/(111.2*max(.5,math.cos(math.radians(lat))))
        boxes.append((lat-delta_lat, lat+delta_lat, lon-delta_lon, lon+delta_lon))
    BOXES = boxes
    return ngos
SPEEDS = {'motorway':100,'motorway_link':55,'trunk':90,'trunk_link':50,
          'primary':75,'primary_link':45,'secondary':60,'secondary_link':40,
          'tertiary':50,'tertiary_link':35,'residential':35,'unclassified':40,
          'service':20,'living_street':15}
MAXSPEED_RE = re.compile(r'[0-9]{2,3}')


def unsigned(buf, pos):
    value = 0
    shift = 0
    while pos < len(buf):
        octet = buf[pos]
        pos += 1
        value |= (octet & 127) << shift
        if octet < 128:
            return value, pos
        shift += 7
        if shift >= 70:
            raise ValueError('Invalid PBF varint')
    raise ValueError('Unexpected end of PBF varint')


def fields(buf):
    pos = 0
    total = len(buf)
    while pos < total:
        key, pos = unsigned(buf, pos)
        tag, wire = key >> 3, key & 7
        if wire == 0:
            val, pos = unsigned(buf, pos)
        elif wire == 2:
            size, pos = unsigned(buf, pos)
            val = buf[pos:pos+size]
            if len(val) != size:
                raise ValueError('Truncated PBF length-delimited field')
            pos += size
        elif wire == 1:
            val = None
            pos += 8
        elif wire == 5:
            val = None
            pos += 4
        else:
            raise ValueError(f'Unexpected protobuf wire type {wire}')
        yield tag, val


def signed(value):
    return (value >> 1) ^ -(value & 1)


def delta_values(packed):
    pos = 0
    acc = 0
    n = len(packed)
    while pos < n:
        raw, pos = unsigned(packed, pos)
        acc += signed(raw)
        yield acc


def unsigned_values(packed):
    pos = 0
    while pos < len(packed):
        n, pos = unsigned(packed, pos)
        yield n


def parse_blob_stream(file):
    """Yield decompressed OSMData blocks from an OSM PBF without external libraries."""
    with open(file, 'rb') as src:
        while True:
            prefix = src.read(4)
            if not prefix:
                return
            if len(prefix) != 4:
                raise ValueError('Truncated PBF blob header length')
            length = struct.unpack('>I', prefix)[0]
            if not 0 < length <= 1048576:
                raise ValueError('Invalid PBF blob header length')
            header = src.read(length)
            if len(header) != length:
                raise ValueError('Truncated PBF header')
            typ, compressed_size = '', None
            for tag, value in fields(header):
                if tag == 1:
                    typ = value.decode('utf8')
                elif tag == 3:
                    compressed_size = value
            if compressed_size is None or compressed_size > 64*1024*1024:
                raise ValueError('Invalid compressed PBF blob size')
            blob = src.read(compressed_size)
            if len(blob) != compressed_size:
                raise ValueError('Truncated PBF data block')
            if typ != 'OSMData':
                continue
            raw = None
            zdata = None
            raw_size = None
            for tag, value in fields(blob):
                if tag == 1:
                    raw = value
                elif tag == 2:
                    raw_size = value
                elif tag == 3:
                    zdata = value
            if zdata is not None:
                content = zlib.decompress(zdata)
                if raw_size is not None and len(content) != raw_size:
                    raise ValueError('PBF compressed block decompression length mismatch')
                yield content
            elif raw is not None:
                yield raw
            else:
                raise ValueError('Unsupported OSM PBF blob encoding: not raw or zlib')


def primitive_group_info(block):
    groups = []
    granularity, offlat, offlon = 100, 0, 0
    table = b''
    for tag, value in fields(block):
        if tag == 1:
            table = value
        elif tag == 2:
            groups.append(value)
        elif tag == 17:
            granularity = value
        elif tag == 19:
            offlat = value if value < 2**63 else value - 2**64
        elif tag == 20:
            offlon = value if value < 2**63 else value - 2**64
    return groups, table, granularity, offlat, offlon


def within(lat, lon):
    return any(s <= lat <= n and w <= lon <= e for s, n, w, e in BOXES)


def read_nodes(block, coords, hub_candidates):
    groups, table, gran, lat_off, lon_off = primitive_group_info(block)
    strings = [x for t,x in fields(table) if t == 1]
    for g in groups:
        for typ, record in fields(g):
            if typ == 2:  # DenseNodes
                ids = lats = lons = packed_tags = None
                for tag, value in fields(record):
                    if tag == 1: ids = value
                    elif tag == 8: lats = value
                    elif tag == 9: lons = value
                    elif tag == 10: packed_tags = value
                if ids is None or lats is None or lons is None: continue
                kv = iter(unsigned_values(packed_tags or b''))
                for nid, lat, lon in zip(delta_values(ids), delta_values(lats), delta_values(lons)):
                    y = (lat_off + gran * lat) * 1e-9
                    x = (lon_off + gran * lon) * 1e-9
                    tags = {}
                    # Dense node tag records are terminated by a zero key index.
                    for ki in kv:
                        if ki == 0: break
                        vi = next(kv)
                        if ki < len(strings) and vi < len(strings):
                            key = strings[ki]
                            if key in (b'amenity', b'name'):
                                tags[key] = strings[vi]
                    if within(y,x):
                        coords[nid] = (y,x)
                        amenity=tags.get(b'amenity',b'').decode('utf8','replace')
                        if amenity in ('community_centre','townhall'):
                            hub_candidates[('node',nid)] = ('node',nid,amenity,tags.get(b'name',b'').decode('utf8','replace'),y,x)
            elif typ == 1:  # Node
                nid, lat, lon = None, None, None
                keys=[];vals=[]
                for tag, value in fields(record):
                    if tag == 1: nid = value
                    elif tag == 8: lat = signed(value)
                    elif tag == 9: lon = signed(value)
                    elif tag == 2: keys.extend(unsigned_values(value) if isinstance(value,bytes) else [value])
                    elif tag == 3: vals.extend(unsigned_values(value) if isinstance(value,bytes) else [value])
                if nid is not None and lat is not None and lon is not None:
                    y = (lat_off + gran*lat)*1e-9
                    x = (lon_off + gran*lon)*1e-9
                    if within(y,x):
                        coords[nid] = (y,x)
                        tags={strings[k]:strings[v] for k,v in zip(keys,vals) if k<len(strings) and v<len(strings)}
                        amenity=tags.get(b'amenity',b'').decode('utf8','replace')
                        if amenity in ('community_centre','townhall'):
                            hub_candidates[('node',nid)]=('node',nid,amenity,tags.get(b'name',b'').decode('utf8','replace'),y,x)


def read_way(record, strings, coords, outfile):
    keys = vals = refs = None
    for tag,value in fields(record):
        if tag == 2:
            keys = value
        elif tag == 3:
            vals = value
        elif tag == 8:
            refs = value
    if refs is None or keys is None or vals is None:
        return 0
    tags = {}
    for ki,vi in zip(unsigned_values(keys),unsigned_values(vals)):
        if ki < len(strings) and vi < len(strings):
            k = strings[ki]
            if k in (b'highway',b'access',b'motor_vehicle',b'motorcar',b'service',b'maxspeed',b'oneway',b'junction'):
                tags[k] = strings[vi]
    highway = tags.get(b'highway',b'').decode('utf8',errors='replace')
    speed = SPEEDS.get(highway,0)
    if not speed or tags.get(b'access') == b'no' or tags.get(b'motor_vehicle') == b'no' or tags.get(b'motorcar') == b'no' or tags.get(b'service') == b'parking_aisle':
        return 0
    maxspeed = tags.get(b'maxspeed',b'').decode('utf8',errors='replace')
    match = MAXSPEED_RE.search(maxspeed)
    if match:
        proposed = int(match.group()) * (1.60934 if 'mph' in maxspeed else 1.0)
        speed = min(110.0,max(8.0,proposed))
    oneway = tags.get(b'oneway',b'')
    backward = oneway in (b'-1',b'reverse')
    one_direction = (oneway in (b'yes',b'1',b'true',b'-1',b'reverse') or
                     tags.get(b'junction') == b'roundabout' or highway in ('motorway','motorway_link'))
    count = 0
    last = None
    for node in delta_values(refs):
        if last is not None:
            p,q = coords.get(last),coords.get(node)
            if p is not None and q is not None:
                y = (p[0]+q[0])*0.5
                dy = (q[0]-p[0])*111.1949
                dx = (q[1]-p[1])*111.1949*math.cos(math.radians(y))
                km = math.hypot(dx,dy)
                if .0003 < km < 5.0:
                    minute = 60.0*km/speed
                    if not backward:
                        outfile.write(f'{last},{node},{km:.8g},{minute:.8g}\n')
                        count += 1
                    if not one_direction or backward:
                        outfile.write(f'{node},{last},{km:.8g},{minute:.8g}\n')
                        count += 1
        last = node
    return count


def read_ways(block, coords, output, hub_candidates):
    groups, table, *_ = primitive_group_info(block)
    strings = [item for tag,item in fields(table) if tag == 1]
    count = 0
    for g in groups:
        for tag, record in fields(g):
            if tag == 3:
                count += read_way(record, strings, coords, output)
                tags={}; way_id=None; refs=None;keys=[];vals=[]
                for t,v in fields(record):
                    if t==1: way_id=v
                    elif t==2: keys.extend(unsigned_values(v) if isinstance(v,bytes) else [v])
                    elif t==3: vals.extend(unsigned_values(v) if isinstance(v,bytes) else [v])
                    elif t==8: refs=v
                for k,v in zip(keys,vals):
                    if k<len(strings) and v<len(strings) and strings[k] in (b'amenity',b'name'):
                        tags[strings[k]]=strings[v]
                amenity=tags.get(b'amenity',b'').decode('utf8','replace')
                if amenity in ('community_centre','townhall') and refs is not None and way_id is not None:
                    points=[coords[n] for n in delta_values(refs) if n in coords]
                    if points:
                        lat=sum(v[0] for v in points)/len(points)
                        lon=sum(v[1] for v in points)/len(points)
                        hub_candidates[('way',way_id)]=('way',way_id,amenity,tags.get(b'name',b'').decode('utf8','replace'),lat,lon)
    return count


def extract(pbf, nodes, edges, hubs, ngos, radius_km):
    ngo_rows = set_boxes(ngos, radius_km)
    print(f"OSM regions: {len(ngo_rows)} NGO references, {len(BOXES)} extraction windows, {radius_km}km + 3km buffer", flush=True)
    started = time.monotonic()
    coords = {}
    hub_candidates = {}
    print('Python OSM pass 1/2: extracting in-bounds coordinates', flush=True)
    count = 0
    for count,blob in enumerate(parse_blob_stream(pbf),1):
        read_nodes(blob,coords,hub_candidates)
        if count % 500 == 0:
            print(f'  scanned {count} blocks, {len(coords):,} coordinates',flush=True)
    if not coords:
        raise RuntimeError('No OSM nodes found in declared geographic boxes')
    nodes.parent.mkdir(parents=True,exist_ok=True)
    with open(nodes,'w',encoding='utf8') as out:
        for nid,(lat,lon) in coords.items():
            out.write(f'{nid},{lat:.10g},{lon:.10g}\n')
    print(f'Python OSM pass 2/2: extracting edges from {len(coords):,} coordinates',flush=True)
    count = 0
    edge_count = 0
    with open(edges,'w',encoding='utf8') as output:
        for count,blob in enumerate(parse_blob_stream(pbf),1):
            edge_count += read_ways(blob,coords,output,hub_candidates)
            if count % 500 == 0:
                print(f'  scanned {count} blocks, {edge_count:,} directed edges',flush=True)
    if not edge_count:
        raise RuntimeError('No drivable road edges found in selected geographic boxes')
    hubs.parent.mkdir(parents=True, exist_ok=True)
    with hubs.open('w',newline='',encoding='utf8') as f:
        w=csv.writer(f);w.writerow(['osm_type','osm_id','amenity','name','latitude','longitude'])
        w.writerows(sorted(hub_candidates.values(),key=lambda r:(r[0],r[1])))
    print(f'OSM mapped amenity candidates: {len(hub_candidates):,}',flush=True)
    print(f'Python OSM extraction: {len(coords):,} coordinates, {edge_count:,} directed edges; {time.monotonic()-started:.1f} seconds', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('pbf',type=Path)
    parser.add_argument('nodes_csv',type=Path)
    parser.add_argument('edges_csv',type=Path)
    parser.add_argument('hubs_csv',type=Path)
    parser.add_argument('--ngos',type=Path,required=True,help='Updated NGO_references.csv')
    parser.add_argument('--radius-km',type=float,default=17.0)
    args = parser.parse_args()
    extract(args.pbf,args.nodes_csv,args.edges_csv,args.hubs_csv,args.ngos,args.radius_km)
