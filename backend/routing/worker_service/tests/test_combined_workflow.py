"""Offline RPC doubles. No Supabase credentials, network or business records."""
from concurrent.futures import ThreadPoolExecutor
from tempfile import TemporaryDirectory
import threading
import unittest
from unittest.mock import Mock

from .test_worker_flow import FakeDatabase,FakeGraph,FakeSession,SID,OWNER,REQ
from backend.routing.worker_service.journal import Journal
from backend.routing.worker_service.orchestrator import RoutingWorker,step_id
from backend.routing.worker_service.validator import Validator
from backend.routing.worker_service.server import Application
from backend.routing.worker_service.errors import WorkerError

class CombinedSession(FakeSession):
    def __init__(self,db):super().__init__(db);self.receipt=None;self.auth_calls=0;self.lost=False;self.ready=None;self.release=None
    def rpc(self,name,params=None):
        if name=='get_my_routing_authorization_receipt':
            value=dict(contract='geolock.routing-auto-now.v1',ngo_id=self.user_id,request_id=params['p_request'],outcome='FOUND' if self.receipt else 'NOT_FOUND')
            if self.receipt:value['result']=self.receipt
            return value
        if name=='authorize_my_routing_candidate':
            self.auth_calls+=1
            assert params['p_depart_at'] is None
            if self.ready:self.ready.set();self.release.wait(10)
            self.receipt=dict(candidate_id=params['p_candidate'],route_ids=['local-authorized-route'],snapshot_id=SID,departure_mode='AUTO_NOW',planned_departure_at='2026-10-24T00:00:00Z')
            if self.lost:raise WorkerError('UPSTREAM_OUTCOME_UNKNOWN_RETRY',503,True)
            return self.receipt
        return super().rpc(name,params)

class CombinedTests(unittest.TestCase):
    def setUp(self):
        self.temp=TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.db=FakeDatabase();self.session=CombinedSession(self.db)
        self.graph=FakeGraph(self.db);self.journal=Journal(self.temp.name)
        self.worker=RoutingWorker(self.db,self.graph,Validator(self.db),self.journal)

    def test_combined_attests_then_authorizes_once_with_null_departure(self):
        result=self.worker.plan_and_authorize(self.session,SID,REQ)
        self.assertEqual(result['kind'],'DATABASE_AUTHORIZATION_RECEIPT')
        self.assertEqual(result['planning']['validation_status'],'ATTESTED')
        self.assertIsNotNone(self.db.attestation);self.assertEqual(self.session.auth_calls,1)
        payload=self.journal.get(SID,'automatic_authorization_request')
        self.assertEqual(payload['p_request'],step_id(SID,'authorize-auto-now'))
        self.assertIsNone(payload['p_depart_at'])
        self.assertEqual([row['method'] for row in result['planning']['methods']],
                         ['fcfs', 'nearest_neighbour', 'proposed'])
        self.assertEqual(self.db.candidate['body']['plan']['method'], 'proposed')
        self.assertEqual(self.db.calls.count('submit_routing_candidate'), 1)
        self.assertEqual(self.db.calls.count('attest_routing_candidate'), 1)
        self.assertEqual(payload['p_candidate'], self.db.candidate['candidate_id'])

    def test_no_feasible_proposed_plan_never_attests_or_authorizes(self):
        for vehicle in self.db.bundle['snapshot']['body']['vehicles']:
            vehicle['payload_capacity_kg'] = 1
        result = self.worker.plan_and_authorize(self.session, SID, REQ)
        self.assertEqual(result['outcome'], 'INFEASIBLE')
        self.assertIsNone(self.db.candidate)
        self.assertIsNone(self.db.attestation)
        self.assertEqual(self.session.auth_calls, 0)

    def test_lost_response_reconciles_read_only_and_replay_never_replans(self):
        self.session.lost=True
        with self.assertRaises(WorkerError):self.worker.plan_and_authorize(self.session,SID,REQ)
        before=self.journal.get(SID,'result');self.worker.solve=lambda _:self.fail('Repeated solver')
        result=self.worker.authorization_result(self.session,SID,REQ)
        self.assertEqual(result['kind'],'DATABASE_AUTHORIZATION_RECEIPT')
        self.worker.plan_and_authorize(self.session,SID,REQ)
        self.assertEqual(self.session.auth_calls,1);self.assertEqual(self.graph.builds,1)
        self.assertEqual(self.journal.get(SID,'result'),before)

    def test_no_receipt_read_does_not_plan_authorize_or_create_journal_steps(self):
        self.db.bundle['snapshot']['matrix_id']=None
        result=self.worker.authorization_result(self.session,SID,REQ)
        self.assertEqual(result['kind'],'AUTHORIZATION_UNCONFIRMED')
        self.assertEqual(self.session.auth_calls,0);self.assertEqual(self.graph.builds,0)
        self.assertIsNone(self.journal.get(SID,'automatic_authorization_intent'))

    def test_existing_saved_advisory_is_never_automatically_authorized(self):
        self.worker.plan(self.session,SID,REQ)
        with self.assertRaises(WorkerError) as error:self.worker.plan_and_authorize(self.session,SID,REQ)
        self.assertEqual(error.exception.code,'SAVED_ADVISORY_RESULT_NOT_AUTO_AUTHORIZABLE')
        self.assertEqual(self.session.auth_calls,0)
        self.worker.saved_result(self.session,SID,REQ)
        self.assertEqual(self.session.auth_calls,0)

    def test_missing_migration_fails_before_any_planner_write(self):
        old=self.session.rpc
        self.session.rpc=lambda name,params=None:{} if name=='get_my_routing_authorization_receipt' else old(name,params)
        with self.assertRaises(WorkerError):self.worker.plan_and_authorize(self.session,SID,REQ)
        self.assertEqual(self.graph.builds,0);self.assertIsNone(self.db.candidate)

    def test_combined_endpoint_requires_explicit_intent_and_verified_session(self):
        auth=Mock();auth.verify.return_value=self.session
        app=Application(auth=auth,worker=self.worker,active=True)
        for body in [dict(request_id=REQ,snapshot_id=SID),dict(request_id=REQ,snapshot_id=SID,authorize_on_success=False)]:
            with self.assertRaises(WorkerError):app.dispatch('/v1/plan-and-authorize','Bearer synthetic',body)
        self.assertEqual(self.session.auth_calls,0)

    def test_concurrent_duplicate_is_busy_then_replays_same_receipt(self):
        self.session.ready=threading.Event();self.session.release=threading.Event()
        with ThreadPoolExecutor(max_workers=2) as pool:
            first=pool.submit(self.worker.plan_and_authorize,self.session,SID,REQ)
            self.assertTrue(self.session.ready.wait(15))
            with self.assertRaises(WorkerError):self.worker.plan_and_authorize(self.session,SID,REQ)
            self.session.release.set();receipt=first.result(timeout=15)
        replay=self.worker.plan_and_authorize(self.session,SID,REQ)
        self.assertEqual(receipt['authorization'],replay['authorization']);self.assertEqual(self.session.auth_calls,1)

    def test_default_gate_and_rejected_jwt_never_call_planner(self):
        auth=Mock();auth.verify.return_value=self.session;worker=Mock()
        app=Application(auth=auth,worker=worker,active=True)
        with self.assertRaises(WorkerError) as error:
            app.dispatch('/v1/plan-and-authorize','Bearer synthetic',dict(request_id=REQ,snapshot_id=SID,authorize_on_success=True))
        self.assertEqual(error.exception.code,'COMBINED_WORKFLOW_DISABLED');worker.plan_and_authorize.assert_not_called()
        auth.verify.side_effect=WorkerError('AUTHENTICATION_REQUIRED',401)
        app.combined_enabled=True
        with self.assertRaises(WorkerError):app.dispatch('/v1/plan-and-authorize','Bearer rejected',dict(request_id=REQ,snapshot_id=SID,authorize_on_success=True))
        worker.plan_and_authorize.assert_not_called()

    def test_definitive_authorization_rejection_is_terminal_and_never_resubmitted(self):
        original=self.session.rpc;attempts=[]
        def reject(name,params=None):
            if name=='authorize_my_routing_candidate':
                attempts.append(params);raise WorkerError('SNAPSHOT_STALE_OR_RESERVATION_CONFLICT',409)
            return original(name,params)
        self.session.rpc=reject
        with self.assertRaises(WorkerError):self.worker.plan_and_authorize(self.session,SID,REQ)
        read=self.worker.authorization_result(self.session,SID,REQ)
        self.assertEqual(read['operation_terminal'],'REJECTED')
        with self.assertRaises(WorkerError):self.worker.plan_and_authorize(self.session,SID,REQ)
        self.assertEqual(len(attempts),1)

if __name__=='__main__':unittest.main()
