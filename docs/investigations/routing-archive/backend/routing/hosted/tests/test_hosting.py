from dataclasses import replace
from email.message import Message
from http.client import HTTPConnection
import ipaddress
import json
from pathlib import Path
from tempfile import TemporaryDirectory
from threading import Thread
import unittest
from unittest.mock import Mock

from psycopg.conninfo import make_conninfo
from ..config import Settings
from ..runtime import Runtime
from ..__main__ import BoundedServer, handler_for
from ...worker_service.errors import WorkerError
from ...worker_service.journal import Journal
from ...worker_service.orchestrator import RoutingWorker
from ...worker_service.server import Application
from ...worker_service.transport import DEV
from ...worker_service.validator import Validator
from ...worker_service.tests.test_combined_workflow import CombinedSession
from ...worker_service.tests.test_worker_flow import FakeDatabase, FakeGraph, SID, REQ
from ...worker_service.tests.test_graph_http import RoadRpc


def settings(**changes):
    return replace(Settings(mode='planner',active=True,public_url='https://routing.invalid',
        proxy_networks=(ipaddress.ip_network('127.0.0.1/32'),)), **changes)


class ConfigurationTests(unittest.TestCase):
    def test_default_disabled_never_reads_credentials_or_connects(self):
        config = Settings.from_env('planner',{})
        factory = Mock(side_effect=AssertionError('No database call'))
        runtime = Runtime(config,rpc_factory=factory)
        runtime.prepare()
        self.assertFalse(runtime.ready)
        factory.assert_not_called()

    def environment(self,tmp,mode='planner'):
        ca=Path(tmp)/'ca.pem';ca.write_text('SYNTHETIC CERTIFICATE; NEVER USED FOR NETWORK')
        env=dict(GEOLOCK_ROUTING_ALLOW_DEV_WRITES='APPROVED',GEOLOCK_PROJECT_REF=DEV,
            GEOLOCK_ROUTING_ACTIVATION_REF='OFFLINE-UNIT-ONLY',PORT='12345',GEOLOCK_PUBLIC_URL='https://routing.invalid',
            GEOLOCK_TRUSTED_PROXY_CIDRS='127.0.0.1/32',GEOLOCK_VALIDATOR_TOKEN='synthetic-token-'*4,
            GEOLOCK_STATE_MOUNT=tmp,GEOLOCK_WORKER_STATE=str(Path(tmp)/'state'),GEOLOCK_PERSISTENCE_MODE='mounted-disk',
            GEOLOCK_GRAPH_ID='00000000-0000-0000-0000-000000000005',
            GEOLOCK_SUPABASE_PUBLISHABLE_KEY='sb_publishable_SYNTHETIC_UNIT_ONLY',GEOLOCK_VALIDATOR_URL='https://validator.invalid')
        for role in (['GRAPH','PLANNER'] if mode=='planner' else ['VALIDATOR']):
            login={'GRAPH':'graph','PLANNER':'planner','VALIDATOR':'validator'}[role]
            env['GEOLOCK_'+role+'_DSN']=make_conninfo(host='db.'+DEV+'.supabase.co',user='geolock_'+login+'_login',
                dbname='postgres',port=5432,sslmode='verify-full',sslrootcert=str(ca))
            env['GEOLOCK_'+role+'_PASSWORD']='SYNTHETIC_PASSWORD_NEVER_USED'
        return env

    def test_roles_port_and_secrets_are_scoped_and_not_in_repr(self):
        with TemporaryDirectory() as tmp:
            for mode in ['planner','validator']:
                cfg=Settings.from_env(mode,self.environment(tmp,mode))
                self.assertEqual(cfg.port,12345)
                self.assertNotIn('SYNTHETIC_PASSWORD',repr(cfg))
                self.assertEqual(len(cfg.credentials),2 if mode=='planner' else 1)

    def test_bad_target_cross_role_wildcard_and_ephemeral_mode_are_rejected(self):
        with TemporaryDirectory() as tmp:
            changes=[{'GEOLOCK_PROJECT_REF':'other'}, {'GEOLOCK_TRUSTED_PROXY_CIDRS':'0.0.0.0/0'},
                     {'GEOLOCK_VALIDATOR_DSN':'forbidden'}, {'GEOLOCK_PERSISTENCE_MODE':'ephemeral'},
                     {'GEOLOCK_PUBLIC_URL':'http://routing.invalid'}, {'GEOLOCK_GRAPH_ENGINE':'unknown'}]
            for change in changes:
                with self.subTest(change=next(iter(change))),self.assertRaises(WorkerError):
                    Settings.from_env('planner',dict(self.environment(tmp),**change))

    def test_forwarded_headers_require_actual_peer_and_exact_https_host(self):
        cfg=settings();headers=Message()
        headers['Host']='routing.invalid';headers['X-Forwarded-Proto']='https'
        self.assertTrue(cfg.trusted_https('127.0.0.1',headers))
        headers['X-Forwarded-For']='127.0.0.1'
        self.assertFalse(cfg.trusted_https('192.0.2.1',headers))
        headers['X-Forwarded-Proto']='http'
        self.assertFalse(cfg.trusted_https('127.0.0.1',headers))

    def test_unmounted_disk_prevents_any_database_call(self):
        factory=Mock(side_effect=AssertionError('No DB'))
        runtime=Runtime(settings(),rpc_factory=factory,mount_check=lambda _:False)
        runtime.prepare()
        self.assertEqual(runtime.reason,'PERSISTENT_MOUNT_NOT_VERIFIED')
        factory.assert_not_called()

    def test_validator_readiness_uses_only_validator_identity(self):
        factory=Mock(return_value=Mock())
        runtime=Runtime(settings(mode='validator',validator_token='x'*32),rpc_factory=factory)
        runtime.prepare()
        self.assertTrue(runtime.ready)
        factory.assert_called_once_with('geolock_validator')
        factory.return_value.now.assert_called_once_with()

    def test_planner_prewarms_before_ready_and_singleton_lock_is_preserved(self):
        with TemporaryDirectory() as tmp:
            db=FakeDatabase();graph=RoadRpc();roles=[]
            def factory(role):
                roles.append(role)
                return graph if role=='geolock_graph_worker' else db
            cfg=settings(state=Path(tmp)/'state',mount=Path(tmp),graph_id='00000000-0000-0000-0000-000000000005',
                         graph_engine='compact',validator_url='https://validator.invalid',validator_token='x'*32,
                         publishable_key='sb_publishable_SYNTHETIC_UNIT_ONLY')
            first=Runtime(cfg,rpc_factory=factory,mount_check=lambda _:True,
                          validator_health=lambda:dict(status='ACTIVE',project_ref=DEV))
            first.prepare();self.addCleanup(first.close)
            self.assertTrue(first.ready and first.graph_ready)
            self.assertEqual(roles,['geolock_graph_worker','geolock_planner'])
            second=Runtime(cfg,rpc_factory=factory,mount_check=lambda _:True)
            second.prepare();self.addCleanup(second.close)
            self.assertFalse(second.ready)
            self.assertEqual(second.reason,'JOB_IN_PROGRESS_RETRY_SAME_REQUEST')
            second.close()
            first.close()  # Release before TemporaryDirectory exits on Windows.


class HttpTests(unittest.TestCase):
    def test_independent_validator_rejects_client_bearer_before_rpc(self):
        self.runtime.ready=True
        self.runtime.app=Application(validator=Validator(self.db),validator_token='v'*32,active=True)
        response=self.request('/v1/validate',dict(candidate_id='00000000-0000-0000-0000-000000000006',
                              snapshot_id=SID,ngo_id='00000000-0000-0000-0000-000000000002'))
        self.assertEqual(response[0],401)
        self.assertEqual(self.db.calls,[])

    def setUp(self):
        self.tmp=TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.runtime=Runtime(settings())
        self.db=FakeDatabase();self.session=CombinedSession(self.db)
        worker=RoutingWorker(self.db,FakeGraph(self.db),Validator(self.db),Journal(Path(self.tmp.name)/'journal'))
        self.runtime.app=Application(auth=Mock(verify=Mock(return_value=self.session)),worker=worker,active=True,combined_enabled=True)
        self.server=BoundedServer(('127.0.0.1',0),handler_for(self.runtime))
        self.thread=Thread(target=self.server.serve_forever,daemon=True);self.thread.start()
        self.addCleanup(self.shutdown)

    def shutdown(self):
        self.server.shutdown();self.server.server_close();self.thread.join()

    def request(self,path,body=None,*,headers=None):
        conn=HTTPConnection('127.0.0.1',self.server.server_port,timeout=10)
        try:
            values={'Host':'routing.invalid','X-Forwarded-Proto':'https','Authorization':'Bearer SYNTHETIC',
                    'Content-Type':'application/json'}
            values.update(headers or {})
            conn.request('POST' if body is not None else 'GET',path,
                         json.dumps(body).encode() if body is not None else None,values)
            result=conn.getresponse()
            return result.status,json.loads(result.read())
        finally:conn.close()

    def test_live_and_readiness_are_distinct_and_generation_blocked(self):
        self.assertEqual(self.request('/live')[0],200)
        self.assertEqual(self.request('/health')[0],503)
        self.assertEqual(self.request('/v1/plan-and-authorize',{})[0],503)
        self.assertEqual(self.db.calls,[])

    def test_https_and_auth_failures_never_create_snapshot_or_route(self):
        self.runtime.ready=True
        self.assertEqual(self.request('/v1/plan-and-authorize',{},headers={'X-Forwarded-Proto':'http'})[0],403)
        self.runtime.app.auth.verify.side_effect=WorkerError('AUTHENTICATION_REQUIRED',401)
        self.assertEqual(self.request('/v1/plan-and-authorize',{})[0],401)
        self.assertEqual(self.db.calls,[])

    def test_receipt_and_original_uuid_replay_are_wire_compatible_after_restart(self):
        self.runtime.ready=True
        body=dict(snapshot_id=SID,request_id=REQ,authorize_on_success=True)
        status,result=self.request('/v1/plan-and-authorize',body)
        self.assertEqual(status,200)
        self.assertEqual(result['kind'],'DATABASE_AUTHORIZATION_RECEIPT')
        self.assertEqual(self.session.auth_calls,1)
        self.assertIsNotNone(self.db.attestation)
        self.runtime.ready=False  # recovery is allowed even when graph not ready
        status,saved=self.request('/v1/authorization-result',dict(snapshot_id=SID,request_id=REQ))
        self.assertEqual(status,200)
        self.assertEqual(saved['authorization'],result['authorization'])
        self.runtime.app.worker=RoutingWorker(self.db,FakeGraph(self.db),Validator(self.db),
            Journal(Path(self.tmp.name)/'journal'),solve=lambda _:self.fail('must not solve again'))
        self.runtime.ready=True
        status,replayed=self.request('/v1/plan-and-authorize',body)
        self.assertEqual(status,200)
        self.assertEqual(replayed['authorization'],result['authorization'])
        self.assertEqual(self.session.auth_calls,1)
