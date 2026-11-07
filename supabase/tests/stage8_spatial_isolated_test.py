"""Stage B.1: opt-in private portable PostgreSQL; never connects to Supabase."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import uuid

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT))

BOOT="""
CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role BYPASSRLS;
CREATE SCHEMA auth; CREATE TABLE auth.users(id uuid PRIMARY KEY,email text);
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE FUNCTION auth.role() RETURNS text LANGUAGE sql STABLE AS $$ SELECT coalesce(nullif(current_setting('request.jwt.claim.role',true),''),current_user) $$;
GRANT USAGE ON SCHEMA auth TO PUBLIC;
CREATE SCHEMA storage; CREATE TABLE storage.objects(id uuid DEFAULT gen_random_uuid(),bucket_id text,name text,metadata jsonb);
CREATE SCHEMA extensions;
CREATE EXTENSION postgis WITH SCHEMA extensions;
CREATE EXTENSION pgrouting WITH SCHEMA extensions;
DROP SCHEMA public CASCADE;
"""
CRON="""
-- Catalog adapter only in the NEW disposable database; no scheduler exists.
CREATE SCHEMA cron;
CREATE TABLE cron.job(jobid bigint GENERATED ALWAYS AS IDENTITY,jobname text,schedule text,command text,username text DEFAULT 'postgres',active boolean DEFAULT true,database text DEFAULT current_database());
CREATE TABLE cron.job_run_details(jobid bigint,status text,start_time timestamptz,end_time timestamptz);
CREATE FUNCTION cron.schedule(text,text,text) RETURNS bigint LANGUAGE sql AS $$ INSERT INTO cron.job(jobname,schedule,command) VALUES($1,$2,$3) RETURNING jobid $$;
INSERT INTO cron.job(jobid,jobname,schedule,command,active) OVERRIDING SYSTEM VALUE VALUES(3,'geolock-expired-claim-recovery','* * * * *','set lock_timeout = ''5s''; set statement_timeout = ''50s''; select public.recover_expired_claims(100);',false);
"""
COVERAGE="""
INSERT INTO public.road_network_coverage(network_snapshot_id,coverage_area,provenance,dataset_kind,approved_at,active_flag)
VALUES('OSM-OPS-LOCAL-SYNTHETIC',extensions.ST_Multi(extensions.ST_MakeEnvelope(100,2,102,4,4326)),
'OPERATIONAL; SYNTHETIC LOCAL TEST ONLY; NOT OSM OR LIVE DATA','OPERATIONAL',now(),true);
INSERT INTO public.road_network_nodes(osm_node_id,network_snapshot_id,latitude,longitude,component_id)
VALUES(101,'OSM-OPS-LOCAL-SYNTHETIC',3,101,1),(102,'OSM-OPS-LOCAL-SYNTHETIC',3.01,101.01,1);
INSERT INTO public.road_network_edges(source_node,target_node,road_km,travel_minutes)
VALUES(101,102,19.9999,20);
"""
NGO='11111111-1111-1111-1111-111111111111'
DONOR='44444444-4444-4444-4444-444444444444'

class Harness:
    def __init__(self,runtime,out):
        self.runtime=runtime;self.pg=runtime/'pgsql';self.out=out;self.data=runtime/('data-'+out.name)
        if self.data.exists():raise RuntimeError('New data directory required')
        self.env={k:v for k,v in os.environ.items() if not k.upper().startswith(('PG','SUPABASE','GEOLOCK')) and k.upper()!='DATABASE_URL'}
        self.env.update(PGCONNECT_TIMEOUT='3',PGPASSFILE=str(runtime/'absent'),PGCLIENTENCODING='UTF8')
        self.env['PATH']=str(self.pg/'bin')+os.pathsep+self.env.get('PATH','')
        self.applied=[];self.results=[];self.started=False;self.seq=0
    def process(self,name,args):
        exe=(self.pg/'bin'/(name+'.exe')).resolve()
        assert exe.is_relative_to(self.pg.resolve()) and name in ('initdb','pg_ctl','psql')
        # pg_ctl's detached Windows server must not inherit a capture PIPE:
        # retained handles prevent communicate() observing EOF after pg_ctl exits.
        with tempfile.TemporaryFile(mode='w+',encoding='utf-8') as output:
            p=subprocess.run([str(exe),*args],env=self.env,stdout=output,stderr=subprocess.STDOUT,timeout=180,creationflags=subprocess.CREATE_NO_WINDOW)
            output.seek(0);message=output.read()
        if p.returncode:raise RuntimeError(message)
        return message.strip()
    def sql(self,sql):
        sql='SET search_path=pg_catalog,public,extensions;\n'+sql
        self.seq+=1;path=self.out/'sql'/f'{self.seq:04}.sql';path.write_text(sql,encoding='utf-8')
        started=time.perf_counter()
        try:
            answer=self.process('psql',['-X','-qAt','-v','ON_ERROR_STOP=1','-h','127.0.0.1','-p',str(self.port),'-U','postgres','-d','postgres','-f',str(path)])
        except Exception as e:
            self.log(path,started,error=str(e));raise
        self.log(path,started,output=answer);return answer
    def log(self,path,started,**values):
        with (self.out/'operations.jsonl').open('a',encoding='utf-8') as f:
            f.write(json.dumps(dict(sql=path.name,sha256=hashlib.sha256(path.read_bytes()).hexdigest(),elapsed_seconds=time.perf_counter()-started,**values))+'\n')
    def apply(self,relative):
        path=ROOT/relative;self.sql(path.read_text());self.applied.append(dict(file=relative,sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
        self.save('applied.json',self.applied)
    def save(self,name,value):
        (self.out/name).write_text(json.dumps(value,indent=2)+'\n',encoding='utf-8')
    def check(self,name,sql,expected):
        actual=json.loads(self.sql(sql));ok=actual==expected
        self.results.append(dict(name=name,status='PASS' if ok else 'FAIL',expected=expected,actual=actual,sql=f'sql/{self.seq:04}.sql'))
        self.save('checks.json',self.results);print(name,self.results[-1]['status'],flush=True)
    def start(self):
        self.process('initdb',['-D',str(self.data),'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
        with socket.socket() as s:s.bind(('127.0.0.1',0));self.port=s.getsockname()[1]
        self.process('pg_ctl',['-D',str(self.data),'-l',str(self.out/'postgresql-server.log'),'-w','-t','25','-o',f'-h 127.0.0.1 -p {self.port}','start']);self.started=True
    def setup(self):
        self.sql(BOOT)
        self.save('environment.json',json.loads(self.sql("SELECT jsonb_build_object('postgresql',version(),'postgis',extensions.postgis_full_version(),'pgrouting',extensions.pgr_full_version(),'host',inet_server_addr(),'port',inet_server_port(),'extension_schemas',(SELECT jsonb_agg(jsonb_build_object('name',e.extname,'version',e.extversion,'schema',n.nspname)) FROM pg_extension e JOIN pg_namespace n ON n.oid=e.extnamespace));")))
        snapshot=re.sub(r'^\\(?:un)?restrict[^\n]*','',(ROOT/'geolock-v3-public-schema.sql').read_text(),flags=re.M)
        self.sql(snapshot);self.applied.append(dict(file='geolock-v3-public-schema.sql',sha256=hashlib.sha256((ROOT/'geolock-v3-public-schema.sql').read_bytes()).hexdigest(),note='psql restrict directives removed'))
        self.sql('INSERT INTO public.coordination_config(singleton) VALUES(true);')
        self.apply('supabase/migrations/20261019_stage1_claim_recovery_and_reconciliation.sql')
        self.apply('supabase/migrations/20261019_retire_delivered_state.sql')
        self.apply('supabase/migrations/20261019_remove_validated_donation_state.sql')
        self.apply('supabase/migrations/20261020_operational_road_node_resolution.sql')
        self.sql(COVERAGE);self.sql(CRON)
        for name in ('20261021_auto_validate_ngo_registration_location.sql','20261022_role_onboarding_and_profile_management.sql','20261023_async_ngo_eligibility_refresh.sql','20261024_async_listing_eligibility_refresh.sql','20261025_fix_cancel_claim_audit_columns.sql','20261026_fix_claim_recovery_reconciliation_audit_columns.sql','20261027_persisted_donation_lifecycle.sql','20261029_fix_claim_recovery_listing_expiration_race.sql','20261030_fix_claim_recovery_unresolved_reconciliation.sql','20261031_claim_audit_and_failure_capture.sql'):
            self.apply('supabase/migrations/'+name)
        self.sql(f"""INSERT INTO auth.users(id,email) VALUES('{NGO}','ngo@local.invalid'),('{DONOR}','donor@local.invalid');
        INSERT INTO public.user_profiles(user_id,full_name,role) VALUES('{NGO}','LOCAL NGO','NGO'),('{DONOR}','LOCAL DONOR','DONOR');
        INSERT INTO public.ngo_profiles(user_id,ngo_name,operating_address,latitude,longitude,road_node_id,location_verified_at) VALUES('{NGO}','LOCAL NGO','LOCAL',3,101,'101',now());
        INSERT INTO public.donor_profiles(user_id) VALUES('{DONOR}');
        INSERT INTO public.donation_categories(category_id,category_name,active_flag) VALUES('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','LOCAL',true);""")
    def tests(self):
        self.check('postgis_spatial_operations',"SELECT to_jsonb(extensions.ST_SRID(extensions.ST_SetSRID(extensions.ST_MakePoint(101,3),4326))=4326 AND extensions.ST_Distance(extensions.ST_SetSRID(extensions.ST_MakePoint(101,3),4326)::extensions.geography,extensions.ST_SetSRID(extensions.ST_MakePoint(101,3),4326)::extensions.geography)=0);",True)
        self.check('directed_forward_path',"SELECT to_jsonb(abs(agg_cost-19.9999)<0.000002) FROM extensions.pgr_dijkstraCost('SELECT edge_id AS id,source_node AS source,target_node AS target,road_km::float8 AS cost,-1::float8 AS reverse_cost FROM public.road_network_edges',101::bigint,102::bigint,true);",True)
        self.check('directed_reverse_unreachable',"SELECT to_jsonb(count(*)) FROM extensions.pgr_dijkstraCost('SELECT edge_id AS id,source_node AS source,target_node AS target,road_km::float8 AS cost,-1::float8 AS reverse_cost FROM public.road_network_edges',102::bigint,101::bigint,true);",0)
        self.check('invalid_coordinate_resolver',"SELECT to_jsonb(count(*)) FROM (SELECT * FROM public.geolock_resolve_road_node(91,101) UNION ALL SELECT * FROM public.geolock_resolve_road_node(3,181) UNION ALL SELECT * FROM public.geolock_resolve_road_node('NaN',101) UNION ALL SELECT * FROM public.geolock_resolve_road_node(NULL,101)) x;",0)
        self.check('nearest_node_repeat',"SELECT to_jsonb(array_agg(node_id)) FROM generate_series(1,20) g CROSS JOIN LATERAL public.geolock_resolve_road_node(3+g*0.00000001,101);",['101']*20)
        self.check('snap_outside_500m_fails_closed',"SELECT to_jsonb(count(*)) FROM public.geolock_resolve_road_node(3.1,101.1);",0)
        self.check('missing_road_node_costs',"SELECT to_jsonb(count(*)) FROM public.geolock_road_costs(ARRAY[999999::bigint],ARRAY[102::bigint],3,101,20000);",0)
        self.check('missing_same_node_costs_fail_closed',"SELECT to_jsonb(count(*)) FROM public.geolock_road_costs(ARRAY[999999::bigint],ARRAY[999999::bigint],3,101,20000);",0)
        self.check('missing_snapshot_fails_closed',"BEGIN; UPDATE public.road_network_coverage SET active_flag=false; SELECT to_jsonb(count(*)) FROM public.geolock_resolve_road_node(3,101); ROLLBACK;",0)
        # Real protected donation creation; only Storage metadata is an adapter.
        request=str(uuid.uuid4());photo=f'{DONOR}/pending/{request}/{uuid.uuid4()}.jpg'
        items=json.dumps([dict(category_id='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',item_name='LOCAL',quantity=1,unit_weight_kg=20)])
        images=json.dumps([dict(storage_path=photo,content_type='image/jpeg',size_bytes=100)])
        did=self.sql(f"SET request.jwt.claim.sub='{DONOR}'; SET request.jwt.claim.role='authenticated'; INSERT INTO storage.objects(bucket_id,name,metadata) VALUES('geolock-donation-images','{photo}','{{\"size\":100,\"mimetype\":\"image/jpeg\"}}'); SELECT public.create_donation_with_images('{request}','LOCAL SPATIAL','SYNTHETIC','LOCAL',3.01,101.01,'{items}'::jsonb,'102','{images}'::jsonb);")
        listing=self.sql(f"SELECT listing_id FROM public.listings WHERE donation_id='{did}';")
        self.save('fixture.json',dict(ngo=NGO,donor=DONOR,donation=did,listing=listing,snapshot='OSM-OPS-LOCAL-SYNTHETIC',synthetic=True))
        self.check('pending_generation_fails_closed',f"SELECT to_jsonb(public.geolock_ngo_listing_road_check('{NGO}','{listing}')->>'outcome');",'ELIGIBILITY_UNDETERMINED')
        self.check('actual_listing_queue_processor',"SELECT to_jsonb(public.process_listing_eligibility_refresh_jobs()->>'outcome');",'COMPLETED')
        self.check('actual_readiness_guards',f"SELECT to_jsonb(public.geolock_ngo_eligibility_ready('{NGO}') AND public.geolock_listing_eligibility_ready('{listing}'));",True)
        boundary=[]
        for meters,expected in [(19999.9,'ELIGIBLE'),(20000,'ELIGIBLE'),(20000.1,'OUTSIDE_GEOFENCE')]:
            self.sql(f"UPDATE public.road_network_edges SET road_km={meters}/1000.0 WHERE source_node=101 AND target_node=102; DELETE FROM public.ngo_listing_road_eligibility;")
            self.check(f'road_boundary_{meters}m',f"SELECT to_jsonb(public.geolock_ngo_listing_road_check('{NGO}','{listing}')->>'outcome');",expected)
            evidence=json.loads(self.sql(f"SELECT jsonb_build_object('specified_m',{meters},'stored_edge_m',(SELECT road_km::float8*1000 FROM public.road_network_edges WHERE source_node=101 AND target_node=102),'raw_pgr_m',(SELECT road_km*1000 FROM public.geolock_road_costs(ARRAY[101::bigint],ARRAY[102::bigint],3.01,101.01,20000)),'cached_m',e.road_distance_km*1000,'outcome',e.outcome,'rpc',public.geolock_ngo_listing_road_check('{NGO}','{listing}')) FROM public.ngo_listing_road_eligibility e WHERE e.ngo_user_id='{NGO}' AND e.listing_id='{listing}';"))
            boundary.append(evidence)
        self.save('boundary-evidence.json',boundary)
        # Delete only this disposable graph's forward arc, retain opposite arc.
        self.sql('DELETE FROM public.road_network_edges; INSERT INTO public.road_network_edges(source_node,target_node,road_km,travel_minutes) VALUES(102,101,1,1); DELETE FROM public.ngo_listing_road_eligibility;')
        # Both nodes still carry component 1: report the exact current code,
        # while independently requiring that it cannot return ELIGIBLE.
        decision=json.loads(self.sql(f"SELECT public.geolock_ngo_listing_road_check('{NGO}','{listing}');"))
        self.save('directed-unreachable-decision.json',decision)
        self.check('directed_unreachable_claim_eligibility_fails_closed',f"SELECT to_jsonb(public.geolock_ngo_listing_road_check('{NGO}','{listing}')->>'outcome'<>'ELIGIBLE');",True)
        self.sql('UPDATE public.road_network_nodes SET component_id=2 WHERE osm_node_id=102; DELETE FROM public.ngo_listing_road_eligibility;')
        self.check('unreachable_different_components_reason',f"SELECT to_jsonb(public.geolock_ngo_listing_road_check('{NGO}','{listing}')->>'outcome');",'ROUTE_UNAVAILABLE')
        # Missing node identity is injected solely into this fresh local profile.
        self.sql(f"UPDATE public.ngo_profiles SET road_node_id=NULL WHERE user_id='{NGO}'; DELETE FROM public.ngo_listing_road_eligibility;")
        self.check('missing_ngo_node_fails_closed',f"SELECT to_jsonb(public.geolock_ngo_listing_road_check('{NGO}','{listing}')->>'outcome'<>'ELIGIBLE');",True)
        self.matrix_test()
        # Resolver has no stable ID tie breaker. Preserve production source and
        # document whether physically identical nodes change the selected ID.
        self.sql("INSERT INTO public.road_network_nodes(osm_node_id,network_snapshot_id,latitude,longitude,component_id) VALUES(100,'OSM-OPS-LOCAL-SYNTHETIC',3,101,1);")
        before=self.sql('SELECT node_id FROM public.geolock_resolve_road_node(3,101);')
        self.sql('CREATE TABLE public.local_node_copy AS TABLE public.road_network_nodes ORDER BY osm_node_id; DELETE FROM public.road_network_edges; DELETE FROM public.road_network_nodes; INSERT INTO public.road_network_nodes(osm_node_id,network_snapshot_id,latitude,longitude,component_id,active_flag) SELECT osm_node_id,network_snapshot_id,latitude,longitude,component_id,active_flag FROM public.local_node_copy ORDER BY osm_node_id;')
        after=self.sql('SELECT node_id FROM public.geolock_resolve_road_node(3,101);')
        self.save('nearest-tie-evidence.json',dict(before_reinsert=before,after_reinsert=after,production_order='n.geog <-> pt.g::extensions.geography',stable_id_tiebreaker=False,status='FAIL' if before!=after else 'UNVERIFIED_PHYSICAL_LAYOUT_DEPENDENCE'))
        self.check('deterministic_equal_distance_tie',f"SELECT to_jsonb('{before}'='{after}');",True)

    def matrix_test(self):
        from backend.routing.integration.graph_worker import matrix_from_export
        self.sql('DELETE FROM public.road_network_edges; INSERT INTO public.road_network_edges(source_node,target_node,road_km,travel_minutes) VALUES(101,102,19.9999,20),(102,101,2,3);')
        # Match the production export's explicit PG_REAL_OUTPUT_0 projection.
        nodes=json.loads(self.sql('SELECT jsonb_agg(to_jsonb(n) ORDER BY osm_node_id) FROM public.road_network_nodes n;'))
        edges=json.loads(self.sql('SET extra_float_digits=0; SELECT jsonb_agg(to_jsonb(e) ORDER BY edge_id) FROM public.road_network_edges e;'))
        manifest=dict(content_digest='a'*64,precision_policy='EXACT_MAX_6_DECIMALS',float_output_profile='PG_REAL_OUTPUT_0',node_count=len(nodes),edge_count=len(edges),coverage_snapshot='OSM-OPS-LOCAL-SYNTHETIC',speed_profile='LOCAL SYNTHETIC EXPLICIT TIMES',graph_id='LOCAL-SPATIAL-EXPORT')
        matrix=matrix_from_export(manifest,nodes,edges,['101','102'])
        raw=json.loads(self.sql("SELECT jsonb_agg(jsonb_build_object('source',start_vid,'target',end_vid,'road_km',agg_cost)) FROM extensions.pgr_dijkstraCost('SELECT edge_id AS id,source_node AS source,target_node AS target,road_km::float8 AS cost,-1::float8 AS reverse_cost FROM public.road_network_edges',ARRAY[101::bigint,102::bigint],ARRAY[101::bigint,102::bigint],true);"))
        max_error=max(abs(matrix['distance_km'][['101','102'].index(str(r['source']))][['101','102'].index(str(r['target']))]-r['road_km']) for r in raw)
        self.results.append(dict(name='worker_matrix_agrees_with_real_pgrouting',status='PASS' if max_error<0.000002 else 'FAIL',max_error_km=max_error,tolerance_km=0.000002))
        one_way=dict(manifest,edge_count=1)
        unavailable=matrix_from_export(one_way,nodes,[e for e in edges if e['source_node']==101],['101','102'])
        self.results.append(dict(name='worker_directed_unreachable_arc',status='PASS' if unavailable['arc_status'][1][0]=='UNREACHABLE' and unavailable['distance_km'][1][0] is None else 'FAIL'))
        self.save('checks.json',self.results)
        self.save('matrix-evidence.json',dict(manifest=manifest,nodes=nodes,edges=edges,matrix=matrix,pgrouting=raw,max_error_km=max_error,one_way_matrix=unavailable,note='Local export adapter; content digest is a declared placeholder, not protected DB attestation'))
        self.check('database_export_forward_precision',"SET extra_float_digits=0; SELECT to_jsonb(road_km::text) FROM public.road_network_edges WHERE source_node=101;",'19.9999')

def main():
    p=argparse.ArgumentParser();p.add_argument('--run-isolated',required=True,action='store_true');p.add_argument('--runtime',required=True,type=Path);p.add_argument('--output-dir',required=True,type=Path);a=p.parse_args()
    runtime=a.runtime.resolve();out=a.output_dir.resolve()
    if runtime.parent!=Path(tempfile.gettempdir()).resolve() or not runtime.name.startswith('geolock-spatial-runtime-'):p.error('Owned new temporary runtime required')
    if not out.is_relative_to(ROOT) or out.exists():p.error('New workspace evidence directory required')
    out.mkdir(parents=True);(out/'sql').mkdir();h=Harness(runtime,out);error=None;stopped=False
    try:h.start();h.setup();h.tests()
    except Exception as e:error=str(e);print(error,file=sys.stderr)
    finally:
        if h.started:
            try:h.process('pg_ctl',['-D',str(h.data),'-m','fast','-w','stop']);stopped=True
            except Exception as e:error=(error or '')+'\nCLEANUP: '+str(e)
        h.save('results.json',dict(status='BLOCKED' if error else 'PASS' if all(r['status']=='PASS' for r in h.results) else 'FAIL',checks=len(h.results),passed=sum(r['status']=='PASS' for r in h.results),error=error,supabase_connections=0,scope='REAL_POSTGIS_PGROUTING_LOCAL_ONLY_AUTH_STORAGE_CRON_CATALOG_ADAPTERS',cluster_stopped=stopped))
    return int(bool(error or any(r['status']!='PASS' for r in h.results)))

if __name__=='__main__':raise SystemExit(main())
