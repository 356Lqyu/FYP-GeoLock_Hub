"""Operator-run read-only export. Default --prepare-only never connects.

Use --export from a real local console for a hidden password prompt. No password
is written to files, command arguments, environment, repository or reports.
"""
import argparse
from datetime import datetime,timezone
import getpass
import json
from pathlib import Path
import subprocess
import sys
import warnings
from uuid import uuid4

import psycopg
from psycopg.rows import dict_row
from export_diagnostics import safe_error
from road_export_contract import (HERE,ROOT,PROJECT,HASHES,sha,reference_check,approved_profile,
    IDENTITY_SQL,COVERAGE_SQL,ACCESS_SQL,TYPES_SQL,NODE_SQL,EDGE_SQL)

def now(): return datetime.now(timezone.utc).isoformat()
def write(path,obj): path.write_text(json.dumps(obj,indent=2,default=str)+'\n',encoding='utf-8')

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--export',action='store_true',help='Connect read-only after secure local prompt')
    parser.add_argument('--prepare-only',action='store_true',help='Validate local prerequisites only (default)')
    parser.add_argument('--diagnose-connection',action='store_true',help='Prompt, check connection/read-only snapshot and stop; no CSV export')
    args=parser.parse_args()
    assert sum((args.export,args.prepare_only,args.diagnose_connection))<=1,'Choose one mode'
    ref=reference_check()
    profile,params=approved_profile()
    prep={'status':'PREPARED / NOT EXPORTED / EQUIVALENCE NOT VERIFIED','project_ref':PROJECT,
       'profile_file':str(profile),'profile':'geolock_dev_owner_export','connection':params,
       'certificate_sha256':sha(Path(params['sslrootcert'])),'reference_hashes':ref,
       'client':'psycopg '+psycopg.__version__,'libpq_version':psycopg.pq.version(),
       'compatibility':'libpq protocol export client, not pg_dump; libpq 18 can connect to PostgreSQL 17',
       'password_required':'Hidden local prompt only; no existing secret inspected',
       'database_connection_attempted':False,'database_writes':False}
    write(ROOT/'results/routing-initialization-preparation/export-preparation.json',prep)
    if not(args.export or args.diagnose_connection):
        print(json.dumps(prep,indent=2)); return 0
    if not sys.stdin.isatty():
        raise RuntimeError('Real local console required for hidden password entry')
    # Pin connection keywords explicitly from approved profile; no environment secret is read.
    with warnings.catch_warnings():
        warnings.simplefilter('error',getpass.GetPassWarning)
        password=getpass.getpass('Approved DEV read-only export account password (hidden): ')
    if not password: raise RuntimeError('Empty password; no connection attempted')
    output_root='routing-connection-diagnostics' if args.diagnose_connection else 'routing-current-export'
    target=ROOT/'results'/output_root/(datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-'+uuid4().hex[:6])
    target.mkdir(parents=True,exist_ok=False)
    receipt={'status':'INCOMPLETE','project_ref':PROJECT,'started_at':now(),
       'profile_sha256':sha(profile),'connection':params,'files':{},'database_writes':False,
       'exporter_sha256':sha(HERE/'export_current_dev.py'),
       'query_contract_sha256':sha(HERE/'road_export_contract.py'),
       'diagnostics_sha256':sha(HERE/'export_diagnostics.py'),
       'mode':'connection_diagnostic' if args.diagnose_connection else 'export','phase':'connect'}
    write(target/'receipt.json',receipt)
    metadata_queries=(IDENTITY_SQL,) if args.diagnose_connection else (IDENTITY_SQL,ACCESS_SQL,TYPES_SQL,COVERAGE_SQL)
    copy_queries=() if args.diagnose_connection else (NODE_SQL,EDGE_SQL)
    (target/'queries.sql').write_text('-- Audit of the selected mode query contract, no credentials.\n'+
       'BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;\n'+
       "SET LOCAL statement_timeout='60s';\nSET LOCAL lock_timeout='5s';\nSET LOCAL extra_float_digits=0;\nSET LOCAL timezone='UTC';\n"+
       '\n'.join(q+';' for q in metadata_queries)+'\n'+
       '\n'.join('COPY ('+q+') TO STDOUT WITH (FORMAT CSV, HEADER TRUE);' for q in copy_queries)+
       '\nROLLBACK;\n',encoding='utf-8')
    try:
        with psycopg.connect(**params,password=password,autocommit=True) as conn:
            del password
            receipt['phase']='snapshot_begin'
            write(target/'receipt.json',receipt)
            conn.execute('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY')
            try:
                for setting in ("statement_timeout='60s'","lock_timeout='5s'","extra_float_digits=0","timezone='UTC'"):
                    receipt['phase']='set_'+setting.split('=',1)[0]
                    write(target/'receipt.json',receipt)
                    conn.execute('SET LOCAL '+setting)
                receipt['phase']='identity'
                write(target/'receipt.json',receipt)
                identity=conn.execute(IDENTITY_SQL).fetchone()[0]
                receipt['identity']=identity
                assert identity['database']=='postgres' and identity['current_user']==identity['session_user']=='postgres'
                assert identity['read_only']=='on' and identity['ssl'] is True and identity['float_output']=='0'
                assert 170000<=identity['server_version_num']<180000,'Expected PostgreSQL major 17; review server drift'
                if not args.diagnose_connection:
                    receipt['phase']='access_metadata'; write(target/'receipt.json',receipt)
                    with conn.cursor(row_factory=dict_row) as cur:
                        access=cur.execute(ACCESS_SQL).fetchall()
                        receipt['phase']='type_metadata'; write(target/'receipt.json',receipt)
                        types=cur.execute(TYPES_SQL).fetchall()
                    receipt['access']=access; receipt['types']=types
                    assert len(access)==3 and all(r['can_select'] for r in access)
                    assert all(not(r['relrowsecurity'] or r['relforcerowsecurity']) or identity['bypassrls'] for r in access),'RLS coverage needs review'
                    lookup={(r['relname'],r['attname']):r['type'] for r in types}
                    for table,col,typ in [('road_network_nodes','osm_node_id','bigint'),('road_network_nodes','latitude','double precision'),
                        ('road_network_nodes','longitude','double precision'),('road_network_edges','edge_id','integer'),
                        ('road_network_edges','source_node','bigint'),('road_network_edges','target_node','bigint'),
                        ('road_network_edges','road_km','real'),('road_network_edges','travel_minutes','real')]:
                        assert lookup.get((table,col))==typ,'Source storage type drift'
                    receipt['phase']='coverage_metadata'; write(target/'receipt.json',receipt)
                    receipt['coverage']=conn.execute(COVERAGE_SQL).fetchone()[0]
                    for filename,query in (('nodes.csv',NODE_SQL),('edges.csv',EDGE_SQL)):
                        receipt['phase']='copy_'+filename; write(target/'receipt.json',receipt)
                        with (target/filename).open('xb') as f,conn.cursor() as cur:
                            with cur.copy('COPY ('+query+') TO STDOUT WITH (FORMAT CSV, HEADER TRUE)') as copy:
                                for block in copy: f.write(block)
                        receipt['phase']='hash_'+filename
                        receipt['files'][filename]={'sha256':sha(target/filename),'bytes':(target/filename).stat().st_size}
                        write(target/'receipt.json',receipt)
            except Exception as primary:
                receipt['primary_error']=safe_error(primary,receipt['phase'])
                raise
            finally:
                if not receipt.get('primary_error'):
                    receipt['phase']='rollback'; write(target/'receipt.json',receipt)
                try:
                    conn.execute('ROLLBACK')
                    receipt['rollback_completed']=True
                except Exception as cleanup:
                    receipt['rollback_error']=safe_error(cleanup,'rollback')
                    if not receipt.get('primary_error'): raise
        receipt.update(status='DIAGNOSTIC_PASS' if args.diagnose_connection else 'COMPLETE',
                       phase='diagnostic_complete' if args.diagnose_connection else 'export_complete',completed_at=now())
        write(target/'receipt.json',receipt)
    except Exception as error:
        receipt.update(status='INCOMPLETE',error_type=type(error).__name__,sqlstate=getattr(error,'sqlstate',None))
        receipt['failure']=receipt.get('primary_error') or safe_error(error,receipt['phase'])
        write(target/'receipt.json',receipt)
        print('Operation incomplete; evidence preserved at '+str(target)+'. No equivalence PASS.')
        print(json.dumps(receipt['failure']))
        return 1
    if args.diagnose_connection:
        print('Connection/read-only snapshot diagnostic PASS. No CSV export or equivalence check performed. Evidence: '+str(target))
        return 0
    print('Read-only export saved at '+str(target))
    # Verification never reconnects or receives the password.
    return subprocess.run([sys.executable,'-B',str(HERE/'verify_current_export.py'),'--export-dir',str(target)],check=False).returncode

if __name__=='__main__':
    try: raise SystemExit(main())
    except Exception as error:
        print('Stopped before a complete export: '+type(error).__name__+'. No equivalence PASS. Check local prerequisites; never share credentials.')
        raise SystemExit(1)
