"""Disposable loopback-only integration. No DEV DSN, credentials or network accepted.

Uses real historical application SQL + unchanged Stage A migrations, real
PostGIS/pgRouting/OR-Tools and protected role RPCs. Auth/Storage/cron adapters
are explicit local doubles. Does not claim Supabase/Flutter live E2E parity.
"""
import argparse
from decimal import Decimal
from datetime import datetime,timezone,timedelta
import hashlib
import json
import multiprocessing as mp
import os
from pathlib import Path
import secrets
import sys
import threading
import time
import traceback
from uuid import UUID,uuid5

import stage8_stage_c5_isolated_test as assembly
from stage8_spatial_isolated_test import NGO,DONOR
ROOT=assembly.ROOT
sys.path.insert(0,str(ROOT))
import psycopg
from psycopg.rows import dict_row
from backend.routing.worker_service.transport import RoleRpc,JsonHttp
from backend.routing.worker_service.validator import Validator,RemoteValidator
from backend.routing.worker_service.graph_cache import GraphCache
from backend.routing.worker_service.journal import Journal
from backend.routing.worker_service.orchestrator import RoutingWorker
from backend.routing.worker_service.server import Application,make_handler
from http.server import ThreadingHTTPServer

NAMESPACE=UUID('116a91b7-31b8-4a5c-8816-731954eeed25')
def uid(label): return str(uuid5(NAMESPACE,label))

def connection(port,login):
    return psycopg.connect(host='127.0.0.1',hostaddr='127.0.0.1',port=port,
        dbname='postgres',user=login,sslmode='disable',options='',connect_timeout=3)

def role_rpc(port,scope):
    login={'geolock_graph_worker':'geolock_graph_login','geolock_planner':'geolock_planner_login',
           'geolock_validator':'geolock_validator_login'}[scope]
    return RoleRpc('',scope,connect=lambda:connection(port,login))

def validator_process(port,token,channel):
    server=ThreadingHTTPServer(('127.0.0.1',0),make_handler(Application(
       validator=Validator(role_rpc(port,'geolock_validator')),validator_token=token,active=True)))
    channel.send({'port':server.server_port,'pid':os.getpid()}); channel.close()
    server.serve_forever()

class NgoSession:
    """Real authenticated-role SQL RPCs; synthetic local auth.uid GUC, not JWT verification."""
    def __init__(self,port,user_id=NGO): self.port,self.user_id=port,user_id
    def rpc(self,name,params=None):
        allowed={'claim_listing','list_my_vehicles','get_my_claim_cards_v2','register_my_vehicle',
          'get_my_routing_overview','begin_my_routing_snapshot','authorize_my_routing_candidate',
          'get_my_authorized_route','start_pickup','complete_pickup','close_my_collected_route',
          'cancel_my_unstarted_route'}
        if name not in allowed: raise ValueError('LOCAL_RPC_NOT_ALLOWED')
        params=params or {}
        with connection(self.port,'geolock_local_ngo_login') as conn:
            with conn.cursor(row_factory=dict_row) as cur:
                cur.execute('SET LOCAL ROLE authenticated')
                cur.execute("SELECT set_config('request.jwt.claim.sub',%s,true),set_config('request.jwt.claim.role','authenticated',true)",(self.user_id,))
                args=','.join(key+' => %s' for key in params)
                # Parameter names come only from this fixture runner's fixed call sites.
                cur.execute('SELECT * FROM public.'+name+'('+args+')',list(params.values()))
                rows=cur.fetchall()
                if name=='get_my_claim_cards_v2':
                    # Match PostgREST JSON wire types, not psycopg UUID/datetime objects.
                    def wire(value):
                        if isinstance(value,datetime): return value.isoformat()
                        if isinstance(value,Decimal): return float(value)
                        return str(value)
                    return json.loads(json.dumps(rows,default=wire))
                if not rows: return None
                return next(iter(rows[0].values()))

class LocalAuth:
    def __init__(self,session): self.session=session
    def verify(self,bearer):
        if bearer!='Bearer local-synthetic-ngo': raise ValueError('LOCAL_AUTH_REJECTED')
        return self.session

def setup_fixture(lane):
    lane.sql(f"""INSERT INTO auth.users(id,email) VALUES('{NGO}','ngo@local.invalid'),('{DONOR}','donor@local.invalid');
     INSERT INTO public.user_profiles(user_id,full_name,role) VALUES('{NGO}','LOCAL NGO','NGO'),('{DONOR}','LOCAL DONOR','DONOR');
     INSERT INTO public.ngo_profiles(user_id,ngo_name,operating_address,latitude,longitude,road_node_id,location_verified_at)
       VALUES('{NGO}','LOCAL NGO','LOCAL',3,101,'101',now());
     INSERT INTO public.donor_profiles(user_id) VALUES('{DONOR}');
     INSERT INTO public.donation_categories(category_id,category_name,active_flag) VALUES('{uid('category')}','LOCAL',true);
     UPDATE public.road_network_edges SET road_km=1,travel_minutes=1;
     INSERT INTO public.road_network_edges(source_node,target_node,road_km,travel_minutes) VALUES(102,101,1,1);
     CREATE ROLE geolock_graph_login LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
     CREATE ROLE geolock_planner_login LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
     CREATE ROLE geolock_validator_login LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
     CREATE ROLE geolock_local_ngo_login LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
     GRANT geolock_graph_worker TO geolock_graph_login;
     GRANT geolock_planner TO geolock_planner_login;
     GRANT geolock_validator TO geolock_validator_login;
     GRANT authenticated TO geolock_local_ngo_login;
     -- Supabase's platform schema USAGE is outside the public-only dump.
     -- Reproduce that platform baseline locally, without table writes/worker grants.
     GRANT USAGE ON SCHEMA public TO anon,authenticated,service_role;""")
    other=uid('foreign-ngo')
    lane.sql(f"INSERT INTO auth.users(id,email) VALUES('{other}','other@local.invalid'); "
      f"INSERT INTO public.user_profiles(user_id,full_name,role) VALUES('{other}','OTHER LOCAL NGO','NGO'); "
      f"INSERT INTO public.ngo_profiles(user_id,ngo_name,operating_address,latitude,longitude,road_node_id,location_verified_at) "
      f"VALUES('{other}','OTHER LOCAL NGO','LOCAL',3,101,'101',now());")
    # Install only the exact reader block; no fake pg_extension/real cron daemon.
    reader=(ROOT/'supabase/migrations/20261028_claim_card_expiry_and_paused_recovery.sql').read_text()
    reader=reader[reader.index('create function public.get_my_claim_cards_v2()'):reader.index('-- Reject unexpected default-privilege recipients')]
    lane.sql(reader)
    request=uid('donation-request'); photo=f'{DONOR}/pending/{request}/{uid("image")}.jpg'
    items=json.dumps([dict(category_id=uid('category'),item_name='LOCAL FOOD',quantity=1,unit_weight_kg=20)])
    images=json.dumps([dict(storage_path=photo,content_type='image/jpeg',size_bytes=100)])
    donation=lane.sql(f"SET request.jwt.claim.sub='{DONOR}'; SET request.jwt.claim.role='authenticated'; "
      f"INSERT INTO storage.objects(bucket_id,name,metadata) VALUES('geolock-donation-images','{photo}','{{\"size\":100,\"mimetype\":\"image/jpeg\"}}'); "
      f"SELECT public.create_donation_with_images('{request}','LOCAL ROUTING','SYNTHETIC','LOCAL',3.01,101.01,'{items}'::jsonb,'102','{images}'::jsonb);")
    listing=lane.sql(f"SELECT listing_id FROM public.listings WHERE donation_id='{donation}';")
    lane.sql('SELECT public.process_listing_eligibility_refresh_jobs();')
    lane.save('source-fixture.json',dict(synthetic=True,ngo=NGO,donor=DONOR,donation=donation,listing=listing))
    return donation,listing

def run(lane):
    print('LOCAL bootstrap: unchanged historical SQL + A001/A002/A003',flush=True)
    lane.freeze(); lane.start(); lane.assemble()
    lane.apply(assembly.AUTHORITY+assembly.A_FILES[2])  # this NEW local cluster only
    donation,listing=setup_fixture(lane)
    session=NgoSession(lane.port)
    claim=session.rpc('claim_listing',{'p_listing':listing,'p_request':uid('claim-request')})
    lane.save('claim.json',claim)
    assert claim['outcome']=='SUCCESS',claim
    replay=session.rpc('claim_listing',{'p_listing':listing,'p_request':uid('claim-request')})
    assert replay['claim_id']==claim['claim_id'] and replay['replayed'] is True
    assert lane.sql('SELECT count(*) FROM public.donation_claims;')=='1'
    negatives=['claim_request_replay_no_duplicate']
    try:
        with connection(lane.port,'geolock_graph_login') as conn:
            conn.execute('SET LOCAL ROLE geolock_graph_worker')
            conn.execute('SELECT public.start_pickup(%s)',(claim['claim_id'],))
    except psycopg.Error as error: assert error.sqlstate=='42501'
    else: raise AssertionError('WORKER_PICKUP_EXECUTE_WAS_NOT_DENIED')
    negatives.append('worker_cannot_dispatch')
    print('LOCAL claim RPC: SUCCESS',flush=True)
    vehicle=session.rpc('register_my_vehicle',{'p_request_id':uid('vehicle-request'),'p_label':'LOCAL VAN',
        'p_vehicle_type':'VAN','p_capacity_kg':100,'p_fixed_cost_rm':10,'p_distance_cost_rm_per_km':1,
        'p_max_route_duration_min':240,'p_available':True})
    policy=json.loads((ROOT/'docs/stage8/stage-a/deployment-preparation/routing-initialization/policy.proposed.json').read_text())
    policy['solver']['time_limit_seconds']=1  # fixture-only fast solve; proposed DEV file unchanged
    lane.save('local-policy.json',policy)
    with connection(lane.port,'geolock_graph_login') as conn:
        conn.execute('SET LOCAL ROLE geolock_graph_worker')
        pid=str(conn.execute('SELECT public.install_routing_policy(%s,%s::jsonb)',(uid('policy-request'),json.dumps(policy))).fetchone()[0])
        gid=str(conn.execute('SELECT public.freeze_routing_graph(%s,%s,%s,%s)',
          (uid('graph-request'),'OSM-OPS-LOCAL-SYNTHETIC','EXPLICIT LOCAL SYNTHETIC 1KM/1MIN ARCS','EXACT_MAX_6_DECIMALS')).fetchone()[0])
    # Unrouted pickup is rejected by the installed 003 authority guard.
    try: session.rpc('start_pickup',{'p_claim':claim['claim_id']})
    except psycopg.Error as error: assert error.diag.message_primary=='DATABASE_DISPATCH_AUTHORIZATION_REQUIRED'
    else: raise AssertionError('UNROUTED_PICKUP_WAS_NOT_REJECTED')
    negatives.append('unrouted_start_rejected')
    request=uid('snapshot-request')
    snapshot=session.rpc('begin_my_routing_snapshot',{'p_request':request,'p_policy':pid,'p_vehicle_ids':[vehicle['vehicle_id']]})
    lane.save('snapshot.json',snapshot)
    # Validator runs in its own OS process with its own restricted DB login.
    token=secrets.token_urlsafe(32)
    parent,child=mp.get_context('spawn').Pipe(duplex=False)
    validator=mp.get_context('spawn').Process(target=validator_process,args=(lane.port,token,child),daemon=True)
    validator.start(); child.close()
    planner_server=None; thread=None
    try:
        assert parent.poll(20),'LOCAL_VALIDATOR_START_TIMEOUT'
        validation_identity=parent.recv(); assert validation_identity['pid']!=os.getpid()
        parent.close()
        graph=GraphCache(role_rpc(lane.port,'geolock_graph_worker'),gid,lane.out/'graph-cache')
        worker=RoutingWorker(role_rpc(lane.port,'geolock_planner'),graph,
           RemoteValidator('http://127.0.0.1:'+str(validation_identity['port']),token),Journal(lane.out/'journal'))
        planner_server=ThreadingHTTPServer(('127.0.0.1',0),make_handler(Application(auth=LocalAuth(session),worker=worker,active=True)))
        thread=threading.Thread(target=planner_server.serve_forever,daemon=True); thread.start()
        url='http://127.0.0.1:'+str(planner_server.server_port)
        print('LOCAL planner HTTP -> independent validator process -> protected RPCs',flush=True)
        planned=JsonHttp().request(url+'/v1/plan',token='local-synthetic-ngo',body={'request_id':request,'snapshot_id':snapshot['snapshot_id']},timeout=120)
        lane.save('planning-response.json',planned)
        assert planned['outcome']=='CANDIDATE_READY' and planned['validation_status']=='ATTESTED',planned
        assert planned['dispatch_authority_issued'] is False
        assert lane.sql('SELECT count(*) FROM public.pickup_routes;')=='0'
        assert lane.sql('SELECT count(*) FROM routing_private.validations;')=='1'
        matrix=lane.js('SELECT body FROM routing_private.matrices;')
        assert matrix['distance_km']==[[0,1],[1,0]] and matrix['travel_minutes']==[[0,1],[1,0]]
        lane.save('matrix.json',matrix)
        attestation=lane.js('SELECT to_jsonb(v) FROM routing_private.validations v;')
        lane.save('attestation.json',attestation)
        departure=(worker.planner.now()+timedelta(seconds=2)).isoformat()
        authorized=session.rpc('authorize_my_routing_candidate',{'p_request':uid('authorize-request'),
           'p_candidate':planned['candidate_id'],'p_depart_at':departure})
        rid=authorized['route_ids'][0]
        detail=session.rpc('get_my_authorized_route',{'p_route':rid})
        assert detail['contract']=='geolock.ngo-routing.v1' and detail['authorization_confirmed'] is True
        assert detail['route_status']=='AUTHORISED' and len(detail['stops'])==1
        try: NgoSession(lane.port,uid('foreign-ngo')).rpc('get_my_authorized_route',{'p_route':rid})
        except psycopg.Error as error: assert error.diag.message_primary=='OWNED_MANAGED_ROUTE_NOT_FOUND'
        else: raise AssertionError('FOREIGN_ROUTE_VISIBILITY_NOT_DENIED')
        negatives.append('foreign_ngo_route_read_denied')
        capture={'scope':'REAL LOCAL DATABASE/HTTP RESULTS; synthetic Auth adapter, not live Supabase',
          'ngo_id':NGO,'claim':claim,'vehicle':vehicle,'policy_id':pid,'snapshot':snapshot,
          'planning':planned,'authorization':authorized,'authorized_detail':detail,
          'departure_at':departure,'route_id':rid,'donation_id':donation,'listing_id':listing,
          'validator_process':validation_identity}
        wait=max(0,(datetime.fromisoformat(departure)-datetime.now(timezone.utc)).total_seconds())
        if wait: time.sleep(min(wait+.05,3))
        detail=session.rpc('get_my_authorized_route',{'p_route':rid})
        assert detail['stops'][0]['can_start'] is True,detail
        capture['ready_detail']=detail
        session.rpc('start_pickup',{'p_claim':claim['claim_id']})
        capture['started_detail']=session.rpc('get_my_authorized_route',{'p_route':rid})
        assert capture['started_detail']['stops'][0]['can_complete'] is True
        audit_before=lane.sql('SELECT count(*) FROM public.audit_events;')
        try: session.rpc('complete_pickup',{'p_claim':claim['claim_id'],'p_handover_confirmed':False})
        except psycopg.Error as error: assert error.diag.message_primary=='HANDOVER_NOT_CONFIRMED'
        else: raise AssertionError('HANDOVER_CONFIRMATION_BYPASSED')
        assert lane.sql('SELECT count(*) FROM public.audit_events;')==audit_before
        assert lane.sql('SELECT task_status FROM public.pickup_tasks;')=='DISPATCHED'
        negatives.append('unconfirmed_handover_rolls_back_without_audit_or_state_delta')
        session.rpc('complete_pickup',{'p_claim':claim['claim_id'],'p_handover_confirmed':True})
        capture['collected_detail']=session.rpc('get_my_authorized_route',{'p_route':rid})
        assert capture['collected_detail']['can_close'] is True
        assert lane.sql('SELECT count(*) FROM public.active_task_route_assignments;')=='1','Hold released before depot return'
        try: session.rpc('close_my_collected_route',{'p_route':rid,'p_depot_return_confirmed':False})
        except psycopg.Error as error: assert error.diag.message_primary=='DEPOT_RETURN_CONFIRMATION_REQUIRED'
        else: raise AssertionError('DEPOT_CONFIRMATION_BYPASSED')
        negatives.append('depot_return_confirmation_required')
        session.rpc('close_my_collected_route',{'p_route':rid,'p_depot_return_confirmed':True})
        capture['closed_detail']=session.rpc('get_my_authorized_route',{'p_route':rid})
        final=lane.js("SELECT jsonb_build_object('task',(SELECT task_status FROM public.pickup_tasks),"
           "'claim',(SELECT claim_status FROM public.donation_claims),'lease',(SELECT lease_status FROM public.claim_leases),"
           "'donation',(SELECT donation_status FROM public.donations),'route',(SELECT route_status FROM public.pickup_routes),"
           "'assignments',(SELECT count(*) FROM public.active_task_route_assignments),"
           "'vehicle_hold',(SELECT fleet_private.vehicle_has_hold(vehicle_id) FROM public.vehicles),"
           "'audit_events',(SELECT jsonb_agg(to_jsonb(a) ORDER BY occurred_at,event_id) FROM public.audit_events a));")
        lane.save('final-state.json',final)
        assert final['task']=='COLLECTED' and final['claim']==final['lease']=='COMPLETED'
        assert final['donation']=='COLLECTED' and final['route']=='COMPLETED'
        assert final['assignments']==0 and final['vehicle_hold'] is False
        events={e['event_type'] for e in final['audit_events']}
        assert {'CLAIM_ATTEMPT','AUTHORIZE_ROUTING','START_PICKUP','COMPLETE_PICKUP','CLOSE_COLLECTED_ROUTE'}<=events,events
        transitions=[e for e in final['audit_events'] if e['event_type']=='DONATION_STATUS_CHANGED']
        assert [(e['previous_state'],e['resulting_state']) for e in transitions]==[
            ('AVAILABLE','CLAIMED'),('CLAIMED','PICKUP_IN_PROGRESS'),('PICKUP_IN_PROGRESS','COLLECTED')]
        assert all(e['actor_user_id']==NGO and e['actor_role']=='NGO' and e['entity_id']==donation
            and e['claim_id']==claim['claim_id'] and e['lease_id'] is not None and e['outcome']=='SUCCESS' for e in transitions)
        negatives.append('audit_transition_actor_claim_and_lease_context_verified')
        capture['final_state']=final; lane.save('flutter-contract-capture.json',capture)
        print('LOCAL pickup/complete/depot closure: PASS',flush=True)
        return {'status':'PASS','claim_id':claim['claim_id'],'route_id':rid,
           'real_http_planner':True,'separate_validator_process':True,'real_claim_rpc':True,
           'actual_route_payload':'flutter-contract-capture.json','negative_and_replay_checks':negatives,'final_state':final}
    finally:
        if planner_server is not None: planner_server.shutdown(); planner_server.server_close()
        if thread is not None: thread.join(5)
        if validator.is_alive(): validator.terminate()
        validator.join(10)
        lane.save('worker-cleanup.json',{'validator_stopped':not validator.is_alive(),
          'planner_thread_stopped':thread is None or not thread.is_alive()})
        assert not validator.is_alive() and (thread is None or not thread.is_alive())

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-local',action='store_true',required=True)
    parser.add_argument('--runtime',type=Path,required=True)
    args=parser.parse_args(); runtime=args.runtime.resolve()
    # This process and its local children cannot inherit remote DB credentials/options.
    for key in list(os.environ):
        if key.upper().startswith(('PG','SUPABASE','GEOLOCK')) or key.upper() in ('DATABASE_URL','DB_URL'):
            os.environ.pop(key,None)
    if not runtime.name.startswith('geolock-spatial-runtime-') or not (runtime/'pgsql/bin/postgres.exe').is_file():
        parser.error('Existing private portable runtime required, never an existing database/DSN')
    out=ROOT/'results/postclaim-local-e2e'/(datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-'+secrets.token_hex(3))
    out.mkdir(parents=True,exist_ok=False); (out/'sql').mkdir()
    lane=assembly.Lane(runtime,out); result={'status':'FAIL / INCOMPLETE'}
    try: result=run(lane)
    except BaseException as error:
        result.update(error=str(error),traceback=traceback.format_exc()); print(traceback.format_exc(),flush=True)
    finally:
        if lane.started:
            code,message=lane.process('pg_ctl',['-D',str(lane.data),'-m','fast','-w','-t','25','stop'])
            result['cluster_stopped']=code==0 and not (lane.data/'postmaster.pid').exists()
        result.update(remote_database_connections=0,source_sql_modified=False,
          scope='LOCAL REAL DATABASE CONTRACTS; synthetic auth/storage/inert cron; NON-PARITY GIS versions',
          elapsed_seconds=round(time.monotonic()-lane.begin,3))
        lane.verify_frozen()
        lane.save('result.json',result)
        brief={k:v for k,v in result.items() if k not in ('traceback','final_state')}
        print(json.dumps({'output':str(out),**brief},indent=2),flush=True)
    return 0 if result['status']=='PASS' and result.get('cluster_stopped') else 1

if __name__=='__main__': mp.freeze_support(); raise SystemExit(main())
