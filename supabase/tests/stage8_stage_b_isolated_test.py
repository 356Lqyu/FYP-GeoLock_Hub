"""Opt-in NEW disposable PostgreSQL only. Full business-schema snapshot.

Auth, Storage catalogue, road resolution/eligibility and cron catalogue are
explicit local doubles; PostGIS/pgRouting and live Supabase are NOT simulated
as verified extensions. Historical source files are never edited.
"""
import argparse
from datetime import datetime,timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest

import stage8_reconciliation_compatibility_isolated_test as runtime
from isolated_psql_sqlfile import SqlFiles
ROOT=runtime.ROOT
sys.path.insert(0,str(ROOT))
spec=importlib.util.spec_from_file_location('stage_a',ROOT/'docs/stage8/stage-a/build_package.py')
builder=importlib.util.module_from_spec(spec);spec.loader.exec_module(builder)
A,B,D=runtime.source.A,runtime.source.B,runtime.DONOR
OUT=None

BOOT='''
CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role BYPASSRLS;
CREATE SCHEMA auth; CREATE TABLE auth.users(id uuid PRIMARY KEY,email text);
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE FUNCTION auth.role() RETURNS text LANGUAGE sql STABLE AS $$ SELECT coalesce(nullif(current_setting('request.jwt.claim.role',true),''),current_user) $$;
GRANT USAGE ON SCHEMA auth TO PUBLIC;
CREATE SCHEMA storage; CREATE TABLE storage.objects(id uuid DEFAULT gen_random_uuid(),bucket_id text,name text,metadata jsonb);
CREATE SCHEMA extensions;
-- Spatial extensions are not installed: no geometry computation is claimed.
CREATE DOMAIN extensions.geography AS text;
DROP SCHEMA public CASCADE;
'''
EXTRA='''
INSERT INTO public.coordination_config(singleton) VALUES(true);
ALTER TABLE public.ngo_profiles ADD location_generation bigint NOT NULL DEFAULT 0;
ALTER TABLE public.listings ADD eligibility_generation bigint NOT NULL DEFAULT 1;
CREATE TABLE public.road_network_coverage(network_snapshot_id text PRIMARY KEY,active_flag boolean,dataset_kind text,approved_at timestamptz,max_snap_distance_m integer DEFAULT 500);
CREATE TABLE public.road_network_nodes(osm_node_id bigint PRIMARY KEY,network_snapshot_id text,active_flag boolean,component_id bigint DEFAULT 1,latitude double precision,longitude double precision);
CREATE TABLE public.road_network_edges(edge_id integer PRIMARY KEY,source_node bigint,target_node bigint,road_km real,travel_minutes real);
INSERT INTO public.road_network_coverage VALUES('OSM-OPS-ISOLATED-SYNTHETIC',true,'OPERATIONAL',now(),500);
INSERT INTO public.road_network_nodes VALUES(101,'OSM-OPS-ISOLATED-SYNTHETIC',true,1,3,101),(102,'OSM-OPS-ISOLATED-SYNTHETIC',true,1,3.01,101.01);
INSERT INTO public.road_network_edges VALUES(1,101,102,1,1),(2,102,101,1,1);
CREATE FUNCTION public.geolock_active_road_snapshot() RETURNS text LANGUAGE sql STABLE AS $$ SELECT 'OSM-OPS-ISOLATED-SYNTHETIC'::text $$;
CREATE FUNCTION public.geolock_resolve_road_node(double precision,double precision) RETURNS TABLE(node_id text,snap_distance_m double precision,snapshot_id text) LANGUAGE sql STABLE AS $$ SELECT '102'::text,0::float8,'OSM-OPS-ISOLATED-SYNTHETIC'::text $$;
CREATE FUNCTION public.geolock_ngo_eligibility_ready(uuid) RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT true $$;
CREATE FUNCTION public.geolock_listing_eligibility_ready(uuid) RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT true $$;
CREATE FUNCTION public.geolock_road_eligible_km(uuid,uuid) RETURNS double precision LANGUAGE sql STABLE AS $$ SELECT 1::float8 $$;
CREATE FUNCTION public.geolock_ngo_listing_road_check(uuid,uuid) RETURNS jsonb LANGUAGE sql AS $$ SELECT '{"outcome":"ELIGIBLE","road_distance_km":1}'::jsonb $$;
CREATE FUNCTION public.geolock_refresh_ngo_road_eligibility(uuid) RETURNS void LANGUAGE plpgsql AS $$ BEGIN RETURN; END $$;
CREATE SCHEMA cron;
CREATE TABLE cron.job(jobid integer,jobname text,active boolean,username text,database text,schedule text,command text);
CREATE TABLE cron.job_run_details(jobid integer,status text,start_time timestamptz,end_time timestamptz);
INSERT INTO cron.job VALUES(1,'LOCAL-NGO-DOUBLE',true,'postgres',current_database(),'* * * * *','LOCAL-NO-SCHEDULER'),(2,'LOCAL-LISTING-DOUBLE',true,'postgres',current_database(),'* * * * *','LOCAL-NO-SCHEDULER'),(3,'geolock-expired-claim-recovery',false,'postgres',current_database(),'* * * * *','set lock_timeout = ''5s''; set statement_timeout = ''50s''; select public.recover_expired_claims(100);');
'''


class StageBTests(runtime.CompatibilityTests):
    def authorize(self):
        f=self.fixture
        result=self.jrpc(f"public.authorize_my_routing_candidate('{self.req()}','{f['candidate']['candidate_id']}',clock_timestamp()+interval '1 second')")
        self.query('SELECT pg_sleep(1.05);')
        return result['route_ids'][0]

    def managed(self,started=True,expired=False,hub=False):
        if hub or expired:raise NotImplementedError('Whole-batch/expired reconciliation fixture is not prepared in this suite')
        f=self.prepare();rid=self.authorize()
        if started:self.rpc(f"public.start_pickup('{f['claim']}')")
        self.query(f"""BEGIN;
        UPDATE public.donation_claims SET claim_status='RECONCILIATION_REQUIRED' WHERE claim_id='{f['claim']}';
        UPDATE public.claim_leases SET lease_status='RECONCILIATION_REQUIRED' WHERE claim_id='{f['claim']}';
        INSERT INTO public.claim_reconciliation_cases(claim_id,listing_id,donation_id,source_type,case_status)
        VALUES('{f['claim']}','{f['listing']}','{f['donation']}','DIRECT_DONATION','OPEN');
        COMMIT;""")
        return f,rid
    @classmethod
    def setUpClass(cls):
        cls.tmp=tempfile.TemporaryDirectory(prefix='geolock-stage-b-')
        cls.folder=Path(cls.tmp.name);cls.data=cls.folder/'data';cls.db='postgres'
        cls.env={k:v for k,v in os.environ.items() if not k.upper().startswith(('PG','GEOLOCK','SUPABASE')) and k.upper()!='DATABASE_URL'}
        cls.env.update(PGCONNECT_TIMEOUT='3',PGPASSFILE=str(cls.folder/'absent'),PGCLIENTENCODING='UTF8')
        cls.flags=subprocess.CREATE_NO_WINDOW if os.name=='nt' else 0
        cls.addClassCleanup(cls.cleanup)
        cls.run_process([cls.bins['initdb'],'-D',str(cls.data),'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
        with socket.socket() as s:s.bind(('127.0.0.1',0));cls.port=s.getsockname()[1]
        cls.run_process([cls.bins['pg_ctl'],'-D',str(cls.data),'-l',str(cls.folder/'server.log'),'-w','-t','20','-o',f'-h 127.0.0.1 -p {cls.port}','start'])
        cls.applied=[]
        cls.query(BOOT)
        snapshot=(ROOT/'geolock-v3-public-schema.sql').read_text()
        snapshot=re.sub(r'^\\(?:un)?restrict[^\n]*','',snapshot,flags=re.M)
        cls.query(snapshot)
        cls.applied.append(dict(file='geolock-v3-public-schema.sql',sha256=builder.sha(ROOT/'geolock-v3-public-schema.sql'),note='psql restrict directives removed for SQL-file transport'))
        cls.query(EXTRA)
        # Snapshot contains the earlier photo/creation schema. Later exact
        # lifecycle files are applied, not patched to satisfy local guards.
        for name in ('20261019_stage1_claim_recovery_and_reconciliation.sql',
                     '20261027_persisted_donation_lifecycle.sql',
                     '20261029_fix_claim_recovery_listing_expiration_race.sql',
                     '20261030_fix_claim_recovery_unresolved_reconciliation.sql',
                     '20261031_claim_audit_and_failure_capture.sql'):
            path=ROOT/'supabase/migrations'/name
            cls.query(path.read_text())
            cls.applied.append(dict(file=str(path.relative_to(ROOT)),sha256=builder.sha(path)))
        cls.query(runtime.source.base.DEPOT+'; CREATE TRIGGER trg_vehicle_depot_node BEFORE INSERT OR UPDATE OF depot_road_node_id,ngo_user_id ON public.vehicles FOR EACH ROW EXECUTE FUNCTION public.geolock_assign_vehicle_depot();')
        # The older schema dump's assignment definition differs from the captured
        # installation prerequisite. Install the captured definition locally;
        # do NOT change the Stage A drift guard or its reviewed fingerprint.
        capture=json.loads((ROOT/'docs/stage8/integration/dev-preparation-evidence.json').read_text())
        assignment=next(f['definition'] for f in capture['functions'] if f['name']=='assign_task_to_route')
        cls.query(assignment)
        cls.applied.append(dict(file='captured assign_task_to_route prerequisite',sha256=hashlib.sha256(assignment.encode()).hexdigest()))
        cls.query((ROOT/'docs/stage8/phase-c1/proposed_migration_v2.sql').read_text())
        cls.applied.append(dict(file='docs/stage8/phase-c1/proposed_migration_v2.sql',sha256=builder.sha(ROOT/'docs/stage8/phase-c1/proposed_migration_v2.sql')))
        for name in builder.OUTPUTS:
            path=ROOT/'docs/stage8/stage-a/forward-migrations'/name
            cls.query(path.read_text());cls.applied.append(dict(file=str(path.relative_to(ROOT)),sha256=builder.sha(path)))
        (OUT/'applied.json').write_text(json.dumps(cls.applied,indent=2)+'\n')
        cls.query(f"""INSERT INTO auth.users(id,email) VALUES('{A}','ngo-a@local.invalid'),('{B}','ngo-b@local.invalid'),('{D}','donor@local.invalid');
        INSERT INTO public.user_profiles(user_id,full_name,role) VALUES('{A}','SYNTHETIC NGO A','NGO'),('{B}','SYNTHETIC NGO B','NGO'),('{D}','SYNTHETIC DONOR','DONOR');
        INSERT INTO public.donor_profiles(user_id) VALUES('{D}');
        INSERT INTO public.ngo_profiles(user_id,ngo_name,operating_address,latitude,longitude,road_node_id,location_verified_at) VALUES('{A}','A','LOCAL',3,101,'101',now()),('{B}','B','LOCAL',3,101,'101',now());
        INSERT INTO public.donation_categories(category_id,category_name,active_flag) VALUES('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','LOCAL',true);
        GRANT USAGE ON SCHEMA public TO authenticated;
        GRANT EXECUTE ON FUNCTION public.claim_listing(uuid,uuid),public.create_donation_with_images(uuid,text,text,text,double precision,double precision,jsonb,text,jsonb),public.discover_eligible_listing_cards() TO authenticated;
        """)
        env=cls.query("SELECT jsonb_build_object('version',version(),'host',inet_server_addr(),'port',inet_server_port(),'extensions',(SELECT jsonb_agg(jsonb_build_object('name',extname,'version',extversion)) FROM pg_extension),'constraints',(SELECT count(*) FROM pg_constraint WHERE connamespace='public'::regnamespace),'triggers',(SELECT count(*) FROM pg_trigger WHERE NOT tgisinternal));")
        (OUT/'environment.json').write_text(json.dumps(json.loads(env),indent=2)+'\n')
        cls.db='template1'

    def prepare(self,**kwargs):
        if kwargs.get('hub') or kwargs.get('two'):
            raise NotImplementedError('This suite uses the approved one-direct-task fixture only')
        # First acceptance path: protected photo-backed creation and claim,
        # not synthetic direct INSERTs into claims/leases/tasks.
        request=self.req();path=f'{D}/pending/{request}/{self.req()}.jpg'
        self.query(f"INSERT INTO storage.objects(bucket_id,name,metadata) VALUES('geolock-donation-images','{path}','{{\"size\":100,\"mimetype\":\"image/jpeg\"}}');")
        items=[dict(category_id='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',item_name='LOCAL ITEM',quantity=1,unit_weight_kg=20)]
        images=[dict(storage_path=path,content_type='image/jpeg',size_bytes=100)]
        did=self.rpc(f"public.create_donation_with_images('{request}','LOCAL DONATION','Local synthetic description','LOCAL',3.01,101.01,{self.literal(items)},'102',{self.literal(images)})",user=D)
        lid=self.query(f"SELECT listing_id FROM public.listings WHERE donation_id='{did}';")
        self.creation_trace=[dict(step='CREATED',donation=did,listing=lid,create_request=request,
            committed=json.loads(self.query(f"SELECT to_jsonb(d) FROM public.donations d WHERE donation_id='{did}';")))]
        discovery=self.rpc('public.discover_eligible_listing_cards()')
        self.assertIn(lid,discovery)
        claim_request=self.req()
        claim=self.jrpc(f"public.claim_listing('{lid}','{claim_request}')")
        self.assertEqual(claim['outcome'],'SUCCESS')
        cid=claim['claim_id'];tid=self.query(f"SELECT task_id FROM public.pickup_tasks WHERE claim_id='{cid}';")
        self.assertEqual(self.query(f"SELECT round(extract(epoch FROM(expires_at-issued_at))/60) FROM public.claim_leases WHERE claim_id='{cid}';"),'360')
        self.creation_trace.append(dict(step='CLAIMED',request=claim_request,response=claim,
            committed=json.loads(self.query(f"SELECT jsonb_build_object('claim',to_jsonb(c),'lease',to_jsonb(le),'task',to_jsonb(t)) FROM public.donation_claims c JOIN public.claim_leases le USING(claim_id) JOIN public.pickup_tasks t USING(claim_id) WHERE c.claim_id='{cid}';"))))
        v=self.jrpc(f"public.register_my_vehicle('{self.req()}','LOCAL VAN','VAN',100,10,1,240,true)")
        # Reuse the exact existing planning/attestation seam, after the real
        # protected creation path above. The road graph remains synthetic.
        from backend.routing.generate_examples import build_mixed
        import ortools
        from backend.routing.integration import solve_bundle,validate_work_item
        from dataclasses import asdict
        solver=build_mixed()['solver'];solver['version']=ortools.__version__;solver['time_limit_seconds']=1
        policy=dict(mandatory=True,horizon_minutes=240,dispatch_margin_minutes=5,direct_service_minutes=10,hub_service_minutes=10,solver=solver,execution=dict(fixed_cost_weight=1,distance_cost_weight=1,deterministic_seconds_per_pass=.05))
        pid=self.rpc(f"public.install_routing_policy('{self.req()}',{self.literal(policy)})",role='geolock_graph_worker')
        gid=self.rpc(f"public.freeze_routing_graph('{self.req()}','OSM-OPS-ISOLATED-SYNTHETIC','LOCAL EXPLICIT EDGE TIMES','EXACT_MAX_6_DECIMALS')",role='geolock_graph_worker')
        from backend.routing.integration.graph_worker import matrix_from_export
        exported=self.jrpc(f"public.read_frozen_routing_graph('{gid}',NULL,NULL)",role='geolock_graph_worker')
        matrix=matrix_from_export(exported['graph'],exported['nodes'],exported['edges'],['101','102'])
        mid=self.rpc(f"public.store_routing_matrix('{self.req()}','{gid}',{self.literal(matrix)})",role='geolock_graph_worker')
        snapshot=self.jrpc(f"public.begin_my_routing_snapshot('{self.req()}','{pid}')")
        self.jrpc(f"public.seal_routing_snapshot('{snapshot['snapshot_id']}','{mid}')",role='geolock_planner')
        bundle=self.jrpc(f"public.read_routing_snapshot_bundle('{snapshot['snapshot_id']}')",role='geolock_planner')
        comparison=solve_bundle(bundle);self.assertIsNotNone(comparison.proposed_candidate)
        candidate=self.jrpc(f"public.submit_routing_candidate('{self.req()}','{snapshot['snapshot_id']}',{self.literal(dict(plan=asdict(comparison.proposed_candidate)))})",role='geolock_planner')
        work=self.jrpc(f"public.read_routing_work_item('{candidate['candidate_id']}')",role='geolock_validator')
        report=validate_work_item(work,validator_build='STAGE-B-LOCAL')
        self.rpc(f"public.attest_routing_candidate('{candidate['candidate_id']}','{candidate['digest']}',{self.literal(report)})",role='geolock_validator')
        self.fixture=dict(vehicle=v,task=tid,claim=cid,donation=did,listing=lid,candidate=candidate,bundle=bundle,report=report)
        self.assertEqual(self.query('SELECT count(*) FROM public.pickup_routes;'),'0')
        self.assertEqual(self.query(f"SELECT task_status FROM public.pickup_tasks WHERE task_id='{tid}';"),'CONFIRMED')
        return self.fixture

    def test_direct_workflow(self):
        f=self.prepare();rid=self.authorize();trace=list(self.creation_trace)
        def record(label):
            row=json.loads(self.query(f"SELECT jsonb_build_object('donation',d.donation_status,'listing',l.listing_status,'claim',c.claim_status,'lease',le.lease_status,'task',t.task_status,'route',r.route_status,'vehicle_held',fleet_private.vehicle_has_hold(r.vehicle_id),'audit',(SELECT jsonb_agg(to_jsonb(a) ORDER BY occurred_at,event_id) FROM public.audit_events a)) FROM public.donations d JOIN public.listings l ON l.donation_id=d.donation_id JOIN public.donation_claims c USING(listing_id) JOIN public.claim_leases le USING(claim_id) JOIN public.pickup_tasks t USING(claim_id) JOIN public.pickup_routes r ON r.route_id='{rid}' WHERE d.donation_id='{f['donation']}';"))
            trace.append(dict(step=label,state=row));return row
        record('AUTHORIZED')
        self.rpc(f"public.start_pickup('{f['claim']}')");self.assertEqual(record('STARTED')['donation'],'PICKUP_IN_PROGRESS')
        self.rpc(f"public.complete_pickup('{f['claim']}',true)");state=record('COLLECTED')
        self.assertEqual([state[k] for k in ('donation','listing','claim','lease','task')],['COLLECTED','CLOSED','COMPLETED','COMPLETED','COLLECTED'])
        self.assertTrue(state['vehicle_held'])
        self.rpc(f"public.close_my_collected_route('{rid}',true)");self.assertFalse(record('CLOSED')['vehicle_held'])
        events=state['audit'];transitions=[a for a in events if a['event_type']=='DONATION_STATUS_CHANGED']
        self.assertEqual(len(transitions),3)
        self.assertTrue(all(a['claim_id']==f['claim'] and a['lease_id'] and a['details']['transaction_id'] for a in transitions))
        (OUT/'direct-workflow.json').write_text(json.dumps(dict(fixture=f,trace=trace),indent=2,default=str)+'\n')

    def test_missing_lease_and_expired_authority_fail_closed(self):
        f=self.prepare();rid=self.authorize()
        self.query(f"UPDATE public.claim_leases SET expires_at=clock_timestamp()+interval '0.1 second' WHERE claim_id='{f['claim']}'; SELECT pg_sleep(0.15);")
        self.rpc(f"public.start_pickup('{f['claim']}')",error='DISPATCH_SOURCE_STALE')
        self.assertEqual(self.query(f"SELECT donation_status FROM public.donations WHERE donation_id='{f['donation']}';"),'CLAIMED')
        self.query(f"DELETE FROM public.claim_leases WHERE claim_id='{f['claim']}';")
        self.rpc(f"public.start_pickup('{f['claim']}')",error='DISPATCH_SOURCE_STALE')

    def test_void_pickup_retry_reads_committed_authority(self):
        f=self.prepare();rid=self.authorize()
        self.rpc(f"public.start_pickup('{f['claim']}')")
        self.rpc(f"public.start_pickup('{f['claim']}')",error='PREVIOUS_PICKUP_UNRESOLVED')
        self.rpc(f"public.complete_pickup('{f['claim']}',true)")
        self.rpc(f"public.complete_pickup('{f['claim']}',true)",error='PICKUP_NOT_STARTED')
        row=self.jrpc(f"public.get_my_authorized_route('{rid}')")
        self.assertEqual(row['stops'][0]['task_status'],'COLLECTED')
        self.assertFalse(row['stops'][0]['can_start']);self.assertFalse(row['stops'][0]['can_complete'])

    def test_required_audit_failure_rolls_back_permit_and_business_state(self):
        f=self.prepare();rid=self.authorize()
        self.query("CREATE FUNCTION public.local_fail() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.event_type='START_PICKUP' THEN RAISE EXCEPTION 'LOCAL_REQUIRED_AUDIT_FAILURE'; END IF; RETURN NEW; END $$; CREATE TRIGGER local_fail BEFORE INSERT ON public.audit_events FOR EACH ROW EXECUTE FUNCTION public.local_fail();")
        before=self.query('SELECT count(*) FROM public.audit_events;')
        self.rpc(f"public.start_pickup('{f['claim']}')",error='LOCAL_REQUIRED_AUDIT_FAILURE')
        self.assertEqual(before,self.query('SELECT count(*) FROM public.audit_events;'))
        self.assertEqual(self.query(f"SELECT task_status FROM public.pickup_tasks WHERE task_id='{f['task']}';"),'PLANNED')
        self.assertEqual(self.query('SELECT consumed_at IS NULL FROM routing_private.items;'),'t')

    def test_route_and_candidate_forgery_and_request_reuse(self):
        f=self.prepare()
        self.rpc(f"public.get_my_authorized_route('{self.req()}')",error='OWNED_MANAGED_ROUTE_NOT_FOUND')
        self.rpc(f"public.start_pickup('{self.req()}')",error='DATABASE_DISPATCH_AUTHORIZATION_REQUIRED')
        request=self.req();departure="clock_timestamp()+interval '5 seconds'"
        self.jrpc(f"public.authorize_my_routing_candidate('{request}','{f['candidate']['candidate_id']}',{departure})")
        self.rpc(f"public.authorize_my_routing_candidate('{request}','{f['candidate']['candidate_id']}',clock_timestamp()+interval '6 seconds')",error='REQUEST_CONFLICT')
        self.assertEqual(self.query('SELECT count(*) FROM public.pickup_routes;'),'1')

    def test_rls_constraints_and_current_source_preservation(self):
        self.prepare()
        self.query('SET ROLE authenticated; UPDATE public.pickup_tasks SET task_status=\'DISPATCHED\';','permission denied')
        self.query('SET ROLE authenticated; INSERT INTO public.operation_failure_events(operation_name,reason_code) VALUES(\'forged\',\'forged\');','permission denied')
        self.assertEqual(self.query("SELECT relrowsecurity FROM pg_class WHERE oid='public.pickup_tasks'::regclass;"),'t')
        self.assertEqual(self.query("SELECT md5(replace(prosrc,E'\\r\\n',E'\\n')) FROM pg_proc WHERE oid='public.claim_listing(uuid,uuid)'::regprocedure;"),builder.PINS['claim_listing'])
        self.assertEqual(self.query("SELECT md5(replace(prosrc,E'\\r\\n',E'\\n')) FROM pg_proc WHERE oid='public.recover_expired_claims(integer)'::regprocedure;"),builder.PINS['recover_expired_claims'])

    def test_recovery_retains_reserved_task_and_cases(self):
        f=self.prepare();self.authorize()
        # Only this disposable test's lease is backdated; preserve its CHECK
        # and the six-hour duration. No production clock/lease is changed.
        self.query(f"UPDATE public.claim_leases SET issued_at=clock_timestamp()-interval '7 hours',expires_at=clock_timestamp()-interval '1 hour' WHERE claim_id='{f['claim']}';")
        self.assertEqual(self.query('SELECT public.recover_expired_claims(100);'),'1')
        self.assertEqual(self.query(f"SELECT claim_status FROM public.donation_claims WHERE claim_id='{f['claim']}';"),'RECONCILIATION_REQUIRED')
        self.assert_held(f)


def main():
    global OUT
    parser=argparse.ArgumentParser();parser.add_argument('--run-isolated',required=True,action='store_true');parser.add_argument('--output-dir',type=Path,required=True)
    args=parser.parse_args();OUT=args.output_dir.resolve()
    if not OUT.is_relative_to(ROOT.resolve()):parser.error('Workspace evidence directory required')
    OUT.mkdir(parents=True,exist_ok=False);runtime.EVIDENCE_DIR=OUT
    StageBTests.bins={name:str(Path(r'C:\Program Files\PostgreSQL\17\bin')/(name+'.exe')) for name in ('initdb','pg_ctl','psql')}
    names=[n for n in StageBTests.__dict__ if n.startswith('test_')]+[
      'test_unrouted_start_and_direct_task_bypass_denied','test_invalid_handover_rolls_back_completion',
      'test_vehicle_hold_and_stale_version','test_c1_seal_and_artifact_immutability',
      'test_race_cancel_first_denies_start','test_race_start_first_blocks_cancel',
      'test_race_publication_is_idempotent','test_bad_validation_binding_denied',
      'test_unauthenticated_and_old_assignment_entrypoint_denied',
      'test_sql_rechecks_schedule_even_with_forged_trusted_attestation',
      'test_successful_managed_reconciliation_keeps_depot_hold',
      'test_conflicting_evidence_never_mints_permit','test_unauthorized_participant_and_private_helper_denied',
      'test_planned_reserved_route_cannot_be_collected_by_evidence',
      'test_resolved_retry_returns_cached_response_without_new_audit',
      'test_concurrent_participants_serialize_without_duplicate_evidence',
      'test_concurrent_duplicate_final_request_is_idempotent']
    names += ['test_cancel_archives_and_releases_without_losing_task',
      'test_no_cancellation_or_closure_of_started_unresolved_route',
      'test_cross_ngo_and_ordinary_worker_access_denied',
      'test_concurrent_depot_closure_waits_for_reconciliation_commit',
      'test_permit_does_not_survive_into_next_transaction',
      'test_concurrent_cancellation_cannot_release_started_route',
      'test_concurrent_completion_cannot_bypass_reconciliation']
    result=unittest.TextTestRunner(verbosity=2).run(unittest.TestSuite(StageBTests(n) for n in names))
    (OUT/'results.json').write_text(json.dumps(dict(tests=result.testsRun,failures=[str(t)+e for t,e in result.failures],errors=[str(t)+e for t,e in result.errors],skipped=[str(t)+e for t,e in result.skipped],supabase_connections=0,scope='REAL_POSTGRESQL_FULL_BUSINESS_SCHEMA_WITH_DECLARED_EXTERNAL_DOUBLES'),indent=2)+'\n')
    return 0 if result.wasSuccessful() else 1

if __name__=='__main__':raise SystemExit(main())
