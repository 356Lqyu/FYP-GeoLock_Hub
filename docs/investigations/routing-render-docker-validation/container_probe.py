"""Offline Linux measurement payload. No credentials, network or live journals."""
from time import perf_counter
START=perf_counter()
import argparse
from dataclasses import asdict
import hashlib
import json
from pathlib import Path
import resource
from tempfile import TemporaryDirectory
import sys

sys.path.insert(0,'/app')


def sha(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda:stream.read(1024*1024),b''):h.update(block)
    return h.hexdigest()


def metrics():
    root=Path('/sys/fs/cgroup')
    return dict(process_peak_rss_bytes=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss*1024,
                process_cpu_seconds=resource.getrusage(resource.RUSAGE_SELF).ru_utime+resource.getrusage(resource.RUSAGE_SELF).ru_stime,
                cgroup={name:(root/name).read_text().strip() for name in
                        ('memory.max','memory.peak','memory.events','cpu.max','cpu.stat')})


def output(value):
    value.update(total_seconds=perf_counter()-START,metrics=metrics())
    print(json.dumps(value),flush=True)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('mode',choices=('inventory','startup','planner','prepare-validator','validator','graph','hold','restore'))
    p.add_argument('--role',choices=('planner','validator'),default='planner')
    p.add_argument('--engine',choices=('legacy','compact','artifact'),default='legacy')
    p.add_argument('--artifact-sha256');a=p.parse_args()
    if a.mode=='inventory':
        import os,platform,sqlite3,ortools,numpy,pandas,psycopg
        assert os.getuid()==10001
        assert not any(key.startswith(('GEOLOCK_','PGPASSWORD','PGSERVICE')) for key in os.environ)
        forbidden=[str(path) for path in Path('/app').rglob('*') if path.is_file() and
                   (path.suffix in ('.jsonl','.csr','.pem','.crt','.sqlite3','.backup') or path.name.startswith('.env'))]
        assert not forbidden,forbidden
        output(dict(mode='inventory',uid=os.getuid(),python=platform.python_version(),architecture=platform.machine(),
                    sqlite=sqlite3.sqlite_version,ortools=ortools.__version__,numpy=numpy.__version__,
                    pandas=pandas.__version__,psycopg=psycopg.__version__,forbidden_files=forbidden,
                    app_files=sorted(str(path.relative_to('/app')) for path in Path('/app').rglob('*') if path.is_file())))
    elif a.mode=='startup':
        from http.client import HTTPConnection
        from threading import Thread
        from backend.routing.hosted.config import Settings
        from backend.routing.hosted.runtime import Runtime
        from backend.routing.hosted.__main__ import BoundedServer,handler_for
        runtime=Runtime(Settings.from_env(a.role,{}));runtime.prepare()
        server=BoundedServer(('127.0.0.1',0),handler_for(runtime))
        thread=Thread(target=server.serve_forever,daemon=True);thread.start()
        c=HTTPConnection('127.0.0.1',server.server_port,timeout=5)
        c.request('GET','/live');r=c.getresponse();assert r.status==200;r.read()
        c.request('GET','/health');r=c.getresponse();assert r.status==503
        assert json.loads(r.read())['status']=='DISABLED';c.close()
        output(dict(mode='startup',role=a.role,scope='DISABLED_NO_DB_NO_GRAPH',startup_to_health_seconds=perf_counter()-START))
        server.shutdown();server.server_close();thread.join();runtime.close()
    elif a.mode=='prepare-validator':
        from backend.routing.worker_service.tests.test_worker_flow import FakeDatabase,FakeGraph,FakeSession,SID,REQ,CID
        from backend.routing.worker_service.journal import Journal
        from backend.routing.worker_service.orchestrator import RoutingWorker
        from backend.routing.worker_service.validator import Validator
        with TemporaryDirectory() as tmp:
            db=FakeDatabase()
            RoutingWorker(db,FakeGraph(db),Validator(db),Journal(tmp)).plan(FakeSession(db),SID,REQ)
            path=Path('/out/synthetic-validator-work.json')
            with path.open('x') as target:json.dump(dict(clock=db.clock.isoformat(),work=db.call('read_routing_work_item',CID)),target)
            output(dict(mode='prepare-validator',scope='EXISTING_SYNTHETIC_UNIT_FIXTURE',work_sha256=sha(path)))
    elif a.mode=='validator':
        from backend.routing.integration.worker import timestamp
        from backend.routing.worker_service.validator import Validator
        data=json.loads(Path('/fixtures/synthetic-validator-work.json').read_text())
        class SyntheticRpc:
            def __init__(self):self.attestations=0
            def now(self):return timestamp(data['clock'])
            def call(self,name,*args):
                if name=='read_routing_work_item':return data['work']
                if name=='attest_routing_candidate':self.attestations+=1;return None
                raise AssertionError(name)
        rpc=SyntheticRpc();validator=Validator(rpc);work=data['work'];durations=[]
        for _ in range(3):
            began=perf_counter();validator.validate(work['candidate']['candidate_id'],work['snapshot']['snapshot_id'],work['snapshot']['ngo_id'])
            durations.append(perf_counter()-began)
        output(dict(mode='validator',scope='SYNTHETIC_NO_DB_OR_HTTP_ATTESTATION',validation_seconds=durations,
                    mock_attestations=rpc.attestations,fixture_sha256=sha('/fixtures/synthetic-validator-work.json')))
    elif a.mode=='planner':
        from backend.routing.hosted.compact_graph import CompactGraph
        from backend.routing.integration.graph_worker import matrix_from_export
        from backend.routing.integration.tests.test_worker import synthetic_bundle
        from backend.routing.worker_service.tests.test_graph_http import RoadRpc
        from backend.routing.integration import solve_bundle
        source=RoadRpc();g=source.manifest
        nodes=[dict(osm_node_id=i,active_flag=True,network_snapshot_id=g['coverage_snapshot']) for i in range(101,1101)]
        edges=[dict(edge_id=(i-101)*3+j+1,source_node=i,target_node=101+(i-101+offset)%1000,
                    road_km=offset/100,travel_minutes=offset/10)
               for i in range(101,1101) for j,offset in enumerate((1,7,29))]
        g.update(node_count=len(nodes),edge_count=len(edges));bundle=synthetic_bundle();order=bundle['matrix']['body']['node_order']
        began=perf_counter();graph=CompactGraph.from_export(g,nodes,edges) if a.engine=='compact' else None
        warm=perf_counter()-began;durations=[];matrix=None
        for _ in range(3):
            began=perf_counter();value=graph.matrix(order) if graph else matrix_from_export(g,nodes,edges,order)
            durations.append(perf_counter()-began)
            if matrix is not None:assert matrix==value
            matrix=value
        bundle['matrix']['body']=matrix;began=perf_counter();comparison=solve_bundle(bundle);solve=perf_counter()-began
        methods=[dict(method=name,valid=check.valid,feasible=check.feasible,status=plan.status,
                      runtime_seconds=plan.runtime_seconds,solver_runtime_seconds=plan.solver_runtime_seconds,
                      timeout=plan.timeout,solver_statuses=plan.solver_statuses,coverage_optimal=plan.coverage_optimal)
                 for name,plan,check in comparison.results]
        assert len(methods)==4 and all(m['valid'] for m in methods)
        output(dict(mode='planner',engine=a.engine,scope='EXISTING_SYNTHETIC_1000_NODE_3000_EDGE_FIXTURE',
                    warm_seconds=warm,matrix_seconds=durations,four_method_seconds=solve,methods=methods,
                    matrix_sha256=hashlib.sha256(json.dumps(matrix,sort_keys=True,separators=(',',':')).encode()).hexdigest()))
    elif a.mode=='graph':
        from backend.routing.hosted.artifact import load_export
        from backend.routing.hosted.compact_graph import CompactGraph
        from backend.routing.integration.graph_worker import matrix_from_export
        expected=json.loads(Path('/fixtures/expected-matrix.json').read_text());order=expected['node_order']
        began=perf_counter()
        if a.engine=='artifact':
            with Path('/fixtures/graph.jsonl').open() as stream:g=json.loads(next(stream))['graph']
            graph=CompactGraph.read_artifact('/var/data/approved-graph.csr',a.artifact_sha256,g)
        else:
            g,nodes,edges=load_export('/fixtures/graph.jsonl','a525f79eada8fc65ce0568fd0cdba66237f1e5e6e3009bb4fa0e7482fc70accb')
            graph=None
        load=perf_counter()-began;began=perf_counter();artifact_sha=None
        if a.engine=='compact':
            graph=CompactGraph.from_export(g,nodes,edges);del nodes,edges
            artifact=Path('/var/data/approved-graph.csr')
            if not artifact.exists():artifact_sha=graph.write_artifact(artifact)
        warm=perf_counter()-began;durations=[]
        for _ in range(2):
            began=perf_counter();matrix=graph.matrix(order) if graph else matrix_from_export(g,nodes,edges,order)
            durations.append(perf_counter()-began);assert matrix==expected,'historical full-matrix parity failed'
        output(dict(mode='graph',engine=a.engine,scope='APPROVED_HISTORICAL_FULL_GRAPH_THREE_NODE_MATRIX_ONLY_NO_ROUTING_BUNDLE',
                    nodes=g['node_count'],edges=g['edge_count'],load_seconds=load,compile_and_optional_artifact_seconds=warm,
                    matrix_seconds=durations,full_matrix_parity=True,artifact_sha256=artifact_sha,
                    graph_sha256=matrix['version']))
    elif a.mode in ('hold','restore'):
        import os,stat
        from backend.routing.worker_service.journal import Journal
        assert os.path.ismount('/var/data') and os.stat('/var/data').st_uid==os.getuid()==10001
        sid,owner,request=[f'00000000-0000-0000-0000-{i:012d}' for i in (1,2,3)]
        j=Journal('/var/data/synthetic-journal')
        with j.claim(sid,owner,request):
            if a.mode=='hold':
                j.save(sid,'prepared',{'scope':'SYNTHETIC-CONTAINER-CRASH','request_id':request})
                with j._db() as reader:
                    reader.execute('BEGIN');reader.execute('SELECT * FROM jobs').fetchall()
                    print(json.dumps(dict(state='READY_TO_KILL')),flush=True)
                    import signal
                    while True:signal.pause()
            else:
                assert j.get(sid,'prepared')=={'scope':'SYNTHETIC-CONTAINER-CRASH','request_id':request}
                assert stat.S_IMODE(j.path.stat().st_mode)==0o600
                assert stat.S_IMODE(j.directory.stat().st_mode)==0o700
                output(dict(mode='restore',scope='SYNTHETIC_VOLUME_REOPEN',committed_step_preserved=True,
                            actual_mount=True,uid=os.getuid(),journal_mode='0600',directory_mode='0700'))


if __name__=='__main__':main()
