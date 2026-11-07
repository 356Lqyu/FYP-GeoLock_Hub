"""Owned disposable loopback PostgreSQL17 benchmark; never accepts a DEV DSN."""
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
_HANDLE,_CLIENT=configure_client()
import psycopg


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime',type=Path,required=True)
    args=parser.parse_args();runtime=args.runtime.resolve()
    if not runtime.name.startswith('geolock-spatial-runtime-'):raise ValueError('Private local runtime required')
    pg=runtime/'pgsql/bin'
    env={k:v for k,v in os.environ.items() if not k.upper().startswith(('PG','GEOLOCK_'))}
    version=subprocess.run([str(pg/'postgres.exe'),'--version'],capture_output=True,text=True,env=env,check=True).stdout
    if '17.11' not in version:raise ValueError('Expected PostgreSQL17.11')
    target=Path(tempfile.mkdtemp(prefix='geolock-local-paging-'));data=target/'cluster'
    subprocess.run([str(pg/'initdb.exe'),'-D',str(data),'-U','postgres','-A','trust','--encoding=UTF8','--no-locale'],env=env,capture_output=True,check=True,timeout=60)
    with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
    with (data/'postgresql.conf').open('a') as stream:
        stream.write("\nlisten_addresses='127.0.0.1'\nport="+str(port)+"\nshared_buffers='32MB'\nmax_parallel_workers_per_gather=0\n")
    report=dict(scope='LOCAL SYNTHETIC SQL PERFORMANCE ONLY; NOT actual DEV plan',dev_connections=0,server=version.strip(),edges=400000,plans={})
    started=False
    try:
        with (target/'control.log').open('w') as log:
            subprocess.run([str(pg/'pg_ctl.exe'),'-D',str(data),'-l',str(target/'server.log'),'-w','start'],env=env,stdout=log,stderr=log,check=True,timeout=60)
        started=True
        with psycopg.connect(host='127.0.0.1',port=port,dbname='postgres',user='postgres',sslmode='disable',connect_timeout=3,options='-c statement_timeout=15000',autocommit=True) as conn:
            conn.execute('CREATE TABLE local_edges(edge_id integer NOT NULL,source_node bigint NOT NULL,target_node bigint NOT NULL,road_km real NOT NULL,travel_minutes real NOT NULL,PRIMARY KEY(source_node,target_node))')
            conn.execute('INSERT INTO local_edges SELECT (i*37)%400000+1,i,i+1,1,2 FROM generate_series(1,400000)i')
            conn.execute('ANALYZE local_edges')
            query='SELECT edge_id,source_node,target_node,road_km,travel_minutes FROM local_edges WHERE ($1 IS NULL OR edge_id>$1) ORDER BY edge_id LIMIT 10000'
            conn.execute('PREPARE page(integer) AS '+query)
            for indexed in [False,True]:
                if indexed:conn.execute('CREATE INDEX local_edge_cursor ON local_edges(edge_id)');conn.execute('ANALYZE local_edges')
                for mode in ['force_custom_plan','force_generic_plan']:
                    conn.execute('SET plan_cache_mode='+mode)
                    for cursor in ['NULL','200000','390000']:
                        key=('indexed' if indexed else 'unindexed')+'/'+mode+'/'+cursor
                        report['plans'][key]=conn.execute('EXPLAIN(ANALYZE,BUFFERS,FORMAT JSON) EXECUTE page('+cursor+')').fetchone()[0][0]
            # Validate the exact operator SQL on synthetic local objects only.
            conn.execute('ALTER TABLE local_edges RENAME TO road_network_edges')
            conn.execute('CREATE TABLE road_network_nodes(osm_node_id bigint PRIMARY KEY,network_snapshot_id text,active_flag boolean)')
            conn.execute("CREATE FUNCTION public.read_frozen_routing_graph(uuid,bigint,integer) RETURNS jsonb LANGUAGE SQL AS $$SELECT '{}'::jsonb$$")
            sql=ROOT/'docs/stage8/functional-routing/GRAPH_PAGING_PLAN.readonly.sql'
            result=subprocess.run([str(pg/'psql.exe'),'-X','-w','--dbname',f'host=127.0.0.1 port={port} dbname=postgres user=postgres sslmode=disable connect_timeout=3',
                '--set','ON_ERROR_STOP=1','--file',str(sql)],env=env,capture_output=True,text=True,timeout=30,check=True)
            (target/'readonly-plan-syntax-check.txt').write_text(result.stdout,encoding='utf-8')
            report['operator_readonly_sql_local_validation']='PASS / exact script; synthetic tables and function only'
    finally:
        if started:
            with (target/'control.log').open('a') as log:
                subprocess.run([str(pg/'pg_ctl.exe'),'-D',str(data),'-m','fast','-w','stop'],env=env,stdout=log,stderr=log,check=True,timeout=60)
        _HANDLE.close()
    report['local_server_stopped']=True
    output=ROOT/'results/worker-readiness'/target.name;output.mkdir(exist_ok=False)
    (output/'result.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(output/'result.json')


if __name__=='__main__':main()
