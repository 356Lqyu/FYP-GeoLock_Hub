"""One connection, READ ONLY, one tail-sample RPC. No graph loader or matrix imports."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from uuid import uuid4

from .errors import check
from .probe_diagnostics import safe_failure
from .transport import RoleRpc

GRAPH='eab1f7ee-a8e0-4bed-a0e1-2c4bff024936'
DIGEST='5e06dab0fb4d2b97ac53fd9a1178dc46aa6b98811aefbaef96528c604a04012a'
# Last-three cursors rederived offline from checksum-verified native capture
# 20261026T190933Z-native-23ecce; avoid the RPC's normal first 10000-row pages.
AFTER_NODE=14297239927
AFTER_EDGE=2145825
NODE_IDS=[14297239930,14297239933,14297239934]
EDGE_IDS=[2145826,2145827,2145828]

IDENTITY_SQL="""SELECT jsonb_build_object('session_user',session_user,'current_user',current_user,
 'database',current_database(),'read_only',current_setting('transaction_read_only'),
 'default_read_only',current_setting('default_transaction_read_only'),
 'ssl',(SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()),
 'tls_version',(SELECT version FROM pg_stat_ssl WHERE pid=pg_backend_pid()))"""
PERMISSIONS_SQL="""SELECT jsonb_build_object('current_user',current_user,
 'read_only',current_setting('transaction_read_only'),
 'can_read_graph',has_function_privilege(current_user,'public.read_frozen_routing_graph(uuid,bigint,integer)','EXECUTE'),
 'safe_login',(SELECT NOT rolsuper AND NOT rolbypassrls AND NOT rolcreatedb AND NOT rolcreaterole
 FROM pg_roles WHERE rolname=session_user),
 'memberships',(SELECT jsonb_agg(rolname) FROM pg_roles WHERE rolname IN
 ('geolock_graph_worker','geolock_planner','geolock_validator') AND pg_has_role(session_user,oid,'MEMBER')),
 'can_store_matrix',has_function_privilege(current_user,'public.store_routing_matrix(uuid,uuid,jsonb)','EXECUTE'))"""


def write(path,value):
    path.write_text(json.dumps(value,indent=2)+'\n',encoding='utf-8')


def diagnose(dsn, report, save=lambda:None, *, connect=None):
    conn=None; began=False; start=time.monotonic()
    def phase(value):
        report['phase']=value; save()
    def failure(error,operation):
        report.update(status='FAILED / NO CONNECTION PASS',failure=safe_failure(error,operation))
    try:
        phase('connection_configuration')
        RoleRpc.validate_dsn(dsn)
        from psycopg.conninfo import conninfo_to_dict
        import psycopg
        report['client']=dict(psycopg=psycopg.__version__,implementation=psycopg.pq.__impl__,libpq_version=psycopg.pq.version())
        params=conninfo_to_dict(dsn)
        check(params['host']=='aws-0-ap-northeast-2.pooler.supabase.com'
              and params['user']=='geolock_graph_login.rcgyuwiidqvrgbxswhqj'
              and params.get('port')=='5432' and params.get('dbname')=='postgres'
              and params.get('sslrootcert')=='C:/Users/User/Downloads/prod-ca-2021.crt',
              'APPROVED_GRAPH_CONNECTION_REQUIRED',503)
        report['tls_client_mode']='verify-full'
        report['connection_settings']={k:params[k] for k in ('host','port','dbname','user','sslmode','sslrootcert')}
        phase('connect')
        # Same connection implementation as the real worker; no automatic retry.
        conn=connect() if connect else RoleRpc(dsn,'geolock_graph_worker')._connection()
        report['connection_established']=True
        phase('begin_read_only')
        conn.autocommit=True
        conn.execute('BEGIN READ ONLY'); began=True
        phase('set_timeouts')
        conn.execute("SET LOCAL statement_timeout='10s'")
        conn.execute("SET LOCAL lock_timeout='2s'")
        phase('identity_and_tls')
        identity=conn.execute(IDENTITY_SQL).fetchone()[0]
        report['observed_identity']=identity
        check(identity['session_user']==identity['current_user']=='geolock_graph_login'
              and identity['database']=='postgres' and identity['read_only']=='on'
              and identity['ssl'] is True,'GRAPH_IDENTITY_TLS_MISMATCH',503)
        report['authentication']='PASS / observed dedicated session identity'
        phase('set_role')
        conn.execute('SET LOCAL ROLE geolock_graph_worker')
        phase('effective_permissions')
        permissions=conn.execute(PERMISSIONS_SQL).fetchone()[0]
        report['observed_permissions']=permissions
        check(permissions['current_user']=='geolock_graph_worker' and permissions['read_only']=='on'
              and permissions['can_read_graph'] and permissions['safe_login']
              and permissions['memberships']==['geolock_graph_worker'], 'GRAPH_PERMISSION_SCOPE_MISMATCH',503)
        phase('read_frozen_manifest_and_tail_sample')
        page=conn.execute('SELECT public.read_frozen_routing_graph(%s::uuid,%s::bigint,%s::integer)',
                          (GRAPH,AFTER_NODE,AFTER_EDGE)).fetchone()[0]
        manifest=page['graph']
        report['observed_graph']={k:manifest[k] for k in
            ('graph_id','content_digest','coverage_snapshot','node_count','edge_count','precision_policy','float_output_profile')}
        phase('validate_manifest_and_sample')
        check(manifest['graph_id']==GRAPH and manifest['content_digest']==DIGEST
              and manifest['coverage_snapshot']=='OSM-OPS-20261018' and manifest['node_count']==926414
              and manifest['edge_count']==2145828 and manifest['precision_policy']=='EXACT_MAX_6_DECIMALS'
              and manifest['float_output_profile']=='PG_REAL_OUTPUT_0','FROZEN_MANIFEST_MISMATCH',409)
        check([n['osm_node_id'] for n in page['nodes']]==NODE_IDS
              and [e['edge_id'] for e in page['edges']]==EDGE_IDS,'BOUNDED_TAIL_SAMPLE_MISMATCH',409)
        check(all(n['active_flag'] and n['network_snapshot_id']=='OSM-OPS-20261018' for n in page['nodes']),
              'SAMPLE_NODE_SCOPE_MISMATCH',409)
        report['observed_sample']={'nodes':page['nodes'],'edges':page['edges']}
        report['manifest_matches']=True
        report['checks_completed']=True
    except Exception as error:
        failure(error,report['phase'])
    finally:
        if conn:
            if began:
                try:
                    conn.execute('ROLLBACK'); report['rollback_completed']=True
                except Exception as error:
                    report['rollback_failure']=safe_failure(error,'rollback')
                    if 'failure' not in report: failure(error,'rollback')
            try:
                conn.close()
            except Exception as error:
                if 'failure' not in report: failure(error,'close_connection')
        report['elapsed_seconds']=round(time.monotonic()-start,3)
        if report.get('checks_completed') and report.get('rollback_completed') and 'failure' not in report:
            report.update(status='READ_ONLY CONNECTION DIAGNOSTIC PASS',phase='complete')
        save()
    return 0 if report['status']=='READ_ONLY CONNECTION DIAGNOSTIC PASS' else 1


def main(*, child_module=None, connection_factory=None, dsn_override=None, password_reader=None, transport_label='psycopg DSN'):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--child',type=Path,help=argparse.SUPPRESS)
    args=parser.parse_args()
    check(os.environ.get('GEOLOCK_ROUTING_ALLOW_DEV_WRITES')!='APPROVED','WRITE_ACTIVATION_MUST_BE_UNSET',503)
    if args.child:
        report=json.loads((args.child/'result.json').read_text())
        return diagnose(dsn_override or os.environ.get('GEOLOCK_GRAPH_DSN',''),report,
                        lambda:write(args.child/'result.json',report),connect=connection_factory)
    root=Path(__file__).resolve().parents[3]
    target=root/'results/worker-connection-diagnostics'/(datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-'+uuid4().hex[:6])
    target.mkdir(parents=True,exist_ok=False)
    report={'status':'INCOMPLETE','phase':'child_start','expected_graph_id':GRAPH,
            'expected_digest':DIGEST,'observed_graph':None,'database_writes':False,
            'activation':False,'full_graph_load':False,'matrix_computation':False,'rollback_completed':False}
    report['connection_transport']=transport_label
    write(target/'result.json',report)
    password=None
    try:
        if password_reader:
            report['phase']='native_password_prompt';write(target/'result.json',report)
            password=password_reader()
            report['phase']='child_start';write(target/'result.json',report)
        with (target/'process.log').open('w') as log:
            result=subprocess.run([sys.executable,'-B','-m',child_module or __spec__.name,'--child',str(target)],
                                  input=password,stdout=log,stderr=log,timeout=45)
        code=result.returncode
        report=json.loads((target/'result.json').read_text())
        if code and report['status']=='INCOMPLETE':
            report.update(status='FAILED / NO CONNECTION PASS',child_exit_code=code)
            write(target/'result.json',report)
    except subprocess.TimeoutExpired:
        report=json.loads((target/'result.json').read_text())
        report.update(status='TIMEOUT / NO CONNECTION PASS',budget_seconds=45)
        write(target/'result.json',report); code=1
    except Exception as error:
        report.update(status='FAILED / NO CONNECTION PASS',failure=safe_failure(error,report['phase']))
        write(target/'result.json',report);code=1
    finally:
        if isinstance(password,bytearray): password[:]=b'\0'*len(password)
    print('Read-only connection diagnostic evidence: '+str(target))
    return code


if __name__=='__main__':
    raise SystemExit(main())
