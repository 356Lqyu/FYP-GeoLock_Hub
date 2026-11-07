"""Offline saved-page and synthetic matrix benchmark. Never opens a DB connection."""
import argparse
from datetime import datetime,timezone
import hashlib
import json
from pathlib import Path
import sys
from time import perf_counter
from uuid import uuid4

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT))
from backend.routing.phase_c2.matrices import freeze_graph,build_matrix
from backend.routing.worker_service.transport import encode


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--partial',type=Path,required=True)
    args=parser.parse_args();path=args.partial.resolve()
    if path.suffix!='.partial' or not path.is_relative_to(ROOT/'results/worker-readiness'):
        raise ValueError('Expected existing local readiness partial file')
    report=dict(scope='OFFLINE ONLY; no database connections; NOT DEV readiness PASS',
        source=str(path),source_bytes=path.stat().st_size,nodes=0,edges=0,pages=0,
        json_decode_seconds=0.,page_validation_seconds=0.,json_reencode_seconds=0.)
    started=perf_counter();digest=hashlib.sha256();after_node=after_edge=None;manifest=None
    with path.open('rb') as stream:
        for raw in stream:
            digest.update(raw);begin=perf_counter();page=json.loads(raw)
            report['json_decode_seconds']+=perf_counter()-begin
            begin=perf_counter()
            if manifest is None:manifest=page['graph']
            assert page['graph']==manifest
            ns=page['nodes'];es=page['edges']
            assert len(ns)<=10000 and len(es)<=10000
            for values,key,previous in [(ns,'osm_node_id',after_node),(es,'edge_id',after_edge)]:
                ids=[v[key] for v in values]
                assert ids==sorted(set(ids)) and (not ids or previous is None or ids[0]>previous)
            if ns:after_node=ns[-1]['osm_node_id']
            if es:after_edge=es[-1]['edge_id']
            report['nodes']+=len(ns);report['edges']+=len(es);report['pages']+=1
            report['page_validation_seconds']+=perf_counter()-begin
            begin=perf_counter();encode(page).encode('utf-8')
            report['json_reencode_seconds']+=perf_counter()-begin
    report.update(saved_page_processing_seconds=perf_counter()-started,source_sha256=digest.hexdigest(),
        manifest=manifest,last_node_cursor=after_node,last_edge_cursor=after_edge,
        limitations=['No original per-page RPC/server/network timings available',
            'Decode/validation/re-encoding only: excludes full retained object memory, live transfer and original disk writes',
            'Partial file remains incomplete and unsealed; never reused as a complete graph'])
    # Representative paged graph scale, deliberately synthetic and not a DEV matrix.
    count=10000;nodes=[str(i) for i in range(count)];edges=[]
    for i in range(count):
        for j in [(i+1)%count,(i-1)%count]:
            edges.append(dict(edge_id=str(len(edges)+1),source_node=str(i),target_node=str(j),road_km=1,travel_minutes=2))
    begin=perf_counter();graph=freeze_graph(nodes=nodes,edges=edges,snapshot_id='OFFLINE-BENCHMARK',
        kind='SYNTHETIC_BENCHMARK',complete=True,speed_profile='SYNTHETIC unit costs')
    synthetic=dict(nodes=count,edges=len(edges),freeze_seconds=perf_counter()-begin,matrices=[])
    for _ in range(2):
        profiles=[];begin=perf_counter();matrix=build_matrix(graph,['0','1','2'],profile=profiles.append)
        assert matrix['distance_km']==[[0,1,2],[1,0,1],[2,1,0]]
        synthetic['matrices'].append(dict(seconds=perf_counter()-begin,profile=profiles[-1]))
    report['synthetic']=synthetic
    target=ROOT/'results/worker-readiness'/('offline-timeout-review-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-'+uuid4().hex[:6])
    target.mkdir(exist_ok=False)
    (target/'result.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(target/'result.json')


if __name__=='__main__':main()
