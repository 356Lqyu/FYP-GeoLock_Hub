"""Synthetic in-memory transports; REAL solvers/independent validator, never DEV."""
from copy import deepcopy
from datetime import timedelta
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch
from uuid import UUID
import json
import threading
import unittest

from backend.routing.integration.presentation import planning_response
from backend.routing.integration.tests.test_worker import synthetic_bundle
from backend.routing.integration.worker import timestamp
from backend.routing.worker_service.errors import WorkerError
from backend.routing.worker_service.journal import Journal
from backend.routing.worker_service.orchestrator import RoutingWorker
from backend.routing.worker_service.server import Application, application_from_env, body_json
from backend.routing.worker_service.transport import RoleRpc, SupabaseAuth, DEV, database_error, JsonHttp
from backend.routing.worker_service.validator import Validator

SID,OWNER,REQ,MID,GID,CID=[str(UUID(int=i)) for i in range(1,7)]


class FakeDatabase:
    """Explicit synthetic RPC double, including commit-before-response-loss."""
    def __init__(self):
        self.bundle=synthetic_bundle();s=self.bundle['snapshot'];raw=s['body']
        s.update(snapshot_id=SID,ngo_id=OWNER,request_id=REQ,matrix_id=None,sealed_at=None)
        raw['ngo']['user_id']=OWNER
        for v in raw['vehicles']:v['ngo_user_id']=OWNER
        for o in raw['observations']:o['task']['ngo_user_id']=o['claim']['ngo_user_id']=OWNER
        self.bundle['matrix'].update(matrix_id=MID,graph_id=GID)
        self.clock=timestamp(s['cutoff'])+timedelta(seconds=1)
        self.calls=[];self.candidate=None;self.attestation=None;self.lose_submit=False;self.authorized=False

    def now(self):return self.clock
    def call(self,name,*args):
        self.calls.append(name)
        if name=='read_pending_routing_snapshot':return deepcopy(self.bundle['snapshot'])
        if name=='store_routing_matrix':
            self.bundle['matrix']['body']=deepcopy(args[2]);return MID
        if name=='seal_routing_snapshot':
            self.bundle['snapshot'].update(matrix_id=MID,sealed_at=self.bundle['snapshot']['cutoff'])
            return deepcopy(self.bundle['snapshot'])
        if name=='read_routing_snapshot_bundle':return deepcopy(self.bundle)
        if name=='submit_routing_candidate':
            candidate=dict(candidate_id=CID,snapshot_id=SID,digest='c'*64,body=deepcopy(args[2]))
            if self.candidate is not None and self.candidate!=candidate:raise WorkerError('REQUEST_CONFLICT')
            self.candidate=candidate
            if self.lose_submit:
                self.lose_submit=False;raise WorkerError('RPC_OUTCOME_UNKNOWN_RETRY_SAME_REQUEST',503,True)
            return deepcopy(candidate)
        if name=='read_routing_work_item':return dict(deepcopy(self.bundle),candidate=deepcopy(self.candidate))
        if name=='attest_routing_candidate':self.attestation=args;return None
        raise AssertionError('Unexpected RPC '+name)


class FakeSession:
    def __init__(self,db,user_id=OWNER):self.db,self.user_id=db,user_id
    def rpc(self,name,params=None):
        if name=='list_my_vehicles':
            return dict(vehicles=[dict(deepcopy(v),eligible_for_planning=True) for v in self.db.bundle['snapshot']['body']['vehicles']])
        if name=='get_my_claim_cards_v2':
            return [dict(claim_id=o['claim']['claim_id'],claim_status=o['claim']['claim_status'],lease_status=o['lease']['lease_status'],
                lease_id=o['lease']['lease_id'],lease_expires_at=o['lease']['expires_at'],task_status=o['task']['task_status']) for o in self.db.bundle['snapshot']['body']['observations']]
        if name=='authorize_my_routing_candidate':
            self.db.authorized=True;return dict(candidate_id=params['p_candidate'],route_ids=['synthetic-route'])
        raise AssertionError(name)


class FakeGraph:
    graph_id=GID
    def __init__(self,db):self.db=self.rpc=db;self.builds=0
    def matrix(self,nodes):self.builds+=1;return deepcopy(self.db.bundle['matrix']['body'])


class FlowTests(unittest.TestCase):
    def setUp(self):
        self.temp=TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.db=FakeDatabase();self.graph=FakeGraph(self.db);self.session=FakeSession(self.db)
        self.journal=Journal(self.temp.name)
        self.worker=RoutingWorker(self.db,self.graph,Validator(self.db),self.journal)

    def test_three_operational_methods_and_independent_attestation_never_reserve(self):
        events=[];self.worker.observe=events.append
        result=self.worker.plan(self.session,SID,REQ)
        self.assertEqual({x['method'] for x in result['methods']},{'fcfs','nearest_neighbour','proposed'})
        self.assertEqual(result['validation_status'],'ATTESTED')
        self.assertIsNotNone(self.db.attestation)
        self.assertFalse(result['dispatch_authority_issued']);self.assertFalse(self.db.authorized)
        self.assertNotIn('start_pickup',self.db.calls)
        self.assertEqual([e['stage'] for e in events],['read_pending_snapshot','verify_snapshot_freshness',
            'build_road_matrix','store_and_seal_matrix','four_method_optimization','submit_candidate',
            'independent_validation','candidate_ready'])
        self.assertTrue(all(e['request_id']==REQ and e['snapshot_id']==SID for e in events))

    def test_lost_submit_ack_resumes_exact_payload_without_resolving(self):
        self.db.lose_submit=True
        with self.assertRaises(WorkerError):self.worker.plan(self.session,SID,REQ)
        payload=deepcopy(self.db.candidate)
        restarted=RoutingWorker(self.db,self.graph,Validator(self.db),Journal(self.temp.name),solve=lambda _:self.fail('Repeated solve after persisted payload'))
        result=restarted.plan(self.session,SID,REQ)
        self.assertEqual(result['candidate_id'],CID);self.assertEqual(payload,self.db.candidate)
        self.assertEqual(self.graph.builds,1)

    def test_completed_retry_returns_same_advisory_result(self):
        first=self.worker.plan(self.session,SID,REQ)
        submits=self.db.calls.count('submit_routing_candidate')
        self.assertEqual(first,self.worker.plan(self.session,SID,REQ))
        self.assertEqual(submits,self.db.calls.count('submit_routing_candidate'))

    def test_saved_result_read_preserves_historical_receipt_without_replanning(self):
        def legacy_response(*args):
            response = planning_response(*args)
            duplicate = deepcopy(response['methods'][-1])
            duplicate['method'] = duplicate['plan']['method'] = 'distance_only'
            response['methods'].insert(2, duplicate)
            return response

        with patch('backend.routing.worker_service.orchestrator.planning_response', legacy_response):
            first = self.worker.plan(self.session, SID, REQ)
        self.db.clock+=timedelta(days=1)  # Display is allowed; this is NOT authority.
        before=self.journal.get(SID,'result'); self.db.calls.clear()
        self.worker.solve=lambda _:self.fail('Saved display must not solve')
        with patch.object(self.graph,'matrix',side_effect=AssertionError('No matrix build')):
            shown=self.worker.saved_result(self.session,SID,REQ)
        self.assertEqual(shown['candidate_id'],first['candidate_id'])
        self.assertEqual(shown['methods'], first['methods'])
        self.assertEqual(len(shown['methods']), 4)
        self.assertTrue(shown['saved_result_display_only'])
        self.assertEqual(self.db.calls,['read_routing_snapshot_bundle'])
        self.assertEqual(self.journal.get(SID,'result'),before)
        self.assertFalse(self.db.authorized)

    def test_saved_result_denies_foreign_owner_and_wrong_request_before_database_read(self):
        self.worker.plan(self.session,SID,REQ); self.db.calls.clear()
        for session,request in [(FakeSession(self.db,str(UUID(int=99))),REQ),(self.session,str(UUID(int=98)))]:
            with self.assertRaises(WorkerError): self.worker.saved_result(session,SID,request)
        self.assertEqual(self.db.calls,[])

    def test_committed_attestation_lost_ack_can_be_retried(self):
        actual=Validator(self.db)
        class DropOnce:
            lost=False
            def validate(inner,*args):
                result=actual.validate(*args)
                if not inner.lost:
                    inner.lost=True;raise WorkerError('RPC_OUTCOME_UNKNOWN_RETRY_SAME_REQUEST',503,True)
                return result
        self.worker.validator=DropOnce()
        with self.assertRaises(WorkerError):self.worker.plan(self.session,SID,REQ)
        first=deepcopy(self.db.attestation)
        result=self.worker.plan(self.session,SID,REQ)
        self.assertEqual(result['validation_status'],'ATTESTED');self.assertEqual(first,self.db.attestation)

    def test_cross_ngo_is_rejected_before_any_mutating_rpc(self):
        with self.assertRaises(WorkerError) as caught:self.worker.plan(FakeSession(self.db,str(UUID(int=99))),SID,REQ)
        self.assertEqual(caught.exception.status,403)
        self.assertEqual(self.db.calls,['read_pending_routing_snapshot'])

    def test_request_is_bound_to_snapshot_request_key(self):
        with self.assertRaises(WorkerError):self.worker.plan(self.session,SID,str(UUID(int=99)))
        self.assertEqual(self.db.calls,['read_pending_routing_snapshot'])

    def test_stale_snapshot_has_no_mutating_rpc(self):
        self.db.clock+=timedelta(minutes=6)
        with self.assertRaises(WorkerError) as caught:self.worker.plan(self.session,SID,REQ)
        self.assertEqual(caught.exception.code,'SNAPSHOT_STALE')
        self.assertEqual(self.db.calls,['read_pending_routing_snapshot'])

    def test_infeasible_vehicles_never_create_a_candidate(self):
        for v in self.db.bundle['snapshot']['body']['vehicles']:v['payload_capacity_kg']=1
        result=self.worker.plan(self.session,SID,REQ)
        self.assertEqual(result['outcome'],'INFEASIBLE')
        self.assertNotIn('candidate_id',result);self.assertIsNone(self.db.candidate)
        self.assertTrue(all(m['validation']['valid'] for m in result['methods']))

    def test_zero_vehicles_is_explicit_without_default(self):
        self.db.bundle['snapshot']['body']['vehicles']=[]
        with self.assertRaises(WorkerError) as caught:self.worker.plan(self.session,SID,REQ)
        self.assertEqual(caught.exception.code,'NO_ELIGIBLE_VEHICLES')
        self.assertIsNone(self.db.candidate)

    def test_unreachable_roads_are_not_stored_or_published(self):
        self.graph.matrix=lambda _:(_ for _ in ()).throw(WorkerError('ROUTE_UNAVAILABLE',422))
        with self.assertRaises(WorkerError):self.worker.plan(self.session,SID,REQ)
        self.assertNotIn('store_routing_matrix',self.db.calls)

    def test_validation_failure_never_claims_attested_success(self):
        self.worker.validator=type('Rejector',(),{'validate':lambda *args:(_ for _ in ()).throw(WorkerError('REJECTED',422))})()
        with self.assertRaises(WorkerError):self.worker.plan(self.session,SID,REQ)
        self.assertIsNone(self.journal.get(SID,'result'));self.assertFalse(self.db.authorized)

    def test_authorization_uses_caller_session_not_worker_role(self):
        result=self.worker.authorize(self.session,REQ,CID,'2026-10-24T00:10:00Z')
        self.assertEqual(result['candidate_id'],CID);self.assertEqual(self.db.calls,[])

    def test_failed_reservation_is_not_repaired_or_converted_to_success(self):
        self.session.rpc=lambda *args:(_ for _ in ()).throw(WorkerError('SNAPSHOT_STALE_OR_RESERVATION_CONFLICT',409))
        with self.assertRaises(WorkerError):self.worker.authorize(self.session,REQ,CID,'2026-10-24T00:10:00Z')
        self.assertFalse(self.db.authorized);self.assertEqual(self.db.calls,[])

    def test_independent_validator_rebuilds_and_rejects_tamper(self):
        self.worker.plan(self.session,SID,REQ)
        self.db.attestation=None
        self.db.candidate['body']['plan']['routes'][0]['stops'][0]['road_node_id']='999'
        with self.assertRaises(ValueError):Validator(self.db).validate(CID,SID,OWNER)
        self.assertIsNone(self.db.attestation)

    def test_journal_is_restart_safe_and_never_overwrites_changed_payload(self):
        self.journal.save(SID,'unit',{'request':'synthetic'})
        self.assertEqual(Journal(self.temp.name).get(SID,'unit'),{'request':'synthetic'})
        with self.assertRaises(WorkerError):self.journal.save(SID,'unit',{'changed':True})

    def test_duplicate_local_job_is_busy_and_lock_is_released(self):
        with self.journal.claim(SID,OWNER,REQ):
            with self.assertRaises(WorkerError):
                with Journal(self.temp.name).claim(SID,OWNER,REQ):pass
        with self.journal.claim(SID,OWNER,REQ):pass


class SecurityTests(unittest.TestCase):
    def test_default_startup_disabled_without_network(self):
        app=application_from_env('planner',{})
        with self.assertRaises(WorkerError) as caught:app.dispatch('/v1/plan','Bearer synthetic',{})
        self.assertEqual(caught.exception.code,'WORKER_NOT_ACTIVATED')

    def test_wrong_project_dsn_and_superuser_login_rejected(self):
        for dsn in ('host=db.other.supabase.co user=geolock_planner_login sslmode=verify-full sslrootcert=system',
                    'host=db.'+DEV+'.supabase.co user=postgres sslmode=verify-full sslrootcert=system',
                    'host=db.'+DEV+'.supabase.co user=geolock_planner_login sslmode=require'):
            with self.assertRaises(WorkerError):RoleRpc.validate_dsn(dsn)

    def test_whitelist_rejects_lifecycle_or_validator_calls_before_connection(self):
        rpc=RoleRpc('','geolock_planner',connect=lambda:self.fail('Connected'))
        for name in ('start_pickup','complete_pickup','claim_listing','attest_routing_candidate'):
            with self.assertRaises(WorkerError):rpc.call(name)

    def test_auth_verification_is_server_side_and_ngo_rpc_uses_same_token(self):
        class Http:
            def __init__(self):self.calls=[]
            def request(self,url,**kwargs):
                self.calls.append((url,kwargs))
                return {'id':OWNER} if url.endswith('/user') else {'vehicles':[]}
        http=Http();auth=SupabaseAuth('sb_publishable_SYNTHETIC',http)
        session=auth.verify('Bearer SYNTHETIC_NOT_A_REAL_JWT')
        self.assertEqual(session.user_id,OWNER)
        self.assertEqual(len(http.calls),2)
        self.assertTrue(all('rcgyuwiidqvrgbxswhqj.supabase.co' in c[0] for c in http.calls))
        self.assertEqual(http.calls[0][1]['token'],http.calls[1][1]['token'])

    def test_auth_rejection_never_invokes_worker(self):
        auth=type('Auth',(),{'verify':lambda *args:(_ for _ in ()).throw(WorkerError('AUTHENTICATION_REQUIRED',401))})()
        app=Application(auth=auth,worker=object(),active=True)
        with self.assertRaises(WorkerError) as caught:app.dispatch('/v1/plan','Bearer fake',{'snapshot_id':SID,'request_id':REQ})
        self.assertEqual(caught.exception.status,401)

    def test_validator_does_not_accept_a_user_jwt_or_success_boolean(self):
        app=Application(validator=object(),validator_token='synthetic-internal-secret-'*2,active=True)
        with self.assertRaises(WorkerError) as caught:app.dispatch('/v1/validate','Bearer user-jwt',{'valid':True})
        self.assertEqual(caught.exception.status,401)

    def test_duplicate_json_fields_rejected(self):
        with self.assertRaises(WorkerError):body_json(b'{"snapshot_id":"a","snapshot_id":"b"}')

    def test_database_target_overrides_ambient_pg_connection_settings(self):
        dsn='host=db.'+DEV+'.supabase.co user=geolock_planner_login sslmode=verify-full sslrootcert=system'
        with patch('psycopg.connect') as connect:
            RoleRpc(dsn,'geolock_planner')._connection()
            self.assertEqual(connect.call_args.kwargs['hostaddr'],'')
            self.assertEqual(connect.call_args.kwargs['host'],'db.'+DEV+'.supabase.co')
            self.assertEqual(connect.call_args.kwargs['options'],'')

    def test_raw_database_errors_are_not_exposed(self):
        err=database_error('XX000','SYNTHETIC_SECRET_THAT_MUST_NOT_LEAK')
        self.assertNotIn('SYNTHETIC_SECRET',str(err))

    def test_validator_unknown_commit_outcome_preserves_retry_signal(self):
        import io,urllib.error
        error=urllib.error.HTTPError('http://127.0.0.1:8788',503,'synthetic',{},io.BytesIO(b'{"error":{"code":"RPC_OUTCOME_UNKNOWN_RETRY_SAME_REQUEST"}}'))
        with patch('urllib.request.build_opener') as opener:
            opener.return_value.open.side_effect=error
            with self.assertRaises(WorkerError) as caught:JsonHttp().request('http://127.0.0.1:8788/v1/validate',token='synthetic',body={})
        self.assertTrue(caught.exception.retryable)
        self.assertEqual(caught.exception.status,503)


if __name__=='__main__':unittest.main()
