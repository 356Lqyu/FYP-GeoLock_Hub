"""Bounded frozen-DEV cache/matrix benchmark. No HTTP server or mutating RPCs.

Provision GEOLOCK_GRAPH_DSN securely outside Git/command arguments. No credentials
are printed. --run is explicit; default only checks local configuration.
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from uuid import uuid4

from .errors import WorkerError, check
from .graph_cache import GraphCache
from .transport import RoleRpc
from .probe_diagnostics import safe_failure

GRAPH = 'eab1f7ee-a8e0-4bed-a0e1-2c4bff024936'
DIGEST = '5e06dab0fb4d2b97ac53fd9a1178dc46aa6b98811aefbaef96528c604a04012a'
NODES = ['1755847853','2308277456','5735535080']


class ReadOnlyGraphRpc(RoleRpc):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.failure = None

    def _failure(self, error):
        self.failure = safe_failure(error,self._phase)

    def _connection(self):
        conn = super()._connection()
        try:
            self._phase = 'set_transaction_read_only'
            conn.execute('SET TRANSACTION READ ONLY')
            self._phase = 'verify_transaction_read_only'
            check(conn.execute("SELECT current_setting('transaction_read_only')").fetchone()==('on',),
                  'PROBE_TRANSACTION_READ_ONLY_REQUIRED',503)
            return conn
        except BaseException:
            try:
                conn.close()
            except Exception:
                pass  # Preserve the primary read-only setup exception.
            raise

    def call(self, name, *args):
        self.failure = None
        check(name == 'read_frozen_routing_graph' and args and args[0] == GRAPH,
              'READ_ONLY_PROBE_RPC_REJECTED', 403)
        try:
            page = super().call(name, *args)
        except WorkerError:
            # Read-only work cannot have an unknown write-commit outcome. Keep
            # normal write-worker retry semantics unchanged; this probe stops.
            if self.failure:
                raise WorkerError('READ_ONLY_PROBE_OPERATION_FAILED',503,False) from None
            raise
        self._phase = 'validate_manifest'
        manifest = page['graph']
        check(manifest['graph_id']==GRAPH and manifest['content_digest']==DIGEST
              and manifest['coverage_snapshot']=='OSM-OPS-20261018'
              and manifest['node_count']==926414 and manifest['edge_count']==2145828,
              'PINNED_FROZEN_GRAPH_MISMATCH', 409)
        return page


def write(path, value):
    # Preserve the last valid progress report if the child is terminated mid-write.
    temporary=path.with_suffix(path.suffix+'.tmp')
    temporary.write_text(json.dumps(value,indent=2)+'\n',encoding='utf-8')
    temporary.replace(path)


def child(target, matrix, *, connection_factory=None, dsn_override=None):
    report = {'status':'INCOMPLETE','graph_id':GRAPH,'content_digest':DIGEST,
              'database_writes':False,'activation':False,'phase':'graph_load',
              'graph_warmup_seconds':None,'matrix_seconds':[],
              'worker_pid':os.getpid(),'worker_parent_pid':os.getppid()}
    write(target/'result.json', report)
    started = time.monotonic()
    rpc = None
    code=1
    try:
        import psycopg
        report['client']=dict(psycopg=psycopg.__version__,implementation=psycopg.pq.__impl__,libpq_version=psycopg.pq.version())
        rpc = ReadOnlyGraphRpc(dsn_override or os.environ['GEOLOCK_GRAPH_DSN'],'geolock_graph_worker',connect=connection_factory)
        def native_profile():
            report['native_io_profile']=connection_factory.metrics();write(target/'result.json',report)
        if connection_factory is not None:connection_factory.on_profile=native_profile
        def progress(nodes,edges):
            report['graph_progress']=dict(nodes_loaded=nodes,edges_loaded=edges)
            report['graph_load_profile']=cache.profile
            write(target/'result.json',report)
        cache = GraphCache(rpc,GRAPH,target/'graphs',progress=progress)
        manifest,nodes,edges = cache.load()
        report.update(graph_warmup_seconds=round(time.monotonic()-started,3),
                      nodes=len(nodes),edges=len(edges),phase='matrix' if matrix else 'complete')
        write(target/'result.json',report)
        if matrix:
            timings=[]
            for i in range(2):
                report['phase']='matrix_'+str(i+1);write(target/'result.json',report)
                begin=time.monotonic()
                def matrix_profile(value):
                    report['matrix_profile']=value;write(target/'result.json',report)
                body=cache.matrix(NODES,profile=matrix_profile)
                timings.append(round(time.monotonic()-begin,3))
                write(target/('matrix-'+str(i+1)+'.json'),body)
                report['matrix_seconds']=timings
                write(target/'result.json',report)
            report['matrix_arc_status']=body['arc_status']
            # Runtime readiness remains distinct from SQL storage/validator acceptance.
            report['fits_flutter_150_second_budget_per_matrix']=all(t<150 for t in timings)
        report.update(status='READ_ONLY PROBE PASS',phase='complete',elapsed_seconds=round(time.monotonic()-started,3),
                      limitations=['No matrix stored, candidate/attestation/route created or live JWT tested',
                                   'GraphCache count/manifest checks are not an independent DB hash-chain recomputation',
                                   'Diagnostic pairs only; total solver/validator/HTTP latency remains to be measured'])
        write(target/'result.json',report)
        code=0
    except Exception as error:
        report.update(status='FAILED / NO READINESS PASS',phase=report['phase'],
                      elapsed_seconds=round(time.monotonic()-started,3),
                      error_code=error.code if isinstance(error,WorkerError) else type(error).__name__)
        report['failure'] = (rpc.failure or safe_failure(error,rpc._phase)) if rpc else safe_failure(error,'probe_setup')
        write(target/'result.json',report)
        code=1
    finally:
        if connection_factory is not None:
            try:connection_factory.close()
            except Exception:
                report.update(status='FAILED / NO READINESS PASS',error_code='NATIVE_SESSION_CLEANUP_FAILED');code=1
            report['connection_metrics']=connection_factory.metrics()
        write(target/'result.json',report)
    return code


def main(*, child_module=None, connection_factory=None, dsn_override=None,password_reader=None,
         default_timeout=300,default_memory=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run',action='store_true')
    parser.add_argument('--matrix',action='store_true',help='Two real C2 matrices, entirely in local memory; no storage RPC')
    parser.add_argument('--timeout-seconds',type=int,default=default_timeout)
    parser.add_argument('--max-memory-mb',type=int,default=default_memory)
    parser.add_argument('--child',type=Path,help=argparse.SUPPRESS)
    args=parser.parse_args()
    check(os.environ.get('GEOLOCK_ROUTING_ALLOW_DEV_WRITES')!='APPROVED','UNSET_WRITE_ACTIVATION_FOR_PROBE',503)
    dsn=dsn_override or os.environ.get('GEOLOCK_GRAPH_DSN')
    if not dsn:
        print('NOT RUN: securely provision the dedicated GEOLOCK_GRAPH_DSN; no connection attempted.')
        return 2 if args.run else 0
    RoleRpc.validate_dsn(dsn)
    if args.child:
        return child(args.child,args.matrix,connection_factory=connection_factory,dsn_override=dsn_override)
    if not args.run:
        print('READ_ONLY_PROBE_CONFIGURED / NOT CONNECTED')
        return 0
    check(1<=args.timeout_seconds<=1200,'INVALID_PROBE_TIMEOUT',400)
    check(args.max_memory_mb is None or 256<=args.max_memory_mb<=8192,'INVALID_MEMORY_LIMIT',400)
    root=Path(__file__).resolve().parents[3]
    target=root/'results/worker-readiness'/(datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-'+uuid4().hex[:6])
    target.mkdir(parents=True,exist_ok=False)
    (target/'.gitignore').write_text('graphs/\n',encoding='utf-8')
    write(target/'result.json',{'status':'INCOMPLETE','graph_id':GRAPH,'content_digest':DIGEST,
          'database_writes':False,'activation':False,'phase':'child_start',
          'graph_warmup_seconds':None,'matrix_seconds':[]})
    command=[sys.executable,'-B','-m',child_module or __spec__.name,'--child',str(target)]
    if args.matrix: command.append('--matrix')
    password=None
    try:
        if password_reader:
            report=json.loads((target/'result.json').read_text());report['phase']='native_password_prompt'
            write(target/'result.json',report)
            password=password_reader()
        with (target/'process.log').open('w') as log:
            from .probe_resources import run_bounded
            result=run_bounded(command,log,args.timeout_seconds,password=password,max_memory_mb=args.max_memory_mb,
                worker_metadata=lambda:json.loads((target/'result.json').read_text()))
        report=json.loads((target/'result.json').read_text());report['resources']=result
        code=result['returncode']
        if result['stop_reason']:
            report['status']=result['stop_reason'];code=1
        write(target/'result.json',report)
        if code:
            path=target/'result.json'
            report=json.loads(path.read_text())
            if report.get('status')=='INCOMPLETE':
                report.update(status='FAILED / NO READINESS PASS',child_exit_code=code)
                write(path,report)
    except Exception as error:
        path=target/'result.json'
        report=json.loads(path.read_text()) if path.exists() else {}
        report.update(status='FAILED / NO READINESS PASS',failure=safe_failure(error,report.get('phase','probe_parent')))
        write(path,report)
        code=1
    finally:
        if isinstance(password,bytearray):password[:]=b'\0'*len(password)
    print('Read-only probe evidence: '+str(target))
    return code


if __name__=='__main__':
    try:
        raise SystemExit(main())
    except WorkerError as error:
        print(error.code)
        raise SystemExit(2)
