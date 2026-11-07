"""Offline exact-scope gate tests: real solvers/validator, synthetic RPC transports."""
from copy import deepcopy
from datetime import timedelta
from tempfile import TemporaryDirectory
from concurrent.futures import ThreadPoolExecutor
import threading
import json
from pathlib import Path
import subprocess
import sys
from unittest.mock import Mock, patch
from uuid import UUID
import unittest

from .test_worker_flow import FakeDatabase, FakeGraph, SID, OWNER, REQ, GID
from .test_combined_workflow import CombinedSession
from ..errors import WorkerError
from ..journal import Journal
from ..orchestrator import RoutingWorker
from ..validator import Validator
from ..staged import ExactRouteWorkflow
from ..server import Application, application_from_env

VID, PID = [str(UUID(int=i)) for i in (30, 31)]
TASKS = [str(UUID(int=i)) for i in (40, 41, 42)]


class ExactSession(CombinedSession):
    def __init__(self, db):
        super().__init__(db)
        self.snapshots = 0
        self.calls = []
        self.admitted = True
        self.short_lease = False

    def rpc(self, name, params=None):
        self.calls.append(name)
        if name == 'get_my_routing_overview':
            return dict(ngo_id=self.user_id, policy_id=PID, authorization_enforced=True,
                        eligible_tasks=[dict(task_id=o['task']['task_id'], claim_id=o['claim']['claim_id'],
                                             load_kg=o['task']['load_kg'])
                                        for o in self.db.bundle['snapshot']['body']['observations']] if self.admitted else [])
        if name == 'begin_my_routing_snapshot':
            self.snapshots += 1
            assert params == dict(p_request=REQ, p_policy=PID, p_vehicle_ids=[VID])
            return deepcopy(self.db.bundle['snapshot'])
        result = super().rpc(name, params)
        if name == 'get_my_claim_cards_v2' and self.short_lease:
            result[0]['lease_expires_at'] = (self.db.clock + timedelta(minutes=254)).isoformat()
        return result


class StagedTests(unittest.TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.db = FakeDatabase()
        snapshot = self.db.bundle['snapshot']
        raw = snapshot['body']
        snapshot['policy_id'] = PID
        raw['policy'].update(mandatory=False, dispatch_margin_minutes=15)
        raw['vehicles'] = [raw['vehicles'][0]]
        raw['vehicles'][0].update(vehicle_id=VID, payload_capacity_kg=600)
        raw['selected_vehicle_ids'] = [VID]
        third = deepcopy(raw['observations'][0])
        third['task'].update(claim_id='THIRD-CLAIM', listing_id='THIRD-LISTING')
        third['claim'].update(claim_id='THIRD-CLAIM', listing_id='THIRD-LISTING')
        third['lease'].update(claim_id='THIRD-CLAIM', lease_id='THIRD-LEASE')
        third['listing'].update(listing_id='THIRD-LISTING', donation_id='THIRD-DONATION')
        third['donations'][0]['donation_id'] = 'THIRD-DONATION'
        raw['observations'].append(third)
        for tid, observation in zip(TASKS, raw['observations']):
            observation['task']['task_id'] = tid
        self.session = ExactSession(self.db)
        self.journal = Journal(self.temp.name)
        self.worker = RoutingWorker(self.db, FakeGraph(self.db), Validator(self.db), self.journal)
        self.flow = ExactRouteWorkflow(self.worker)
        self.scope = dict(ngo_id=OWNER, vehicle_id=VID, policy_id=PID, graph_id=GID,
                          task_ids=TASKS, horizon_minutes=240, dispatch_margin_minutes=15)

    def ready(self):
        result = self.flow.plan(self.session, REQ, self.scope)
        self.assertEqual(result['kind'], 'EXACT_CANDIDATE_VERIFIED')
        self.assertFalse(result['dispatch_authority_issued'])
        self.assertEqual(self.session.auth_calls, 0)
        return result

    def test_exact_three_task_success_requires_separate_authorization_with_null(self):
        ready = self.ready()
        self.assertIsNotNone(self.db.attestation)
        result = self.flow.authorize(self.session, REQ, self.scope)
        self.assertEqual(result['authorization']['candidate_id'], ready['candidate_id'])
        self.assertEqual(self.session.snapshots, 1)
        self.assertEqual(self.session.auth_calls, 1)
        self.assertEqual(self.journal.get(REQ, 'exact_authorization_request')['p_depart_at'], None)
        self.assertEqual(self.flow.authorize(self.session, REQ, self.scope), result)
        self.assertEqual(self.session.auth_calls, 1)

    def test_missing_extra_duplicate_unserved_wrong_vehicle_and_invalid_attestation_never_authorize(self):
        actual = self.worker.plan
        for kind in ('missing', 'extra', 'duplicate', 'unserved', 'vehicle', 'attestation'):
            with self.subTest(kind=kind), TemporaryDirectory() as directory:
                self.journal = self.worker.journal = Journal(directory)
                self.flow = ExactRouteWorkflow(self.worker)
                def changed(*args):
                    result = deepcopy(actual(*args))
                    plan = next(m['plan'] for m in result['methods'] if m['method'] == 'proposed')
                    if kind == 'missing': plan['routes'][0]['stops'].pop()
                    if kind == 'extra': plan['routes'][0]['stops'].append(dict(plan['routes'][0]['stops'][0], task_id=str(UUID(int=999))))
                    if kind == 'duplicate': plan['routes'][0]['stops'][1] = deepcopy(plan['routes'][0]['stops'][0])
                    if kind == 'unserved': plan['unserved_tasks'] = [TASKS[0]]
                    if kind == 'vehicle': plan['routes'][0]['vehicle_id'] = str(UUID(int=999))
                    if kind == 'attestation': result['validation_status'] = 'LOCAL_ONLY'
                    return result
                with patch.object(self.worker, 'plan', side_effect=changed):
                    with self.assertRaises(WorkerError): self.flow.plan(self.session, REQ, self.scope)
                with self.assertRaises(WorkerError): self.flow.authorize(self.session, REQ, self.scope)
                self.assertEqual(self.session.auth_calls, 0)

    def test_unserved_exact_plan_gate_is_not_just_a_display_label(self):
        self.ready()
        result = self.journal.read_saved_result(SID, OWNER, REQ)
        proposed = next(m['plan'] for m in result['methods'] if m['method'] == 'proposed')
        self.assertEqual(sorted(s['task_id'] for s in proposed['routes'][0]['stops']), sorted(TASKS))
        self.assertEqual(proposed['unserved_tasks'], [])

    def test_real_attested_partial_plan_is_rejected_without_authorization(self):
        # Synthetic graph only: make the hub unreachable within the horizon.
        # mandatory=false remains unchanged; independent validation accepts a
        # feasible subset, but the new exact gate must reject that valid subset.
        matrix = self.db.bundle['matrix']['body']
        node = self.db.bundle['snapshot']['body']['observations'][1]['task']['pickup_road_node_id']
        index = matrix['node_order'].index(str(node))
        for other in range(len(matrix['node_order'])):
            if other != index:
                matrix['travel_minutes'][index][other] = 500
                matrix['travel_minutes'][other][index] = 500
        with self.assertRaises(WorkerError) as error: self.flow.plan(self.session, REQ, self.scope)
        self.assertIn(error.exception.code, ('EXACT_UNSERVED_TASKS', 'EXACT_TASK_SET_MISMATCH'))
        self.assertIsNotNone(self.db.attestation)
        self.assertEqual(self.journal.get(SID, 'result')['validation_status'], 'ATTESTED')
        self.assertEqual(self.session.auth_calls, 0)
        self.assertIsNone(self.journal.get(REQ, 'exact_ready'))

    def test_real_attested_four_task_plan_is_not_authorized_for_three_task_scope(self):
        raw = self.db.bundle['snapshot']['body']
        fourth = deepcopy(raw['observations'][0])
        fourth['task'].update(task_id=str(UUID(int=43)), claim_id='FOURTH-CLAIM', listing_id='FOURTH-LISTING')
        fourth['claim'].update(claim_id='FOURTH-CLAIM', listing_id='FOURTH-LISTING')
        fourth['lease'].update(claim_id='FOURTH-CLAIM', lease_id='FOURTH-LEASE')
        fourth['listing'].update(listing_id='FOURTH-LISTING', donation_id='FOURTH-DONATION')
        fourth['donations'][0]['donation_id'] = 'FOURTH-DONATION'
        raw['observations'].append(fourth)
        with self.assertRaises(WorkerError) as error: self.flow.plan(self.session, REQ, self.scope)
        self.assertEqual(error.exception.code, 'EXACT_TASK_SET_MISMATCH')
        self.assertIsNotNone(self.db.attestation)
        self.assertEqual(self.session.auth_calls, 0)

    def test_missing_or_corrupt_independent_witness_blocks_authorization(self):
        self.ready()
        original = self.journal.get
        for bad in (None, dict(original(SID, 'independent_attestation'), candidate_id=str(UUID(int=99))),
                    dict(original(SID, 'independent_attestation'), candidate_digest='invalid'),
                    dict(original(SID, 'independent_attestation'), validator_build=None)):
            with self.subTest(witness=bad), patch.object(self.journal, 'get',
                    side_effect=lambda sid, name: bad if name == 'independent_attestation' else original(sid, name)):
                with self.assertRaises(WorkerError): self.flow.authorize(self.session, REQ, self.scope)
                self.assertEqual(self.session.auth_calls, 0)

    def test_stale_policy_graph_snapshot_vehicle_and_lease_bindings_fail_closed(self):
        self.ready()
        for kind in ('age', 'policy', 'graph', 'snapshot', 'lease'):
            before = deepcopy(self.db.bundle)
            clock = self.db.clock
            with self.subTest(kind=kind):
                if kind == 'age': self.db.clock += timedelta(minutes=6)
                if kind == 'policy': self.db.bundle['snapshot']['body']['policy']['dispatch_margin_minutes'] = 10
                if kind == 'graph': self.db.bundle['matrix']['graph_id'] = str(UUID(int=99))
                if kind == 'snapshot': self.db.bundle['snapshot']['digest'] = 'z'*64
                if kind == 'lease': self.session.short_lease = True
                with self.assertRaises(WorkerError): self.flow.authorize(self.session, REQ, self.scope)
                self.assertEqual(self.session.auth_calls, 0)
                self.db.bundle = before
                self.db.clock = clock
                self.session.short_lease = False

    def test_expired_insufficient_and_exact_255_lease_reject_before_snapshot(self):
        original = self.session.rpc
        for minutes in (-1, 254, 255):
            with self.subTest(minutes=minutes), TemporaryDirectory() as directory:
                self.flow = ExactRouteWorkflow(RoutingWorker(self.db, FakeGraph(self.db), Validator(self.db), Journal(directory)))
                def short(name, params=None):
                    result = original(name, params)
                    if name == 'get_my_claim_cards_v2':
                        result[0]['lease_expires_at'] = (self.db.clock + timedelta(minutes=minutes)).isoformat()
                    return result
                with patch.object(self.session, 'rpc', side_effect=short):
                    with self.assertRaises(WorkerError) as error: self.flow.plan(self.session, REQ, self.scope)
                    self.assertEqual(error.exception.code, 'EXACT_LEASE_BELOW_ADMISSION')
                self.assertEqual(self.session.snapshots, 0)
                self.assertEqual(self.session.auth_calls, 0)

    def test_current_vehicle_version_change_or_reservation_blocks_authorization(self):
        self.ready()
        original = self.session.rpc
        for field, value in [('vehicle_version', 999), ('eligible_for_planning', False),
                             ('ngo_user_id', str(UUID(int=99))), ('max_route_duration_min', 260)]:
            def changed(name, params=None):
                result = original(name, params)
                if name == 'list_my_vehicles': result['vehicles'][0][field] = value
                return result
            with self.subTest(field=field), patch.object(self.session, 'rpc', side_effect=changed):
                with self.assertRaises(WorkerError): self.flow.authorize(self.session, REQ, self.scope)
                self.assertEqual(self.session.auth_calls, 0)

    def test_concurrent_authorization_has_one_call_then_receipt_only_replay(self):
        self.ready()
        self.session.ready = threading.Event()
        self.session.release = threading.Event()
        with ThreadPoolExecutor(max_workers=2) as pool:
            first = pool.submit(self.flow.authorize, self.session, REQ, self.scope)
            self.assertTrue(self.session.ready.wait(10))
            with self.assertRaises(WorkerError): self.flow.authorize(self.session, REQ, self.scope)
            self.session.release.set()
            result = first.result(timeout=10)
        self.assertEqual(self.flow.authorize(self.session, REQ, self.scope), result)
        self.assertEqual(self.session.auth_calls, 1)

    def test_protected_overview_rejection_before_plan_and_before_authorization(self):
        self.session.admitted = False
        with self.assertRaises(WorkerError): self.flow.plan(self.session, REQ, self.scope)
        self.assertEqual(self.session.snapshots, 0)
        self.session.admitted = True
        self.ready()
        self.session.admitted = False
        with self.assertRaises(WorkerError): self.flow.authorize(self.session, REQ, self.scope)
        self.assertEqual(self.session.auth_calls, 0)

    def test_lost_authorization_ack_reconciles_committed_receipt_without_retry(self):
        self.ready()
        self.session.lost = True
        with self.assertRaises(WorkerError): self.flow.authorize(self.session, REQ, self.scope)
        self.assertIsNotNone(self.journal.get(REQ, 'exact_authorization_send'))
        restarted = ExactRouteWorkflow(self.worker)
        result = restarted.authorize(self.session, REQ, self.scope)
        self.assertEqual(result['kind'], 'DATABASE_AUTHORIZATION_RECEIPT')
        self.assertEqual(self.session.auth_calls, 1)

    def test_uncertain_uncommitted_authorization_is_never_resent_even_after_restart(self):
        self.ready()
        original = self.session.rpc
        def uncertain(name, params=None):
            if name == 'authorize_my_routing_candidate':
                self.session.auth_calls += 1
                raise WorkerError('RPC_OUTCOME_UNKNOWN_RETRY_SAME_REQUEST', 503, True)
            return original(name, params)
        with patch.object(self.session, 'rpc', side_effect=uncertain):
            with self.assertRaises(WorkerError): self.flow.authorize(self.session, REQ, self.scope)
            with self.assertRaises(WorkerError) as error:
                ExactRouteWorkflow(self.worker).authorize(self.session, REQ, self.scope)
            self.assertEqual(error.exception.code, 'EXACT_AUTHORIZATION_UNCERTAIN_RECONCILE_ONLY')
        self.assertEqual(self.session.auth_calls, 1)

    def test_abrupt_server_process_exit_preserves_send_marker_and_prevents_resend(self):
        self.ready()
        directory = Path(self.temp.name)
        (directory / 'synthetic-bundle.json').write_text(json.dumps(self.db.bundle), encoding='utf-8')
        code = r'''
import json, os, sys
from pathlib import Path
from backend.routing.worker_service.tests.test_staged_workflow import ExactSession
from backend.routing.worker_service.tests.test_worker_flow import FakeDatabase, FakeGraph, REQ
from backend.routing.worker_service.journal import Journal
from backend.routing.worker_service.orchestrator import RoutingWorker
from backend.routing.worker_service.validator import Validator
from backend.routing.worker_service.staged import ExactRouteWorkflow
directory=Path(sys.argv[1]);scope=json.loads(sys.argv[2])
db=FakeDatabase();db.bundle=json.loads((directory/'synthetic-bundle.json').read_text(encoding='utf-8'))
session=ExactSession(db);original=session.rpc
def abrupt(name, params=None):
    if name=='authorize_my_routing_candidate':
        (directory/'synthetic-authorize-call-count.txt').write_text('1',encoding='utf-8')
        os._exit(37)
    return original(name,params)
session.rpc=abrupt
worker=RoutingWorker(db,FakeGraph(db),Validator(db),Journal(directory))
ExactRouteWorkflow(worker).authorize(session,REQ,scope)
'''
        child = subprocess.run([sys.executable, '-B', '-c', code, self.temp.name, json.dumps(self.scope)],
                               cwd=Path(__file__).resolve().parents[4], capture_output=True, timeout=20)
        self.assertEqual(child.returncode, 37, child.stderr.decode(errors='replace'))
        reopened = Journal(self.temp.name)
        self.assertIsNotNone(reopened.get(REQ, 'exact_authorization_send'))
        self.assertEqual((directory / 'synthetic-authorize-call-count.txt').read_text(), '1')
        self.worker.journal = reopened
        with self.assertRaises(WorkerError) as error:
            ExactRouteWorkflow(self.worker).authorize(self.session, REQ, self.scope)
        self.assertEqual(error.exception.code, 'EXACT_AUTHORIZATION_UNCERTAIN_RECONCILE_ONLY')
        self.assertEqual(self.session.auth_calls, 0)

    def test_lost_snapshot_ack_never_creates_another_snapshot(self):
        original = self.session.rpc
        def uncertain(name, params=None):
            result = original(name, params)
            if name == 'begin_my_routing_snapshot': raise WorkerError('OUTCOME_UNKNOWN', 503, True)
            return result
        with patch.object(self.session, 'rpc', side_effect=uncertain):
            with self.assertRaises(WorkerError): self.flow.plan(self.session, REQ, self.scope)
            with self.assertRaises(WorkerError): self.flow.plan(self.session, REQ, self.scope)
        self.assertEqual(self.session.snapshots, 1)
        self.assertEqual(self.session.auth_calls, 0)

    def test_owner_scope_and_default_endpoint_gate(self):
        auth = Mock()
        auth.verify.return_value = self.session
        app = Application(auth=auth, worker=self.worker, active=True)
        body = dict(request_id=REQ, scope=self.scope)
        for endpoint in ('/v1/exact-route-plan', '/v1/exact-route-authorize'):
            with self.assertRaises(WorkerError) as error: app.dispatch(endpoint, 'Bearer synthetic', body)
            self.assertEqual(error.exception.code, 'EXACT_WORKFLOW_DISABLED')
            self.assertEqual(self.session.snapshots, 0)
            self.assertEqual(self.session.auth_calls, 0)
        app.exact_enabled = True
        scope = dict(self.scope, ngo_id=str(UUID(int=99)))
        with self.assertRaises(WorkerError): app.dispatch('/v1/exact-route-plan', 'Bearer synthetic', dict(body, scope=scope))
        self.assertEqual(self.session.snapshots, 0)
        auth.verify.side_effect = WorkerError('AUTHENTICATION_REQUIRED', 401)
        with self.assertRaises(WorkerError): app.dispatch('/v1/exact-route-plan', 'Bearer rejected', body)
        self.assertEqual(self.session.auth_calls, 0)

    def test_environment_gate_requires_exact_approval_and_existing_activation(self):
        # Configuration construction only: no real credentials or connections.
        env = dict(GEOLOCK_ROUTING_ALLOW_DEV_WRITES='APPROVED',
                   GEOLOCK_ROUTING_ACTIVATION_REF='LOCAL-ONLY-TEST',
                   GEOLOCK_PROJECT_REF='rcgyuwiidqvrgbxswhqj',
                   GEOLOCK_VALIDATOR_TOKEN='synthetic-token-' * 3,
                   GEOLOCK_GRAPH_DSN='synthetic-graph', GEOLOCK_PLANNER_DSN='synthetic-planner',
                   GEOLOCK_SUPABASE_PUBLISHABLE_KEY='sb_publishable_SYNTHETIC',
                   GEOLOCK_VALIDATOR_URL='http://127.0.0.1:8788', GEOLOCK_GRAPH_ID=GID,
                   GEOLOCK_WORKER_STATE=self.temp.name)
        with patch('backend.routing.worker_service.server.RoleRpc.validate_dsn'), \
                patch('backend.routing.worker_service.server.GraphCache'):
            for flag in ('', 'true', 'approved', 'APPROVED'):
                with self.subTest(flag=flag):
                    app = application_from_env('planner', dict(env, GEOLOCK_EXACT_ROUTE_ENABLED=flag),
                                               rpc_factory=lambda *args: Mock())
                    self.assertEqual(app.exact_enabled, flag == 'APPROVED')
                    self.assertFalse(app.combined_enabled)
        disabled = application_from_env('planner', {'GEOLOCK_EXACT_ROUTE_ENABLED': 'APPROVED'})
        for endpoint in ('/v1/exact-route-plan', '/v1/exact-route-authorize'):
            with self.assertRaises(WorkerError) as error: disabled.dispatch(endpoint, 'Bearer synthetic', {})
            self.assertEqual(error.exception.code, 'WORKER_NOT_ACTIVATED')


if __name__ == '__main__':
    unittest.main()
