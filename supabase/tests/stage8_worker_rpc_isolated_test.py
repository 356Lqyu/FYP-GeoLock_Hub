"""FOCUSED local worker/RPC integration. NEW loopback cluster, never Supabase.

Reuses the existing reduced C1/integration SQL fixture. Dedicated LOGINs exercise
real PostgreSQL grants/role checks; NGO authentication is an explicit test double.
No DSN argument or external database is accepted by this runner.
"""
from datetime import timedelta
from pathlib import Path
from tempfile import TemporaryDirectory
import argparse
import json
import sys
import unittest

import stage8_integration_isolated_test as source
import psycopg

from backend.routing.worker_service.errors import WorkerError
from backend.routing.worker_service.graph_cache import GraphCache
from backend.routing.worker_service.journal import Journal
from backend.routing.worker_service.orchestrator import RoutingWorker
from backend.routing.worker_service.transport import RoleRpc
from backend.routing.worker_service.validator import Validator


class LocalNgoSession:
    """Synthetic auth.uid fixture, not proof of real JWT/RLS behavior."""
    def __init__(self,test,user=source.A):self.test,self.user_id=test,user
    def rpc(self,name,params=None):
        t=self.test
        if name=='list_my_vehicles':return t.jrpc('public.list_my_vehicles()',user=self.user_id)
        if name=='get_my_claim_cards_v2':
            return json.loads(t.query(f"""SELECT coalesce(jsonb_agg(jsonb_build_object('claim_id',c.claim_id,'claim_status',c.claim_status,
             'lease_status',le.lease_status,'lease_id',le.lease_id,'lease_expires_at',le.expires_at,'task_status',p.task_status)),'[]')
             FROM public.donation_claims c JOIN public.claim_leases le USING(claim_id) JOIN public.pickup_tasks p USING(claim_id)
             WHERE c.ngo_user_id='{self.user_id}';"""))
        if name=='authorize_my_routing_candidate':
            return t.jrpc(f"public.authorize_my_routing_candidate('{params['p_request']}','{params['p_candidate']}','{params['p_depart_at']}')",user=self.user_id)
        raise AssertionError(name)


class WorkerRpcTests(source.IntegrationTests):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.query("""
         CREATE ROLE geolock_graph_login LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
         CREATE ROLE geolock_planner_login LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
         CREATE ROLE geolock_validator_login LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
         GRANT geolock_graph_worker TO geolock_graph_login;
         GRANT geolock_planner TO geolock_planner_login;
         GRANT geolock_validator TO geolock_validator_login;
        """)
        cls.db='postgres'
        cls.query("INSERT INTO public.road_network_edges(edge_id,source_node,target_node,road_km,travel_minutes) VALUES(1,101,102,1,1),(2,102,101,1,1);")
        cls.db='template1'

    def setUp(self):
        super().setUp()
        self.tmp=TemporaryDirectory(prefix='geolock-worker-test-');self.addCleanup(self.tmp.cleanup)

    def role(self,scope):
        role='geolock_'+scope
        login={'graph_worker':'geolock_graph_login','planner':'geolock_planner_login','validator':'geolock_validator_login'}[scope]
        # This injected local connector intentionally cannot be selected by the
        # production CLI; production DSNs require DEV host + verified TLS.
        return RoleRpc('',role,connect=lambda:psycopg.connect(host='127.0.0.1',hostaddr='127.0.0.1',port=self.port,user=login,dbname=self.database,sslmode='disable',options='',connect_timeout=3))

    def setup_worker(self):
        f=self.prepare()
        self.planner=self.role('planner');self.graph_rpc=self.role('graph_worker');self.validator_rpc=self.role('validator')
        gid=self.query('SELECT graph_id FROM routing_private.graphs LIMIT 1;')
        self.graph=GraphCache(self.graph_rpc,gid,Path(self.tmp.name)/'graphs')
        pid=f['bundle']['snapshot']['policy_id'];request=self.req()
        snap=self.jrpc(f"public.begin_my_routing_snapshot('{request}','{pid}',ARRAY['{f['vehicle']['vehicle_id']}'::uuid])")
        self.worker=RoutingWorker(self.planner,self.graph,Validator(self.validator_rpc),Journal(Path(self.tmp.name)/'journal'))
        return snap,request,LocalNgoSession(self)

    def test_worker_real_rpc_pipeline_and_explicit_owner_authorization(self):
        snap,request,session=self.setup_worker()
        result=self.worker.plan(session,snap['snapshot_id'],request)
        self.assertEqual(result['validation_status'],'ATTESTED')
        self.assertFalse(result['dispatch_authority_issued'])
        self.assertEqual(self.query('SELECT count(*) FROM public.pickup_routes;'),'0')
        self.assertEqual(self.query('SELECT count(*) FROM public.active_task_route_assignments;'),'0')
        departure=(self.planner.now()+timedelta(seconds=5)).isoformat()
        receipt=self.worker.authorize(session,self.req(),result['candidate_id'],departure)
        self.assertEqual(len(receipt['route_ids']),1)
        self.assertEqual(self.query('SELECT route_status FROM public.pickup_routes;'),'AUTHORISED')
        self.assertEqual(self.query('SELECT donation_status FROM public.donations;'),'CLAIMED')

    def test_worker_committed_submit_lost_ack_is_restart_safe(self):
        snap,request,session=self.setup_worker();actual=self.planner
        class DropOnce:
            lost=False
            def now(self):return actual.now()
            def call(inner,name,*args):
                result=actual.call(name,*args)
                if name=='submit_routing_candidate' and not inner.lost:
                    inner.lost=True;raise WorkerError('RPC_OUTCOME_UNKNOWN_RETRY_SAME_REQUEST',503,True)
                return result
        self.worker.planner=DropOnce()
        with self.assertRaises(WorkerError):self.worker.plan(session,snap['snapshot_id'],request)
        before=self.query('SELECT count(*) FROM routing_private.candidates;')
        restarted=RoutingWorker(actual,self.graph,Validator(self.validator_rpc),Journal(Path(self.tmp.name)/'journal'),solve=lambda _:self.fail('Unnecessary re-solve'))
        result=restarted.plan(session,snap['snapshot_id'],request)
        self.assertEqual(result['validation_status'],'ATTESTED')
        self.assertEqual(before,self.query('SELECT count(*) FROM routing_private.candidates;'))
        self.assertEqual(self.query('SELECT count(*) FROM public.active_task_route_assignments;'),'0')

    def test_worker_foreign_snapshot_denied_without_artifact_writes(self):
        snap,request,_=self.setup_worker()
        before=self.query('SELECT count(*) FROM routing_private.matrices;')
        with self.assertRaises(WorkerError) as caught:self.worker.plan(LocalNgoSession(self,source.B),snap['snapshot_id'],request)
        self.assertEqual(caught.exception.status,403)
        self.assertEqual(before,self.query('SELECT count(*) FROM routing_private.matrices;'))

    def test_worker_logins_cannot_use_other_worker_role(self):
        self.prepare()
        graph=self.role('graph_worker')
        wrong=RoleRpc('','geolock_validator',connect=graph._connect)
        with self.assertRaises(WorkerError) as caught:wrong.call('read_routing_work_item',self.req())
        self.assertEqual(caught.exception.code,'WORKER_DATABASE_PERMISSION_DENIED')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-isolated',required=True,action='store_true');parser.parse_args()
    names=[n for n in unittest.defaultTestLoader.getTestCaseNames(WorkerRpcTests) if n.startswith('test_worker_')]
    result=unittest.TextTestRunner(verbosity=2).run(unittest.TestSuite(WorkerRpcTests(n) for n in names))
    sys.exit(not result.wasSuccessful())
