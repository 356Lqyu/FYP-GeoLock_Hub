"""No network, ADB, JWT or database. Durable operator-stage regression tests."""
from tempfile import TemporaryDirectory
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import subprocess
import sys
import threading
import unittest

from .test_staged_workflow import TASKS, VID, PID
from .test_worker_flow import SID, OWNER, REQ, GID, CID
from ..errors import WorkerError
from ..orchestrator import step_id
from ..staged_client import StagedPilotClient


class ClientTests(unittest.TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.scope = dict(ngo_id=OWNER, vehicle_id=VID, policy_id=PID, graph_id=GID,
                          task_ids=TASKS, horizon_minutes=240, dispatch_margin_minutes=15)
        self.ready = dict(kind='EXACT_CANDIDATE_VERIFIED', ngo_id=OWNER,
            vehicle_id=VID, policy_id=PID, task_ids=sorted(TASKS), request_id=REQ,
            snapshot_id=SID, candidate_id=CID, validation_status='ATTESTED',
            authorization_request_id=step_id(SID, 'authorize-auto-now'), dispatch_authority_issued=False)
        self.receipt = dict(kind='DATABASE_AUTHORIZATION_RECEIPT', ngo_id=OWNER,
            request_id=REQ, snapshot_id=SID, authorization_request_id=self.ready['authorization_request_id'],
            authorization=dict(candidate_id=CID, snapshot_id=SID, departure_mode='AUTO_NOW', route_ids=['local-route']))
        self.calls = []
        def call(path, body):
            self.calls.append((path, body))
            return self.ready if path.endswith('-plan') else self.receipt
        self.call = call
        self.client = StagedPilotClient(self.temp.name, REQ, self.scope, self.call)

    def test_plan_stops_before_authorization_and_reopening_never_sends(self):
        self.client.plan()
        self.assertEqual([p for p, _ in self.calls], ['/v1/exact-route-plan'])
        reopened = StagedPilotClient(self.temp.name, REQ, self.scope, self.call)
        self.assertEqual(len(self.calls), 1)
        with self.assertRaises(WorkerError): reopened.plan()
        self.assertEqual(len(self.calls), 1)

    def test_separate_authorization_once_with_persisted_id(self):
        self.client.plan()
        self.client.authorize()
        send = self.client.journal.get(REQ, 'client_authorization_send')
        self.assertEqual(send['request_id'], self.ready['authorization_request_id'])
        with self.assertRaises(WorkerError): self.client.authorize()
        self.assertEqual(len(self.calls), 2)
        self.assertEqual(self.client.reconcile(), self.receipt)
        self.assertEqual(self.calls[-1][0], '/v1/authorization-result')

    def test_timeout_never_retries_authorization_after_restart(self):
        self.client.plan()
        self.client.call = lambda *_: (_ for _ in ()).throw(TimeoutError())
        with self.assertRaises(TimeoutError): self.client.authorize()
        reopened = StagedPilotClient(self.temp.name, REQ, self.scope,
                                     lambda *_: self.fail('Authorization resent'))
        with self.assertRaises(WorkerError): reopened.authorize()

    def test_not_found_receipt_does_not_clear_send_marker(self):
        self.client.plan()
        self.client.journal.save(REQ, 'client_authorization_send', {'test': 'uncertain'})
        self.client.call = lambda *_: dict(kind='AUTHORIZATION_UNCONFIRMED', ngo_id=OWNER,
                                          snapshot_id=SID, request_id=REQ)
        self.client.reconcile()
        with self.assertRaises(WorkerError): self.client.authorize()

    def test_changed_scope_and_malformed_receipt_fail_closed(self):
        self.client.plan()
        with self.assertRaises(WorkerError):
            StagedPilotClient(self.temp.name, REQ, dict(self.scope, vehicle_id=GID), self.call)
        self.client.call = lambda *_: dict(self.receipt, snapshot_id=GID)
        with self.assertRaises(WorkerError): self.client.authorize()
        self.assertIsNone(self.client.journal.get(REQ, 'client_receipt'))

    def test_incomplete_plan_can_never_authorize(self):
        self.client.call = lambda *_: dict(self.ready, task_ids=TASKS[:2])
        with self.assertRaises(WorkerError): self.client.plan()
        with self.assertRaises(WorkerError): self.client.authorize()
        self.assertIsNone(self.client.journal.get(REQ, 'client_ready'))

    def test_abrupt_client_process_exit_cannot_resend_after_reopen(self):
        self.client.plan()
        code = r'''
import json, os, sys
from pathlib import Path
from backend.routing.worker_service.staged_client import StagedPilotClient
from backend.routing.worker_service.tests.test_worker_flow import REQ
def abrupt(path, body):
    (Path(sys.argv[1])/'synthetic-http-send-count.txt').write_text('1',encoding='utf-8')
    os._exit(38)
StagedPilotClient(sys.argv[1],REQ,json.loads(sys.argv[2]),abrupt).authorize()
'''
        child = subprocess.run([sys.executable, '-B', '-c', code, self.temp.name, json.dumps(self.scope)],
                               cwd=Path(__file__).resolve().parents[4], capture_output=True, timeout=20)
        self.assertEqual(child.returncode, 38, child.stderr.decode(errors='replace'))
        reopened = StagedPilotClient(self.temp.name, REQ, self.scope,
                                     lambda *_: self.fail('HTTP authorization resent'))
        with self.assertRaises(WorkerError): reopened.authorize()
        self.assertIsNotNone(reopened.journal.get(REQ, 'client_authorization_send'))
        self.assertEqual((Path(self.temp.name) / 'synthetic-http-send-count.txt').read_text(), '1')

    def test_concurrent_clients_have_one_authorization_send(self):
        self.client.plan()
        started, release = threading.Event(), threading.Event()
        sends = []
        def slow(path, body):
            sends.append(path)
            started.set()
            release.wait(10)
            return self.receipt
        first = StagedPilotClient(self.temp.name, REQ, self.scope, slow)
        second = StagedPilotClient(self.temp.name, REQ, self.scope, slow)
        with ThreadPoolExecutor(max_workers=2) as pool:
            running = pool.submit(first.authorize)
            try:
                self.assertTrue(started.wait(10))
                with self.assertRaises(WorkerError): second.authorize()
            finally:
                release.set()
            self.assertEqual(running.result(timeout=10), self.receipt)
        self.assertEqual(sends, ['/v1/exact-route-authorize'])


if __name__ == '__main__':
    unittest.main()
