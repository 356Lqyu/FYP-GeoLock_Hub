"""Fresh Windows processes, synthetic inputs, loopback health only; not capacity proof."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
from time import perf_counter

ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT))
START=perf_counter()


def child(mode,work=None):
    from backend.routing.hosted.benchmark import peak_memory
    if mode in ('planner','validator'):
        from http.client import HTTPConnection
        from threading import Thread
        from backend.routing.hosted.config import Settings
        from backend.routing.hosted.runtime import Runtime
        from backend.routing.hosted.__main__ import BoundedServer,handler_for
        runtime=Runtime(Settings.from_env(mode,{}));runtime.prepare()
        server=BoundedServer(('127.0.0.1',0),handler_for(runtime))
        thread=Thread(target=server.serve_forever,daemon=True);thread.start()
        connection=HTTPConnection('127.0.0.1',server.server_port,timeout=5)
        connection.request('GET','/health');response=connection.getresponse();body=json.loads(response.read());connection.close()
        result=dict(mode=mode,scope='DISABLED_STARTUP_NO_GRAPH_NO_DB',startup_to_health_seconds=perf_counter()-START,
                    health_http=response.status,health_status=body['status'],memory=peak_memory())
        server.shutdown();server.server_close();thread.join();runtime.close()
    else:
        from backend.routing.integration.worker import timestamp
        from backend.routing.worker_service.validator import Validator
        data=json.loads(Path(work).read_text(encoding='utf-8'))
        class SyntheticRpc:
            def __init__(self):self.attestations=0
            def now(self):return timestamp(data['clock'])
            def call(self,name,*args):
                if name=='read_routing_work_item':return data['work']
                if name=='attest_routing_candidate':self.attestations+=1;return None
                raise AssertionError('Unexpected synthetic RPC '+name)
        rpc=SyntheticRpc();validator=Validator(rpc);durations=[]
        work=data['work'];snapshot=work['snapshot'];candidate=work['candidate']
        for _ in range(3):
            began=perf_counter();validator.validate(candidate['candidate_id'],snapshot['snapshot_id'],snapshot['ngo_id'])
            durations.append(perf_counter()-began)
        result=dict(mode='independent-validator',scope='SYNTHETIC_WORK_ITEM_NO_DB_NO_REAL_ATTESTATION',
                    startup_and_validation_seconds=perf_counter()-START,validation_seconds=durations,
                    mock_attestations=rpc.attestations,memory=peak_memory())
    print(json.dumps(result))


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--child',choices=('planner','validator','validate'))
    parser.add_argument('--work');args=parser.parse_args()
    if args.child:return child(args.child,args.work)
    from backend.routing.worker_service.tests.test_worker_flow import FakeDatabase,FakeGraph,FakeSession,SID,REQ,CID
    from backend.routing.worker_service.journal import Journal
    from backend.routing.worker_service.orchestrator import RoutingWorker
    from backend.routing.worker_service.validator import Validator
    env={k:v for k,v in os.environ.items() if not k.startswith(('GEOLOCK_','PG'))}
    with TemporaryDirectory() as tmp:
        tmp=Path(tmp);db=FakeDatabase()
        RoutingWorker(db,FakeGraph(db),Validator(db),Journal(tmp/'synthetic-journal')).plan(FakeSession(db),SID,REQ)
        work=tmp/'synthetic-work.json'
        work.write_text(json.dumps(dict(clock=db.clock.isoformat(),work=db.call('read_routing_work_item',CID))),encoding='utf-8')
        results=[]
        for mode in ('planner','validator','validate'):
            run=subprocess.run([sys.executable,'-B',str(Path(__file__).resolve()),'--child',mode,'--work',str(work)],
                               cwd=ROOT,env=env,capture_output=True,text=True,timeout=30)
            assert run.returncode==0,run.stderr
            results.append(json.loads(run.stdout))
    output=Path(__file__).parent/'component-measurements.json'
    with output.open('x',encoding='utf-8') as target:json.dump(results,target,indent=2);target.write('\n')
    print(json.dumps(results,indent=2))


if __name__=='__main__':main()
