"""Bounded offline inventory; never connects to DEV or reads live journals."""
import hashlib
import json
from pathlib import Path
import platform
import shutil
import subprocess
import sys
from datetime import datetime,timezone

ROOT=Path(__file__).resolve().parents[3]
OUT=Path(__file__).resolve().parent
GRAPH=ROOT/'results/worker-readiness/20261027T083653Z-5f56bb/graphs/eab1f7ee-a8e0-4bed-a0e1-2c4bff024936.jsonl'
EXPECTED='a525f79eada8fc65ce0568fd0cdba66237f1e5e6e3009bb4fa0e7482fc70accb'


def digest(path):
    h=hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda:stream.read(1024*1024),b''):h.update(chunk)
    return h.hexdigest()


def main():
    receipt=dict(at_utc=datetime.now(timezone.utc).isoformat(),platform=platform.platform(),
                 windows_build=sys.getwindowsversion().build,
                 commands={n:shutil.which(n) for n in ('docker','podman','nerdctl','wsl','wslc','lima','colima')},
                 network_or_database_access=False,software_installed=False)
    receipt['install_paths']={str(p):p.exists() for p in [
        Path('C:/Program Files/Docker/Docker/Docker Desktop.exe'),
        Path('C:/Program Files/Docker/Docker/resources/bin/docker.exe'),
        Path('C:/Program Files/RedHat/Podman/podman.exe'),
        Path.home()/'AppData/Local/Programs/DockerDesktop/Docker Desktop.exe',
        Path.home()/'AppData/Local/Programs/podman-desktop/Podman Desktop.exe']}
    receipt['wsl']=[]
    for args in [('wsl.exe','--status'),('wsl.exe','--list','--verbose')]:
        run=subprocess.run(args,capture_output=True,timeout=15)
        def decode(raw):return raw.decode('utf-16-le',errors='replace') if b'\0' in raw else raw.decode('utf-8',errors='replace')
        receipt['wsl'].append(dict(command=list(args),exit_code=run.returncode,stdout=decode(run.stdout),stderr=decode(run.stderr)))
    assert digest(GRAPH)==EXPECTED==GRAPH.with_suffix('.sha256').read_text().strip()
    # Counts/cursors plus endpoint membership, without a full dictionary graph.
    manifest=None;node_ids=set();nodes=edges=pages=0;last_node=last_edge=None
    with GRAPH.open(encoding='utf-8') as stream:
        for line in stream:
            page=json.loads(line);pages+=1
            if manifest is None:manifest=page['graph']
            assert page['graph']==manifest
            ns=page['nodes'];es=page['edges']
            assert len(ns)<=10000 and len(es)<=10000
            for n in ns:
                key=n['osm_node_id'];assert last_node is None or key>last_node
                last_node=key;node_ids.add(key);nodes+=1
            for e in es:
                key=e['edge_id'];assert last_edge is None or key>last_edge
                last_edge=key;edges+=1
    assert nodes==len(node_ids)==manifest['node_count']==926414
    assert edges==manifest['edge_count']==2145828
    assert manifest['graph_id']=='eab1f7ee-a8e0-4bed-a0e1-2c4bff024936'
    assert manifest['content_digest']=='5e06dab0fb4d2b97ac53fd9a1178dc46aa6b98811aefbaef96528c604a04012a'
    with GRAPH.open(encoding='utf-8') as stream:
        for line in stream:
            for e in json.loads(line)['edges']:
                assert e['source_node'] in node_ids and e['target_node'] in node_ids
                assert e['road_km']>0 and e['travel_minutes']>0
    receipt['graph']=dict(path=str(GRAPH.relative_to(ROOT)),bytes=GRAPH.stat().st_size,
        file_sha256=EXPECTED,pages=pages,manifest=manifest,counts_cursors_endpoints='PASS',
        provenance='Historical independent SHA256 in docs/stage8/functional-routing/LOCAL_SERVICE_PREPARATION.md; frozen identity in FROZEN_DEV_PILOT.md',
        fresh_dev_manifest_verified=False)
    bundle=ROOT/'results/proposed-only-routing/runtime-compatibility-input.json'
    b=json.loads(bundle.read_text(encoding='utf-8'))['bundle'];snapshot=b['snapshot'];matrix=b['matrix']
    receipt['bundle_candidate']=dict(path=str(bundle.relative_to(ROOT)),sha256=digest(bundle),bytes=bundle.stat().st_size,
        snapshot_fields=list(snapshot),matrix_fields=list(matrix),
        graph_id=matrix.get('graph_id'),coverage=matrix['body'].get('network_snapshot_id'),
        required_nodes=len(matrix['body']['node_order']),observations=len(snapshot['body']['observations']),
        status='NOT_APPROVED_SANITIZED_BENCHMARK_INPUT',
        missing_snapshot_fields=[k for k in ('cutoff','sealed_at','digest') if k not in snapshot],
        limitation='Actual historical DEV SELECT capture; presentation compatibility only. No independent approved fixture seal or sanitization/admission review established.')
    receipt['profiles']=[dict(memory_mb=m,cpus=c,planner='NOT_TESTED',validator='NOT_TESTED')
        for m,c in [(512,.1),(2048,1),(4096,2),(8192,2)]]
    baseline=json.loads((ROOT/'docs/investigations/routing-render-implementation/BASELINE_SEALS.json').read_text())
    receipt['original_sources_unchanged']=all(digest(ROOT/p)==seal for p,seal in baseline.items())
    assert receipt['original_sources_unchanged']
    with (OUT/'local-inventory.json').open('x',encoding='utf-8') as target:json.dump(receipt,target,indent=2);target.write('\n')
    print(json.dumps(dict(graph_sha256=EXPECTED,nodes=nodes,edges=edges,pages=pages,
                          bundle_status=receipt['bundle_candidate']['status'])))


if __name__=='__main__':main()
