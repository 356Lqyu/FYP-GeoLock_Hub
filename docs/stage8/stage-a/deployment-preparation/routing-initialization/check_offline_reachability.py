"""Bounded, local-only directed reachability on hash-pinned import CSVs.

No database, solver, matrix, fixture or route writes. This proves CSV paths only;
database/import equivalence is a separate prerequisite. Hard budget: 60 seconds,
at most the pinned 926414 nodes/2145828 edges, three sources, two target searches
per source. No shortest-distance/time or whole-database SCC claim.
"""
import csv
import hashlib
import json
import time
from array import array
from pathlib import Path

ROOT = Path(__file__).resolve().parents[5]
OUT = ROOT/'supabase/road_network/output'
RESULT = ROOT/'results/routing-initialization-preparation/offline-reachability.json'
started = time.monotonic()
POINTS = ['1755847853','2308277456','5735535080']

def budget():
    if time.monotonic()-started > 60:
        raise TimeoutError('Offline 60-second budget exceeded; no PASS')

def run():
    manifest = json.loads((OUT/'manifest.json').read_text())
    hashes = {}
    for name in ('road_network_nodes.csv','road_network_edges.csv'):
        path = OUT/name
        assert path.stat().st_size < 150_000_000
        h = hashlib.sha256(path.read_bytes()).hexdigest()
        assert h == manifest['files'][name], name
        hashes[name] = h
    nodes = {}
    with (OUT/'road_network_nodes.csv').open(newline='') as f:
        for row in csv.DictReader(f):
            assert len(nodes) < 926414
            assert row['network_snapshot_id']=='OSM-OPS-20261018' and row['active_flag']=='true'
            assert row['osm_node_id'] not in nodes
            nodes[row['osm_node_id']] = len(nodes)
            if len(nodes)%65536 == 0: budget()
    assert len(nodes)==926414
    wanted = {nodes[p] for p in POINTS}
    degree = array('I',[0])*len(nodes)
    sources, targets = array('I'),array('I')
    max_scale = {'road_km':0,'travel_minutes':0}
    with (OUT/'road_network_edges.csv').open(newline='') as f:
        for row in csv.DictReader(f):
            assert len(sources)<2145828
            u,v = nodes[row['source_node']],nodes[row['target_node']]
            for key in max_scale:
                fraction=row[key].partition('.')[2].rstrip('0')
                max_scale[key]=max(max_scale[key],len(fraction))
            sources.append(u); targets.append(v); degree[u]+=1
            if len(sources)%65536 == 0: budget()
    assert len(sources)==2145828
    offsets=array('I',[0])
    for d in degree: offsets.append(offsets[-1]+d)
    cursor=array('I',offsets[:-1]); adjacency=array('I',[0])*len(sources)
    for i,(u,v) in enumerate(zip(sources,targets)):
        adjacency[cursor[u]]=v; cursor[u]+=1
        if i%65536 == 0: budget()
    pairs=[]
    for point in POINTS:
        source=nodes[point]; visited=bytearray(len(nodes)); visited[source]=1
        queue=array('I',[source]); head=0; remaining=wanted-{source}
        while head<len(queue) and remaining:
            u=queue[head]; head+=1
            for i in range(offsets[u],offsets[u+1]):
                v=adjacency[i]
                if not visited[v]:
                    visited[v]=1; queue.append(v); remaining.discard(v)
            if head%65536 == 0: budget()
        budget()
        for target in POINTS:
            pairs.append({'source_node':point,'target_node':target,
                          'reachable_in_pinned_csv':bool(visited[nodes[target]])})
    return {'status':'PASS' if all(p['reachable_in_pinned_csv'] for p in pairs) else 'FAIL',
            'scope':'Three-point directed reachability in hash-pinned import CSVs ONLY',
            'database_reachability':'NOT VERIFIED: database edge-content equivalence not proven',
            'node_count':len(nodes),'edge_count':len(sources),'source_file_hashes':hashes,'pairs':pairs,
            'max_csv_fractional_decimal_places':max_scale,
            'elapsed_seconds':round(time.monotonic()-started,3),'database_access':False,
            'whole_graph_scc_checked':False,'distance_time_precision_checked':False}

try:
    result=run()
except Exception as e:
    result={'status':'NOT VERIFIED','error':type(e).__name__+': '+str(e),'database_access':False}
RESULT.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
print(json.dumps(result,indent=2))
if result['status']!='PASS': raise SystemExit(1)
