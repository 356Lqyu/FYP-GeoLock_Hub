"""Fresh loopback-only PostgreSQL 17: real historical SQL and new A004.

No existing DB/DSN accepted. Auth JWT-GUC/Storage/cron are LOCAL adapters,
not Supabase parity. Independent validator runs in a separate process.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone, timedelta
from decimal import Decimal
import hashlib
import json
import multiprocessing as mp
from pathlib import Path
import secrets
import sys
import tempfile
import threading
import time
import unittest
from uuid import uuid4

import postclaim_local_e2e as existing
import stage8_stage_c5_isolated_test as assembly
ROOT=assembly.ROOT
sys.path.insert(0,str(ROOT))
import psycopg
from psycopg.rows import dict_row
from backend.routing.worker_service.transport import RoleRpc, JsonHttp
from backend.routing.worker_service.graph_cache import GraphCache
from backend.routing.worker_service.validator import Validator, RemoteValidator
from backend.routing.worker_service.orchestrator import RoutingWorker, step_id
from backend.routing.worker_service.journal import Journal
from backend.routing.worker_service.server import Application, make_handler
from http.server import ThreadingHTTPServer

MIGRATION='docs/stage8/stage-a/forward-migrations/20261104_routing_automatic_departure.sql'

def connect(port,db,login):
    return psycopg.connect(host='127.0.0.1',hostaddr='127.0.0.1',port=port,dbname=db,
        user=login,password='',sslmode='disable',options='',connect_timeout=3)

def worker_rpc(port,db,role):
    login={'geolock_planner':'geolock_planner_login','geolock_validator':'geolock_validator_login',
           'geolock_graph_worker':'geolock_graph_login'}[role]
    return RoleRpc('',role,connect=lambda:connect(port,db,login))

def validator_process(port,db,token,channel):
    server=ThreadingHTTPServer(('127.0.0.1',0),make_handler(Application(
        validator=Validator(worker_rpc(port,db,'geolock_validator')),validator_token=token,active=True)))
    channel.send({'port':server.server_port,'pid':__import__('os').getpid()});channel.close()
    server.serve_forever()

class Session:
    ALLOWED={'claim_listing','register_my_vehicle','begin_my_routing_snapshot','list_my_vehicles',
      'get_my_claim_cards_v2','authorize_my_routing_candidate','get_my_routing_authorization_receipt',
      'get_my_authorized_route','start_pickup','complete_pickup','close_my_collected_route'}
    def __init__(self,port,db,user_id=existing.NGO):self.port,self.db,self.user_id=port,db,user_id
    def rpc(self,name,params=None):
        assert name in self.ALLOWED
        params=params or {}
        with connect(self.port,self.db,'geolock_local_ngo_login') as conn:
            with conn.cursor(row_factory=dict_row) as cur:
                cur.execute('SET LOCAL ROLE authenticated')
                cur.execute("SELECT set_config('request.jwt.claim.sub',%s,true)",(self.user_id,))
                args=','.join(k+' => %s' for k in params)
                cur.execute('SELECT * FROM public.'+name+'('+args+')',list(params.values()))
                rows=cur.fetchall()
                if name=='get_my_claim_cards_v2':
                    return json.loads(json.dumps(rows,default=lambda v:float(v) if isinstance(v,Decimal) else v.isoformat() if isinstance(v,datetime) else str(v)))
                return next(iter(rows[0].values())) if rows else None

class AutomaticTests(unittest.TestCase):
    runtime=None
    @classmethod
    def setUpClass(cls):
        stamp=datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-'+secrets.token_hex(3)
        cls.out=ROOT/'results/automatic-routing-local'/stamp;cls.out.mkdir(parents=True);(cls.out/'sql').mkdir()
        cls.lane=assembly.Lane(cls.runtime,cls.out)
        cls.addClassCleanup(cls.stop)
        cls.lane.freeze();cls.lane.hashes[MIGRATION]=assembly.digest(ROOT/MIGRATION)
        cls.lane.hashes[str(Path(__file__).relative_to(ROOT)).replace('\\','/')]=assembly.digest(Path(__file__))
        cls.lane.start();cls.lane.assemble();cls.lane.apply(assembly.AUTHORITY+assembly.A_FILES[2])
        cls.donation,cls.listing=existing.setup_fixture(cls.lane)
        cls.lane.apply(MIGRATION)
        cls.status={}

    @classmethod
    def stop(cls):
        lane=cls.lane
        if lane.started:
            code,_=lane.process('pg_ctl',['-D',str(lane.data),'-m','fast','-w','-t','25','stop'])
            lane.save('cluster-stop.json',{'stopped':code==0,'remote_connections':0})
        lane.verify_frozen()

    def setUp(self):
        self.db='auto_test_'+uuid4().hex;self.lane.db='postgres'
        self.lane.sql('CREATE DATABASE '+self.db+' TEMPLATE postgres;');self.lane.db=self.db
        self.session=Session(self.lane.port,self.db)
        self.temp=tempfile.TemporaryDirectory(prefix='geolock-auto-journal-');self.addCleanup(self.temp.cleanup)
        self.addCleanup(self.drop)

    def drop(self):
        self.lane.db='postgres';self.lane.sql('DROP DATABASE '+self.db+' WITH (FORCE);')

    def prepare(self,two=False,three=False):
        self.claim=self.session.rpc('claim_listing',{'p_listing':self.listing,'p_request':str(uuid4())})
        self.assertEqual(self.claim['outcome'],'SUCCESS')
        if two:
            request=str(uuid4());photo=f'{existing.DONOR}/pending/{request}/{uuid4()}.jpg'
            items=json.dumps([dict(category_id=existing.uid('category'),item_name='LOCAL SECOND PICKUP',quantity=1,unit_weight_kg=15)])
            images=json.dumps([dict(storage_path=photo,content_type='image/jpeg',size_bytes=100)])
            donation=self.lane.sql(f"SET request.jwt.claim.sub='{existing.DONOR}'; SET request.jwt.claim.role='authenticated'; INSERT INTO storage.objects(bucket_id,name,metadata) VALUES('geolock-donation-images','{photo}','{{\"size\":100,\"mimetype\":\"image/jpeg\"}}'); SELECT public.create_donation_with_images('{request}','LOCAL SECOND','SYNTHETIC','LOCAL',3.01,101.01,'{items}'::jsonb,'102','{images}'::jsonb);")
            listing=self.lane.sql(f"SELECT listing_id FROM public.listings WHERE donation_id='{donation}';")
            self.lane.sql('SELECT public.process_listing_eligibility_refresh_jobs();')
            self.second_claim=self.session.rpc('claim_listing',{'p_listing':listing,'p_request':str(uuid4())})
            self.assertEqual(self.second_claim['outcome'],'SUCCESS')
        if three:
            request=str(uuid4());photo=f'{existing.DONOR}/pending/{request}/{uuid4()}.jpg'
            items=json.dumps([dict(category_id=existing.uid('category'),item_name='LOCAL THIRD PICKUP',quantity=1,unit_weight_kg=15)])
            images=json.dumps([dict(storage_path=photo,content_type='image/jpeg',size_bytes=100)])
            donation=self.lane.sql(f"SET request.jwt.claim.sub='{existing.DONOR}'; SET request.jwt.claim.role='authenticated'; INSERT INTO storage.objects(bucket_id,name,metadata) VALUES('geolock-donation-images','{photo}','{{\"size\":100,\"mimetype\":\"image/jpeg\"}}'); SELECT public.create_donation_with_images('{request}','LOCAL THIRD','SYNTHETIC','LOCAL',3.01,101.01,'{items}'::jsonb,'102','{images}'::jsonb);")
            listing=self.lane.sql(f"SELECT listing_id FROM public.listings WHERE donation_id='{donation}';")
            self.lane.sql('SELECT public.process_listing_eligibility_refresh_jobs();')
            self.third_claim=self.session.rpc('claim_listing',{'p_listing':listing,'p_request':str(uuid4())})
            self.assertEqual(self.third_claim['outcome'],'SUCCESS')
        self.vehicle=self.session.rpc('register_my_vehicle',{'p_request_id':str(uuid4()),'p_label':'LOCAL AUTO VAN',
          'p_vehicle_type':'VAN','p_capacity_kg':100,'p_fixed_cost_rm':10,'p_distance_cost_rm_per_km':1,
          'p_max_route_duration_min':240,'p_available':True})
        policy=json.loads((ROOT/'docs/stage8/stage-a/deployment-preparation/routing-initialization/policy.proposed.json').read_text())
        policy['solver']['time_limit_seconds']=0.1
        graph=worker_rpc(self.lane.port,self.db,'geolock_graph_worker')
        # Installation/freezing exist only in this isolated fixture setup.
        with connect(self.lane.port,self.db,'geolock_graph_login') as conn:
            conn.execute('SET LOCAL ROLE geolock_graph_worker')
            pid=str(conn.execute('SELECT public.install_routing_policy(%s,%s::jsonb)',(str(uuid4()),json.dumps(policy))).fetchone()[0])
            gid=str(conn.execute('SELECT public.freeze_routing_graph(%s,%s,%s,%s)',(str(uuid4()),'OSM-OPS-LOCAL-SYNTHETIC','LOCAL SYNTHETIC','EXACT_MAX_6_DECIMALS')).fetchone()[0])
        self.request=str(uuid4());self.snapshot=self.session.rpc('begin_my_routing_snapshot',{
          'p_request':self.request,'p_policy':pid,'p_vehicle_ids':[self.vehicle['vehicle_id']]})
        self.sid=self.snapshot['snapshot_id'];self.aid=step_id(self.sid,'authorize-auto-now')
        token=secrets.token_urlsafe(32);parent,child=mp.get_context('spawn').Pipe(duplex=False)
        process=mp.get_context('spawn').Process(target=validator_process,args=(self.lane.port,self.db,token,child),daemon=True)
        process.start();child.close()
        self.addCleanup(lambda:(process.terminate(),process.join(10)))
        self.assertTrue(parent.poll(20));info=parent.recv();parent.close()
        self.worker=RoutingWorker(worker_rpc(self.lane.port,self.db,'geolock_planner'),
          GraphCache(graph,gid,Path(self.temp.name)/'graphs'),
          RemoteValidator('http://127.0.0.1:'+str(info['port']),token),Journal(Path(self.temp.name)/'journal'))
        return self

    def authorize(self):
        result=self.worker.plan_and_authorize(self.session,self.sid,self.request)
        self.receipt=result['authorization'];self.rid=self.receipt['route_ids'][0]
        return result

    def test_full_combined_then_ordered_pickup_depot_return(self):
        self.prepare();result=self.authorize()
        detail=self.session.rpc('get_my_authorized_route',{'p_route':self.rid})
        self.assertTrue(detail['authorization_confirmed']);self.assertIsNone(detail['actual_started_at'])
        self.assertEqual(detail['depot']['latitude'],self.snapshot['body']['ngo']['latitude'])
        self.assertEqual(result['planning']['validation_status'],'ATTESTED')
        self.session.rpc('start_pickup',{'p_claim':self.claim['claim_id']})
        started=self.session.rpc('get_my_authorized_route',{'p_route':self.rid})
        self.assertIsNotNone(started['actual_started_at']);self.assertTrue(started['stops'][0]['can_complete'])
        self.session.rpc('complete_pickup',{'p_claim':self.claim['claim_id'],'p_handover_confirmed':True})
        self.session.rpc('close_my_collected_route',{'p_route':self.rid,'p_depot_return_confirmed':True})
        self.assertEqual(self.lane.sql('SELECT route_status FROM public.pickup_routes;'),'COMPLETED')
        self.lane.save('flutter-combined-capture.json',{'authorization':result,'ready_detail':detail,'started_detail':started})

    def test_concurrent_same_request_one_route_one_audit_and_replay(self):
        self.prepare();plan=self.worker.plan(self.session,self.sid,self.request)
        params={'p_request':self.aid,'p_candidate':plan['candidate_id'],'p_depart_at':None}
        with ThreadPoolExecutor(max_workers=2) as pool: receipts=list(pool.map(lambda _:self.session.rpc('authorize_my_routing_candidate',params),range(2)))
        self.assertEqual(receipts[0],receipts[1]);self.assertEqual(self.lane.sql('SELECT count(*) FROM public.pickup_routes;'),'1')
        self.assertEqual(self.lane.sql("SELECT count(*) FROM public.audit_events WHERE event_type='AUTHORIZE_ROUTING';"),'1')
        self.assertEqual(self.session.rpc('get_my_routing_authorization_receipt',{'p_request':self.aid})['result'],receipts[0])

    def test_lost_authorization_response_read_only_reconciliation_no_new_plan(self):
        self.prepare();actual=self.session;lost=[False]
        class LoseResponse:
            user_id=actual.user_id
            def rpc(inner,name,params=None):
                value=actual.rpc(name,params)
                if name=='authorize_my_routing_candidate' and not lost[0]:
                    lost[0]=True;raise TimeoutError('synthetic commit response loss')
                return value
        with self.assertRaises(TimeoutError):self.worker.plan_and_authorize(LoseResponse(),self.sid,self.request)
        before=self.lane.sql('SELECT count(*) FROM public.audit_events;')
        result=self.worker.authorization_result(self.session,self.sid,self.request)
        self.assertEqual(result['kind'],'DATABASE_AUTHORIZATION_RECEIPT')
        self.worker.solve=lambda _:self.fail('No replanning after lost response')
        self.assertEqual(self.worker.plan_and_authorize(self.session,self.sid,self.request)['authorization'],result['authorization'])
        self.assertEqual(self.lane.sql('SELECT count(*) FROM public.audit_events;'),before)

    def test_owner_scoped_receipt_and_worker_permissions(self):
        self.prepare();self.authorize()
        other=Session(self.lane.port,self.db,existing.uid('foreign-ngo'))
        self.assertEqual(other.rpc('get_my_routing_authorization_receipt',{'p_request':self.aid})['outcome'],'NOT_FOUND')
        for role in ['anon','service_role','geolock_planner','geolock_validator','geolock_graph_worker']:
            self.assertEqual(self.lane.sql(f"SELECT has_function_privilege('{role}','public.get_my_routing_authorization_receipt(uuid)','EXECUTE');"),'f')

    def test_explicit_departure_preserved_and_past_rejected(self):
        self.prepare();plan=self.worker.plan(self.session,self.sid,self.request)
        past=(datetime.now(timezone.utc)-timedelta(minutes=1)).isoformat()
        with self.assertRaises(psycopg.Error) as invalid:
            self.session.rpc('authorize_my_routing_candidate',{'p_request':str(uuid4()),'p_candidate':plan['candidate_id'],'p_depart_at':past})
        self.assertEqual(invalid.exception.diag.message_primary,'INVALID_DEPARTURE')
        future=(datetime.now(timezone.utc)+timedelta(minutes=1)).isoformat()
        receipt=self.session.rpc('authorize_my_routing_candidate',{'p_request':str(uuid4()),'p_candidate':plan['candidate_id'],'p_depart_at':future})
        self.assertNotIn('departure_mode',receipt)
        self.assertEqual(set(receipt),{'route_ids','candidate_id'})

    def test_auto_clock_is_selected_after_vehicle_lock_and_replay_cannot_change_mode(self):
        self.prepare();plan=self.worker.plan(self.session,self.sid,self.request)
        blocker=connect(self.lane.port,self.db,'postgres')
        blocker.execute('SELECT 1 FROM public.vehicles WHERE vehicle_id=%s FOR UPDATE',(self.vehicle['vehicle_id'],))
        params={'p_request':self.aid,'p_candidate':plan['candidate_id'],'p_depart_at':None}
        try:
            with ThreadPoolExecutor(max_workers=1) as pool:
                pending=pool.submit(self.session.rpc,'authorize_my_routing_candidate',params)
                time.sleep(.15)
                released=blocker.execute('SELECT clock_timestamp()').fetchone()[0];blocker.commit()
                receipt=pending.result(timeout=15)
        finally:blocker.close()
        self.assertGreaterEqual(datetime.fromisoformat(receipt['planned_departure_at']),released)
        with self.assertRaises(psycopg.Error) as conflict:
            self.session.rpc('authorize_my_routing_candidate',{**params,'p_depart_at':(datetime.now(timezone.utc)+timedelta(minutes=1)).isoformat()})
        self.assertEqual(conflict.exception.diag.message_primary,'REQUEST_CONFLICT')

    def test_two_stop_order_duplicate_start_and_actual_time_are_protected(self):
        self.prepare(two=True);self.authorize()
        detail=self.session.rpc('get_my_authorized_route',{'p_route':self.rid});first,second=detail['stops']
        self.assertTrue(first['can_start']);self.assertFalse(second['can_start'])
        self.assertIsNone(detail['actual_started_at']);time.sleep(.05)
        with self.assertRaises(psycopg.Error):self.session.rpc('start_pickup',{'p_claim':second['claim_id']})
        self.session.rpc('start_pickup',{'p_claim':first['claim_id']})
        started=self.session.rpc('get_my_authorized_route',{'p_route':self.rid})
        self.assertGreater(datetime.fromisoformat(started['actual_started_at']),datetime.fromisoformat(self.receipt['planned_departure_at']))
        for claim in (first['claim_id'],second['claim_id']):
            with self.assertRaises(psycopg.Error):self.session.rpc('start_pickup',{'p_claim':claim})
        self.session.rpc('complete_pickup',{'p_claim':first['claim_id'],'p_handover_confirmed':True})
        self.session.rpc('start_pickup',{'p_claim':second['claim_id']})
        self.assertEqual(self.session.rpc('get_my_authorized_route',{'p_route':self.rid})['actual_started_at'],started['actual_started_at'])
        self.session.rpc('complete_pickup',{'p_claim':second['claim_id'],'p_handover_confirmed':True})
        self.session.rpc('close_my_collected_route',{'p_route':self.rid,'p_depot_return_confirmed':True})
        self.assertEqual(self.lane.sql("SELECT count(*) FROM public.audit_events WHERE event_type='START_PICKUP';"),'2')

    def test_migration_replay_is_rejected_without_changing_functions(self):
        before=self.lane.sql("SELECT md5(pg_get_functiondef('public.authorize_my_routing_candidate(uuid,uuid,timestamptz)'::regprocedure));")
        self.lane.sql('',expected='AUTHORIZATION_BASELINE_DRIFT_OR_ALREADY_APPLIED',exact_bytes=(ROOT/MIGRATION).read_bytes())
        self.assertEqual(before,self.lane.sql("SELECT md5(pg_get_functiondef('public.authorize_my_routing_candidate(uuid,uuid,timestamptz)'::regprocedure));"))

    def test_http_combined_authorization_and_read_only_status(self):
        self.prepare()
        server=ThreadingHTTPServer(('127.0.0.1',0),make_handler(Application(auth=existing.LocalAuth(self.session),worker=self.worker,active=True,combined_enabled=True)))
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        try:
            url='http://127.0.0.1:'+str(server.server_port);client=JsonHttp()
            capability=client.request(url+'/v1/authorization-capabilities',token='local-synthetic-ngo',body={'request_id':self.request})
            self.assertTrue(capability['combined_generation_enabled'])
            result=client.request(url+'/v1/plan-and-authorize',token='local-synthetic-ngo',body={'request_id':self.request,'snapshot_id':self.sid,'authorize_on_success':True},timeout=30)
            self.assertEqual(result['kind'],'DATABASE_AUTHORIZATION_RECEIPT')
            count=self.lane.sql('SELECT count(*) FROM public.audit_events;')
            read=client.request(url+'/v1/authorization-result',token='local-synthetic-ngo',body={'request_id':self.request,'snapshot_id':self.sid})
            self.assertEqual(read['authorization'],result['authorization']);self.assertEqual(count,self.lane.sql('SELECT count(*) FROM public.audit_events;'))
        finally:server.shutdown();server.server_close();thread.join(5)

    def test_expired_before_authorization_rolls_back_everything(self):
        self.prepare();plan=self.worker.plan(self.session,self.sid,self.request)
        self.lane.sql("UPDATE public.claim_leases SET expires_at=clock_timestamp()-interval '1 second';")
        with self.assertRaises(psycopg.Error):self.session.rpc('authorize_my_routing_candidate',{'p_request':self.aid,'p_candidate':plan['candidate_id'],'p_depart_at':None})
        self.assertEqual(self.lane.sql('SELECT count(*) FROM public.pickup_routes;'),'0')
        self.assertEqual(self.lane.sql('SELECT count(*) FROM public.active_task_route_assignments;'),'0')
        self.assertEqual(self.session.rpc('get_my_routing_authorization_receipt',{'p_request':self.aid})['outcome'],'NOT_FOUND')

    def test_delay_revalidates_and_expired_start_changes_no_custody(self):
        self.prepare();self.authorize()
        self.lane.sql("UPDATE public.claim_leases SET expires_at=clock_timestamp()-interval '1 second';")
        with self.assertRaises(psycopg.Error):self.session.rpc('start_pickup',{'p_claim':self.claim['claim_id']})
        self.assertEqual(self.lane.sql('SELECT task_status FROM public.pickup_tasks;'),'PLANNED')
        self.assertEqual(self.lane.sql('SELECT started_at IS NULL FROM routing_private.bindings;'),'t')
        self.assertEqual(self.lane.sql('SELECT donation_status FROM public.donations;'),'CLAIMED')

    def test_rollback_after_authorization_leaves_no_receipt_or_routes(self):
        self.prepare();plan=self.worker.plan(self.session,self.sid,self.request)
        with connect(self.lane.port,self.db,'geolock_local_ngo_login') as conn:
            conn.execute('SET LOCAL ROLE authenticated');conn.execute("SELECT set_config('request.jwt.claim.sub',%s,true)",(self.session.user_id,))
            conn.execute('SELECT public.authorize_my_routing_candidate(%s,%s,NULL)',(self.aid,plan['candidate_id']))
            conn.rollback()
        self.assertEqual(self.lane.sql('SELECT count(*) FROM public.pickup_routes;'),'0')
        self.assertEqual(self.lane.sql('SELECT count(*) FROM routing_private.items;'),'0')
        self.assertEqual(self.session.rpc('get_my_routing_authorization_receipt',{'p_request':self.aid})['outcome'],'NOT_FOUND')

    def test_missing_attestation_cannot_authorize(self):
        from backend.routing.worker_service.errors import WorkerError
        self.prepare()
        class RejectBeforeAttestation:
            def validate(inner,*args): raise WorkerError('SYNTHETIC_VALIDATION_REJECTED',422)
        self.worker.validator=RejectBeforeAttestation()
        with self.assertRaises(WorkerError): self.worker.plan(self.session,self.sid,self.request)
        candidate=self.lane.sql('SELECT candidate_id FROM routing_private.candidates;')
        self.assertEqual(self.lane.sql('SELECT count(*) FROM routing_private.validations;'),'0')
        with self.assertRaises(psycopg.Error) as error:
            self.session.rpc('authorize_my_routing_candidate',{'p_request':self.aid,'p_candidate':candidate,'p_depart_at':None})
        self.assertEqual(error.exception.diag.message_primary,'VALIDATED_FEASIBLE_PLAN_REQUIRED')
        self.assertEqual(self.lane.sql('SELECT count(*) FROM public.pickup_routes;'),'0')

    def test_recorded_attestation_remains_immutable(self):
        self.prepare();self.worker.plan(self.session,self.sid,self.request)
        self.lane.sql('DELETE FROM routing_private.validations;',expected='ROUTING_ARTIFACT_IMMUTABLE')
        self.assertEqual(self.lane.sql('SELECT count(*) FROM routing_private.validations;'),'1')

    def test_vehicle_change_or_source_window_change_rejects_authorization(self):
        self.prepare();plan=self.worker.plan(self.session,self.sid,self.request)
        self.lane.sql(f"UPDATE public.vehicles SET payload_capacity_kg=1 WHERE vehicle_id='{self.vehicle['vehicle_id']}';")
        with self.assertRaises(psycopg.Error):self.session.rpc('authorize_my_routing_candidate',{'p_request':self.aid,'p_candidate':plan['candidate_id'],'p_depart_at':None})
        self.assertEqual(self.lane.sql('SELECT count(*) FROM public.pickup_routes;'),'0')

    def test_route_map_coordinates_remain_snapshot_bound_after_live_listing_change(self):
        self.prepare();self.authorize()
        before=self.session.rpc('get_my_authorized_route',{'p_route':self.rid})['stops'][0]
        self.lane.sql("UPDATE public.listings SET pickup_latitude=pickup_latitude+0.000001;")
        after=self.session.rpc('get_my_authorized_route',{'p_route':self.rid})['stops'][0]
        self.assertEqual(after['pickup_latitude'],before['pickup_latitude'])
        self.assertEqual(after['pickup_longitude'],before['pickup_longitude'])
        self.assertFalse(after['can_start'])

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--run-isolated',action='store_true',required=True);parser.add_argument('--runtime',type=Path,required=True);args=parser.parse_args()
    runtime=args.runtime.resolve();assert runtime.name.startswith('geolock-spatial-runtime-') and (runtime/'pgsql/bin/postgres.exe').is_file()
    import os
    for key in list(os.environ):
        if key.upper().startswith(('PG','GEOLOCK','SUPABASE')) or key.upper() in ('DATABASE_URL','DB_URL'):os.environ.pop(key,None)
    AutomaticTests.runtime=runtime
    result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(AutomaticTests))
    summary={'status':'PASS' if result.wasSuccessful() else 'FAIL','tests_run':result.testsRun,'failures':len(result.failures),'errors':len(result.errors),'remote_connections':0,'scope':'Fresh disposable PostgreSQL; synthetic auth/Storage/cron; real SQL/solver and independent validator process; not Supabase parity'}
    AutomaticTests.lane.save('test-result.json',summary);print(json.dumps({'evidence':str(AutomaticTests.out),**summary},indent=2));return not result.wasSuccessful()

if __name__=='__main__':mp.freeze_support();raise SystemExit(main())
