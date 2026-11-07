"""C1 proposal tests in a NEW disposable loopback PostgreSQL only.

No DSN, URL, existing database, or Supabase connection is accepted.
Reduced schema and auth.uid() double are explicit. The exact proposal SQL and
captured deployed depot trigger function execute in a real PostgreSQL engine.
"""
from pathlib import Path
import argparse
from contextlib import contextmanager
import json
import os
import shutil
import socket
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
FOLDER = ROOT / 'docs/stage8/phase-c1'
SQL = (FOLDER / 'proposed_migration.sql').read_text(encoding='utf-8')
EVIDENCE = json.loads((FOLDER / 'dev-evidence.json').read_text(encoding='utf-8'))
DEPOT = next(r['definition'] for q in EVIDENCE['queries'] if q['name']=='functions'
             for r in q['rows'] if r['signature']=='geolock_assign_vehicle_depot()')
A = '11111111-1111-1111-1111-111111111111'
B = '22222222-2222-2222-2222-222222222222'
UNVERIFIED = '33333333-3333-3333-3333-333333333333'
DONOR = '44444444-4444-4444-4444-444444444444'
REQ = '55555555-5555-5555-5555-555555555555'
LEGACY = '66666666-6666-6666-6666-666666666666'

FIXTURE = f"""
CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role BYPASSRLS;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS
$$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE auth.users(id uuid PRIMARY KEY);
INSERT INTO auth.users VALUES('{A}'),('{B}'),('{UNVERIFIED}'),('{DONOR}');
CREATE TABLE public.user_profiles(user_id uuid PRIMARY KEY REFERENCES auth.users,role text,
 UNIQUE(user_id,role));
INSERT INTO public.user_profiles VALUES('{A}','NGO'),('{B}','NGO'),('{UNVERIFIED}','NGO'),('{DONOR}','DONOR');
CREATE TABLE public.ngo_profiles(user_id uuid PRIMARY KEY,role text DEFAULT 'NGO' CHECK(role='NGO'),
 road_node_id text,active_flag boolean NOT NULL DEFAULT true,location_verified_at timestamptz,
 location_generation bigint NOT NULL DEFAULT 0,FOREIGN KEY(user_id,role) REFERENCES public.user_profiles(user_id,role));
INSERT INTO public.ngo_profiles VALUES('{A}','NGO','101',true,now(),0),('{B}','NGO','102',true,now(),0),
 ('{UNVERIFIED}','NGO',NULL,true,NULL,0);
CREATE TABLE public.road_network_coverage(network_snapshot_id text PRIMARY KEY,active_flag boolean,
 dataset_kind text,approved_at timestamptz);
INSERT INTO public.road_network_coverage VALUES('synthetic-operational-fixture',true,'OPERATIONAL',now());
CREATE TABLE public.road_network_nodes(osm_node_id bigint PRIMARY KEY,network_snapshot_id text,
 active_flag boolean NOT NULL DEFAULT true);
INSERT INTO public.road_network_nodes VALUES(101,'synthetic-operational-fixture',true),(102,'synthetic-operational-fixture',true),
 (103,'synthetic-operational-fixture',false);
CREATE TABLE public.vehicles(vehicle_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 ngo_user_id uuid NOT NULL REFERENCES public.ngo_profiles,vehicle_label text NOT NULL,
 payload_capacity_kg numeric(12,3) NOT NULL CHECK(payload_capacity_kg>0),depot_road_node_id text,
 active_flag boolean NOT NULL DEFAULT true,UNIQUE(vehicle_id,ngo_user_id));
CREATE TABLE public.pickup_routes(route_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),ngo_user_id uuid NOT NULL,
 vehicle_id uuid NOT NULL,route_status text NOT NULL DEFAULT 'DRAFT',
 CHECK(route_status IN ('DRAFT','VALIDATED','AUTHORISED','IN_PROGRESS','COMPLETED','CANCELLED','STALE')),
 FOREIGN KEY(vehicle_id,ngo_user_id) REFERENCES public.vehicles(vehicle_id,ngo_user_id));
CREATE TABLE public.audit_events(event_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 actor_user_id uuid REFERENCES auth.users,actor_role text,entity_type text,entity_id uuid,
 event_type text,outcome text CHECK(outcome IN ('SUCCESS','REJECTED','ERROR')),details jsonb);
ALTER TABLE public.vehicles ENABLE ROW LEVEL SECURITY;
GRANT ALL ON public.vehicles TO anon,authenticated,service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO anon,authenticated,service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon,authenticated,service_role;
"""


class FleetTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='geolock-c1-isolated-')
        cls.folder = Path(cls.tmp.name)
        cls.data = cls.folder/'data'
        cls.env = {k:v for k,v in os.environ.items() if not k.upper().startswith('PG')}
        cls.env.update(PGCONNECT_TIMEOUT='3',PGPASSFILE=str(cls.folder/'absent-password-file'))
        cls.flags = subprocess.CREATE_NO_WINDOW if os.name=='nt' else 0
        cls.addClassCleanup(cls.cleanup)
        cls.run_process([cls.bins['initdb'],'-D',str(cls.data),'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
        with socket.socket() as sock:
            sock.bind(('127.0.0.1',0)); cls.port=sock.getsockname()[1]
        cls.run_process([cls.bins['pg_ctl'],'-D',str(cls.data),'-l',str(cls.folder/'server.log'),
                         '-w','-t','20','-o',f'-h 127.0.0.1 -p {cls.port}','start'])
        cls.query(FIXTURE+DEPOT+";\n"+"""
          CREATE TRIGGER trg_vehicle_depot_node BEFORE INSERT OR UPDATE OF depot_road_node_id,ngo_user_id
          ON public.vehicles FOR EACH ROW EXECUTE FUNCTION public.geolock_assign_vehicle_depot();
        """)
        cls.query(f"INSERT INTO public.vehicles(vehicle_id,ngo_user_id,vehicle_label,payload_capacity_kg) VALUES('{LEGACY}','{A}','Legacy',12.345);")
        cls.query(SQL)
        cls.query(SQL)  # exact same migration is rerunnable

    @classmethod
    def run_process(cls,args):
        with tempfile.TemporaryFile(mode='w+',encoding='utf-8') as output:
            result=subprocess.run(args,env=cls.env,creationflags=cls.flags,stdout=output,stderr=output,text=True,timeout=40)
            output.seek(0); message=output.read()
        if result.returncode: raise RuntimeError(message)
        return message.strip()

    @classmethod
    def args(cls,sql):
        return [cls.bins['psql'],'-X','--no-password','-h','127.0.0.1','-p',str(cls.port),
                '-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1','-Atq','-c',sql]

    @classmethod
    def query(cls,sql,expect_error=None):
        try: result=cls.run_process(cls.args(sql))
        except RuntimeError as exc:
            if expect_error and expect_error in str(exc): return str(exc)
            raise
        if expect_error: raise AssertionError(f'Expected {expect_error}, got {result}')
        return result

    @classmethod
    def cleanup(cls):
        if (cls.data/'postmaster.pid').exists():
            cls.run_process([cls.bins['pg_ctl'],'-D',str(cls.data),'-m','immediate','-w','stop'])
        cls.tmp.cleanup()

    def setUp(self):
        self.query("""TRUNCATE public.pickup_routes,public.vehicles,public.audit_events;
          UPDATE public.ngo_profiles SET active_flag=true,road_node_id=CASE
            WHEN user_id='11111111-1111-1111-1111-111111111111' THEN '101'
            WHEN user_id='22222222-2222-2222-2222-222222222222' THEN '102' END,
            location_verified_at=CASE WHEN user_id<>'33333333-3333-3333-3333-333333333333' THEN now() END;
          UPDATE public.road_network_nodes SET active_flag=(osm_node_id<>103);
          UPDATE public.road_network_coverage SET active_flag=true;
        """)

    def rpc(self,call,user=A,role='authenticated',error=None):
        return self.query(f"BEGIN; SET LOCAL ROLE {role}; SET LOCAL request.jwt.claim.sub='{user}'; SELECT {call}; COMMIT;",error)

    def register(self,user=A,available='true',request=REQ,label='Van',kind='VAN',capacity='123.456',fixed='25.00',rate='0.4500',duration='240'):
        return json.loads(self.rpc(f"public.register_my_vehicle('{request}','{label}','{kind}',{capacity},{fixed},{rate},{duration},{available})",user))

    def route(self,vehicle,status='DRAFT'):
        return self.query(f"INSERT INTO public.pickup_routes(ngo_user_id,vehicle_id,route_status) VALUES('{A}','{vehicle}','{status}') RETURNING route_id;")

    def test_01_legacy_preservation_and_idempotency(self):
        # A separate legacy-shaped row survives rerunning the exact proposal.
        self.query(f"INSERT INTO public.vehicles(vehicle_id,ngo_user_id,vehicle_label,payload_capacity_kg) VALUES('{LEGACY}','{A}','Legacy',12.345);")
        before=self.query(f"SELECT to_jsonb(v) FROM public.vehicles v WHERE vehicle_id='{LEGACY}';")
        self.query(SQL)
        self.assertEqual(before,self.query(f"SELECT to_jsonb(v) FROM public.vehicles v WHERE vehicle_id='{LEGACY}';"))
        row=json.loads(before)
        self.assertEqual(row['payload_capacity_kg'],12.345)
        self.assertIsNone(row['fixed_cost_rm']); self.assertFalse(row['available_for_planning'])

    def test_zero_and_multiple_vehicles(self):
        data=json.loads(self.rpc('public.list_my_vehicles()'))
        self.assertEqual(data['vehicles'],[]); self.assertEqual(data['fleet_outcome'],'NO_FEASIBLE_PLAN')
        self.register(); self.register(request=B)
        self.assertEqual(len(json.loads(self.rpc('public.list_my_vehicles()'))['vehicles']),2)

    def test_registration_retry_and_conflict(self):
        first=self.register(); self.assertEqual(first,self.register())
        self.rpc(f"public.register_my_vehicle('{REQ}','Other','VAN',123.456,25.00,0.4500,240,true)",error='REGISTRATION_REQUEST_CONFLICT')
        self.assertEqual(self.query('SELECT count(*) FROM public.vehicles;'),'1')

    def test_owner_isolation_all_mutations_and_list(self):
        v=self.register(); foreign=self.register(user=B)
        self.assertEqual([r['vehicle_id'] for r in json.loads(self.rpc('public.list_my_vehicles()'))['vehicles']],[v['vehicle_id']])
        for call in [f"public.update_my_vehicle('{foreign['vehicle_id']}',1,'x','VAN',20,1,1,60)",
                     f"public.set_my_vehicle_availability('{foreign['vehicle_id']}',1,false)",
                     f"public.deactivate_my_vehicle('{foreign['vehicle_id']}',1)"]:
            with self.subTest(call=call): self.rpc(call,error='VEHICLE_NOT_FOUND')

    def test_anonymous_donor_inactive_and_missing_identity(self):
        self.rpc('public.list_my_vehicles()',role='anon',error='permission denied')
        self.rpc('public.list_my_vehicles()',user='',error='UNAUTHENTICATED')
        self.rpc('public.list_my_vehicles()',user=DONOR,error='ACTIVE_NGO_PROFILE_REQUIRED')
        self.query(f"UPDATE public.ngo_profiles SET active_flag=false WHERE user_id='{A}';")
        self.rpc('public.list_my_vehicles()',error='ACTIVE_NGO_PROFILE_REQUIRED')

    def test_invalid_values(self):
        args=['123.456','25.00','0.4500','240']
        for column,values in enumerate([['NULL','0','-1',"'NaN'::numeric","'Infinity'::numeric",'1.0001','1000000000'],
                                       ['NULL','-1',"'NaN'::numeric","'Infinity'::numeric",'0.001'],
                                       ['NULL','-1',"'NaN'::numeric","'Infinity'::numeric",'0.00001'],
                                       ['NULL','0','-1',"'NaN'::numeric","'Infinity'::numeric",'1.0001']]):
            for value in values:
                actual=args.copy(); actual[column]=value
                with self.subTest(column=column,value=value):
                    self.rpc(f"public.register_my_vehicle('{REQ}','Van','VAN',{','.join(actual)},true)",error='INVALID_VEHICLE_FIELDS')
        for label,kind in [("''","'VAN'"),("'Van'","''"),("NULL","'VAN'")]:
            self.rpc(f"public.register_my_vehicle('{REQ}',{label},{kind},10,0,0,60,false)",error='INVALID_VEHICLE_FIELDS')

    def test_zero_costs_are_explicit_and_valid(self):
        v=self.register(fixed='0',rate='0')
        self.assertEqual((v['fixed_cost_rm'],v['distance_cost_rm_per_km']),(0,0))

    def test_unverified_invalid_inactive_wrong_snapshot_depots(self):
        self.rpc(f"public.register_my_vehicle('{REQ}','v','VAN',10,0,0,60,false)",user=UNVERIFIED,error='VERIFIED_OPERATIONAL_DEPOT_REQUIRED')
        for node in ['999','103','not-a-node','999999999999999999999999999999999999999999']:
            self.query(f"UPDATE public.ngo_profiles SET road_node_id='{node}' WHERE user_id='{A}';")
            self.rpc(f"public.register_my_vehicle('{REQ}','v','VAN',10,0,0,60,false)",error='VERIFIED_OPERATIONAL_DEPOT_REQUIRED')
        self.query(f"UPDATE public.ngo_profiles SET road_node_id='101' WHERE user_id='{A}'; UPDATE public.road_network_coverage SET active_flag=false;")
        self.rpc(f"public.register_my_vehicle('{REQ}','v','VAN',10,0,0,60,false)",error='VERIFIED_OPERATIONAL_DEPOT_REQUIRED')

    def test_depot_client_value_is_not_authority(self):
        v=self.register()
        self.query(f"UPDATE public.vehicles SET depot_road_node_id='999' WHERE vehicle_id='{v['vehicle_id']}';")
        self.assertEqual(self.query(f"SELECT depot_road_node_id FROM public.vehicles WHERE vehicle_id='{v['vehicle_id']}';"),'101')

    def test_update_version_and_availability(self):
        v=self.register(available='false'); vid=v['vehicle_id']
        self.assertEqual(json.loads(self.rpc('public.list_my_vehicles()'))['fleet_outcome'],'NO_FEASIBLE_PLAN')
        v=json.loads(self.rpc(f"public.set_my_vehicle_availability('{vid}',1,true)")); self.assertEqual(v['vehicle_version'],2)
        self.assertEqual(json.loads(self.rpc('public.list_my_vehicles()'))['fleet_outcome'],'AVAILABLE_VEHICLES')
        self.rpc(f"public.set_my_vehicle_availability('{vid}',1,false)",error='VEHICLE_VERSION_CONFLICT')
        v=json.loads(self.rpc(f"public.update_my_vehicle('{vid}',2,'Truck','TRUCK',200,20,0.5,180)"))
        self.assertEqual(v['vehicle_version'],3); self.assertEqual(v['payload_capacity_kg'],200)
        v=json.loads(self.rpc(f"public.set_my_vehicle_availability('{vid}',3,false)")); self.assertEqual(v['vehicle_version'],4)

    def test_deactivate_preserves_identity_and_history(self):
        v=self.register(); vid=v['vehicle_id']; self.route(vid,'COMPLETED')
        v=json.loads(self.rpc(f"public.deactivate_my_vehicle('{vid}',1)"))
        self.assertFalse(v['active_flag']); self.assertFalse(v['available_for_planning'])
        self.rpc(f"public.set_my_vehicle_availability('{vid}',2,true)",error='VEHICLE_DEACTIVATED')
        self.query(f"DELETE FROM public.vehicles WHERE vehicle_id='{vid}';",'DEACTIVATE_VEHICLE_INSTEAD')

    def test_all_nonterminal_routes_protect_operational_fields(self):
        for state in ['DRAFT','VALIDATED','AUTHORISED','IN_PROGRESS']:
            with self.subTest(state=state):
                self.query('TRUNCATE public.pickup_routes,public.vehicles;')
                v=self.register(); vid=v['vehicle_id']; self.route(vid,state)
                for call in [f"public.deactivate_my_vehicle('{vid}',1)",
                             f"public.set_my_vehicle_availability('{vid}',1,false)",
                             f"public.update_my_vehicle('{vid}',1,'Van','VAN',200,25,0.45,240)"]:
                    self.rpc(call,error='VEHICLE_HAS_ACTIVE_ROUTE')
                data=json.loads(self.rpc('public.list_my_vehicles()'))
                self.assertFalse(data['vehicles'][0]['eligible_for_planning'])
                self.assertEqual(data['fleet_outcome'],'NO_FEASIBLE_PLAN')

    def test_label_edit_also_preserves_reserved_vehicle_version(self):
        v=self.register(); self.route(v['vehicle_id'],'AUTHORISED')
        self.rpc(f"public.update_my_vehicle('{v['vehicle_id']}',1,'New label','VAN',123.456,25,0.45,240)",error='VEHICLE_HAS_ACTIVE_ROUTE')
        self.assertEqual(self.query(f"SELECT vehicle_version FROM public.vehicles WHERE vehicle_id='{v['vehicle_id']}';"),'1')

    def test_route_binding_rejects_unavailable_foreign_and_active_delete(self):
        v=self.register(available='false')
        self.query(f"INSERT INTO public.pickup_routes(ngo_user_id,vehicle_id) VALUES('{A}','{v['vehicle_id']}');",'VEHICLE_NOT_AVAILABLE')
        v=json.loads(self.rpc(f"public.set_my_vehicle_availability('{v['vehicle_id']}',1,true)"))
        self.query(f"INSERT INTO public.pickup_routes(ngo_user_id,vehicle_id) VALUES('{B}','{v['vehicle_id']}');",'VEHICLE_NOT_AVAILABLE')
        rid=self.route(v['vehicle_id'])
        self.query(f"DELETE FROM public.pickup_routes WHERE route_id='{rid}';",'ACTIVE_ROUTE_DELETE_FORBIDDEN')

    def test_terminal_route_releases_protection(self):
        v=self.register(); rid=self.route(v['vehicle_id'])
        self.query(f"UPDATE public.pickup_routes SET route_status='COMPLETED' WHERE route_id='{rid}';")
        self.rpc(f"public.deactivate_my_vehicle('{v['vehicle_id']}',1)")

    def test_unverified_after_registration_not_plannable(self):
        self.register()
        self.query(f"UPDATE public.ngo_profiles SET location_verified_at=NULL WHERE user_id='{A}';")
        data=json.loads(self.rpc('public.list_my_vehicles()'))
        self.assertEqual(data['fleet_outcome'],'NO_FEASIBLE_PLAN')

    def test_location_refresh_preserved_and_reserved_refresh_rejected(self):
        v=self.register()
        # Same vehicle refresh statement used by the captured location functions.
        self.query(f"UPDATE public.ngo_profiles SET road_node_id='102' WHERE user_id='{A}'; UPDATE public.vehicles SET depot_road_node_id=NULL WHERE ngo_user_id='{A}';")
        self.assertEqual(self.query(f"SELECT depot_road_node_id FROM public.vehicles WHERE vehicle_id='{v['vehicle_id']}';"),'102')
        self.route(v['vehicle_id'])
        self.query(f"BEGIN; UPDATE public.ngo_profiles SET road_node_id='101' WHERE user_id='{A}'; UPDATE public.vehicles SET depot_road_node_id=NULL WHERE ngo_user_id='{A}'; COMMIT;",'VEHICLE_HAS_ACTIVE_ROUTE')
        self.assertEqual(self.query(f"SELECT road_node_id FROM public.ngo_profiles WHERE user_id='{A}';"),'102')

    def test_idle_depot_revocation_disables_planning(self):
        v=self.register()
        self.query(f"BEGIN; UPDATE public.ngo_profiles SET location_verified_at=NULL,road_node_id=NULL WHERE user_id='{A}'; UPDATE public.vehicles SET depot_road_node_id=NULL WHERE ngo_user_id='{A}'; COMMIT;")
        row=json.loads(self.query(f"SELECT to_jsonb(v) FROM public.vehicles v WHERE vehicle_id='{v['vehicle_id']}';"))
        self.assertFalse(row['available_for_planning']); self.assertIsNone(row['depot_road_node_id'])
        self.assertEqual(row['vehicle_version'],2)
        self.rpc(f"public.set_my_vehicle_availability('{v['vehicle_id']}',2,true)",error='VERIFIED_OPERATIONAL_DEPOT_REQUIRED')

    def test_direct_writes_reads_helpers_and_service_denied(self):
        v=self.register()
        for role in ['anon','authenticated','service_role']:
            for statement in ['SELECT * FROM public.vehicles',
                              "INSERT INTO public.vehicles(ngo_user_id,vehicle_label,payload_capacity_kg) VALUES('"+A+"','x',1)",
                              'UPDATE public.vehicles SET active_flag=false','DELETE FROM public.vehicles','TRUNCATE public.vehicles']:
                with self.subTest(role=role,statement=statement):
                    self.query(f'SET ROLE {role}; {statement};','permission denied')
            self.query(f'SET ROLE {role}; SELECT fleet_private.require_ngo();','permission denied')
        self.rpc('public.list_my_vehicles()',role='service_role',error='permission denied')

    def test_identity_and_owner_immutable(self):
        v=self.register()
        self.query(f"UPDATE public.vehicles SET ngo_user_id='{B}' WHERE vehicle_id='{v['vehicle_id']}';",'IMMUTABLE_VEHICLE_IDENTITY')

    def test_stronger_isolation_rejected(self):
        v=self.register()
        self.query(f"BEGIN ISOLATION LEVEL REPEATABLE READ; UPDATE public.vehicles SET available_for_planning=false WHERE vehicle_id='{v['vehicle_id']}';",'FLEET_REQUIRES_READ_COMMITTED')

    def test_audit_is_atomic_and_idempotent_noop(self):
        v=self.register(); self.register()
        self.assertEqual(self.query('SELECT count(*) FROM public.audit_events;'),'1')
        self.rpc(f"public.set_my_vehicle_availability('{v['vehicle_id']}',1,true)")
        self.assertEqual(self.query('SELECT count(*) FROM public.audit_events;'),'1')

    def test_invalid_update_and_incomplete_legacy_availability(self):
        v=self.register()
        self.rpc(f"public.update_my_vehicle('{v['vehicle_id']}',1,'Van','VAN',-1,0,0,60)",error='INVALID_VEHICLE_FIELDS')
        self.query(f"INSERT INTO public.vehicles(vehicle_id,ngo_user_id,vehicle_label,payload_capacity_kg) VALUES('{LEGACY}','{A}','Legacy',1);")
        self.rpc(f"public.set_my_vehicle_availability('{LEGACY}',1,true)",error='INVALID_VEHICLE_FIELDS')
        self.rpc(f"public.update_my_vehicle('{LEGACY}',1,'Legacy','VAN',1,0,0,60)")
        self.rpc(f"public.set_my_vehicle_availability('{LEGACY}',2,true)")

    def test_database_constraints_reject_nonfinite_and_negative_cost(self):
        v=self.register(available='false')
        for field,value in [('fixed_cost_rm','-1'),('distance_cost_rm_per_km',"'NaN'::numeric"),
                            ('payload_capacity_kg',"'NaN'::numeric"),('max_route_duration_min',"'Infinity'::numeric")]:
            with self.subTest(field=field):
                self.query(f"UPDATE public.vehicles SET {field}={value} WHERE vehicle_id='{v['vehicle_id']}';",'vehicles_c1_fields')

    def test_failed_audit_rolls_back_registration(self):
        self.query("""CREATE FUNCTION public.c1_test_audit_failure() RETURNS trigger LANGUAGE plpgsql AS
          $$ BEGIN RAISE EXCEPTION 'AUDIT_FAULT'; END $$;
          CREATE TRIGGER c1_test_fail BEFORE INSERT ON public.audit_events FOR EACH ROW EXECUTE FUNCTION public.c1_test_audit_failure();""")
        try:
            self.rpc(f"public.register_my_vehicle('{REQ}','v','VAN',1,0,0,60,false)",error='AUDIT_FAULT')
            self.assertEqual(self.query('SELECT count(*) FROM public.vehicles;'),'0')
        finally:
            self.query('DROP TRIGGER c1_test_fail ON public.audit_events; DROP FUNCTION public.c1_test_audit_failure();')

    def test_unreviewed_policy_aborts_migration(self):
        self.query('CREATE POLICY c1_test_policy ON public.vehicles FOR SELECT TO authenticated USING(true);')
        try: self.query(SQL,'UNREVIEWED_VEHICLE_POLICIES')
        finally: self.query('DROP POLICY c1_test_policy ON public.vehicles;')

    def test_private_search_path_and_execute_acls(self):
        self.assertEqual(self.query("""SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
          WHERE (n.nspname='fleet_private' OR p.proname IN ('register_my_vehicle','list_my_vehicles','update_my_vehicle',
          'set_my_vehicle_availability','deactivate_my_vehicle')) AND
          (NOT p.prosecdef OR p.proconfig IS DISTINCT FROM ARRAY['search_path=pg_catalog, pg_temp']);"""),'0')
        self.assertEqual(self.query("SELECT has_function_privilege('anon','public.list_my_vehicles()','EXECUTE');"),'f')
        self.assertEqual(self.query("SELECT has_function_privilege('service_role','public.list_my_vehicles()','EXECUTE');"),'f')
        self.assertEqual(self.query("SELECT has_function_privilege('authenticated','public.list_my_vehicles()','EXECUTE');"),'t')

    @contextmanager
    def concurrent(self,sql):
        out=tempfile.TemporaryFile(mode='w+',encoding='utf-8')
        env=dict(self.env,PGAPPNAME='c1-fleet-race')
        proc=subprocess.Popen(self.args(sql),env=env,creationflags=self.flags,stdout=out,stderr=out)
        try:
            for _ in range(150):
                if self.query("SELECT exists(SELECT 1 FROM pg_stat_activity WHERE application_name='c1-fleet-race' AND wait_event='PgSleep');")=='t': break
                time.sleep(.02)
            else: self.fail('Concurrent transaction did not reach guarded pause')
            yield
        finally:
            proc.wait(timeout=10); out.seek(0); message=out.read(); out.close()
            self.assertEqual(proc.returncode,0,message)

    def test_race_route_first_blocks_deactivation(self):
        v=self.register(); vid=v['vehicle_id']
        with self.concurrent(f"BEGIN; INSERT INTO public.pickup_routes(ngo_user_id,vehicle_id) VALUES('{A}','{vid}'); SELECT pg_sleep(1.2); COMMIT;"):
            self.rpc(f"public.deactivate_my_vehicle('{vid}',1)",error='VEHICLE_HAS_ACTIVE_ROUTE')

    def test_race_deactivation_first_blocks_route(self):
        v=self.register(); vid=v['vehicle_id']
        with self.concurrent(f"BEGIN; UPDATE public.vehicles SET active_flag=false,available_for_planning=false WHERE vehicle_id='{vid}'; SELECT pg_sleep(1.2); COMMIT;"):
            self.query(f"INSERT INTO public.pickup_routes(ngo_user_id,vehicle_id) VALUES('{A}','{vid}');",'VEHICLE_NOT_AVAILABLE')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-isolated',action='store_true',required=True)
    parser.parse_args()
    FleetTests.bins={n:shutil.which(n) for n in ['initdb','pg_ctl','psql']}
    if not all(FleetTests.bins.values()): parser.error('PostgreSQL initdb, pg_ctl and psql must be on PATH')
    unittest.main(argv=[__file__],verbosity=2)
