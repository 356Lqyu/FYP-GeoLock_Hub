"""LOCAL ONLY: fresh loopback cluster; reduced schema, synthetic auth double.

Executes exact proposals and captured legacy functions. No DSN/network options,
no Supabase clients, no PostGIS or deployed recovery/claim trigger coverage.
"""
from pathlib import Path
from dataclasses import asdict
import argparse
import json
import shutil
import sys
import unittest
import uuid

import stage8_c1_fleet_isolated_test as base

ROOT = base.ROOT
sys.path.insert(0, str(ROOT))
from backend.routing.integration import prepare_bundle, solve_bundle, validate_work_item

HERE = ROOT/'docs/stage8/integration'
E = json.loads((HERE/'dev-preparation-evidence.json').read_text())
A, B = base.A, base.B


def fixture_extension():
    # Actual captured column names/types, reduced nullability/FKs and no geography.
    # This is deliberately NOT a full deployed-schema or auth integration test.
    existing = {
        'ngo_profiles': {'user_id','role','road_node_id','active_flag','location_verified_at','location_generation'},
        'road_network_nodes': {'osm_node_id','network_snapshot_id','active_flag'},
        'road_network_coverage': {'network_snapshot_id','active_flag','dataset_kind','approved_at'},
        'pickup_routes': {'route_id','ngo_user_id','vehicle_id','route_status'},
        'audit_events': {'event_id','actor_user_id','actor_role','entity_type','entity_id','event_type','outcome','details'},
    }
    keys = dict(pickup_tasks='task_id', listings='listing_id', donations='donation_id',
                donation_claims='claim_id', claim_leases='lease_id', hub_batches='batch_id')
    sql = []
    for table in sorted({r['table_name'] for r in E['columns']}):
        columns = [r for r in E['columns'] if r['table_name']==table and r['data_type']!='USER-DEFINED']
        if table not in existing:
            sql.append('CREATE TABLE public.'+table+'('+','.join(r['column_name']+' '+r['data_type'] +
                       (' PRIMARY KEY' if keys.get(table)==r['column_name'] else '')+
                       (' DEFAULT '+r['column_default'] if r['column_default'] else '') for r in columns)+');')
        else:
            for r in columns:
                if r['column_name'] not in existing[table]:
                    sql.append('ALTER TABLE public.'+table+' ADD COLUMN '+r['column_name']+' '+r['data_type']+
                               (' DEFAULT '+r['column_default'] if r['column_default'] else '')+';')
    sql += [
        'ALTER TABLE public.active_task_route_assignments ADD PRIMARY KEY(task_id);',
        'ALTER TABLE public.pickup_route_stops ADD PRIMARY KEY(route_id,stop_order);',
        'ALTER TABLE public.claim_leases ADD UNIQUE(claim_id);',
        'ALTER TABLE public.pickup_tasks ADD UNIQUE(claim_id);',
        'CREATE TABLE public.community_hubs(hub_id uuid PRIMARY KEY,road_node_id text,latitude numeric,longitude numeric,active_flag boolean);',
        "UPDATE public.ngo_profiles SET latitude=3,longitude=101;",
    ]
    for name in ('geolock_lock_listing_donations','geolock_transition_listing_donations','start_pickup','complete_pickup','assign_task_to_route'):
        sql.append(next(f['definition'] for f in E['functions'] if f['name']==name)+';')
    return '\n'.join(sql)


class IntegrationTests(unittest.TestCase):
    bins = {n:shutil.which(n) for n in ('initdb','pg_ctl','psql')}
    run_process = base.FleetTests.__dict__['run_process']
    query = base.FleetTests.__dict__['query']
    cleanup = base.FleetTests.__dict__['cleanup']
    concurrent = base.FleetTests.__dict__['concurrent']
    db = 'postgres'

    @classmethod
    def args(cls, sql):
        result=base.FleetTests.args.__func__(cls,sql)
        result[result.index('-d')+1]=cls.db
        return result

    @classmethod
    def setUpClass(cls):
        if not all(cls.bins.values()): raise RuntimeError('Local PostgreSQL binaries required')
        base.SQL=(base.FOLDER/'proposed_migration_v2.sql').read_text()
        base.FIXTURE=base.FIXTURE.replace('synthetic-operational-fixture','OSM-OPS-ISOLATED-SYNTHETIC')+fixture_extension()
        base.FleetTests.setUpClass.__func__(cls)
        for name in ('001_authority_proposal.sql','002_publication_proposal.sql','003_pickup_enforcement_proposal.sql'):
            cls.query((HERE/name).read_text())
        cls.db='template1'

    def setUp(self):
        self.database='routing_test_'+uuid.uuid4().hex
        type(self).db='template1'
        self.query('CREATE DATABASE '+self.database+' TEMPLATE postgres;')
        type(self).db=self.database
        self.addCleanup(self.drop_fixture)

    def drop_fixture(self):
        type(self).db='template1'
        self.query('DROP DATABASE '+self.database+';')

    def rpc(self, call, role='authenticated', user=A, error=None):
        return self.query(f"BEGIN; SET LOCAL ROLE {role}; SET LOCAL request.jwt.claim.sub='{user}'; SELECT {call}; COMMIT;",error)

    def jrpc(self,call,**kw): return json.loads(self.rpc(call,**kw))
    def req(self): return str(uuid.uuid4())
    def literal(self,obj): return "'"+json.dumps(obj).replace("'","''")+"'::jsonb"

    def prepare(self,hub=False,two=False,window_start_delay=-60,window_length=None,hub_members=1):
        v=self.jrpc(f"public.register_my_vehicle('{self.req()}','SYNTHETIC LOCAL','VAN',100,10,1,60,true)")
        did,lid,cid,leid,tid=[self.req() for _ in range(5)]
        self.query(f"""
        INSERT INTO public.donations(donation_id,collection_path,donation_status,pickup_road_node_id,total_weight_kg,latitude,longitude,availability_start,availability_end,updated_at)
        VALUES('{did}','DIRECT_PICKUP','CLAIMED','102',10,3,101,now()+make_interval(mins=>{window_start_delay}),now()+make_interval(mins=>{300 if window_length is None else window_start_delay+window_length}),now());
        INSERT INTO public.listings(listing_id,source_type,donation_id,listing_status,listing_weight_kg,pickup_road_node_id,pickup_latitude,pickup_longitude,listing_version)
        VALUES('{lid}','DIRECT_DONATION','{did}','CLAIMED',10,'102',3,101,2);
        INSERT INTO public.donation_claims(claim_id,listing_id,ngo_user_id,claim_status,claimed_at) VALUES('{cid}','{lid}','{A}','ACTIVE',now());
        INSERT INTO public.claim_leases(lease_id,claim_id,lease_status,issued_at,expires_at) VALUES('{leid}','{cid}','ACTIVE',now(),now()+interval '6 hours');
        INSERT INTO public.pickup_tasks(task_id,claim_id,listing_id,ngo_user_id,pickup_road_node_id,load_kg,task_status,created_at)
        VALUES('{tid}','{cid}','{lid}','{A}','102',10,'CONFIRMED',now());
        """)
        if hub:
            hid,bid=self.req(),self.req()
            self.query(f"""INSERT INTO public.community_hubs VALUES('{hid}','102',3,101,true);
            INSERT INTO public.hub_batches(batch_id,hub_id,batch_status,batch_weight_kg,batch_donation_count,batch_version) VALUES('{bid}','{hid}','PUBLISHED',10,1,1);
            INSERT INTO public.hub_batch_members(batch_id,hub_id,donation_id,membership_status) VALUES('{bid}','{hid}','{did}','ACTIVE');
            INSERT INTO public.hub_inventory(donation_id,hub_id,inventory_status) VALUES('{did}','{hid}','BATCHED');
            UPDATE public.donations SET collection_path='HUB_COLLECTION' WHERE donation_id='{did}';
            UPDATE public.listings SET source_type='HUB_BATCH',donation_id=NULL,batch_id='{bid}' WHERE listing_id='{lid}';""")
            if not 1 <= hub_members <= 10:
                raise ValueError('hub_members must be between one and ten')
            if hub_members > 1:
                members=[self.req() for _ in range(hub_members-1)]
                inserts=[]
                for member in members:
                    inserts.append(f"""INSERT INTO public.donations(
                      donation_id,collection_path,donation_status,pickup_road_node_id,
                      total_weight_kg,latitude,longitude,availability_start,availability_end,updated_at)
                      VALUES('{member}','HUB_COLLECTION','CLAIMED','102',10,3,101,
                      now()+make_interval(mins=>{window_start_delay}),
                      now()+make_interval(mins=>{300 if window_length is None else window_start_delay+window_length}),now());
                      INSERT INTO public.hub_batch_members(batch_id,hub_id,donation_id,membership_status)
                      VALUES('{bid}','{hid}','{member}','ACTIVE');
                      INSERT INTO public.hub_inventory(donation_id,hub_id,inventory_status)
                      VALUES('{member}','{hid}','BATCHED');""")
                self.query('\n'.join(inserts)+f"""
                  UPDATE public.hub_batches SET batch_weight_kg={10*hub_members},batch_donation_count={hub_members} WHERE batch_id='{bid}';
                  UPDATE public.listings SET listing_weight_kg={10*hub_members} WHERE listing_id='{lid}';
                  UPDATE public.pickup_tasks SET load_kg={10*hub_members} WHERE task_id='{tid}';""")
        if two:
            d2,l2,c2,le2,t2=[self.req() for _ in range(5)]
            for table,where,changes in [
                ('donations',f"donation_id='{did}'",dict(donation_id=d2)),
                ('listings',f"listing_id='{lid}'",dict(listing_id=l2,donation_id=d2)),
                ('donation_claims',f"claim_id='{cid}'",dict(claim_id=c2,listing_id=l2)),
                ('claim_leases',f"lease_id='{leid}'",dict(lease_id=le2,claim_id=c2)),
                ('pickup_tasks',f"task_id='{tid}'",dict(task_id=t2,claim_id=c2,listing_id=l2))]:
                self.query(f"INSERT INTO public.{table} SELECT (jsonb_populate_record(NULL::public.{table},to_jsonb(x)||{self.literal(changes)})).* FROM public.{table} x WHERE {where};")
        from backend.routing.generate_examples import build_mixed
        import ortools
        solver=build_mixed()['solver']; solver['version']=ortools.__version__; solver['time_limit_seconds']=3
        policy=dict(mandatory=True,horizon_minutes=120,dispatch_margin_minutes=5,direct_service_minutes=1,hub_service_minutes=2,
                    solver=solver,execution=dict(fixed_cost_weight=1,distance_cost_weight=1,deterministic_seconds_per_pass=.05))
        pid=self.rpc(f"public.install_routing_policy('{self.req()}',{self.literal(policy)})",role='geolock_graph_worker')
        gid=self.rpc(f"public.freeze_routing_graph('{self.req()}','OSM-OPS-ISOLATED-SYNTHETIC','EXPLICIT LOCAL EDGE TIMES','EXACT_MAX_6_DECIMALS')",role='geolock_graph_worker')
        matrix=dict(matrix_id='LOCAL-SYNTHETIC-ONLY',version='1',network_snapshot_id='OSM-OPS-ISOLATED-SYNTHETIC',source_kind='OPERATIONAL_ROAD_NETWORK',
                    provenance='ISOLATED SYNTHETIC DATABASE FIXTURE; not live road measurements',method='Directed explicit fixture arcs',edge_speed_profile='EXPLICIT LOCAL EDGE TIMES',
                    path_policy='DIRECTED_SHORTEST_DISTANCE_WITH_TIME_ON_SAME_PATH',unavailable_policy='FAIL_SCENARIO',node_order=['101','102'],
                    distance_km=[[0,1],[1,0]],travel_minutes=[[0,1],[1,0]],arc_status=[['AVAILABLE']*2]*2)
        mid=self.rpc(f"public.store_routing_matrix('{self.req()}','{gid}',{self.literal(matrix)})",role='geolock_graph_worker')
        snapshot=self.jrpc(f"public.begin_my_routing_snapshot('{self.req()}','{pid}')")
        snapshot=self.jrpc(f"public.seal_routing_snapshot('{snapshot['snapshot_id']}','{mid}')",role='geolock_planner')
        bundle=self.jrpc(f"public.read_routing_snapshot_bundle('{snapshot['snapshot_id']}')",role='geolock_planner')
        comparison=solve_bundle(bundle)
        self.assertEqual(len(comparison.results),3)
        self.assertIsNotNone(comparison.proposed_candidate)
        body=dict(plan=asdict(comparison.proposed_candidate))
        candidate=self.jrpc(f"public.submit_routing_candidate('{self.req()}','{snapshot['snapshot_id']}',{self.literal(body)})",role='geolock_planner')
        work=self.jrpc(f"public.read_routing_work_item('{candidate['candidate_id']}')",role='geolock_validator')
        report=validate_work_item(work,validator_build='LOCAL-SYNTHETIC-VALIDATOR-v1')
        self.rpc(f"public.attest_routing_candidate('{candidate['candidate_id']}','{candidate['digest']}',{self.literal(report)})",role='geolock_validator')
        self.fixture=dict(vehicle=v,task=tid,claim=cid,donation=did,candidate=candidate,bundle=bundle,report=report)
        return self.fixture

    def authorize(self):
        f=self.fixture
        result=self.jrpc(f"public.authorize_my_routing_candidate('{self.req()}','{f['candidate']['candidate_id']}',clock_timestamp()+interval '0.1 second')")
        self.query('SELECT pg_sleep(0.15);')  # isolated loopback only
        return result['route_ids'][0]

    def test_publish_start_collect_releases_holds(self):
        f=self.prepare(); rid=self.authorize()
        self.rpc(f"public.start_pickup('{f['claim']}')")
        self.assertEqual(self.query(f"SELECT donation_status FROM public.donations WHERE donation_id='{f['donation']}';"),'PICKUP_IN_PROGRESS')
        self.rpc(f"public.complete_pickup('{f['claim']}',true)")
        self.assertEqual(self.query(f"SELECT route_status FROM public.pickup_routes WHERE route_id='{rid}';"),'IN_PROGRESS')
        self.assertEqual(self.query(f"SELECT fleet_private.vehicle_has_hold('{f['vehicle']['vehicle_id']}');"),'t')
        self.rpc(f"public.close_my_collected_route('{rid}',false)",error='DEPOT_RETURN_CONFIRMATION_REQUIRED')
        self.rpc(f"public.close_my_collected_route('{rid}',true)")
        self.assertEqual(self.query(f"SELECT route_status FROM public.pickup_routes WHERE route_id='{rid}';"),'COMPLETED')
        self.assertEqual(self.query('SELECT count(*) FROM public.active_task_route_assignments;'),'0')
        self.assertEqual(self.query(f"SELECT fleet_private.vehicle_has_hold('{f['vehicle']['vehicle_id']}');"),'f')
        self.assertEqual(self.query(f"SELECT donation_status FROM public.donations WHERE donation_id='{f['donation']}';"),'COLLECTED')

    def test_unrouted_start_and_direct_task_bypass_denied(self):
        f=self.prepare()
        self.rpc(f"public.start_pickup('{f['claim']}')",error='DATABASE_DISPATCH_AUTHORIZATION_REQUIRED')
        self.query(f"UPDATE public.pickup_tasks SET task_status='DISPATCHED' WHERE task_id='{f['task']}';",'DATABASE_DISPATCH_AUTHORIZATION_REQUIRED')

    def test_cancel_archives_and_releases_without_losing_task(self):
        f=self.prepare(); rid=self.authorize()
        self.rpc(f"public.cancel_my_unstarted_route('{rid}')")
        self.rpc(f"public.cancel_my_unstarted_route('{rid}')")
        self.assertEqual(self.query('SELECT count(*) FROM routing_private.cancelled_stop_history;'),'1')
        self.assertEqual(self.query('SELECT count(*) FROM public.pickup_route_stops;'),'0')
        self.assertEqual(self.query(f"SELECT task_status FROM public.pickup_tasks WHERE task_id='{f['task']}';"),'CONFIRMED')
        self.assertEqual(self.query(f"SELECT fleet_private.vehicle_has_hold('{f['vehicle']['vehicle_id']}');"),'f')

    def test_no_cancellation_or_closure_of_started_unresolved_route(self):
        f=self.prepare(); rid=self.authorize(); self.rpc(f"public.start_pickup('{f['claim']}')")
        self.rpc(f"public.cancel_my_unstarted_route('{rid}')",error='STARTED_ROUTE_REQUIRES_RECONCILIATION')
        self.rpc(f"public.close_my_collected_route('{rid}',true)",error='ROUTE_HAS_UNRESOLVED_TASKS')

    def test_cross_ngo_and_ordinary_worker_access_denied(self):
        self.prepare(); rid=self.authorize()
        self.rpc(f"public.cancel_my_unstarted_route('{rid}')",user=B,error='NOT_ROUTE_OWNER')
        self.rpc(f"public.read_routing_snapshot_bundle('{self.fixture['bundle']['snapshot']['snapshot_id']}')",error='permission denied')
        for role in ('anon','authenticated','service_role'):
            self.query(f'SET ROLE {role}; SELECT * FROM routing_private.bindings;','permission denied')

    def test_vehicle_hold_and_stale_version(self):
        f=self.prepare(); vid=f['vehicle']['vehicle_id']
        self.rpc(f"public.set_my_vehicle_availability('{vid}',1,false)")
        self.rpc(f"public.authorize_my_routing_candidate('{self.req()}','{f['candidate']['candidate_id']}',clock_timestamp()+interval '1 second')",error='PLAN_STALE_VEHICLE')
        self.assertEqual(self.query('SELECT count(*) FROM public.pickup_routes;'),'0')

    def test_c1_seal_and_artifact_immutability(self):
        self.prepare()
        self.assertEqual(self.query("SELECT obj_description('fleet_private'::regnamespace,'pg_namespace')='geolock-stage8-c1-v2:'||fleet_private.installation_fingerprint();"),'t')
        self.query("UPDATE routing_private.snapshots SET digest='bad';",'SNAPSHOT_IMMUTABLE')
        self.query('DELETE FROM routing_private.validations;','ROUTING_ARTIFACT_IMMUTABLE')
        self.query('UPDATE public.road_network_nodes SET active_flag=false;','GRAPH_REVISION_FROZEN')

    def test_race_cancel_first_denies_start(self):
        f=self.prepare(); rid=self.authorize()
        with self.concurrent(f"BEGIN; SET LOCAL ROLE authenticated; SET LOCAL request.jwt.claim.sub='{A}'; SELECT public.cancel_my_unstarted_route('{rid}'); SELECT pg_sleep(1.2); COMMIT;"):
            self.rpc(f"public.start_pickup('{f['claim']}')",error='ROUTE_BINDING_DRIFT')
        self.assertEqual(self.query(f"SELECT task_status FROM public.pickup_tasks WHERE task_id='{f['task']}';"),'CONFIRMED')

    def test_race_start_first_blocks_cancel(self):
        f=self.prepare(); rid=self.authorize()
        with self.concurrent(f"BEGIN; SET LOCAL ROLE authenticated; SET LOCAL request.jwt.claim.sub='{A}'; SELECT public.start_pickup('{f['claim']}'); SELECT pg_sleep(1.2); COMMIT;"):
            self.rpc(f"public.cancel_my_unstarted_route('{rid}')",error='STARTED_ROUTE_REQUIRES_RECONCILIATION')

    def test_race_closure_then_vehicle_update(self):
        f=self.prepare(); rid=self.authorize(); self.rpc(f"public.start_pickup('{f['claim']}')")
        self.rpc(f"public.complete_pickup('{f['claim']}',true)")
        self.rpc(f"public.set_my_vehicle_availability('{f['vehicle']['vehicle_id']}',1,false)",error='VEHICLE_HAS_ACTIVE_ROUTE')
        with self.concurrent(f"BEGIN; SET LOCAL ROLE authenticated; SET LOCAL request.jwt.claim.sub='{A}'; SELECT public.close_my_collected_route('{rid}',true); SELECT pg_sleep(1.2); COMMIT;"):
            self.rpc(f"public.set_my_vehicle_availability('{f['vehicle']['vehicle_id']}',1,false)")
        self.assertEqual(self.query('SELECT count(*) FROM public.active_task_route_assignments;'),'0')

    def test_race_publication_is_idempotent(self):
        f=self.prepare(); request=self.req()
        depart=self.query("SELECT (clock_timestamp()+interval '5 seconds')::text;")
        call=f"public.authorize_my_routing_candidate('{request}','{f['candidate']['candidate_id']}','{depart}')"
        with self.concurrent(f"BEGIN; SET LOCAL ROLE authenticated; SET LOCAL request.jwt.claim.sub='{A}'; SELECT {call}; SELECT pg_sleep(1.2); COMMIT;"):
            result=self.jrpc(call)
        self.assertEqual(len(result['route_ids']),1)
        self.assertEqual(self.query('SELECT count(*) FROM public.pickup_routes;'),'1')

    def test_invalid_handover_rolls_back_completion(self):
        f=self.prepare(); rid=self.authorize(); self.rpc(f"public.start_pickup('{f['claim']}')")
        self.rpc(f"public.complete_pickup('{f['claim']}',false)",error='HANDOVER_NOT_CONFIRMED')
        self.assertEqual(self.query(f"SELECT task_status FROM public.pickup_tasks WHERE task_id='{f['task']}';"),'DISPATCHED')
        self.assertEqual(self.query('SELECT count(*) FROM public.active_task_route_assignments;'),'1')

    def test_reconciliation_keeps_reservation_and_denies_start(self):
        f=self.prepare(); self.authorize()
        # Simulates existing recovery's protected uncertain-state branch;
        # the deployed recovery scheduler/guards are not installed in this fixture.
        self.query(f"UPDATE public.donation_claims SET claim_status='RECONCILIATION_REQUIRED' WHERE claim_id='{f['claim']}'; UPDATE public.claim_leases SET lease_status='RECONCILIATION_REQUIRED' WHERE claim_id='{f['claim']}'; UPDATE public.pickup_tasks SET task_status='STALE' WHERE task_id='{f['task']}';")
        self.rpc(f"public.start_pickup('{f['claim']}')",error='DISPATCH_SOURCE_STALE')
        self.assertEqual(self.query('SELECT count(*) FROM public.active_task_route_assignments;'),'1')
        self.assertEqual(self.query(f"SELECT fleet_private.vehicle_has_hold('{f['vehicle']['vehicle_id']}');"),'t')

    def test_bad_validation_binding_denied(self):
        f=self.prepare(); report=dict(f['report'],matrix_digest='0'*64)
        self.rpc(f"public.attest_routing_candidate('{f['candidate']['candidate_id']}','{f['candidate']['digest']}',{self.literal(report)})",role='geolock_validator',error='TRUSTED_VALIDATION_REQUIRED')

    def test_unauthenticated_and_old_assignment_entrypoint_denied(self):
        f=self.prepare()
        self.rpc(f"public.start_pickup('{f['claim']}')",role='anon',error='permission denied')
        self.rpc(f"public.assign_task_to_route('{self.req()}','{f['task']}',1)",error='permission denied')

    def test_migration_replay_fails_cleanly(self):
        self.query((HERE/'001_authority_proposal.sql').read_text(),'ROUTING_INSTALL_EXISTS_REVIEW_VERSION_INSTEAD_OF_REPLAY')
        self.assertEqual(self.query('SELECT count(*) FROM routing_private.graphs;'),'0')

    def test_sql_rechecks_schedule_even_with_forged_trusted_attestation(self):
        f=self.prepare(); body=f['candidate']['body']; body['plan']['routes'][0]['stops'][0]['arrival_us']+=1
        c=self.jrpc(f"public.submit_routing_candidate('{self.req()}','{f['bundle']['snapshot']['snapshot_id']}',{self.literal(body)})",role='geolock_planner')
        # Deliberately malicious privileged-validator fixture, NOT valid evidence.
        report=dict(f['report'],candidate_digest=c['digest'])
        self.rpc(f"public.attest_routing_candidate('{c['candidate_id']}','{c['digest']}',{self.literal(report)})",role='geolock_validator')
        self.rpc(f"public.authorize_my_routing_candidate('{self.req()}','{c['candidate_id']}',clock_timestamp()+interval '1 second')",error='ROUTE_SCHEDULE_INVALID')
        self.assertEqual(self.query('SELECT count(*) FROM public.pickup_routes;'),'0')

    def test_hub_collection_preserves_source_lifecycle(self):
        f=self.prepare(hub=True); self.authorize(); self.rpc(f"public.start_pickup('{f['claim']}')")
        self.rpc(f"public.complete_pickup('{f['claim']}',true)")
        self.assertEqual(self.query('SELECT batch_status FROM public.hub_batches;'),'COLLECTED')
        self.assertEqual(self.query('SELECT inventory_status FROM public.hub_inventory;'),'COLLECTED')

    def test_multi_donation_hub_is_one_pickup_task_with_full_batch_weight(self):
        from backend.routing.integration import solve_bundle
        f=self.prepare(hub=True,hub_members=2)
        observation=f['bundle']['snapshot']['body']['observations'][0]
        self.assertEqual(len(f['bundle']['snapshot']['body']['observations']),1)
        self.assertEqual(len(observation['donations']),2)
        self.assertEqual(observation['batch']['batch_donation_count'],2)
        self.assertEqual(observation['batch']['batch_weight_kg'],20)
        self.assertEqual(self.query('SELECT count(*) FROM public.pickup_tasks;'),'1')
        self.assertEqual(self.query('SELECT load_kg FROM public.pickup_tasks;'),'20')
        plan=solve_bundle(f['bundle']).proposed_candidate
        self.assertEqual(plan.optimization_objective,'MAX_PICKUP_TASKS_THEN_MIN_DIRECTED_ROAD_KM')
        self.assertEqual(plan.pickup_task_objective_value,1)
        self.assertEqual(len(plan.routes),1)
        self.assertEqual(len(plan.routes[0].stops),1)
        self.assertEqual(plan.routes[0].stops[0].cumulative_load_kg,20)
        self.assertTrue(f['report']['valid'])
        self.assertTrue(f['report']['feasible'])

    def test_partial_route_does_not_release_uncollected_task(self):
        f=self.prepare(two=True); rid=self.authorize()
        claims=self.query('SELECT t.claim_id FROM routing_private.items i JOIN public.pickup_tasks t USING(task_id) ORDER BY i.ordinal;').splitlines()
        self.assertEqual(len(claims),2)
        self.rpc(f"public.start_pickup('{claims[0]}')"); self.rpc(f"public.complete_pickup('{claims[0]}',true)")
        self.assertEqual(self.query('SELECT count(*) FROM public.active_task_route_assignments;'),'2')
        self.assertEqual(self.query(f"SELECT route_status FROM public.pickup_routes WHERE route_id='{rid}';"),'IN_PROGRESS')
        self.rpc(f"public.start_pickup('{claims[1]}')"); self.rpc(f"public.complete_pickup('{claims[1]}',true)")
        self.assertEqual(self.query('SELECT count(*) FROM public.active_task_route_assignments;'),'2')
        self.rpc(f"public.close_my_collected_route('{rid}',true)")
        self.assertEqual(self.query('SELECT count(*) FROM public.active_task_route_assignments;'),'0')

    def test_direct_column_writes_removed(self):
        for table in ('pickup_tasks','pickup_routes','pickup_route_stops','active_task_route_assignments'):
            for role in ('anon','authenticated'):
                self.assertEqual(self.query(f"SELECT has_any_column_privilege('{role}','public.{table}','UPDATE');"),'f')

    def test_flutter_reads_are_owned_and_dispatch_is_backed_by_permit(self):
        f=self.prepare()
        overview=self.jrpc('public.get_my_routing_overview()')
        self.assertEqual(len(overview['eligible_tasks']),1)
        self.assertTrue(overview['authorization_enforced'])
        rid=self.authorize()
        row=self.jrpc(f"public.get_my_authorized_route('{rid}')")
        self.assertTrue(row['authorization_confirmed']); self.assertTrue(row['stops'][0]['can_start'])
        self.rpc(f"public.get_my_authorized_route('{rid}')",user=B,error='OWNED_MANAGED_ROUTE_NOT_FOUND')
        self.rpc(f"public.start_pickup('{f['claim']}')")
        row=self.jrpc(f"public.get_my_authorized_route('{rid}')")
        self.assertFalse(row['stops'][0]['can_start']); self.assertTrue(row['stops'][0]['can_complete'])
        self.rpc(f"public.complete_pickup('{f['claim']}',true)")
        row=self.jrpc(f"public.get_my_authorized_route('{rid}')")
        self.assertTrue(row['can_close']); self.assertFalse(row['stops'][0]['can_complete'])
        self.rpc(f"public.close_my_collected_route('{rid}',true)")
        self.assertFalse(self.jrpc(f"public.get_my_authorized_route('{rid}')")['authorization_confirmed'])

    def test_selected_vehicles_are_snapshot_authority_and_retry_bound(self):
        f=self.prepare(); pid=f['bundle']['snapshot']['policy_id']; req=self.req(); vid=f['vehicle']['vehicle_id']
        snap=self.jrpc(f"public.begin_my_routing_snapshot('{req}','{pid}',ARRAY['{vid}'::uuid])")
        self.assertEqual([v['vehicle_id'] for v in snap['body']['vehicles']],[vid])
        self.rpc(f"public.begin_my_routing_snapshot('{req}','{pid}',ARRAY[]::uuid[])",error='REQUEST_CONFLICT')
        empty=self.jrpc(f"public.begin_my_routing_snapshot('{self.req()}','{pid}',ARRAY[]::uuid[])")
        self.assertEqual(empty['body']['vehicles'],[])
        self.rpc(f"public.begin_my_routing_snapshot('{self.req()}','{pid}',ARRAY['{self.req()}'::uuid])",error='INVALID_OWNED_VEHICLE_SELECTION')

    def test_flutter_reader_is_not_granted_to_anon_or_service_role(self):
        for role in ('anon','service_role'):
            self.rpc('public.get_my_routing_overview()',role=role,error='permission denied')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-isolated',required=True,action='store_true')
    parser.parse_args()
    unittest.main(argv=[__file__],verbosity=2)
