"""Synthetic session bytes only. Never contacts a phone, service or DEV."""
from contextlib import redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
import unittest

from ..errors import WorkerError

SCRIPT = Path(__file__).resolve().parents[4] / 'scripts/Run-ExactV3Pilot.py'
spec = importlib.util.spec_from_file_location('exact_pilot_operator_test', SCRIPT)
operator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(operator)


class OperatorTests(unittest.TestCase):
    def test_check_local_never_reads_token_or_contacts_any_surface(self):
        output = io.StringIO()
        with patch('sys.argv', [str(SCRIPT), '--stage', 'check-local']), \
                patch.object(operator, 'health', side_effect=AssertionError('Network')), \
                patch.object(operator, 'phone_session', side_effect=AssertionError('Phone')), redirect_stdout(output):
            operator.main()
        self.assertFalse(json.loads(output.getvalue())['connection_attempted'])

    def test_native_phone_token_is_memory_only_and_scoped(self):
        owner = 'synthetic-ngo'
        token = 'SYNTHETIC-TOKEN-NEVER-LOG'
        session = json.dumps(dict(user=dict(id=owner), access_token=token))
        xml = ('<map><string name="flutter.sb-rcgyuwiidqvrgbxswhqj-auth-token">'
               + session + '</string></map>').encode()
        responses = [SimpleNamespace(returncode=0, stdout=b'List of devices attached\nphone123\tdevice\n'),
                     SimpleNamespace(returncode=0, stdout=xml)]
        output = io.StringIO()
        with patch.dict('os.environ', {'LOCALAPPDATA': 'C:/synthetic'}), \
                patch.object(operator.subprocess, 'run', side_effect=responses) as run, redirect_stdout(output):
            self.assertEqual(operator.phone_session(owner), token)
        self.assertEqual(output.getvalue(), '')
        self.assertTrue(all(token not in str(call) for call in run.call_args_list))

    def test_wrong_session_owner_is_rejected_without_http_or_token_output(self):
        xml = b'<map><string name="flutter.sb-rcgyuwiidqvrgbxswhqj-auth-token">{"user":{"id":"other"},"access_token":"SYNTHETIC"}</string></map>'
        with patch.dict('os.environ', {'LOCALAPPDATA': 'C:/synthetic'}), patch.object(operator.subprocess, 'run',
                side_effect=[SimpleNamespace(returncode=0, stdout=b'phone123\tdevice\n'),
                             SimpleNamespace(returncode=0, stdout=xml)]):
            with self.assertRaises(WorkerError): operator.phone_session('expected-owner')

    def test_http_transport_never_follows_arbitrary_endpoints(self):
        with self.assertRaises(WorkerError): operator.call_with_token('SYNTHETIC', '/v1/plan-and-authorize', {})

    def test_live_stage_requires_approval_before_health_or_session_access(self):
        with patch('sys.argv', [str(SCRIPT), '--stage', 'plan']), \
                patch.object(operator, 'health', side_effect=AssertionError('Network')):
            with self.assertRaises(WorkerError): operator.main()

    def test_readonly_receipt_reconciliation_does_not_depend_on_validator(self):
        output = io.StringIO()
        with patch('sys.argv', [str(SCRIPT), '--stage', 'reconcile', '--approval-ref', 'LOCAL-ONLY-TEST']), \
                patch.object(operator, 'health') as health, \
                patch.object(operator, 'phone_session', return_value='SYNTHETIC'), \
                patch.object(operator, 'StagedPilotClient') as client, \
                patch.dict('os.environ', {'LOCALAPPDATA': 'C:/synthetic'}), redirect_stdout(output):
            client.return_value.reconcile.return_value = {'kind': 'AUTHORIZATION_UNCONFIRMED'}
            operator.main()
        health.assert_called_once_with((8787,))
        client.return_value.reconcile.assert_called_once_with()
        client.return_value.plan.assert_not_called()
        client.return_value.authorize.assert_not_called()
        self.assertNotIn('SYNTHETIC', output.getvalue())


if __name__ == '__main__':
    unittest.main()
