"""Explicit local-only TLS/transaction regression; no DEV settings/credentials.

Fresh owned loopback PostgreSQL17 cluster, default read-write, synthetic roles/CA.
Nothing is restored, and no existing database connection string is accepted.
"""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT))
from backend.routing.worker_service.connection_diagnostic_native17 import configure_client
_NATIVE_HANDLE,_NATIVE_CLIENT=configure_client()
from backend.routing.worker_service.connection_diagnostic import IDENTITY_SQL
from backend.routing.worker_service.native_readonly_session import NativeReadOnlySession
from backend.routing.worker_service.readonly_pilot_probe import ReadOnlyGraphRpc
from backend.routing.worker_service.errors import WorkerError
import psycopg
from psycopg.pq import TransactionStatus
from psycopg import pq
from psycopg.conninfo import make_conninfo


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime',type=Path,required=True)
    args=parser.parse_args();runtime=args.runtime.resolve()
    if not runtime.name.startswith('geolock-spatial-runtime-'):raise ValueError('Private local runtime required')
    pg=runtime/'pgsql/bin'
    for key in list(os.environ):
        if key.upper().startswith(('PG','GEOLOCK_')):os.environ.pop(key)
    env={k:v for k,v in os.environ.items() if not k.upper().startswith(('PG','GEOLOCK_'))}
    def run(command,**kwargs):
        result=subprocess.run([str(x) for x in command],capture_output=True,text=True,env=env,**kwargs)
        if result.returncode:raise RuntimeError(result.stdout+'\n'+result.stderr)
        return result.stdout
    if '17.11' not in run([pg/'postgres.exe','--version']):raise ValueError('Expected local PostgreSQL17.11')
    target=Path(tempfile.mkdtemp(prefix='geolock-readonly-transaction-'))
    data=target/'cluster';cert=target/'local-cert.pem';key=target/'local-key.pem'
    run(['C:/Program Files/Git/usr/bin/openssl.exe','req','-x509','-newkey','rsa:2048','-nodes','-days','1',
         '-subj','/CN=localhost','-addext','subjectAltName=DNS:localhost,IP:127.0.0.1',
         '-keyout',key,'-out',cert])
    run([pg/'initdb.exe','-D',data,'-U','postgres','-A','trust','--encoding=UTF8','--no-locale'])
    with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
    with (data/'postgresql.conf').open('a') as f:
        f.write("\nlisten_addresses='127.0.0.1'\nport="+str(port)+"\nssl=on\nssl_cert_file='"+cert.as_posix()+"'\nssl_key_file='"+key.as_posix()+"'\ndefault_transaction_read_only=off\n")
    report={'scope':'LOCAL SYNTHETIC TLS/READONLY REGRESSION ONLY','dev_connections':0,'evidence':str(target),'client':_NATIVE_CLIENT}
    try:
        with (target/'control.log').open('w') as log:
            subprocess.run([str(pg/'pg_ctl.exe'),'-D',str(data),'-l',str(target/'server.log'),'-w','start'],
                           env=env,stdout=log,stderr=log,check=True,timeout=60)
        params=dict(host='127.0.0.1',port=port,dbname='postgres',sslmode='verify-full',sslrootcert=str(cert),connect_timeout=3)
        with psycopg.connect(**params,user='postgres',autocommit=True) as admin:
            admin.execute('CREATE ROLE geolock_graph_login LOGIN')
            admin.execute('CREATE ROLE geolock_graph_worker NOLOGIN')
            admin.execute('GRANT geolock_graph_worker TO geolock_graph_login')
            admin.execute('CREATE TABLE public.local_readonly_guard(i integer)')
            # Local fixture grants make the subsequent INSERT test read-only rejection,
            # independently of privilege denial. Never executed against DEV.
            admin.execute('GRANT INSERT,SELECT ON public.local_readonly_guard TO geolock_graph_worker')
        def connect(_):
            pgconn=pq.PGconn.connect(make_conninfo(**params,user='geolock_graph_login').encode('utf-8'))
            if pgconn.status!=pq.ConnStatus.OK:pgconn.finish();raise RuntimeError('Local fixture connection failed')
            pgconn.nonblocking=1
            return psycopg.Connection(pgconn)
        baseline=connect(None)
        report['old_implicit_begin']=baseline.execute(IDENTITY_SQL).fetchone()[0]
        assert report['old_implicit_begin']['read_only']=='off'
        assert report['old_implicit_begin']['ssl'] is True
        baseline.rollback();baseline.close()
        session=NativeReadOnlySession(bytearray(b'SYNTHETIC_UNUSED'),connector=connect)
        rpc=ReadOnlyGraphRpc('', 'geolock_graph_worker',connect=session)
        pages=[]
        for _ in range(2):
            borrowed=rpc._connection()
            with borrowed as conn:
                conn.execute('SET LOCAL ROLE geolock_graph_worker')
                state=conn.execute(IDENTITY_SQL).fetchone()[0]
                assert state['read_only']=='on' and state['default_read_only']=='off'
                assert conn.info.transaction_status==TransactionStatus.INTRANS
                pages.append(state)
            assert conn.info.transaction_status==TransactionStatus.IDLE
        try:
            with rpc._connection() as conn:
                conn.execute('SET LOCAL ROLE geolock_graph_worker')
                conn.execute('INSERT INTO public.local_readonly_guard VALUES(1)')
        except psycopg.errors.ReadOnlySqlTransaction as error:
            assert error.sqlstate=='25006';report['local_write_rejected_sqlstate']=error.sqlstate
        else:raise AssertionError('Local READ ONLY guard failed')
        assert session.metrics()['connection_closed']
        try:session()
        except WorkerError:pass
        else:raise AssertionError('Unexpected reconnection')
        with psycopg.connect(**params,user='postgres') as admin:
            assert admin.execute('SELECT count(*) FROM public.local_readonly_guard').fetchone()==(0,)
        # Narrow native runtime factory regression on THIS owned synthetic cluster.
        # No application activation and no external connection. Dummy functions
        # support catalog ACL checks only and are never invoked.
        from backend.routing.worker_service.native_worker import NativeRpcFactory,check_connection
        from backend.routing.worker_service.native_service_connection import approved_profile
        from backend.routing.worker_service.transport import RPCS
        with psycopg.connect(**params,user='postgres',autocommit=True) as admin:
            for role,login in [('geolock_planner','geolock_planner_login'),('geolock_validator','geolock_validator_login')]:
                admin.execute('CREATE ROLE '+role+' NOLOGIN')
                admin.execute('CREATE ROLE '+login+' LOGIN')
                admin.execute('GRANT '+role+' TO '+login)
                admin.execute('GRANT SELECT,INSERT ON public.local_readonly_guard TO '+role)
            for role,functions in RPCS.items():
                for name,types in functions.items():
                    signature='public.'+name+'('+','.join(types)+')'
                    admin.execute('CREATE FUNCTION '+signature+" RETURNS jsonb LANGUAGE SQL AS $$SELECT '{}'::jsonb$$")
                    admin.execute('REVOKE ALL ON FUNCTION '+signature+' FROM PUBLIC')
                    admin.execute('GRANT EXECUTE ON FUNCTION '+signature+' TO '+role)
        def local_native(password,*,role,read_only):
            try:
                login={'geolock_planner':'geolock_planner_login','geolock_validator':'geolock_validator_login'}[role]
                value=make_conninfo(**params,user=login,options='-c default_transaction_read_only=on' if read_only else '')
                pgconn=pq.PGconn.connect(value.encode('utf-8'))
                if pgconn.status!=pq.ConnStatus.OK:pgconn.finish();raise RuntimeError('Owned local fixture connection failed')
                pgconn.nonblocking=1
                return psycopg.Connection(pgconn)
            finally:password[:]=b'\0'*len(password)
        runtime_results=[]
        for role,login in [('geolock_planner','geolock_planner_login'),('geolock_validator','geolock_validator_login')]:
            settings=approved_profile();settings={k:settings[k] for k in ('host','port','dbname','sslmode','sslrootcert')}
            settings['user']=login+'.rcgyuwiidqvrgbxswhqj'
            # Identity-only DEV reference is validated, but the injected connector
            # above unconditionally uses127.0.0.1 and the owned synthetic cluster.
            with_readonly=NativeRpcFactory(reader=lambda _:bytearray(b'SYNTHETIC_UNUSED'),connector=local_native,read_only=True)
            try:
                result=check_connection(with_readonly(make_conninfo(**settings),role))
                assert result['status']=='PASS',result
                runtime_results.append(result)
            finally:with_readonly.close()
            writable=NativeRpcFactory(reader=lambda _:bytearray(b'SYNTHETIC_UNUSED'),connector=local_native)
            try:
                runtime_rpc=writable(make_conninfo(**settings),role)
                runtime_rpc.now() # Actual existing membership/role/timeout path.
                with runtime_rpc._connection() as conn:
                    conn.execute('SET LOCAL ROLE '+role)
                    conn.execute('INSERT INTO public.local_readonly_guard VALUES(40)')
                try:
                    with runtime_rpc._connection() as conn:
                        conn.execute('SET LOCAL ROLE '+role)
                        conn.execute('INSERT INTO public.local_readonly_guard VALUES(41)')
                        raise ValueError('SYNTHETIC_ROLLBACK')
                except ValueError:pass
            finally:writable.close()
        with psycopg.connect(**params,user='postgres') as admin:
            assert admin.execute('SELECT i,count(*) FROM public.local_readonly_guard GROUP BY i').fetchall()==[(40,2)]
        report.update(native_runtime_readonly_checks=runtime_results,native_runtime_commit_and_rollback='PASS / LOCAL SYNTHETIC ONLY')
        report.update(status='PASS',explicit_page_transactions=pages,connection_metrics=session.metrics())
    finally:
        if (data/'postmaster.pid').exists():
            run([pg/'pg_ctl.exe','-D',data,'-m','fast','-w','stop'])
    (target/'result.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))


if __name__=='__main__':
    try:main()
    finally:_NATIVE_HANDLE.close()
