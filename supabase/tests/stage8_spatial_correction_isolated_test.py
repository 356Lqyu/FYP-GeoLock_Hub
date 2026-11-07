"""Stage B.2: existing real spatial suite plus forward-correction regressions."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import subprocess
import stage8_spatial_isolated_test as base

ROOT=base.ROOT
MIGRATION='docs/stage8/stage-b2/forward-migrations/20261104_spatial_endpoint_validation.sql'
HELPERS=['public.geolock_resolve_road_node(double precision,double precision)',
         'public.geolock_road_costs(bigint[],bigint[],double precision,double precision,double precision)']

class Harness(base.Harness):
    def process(self,name,args):
        if name!='psql':return super().process(name,args)
        exe=(self.pg/'bin'/'psql.exe').resolve()
        assert exe.is_relative_to(self.pg.resolve())
        p=subprocess.run([str(exe),*args],env=self.env,capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=180,creationflags=subprocess.CREATE_NO_WINDOW)
        if p.stderr:
            with (self.out/'diagnostics.jsonl').open('a',encoding='utf-8') as f:
                f.write(json.dumps(dict(sql=f'sql/{self.seq:04}.sql',stderr=p.stderr,returncode=p.returncode))+'\n')
        if p.returncode:raise RuntimeError(p.stderr+'\n'+p.stdout)
        return p.stdout.strip()
    def catalog(self):
        return json.loads(self.sql("""SELECT jsonb_agg(jsonb_build_object('oid',p.oid,'signature','public.'||p.oid::regprocedure::text,
        'owner',pg_get_userbyid(p.proowner),'security_definer',p.prosecdef,'volatility',p.provolatile,
        'config',p.proconfig,'result',pg_get_function_result(p.oid),'acl',p.proacl::text,
        'body_md5',md5(replace(p.prosrc,E'\\r\\n',E'\\n'))) ORDER BY p.oid)
        FROM pg_proc p WHERE p.pronamespace='public'::regnamespace;"""))
    def setup(self):
        super().setup()
        # Model client schema USAGE so denial proves function ACL enforcement,
        # rather than stopping at the snapshot's absent schema grant.
        self.sql('GRANT USAGE ON SCHEMA public TO anon,authenticated,service_role;')
        before=self.catalog();self.save('catalog-before.json',before)
        self.apply(MIGRATION)
        after=self.catalog();self.save('catalog-after.json',after)
        by_id={row['oid']:row for row in before}
        changed=[];other_changes=[];metadata_changes=[]
        for row in after:
            old=by_id.get(row['oid'])
            if old is None:other_changes.append(row['signature']);continue
            if old['body_md5']!=row['body_md5']:changed.append(row['signature'])
            if {k:v for k,v in old.items() if k!='body_md5'}!={k:v for k,v in row.items() if k!='body_md5'}:metadata_changes.append(row['signature'])
        expected=set(HELPERS)
        self.results.append(dict(name='only_two_reviewed_function_bodies_changed',status='PASS' if set(changed)==expected and len(before)==len(after) and not other_changes else 'FAIL',changed=changed,expected=HELPERS))
        self.results.append(dict(name='all_function_signatures_owners_security_settings_acls_preserved',status='PASS' if not metadata_changes else 'FAIL',changes=metadata_changes))
        self.save('checks.json',self.results)
        self.check('private_helpers_not_executable_by_client_roles',"""SELECT to_jsonb(NOT EXISTS(SELECT 1 FROM pg_roles r CROSS JOIN pg_proc p
        WHERE r.rolname IN('anon','authenticated','service_role')
        AND p.oid IN('public.geolock_resolve_road_node(double precision,double precision)'::regprocedure,
        'public.geolock_road_costs(bigint[],bigint[],double precision,double precision,double precision)'::regprocedure)
        AND has_function_privilege(r.oid,p.oid,'EXECUTE')));""",True)
    def save(self,name,value):
        if name=='nearest-tie-evidence.json':
            value=dict(value,production_order='n.geog <-> pt.g::extensions.geography, n.osm_node_id',stable_id_tiebreaker=True,
                       status='PASS' if value['before_reinsert']==value['after_reinsert']=='100' else 'FAIL')
        super().save(name,value)
    def expect_error(self,name,sql,fragment):
        try:self.sql(sql)
        except RuntimeError as error:
            actual=str(error);ok=fragment in actual
        else:actual='NO_ERROR';ok=False
        self.results.append(dict(name=name,status='PASS' if ok else 'FAIL',expected_error=fragment,actual=actual,sql=f'sql/{self.seq:04}.sql'))
        self.save('checks.json',self.results)
    def costs(self,sources,targets,tail='3,101,20000'):
        return f"SELECT to_jsonb(count(*)) FROM public.geolock_road_costs({sources},{targets},{tail});"
    def tests(self):
        super().tests()
        self.endpoint_tests();self.tie_tests();self.compatibility_tests()
    def endpoint_tests(self):
        self.sql("""INSERT INTO public.road_network_coverage(network_snapshot_id,coverage_area,provenance,dataset_kind,approved_at,active_flag)
        VALUES('OSM-OPS-INACTIVE-SYNTHETIC',extensions.ST_Multi(extensions.ST_MakeEnvelope(100,2,102,4,4326)),
        'OPERATIONAL; LOCAL TEST ONLY','OPERATIONAL',now(),false);
        INSERT INTO public.road_network_nodes(osm_node_id,network_snapshot_id,latitude,longitude,component_id,active_flag)
        VALUES(201,'OSM-OPS-LOCAL-SYNTHETIC',3.002,101.002,1,false),
              (301,'OSM-OPS-INACTIVE-SYNTHETIC',3.003,101.003,1,true);
        INSERT INTO public.road_network_edges(source_node,target_node,road_km,travel_minutes)
        VALUES(101,102,1,1),(101,201,1,1),(201,102,1,1),(101,301,1,1),(301,102,1,1);""")
        valid='ARRAY[101::bigint]';target='ARRAY[102::bigint]'
        self.check('valid_self_distance_exactly_one_zero',"SELECT to_jsonb(array_agg(road_km)) FROM public.geolock_road_costs(ARRAY[101::bigint,101::bigint],ARRAY[101::bigint],3,101,20000);",[0])
        for node in (999999,201,301):
            invalid=f'ARRAY[{node}::bigint]'
            for label,s,t in [('self',invalid,invalid),('invalid_source',invalid,target),('invalid_target',valid,invalid)]:
                self.check(f'endpoint_{node}_{label}',self.costs(s,t),0)
        self.check('valid_directed_endpoint',self.costs(valid,target),1)
        self.check('valid_reverse_remains_unreachable',self.costs(target,valid),0)
        self.check('mixed_endpoint_arrays_keep_only_valid_members',self.costs('ARRAY[101::bigint,999999::bigint,201::bigint,301::bigint]',target),1)
        for name,s,t,tail in [('null_sources','NULL::bigint[]',target,'3,101,20000'),
            ('empty_targets',valid,'ARRAY[]::bigint[]','3,101,20000'),
            ('null_members','ARRAY[NULL::bigint]','ARRAY[NULL::bigint]','3,101,20000'),
            ('invalid_latitude',valid,valid,'91,101,20000'),('invalid_longitude',valid,valid,'3,181,20000'),
            ('null_center',valid,valid,'NULL,101,20000'),('negative_radius',valid,valid,'3,101,-1'),
            ('nan_radius',valid,valid,"3,101,'NaN'"),('infinite_radius',valid,valid,"3,101,'Infinity'")]:
            self.check(name,self.costs(s,t,tail),0)
        self.check('no_snapshot_valid_self_fails_closed','BEGIN; UPDATE public.road_network_coverage SET active_flag=false; '+self.costs(valid,valid)+' ROLLBACK;',0)
        self.check('inactive_target_even_with_existing_arc','BEGIN; UPDATE public.road_network_nodes SET active_flag=false WHERE osm_node_id=102; '+self.costs(valid,target)+' ROLLBACK;',0)
        self.check('inactive_intermediate_cannot_create_path','BEGIN; DELETE FROM public.road_network_edges WHERE source_node=101 AND target_node=102; '+self.costs(valid,target)+' ROLLBACK;',0)
        self.check('missing_edges_valid_distinct_endpoints','BEGIN; DELETE FROM public.road_network_edges; '+self.costs(valid,target)+' ROLLBACK;',0)
        self.check('isolated_valid_node_still_has_zero_self_cost','BEGIN; DELETE FROM public.road_network_edges; '+self.costs(valid,valid)+' ROLLBACK;',1)
        self.expect_error('negative_road_weight_constraint_preserved','UPDATE public.road_network_edges SET road_km=-1 WHERE source_node=101 AND target_node=102;','road_network_edges_road_km_check')
        self.expect_error('single_active_snapshot_constraint_preserved',"UPDATE public.road_network_coverage SET active_flag=true WHERE network_snapshot_id='OSM-OPS-INACTIVE-SYNTHETIC';",'road_network_one_active_operational')
        self.expect_error('unapproved_snapshot_activation_rejected',"UPDATE public.road_network_coverage SET approved_at=NULL WHERE active_flag;",'road_network_active_requires_approval')
    def tie_tests(self):
        evidence=[]
        self.sql('CREATE TABLE public.local_nodes_b2 AS TABLE public.road_network_nodes; DELETE FROM public.road_network_edges;')
        for order in ('ASC','DESC'):
            self.sql('DELETE FROM public.road_network_nodes; INSERT INTO public.road_network_nodes(osm_node_id,network_snapshot_id,latitude,longitude,component_id,active_flag) SELECT osm_node_id,network_snapshot_id,latitude,longitude,component_id,active_flag FROM public.local_nodes_b2 ORDER BY osm_node_id '+order+'; ANALYZE public.road_network_nodes;')
            for plan in ('seq','index'):
                options='SET enable_indexscan=off; SET enable_bitmapscan=off;' if plan=='seq' else 'SET enable_seqscan=off;'
                query="SELECT n.osm_node_id FROM public.road_network_nodes n JOIN public.road_network_coverage c USING(network_snapshot_id) WHERE n.active_flag AND c.active_flag AND c.dataset_kind='OPERATIONAL' AND c.approved_at IS NOT NULL AND extensions.ST_Covers(c.coverage_area,extensions.ST_SetSRID(extensions.ST_MakePoint(101,3),4326)) AND extensions.ST_DWithin(n.geog,extensions.ST_SetSRID(extensions.ST_MakePoint(101,3),4326)::extensions.geography,c.max_snap_distance_m) ORDER BY n.geog <-> extensions.ST_SetSRID(extensions.ST_MakePoint(101,3),4326)::extensions.geography,n.osm_node_id LIMIT 1;"
                execution_plan=self.sql(options+' EXPLAIN (FORMAT JSON) '+query)
                self.check(f'tie_order_{order}_plan_{plan}_25_repetitions',options+" SELECT to_jsonb(array_agg(node_id)) FROM generate_series(1,25) g CROSS JOIN LATERAL public.geolock_resolve_road_node(3+g*0.000000001,101);",['100']*25)
                evidence.append(dict(insertion_order=order,plan_profile=plan,explain=json.loads(execution_plan)))
        self.save('tie-plan-evidence.json',evidence)
        for role in ('anon','authenticated','service_role'):
            for fn,call in [('resolver','public.geolock_resolve_road_node(3,101)'),('costs','public.geolock_road_costs(ARRAY[101::bigint],ARRAY[101::bigint],3,101,20000)')]:
                self.expect_error(f'{role}_{fn}_direct_execution_denied',f'SET ROLE {role}; SELECT * FROM {call};','permission denied for function')
    def compatibility_tests(self):
        self.sql("INSERT INTO public.road_network_edges(source_node,target_node,road_km,travel_minutes) VALUES(100,102,1,1),(102,100,1,1); UPDATE public.ngo_profiles SET road_node_id='100' WHERE user_id='"+base.NGO+"'; DELETE FROM public.ngo_listing_road_eligibility;")
        f=json.loads((self.out/'fixture.json').read_text());listing=f['listing']
        self.check('current_claim_eligibility_after_spatial_fix',f"SELECT to_jsonb(public.geolock_ngo_listing_road_check('{base.NGO}','{listing}')->>'outcome');",'ELIGIBLE')
        request=str(base.uuid.uuid4())
        result=json.loads(self.sql(f"SET request.jwt.claim.sub='{base.NGO}'; SET request.jwt.claim.role='authenticated'; SELECT public.claim_listing('{listing}','{request}');"))
        audit_before=self.sql('SELECT count(*) FROM public.audit_events;')
        replay=json.loads(self.sql(f"SET request.jwt.claim.sub='{base.NGO}'; SET request.jwt.claim.role='authenticated'; SELECT public.claim_listing('{listing}','{request}');"))
        audit_after=self.sql('SELECT count(*) FROM public.audit_events;')
        ok=(result.get('outcome')=='SUCCESS' and result.get('replayed') is False and replay.get('replayed') is True
            and {k:v for k,v in result.items() if k!='replayed'}=={k:v for k,v in replay.items() if k!='replayed'} and audit_before==audit_after)
        self.results.append(dict(name='protected_claim_success_and_saved_replay',status='PASS' if ok else 'FAIL',response=result,replay=replay,audit_count_before_replay=audit_before,audit_count_after_replay=audit_after))
        self.save('checks.json',self.results)
        self.check('claim_lease_task_donation_audit_linkage',f"""SELECT to_jsonb(c.claim_status='ACTIVE' AND le.lease_status='ACTIVE'
        AND extract(epoch FROM(le.expires_at-le.issued_at))/60=360 AND t.task_status='CONFIRMED' AND d.donation_status='CLAIMED'
        AND EXISTS(SELECT 1 FROM public.audit_events a WHERE a.event_type='DONATION_STATUS_CHANGED' AND a.claim_id=c.claim_id
        AND a.lease_id=le.lease_id AND a.details->>'transaction_id' IS NOT NULL))
        FROM public.donation_claims c JOIN public.claim_leases le ON le.claim_id=c.claim_id JOIN public.pickup_tasks t ON t.claim_id=c.claim_id
        JOIN public.listings l ON l.listing_id=c.listing_id JOIN public.donations d ON d.donation_id=l.donation_id WHERE c.listing_id='{listing}';""",True)
        self.save('claim-compatibility.json',dict(request_id=request,response=result,replay=replay))
        # Re-applying original-source-only correction must fail without changing state.
        self.expect_error('migration_replay_refuses_changed_source',(ROOT/MIGRATION).read_text(),'REVIEWED_SPATIAL_SOURCE_OR_SECURITY_DRIFT')

def main():
    p=argparse.ArgumentParser();p.add_argument('--run-isolated',required=True,action='store_true');p.add_argument('--runtime',required=True,type=Path);p.add_argument('--output-dir',required=True,type=Path);a=p.parse_args()
    runtime=a.runtime.resolve();out=a.output_dir.resolve()
    if runtime.parent!=Path(tempfile.gettempdir()).resolve() or not runtime.name.startswith('geolock-spatial-runtime-') or (runtime/'pgsql').resolve().parent!=runtime:p.error('Owned private temporary runtime required')
    if not out.is_relative_to(ROOT) or out.exists():p.error('New workspace evidence directory required')
    out.mkdir(parents=True);(out/'sql').mkdir();h=Harness(runtime,out);error=None;stopped=False
    try:h.start();h.setup();h.tests()
    except Exception as e:error=str(e);print(error,file=sys.stderr)
    finally:
        if h.started:
            try:h.process('pg_ctl',['-D',str(h.data),'-m','fast','-w','stop']);stopped=True
            except Exception as e:error=(error or '')+'\nCLEANUP: '+str(e)
        h.save('results.json',dict(status='BLOCKED' if error else 'PASS' if all(r['status']=='PASS' for r in h.results) else 'FAIL',checks=len(h.results),passed=sum(r['status']=='PASS' for r in h.results),failed=sum(r['status']=='FAIL' for r in h.results),skipped=0,error=error,cluster_stopped=stopped,supabase_connections=0,scope='B2_REAL_SPATIAL_LOCAL_ONLY'))
    return int(bool(error or any(r['status']!='PASS' for r in h.results)))

if __name__=='__main__':raise SystemExit(main())
